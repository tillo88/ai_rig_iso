#!/bin/bash
# =============================================================================
#  #707 - la sonda del disco condiviso, portata sul rig.
#
#  IL DIFETTO, misurato: 26 avvii su 26 hanno stampato "Salto" nel log e la
#  unit ha detto "Finished" tutte e 26 le volte. Non ha mai funzionato.
#  Tre difetti sovrapposti:
#    1. la sonda cerca il disco per un seriale che non esiste piu';
#    2. tre uscite 0 silenziose + 'exec >>' che porta via l'output dal
#       journal: systemctl dice "Finished" qualunque cosa succeda;
#    3. l'override documentato in /opt/cache/config/shared-disk.env e' INERTE
#       (definisce SHARED_DISK_SERIAL, la sonda legge SERIAL).
#
#  LA CORREZIONE esiste gia' in ai_rig_iso, commit @@COMMIT@@, con 8 scenari di
#  test che passano. Questo script la porta sul rig, che gira ancora la
#  versione di luglio.
#
#  PROVENIENZA, verificabile qui dentro senza rete e senza git:
#    rig-common-scripts/50-shared-disk.sh @ @@COMMIT@@ (main)
#    git blob sha1  5a5a089021dc0ee13a9a2aa0557baa47625db6b6
#    sha256         b2799533b88d3b5fcf010f7f42ed6497eb73499a59134d44fdaf4750fe6947a9
#  Il sorgente e' incorporato qui sotto in base64 e viene confrontato con
#  questi due valori PRIMA di essere reso. Non si installa niente preso da
#  /tmp, che e' scrivibile da chiunque.
#
#  FAIL-CLOSED in ogni punto: verifica l'origine, verifica che lo UUID
#  dichiarato sia quello del filesystem davvero montato, installa, riavvia la
#  unit, RILEGGE il log, e se non compare AI_RIG_SHARED_DISK=PASS rimette
#  indietro script, env e fstab e lo dice.
#
#  Uso:  sudo bash /tmp/@@NOME@@ --dry-run     (prima)
#        sudo bash /tmp/@@NOME@@               (poi)
# =============================================================================

set -uo pipefail

# --- percorsi (blocco unico: e' anche il punto in cui il banco di prova li
# --- riscrive verso una sandbox, cosi' si prova questo script e non un altro)
DEST=/usr/local/bin/50-shared-disk.sh
ENV=/opt/cache/config/shared-disk.env
LOG=/var/log/ai-rig-stage-shareddisk.log
FSTAB=/etc/fstab
UNIT=ai-rig-stage-shareddisk.service
MOUNT=@@MOUNT@@
UUID_ATTESO=@@UUID@@
SERIAL_RESO=@@SERIAL@@
RADICE_BACKUP=/var/lib/ai-rig/control-plane-backup
BLOB_ATTESO=@@BLOB@@
SHA256_ATTESO=@@SHA256@@

DRY=0
case "${1:-}" in
  "")         DRY=0 ;;
  --dry-run)  DRY=1 ;;
  *)          echo "Argomento non riconosciuto: '$1'"; echo "Uso: sudo bash $0 [--dry-run]";
              echo; echo "ESITO=ARGOMENTO_IGNOTO"; exit 1 ;;
esac

