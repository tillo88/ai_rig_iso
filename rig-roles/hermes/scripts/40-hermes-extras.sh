#!/bin/bash
# =============================================================================
# Solo per il ruolo HERMES. Installa Hermes-Agent (installer ufficiale), lo punta
# al llama-server locale, gli collega AutoMem via MCP, e installa ComfyUI per la
# generazione immagini (checkpoint dal disco condiviso, popolati dalla cache 4 TB
# prima di buildare la ISO). Verificato contro la documentazione ufficiale
# Hermes-Agent (installer, mcp_servers, model/context_length) — l'UNICA parte
# non garantita al 100% e' la selezione automatica del "custom provider" locale:
# lo script prova, poi si AUTO-VERIFICA con una chiamata di test e ti avvisa
# chiaramente nei log se serve un `hermes setup` manuale una tantum.
# =============================================================================
set -Eeuo pipefail
trap 'rc=$?; echo "!!! Hermes extras fallito alla riga $LINENO (rc=$rc)" >&2' ERR
exec >> /var/log/ai-rig-hermes-extras.log 2>&1
echo "=== Hermes extras (Hermes-Agent + AutoMem + ComfyUI) - $(date) ==="

mkdir -p /var/lib/ai-rig
if [ -f /var/lib/ai-rig/stage-hermes-extras-done ]; then
    echo "Gia' completato, esco."
    exit 0
fi

LLAMA_PORT="8080"
CTX_SIZE="32768"
HOME_DIR="/home/tillo"
SEARXNG_PORT=8081   # NON 8080: e' gia' occupato dal llama-server su questo stesso ruolo
SHARED_MOUNT_PATH="/mnt/ai-rig-shared"
SHARED_COMFY_MODELS="$SHARED_MOUNT_PATH/comfyui-models"
SHARED_COMFY_OUTPUT="$SHARED_MOUNT_PATH/comfyui-output"

mountpoint -q "$SHARED_MOUNT_PATH" || {
    echo "!!! Disco condiviso non montato: $SHARED_MOUNT_PATH" >&2
    exit 1
}
mkdir -p "$SHARED_COMFY_MODELS" "$SHARED_COMFY_OUTPUT"

# --- SearXNG (ricerca web privata, self-hosted) ---
mkdir -p /opt/searxng
if [ ! "$(docker ps -a --format '{{.Names}}' | grep -x searxng)" ]; then
    docker run -d --name searxng --restart unless-stopped \
        -p ${SEARXNG_PORT}:8080 \
        -v /opt/searxng:/etc/searxng:rw \
        -e SEARXNG_BASE_URL="http://localhost:${SEARXNG_PORT}/" \
        docker.io/searxng/searxng:latest
    echo "Attendo che SearXNG generi la config iniziale..."
    sleep 8
fi
# SearXNG disabilita il formato JSON di default: Hermes lo richiede per leggere i risultati.
if [ -f /opt/searxng/settings.yml ] && ! grep -q "^\s*- json" /opt/searxng/settings.yml; then
    sed -i '/formats:/a\    - json' /opt/searxng/settings.yml
    docker restart searxng
fi

# --- Firecrawl-simple (self-hosted, SOLO estrazione — SearXNG non lo fa) ---
# Versione "simple" (devflowinc/firecrawl-simple): niente Postgres/auth/billing,
# solo api+worker+redis+puppeteer — piu' leggera della Firecrawl "ufficiale" a 5
# container. Reale comunque: Puppeteer tiene un Chromium headless, aspettati
# qualche centinaio di MB in piu' di RAM per scraping attivo.
if [ ! -d /opt/firecrawl-simple ]; then
    git clone --depth 1 https://github.com/devflowinc/firecrawl-simple.git /opt/firecrawl-simple
fi
cd /opt/firecrawl-simple
if [ ! -f .env ]; then
    cat > .env << 'EOFENV'
NUM_WORKERS_PER_QUEUE=8
PORT=3002
HOST=0.0.0.0
REDIS_URL=redis://redis:6379
REDIS_RATE_LIMIT_URL=redis://redis:6379
EOFENV
fi
docker compose up -d || echo "!!! docker compose per firecrawl-simple fallito, verifica manualmente in /opt/firecrawl-simple" >&2
cd - > /dev/null

# --- Hermes-Agent (installer ufficiale, idempotente) ---
sudo -u tillo -H bash -c 'curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash' \
    || echo "!!! Installer Hermes-Agent fallito, verifica manualmente" >&2

