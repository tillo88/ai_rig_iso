#!/usr/bin/env bash
# =============================================================================
# swap-model.sh — cambia il modello GGUF del ruolo ATTIVO, a caldo.
#
# Perche' (2026-07-16): il modello e' parametrizzato (ROLE_MODEL_PATH in
# /etc/ai-rig/<ruolo>.env). Aggiornarlo — stesso modello ri-uppato o uno
# migliore — deve essere UN comando: piazza il GGUF, aggiorna l'env, riavvia
# llama-server. Memoria/harness/correzioni NON dipendono dai pesi: restano.
#
# Uso (SUL RIG, sul ruolo che vuoi aggiornare — un ruolo alla volta):
#   sudo swap-model.sh <GGUF: url o path locale> [--mmproj <url|path>]
#   es: sudo swap-model.sh https://huggingface.co/.../Ornith-....gguf
#   es: sudo swap-model.sh /mnt/usb/Ornith-nuovo.gguf
#
# NB: aggiorna solo il RUNTIME del rig. Per renderlo permanente anche alle
# future re-installazioni, aggiorna ROLE_MODEL_FILE in config/roles/<ruolo>.env
# sulla build machine (e metti il GGUF in cache/models/<ruolo>/).
# =============================================================================
set -Eeuo pipefail

[ "$(id -u)" -eq 0 ] || { echo "!!! Serve root (sudo)." >&2; exit 1; }
SRC="${1:-}"
MMPROJ_SRC=""
[ "${2:-}" = "--mmproj" ] && MMPROJ_SRC="${3:-}"
[ -n "$SRC" ] || { echo "Uso: sudo $0 <gguf url|path> [--mmproj <url|path>]" >&2; exit 2; }

ROLE="$(cat /etc/ai-rig/role 2>/dev/null || echo unknown)"
ENV_FILE="/etc/ai-rig/${ROLE}.env"
[ -f "$ENV_FILE" ] || { echo "!!! $ENV_FILE assente: ruolo non provisionato?" >&2; exit 3; }
DST_DIR="/opt/models/${ROLE}"
CACHE_DIR="/opt/cache/models/${ROLE}"
mkdir -p "$DST_DIR" "$CACHE_DIR"

fetch() {  # <src> <dest>  — url via wget -c (riprende), path via cp
    local src="$1" dst="$2"
    case "$src" in
        http://*|https://*) echo "Scarico $(basename "$dst")..."; wget -c -O "$dst" "$src" ;;
        *) [ -f "$src" ] || { echo "!!! sorgente non trovata: $src" >&2; return 1; }
           echo "Copio $(basename "$dst")..."; cp -f "$src" "$dst" ;;
    esac
}

MODEL_NAME="$(basename "${SRC%%\?*}")"   # togli eventuale ?download=true
DST="${DST_DIR}/${MODEL_NAME}"
fetch "$SRC" "$DST"
# sanity: un GGUF vero e' > 100MB
[ "$(stat -c%s "$DST" 2>/dev/null || echo 0)" -gt 104857600 ] || \
    { echo "!!! $DST troppo piccolo: download/copia fallita?" >&2; exit 4; }
cp -f "$DST" "${CACHE_DIR}/${MODEL_NAME}"   # tieni anche in cache per re-provision

MMPROJ_LINE=""
if [ -n "$MMPROJ_SRC" ]; then
    MM_NAME="$(basename "${MMPROJ_SRC%%\?*}")"
    fetch "$MMPROJ_SRC" "${DST_DIR}/${MM_NAME}"
    cp -f "${DST_DIR}/${MM_NAME}" "${CACHE_DIR}/${MM_NAME}"
    MMPROJ_LINE="${DST_DIR}/${MM_NAME}"
fi

# Aggiorna l'env (backup .bak, poi sed sui due path)
cp -a "$ENV_FILE" "${ENV_FILE}.bak"
sed -i "s|^ROLE_MODEL_PATH=.*|ROLE_MODEL_PATH=${DST}|" "$ENV_FILE"
[ -n "$MMPROJ_LINE" ] && sed -i "s|^ROLE_MMPROJ_PATH=.*|ROLE_MMPROJ_PATH=${MMPROJ_LINE}|" "$ENV_FILE"

echo "== Riavvio llama-server@${ROLE} col nuovo modello =="
systemctl restart "llama-server@${ROLE}.service"
sleep 3
if systemctl is-active --quiet "llama-server@${ROLE}.service"; then
    echo "✅ ${ROLE}: modello ora = ${MODEL_NAME}"
    echo "   (ricorda: aggiorna anche config/roles/${ROLE}.env sulla build machine per le re-install)"
else
    echo "❌ llama-server non attivo — rollback env, controlla: journalctl -u llama-server@${ROLE} -n 50" >&2
    mv -f "${ENV_FILE}.bak" "$ENV_FILE"
    systemctl restart "llama-server@${ROLE}.service" || true
    exit 5
fi
