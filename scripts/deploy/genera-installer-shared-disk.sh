#!/bin/bash
# =============================================================================
#  Genera l'installer autoportante che porta 50-shared-disk.sh su un rig GIA'
#  installato, senza rifare la ISO. (Difetto #707: la sonda di luglio cercava
#  il disco per un seriale che non esiste piu', usciva 0 in silenzio, e
#  l'override documentato in shared-disk.env era inerte perche' definiva altri
#  nomi di variabile.)
#
#  Perche' un generatore e non un file committato: l'installer si porta dentro
#  una copia di rig-common-scripts/50-shared-disk.sh. Committare anche quella
#  vorrebbe dire due copie dello stesso sorgente nello stesso repo, che e'
#  esattamente il modo in cui le tre copie di luglio sono andate fuori sync.
#  Qui la copia si genera al momento e porta con se' il git blob sha1
#  dell'originale: l'installer lo ricontrolla prima di rendere alcunche', e si
#  rifiuta se non coincide.
#
#  Uso:
#      bash scripts/deploy/genera-installer-shared-disk.sh [file-di-uscita]
#  Senza argomenti scrive su stdout.
# =============================================================================
set -Eeuo pipefail
cd "$(dirname "$0")/../.."
RADICE="$(pwd)"

CORPO="scripts/deploy/installer-shared-disk.corpo.sh"
SORGENTE="rig-common-scripts/50-shared-disk.sh"
USCITA="${1:-}"

[ -f "$CORPO" ]    || { echo "manca $CORPO" >&2; exit 1; }
[ -f "$SORGENTE" ] || { echo "manca $SORGENTE" >&2; exit 1; }

# shellcheck disable=SC1091
source config/shared-disk.env

for v in SHARED_DISK_UUID SHARED_DISK_SERIAL SHARED_MOUNT_PATH; do
    [ -n "${!v:-}" ] || { echo "config/shared-disk.env: $v vuoto" >&2; exit 1; }
done
[[ "$SHARED_DISK_UUID" =~ ^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$ ]] \
    || { echo "config/shared-disk.env: SHARED_DISK_UUID non ha la forma di uno UUID" >&2; exit 1; }
[[ "$SHARED_DISK_SERIAL" != CHANGEME* ]] \
    || { echo "config/shared-disk.env: SHARED_DISK_SERIAL non compilato" >&2; exit 1; }

# I due valori finiscono dentro virgolette doppie nel sorgente reso: una
# virgoletta, un backslash o un $ li' dentro non produce un errore visibile,
# produce uno script che fa un'altra cosa. Meglio fermarsi qui.
for v in SHARED_DISK_SERIAL SHARED_MOUNT_PATH; do
    case "${!v}" in
        *'"'*|*'\'*|*'$'*|*'`'*)
            echo "config/shared-disk.env: $v contiene un carattere che romperebbe la resa" >&2
            exit 1 ;;
    esac
done

# Il sorgente DEVE avere ancora i suoi placeholder: se li ha gia' persi vuol
# dire che qualcuno ha committato un file gia' reso, e l'installer renderebbe
# valori di un altro rig.
for ph in __SHARED_DISK_SERIAL__ __SHARED_MOUNT_PATH__; do
    grep -q "$ph" "$SORGENTE" || { echo "$SORGENTE: manca il placeholder $ph" >&2; exit 1; }
done
bash -n "$SORGENTE" || { echo "$SORGENTE: sintassi non valida" >&2; exit 1; }

# git blob sha1 calcolato a mano: cosi' l'installer puo' riverificarlo su un
# rig dove git non c'e' e la rete non si usa.
BLOB=$( { printf 'blob %d\0' "$(stat -c%s "$SORGENTE")"; cat "$SORGENTE"; } | sha1sum | cut -d' ' -f1)
SHA256=$(sha256sum "$SORGENTE" | cut -d' ' -f1)
if git -C "$RADICE" rev-parse --git-dir >/dev/null 2>&1; then
    ATTESO=$(git -C "$RADICE" hash-object "$SORGENTE")
    [ "$BLOB" = "$ATTESO" ] || { echo "blob calcolato ($BLOB) != git hash-object ($ATTESO)" >&2; exit 1; }
    COMMIT=$(git -C "$RADICE" rev-parse --short=8 HEAD)
    git -C "$RADICE" diff --quiet -- "$SORGENTE" \
        || COMMIT="${COMMIT}-modificato"
else
    COMMIT="sconosciuto"
fi

NOME="$(basename "${USCITA:-rig-installa-shared-disk.sh}")"

genera() {
    sed -e "s|@@BLOB@@|${BLOB}|g" \
        -e "s|@@SHA256@@|${SHA256}|g" \
        -e "s|@@UUID@@|${SHARED_DISK_UUID}|g" \
        -e "s|@@SERIAL@@|${SHARED_DISK_SERIAL}|g" \
        -e "s|@@MOUNT@@|${SHARED_MOUNT_PATH}|g" \
        -e "s|@@COMMIT@@|${COMMIT}|g" \
        -e "s|@@NOME@@|${NOME}|g" \
        "$CORPO" \
    | while IFS= read -r riga; do
          if [ "$riga" = "@@PAYLOAD@@" ]; then
              base64 -w 76 "$SORGENTE"
          else
              printf '%s\n' "$riga"
          fi
      done
}

TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
genera > "$TMP"

# Non si consegna uno script che non compila, e non si consegna uno script che
# ha ancora un segnaposto dentro.
bash -n "$TMP" || { echo "l'installer generato non compila" >&2; exit 1; }
if grep -q '@@[A-Z0-9]*@@' "$TMP"; then
    echo "l'installer generato ha ancora segnaposto:" >&2
    grep -o '@@[A-Z0-9]*@@' "$TMP" | sort -u >&2
    exit 1
fi

if [ -n "$USCITA" ]; then
    install -m 0644 "$TMP" "$USCITA"
    echo "generato: $USCITA" >&2
    echo "  sorgente:  $SORGENTE @ $COMMIT" >&2
    echo "  blob sha1: $BLOB" >&2
    echo "  sha256:    $(sha256sum "$USCITA" | cut -d' ' -f1)" >&2
else
    cat "$TMP"
fi
