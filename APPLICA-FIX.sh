#!/usr/bin/env bash
set -Eeuo pipefail

TARGET="${1:-$HOME/ai-rig-iso-build}"
SRC_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SRC_DIR/build-iso.sh"
DST="$TARGET/build-iso.sh"
SHA_FILE="$SRC_DIR/build-iso.sh.sha256"

fail() { echo "ERRORE: $*" >&2; exit 1; }

[ -d "$TARGET" ] || fail "progetto non trovato: $TARGET"
[ -f "$DST" ] || fail "build-iso.sh non trovato in: $TARGET"
[ -f "$SRC" ] || fail "file corretto assente: $SRC"
[ -f "$SHA_FILE" ] || fail "checksum assente: $SHA_FILE"

bash -n "$SRC"

EXPECTED="$(awk 'NF && $1 !~ /^#/ {print $1; exit}' "$SHA_FILE")"
ACTUAL="$(sha256sum "$SRC" | awk '{print $1}')"
[ -n "$EXPECTED" ] || fail "checksum atteso vuoto in $SHA_FILE"
[ "$ACTUAL" = "$EXPECTED" ] || fail "checksum build-iso.sh non valido (atteso $EXPECTED, trovato $ACTUAL)"

BACKUP="$DST.bak.$(date +%Y%m%d-%H%M%S)"
cp -a -- "$DST" "$BACKUP"
install -m 0755 -- "$SRC" "$DST"

bash -n "$DST"
grep -q 'sync_build_id_to_cache_disk' "$DST" || fail "funzione sync_build_id_to_cache_disk assente dopo l'installazione"
grep -q 'BUILD_ID sincronizzato e verificato' "$DST" || fail "controllo finale BUILD_ID assente dopo l'installazione"
cmp -s "$SRC" "$DST" || fail "il file installato non coincide con il file verificato"

echo "OK: build-iso.sh aggiornato"
echo "Backup: $BACKUP"
echo "Il prossimo build sincronizzera' automaticamente cache/BUILD_ID sul disco ai-rig-cache."
