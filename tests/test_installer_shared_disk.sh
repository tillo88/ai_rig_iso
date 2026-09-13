#!/usr/bin/env bash
# Prova di scripts/deploy/genera-installer-shared-disk.sh e dell'installer che
# genera (difetto #707).
#
# L'installer gira da root su un rig vivo e tocca /usr/local/bin, /opt/cache e
# /etc/fstab. Cio' che conta qui non e' che installi: e' che si RIFIUTI, e che
# quando qualcosa va storto RIMETTA INDIETRO. Un solo scenario su trenta deve
# finire con l'installazione riuscita.
#
# Nessun privilegio richiesto, nessun rig reale: findmnt, blkid, mountpoint e
# systemctl sono sostituiti in PATH, e i percorsi di sistema sono riscritti
# verso una sandbox riscrivendo il SOLO blocco dei percorsi in testa
# all'installer — cosi' si prova l'installer vero, non una sua parafrasi.
#
# Uso:  bash tests/test_installer_shared_disk.sh

set -uo pipefail

QUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RADICE="$QUI/.."
GEN="$RADICE/scripts/deploy/genera-installer-shared-disk.sh"
FONTE="$RADICE/rig-common-scripts/50-shared-disk.sh"
[ -f "$GEN" ]   || { echo "generatore non trovato: $GEN"; exit 1; }
[ -f "$FONTE" ] || { echo "sorgente non trovato: $FONTE"; exit 1; }

# shellcheck disable=SC1091
source "$RADICE/config/shared-disk.env"
UUID_OK="$SHARED_DISK_UUID"
MOUNT_OK="$SHARED_MOUNT_PATH"
UUID_NO=99999999-aaaa-bbbb-cccc-dddddddddddd

BASE="$(mktemp -d)"
trap 'rm -rf "$BASE"' EXIT
PASSATI=0; FALLITI=0; SALTATI=0

# setpriv + un utente senza privilegi servono solo a 4 scenari su 30: dove non
# ci sono, quei 4 si saltano dichiarandolo invece di darli per buoni.
SENZA_PRIVILEGI=0
if command -v setpriv >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ] && id -u nobody >/dev/null 2>&1; then
    SENZA_PRIVILEGI=1
fi

# --- generatore -------------------------------------------------------------
# Genera un installer partendo da una COPIA eventualmente manomessa del
# sorgente, in un finto albero di repo. Cosi' l'installer autentica il proprio
# payload (gli hash li calcola il generatore) e si arriva davvero ai controlli
# a valle, invece di scavalcare la verifica di provenienza.
_genera() {  # $1 = dir di lavoro ; $2 = file installer in uscita ; resto: sed sul sorgente
    local dir="$1" out="$2"; shift 2
    mkdir -p "$dir/rig-common-scripts" "$dir/scripts/deploy" "$dir/config"
    cp "$RADICE/config/shared-disk.env" "$dir/config/"
    cp "$RADICE/scripts/deploy/installer-shared-disk.corpo.sh" "$dir/scripts/deploy/"
    cp "$GEN" "$dir/scripts/deploy/"
    if [ "$#" -gt 0 ]; then
        sed "$@" "$FONTE" > "$dir/rig-common-scripts/50-shared-disk.sh"
    else
        cp "$FONTE" "$dir/rig-common-scripts/50-shared-disk.sh"
    fi
    bash "$dir/scripts/deploy/genera-installer-shared-disk.sh" "$out" 2>"$dir/gen.err"
}

INSTALLER_BUONO="$BASE/installer-buono.sh"
_genera "$BASE/gen-buono" "$INSTALLER_BUONO" \
    || { echo "il generatore non produce nemmeno l'installer buono:"; cat "$BASE/gen-buono/gen.err"; exit 1; }

