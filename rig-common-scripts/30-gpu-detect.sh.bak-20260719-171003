#!/bin/bash
# =============================================================================
# STAGE 3/4 — Rilevamento GPU, ordinamento CUDA_VISIBLE_DEVICES, tensor-split
# Scrive /etc/ai-rig/gpu.env, letto da ogni start-llama-<ruolo>.sh.
# =============================================================================
set -euo pipefail
exec >> /var/log/ai-rig-stage-gpudetect.log 2>&1

echo "=== Stage 3 (gpu-detect) - $(date) ==="

mkdir -p /var/lib/ai-rig /etc/ai-rig

if [ -f /var/lib/ai-rig/stage-gpudetect-done ]; then
    echo "Stage gpu-detect gia' completato; rieseguo il rilevamento live."
fi

if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "!!! nvidia-smi non trovato, esco." >&2
    exit 1
fi

RAM_TOTAL=$(free -g | awk '/^Mem:/{print $2}')

GPU_LIST=$(nvidia-smi \
    --query-gpu=index,name,memory.total,power.default_limit \
    --format=csv,noheader,nounits)

GPU_COUNT=$(grep -cve '^[[:space:]]*$' <<< "$GPU_LIST")

if [ "$GPU_COUNT" -lt 1 ]; then
    echo "!!! Nessuna GPU NVIDIA rilevata." >&2
    exit 1
fi

echo "RAM: ${RAM_TOTAL} GB | GPU rilevate: $GPU_COUNT"

declare -a GPU_INDICES GPU_NAMES GPU_VRAM GPU_POWER

while IFS=',' read -r idx name vram power; do
    idx=$(echo "$idx" | xargs)
    name=$(echo "$name" | xargs)
    vram=$(echo "$vram" | xargs)
    power=$(echo "$power" | xargs)

    GPU_INDICES+=("$idx")
    GPU_NAMES+=("$name")
    GPU_VRAM+=("$vram")
    GPU_POWER+=("$power")

    echo "GPU $idx: $name | VRAM: ${vram}MB | power default: ${power}W"
done <<< "$GPU_LIST"

A2000_FOUND="false"
A2000_INDEX=""
TOTAL_VRAM=0

for i in "${!GPU_INDICES[@]}"; do
    vram_int=$(echo "${GPU_VRAM[$i]}" | cut -d'.' -f1)
    TOTAL_VRAM=$((TOTAL_VRAM + vram_int))

    if [[ "${GPU_NAMES[$i]}" == *"A2000"* ]]; then
        A2000_FOUND="true"
        A2000_INDEX="${GPU_INDICES[$i]}"
    fi
done

echo "VRAM totale: ${TOTAL_VRAM} MB (~$((TOTAL_VRAM / 1024)) GB)"
echo "A2000: $A2000_FOUND ($A2000_INDEX)"

# -----------------------------------------------------------------------------
# Profilo noto del rig a 7 GPU.
#
# CUDA0 ospita anche mmproj e buffer principali: deve essere la GTX 1080 Ti,
# non la RTX A2000 da 6 GB.
#
# Gli indici vengono ricavati dai nomi delle GPU, quindi il profilo continua
# a funzionare anche se il BIOS cambia la numerazione PCIe.
# -----------------------------------------------------------------------------

declare -a \
    IDX_1080TI \
    IDX_1080 \
    IDX_A2000 \
    IDX_1660S \
    IDX_1660TI

for i in "${!GPU_INDICES[@]}"; do
    idx="${GPU_INDICES[$i]}"
    name="${GPU_NAMES[$i]}"

    power_num=$(
        awk -v p="${GPU_POWER[$i]}" \
            'BEGIN { printf "%d", p + 0 }'
    )

    case "$name" in
        *"GTX 1080 Ti"*)
            IDX_1080TI+=("$idx")
            ;;
        *"GTX 1080"*)
            IDX_1080+=("$idx")
            ;;
        *"RTX A2000"*)
            IDX_A2000+=("$idx")
            ;;
        *"GTX 1660 SUPER"*)
            IDX_1660S+=("${power_num}|${idx}")
            ;;
        *"GTX 1660 Ti"*)
            IDX_1660TI+=("$idx")
            ;;
    esac
done

GPU_PROFILE="generic"

if [ "$GPU_COUNT" -eq 7 ] \
   && [ "${#IDX_1080TI[@]}" -eq 1 ] \
   && [ "${#IDX_1080[@]}" -eq 2 ] \
   && [ "${#IDX_A2000[@]}" -eq 1 ] \
   && [ "${#IDX_1660S[@]}" -eq 2 ] \
   && [ "${#IDX_1660TI[@]}" -eq 1 ]; then

    mapfile -t SORTED_1080 < <(
        printf '%s\n' "${IDX_1080[@]}" |
        sort -n
    )

    # Le due 1660 SUPER vengono ordinate per power limit:
    # quella da 140 W precede quella da 125 W.
    mapfile -t SORTED_1660S < <(
        printf '%s\n' "${IDX_1660S[@]}" |
        sort -t'|' -k1,1nr -k2,2n
    )

    ORDERED_INDICES=("${IDX_1080TI[0]}")
    ORDERED_INDICES+=("${SORTED_1080[@]}")
    ORDERED_INDICES+=("${IDX_A2000[0]}")

    for entry in "${SORTED_1660S[@]}"; do
        ORDERED_INDICES+=("${entry##*|}")
    done

    ORDERED_INDICES+=("${IDX_1660TI[0]}")

    CUDA_ORDER=$(IFS=,; echo "${ORDERED_INDICES[*]}")

    # CUDA0 ha una quota leggermente inferiore perché ospita anche
    # mmproj e buffer principali.
    TENSOR_SPLIT="0.16,0.17,0.17,0.125,0.125,0.125,0.125"

    GPU_PROFILE="tillo-7gpu-v1"

    echo "Profilo noto 7 GPU applicato: $GPU_PROFILE"
