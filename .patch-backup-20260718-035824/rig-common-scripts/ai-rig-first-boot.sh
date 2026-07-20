#!/bin/bash
# =============================================================================
# ai-rig-first-boot.sh — autopopulate della catena AUTO.
# Il marker viene creato soltanto da populate-cache.sh dopo copia e abilitazione
# complete. In caso di errore il boot successivo ritenta automaticamente.
# =============================================================================
set -Eeuo pipefail
exec >> /var/log/ai-rig-first-boot.log 2>&1

echo "=== first-boot $(date -Iseconds) ==="
mkdir -p /var/lib/ai-rig

if [ -f /var/lib/ai-rig/populate-cache-done ]; then
    touch /var/lib/ai-rig/first-boot-done
    echo "Cache già popolata."
    exit 0
fi

# Compatibilità con installazioni precedenti: se CUDA/llama o il ruolo sono già
# completati, populate-cache deve necessariamente essere passato con successo.
if [ -f /var/lib/ai-rig/stage-cuda-llama-done ] \
   || [ -f /var/lib/ai-rig/stage-role-done ]; then
    touch /var/lib/ai-rig/populate-cache-done /var/lib/ai-rig/first-boot-done
    echo "Stage pesanti già completate: ricostruiti i marker di populate."
    exit 0
fi

CACHE_READY=0
for _ in $(seq 1 30); do
    if blkid -L ai-rig-cache >/dev/null 2>&1; then
        CACHE_READY=1
        break
    fi
    udevadm settle 2>/dev/null || true
    sleep 1
done
if [ "$CACHE_READY" -ne 1 ]; then
    echo "Cache 'ai-rig-cache' non collegata o non pronta: ritenterò al prossimo boot."
    exit 0
fi

[ -x /usr/local/bin/populate-cache.sh ] || {
    echo "!!! /usr/local/bin/populate-cache.sh assente o non eseguibile" >&2
    exit 1
}

echo "Cache presente: avvio la copia selettiva e l'abilitazione delle stage."
exec /usr/local/bin/populate-cache.sh
