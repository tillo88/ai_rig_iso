#!/bin/bash
# Understory sidecar: memoria Markdown/OKF condivisa fra DEVIN/HERMES/TEACHER.
# Il container resta loopback-only; dalla workstation usare un tunnel SSH.
set -euo pipefail
exec >> /var/log/ai-rig-stage-understory.log 2>&1
echo "=== Stage Understory - $(date) ==="

MOUNT_PATH="/mnt/ai-rig-shared"
ENABLE_UNDERSTORY=true
UNDERSTORY_IMAGE="ghcr.io/thecodacus/understory:latest"
UNDERSTORY_PORT=3800
UNDERSTORY_BIND_HOST="127.0.0.1"
UNDERSTORY_GIT_AUTOCOMMIT=false
[ -f /opt/cache/config/shared-disk.env ] && source /opt/cache/config/shared-disk.env

if [ "${ENABLE_UNDERSTORY}" != "true" ]; then
    echo "Understory disabilitato da config/shared-disk.env"
    exit 0
fi
if ! mountpoint -q "$MOUNT_PATH"; then
    echo "!!! Disco condiviso non montato: salto Understory." >&2
    exit 0
fi
if ! command -v docker >/dev/null 2>&1; then
    echo "!!! Docker non disponibile: salto Understory." >&2
    exit 0
fi

BUNDLE="${MOUNT_PATH}/understory/bundle"
RUNTIME="${MOUNT_PATH}/understory/runtime"
INSTALL_DIR="/opt/ai-rig/understory"
mkdir -p "$BUNDLE" "$RUNTIME" "$INSTALL_DIR"
mkdir -p \
    "$BUNDLE/shared/software-engineering" "$BUNDLE/shared/gui-automation" \
    "$BUNDLE/shared/general" "$BUNDLE/policy"

# Il contratto e' condiviso e versionato assieme alla memoria. Non contiene
# segreti; i client lo usano per validare pubblicazione e recall cross-bot.
if [ -f /opt/cache/config/memory-policy.json ]; then
    install -m 0644 /opt/cache/config/memory-policy.json "$BUNDLE/policy/memory-policy.json"
fi
if [ -f /opt/cache/config/cognitive-policy.json ]; then
    install -m 0644 /opt/cache/config/cognitive-policy.json "$BUNDLE/policy/cognitive-policy.json"
fi

# Git e' il rollback della memoria. Viene inizializzato una volta sola sul 4°
# disco e poi condiviso dai tre sistemi operativi, uno attivo alla volta.
if [ ! -d "$BUNDLE/.git" ]; then
    git -C "$BUNDLE" init
    git -C "$BUNDLE" config user.name "AI Rig Understory"
    git -C "$BUNDLE" config user.email "understory@ai-rig.local"
    cat > "$BUNDLE/index.md" <<'EOF'
---
type: Index
title: AI Rig shared memory
description: Memoria condivisa fra DEVIN, HERMES e TEACHER.
---

# AI Rig shared memory

Bundle OKF federato sul quarto disco. DEVIN, TEACHER e HERMES possono leggere
la conoscenza verificata in shared/, mentre raw/ e quarantine/ restano fuori
dal recall condiviso. Ogni memoria pubblicata conserva fonte, dominio, stato,
polarita e prove. Le modifiche Markdown sono gestite da Understory.
EOF
    git -C "$BUNDLE" add index.md
    git -C "$BUNDLE" commit -m "Initialize shared OKF memory"
fi

cat > "$INSTALL_DIR/docker-compose.yml" <<EOF
services:
  understory:
    image: ${UNDERSTORY_IMAGE}
    restart: unless-stopped
    ports:
      - "${UNDERSTORY_BIND_HOST}:${UNDERSTORY_PORT}:3800"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - ${BUNDLE}:/bundle
      - ${RUNTIME}:/runtime
    environment:
      BUNDLE_ROOT: /bundle
      LLM_PROVIDER: llamacpp
      LLAMACPP_BASE_URL: http://host.docker.internal:8080
      GIT_AUTOCOMMIT: "${UNDERSTORY_GIT_AUTOCOMMIT}"
      PORT: 3800
EOF

docker pull "$UNDERSTORY_IMAGE"
docker image inspect "$UNDERSTORY_IMAGE" --format '{{index .RepoDigests 0}}' \
    > /var/lib/ai-rig/understory-image.txt 2>/dev/null || true
docker compose -f "$INSTALL_DIR/docker-compose.yml" up -d

echo "Understory: http://${UNDERSTORY_BIND_HOST}:${UNDERSTORY_PORT}"
echo "Bundle: $BUNDLE"
echo "=== Stage Understory completato - $(date) ==="