# --- sandbox che finge un rig ------------------------------------------------
prepara() {  # $1 = nome scenario ; $2 = installer da usare (default: buono)
    SB="$BASE/$1"
    rm -rf "$SB"; mkdir -p "$SB"/{usr,opt,var/log,var/lib,etc,fake,bin,tmpdir}
    printf '#!/bin/bash\n# vecchia sonda di luglio\nSERIAL="%s"\necho "Salto"\nexit 0\n' \
        "$SHARED_DISK_SERIAL" > "$SB/usr/50-shared-disk.sh"
    chmod 0755 "$SB/usr/50-shared-disk.sh"
    printf 'SHARED_DISK_SERIAL="%s"\nSHARED_MOUNT_PATH="%s"\n' \
        "$SHARED_DISK_SERIAL" "$MOUNT_OK" > "$SB/opt/shared-disk.env"
    chmod 0644 "$SB/opt/shared-disk.env"
    printf 'vecchia riga 1\nvecchia riga 2\n' > "$SB/var/log/shareddisk.log"
    printf 'UUID=%s  %s  ext4  defaults,nofail  0  2\n' "$UUID_OK" "$MOUNT_OK" > "$SB/etc/fstab"
    echo "$UUID_OK" > "$SB/fake/uuid_montato"
    echo "/dev/sdz1" > "$SB/fake/source_mnt"
    echo 0          > "$SB/fake/is_mountpoint"
    echo 0          > "$SB/fake/restart_rc"
    echo active     > "$SB/fake/is_active"
    echo success    > "$SB/fake/result"
    echo 0          > "$SB/fake/exec_status"
    echo 0          > "$SB/fake/uid"
    echo root       > "$SB/fake/utente"
    printf 'AI_RIG_SHARED_DISK=PASS mount=%s device=/dev/sdz1 uuid=%s mode=uuid\n' \
        "$MOUNT_OK" "$UUID_OK" > "$SB/fake/log_append"
    _finti
    cp -r "$SB/bin" "$SB/bin-vero"; rm -f "$SB/bin-vero/id"
    sed -e "s|^DEST=.*|DEST=$SB/usr/50-shared-disk.sh|" \
        -e "s|^ENV=.*|ENV=$SB/opt/shared-disk.env|" \
        -e "s|^LOG=.*|LOG=$SB/var/log/shareddisk.log|" \
        -e "s|^FSTAB=.*|FSTAB=$SB/etc/fstab|" \
        -e "s|^RADICE_BACKUP=.*|RADICE_BACKUP=$SB/var/lib/backup|" \
        "${2:-$INSTALLER_BUONO}" > "$SB/sotto-prova.sh"
    bash -n "$SB/sotto-prova.sh" || { echo "BANCO ROTTO: la copia non compila"; exit 2; }
    # BASE viene da mktemp -d, che e' 0700: senza il bit di traversata un utente
    # senza privilegi non arriva nemmeno al file, e i quattro scenari "senza
    # root" misurerebbero il permesso sbagliato. Si apre QUI, non dentro
    # esegui_nessuno, cosi' uno scenario puo' poi richiudere un singolo file.
    chmod 0711 "$BASE" 2>/dev/null
    chmod -R a+rX "$SB" 2>/dev/null
    # il TMPDIR dello scenario deve essere scrivibile anche da chi gira senza
    # privilegi, altrimenti i quattro scenari "senza root" fallirebbero per un
    # mktemp negato e non per il motivo che devono provare
    chmod 0777 "$SB/tmpdir" 2>/dev/null
}

_finti() {
    cat > "$SB/bin/findmnt" <<EOF
#!/bin/bash
for a in "\$@"; do [ "\$a" = UUID ] && C=UUID; [ "\$a" = SOURCE ] && C=SOURCE; done
case "\${C:-}" in
  UUID)   v=\$(cat "$SB/fake/uuid_montato") ;;
  SOURCE) v=\$(cat "$SB/fake/source_mnt") ;;
  *)      v="" ;;
esac
[ -n "\$v" ] || exit 1
echo "\$v"
EOF
    cat > "$SB/bin/blkid" <<EOF
#!/bin/bash
v=\$(cat "$SB/fake/uuid_montato"); [ -n "\$v" ] || exit 2; echo "\$v"
EOF
    cat > "$SB/bin/mountpoint" <<EOF
#!/bin/bash
exit \$(cat "$SB/fake/is_mountpoint")
EOF
    cat > "$SB/bin/systemctl" <<EOF
#!/bin/bash
case "\$1" in
  restart)   cat "$SB/fake/log_append" >> "$SB/var/log/shareddisk.log"; exit \$(cat "$SB/fake/restart_rc") ;;
  is-active) cat "$SB/fake/is_active" ;;
  show)      case "\$*" in *Result*) cat "$SB/fake/result" ;; *ExecMainStatus*) cat "$SB/fake/exec_status" ;; esac ;;
