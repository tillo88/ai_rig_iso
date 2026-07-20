#!/bin/bash
# Applica il pacchetto alla root del progetto AI Rig e rigenera gli artefatti.
set -Eeuo pipefail

PACK_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-.}"
TARGET="$(cd "$TARGET" && pwd)"

[ -f "$TARGET/config/rig.env" ] || {
    echo "!!! '$TARGET' non sembra la root del progetto (manca config/rig.env)." >&2
    echo "Uso: bash APPLICA-PATCH.sh /percorso/ai-rig-iso-build" >&2
    exit 1
}

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$TARGET/.patch-backup-$STAMP"
mkdir -p "$BACKUP"

FILES=(
    build-iso.sh
    scripts/05-generate-nocloud.sh
    scripts/grub-centralize.sh
    scripts/grub-stable-entries.sh
    templates/select-next-role.sh.tmpl
    rig-common-scripts/20-cuda-llama-stage.sh
    rig-common-scripts/ai-rig-first-boot.sh
    rig-common-scripts/ai-rig-finalize.sh
    rig-common-scripts/populate-cache.sh
    rig-common-systemd/ai-rig-first-boot.service
    rig-common-systemd/ai-rig-finalize.service
    nocloud/auto/user-data
    nocloud/auto/meta-data
)

for rel in "${FILES[@]}"; do
    src="$PACK_DIR/$rel"
    dst="$TARGET/$rel"
    [ -f "$src" ] || { echo "!!! File pacchetto assente: $rel" >&2; exit 1; }
    if [ -e "$dst" ]; then
        mkdir -p "$BACKUP/$(dirname "$rel")"
        cp -a "$dst" "$BACKUP/$rel"
    fi
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst"
done

chmod +x \
    "$TARGET/build-iso.sh" \
    "$TARGET/scripts/05-generate-nocloud.sh" \
    "$TARGET/scripts/grub-centralize.sh" \
    "$TARGET/scripts/grub-stable-entries.sh" \
    "$TARGET/templates/select-next-role.sh.tmpl" \
    "$TARGET/rig-common-scripts/"*.sh

cd "$TARGET"
bash scripts/05-generate-nocloud.sh

while IFS= read -r -d '' script; do
    bash -n "$script"
done < <(find build-iso.sh scripts rig-common-scripts rig-common -type f -name '*.sh' -print0)

python3 - <<'PY'
from pathlib import Path
try:
    import yaml
except ImportError:
    print("PyYAML non installato: controllo YAML saltato")
else:
    for path in sorted(Path("nocloud").glob("*/user-data")):
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
        if not isinstance(data, dict) or "autoinstall" not in data:
            raise SystemExit(f"YAML non valido: {path}")
    print("YAML NoCloud: OK")
PY

echo "Patch applicata e artefatti rigenerati."
echo "Backup: $BACKUP"
echo "Prossimo comando consigliato: ./build-iso.sh --production --cache-disk /mnt/4tb"
