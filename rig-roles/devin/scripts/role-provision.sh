#!/bin/bash
# =============================================================================
# STAGE 4/4 — Provisioning ruolo: devin
# =============================================================================
set -e
exec >> /var/log/ai-rig-stage-role.log 2>&1
echo "=== Stage 4 (ruolo devin) - $(date) ==="

mkdir -p /var/lib/ai-rig /etc/ai-rig /opt/models/devin /opt/ai-rig/kv-sessions
if [ -f /var/lib/ai-rig/stage-role-done ]; then
    echo "Stage ruolo gia' completato, esco."
    exit 0
fi

echo "devin" > /etc/ai-rig/role

# MOVE (non copy): /opt/cache e /opt/models sono sullo STESSO disco -> il mv e'
# istantaneo e NON crea un doppione da ~25-30GB (era la causa del disco pieno).
# Idempotente: se il modello e' gia' in /opt/models non fa nulla.
MODEL_SRC="/opt/cache/models/devin/Ornith-1.0-35B-A3B-MXFP4_MOE_Q8_0_F16-Imatrix.gguf"
MODEL_DST="/opt/models/devin/Ornith-1.0-35B-A3B-MXFP4_MOE_Q8_0_F16-Imatrix.gguf"
if [ -f "$MODEL_DST" ]; then
    echo "Modello gia' presente in $MODEL_DST."
elif [ -f "$MODEL_SRC" ]; then
    mv "$MODEL_SRC" "$MODEL_DST"
else
    echo "!!! Modello non trovato ne' in $MODEL_DST ne' in $MODEL_SRC — copialo in cache/models/devin/ e ricostruisci la ISO." >&2
fi

MMPROJ_DST=""
if [ -n "" ]; then
    MMPROJ_SRC="/opt/cache/models/devin/"
    MMPROJ_DST="/opt/models/devin/"
    if [ -f "$MMPROJ_DST" ]; then
        :   # gia' presente
    elif [ -f "$MMPROJ_SRC" ]; then
        mv "$MMPROJ_SRC" "$MMPROJ_DST"
    else
        echo "!!! mmproj non trovato in $MMPROJ_SRC" >&2
        MMPROJ_DST=""
    fi
fi

cat > "/etc/ai-rig/devin.env" << EOFENV
ROLE_NAME=devin
ROLE_MODEL_PATH=${MODEL_DST}
ROLE_MMPROJ_PATH=${MMPROJ_DST}
ROLE_LLAMA_PORT=8080
ROLE_CTX_SIZE=32768
ROLE_TEMP=0.55
ROLE_TOP_P=0.90
ROLE_REPEAT_PENALTY=1.08
ROLE_EXTRA_ARGS="--top-k 15 --min-p 0.12 --presence-penalty 0.00 --dry-multiplier 0.8 --dry-base 1.75 --dry-allowed-length 3 --dry-penalty-last-n 1024 --samplers top_k;top_p;min_p;temp;dry --no-warmup --slot-save-path /opt/ai-rig/kv-sessions"
# Reasoning / chat template (vuoti = default: reasoning off, jinja off)
ROLE_REASONING_FORMAT=auto
ROLE_REASONING_BUDGET=20480
ROLE_CHAT_TEMPLATE_KWARGS='{"enable_thinking":true}'
ROLE_JINJA=1
# Derivati da LLAMA_FLAVOR (config/rig.env) — riscritti da swap-llama-flavor.sh
LLAMA_FLAVOR=beellama
ROLE_CACHE_TYPE_K=turbo4
ROLE_CACHE_TYPE_V=turbo3_tcq
ROLE_FLASH_ATTN=on
EOFENV

# Python venv dedicato al ruolo (requirements/devin.txt + requirements/common.txt)
if [ -f /opt/cache/requirements/devin.txt ]; then
    python3 -m venv "/opt/venv-devin"
    "/opt/venv-devin/bin/pip" install --upgrade pip -q
    [ -f /opt/cache/requirements/common.txt ] && "/opt/venv-devin/bin/pip" install -q -r /opt/cache/requirements/common.txt
    "/opt/venv-devin/bin/pip" install -q -r /opt/cache/requirements/devin.txt
    chown -R tillo:tillo "/opt/venv-devin"
fi

chmod +x /usr/local/bin/start-llama-devin.sh 2>/dev/null || true
systemctl daemon-reload
systemctl enable "llama-server@devin.service"
systemctl start "llama-server@devin.service" || echo "!!! avvio llama-server fallito, controlla journalctl" >&2

touch /var/lib/ai-rig/stage-role-done
echo "=== Stage 4 completato - $(date) ==="

# Verifica finale (best effort, non blocca il boot se fallisce)
/usr/local/bin/90-verify.sh || true
