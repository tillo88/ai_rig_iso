#!/usr/bin/env bash
set -Eeuo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="${1:-$PWD}"
FORCE="${FORCE:-0}"
MANIFEST="$SELF_DIR/original-sha256.txt"
PAYLOAD="$SELF_DIR/files"

[ -f "$REPO/build-iso.sh" ] && [ -d "$REPO/rig-common-scripts" ] || {
    echo "ERRORE: '$REPO' non sembra la root di ai-rig-iso-build." >&2
    echo "Uso: bash apply.sh /percorso/ai-rig-iso-build" >&2
    exit 2
}

mismatches=()
while read -r expected file; do
    [ -n "${file:-}" ] || continue
    target="$REPO/$file"
    if [ "$expected" = NEW ]; then
        [ ! -e "$target" ] || mismatches+=("$file (doveva essere nuovo)")
        continue
    fi
    if [ ! -f "$target" ]; then
        mismatches+=("$file (manca)")
        continue
    fi
    actual="$(sha256sum "$target" | awk '{print $1}')"
    [ "$actual" = "$expected" ] || mismatches+=("$file (modificato rispetto all'archivio analizzato)")
done < "$MANIFEST"

if [ "${#mismatches[@]}" -gt 0 ] && [ "$FORCE" != 1 ]; then
    echo "STOP: alcuni sorgenti non coincidono con quelli analizzati:" >&2
    printf '  - %s\n' "${mismatches[@]}" >&2
    echo >&2
    echo "Non sovrascrivo modifiche più recenti. Riesegui con FORCE=1 solo dopo averle revisionate." >&2
    exit 3
fi

stamp="$(date +%Y%m%d-%H%M%S)"
backup="$REPO/.runtime-fix-backups/$stamp"
mkdir -p "$backup"

while read -r _ file; do
    [ -n "${file:-}" ] || continue
    if [ -e "$REPO/$file" ]; then
        mkdir -p "$backup/$(dirname "$file")"
        cp -a "$REPO/$file" "$backup/$file"
    fi
    mkdir -p "$REPO/$(dirname "$file")"
    cp -a "$PAYLOAD/$file" "$REPO/$file"
done < "$MANIFEST"

echo "Backup: $backup"

# Validazione statica senza eseguire build, Docker o modifiche ai rig.
for f in \
    rig-common-scripts/populate-cache.sh \
    rig-common-scripts/60-automem.sh \
    rig-common-scripts/90-verify.sh \
    rig-common-scripts/ai-rig-select-role.sh \
    templates/hermes-extras.sh.tmpl \
    scripts/05-generate-nocloud.sh; do
    bash -n "$REPO/$f"
done

python3 - "$REPO" <<'PY'
import ast
import sys
from pathlib import Path
root = Path(sys.argv[1])
for rel in ("pi-bot/ai-rig-wol-bot.py", "rig-roles/teacher/scripts/teacher-bot.py"):
    text = (root / rel).read_text()
    tree = ast.parse(text, filename=rel)
    for node in ast.walk(tree):
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.BitOr):
            raise SystemExit(f"Sintassi union PEP604 non compatibile con Python 3.9: {rel}:{node.lineno}")
    print(f"PY OK: {rel}")
PY

# Evita che i vecchi comportamenti restino nei sorgenti autorevoli.
if grep -RIn '/opt/cache/comfyui-models' \
    "$REPO/rig-common-scripts/populate-cache.sh" \
    "$REPO/templates/hermes-extras.sh.tmpl"; then
    echo "ERRORE: riferimenti ComfyUI alla root ancora presenti." >&2
    exit 4
fi
if grep -nE '^[[:space:]]*make[[:space:]]+dev([[:space:]]|$)' \
    "$REPO/rig-common-scripts/60-automem.sh"; then
    echo "ERRORE: make dev ancora eseguibile al boot." >&2
    exit 4
fi
grep -q 'automem-install.sha256' "$REPO/rig-common-scripts/60-automem.sh"
grep -q 'docker compose up -d' "$REPO/rig-common-scripts/60-automem.sh"

echo
printf 'FIX APPLICATI AI SORGENTI.\n'
printf 'Per rigenerare le copie derivate: cd %q && bash scripts/05-generate-nocloud.sh\n' "$REPO"
printf 'Per vedere le modifiche: cd %q && git diff --check && git diff\n' "$REPO"
