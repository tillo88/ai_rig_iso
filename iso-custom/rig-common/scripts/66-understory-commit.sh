#!/bin/bash
# Snapshot Git host-side del bundle. Understory 0.1.0 non include git nella sua
# immagine Docker; inoltre attendiamo un minuto di quiete per non fotografare
# una mutazione multi-file a meta'.
set -euo pipefail
MOUNT_PATH="/mnt/ai-rig-shared"
[ -f /opt/cache/config/shared-disk.env ] && source /opt/cache/config/shared-disk.env
BUNDLE="${MOUNT_PATH}/understory/bundle"

mountpoint -q "$MOUNT_PATH" || exit 0
[ -d "$BUNDLE/.git" ] || exit 0

if find "$BUNDLE" -path "$BUNDLE/.git" -prune -o -type f -mmin -1 -print -quit | grep -q .; then
    echo "Bundle modificato da meno di un minuto: rimando il commit."
    exit 0
fi

exec 9>"${MOUNT_PATH}/understory/runtime/git-commit.lock"
flock -n 9 || exit 0
git -C "$BUNDLE" add -A
if ! git -C "$BUNDLE" diff --cached --quiet; then
    ROLE=$(cat /etc/ai-rig/role 2>/dev/null || echo unknown)
    git -C "$BUNDLE" commit -m "Memory update (${ROLE}, $(date -Iseconds))"
fi
