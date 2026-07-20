#!/usr/bin/env bash
# =============================================================================
# Power limit permanente per la GTX 1080 instabile (2026-07-16).
# Sul campo, con gpu-burn UNA delle due 1080 (UUID sotto) dava errori a 210W;
# a 180W tutti i gpu-burn successivi — incluso quello da 2 ore — sono OK.
# Serve su TUTTI e 3 i ruoli (la scheda e' fisica, presente ad ogni boot).
# Idempotente e difensivo: aspetta fino a 2 minuti che driver+GPU siano su.
# =============================================================================
set -Eeuo pipefail
GPU_UUID="GPU-86d20dd9-9119-d542-4ab0-d48bc3c0c8cf"
NVIDIA_SMI="/usr/bin/nvidia-smi"
POWER_LIMIT="180"

for attempt in {1..60}; do
    if "$NVIDIA_SMI" -L 2>/dev/null | grep -Fq "$GPU_UUID"; then
        "$NVIDIA_SMI" -i "$GPU_UUID" -pm 1
        "$NVIDIA_SMI" -i "$GPU_UUID" -pl "$POWER_LIMIT"
        current="$(
            "$NVIDIA_SMI" -i "$GPU_UUID" \
                --query-gpu=power.limit \
                --format=csv,noheader,nounits
        )"
        logger -t gtx1080-powerlimit \
            "Power limit applicato a $GPU_UUID: ${current} W"
        exit 0
    fi
    sleep 2
done
logger -t gtx1080-powerlimit \
    "ERRORE: GPU $GPU_UUID non trovata dopo 120 secondi"
exit 1
