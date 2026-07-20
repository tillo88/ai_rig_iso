#!/bin/bash
# =============================================================================
# scripts/download-cache.sh — popola cache/ con tutto il necessario.
# - SKIP automatico dei file gia' presenti (>1MB): rilanciabile quante volte vuoi.
# - Un download fallito NON blocca gli altri: errori raccolti e riepilogati in fondo.
# - wget -c: i download interrotti riprendono da dove erano.
# Esegui con: bash scripts/download-cache.sh   (da qualsiasi cartella)
# =============================================================================
cd "$(dirname "$0")/.."
mkdir -p cache/models/devin cache/models/hermes cache/models/teacher \
         cache/comfyui-models/checkpoints cache/comfyui-models/unet \
         cache/comfyui-models/clip cache/comfyui-models/vae

FAILED=()
SKIPPED=0
DONE=0

fetch() {
    local url="$1" dest="$2"
    # Skip se esiste ed e' piu' grande di 1MB (evita di "salvare" pagine di errore html)
    if [ -f "$dest" ] && [ "$(stat -c%s "$dest" 2>/dev/null || echo 0)" -gt 1048576 ]; then
        echo "  [skip] $(basename "$dest") gia' presente ($(du -h "$dest" | cut -f1))"
        SKIPPED=$((SKIPPED+1))
        return 0
    fi
    echo "  [get ] $(basename "$dest")"
    if wget -c --show-progress "$url" -O "$dest"; then
        DONE=$((DONE+1))
    else
        echo "  [FAIL] $(basename "$dest") — continuo con gli altri" >&2
        rm -f "$dest"   # non lasciare file vuoti/parziali-html che ingannerebbero lo skip
        FAILED+=("$dest <- $url")
    fi
}

echo "### 1/6 — Driver NVIDIA + CUDA Toolkit ###"
fetch "https://us.download.nvidia.com/XFree86/Linux-x86_64/570.86.10/NVIDIA-Linux-x86_64-570.86.10.run" \
      cache/nvidia-driver.run
fetch "https://developer.download.nvidia.com/compute/cuda/12.8.0/local_installers/cuda_12.8.0_570.86.10_linux.run" \
      cache/cuda-toolkit.run

echo "### 2/6 — DEVIN: Ornith-1.0-35B (20.7GB) ###"
fetch "https://huggingface.co/jashepp/Ornith-1.0-35B-A3B-MXFP4_MOE_Hybrid-Imatrix-GGUF/resolve/main/Ornith-1.0-35B-A3B-MXFP4_MOE_Q8_0_F16-Imatrix.gguf?download=true" \
      cache/models/devin/Ornith-1.0-35B-A3B-MXFP4_MOE_Q8_0_F16-Imatrix.gguf

echo "### 3/6 — TEACHER: Qwen3-VL-30B-Thinking (25.3GB) + mmproj (1.09GB) ###"
fetch "https://huggingface.co/bartowski/Qwen_Qwen3-VL-30B-A3B-Thinking-GGUF/resolve/main/Qwen_Qwen3-VL-30B-A3B-Thinking-Q6_K_L.gguf?download=true" \
      cache/models/teacher/Qwen_Qwen3-VL-30B-A3B-Thinking-Q6_K_L.gguf
fetch "https://huggingface.co/bartowski/Qwen_Qwen3-VL-30B-A3B-Thinking-GGUF/resolve/main/mmproj-Qwen_Qwen3-VL-30B-A3B-Thinking-bf16.gguf?download=true" \
      cache/models/teacher/mmproj-Qwen_Qwen3-VL-30B-A3B-Thinking-bf16.gguf

echo "### 4/6 — HERMES: DavidAU Deckard Q6_K (~32GB) — mmproj: MANUALE ###"
fetch "https://huggingface.co/DavidAU/Qwen3.6-40B-Claude-4.6-Opus-Deckard-Heretic-Uncensored-Thinking-NEO-CODE-Di-IMatrix-MAX-GGUF/resolve/main/Qwen3.6-40B-Deck-Opus-NEO-CODE-HERE-2T-OT-Q6_K.gguf?download=true" \
      cache/models/hermes/Qwen3.6-40B-Deck-Opus-NEO-CODE-HERE-2T-OT-Q6_K.gguf
if ! ls cache/models/hermes/mmproj-* >/dev/null 2>&1; then
    echo "  [MANUALE] mmproj di Hermes non trovato: scaricane UNO da"
    echo "            https://huggingface.co/DavidAU/Qwen3.6-40B-Claude-4.6-Opus-Deckard-Heretic-Uncensored-Thinking-NEO-CODE-Di-IMatrix-MAX-GGUF/tree/main"
    echo "            in cache/models/hermes/ e allinea ROLE_MMPROJ_FILE in config/roles/hermes.env"
else
    echo "  [ok] mmproj presente: $(ls cache/models/hermes/mmproj-*)"
    CONF=$(grep -oP '^ROLE_MMPROJ_FILE="\K[^"]*' config/roles/hermes.env)
    ACTUAL=$(basename "$(ls cache/models/hermes/mmproj-* | head -n1)")
    if [ "$CONF" != "$ACTUAL" ]; then
        echo "  [ATTENZIONE] config/roles/hermes.env dice ROLE_MMPROJ_FILE=\"$CONF\""
        echo "               ma il file si chiama \"$ACTUAL\" — allineali o il primo boot non lo trovera'."
    fi
