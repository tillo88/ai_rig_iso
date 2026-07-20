#!/usr/bin/env bash
# =============================================================================
# AutoMem (FalkorDB + Qdrant + API), dati persistenti sul disco condiviso.
# Installazione idempotente: make install solo quando cambiano gli input;
# avvio normale con docker compose up -d (mai make dev / compose down al boot).
# =============================================================================
set -Eeuo pipefail
exec >> /var/log/ai-rig-stage-automem.log 2>&1
trap 'rc=$?; echo "!!! AutoMem fallito alla riga $LINENO (rc=$rc)" >&2' ERR

echo "=== Stage AutoMem - $(date -Iseconds) ==="

STATE_DIR="/var/lib/ai-rig"
STAMP="$STATE_DIR/automem-install.sha256"
MOUNT_PATH="/mnt/ai-rig-shared"
MIN_ROOT_FREE_GIB="${AUTOMEM_MIN_ROOT_FREE_GIB:-25}"

mkdir -p "$STATE_DIR"

if [ ! -d "$MOUNT_PATH" ] || ! mountpoint -q "$MOUNT_PATH"; then
    echo "!!! $MOUNT_PATH non montato. Salto AutoMem; ritentera' al prossimo boot." >&2
    exit 0
fi
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "!!! Docker non disponibile. Salto AutoMem; ritentera' al prossimo boot." >&2
    exit 0
fi

mkdir -p "${MOUNT_PATH}/automem/falkordb" "${MOUNT_PATH}/automem/qdrant"

if [ ! -d /opt/automem/.git ]; then
    rm -rf /opt/automem
    git clone --depth 1 https://github.com/verygoodplugins/automem.git /opt/automem
fi
cd /opt/automem

cat > docker-compose.override.yml << EOFOVERRIDE
services:
  falkordb:
    volumes:
      - ${MOUNT_PATH}/automem/falkordb:/data
  qdrant:
    volumes:
      - ${MOUNT_PATH}/automem/qdrant:/qdrant/storage
EOFOVERRIDE

SERVICES="$(docker compose config --services)"
grep -qx 'falkordb' <<<"$SERVICES" || { echo "!!! servizio falkordb assente dal compose upstream" >&2; exit 1; }
grep -qx 'qdrant' <<<"$SERVICES" || { echo "!!! servizio qdrant assente dal compose upstream" >&2; exit 1; }

automem_hash() {
    local -a files=()
    while IFS= read -r -d '' f; do files+=("$f"); done < <(
        find . -maxdepth 1 -type f \
            \( -name 'Makefile' -o -name 'requirements*.txt' -o -name 'pyproject.toml' -o -name 'poetry.lock' \) \
            -print0 | sort -z
    )
    [ "${#files[@]}" -gt 0 ] || { echo "nessun-input-install"; return; }
    sha256sum "${files[@]}" | sha256sum | awk '{print $1}'
}

INSTALL_HASH="$(automem_hash)"
NEEDS_INSTALL=1
[ -s "$STAMP" ] && [ "$(cat "$STAMP")" = "$INSTALL_HASH" ] && NEEDS_INSTALL=0
NEEDS_IMAGE=0
[ -n "$(docker compose images -q 2>/dev/null | head -n1)" ] || NEEDS_IMAGE=1

if [ "$NEEDS_INSTALL" -eq 1 ] || [ "$NEEDS_IMAGE" -eq 1 ]; then
    FREE_KIB="$(df -Pk / | awk 'NR==2 {print $4}')"
    MIN_KIB=$((MIN_ROOT_FREE_GIB * 1024 * 1024))
    if [ "$FREE_KIB" -lt "$MIN_KIB" ]; then
        echo "!!! Spazio root insufficiente per install/build AutoMem: servono almeno ${MIN_ROOT_FREE_GIB} GiB liberi." >&2
        df -h /
        exit 1
    fi
fi

if [ "$NEEDS_INSTALL" -eq 1 ]; then
    echo "Input AutoMem nuovi o primo avvio: eseguo make install una sola volta."
    make install
    printf '%s\n' "$INSTALL_HASH" > "$STAMP"
else
    echo "make install gia' completato per questi input: salto."
fi

echo "Avvio/riconcilio i container AutoMem in background..."
docker compose up -d
docker compose ps

touch "$STATE_DIR/stage-automem-ready"
echo "=== AutoMem pronto (dati su ${MOUNT_PATH}/automem) - $(date -Iseconds) ==="