mkdir -p "${HOME_DIR}/.hermes"
cat > "${HOME_DIR}/.hermes/.env" << EOFENV
SEARXNG_BASE_URL=http://localhost:${SEARXNG_PORT}
FIRECRAWL_API_URL=http://localhost:3002
EOFENV
cat > "${HOME_DIR}/.hermes/config.yaml" << EOFCFG
model:
  provider: custom
  default: hermes-local
  base_url: "http://localhost:${LLAMA_PORT}/v1"
  api_mode: chat_completions
  context_length: ${CTX_SIZE}

custom_providers:
  local:
    base_url: "http://localhost:${LLAMA_PORT}/v1"
    api_key: "not-needed"

web:
  backend: searxng          # ricerca
  extract_backend: firecrawl # estrazione pagine — self-hosted, FIRECRAWL_API_URL in .env

mcp_servers:
  librarian:
    url: "http://localhost:3810/mcp"
EOFCFG
chown -R tillo:tillo "${HOME_DIR}/.hermes"

sudo -u tillo -H bash -c 'hermes tools enable web' 2>&1 | tail -5 || \
    echo "⚠️  'hermes tools enable web' non confermato, verifica con: hermes tools list | grep web" >&2

# Auto-verifica: se il provider custom non e' stato agganciato correttamente,
# 'hermes -z' fallira' o non rispondera' in modo sensato — meglio saperlo nei
# log ora che scoprirlo al primo utilizzo.
echo "Verifica Hermes-Agent..."
TEST_OUT=$(sudo -u tillo -H bash -c 'hermes -z "rispondi solo con: OK"' 2>&1 || true)
if echo "$TEST_OUT" | grep -qi "OK"; then
    echo "✅ Hermes-Agent risponde correttamente sul modello locale."
else
    echo "⚠️  Hermes-Agent non ha risposto come atteso. Output: $TEST_OUT" >&2
    echo "⚠️  Esegui manualmente: sudo -u tillo -H hermes setup" >&2
    echo "⚠️  e scegli 'Custom OpenAI-compatible endpoint' -> http://localhost:${LLAMA_PORT}/v1" >&2
fi

# --- ComfyUI (comfy-cli, metodo ufficiale) ---
if [ ! -d /opt/comfyui ]; then
    pip install --break-system-packages comfy-cli
    comfy --workspace /opt/comfyui install --nvidia --version latest
fi
[ -d /opt/comfyui ] || {
    echo "!!! Installazione ComfyUI incompleta: /opt/comfyui assente" >&2
    exit 1
}

# Custom node necessario per caricare Flux in formato GGUF (city96/ComfyUI-GGUF)
if [ ! -d /opt/comfyui/custom_nodes/ComfyUI-GGUF ]; then
    git clone --depth 1 https://github.com/city96/ComfyUI-GGUF /opt/comfyui/custom_nodes/ComfyUI-GGUF \
        && /opt/comfyui/.venv/bin/pip install -r /opt/comfyui/custom_nodes/ComfyUI-GGUF/requirements.txt 2>/dev/null \
        || pip install --break-system-packages gguf
fi

# Collega i checkpoint dal disco condiviso alle sottocartelle GIUSTE di ComfyUI.
# Flux non e' un checkpoint singolo: unet+clip+vae vanno in cartelle separate.
mkdir -p /opt/comfyui/models/checkpoints /opt/comfyui/models/unet /opt/comfyui/models/clip /opt/comfyui/models/vae
if [ -d "$SHARED_COMFY_MODELS" ]; then
    for sub in checkpoints unet clip vae; do
        [ -d "$SHARED_COMFY_MODELS/$sub" ] || continue
        for f in "$SHARED_COMFY_MODELS/$sub"/*; do
            [ -f "$f" ] || continue
            ln -sfn "$f" "/opt/comfyui/models/$sub/$(basename "$f")"
        done
    done
    echo "Checkpoint collegati: $(find /opt/comfyui/models/{checkpoints,unet,clip,vae} -type l 2>/dev/null | wc -l)"
else
    echo "⚠️  $SHARED_COMFY_MODELS vuota — controlla la cache 4 TB e populate-cache.sh." >&2
fi

# Anche gli output possono crescere molto: li manteniamo sul disco condiviso.
if [ -d /opt/comfyui/output ] && [ ! -L /opt/comfyui/output ]; then
    rsync -a /opt/comfyui/output/ "$SHARED_COMFY_OUTPUT/"
    rm -rf /opt/comfyui/output
elif [ -L /opt/comfyui/output ]; then
    rm -f /opt/comfyui/output
fi
ln -s "$SHARED_COMFY_OUTPUT" /opt/comfyui/output

touch /var/lib/ai-rig/stage-hermes-extras-done
echo "=== Hermes extras completato - $(date) ==="