# Il dry-run non scrive niente: legge due file, interroga findmnt e si ferma.
# Percio' non pretende root. L'esecuzione vera si'.
IO=$(id -un 2>/dev/null || echo "?")
if [ "$DRY" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
  echo "L'installazione vera scrive in /usr/local/bin e /opt/cache: serve root."
  echo "    sudo bash $0"
  echo "La prova a vuoto invece gira anche cosi':"
  echo "    bash $0 --dry-run"
  echo; echo "ESITO=SERVE_ROOT"; exit 1
fi

# Questo script legge il proprio sorgente incorporato da "$0": deve essere
# eseguito come FILE. Passato su stdin (bash -s, o una pipe) $0 non e' il file
# e il payload non si troverebbe: meglio dirlo chiaro che fallire di sbieco.
if [ ! -f "$0" ] || [ ! -r "$0" ]; then
  echo "Va eseguito come file, non passato su stdin:"
  echo "    sudo bash /tmp/@@NOME@@ --dry-run"
  echo
  echo "ESITO=NON_E_UN_FILE"
  exit 1
fi

STAMPA=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP="${RADICE_BACKUP}/shared-disk-707-${STAMPA}"
SORGENTE=""

fermo() {  # $1 = codice esito, $2.. = spiegazione
  local codice="$1"; shift
  echo "    FERMO: $*"
  [ -n "$SORGENTE" ] && rm -f "$SORGENTE"
  echo
  echo "ESITO=$codice"
  exit 1
}

echo "================================================================"
echo "  #707 - sonda del disco condiviso per UUID, fail-closed"
[ "$DRY" -eq 1 ] && echo "  MODALITA' DRY-RUN (sola lettura, utente $IO): controllo tutto e non installo niente"
echo "================================================================"

# ---------------------------------------------- 1. origine del sorgente
echo
echo "  --- da dove viene il sorgente ---"

prepara_sorgente() {
  SORGENTE=$(mktemp) || { echo "mktemp fallito"; return 1; }
  chmod 0600 "$SORGENTE"
  local grezzo; grezzo=$(mktemp); chmod 0600 "$grezzo"
  sed -n '/^__PAYLOAD_INIZIO__$/,/^__PAYLOAD_FINE__$/p' "$0" \
    | sed -e '1d' -e '$d' | base64 -d > "$grezzo" 2>/dev/null
  if [ ! -s "$grezzo" ]; then
    rm -f "$grezzo"; echo "    il blocco base64 incorporato non si decodifica"; return 1
  fi
  local blob sha256
  blob=$( { printf 'blob %d\0' "$(stat -c%s "$grezzo")"; cat "$grezzo"; } | sha1sum | cut -d' ' -f1)
  sha256=$(sha256sum "$grezzo" | cut -d' ' -f1)
  echo "    git blob sha1 del sorgente incorporato: $blob"
  echo "    atteso (ai_rig_iso @@COMMIT@@):           $BLOB_ATTESO"
  if [ "$blob" != "$BLOB_ATTESO" ] || [ "$sha256" != "$SHA256_ATTESO" ]; then
    rm -f "$grezzo"; echo "    non coincide con il commit dichiarato"; return 1
  fi
  echo "    coincide: e' il file committato, non una copia passata di mano"
  sed -e "s|__SHARED_DISK_SERIAL__|${SERIAL_RESO}|" \
      -e "s|__SHARED_MOUNT_PATH__|${MOUNT}|" "$grezzo" > "$SORGENTE"
  rm -f "$grezzo"
  return 0
}

prepara_sorgente || fermo SORGENTE_NON_AUTENTICO "non posso fidarmi del sorgente incorporato"

# ---------------------------------------------- 2. il reso e' quello giusto
echo
echo "  --- controlli sul sorgente reso ---"

bash -n "$SORGENTE" 2>&1 | sed 's/^/      /'
[ "${PIPESTATUS[0]}" -eq 0 ] || fermo SORGENTE_NON_VALIDO "il sorgente reso non ha sintassi valida"

RIMASTI=$(grep -c '__[A-Z_]*__' "$SORGENTE")
echo "    placeholder rimasti dopo la resa: $RIMASTI"
[ "$RIMASTI" -eq 0 ] || fermo PLACEHOLDER_RESIDUI "ci sono ancora $RIMASTI placeholder non sostituiti"

for atteso in 'AI_RIG_SHARED_DISK=' 'SHARED_DISK_UUID' 'SHARED_DISK_REQUIRED' '_uuid_valido'; do
  grep -q "$atteso" "$SORGENTE" || fermo SORGENTE_INATTESO "il sorgente non contiene $atteso"
done
echo "    marker e variabili attese: presenti"

MOUNT_RESO=$(sed -n 's/^MOUNT_PATH="\(.*\)"$/\1/p' "$SORGENTE" | head -n1)
echo "    punto di mount reso: ${MOUNT_RESO:-(non trovato)}"
[ -n "$MOUNT_RESO" ] || fermo MOUNT_NON_LEGGIBILE "non riesco a leggere MOUNT_PATH dal sorgente reso"
[ "$MOUNT_RESO" = "$MOUNT" ] || fermo MOUNT_DISCORDE \
  "il sorgente monta $MOUNT_RESO ma io verifico $MOUNT: verificherei il disco sbagliato"

# ---------------------------------------------- 3. lo stato del rig
echo
echo "  --- controlli sul rig, prima di toccare qualcosa ---"

# Un file che c'e' ma non si legge non e' un file che manca: dirlo uguale
# manderebbe a cercare la cosa sbagliata.
[ -e "$DEST" ] || fermo DEST_ASSENTE "manca $DEST: questo rig non ha la sonda, non e' il caso che indovini"
[ -r "$DEST" ] || fermo DEST_NON_LEGGIBILE "$DEST c'e' ma $IO non puo' leggerlo: rifai la prova con sudo"
[ -e "$ENV" ]  || fermo ENV_ASSENTE "manca $ENV"
[ -r "$ENV" ]  || fermo ENV_NON_LEGGIBILE "$ENV c'e' ma $IO non puo' leggerlo: rifai la prova con sudo"

UUID_IN_ENV=$(sed -n 's/^SHARED_DISK_UUID="\?\([^"]*\)"\?$/\1/p' "$ENV" | head -n1)
if [ -n "$UUID_IN_ENV" ]; then
  echo "    $ENV dichiara gia' SHARED_DISK_UUID=$UUID_IN_ENV: comanda quello"
  UUID_DICHIARATO="$UUID_IN_ENV"
else
  UUID_DICHIARATO="$UUID_ATTESO"
fi

UUID_MONTATO=$(findmnt -no UUID --target "$MOUNT" 2>/dev/null | head -n1)
if [ -z "$UUID_MONTATO" ]; then
  SORGENTE_MNT=$(findmnt -no SOURCE --target "$MOUNT" 2>/dev/null | head -n1)
  [ -n "$SORGENTE_MNT" ] && UUID_MONTATO=$(blkid -s UUID -o value "$SORGENTE_MNT" 2>/dev/null)
fi
echo "    UUID del filesystem montato su $MOUNT: ${UUID_MONTATO:-(nessuno)}"
[ -n "$UUID_MONTATO" ] || fermo DISCO_NON_MONTATO \
  "il disco condiviso non risulta montato: non e' il momento di stringere la sonda"

mountpoint -q "$MOUNT" || fermo MOUNT_NON_E_MOUNTPOINT \
  "$MOUNT non e' un punto di mount a se': findmnt sta rispondendo per il filesystem padre"

echo "    UUID che andrei a dichiarare:          $UUID_DICHIARATO"
if [ "$UUID_MONTATO" != "$UUID_DICHIARATO" ]; then
  echo "    FERMO: non coincidono. Installare adesso farebbe fallire la sonda per"
  echo "    uuid-mismatch: corretto, e inutile. Prima va deciso quale dei due e'"
  echo "    il disco giusto."
  rm -f "$SORGENTE"
  echo; echo "ESITO=UUID_DISCORDI"; exit 1
fi
echo "    coincidono"

if grep -q "$UUID_DICHIARATO" "$FSTAB" 2>/dev/null; then
  echo "    $FSTAB contiene gia' questo UUID: la sonda non lo tocchera'"
else
  echo "    $FSTAB NON contiene questo UUID: la sonda aggiungera' una riga nofail"
fi

MODO_DEST=$(stat -c %a "$DEST"); MODO_ENV=$(stat -c %a "$ENV")
echo "    permessi attuali: $DEST $MODO_DEST, $ENV $MODO_ENV"

if [ "$DRY" -eq 1 ]; then
  echo
  echo "  Tutti i controlli passano. In esecuzione vera installerei:"
  echo "    $DEST                                            (permessi invariati: $MODO_DEST)"
  echo "    $ENV  + SHARED_DISK_UUID + SHARED_DISK_REQUIRED  (permessi invariati: $MODO_ENV)"
  echo "    poi riavvio $UNIT e rileggo il log; se non dice PASS rimetto indietro."
  rm -f "$SORGENTE"
  echo
  echo "ESITO=DRY_RUN_OK"
  exit 0
fi

# ---------------------------------------------------------------- backup
echo
echo "  --- backup ---"
mkdir -p "$BACKUP" || fermo BACKUP_FALLITO "non riesco a creare $BACKUP"
chmod 0700 "$BACKUP"
cp -p "$DEST"  "$BACKUP/50-shared-disk.sh.prima" || fermo BACKUP_FALLITO "copia di $DEST fallita"
cp -p "$ENV"   "$BACKUP/shared-disk.env.prima"   || fermo BACKUP_FALLITO "copia di $ENV fallita"
cp -p "$FSTAB" "$BACKUP/fstab.prima"             || fermo BACKUP_FALLITO "copia di $FSTAB fallita"
cp -p "$LOG"   "$BACKUP/log.prima" 2>/dev/null
RIGHE_PRIMA=$(wc -l < "$LOG" 2>/dev/null || echo 0)
echo "    $BACKUP  (script, env, fstab; log a $RIGHE_PRIMA righe)"

# --------------------------------------------------------------- installo
echo
echo "  --- installo ---"
install -m "$MODO_DEST" -o root -g root "$SORGENTE" "$DEST" \
  || fermo INSTALL_FALLITO "install di $DEST fallito"
rm -f "$SORGENTE"; SORGENTE=""
echo "    $DEST  sha256 $(sha256sum "$DEST" | cut -c1-16)"

TMPENV=$(mktemp) || fermo INSTALL_FALLITO "mktemp fallito"
chmod 0600 "$TMPENV"
cp "$ENV" "$TMPENV" || { rm -f "$TMPENV"; fermo INSTALL_FALLITO "copia di lavoro dell'env fallita"; }
grep -q '^SHARED_DISK_UUID=' "$TMPENV" || printf '\n# Identita primaria del disco condiviso: lo UUID sopravvive al cambio di\n# enclosure, il serial no (incidente OP-DEVIN-USB-ASMEDIA-RESET-002).\nSHARED_DISK_UUID="%s"\n' "$UUID_DICHIARATO" >> "$TMPENV"
grep -q '^SHARED_DISK_REQUIRED=' "$TMPENV" || printf '# true: se il disco manca lo stage FALLISCE invece di uscire 0 in silenzio.\nSHARED_DISK_REQUIRED=true\n' >> "$TMPENV"
install -m "$MODO_ENV" -o root -g root "$TMPENV" "$ENV" \
  || { rm -f "$TMPENV"; fermo INSTALL_FALLITO "install di $ENV fallito"; }
rm -f "$TMPENV"
echo "    $ENV"
grep -E '^SHARED_' "$ENV" | sed 's/^/      /'

# ------------------------------------------------------------- verifica
echo
echo "  --- riavvio la unit e rileggo il log (e' il punto di tutto) ---"
systemctl restart "$UNIT"
RC_RESTART=$?
sleep 3
STATO=$(systemctl is-active "$UNIT" 2>&1)
RISULTATO=$(systemctl show -p Result --value "$UNIT" 2>/dev/null)
USCITA=$(systemctl show -p ExecMainStatus --value "$UNIT" 2>/dev/null)
echo "    restart rc=$RC_RESTART   unit: $STATO   Result=$RISULTATO   ExecMainStatus=$USCITA"
echo "    righe nuove nel log:"
tail -n +$((RIGHE_PRIMA + 1)) "$LOG" 2>/dev/null | sed 's/^/      /'

MARKER=$(tail -n +$((RIGHE_PRIMA + 1)) "$LOG" 2>/dev/null | grep -o 'AI_RIG_SHARED_DISK=[A-Z]*' | tail -1)
echo "    marker: ${MARKER:-(nessuno)}"

OK=si
PERCHE=""
[ "$MARKER" = "AI_RIG_SHARED_DISK=PASS" ] || { OK=no; PERCHE="$PERCHE marker=${MARKER:-assente}"; }
[ "$RC_RESTART" -eq 0 ]                   || { OK=no; PERCHE="$PERCHE restart=$RC_RESTART"; }
[ "$RISULTATO" = "success" ]              || { OK=no; PERCHE="$PERCHE Result=${RISULTATO:-ignoto}"; }
case "$STATO" in active|inactive) ;; *) OK=no; PERCHE="$PERCHE stato=$STATO" ;; esac
mountpoint -q "$MOUNT"                    || { OK=no; PERCHE="$PERCHE mount=perso"; }

