#!/usr/bin/env bash
# =============================================================================
# sync-cache-to-disk.sh — copia la cache del progetto sul DISCO-CACHE 4TB.
# Gira sulla BUILD MACHINE (WSL). Una volta (poi rsync aggiorna solo i diff).
#
# Preparazione del 4TB PRIMA (una tantum, DISTRUTTIVO — cancella la USB/ISO
# che c'era scritta raw): formatta ext4 con etichetta 'ai-rig-cache':
#   sudo mkfs.ext4 -L ai-rig-cache /dev/sdX1        # <-- il disco GIUSTO!
# poi montalo e passa il mount qui sotto.
#
# Uso:
#   bash scripts/sync-cache-to-disk.sh /mnt/disco4tb
#   -> crea /mnt/disco4tb/cache e ci rsynca cache/ del progetto
# =============================================================================
set -Eeuo pipefail
cd "$(dirname "$0")/.."
DEST_MNT="${1:?Uso: $0 <mount-point-del-4TB> (es. /mnt/disco4tb)}"

[ -d "$DEST_MNT" ] || { echo "!!! $DEST_MNT non esiste / non montato." >&2; exit 1; }
[ -d "cache" ] || { echo "!!! cartella cache/ non trovata nel progetto." >&2; exit 1; }

# Avviso se l'etichetta non e' quella che populate-cache cerca.
lbl="$(lsblk -no LABEL "$(findmnt -no SOURCE "$DEST_MNT" 2>/dev/null)" 2>/dev/null || true)"
if [ "$lbl" != "ai-rig-cache" ]; then
    echo "NB: etichetta del disco = '${lbl:-nessuna}'. populate-cache.sh cerca 'ai-rig-cache'."
    echo "    (puoi comunque passare il path a mano a populate-cache; o rietichetta: sudo e2label /dev/sdX1 ai-rig-cache)"
fi

echo "== Rsync cache/ -> ${DEST_MNT}/cache (puo' volerci parecchio, ~110GB) =="
mkdir -p "${DEST_MNT}/cache"
rsync -a --info=progress2 cache/ "${DEST_MNT}/cache/"
echo "== Fatto. Contenuto: =="
du -sh "${DEST_MNT}/cache"/* 2>/dev/null || true
echo "Ora collega il 4TB al rig e su ogni ruolo: sudo populate-cache.sh"
