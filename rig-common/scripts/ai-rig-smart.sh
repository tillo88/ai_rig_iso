#!/bin/bash
# =============================================================================
# ai-rig-smart.sh — smartctl "che funziona sempre" per il 4° disco condiviso
# (NVMe Saichi in enclosure USB con bridge Realtek RTL9220, 0bda:9220).
#
# Perche' esiste: il drivedb di Ubuntu 24.04 e' troppo vecchio per riconoscere
# automaticamente il bridge 0x9220, quindi il semplice `smartctl -i /dev/sdX`
# (o --scan-open) puo' non mostrare il disco. Il tipo giusto e' -d sntrealtek
# (supportato da smartctl >= 7.3). Questo wrapper:
#   1. trova il device del disco condiviso per SERIALE (mai /dev/sdX a mano);
#   2. prova prima -d auto (funziona se 55-smart-drivedb.sh ha aggiornato il db);
#   3. se l'auto non legge il disco, ripiega su -d sntrealtek.
#
# Uso:
#   ai-rig-smart.sh              # identita' + salute (-i -H)
#   ai-rig-smart.sh -x           # report esteso completo
#   ai-rig-smart.sh -a           # attributi SMART
#   ai-rig-smart.sh <argomenti smartctl qualsiasi>
#   ai-rig-smart.sh --device /dev/sdX [args]   # forza un device diverso
# =============================================================================
set -euo pipefail

SERIAL="2210VC0S036H0163"
# Override post-install senza rifare la ISO (stesso pattern di 50-shared-disk.sh)
[ -f /opt/cache/config/shared-disk.env ] && . /opt/cache/config/shared-disk.env 2>/dev/null && SERIAL="${SHARED_DISK_SERIAL:-$SERIAL}"

DEV=""
if [ "${1:-}" = "--device" ]; then
    DEV="${2:?--device richiede un path}"; shift 2
fi

if [ -z "$DEV" ]; then
    # Dietro il bridge Realtek lsblk non espone il serial interno: trovo il disco
    # interrogando ogni device con smartctl (-d auto, poi -d sntrealtek).
    _sser() { smartctl -i -d "$2" "$1" 2>/dev/null | awk -F: '/^Serial Number:/{gsub(/^[ \t]+|[ \t]+$/,"",$2);print $2;exit}'; }
    while read -r cand; do
        for t in auto sntrealtek; do
            s=$(_sser "$cand" "$t" || true)
            [ "$s" = "$SERIAL" ] && { DEV="$cand"; break 2; }
            [ -n "$s" ] && break
        done
    done < <(lsblk -dnpo NAME,TYPE | awk '$2=="disk"{print $1}')
    if [ -z "$DEV" ]; then
        echo "!!! Nessun disco col serial interno $SERIAL (smartctl -d auto/sntrealtek). Enclosure spenta/staccata?" >&2
        echo "    Specifica a mano: $0 --device /dev/sdX [args]" >&2
        exit 1
    fi
fi

ARGS=("$@")
[ ${#ARGS[@]} -eq 0 ] && ARGS=(-i -H)

# 1° tentativo: autodetect (drivedb aggiornato). "Serial Number" nell'output di
# -i e' il segnale che il bridge e' stato interrogato davvero.
if out=$(smartctl -i -d auto "$DEV" 2>/dev/null) && echo "$out" | grep -q "Serial Number"; then
    exec smartctl -d auto "${ARGS[@]}" "$DEV"
fi

# 2° tentativo: tipo esplicito per bridge Realtek USB->NVMe
echo "(autodetect fallito: uso -d sntrealtek — normale con drivedb non aggiornato)" >&2
exec smartctl -d sntrealtek "${ARGS[@]}" "$DEV"
