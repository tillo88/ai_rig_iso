#!/usr/bin/env bash
# Emergency helper for HERMES/TEACHER (or DEVIN): install NCCL, resume the
# CUDA/BeeLlama stage, wait for success, then reboot.
set -Eeuo pipefail

[ "$(id -u)" -eq 0 ] || { echo "ERRORE: eseguire come root (sudo)." >&2; exit 1; }

NO_REBOOT=0
TIMEOUT_SECONDS=1800
while [ $# -gt 0 ]; do
    case "$1" in
        --no-reboot) NO_REBOOT=1; shift ;;
        --timeout)
            [ $# -ge 2 ] || { echo "ERRORE: --timeout richiede secondi." >&2; exit 2; }
            TIMEOUT_SECONDS="$2"; shift 2 ;;
        --help|-h)
            echo "Uso: sudo install-nccl-and-resume.sh [--no-reboot] [--timeout 1800]"
            exit 0 ;;
        *) echo "ERRORE: argomento sconosciuto: $1" >&2; exit 2 ;;
    esac
done

exec 9>/run/ai-rig-nccl-resume.lock
flock -n 9 || { echo "ERRORE: un'altra correzione NCCL e' gia' in esecuzione." >&2; exit 1; }

LOG=/var/log/ai-rig-nccl-resume.log
exec > >(tee -a "$LOG") 2>&1

echo "=== NCCL rescue $(date -Iseconds) ==="

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_INSTALLER=""
for candidate in \
    "$SELF_DIR/install-nccl-runtime.sh" \
    /opt/cache/scripts/install-nccl-runtime.sh \
    /usr/local/bin/install-nccl-runtime.sh
 do
    if [ -x "$candidate" ]; then
        RUNTIME_INSTALLER="$candidate"
        break
    fi
 done
[ -n "$RUNTIME_INSTALLER" ] || {
    echo "ERRORE: install-nccl-runtime.sh non trovato." >&2
    exit 1
}

"$RUNTIME_INSTALLER" --cuda 12.8

SERVER=/opt/llama.cpp/build/bin/llama-server
if [ -x "$SERVER" ]; then
    missing="$(ldd "$SERVER" 2>/dev/null | awk '/not found/{print $1}' | xargs || true)"
    [ -z "$missing" ] || { echo "ERRORE: librerie ancora mancanti: $missing" >&2; exit 1; }
fi

UNIT=ai-rig-stage-cuda-llama.service
systemctl cat "$UNIT" >/dev/null 2>&1 || { echo "ERRORE: unit assente: $UNIT" >&2; exit 1; }
systemctl reset-failed "$UNIT" || true
systemctl start --no-block "$UNIT"

echo "Attendo il completamento di $UNIT (timeout ${TIMEOUT_SECONDS}s)..."
start_epoch="$(date +%s)"
while [ ! -f /var/lib/ai-rig/stage-cuda-llama-done ]; do
    if systemctl is-failed --quiet "$UNIT"; then
        echo "ERRORE: lo stage CUDA/BeeLlama e' fallito di nuovo." >&2
        systemctl status "$UNIT" --no-pager -l || true
        tail -n 120 /var/log/ai-rig-stage-cuda-llama.log 2>/dev/null || true
        exit 1
    fi
    now="$(date +%s)"
    if [ $((now - start_epoch)) -ge "$TIMEOUT_SECONDS" ]; then
        echo "ERRORE: timeout in attesa di stage-cuda-llama-done." >&2
        systemctl status "$UNIT" --no-pager -l || true
        exit 1
    fi
    sleep 5
done

echo "Stage CUDA/BeeLlama completato."
if [ "$NO_REBOOT" -eq 1 ]; then
    echo "Nessun riavvio richiesto (--no-reboot)."
    exit 0
fi

echo "Riavvio tra 5 secondi..."
sync
sleep 5
systemctl reboot