esac
exit 0
EOF
    # Due finti che riguardano il BANCO, non il rig, e vanno dichiarati:
    #
    #   id      l'installer decide col uid se e' un'installazione vera o un
    #           dry-run. Nella sandbox scrive solo dentro $SB, quindi pretendere
    #           root qui non proverebbe niente e impedirebbe di arrivare ai
    #           controlli veri. Il finto risponde quello che dice $SB/fake/uid;
    #           gli scenari "senza root" usano $SB/bin-vero, che questo finto
    #           non ce l'ha, e li' il uid e' quello autentico.
    #
    #   install toglie "-o root -g root" e passa il resto all'install vero. In
    #           una sandbox che appartiene a chi esegue il banco il cambio di
    #           proprietario non ha significato; il "-m", che e' quello che i
    #           test controllano, resta quello dell'install vero.
    cat > "$SB/bin/id" <<EOF
#!/bin/bash
case "\${1:-}" in
  -u) cat "$SB/fake/uid" ;;
  -un) cat "$SB/fake/utente" ;;
  *) exec /usr/bin/id "\$@" ;;
esac
EOF
    cat > "$SB/bin/install" <<'EOF'
#!/bin/bash
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o|-g) shift 2 ;;
    *)     args+=("$1"); shift ;;
  esac
done
exec /usr/bin/install "${args[@]}"
EOF
    chmod +x "$SB/bin"/*
}

esegui()          { TMPDIR="$SB/tmpdir" PATH="$SB/bin:$PATH" bash "$SB/sotto-prova.sh" "$@" 2>&1; }
esegui_nessuno()  {
    setpriv --reuid=65534 --regid=65534 --clear-groups \
        env TMPDIR="$SB/tmpdir" PATH="$SB/bin-vero:$PATH" bash "$SB/sotto-prova.sh" "$@" 2>&1
}

verifica() {  # $1 nome, $2 esito atteso, $3 output, $4.. condizioni
    local nome="$1" atteso="$2" out="$3"; shift 3
    local visto; visto=$(printf '%s\n' "$out" | sed -n 's/^ESITO=\([A-Z_0-9]*\).*/\1/p' | tail -1)
    local ko=""
    [ "$visto" = "$atteso" ] || ko="atteso $atteso, visto ${visto:-(nessuno)}"
    local c
    for c in "$@"; do eval "$c" || ko="${ko}; condizione non rispettata: $c"; done
    if [ -z "$ko" ]; then
        printf '  ok    %-32s %s\n' "$nome" "$visto"; PASSATI=$((PASSATI+1))
    else
        printf '  KO    %-32s %s\n' "$nome" "$ko"; FALLITI=$((FALLITI+1))
        printf '%s\n' "$out" | sed 's/^/          | /'
    fi
}
salta() { printf '  --    %-32s saltato: %s\n' "$1" "$2"; SALTATI=$((SALTATI+1)); }

# condizioni ricorrenti: il rig non e' stato toccato
INTATTO='grep -q "vecchia sonda" "$SB/usr/50-shared-disk.sh"'
ENV_INTATTO='! grep -q SHARED_DISK_UUID "$SB/opt/shared-disk.env"'
SENZA_BACKUP='! ls -d "$SB"/var/lib/backup/* >/dev/null 2>&1'

echo "  Prova installer disco condiviso (#707)"
echo "  --------------------------------------------------------------------------"

# =============================== il generatore ==============================
d="$BASE/g1"; _genera "$d" "$d/out.sh" -e 's/^set -uo pipefail$/if [ ; then/'
[ $? -ne 0 ] && grep -q 'sintassi non valida' "$d/gen.err" \
  && { printf '  ok    %-32s rifiutato\n' "gen: sorgente non compila"; PASSATI=$((PASSATI+1)); } \
  || { printf '  KO    %-32s doveva rifiutare\n' "gen: sorgente non compila"; FALLITI=$((FALLITI+1)); }

d="$BASE/g2"; _genera "$d" "$d/out.sh" -e 's/__SHARED_MOUNT_PATH__/\/mnt\/fisso/'
[ $? -ne 0 ] && grep -q 'manca il placeholder' "$d/gen.err" \
  && { printf '  ok    %-32s rifiutato\n' "gen: sorgente gia' reso"; PASSATI=$((PASSATI+1)); } \
  || { printf '  KO    %-32s doveva rifiutare\n' "gen: sorgente gia' reso"; FALLITI=$((FALLITI+1)); }

