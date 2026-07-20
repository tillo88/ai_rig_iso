#!/usr/bin/env bash
# Detects the ai-rig-cache disk, mounts it read-write if necessary, and prepares
# cache/packages + cache/scripts for HERMES and TEACHER.
set -Eeuo pipefail
[ "$(id -u)" -eq 0 ] || { echo "ERRORE: eseguire con sudo." >&2; exit 1; }

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEV="$(blkid -L ai-rig-cache 2>/dev/null || true)"
[ -n "$DEV" ] || { echo "ERRORE: disco ai-rig-cache non trovato." >&2; exit 1; }

EXISTING="$(findmnt -rn -S "$DEV" -o TARGET | head -n1 || true)"
MNT="${EXISTING:-/mnt/ai-rig-cache-nccl}"
MOUNTED_HERE=0
cleanup() {
    if [ "$MOUNTED_HERE" -eq 1 ]; then
        umount "$MNT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

if [ -z "$EXISTING" ]; then
    mkdir -p "$MNT"
    mount "$DEV" "$MNT"
    MOUNTED_HERE=1
else
    OPTIONS="$(findmnt -rn -S "$DEV" -o OPTIONS | head -n1 || true)"
    case ",$OPTIONS," in
        *,ro,*) mount -o remount,rw "$DEV" "$MNT" ;;
    esac
fi

CACHE_PATH="$MNT/cache"
mkdir -p "$CACHE_PATH"
"$SELF_DIR/scripts/prepare-nccl-cache.sh" "$CACHE_PATH"
sync

echo "OK: 4TB pronto per NCCL: $CACHE_PATH"