if [ "$OK" != "si" ]; then
  echo
  echo "  !!! non e' andata come deve:$PERCHE"
  echo "  !!! RIPRISTINO tutto"
  install -m "$MODO_DEST" -o root -g root "$BACKUP/50-shared-disk.sh.prima" "$DEST"
  install -m "$MODO_ENV"  -o root -g root "$BACKUP/shared-disk.env.prima"   "$ENV"
  if ! cmp -s "$BACKUP/fstab.prima" "$FSTAB"; then
    echo "    $FSTAB era stato modificato dalla sonda nuova: lo rimetto com'era"
    cp -p "$BACKUP/fstab.prima" "$FSTAB"
  fi
  systemctl restart "$UNIT" 2>/dev/null
  sleep 2
  echo "    ripristinati. unit: $(systemctl is-active "$UNIT" 2>&1)"
  echo "    $MOUNT montato: $(mountpoint -q "$MOUNT" && echo si || echo NO)"
  echo
  echo "ESITO=RIPRISTINATO niente e' cambiato, backup in $BACKUP"
  exit 1
fi

echo
echo "  Fatto. La sonda ora si identifica per UUID e lo dice nel log."
echo "  Da adesso un disco assente fa FALLIRE la unit invece di farle dire"
echo "  'Finished' mentre lo salta: il difetto #707 non puo' piu' ripetersi in"
echo "  silenzio."
echo "  Backup: $BACKUP"
echo
echo "ESITO=707_INSTALLATO marker=$MARKER"
exit 0

# Sorgente incorporato: rig-common-scripts/50-shared-disk.sh @ @@COMMIT@@ (main).
# Non modificare: i due hash qui sopra lo rifiuterebbero, com'e' giusto.
__PAYLOAD_INIZIO__
@@PAYLOAD@@
__PAYLOAD_FINE__