d="$BASE/g3"; mkdir -p "$d/config"
_genera "$d" "$d/out.sh" >/dev/null 2>&1
sed -i 's|^SHARED_MOUNT_PATH=.*|SHARED_MOUNT_PATH="/mnt/a\\"b"|' "$d/config/shared-disk.env"
if bash "$d/scripts/deploy/genera-installer-shared-disk.sh" "$d/out2.sh" 2>"$d/gen2.err"; then
  printf '  KO    %-32s doveva rifiutare\n' "gen: mount con virgolette"; FALLITI=$((FALLITI+1))
else
  grep -q 'romperebbe la resa' "$d/gen2.err" \
    && { printf '  ok    %-32s rifiutato\n' "gen: mount con virgolette"; PASSATI=$((PASSATI+1)); } \
    || { printf '  KO    %-32s rifiutato per altro motivo\n' "gen: mount con virgolette"; FALLITI=$((FALLITI+1)); }
fi

d="$BASE/g4"; mkdir -p "$d/config"
_genera "$d" "$d/out.sh" >/dev/null 2>&1
sed -i 's|^SHARED_DISK_UUID=.*|SHARED_DISK_UUID="non-uno-uuid"|' "$d/config/shared-disk.env"
if bash "$d/scripts/deploy/genera-installer-shared-disk.sh" "$d/out2.sh" 2>"$d/gen2.err"; then
  printf '  KO    %-32s doveva rifiutare\n' "gen: UUID malformato"; FALLITI=$((FALLITI+1))
else
  printf '  ok    %-32s rifiutato\n' "gen: UUID malformato"; PASSATI=$((PASSATI+1))
fi

# =========================== provenienza del payload =========================
# La minaccia qui non e' un sorgente sbagliato: e' un installer modificato a
# mano dopo la generazione. Percio' si manomette l'installer, non la fonte.
prepara prov1
awk 'BEGIN{n=0} /^__PAYLOAD_INIZIO__$/{p=1} {if(p&&n==3){sub(/^./,(substr($0,1,1)=="B"?"C":"B"))} if(p)n++; print}' \
    "$SB/sotto-prova.sh" > "$SB/x" && mv "$SB/x" "$SB/sotto-prova.sh"
verifica "payload manomesso" SORGENTE_NON_AUTENTICO "$(esegui)" "$INTATTO" "$ENV_INTATTO"

prepara prov2
awk '/^__PAYLOAD_INIZIO__$/{p=1;print;next} /^__PAYLOAD_FINE__$/{p=0} !p{print}' \
    "$SB/sotto-prova.sh" > "$SB/x" && mv "$SB/x" "$SB/sotto-prova.sh"
verifica "payload assente" SORGENTE_NON_AUTENTICO "$(esegui)" "$INTATTO"

prepara prov3
{ printf '#!/bin/bash\nMOUNT_PATH="%s"\n_uuid_valido(){ :; }\nSHARED_DISK_UUID=""\nSHARED_DISK_REQUIRED=true\necho AI_RIG_SHARED_DISK=PASS\n' "$MOUNT_OK" \
    | base64 -w 76 > "$SB/finto.b64"; }
awk -v f="$SB/finto.b64" '/^__PAYLOAD_INIZIO__$/{print;while((getline l<f)>0)print l;p=1;next} /^__PAYLOAD_FINE__$/{p=0} !p{print}' \
    "$SB/sotto-prova.sh" > "$SB/x" && mv "$SB/x" "$SB/sotto-prova.sh"
verifica "sorgente non committato" SORGENTE_NON_AUTENTICO "$(esegui)" "$INTATTO" "$ENV_INTATTO"

# ===================== controlli sul sorgente reso ===========================
# Qui il payload e' autentico rispetto al proprio generatore: si arriva davvero
# ai controlli a valle.
I="$BASE/i-ph.sh";  _genera "$BASE/gph" "$I" -e '3i\# __PLACEHOLDER_DIMENTICATO__'
prepara ph "$I";    verifica "placeholder residui" PLACEHOLDER_RESIDUI "$(esegui)" "$INTATTO"

I="$BASE/i-mk.sh";  _genera "$BASE/gmk" "$I" -e 's/AI_RIG_SHARED_DISK=/AI_RIG_ALTRO=/g'
prepara mk "$I";    verifica "marker assente nel reso" SORGENTE_INATTESO "$(esegui)" "$INTATTO"

