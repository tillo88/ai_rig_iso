#!/bin/bash
# =============================================================================
# STAGE 2/4 — CUDA Toolkit + __LLAMA_FLAVOR__.
# Installa il prebuilt con rename/move sullo stesso filesystem, evitando copie
# duplicate. Il marker viene creato solo dopo smoke test del binario.
# =============================================================================
set -Eeuo pipefail
exec >> /var/log/ai-rig-stage-cuda-llama.log 2>&1

echo "=== Stage 2 (cuda+llama) - $(date -Iseconds) ==="
STATE_DIR="/var/lib/ai-rig"
CACHE_DIR="/opt/cache"
LLAMA_DIR="/opt/llama.cpp"
SERVER="$LLAMA_DIR/build/bin/llama-server"
mkdir -p "$STATE_DIR" /opt/ai-rig

[ -f "$STATE_DIR/stage-cuda-llama-done" ] && {
    echo "Stage già completato."
    exit 0
}

die() { echo "!!! stage-cuda-llama: $*" >&2; exit 1; }

nvidia-smi >/dev/null 2>&1 || die "nvidia-smi non risponde: stage driver incompleto"
nvidia-smi

# Installa CUDA soltanto se nvcc non è già disponibile in una cuda-* valida.
CUDA_BIN_DIR="$(find /usr/local -maxdepth 1 -type d -name 'cuda-*' | sort -V | tail -n1 || true)"
if [ -z "$CUDA_BIN_DIR" ] || [ ! -x "$CUDA_BIN_DIR/bin/nvcc" ]; then
    [ -f "$CACHE_DIR/cuda-toolkit.run" ] || die "$CACHE_DIR/cuda-toolkit.run assente"
    echo "Installo CUDA Toolkit..."
    sh "$CACHE_DIR/cuda-toolkit.run" --toolkit --silent --override
    CUDA_BIN_DIR="$(find /usr/local -maxdepth 1 -type d -name 'cuda-*' | sort -V | tail -n1 || true)"
fi
[ -n "$CUDA_BIN_DIR" ] && [ -x "$CUDA_BIN_DIR/bin/nvcc" ] \
    || die "nvcc non trovato dopo l'installazione CUDA"

cat > /etc/profile.d/cuda.sh <<EOFPROFILE
export PATH=${CUDA_BIN_DIR}/bin:\$PATH
export LD_LIBRARY_PATH=${CUDA_BIN_DIR}/lib64:\${LD_LIBRARY_PATH:-}
EOFPROFILE
chmod 0644 /etc/profile.d/cuda.sh
"$CUDA_BIN_DIR/bin/nvcc" --version

# BeeLlama prebuilt richiede libnccl.so.2. Nel flusso production il pacchetto
# e l'installer sono nella cache offline; l'installer conserva un fallback APT.
if ! ldconfig -p 2>/dev/null | grep -q 'libnccl\.so\.2'; then
    NCCL_INSTALLER="$CACHE_DIR/scripts/install-nccl-runtime.sh"
    [ -x "$NCCL_INSTALLER" ] \
        || die "NCCL assente e installer non trovato: $NCCL_INSTALLER"
    echo "Installo runtime NCCL per CUDA 12.8..."
    "$NCCL_INSTALLER" --cuda 12.8
fi
ldconfig -p 2>/dev/null | grep -q 'libnccl\.so\.2' \
    || die "libnccl.so.2 assente dopo l'installazione NCCL"

if [ -x "$SERVER" ]; then
    echo "__LLAMA_FLAVOR__ già installato: $SERVER"
elif [ -x "$CACHE_DIR/llama-prebuilt/bin/llama-server" ]; then
    echo "Installo __LLAMA_FLAVOR__ precompilato tramite move atomico della directory bin..."
    # Una installazione parziale senza server non è considerata valida.
    rm -rf "$LLAMA_DIR"
    mkdir -p "$LLAMA_DIR/build"
    mv "$CACHE_DIR/llama-prebuilt/bin" "$LLAMA_DIR/build/bin"
    find "$LLAMA_DIR/build/bin" -maxdepth 1 -type f -exec chmod +x {} +
else
    echo "Prebuilt assente: compilo __LLAMA_FLAVOR__ sul target."
    BUILD_TMP="/opt/llama.cpp.build.$$"
    rm -rf "$BUILD_TMP" "$LLAMA_DIR"
    git clone --depth 1 "__LLAMA_REPO__" "$BUILD_TMP"
    cd "$BUILD_TMP"
    # shellcheck disable=SC2086
    cmake -B build \
        -DGGML_CUDA=ON \
        -DCMAKE_CUDA_ARCHITECTURES="__CUDA_ARCHS__" \
        -DGGML_CUDA_FORCE_MMQ=ON \
        __LLAMA_CMAKE_EXTRA__ \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF
    cmake --build build --config Release -j"$(nproc)"
    [ -x "$BUILD_TMP/build/bin/llama-server" ] \
        || die "compilazione completata senza llama-server"
    mv "$BUILD_TMP" "$LLAMA_DIR"
fi

[ -x "$SERVER" ] || die "llama-server non installato"

# Cattura librerie dinamiche mancanti prima di creare il marker.
if command -v ldd >/dev/null 2>&1; then
    MISSING_LIBS="$(ldd "$SERVER" 2>/dev/null | awk '/not found/{print $1}' | xargs || true)"
    [ -z "$MISSING_LIBS" ] || die "librerie mancanti: $MISSING_LIBS"
fi

VERSION_OUT="$(timeout 30 "$SERVER" --version 2>&1)" \
    || die "smoke test 'llama-server --version' fallito"
printf '%s\n' "$VERSION_OUT"

{
    echo "flavor=__LLAMA_FLAVOR__"
    echo "installed_at=$(date -Iseconds)"
    echo "cuda_dir=$CUDA_BIN_DIR"
    if [ -d "$LLAMA_DIR/.git" ]; then
        git -C "$LLAMA_DIR" log -1 --format='commit=%H date=%cI' || true
    else
        echo "source=prebuilt-cache"
        [ -f "$CACHE_DIR/llama-prebuilt/FLAVOR" ] \
            && echo "cache_flavor=$(cat "$CACHE_DIR/llama-prebuilt/FLAVOR")"
    fi
} > /opt/ai-rig/build-info.txt

# Pulizia soltanto dopo installazione e smoke test riusciti.
rm -f "$CACHE_DIR/cuda-toolkit.run"
rm -rf "$CACHE_DIR/llama-prebuilt"
touch "$STATE_DIR/stage-cuda-llama-done"
sync

echo "=== Stage 2 completato - $(date -Iseconds) ==="