fi

echo "### 5/6 — ComfyUI: SDXL base + Pony Diffusion V6 XL ###"
fetch "https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/resolve/main/sd_xl_base_1.0.safetensors?download=true" \
      cache/comfyui-models/checkpoints/sd_xl_base_1.0.safetensors
fetch "https://huggingface.co/LyliaEngine/Pony_Diffusion_V6_XL/resolve/main/ponyDiffusionV6XL_v6StartWithThisOne.safetensors?download=true" \
      cache/comfyui-models/checkpoints/ponyDiffusionV6XL_v6StartWithThisOne.safetensors
fetch "https://huggingface.co/LyliaEngine/Pony_Diffusion_V6_XL/resolve/main/sdxl_vae.safetensors?download=true" \
      cache/comfyui-models/vae/pony_sdxl_vae.safetensors

echo "### 6/6 — ComfyUI: Flux dev Q8_0 GGUF + text encoder + VAE ###"
# Flux NON e' un checkpoint singolo: unet+clip(x2)+vae in cartelle separate.
# Variante Apache 2.0: sostituisci 'dev' con 'schnell' nei primi URL.
fetch "https://huggingface.co/city96/FLUX.1-dev-gguf/resolve/main/flux1-dev-Q8_0.gguf?download=true" \
      cache/comfyui-models/unet/flux1-dev-Q8_0.gguf
fetch "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors?download=true" \
      cache/comfyui-models/clip/clip_l.safetensors
fetch "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp8_e4m3fn.safetensors?download=true" \
      cache/comfyui-models/clip/t5xxl_fp8_e4m3fn.safetensors
# NOTA: il repo black-forest-labs e' GATED (richiede login HuggingFace +
# accettazione licenza): wget anonimo puo' fallire con 401/403. In quel caso
# scarica ae.safetensors dal browser (loggato) e salvalo TU in
# cache/comfyui-models/vae/flux_ae.safetensors — il nome finale deve essere
# esattamente questo, e' quello che hermes-extras collega a ComfyUI.
fetch "https://huggingface.co/black-forest-labs/FLUX.1-schnell/resolve/main/ae.safetensors?download=true" \
      cache/comfyui-models/vae/flux_ae.safetensors

echo "### 7/7 — smartmontools drivedb.h (riconoscimento enclosure USB RTL9220) ###"
# SEMPRE ri-scaricato (niente skip: e' piccolo e deve essere fresco). Il db di
# Ubuntu 24.04 non conosce il bridge 0bda:9220 dell'enclosure del 4° disco:
# questo file viene installato al primo boot da 55-smart-drivedb.sh (con check
# sintassi smartctl prima dell'install). Se il download fallisce si tiene
# l'eventuale copia precedente: sul rig resta comunque il fallback -d sntrealtek.
mkdir -p cache/drivedb
if wget -q "https://raw.githubusercontent.com/smartmontools/smartmontools/master/smartmontools/drivedb.h" \
        -O cache/drivedb/drivedb.h.new; then
    _first=$(head -c1 cache/drivedb/drivedb.h.new)
    _size=$(stat -c%s cache/drivedb/drivedb.h.new 2>/dev/null || echo 0)
    if [ "$_first" = "/" ] && [ "$_size" -gt 10000 ] && [ "$_size" -lt 5000000 ]; then
        mv cache/drivedb/drivedb.h.new cache/drivedb/drivedb.h
        if grep -q "0x9220" cache/drivedb/drivedb.h; then
            echo "  [ok  ] drivedb.h aggiornato (contiene l'ID 0x9220 dell'enclosure)"
        else
            echo "  [warn] drivedb.h scaricato ma SENZA 0x9220 (upstream cambiato?) — resta il fallback sntrealtek"
        fi
        DONE=$((DONE+1))
    else
        echo "  [FAIL] drivedb.h scaricato ma sospetto (size=$_size, first='$_first') — scartato" >&2
        rm -f cache/drivedb/drivedb.h.new
        FAILED+=("cache/drivedb/drivedb.h <- github raw (contenuto sospetto)")
    fi
else
    rm -f cache/drivedb/drivedb.h.new
    if [ -f cache/drivedb/drivedb.h ]; then
        echo "  [warn] download fallito, tengo la copia precedente"
    else
        echo "  [FAIL] drivedb.h non scaricato (nessuna copia in cache) — il rig usera' comunque -d sntrealtek" >&2
        FAILED+=("cache/drivedb/drivedb.h <- github raw")
    fi
fi

echo
echo "======================================================"
echo " Riepilogo: scaricati=$DONE  saltati(gia' presenti)=$SKIPPED  falliti=${#FAILED[@]}"
if [ "${#FAILED[@]}" -gt 0 ]; then
    echo " FALLITI (l'URL potrebbe essere cambiato — verificalo nel browser):"
    for f in "${FAILED[@]}"; do echo "   - $f"; done
    echo " Se il file ce l'hai gia' da altra fonte, mettilo a mano nel path indicato."
fi
echo "======================================================"
du -sh cache/nvidia-driver.run cache/cuda-toolkit.run cache/models/*/* cache/comfyui-models/*/* 2>/dev/null