I="$BASE/i-mo.sh";  _genera "$BASE/gmo" "$I" -e '21i\MOUNT_PATH="/mnt/qualcosaltro"'
prepara mo "$I";    verifica "punto di mount discorde" MOUNT_DISCORDE "$(esegui)" "$INTATTO"

# ========================= controlli sullo stato del rig =====================
prepara nomount; : > "$SB/fake/uuid_montato"; : > "$SB/fake/source_mnt"
verifica "disco non montato" DISCO_NON_MONTATO "$(esegui)" "$INTATTO" "$ENV_INTATTO"

prepara nonmp; echo 1 > "$SB/fake/is_mountpoint"
verifica "non e' un mountpoint" MOUNT_NON_E_MOUNTPOINT "$(esegui)" "$INTATTO"

prepara uuidko; echo "$UUID_NO" > "$SB/fake/uuid_montato"
verifica "UUID discordi" UUID_DISCORDI "$(esegui)" "$INTATTO" "$ENV_INTATTO"

prepara envuuid; printf 'SHARED_DISK_UUID="%s"\n' "$UUID_NO" >> "$SB/opt/shared-disk.env"
verifica "env con UUID diverso comanda" UUID_DISCORDI "$(esegui)" "$INTATTO"

prepara noenv; rm -f "$SB/opt/shared-disk.env"
verifica "env assente" ENV_ASSENTE "$(esegui)" "$INTATTO"

prepara nodest; rm -f "$SB/usr/50-shared-disk.sh"
verifica "destinazione assente" DEST_ASSENTE "$(esegui)" '[ ! -e "$SB/usr/50-shared-disk.sh" ]'

prepara arg
verifica "argomento ignoto" ARGOMENTO_IGNOTO "$(esegui --forza)" "$INTATTO"

prepara stdin
verifica "passato su stdin" NON_E_UN_FILE \
  "$(PATH="$SB/bin:$PATH" bash -s < "$SB/sotto-prova.sh" 2>&1)" "$INTATTO" "$ENV_INTATTO"

# ================================ dry-run ====================================
prepara dry
verifica "dry-run non installa" DRY_RUN_OK "$(esegui --dry-run)" "$INTATTO" "$ENV_INTATTO" "$SENZA_BACKUP"

if [ "$SENZA_PRIVILEGI" -eq 1 ]; then
    prepara nonroot
    verifica "dry-run senza root" DRY_RUN_OK "$(esegui_nessuno --dry-run)" "$INTATTO" "$SENZA_BACKUP"
    prepara nonroot2
    verifica "installazione senza root" SERVE_ROOT "$(esegui_nessuno)" "$INTATTO" "$ENV_INTATTO"
    prepara envchiuso; chmod 0600 "$SB/opt/shared-disk.env"
    verifica "env non leggibile" ENV_NON_LEGGIBILE "$(esegui_nessuno --dry-run)" "$INTATTO"
    prepara destchiuso; chmod 0700 "$SB/usr/50-shared-disk.sh"
    verifica "sonda non leggibile" DEST_NON_LEGGIBILE "$(esegui_nessuno --dry-run)" "$INTATTO"
else
    for n in "dry-run senza root" "installazione senza root" "env non leggibile" "sonda non leggibile"; do
        salta "$n" "serve setpriv + root + utente nobody"
    done
fi

# =========================== ripristino dopo l'installazione =================
prepara fail
echo 'AI_RIG_SHARED_DISK=FAIL reason=not-found' > "$SB/fake/log_append"
echo 1 > "$SB/fake/restart_rc"; echo failed > "$SB/fake/is_active"; echo exit-code > "$SB/fake/result"
verifica "sonda FAIL -> ripristino" RIPRISTINATO "$(esegui)" "$INTATTO" "$ENV_INTATTO" \
  '[ "$(stat -c %a "$SB/usr/50-shared-disk.sh")" = 755 ]' \
  '[ "$(stat -c %a "$SB/opt/shared-disk.env")" = 644 ]'

prepara muta; : > "$SB/fake/log_append"
verifica "unit muta -> ripristino" RIPRISTINATO "$(esegui)" "$INTATTO" "$ENV_INTATTO"