else
    # Fallback generico:
    #   1. VRAM decrescente
    #   2. power limit decrescente
    #   3. indice crescente
    #
    # Così CUDA0 tende ad avere il margine VRAM maggiore.
    declare -a SORTABLE_GPUS ORDERED_INDICES

    for i in "${!GPU_INDICES[@]}"; do
        vram_int=$(echo "${GPU_VRAM[$i]}" | cut -d'.' -f1)

        power_num=$(
            awk -v p="${GPU_POWER[$i]}" \
                'BEGIN { printf "%d", p + 0 }'
        )

        SORTABLE_GPUS+=(
            "${vram_int}|${power_num}|${GPU_INDICES[$i]}"
        )
    done

    mapfile -t SORTED_GPUS < <(
        printf '%s\n' "${SORTABLE_GPUS[@]}" |
        sort -t'|' -k1,1nr -k2,2nr -k3,3n
    )

    for entry in "${SORTED_GPUS[@]}"; do
        ORDERED_INDICES+=("${entry##*|}")
    done

    CUDA_ORDER=$(IFS=,; echo "${ORDERED_INDICES[*]}")

    per_gpu=$(echo "scale=6; 1.0 / $GPU_COUNT" | bc)
    TENSOR_SPLIT=""

    for ((i=0; i<GPU_COUNT; i++)); do
        TENSOR_SPLIT="${TENSOR_SPLIT}${per_gpu},"
    done

    TENSOR_SPLIT="${TENSOR_SPLIT%,}"

    echo "Profilo generico: ordine per VRAM/potenza e split uniforme."
fi

echo "Ordine CUDA automatico: $CUDA_ORDER"
echo "Tensor split automatico: $TENSOR_SPLIT"

# -----------------------------------------------------------------------------
# Override persistente facoltativo.
#
# Il file non viene eseguito come shell: vengono lette esclusivamente
# CUDA_VISIBLE_DEVICES e TENSOR_SPLIT.
# -----------------------------------------------------------------------------

GPU_OVERRIDE_FILE="/etc/ai-rig/gpu.override.env"

if [ -r "$GPU_OVERRIDE_FILE" ]; then
    override_cuda=""
    override_split=""

    while IFS='=' read -r key value; do
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)

        value="${value%\"}"
        value="${value#\"}"
        value="${value%\'}"
        value="${value#\'}"

        case "$key" in
            CUDA_VISIBLE_DEVICES)
                override_cuda="$value"
                ;;
            TENSOR_SPLIT)
                override_split="$value"
                ;;
        esac
    done < "$GPU_OVERRIDE_FILE"

    if [ -n "$override_cuda" ]; then
        CUDA_ORDER="$override_cuda"
    fi

    if [ -n "$override_split" ]; then
        TENSOR_SPLIT="$override_split"
    fi

    GPU_PROFILE="${GPU_PROFILE}+override"

    echo "Override GPU applicato da $GPU_OVERRIDE_FILE"
fi

# Validazione minima: ordine e split devono contenere esattamente
# un elemento per ciascuna GPU.

IFS=',' read -r -a CUDA_FIELDS <<< "$CUDA_ORDER"
IFS=',' read -r -a SPLIT_FIELDS <<< "$TENSOR_SPLIT"

if [ "${#CUDA_FIELDS[@]}" -ne "$GPU_COUNT" ]; then
    echo \
        "!!! CUDA_VISIBLE_DEVICES contiene ${#CUDA_FIELDS[@]} elementi, attesi $GPU_COUNT." \
        >&2
    exit 1
fi

if [ "${#SPLIT_FIELDS[@]}" -ne "$GPU_COUNT" ]; then
    echo \
        "!!! TENSOR_SPLIT contiene ${#SPLIT_FIELDS[@]} elementi, attesi $GPU_COUNT." \
        >&2
    exit 1
fi

cat > /etc/ai-rig/gpu.env << EOFGPU
GPU_COUNT=$GPU_COUNT
TOTAL_VRAM_MB=$TOTAL_VRAM
CUDA_VISIBLE_DEVICES=$CUDA_ORDER
TENSOR_SPLIT=$TENSOR_SPLIT
A2000_FOUND=$A2000_FOUND
A2000_INDEX=$A2000_INDEX
RAM_GB=$RAM_TOTAL
GPU_PROFILE=$GPU_PROFILE
EOFGPU

chmod 644 /etc/ai-rig/gpu.env
touch /var/lib/ai-rig/stage-gpudetect-done

echo "Configurazione finale:"
echo "  CUDA_VISIBLE_DEVICES=$CUDA_ORDER"
echo "  TENSOR_SPLIT=$TENSOR_SPLIT"
echo "  GPU_PROFILE=$GPU_PROFILE"
echo "=== Stage 3 completato - $(date) ==="