prepara skip; echo 'AI_RIG_SHARED_DISK=SKIP reason=not-found' > "$SB/fake/log_append"
verifica "SKIP non basta" RIPRISTINATO "$(esegui)" "$INTATTO" "$ENV_INTATTO"

prepara vecchio; : > "$SB/fake/log_append"
printf 'AI_RIG_SHARED_DISK=PASS di ieri\n' >> "$SB/var/log/shareddisk.log"
verifica "PASS vecchio non conta" RIPRISTINATO "$(esegui)" "$INTATTO"

prepara result; echo timeout > "$SB/fake/result"
verifica "Result!=success" RIPRISTINATO "$(esegui)" "$INTATTO"

prepara mountperso
cat > "$SB/bin/systemctl" <<EOF
#!/bin/bash
case "\$1" in
  restart)   cat "$SB/fake/log_append" >> "$SB/var/log/shareddisk.log"; echo 1 > "$SB/fake/is_mountpoint"; exit 0 ;;
  is-active) cat "$SB/fake/is_active" ;;
  show)      case "\$*" in *Result*) cat "$SB/fake/result" ;; *ExecMainStatus*) cat "$SB/fake/exec_status" ;; esac ;;
esac
exit 0
EOF
chmod +x "$SB/bin/systemctl"
verifica "PASS ma mount perso" RIPRISTINATO "$(esegui)" "$INTATTO"

prepara fstab; : > "$SB/etc/fstab"
cat > "$SB/bin/systemctl" <<EOF
#!/bin/bash
case "\$1" in
  restart)   if [ ! -e "$SB/fake/partita" ]; then
               touch "$SB/fake/partita"
               echo "UUID=$UUID_OK $MOUNT_OK ext4 defaults,nofail 0 2" >> "$SB/etc/fstab"
               cat "$SB/fake/log_append" >> "$SB/var/log/shareddisk.log"
             fi
             exit 1 ;;
  is-active) echo failed ;;
  show)      case "\$*" in *Result*) echo exit-code ;; *ExecMainStatus*) echo 1 ;; esac ;;
esac
exit 0
EOF
chmod +x "$SB/bin/systemctl"
echo 'AI_RIG_SHARED_DISK=FAIL reason=mount-failed' > "$SB/fake/log_append"
verifica "fstab rimesso com'era" RIPRISTINATO "$(esegui)" '[ ! -s "$SB/etc/fstab" ]' "$INTATTO"

# ============================ l'unica strada buona ===========================
prepara buona
verifica "installa davvero" 707_INSTALLATO "$(esegui)" \
  'grep -q "SHARED_DISK_UUID=\"$UUID_OK\"" "$SB/opt/shared-disk.env"' \
  'grep -q "^SHARED_DISK_REQUIRED=true" "$SB/opt/shared-disk.env"' \
  'grep -q "AI_RIG_SHARED_DISK=" "$SB/usr/50-shared-disk.sh"' \
  'grep -q "MOUNT_PATH=\"$MOUNT_OK\"" "$SB/usr/50-shared-disk.sh"' \
  '! grep -q "vecchia sonda" "$SB/usr/50-shared-disk.sh"' \
  '! grep -q "__SHARED" "$SB/usr/50-shared-disk.sh"' \
  '[ "$(stat -c %a "$SB/usr/50-shared-disk.sh")" = 755 ]' \
  '[ "$(stat -c %a "$SB/opt/shared-disk.env")" = 644 ]' \
  'ls -d "$SB"/var/lib/backup/shared-disk-707-* >/dev/null'

prepara due
esegui >/dev/null
verifica "seconda esecuzione, idempotente" 707_INSTALLATO "$(esegui)" \
  '[ "$(grep -c "^SHARED_DISK_UUID=" "$SB/opt/shared-disk.env")" = 1 ]' \
  '[ "$(grep -c "^SHARED_DISK_REQUIRED=" "$SB/opt/shared-disk.env")" = 1 ]'

prepara pulizia
verifica "niente temporanei residui" 707_INSTALLATO "$(esegui)" \
  '[ -z "$(ls -A "$SB/tmpdir")" ]'

echo "  --------------------------------------------------------------------------"
echo "  $PASSATI passati, $FALLITI falliti, $SALTATI saltati"
echo
[ $FALLITI -eq 0 ] || exit 1
echo "  AI_RIG_707_INSTALLER_TESTS=PASS scenari=$PASSATI saltati=$SALTATI installazioni=3"
