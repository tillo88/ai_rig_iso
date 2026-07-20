#!/bin/bash
# =============================================================================
# scripts/recommend-stack.sh [hardware-profile.json] [--llm]
#
# Consuma il profilo generato da 00-preflight.sh. Due modalita':
#  - default: regole rapide, nessuna dipendenza, sempre disponibile
#  - --llm: manda il profilo a un endpoint OpenAI-compatible (locale o esterno)
#           per un consiglio in linguaggio naturale, aggiornato rispetto a
#           quello che esiste OGGI (le regole statiche invecchiano in mesi,
#           i modelli nuovi no) — utile soprattutto per un secondo rig futuro
#           con hardware diverso dal tuo attuale.
#
# Onesta': la parte "regole" e' deliberatamente prudente e generica (fasce di
# VRAM), NON un catalogo di modelli specifici che tra 3 mesi sarebbe gia'
# superato. Per un consiglio su modelli/quant CONCRETI e aggiornati, usa --llm
# puntato a un modello con web search, o chiedimelo direttamente in chat.
# =============================================================================
set -euo pipefail

PROFILE="${1:-./hardware-profile.json}"
USE_LLM=false
[ "${2:-}" = "--llm" ] && USE_LLM=true
[ "${1:-}" = "--llm" ] && { USE_LLM=true; PROFILE="./hardware-profile.json"; }

[ -f "$PROFILE" ] || { echo "Non trovo $PROFILE. Esegui prima scripts/00-preflight.sh" >&2; exit 1; }

RAM_GB=$(python3 -c "import json;print(json.load(open('$PROFILE'))['ram_gb'])")
VRAM_MB=$(python3 -c "import json;print(json.load(open('$PROFILE'))['gpu_total_vram_mb'])")
GPU_COUNT=$(python3 -c "import json;print(len(json.load(open('$PROFILE'))['gpus']))")
VRAM_GB=$((VRAM_MB / 1024))

echo "=== Profilo: RAM ${RAM_GB}GB | VRAM totale ~${VRAM_GB}GB su ${GPU_COUNT} GPU ==="

if [ "$USE_LLM" = false ]; then
    echo
    echo "--- Regole rapide (fasce prudenti, non un catalogo modelli) ---"
    if   [ "$VRAM_GB" -ge 60 ]; then TIER="grande: dense 70B+ Q4-Q5, o MoE 100B+ classe"
    elif [ "$VRAM_GB" -ge 40 ]; then TIER="medio-grande: dense 30-40B Q5-Q6, o MoE 35-70B classe A3B-A8B"
    elif [ "$VRAM_GB" -ge 20 ]; then TIER="medio: dense 13-20B Q5-Q6, o MoE ~20-35B classe A2-A3B"
    elif [ "$VRAM_GB" -ge 10 ]; then TIER="piccolo: dense 7-8B Q6-Q8, o MoE piccoli"
    else TIER="molto piccolo: 3B-7B quantizzati aggressivi (Q4), aspettati compromessi"
    fi
    echo "Fascia indicativa: $TIER"
    echo "Per nomi di modelli CONCRETI e aggiornati ad oggi, usa --llm oppure chiedi in chat."
    exit 0
fi

# --- Modalita' LLM: manda il profilo a un endpoint OpenAI-compatible ---
LLM_BASE_URL="${AI_RIG_LLM_BASE_URL:-http://localhost:8080/v1}"
LLM_API_KEY="${AI_RIG_LLM_API_KEY:-not-needed}"
LLM_MODEL="${AI_RIG_LLM_MODEL:-local}"

PROMPT="Ho un rig con ${RAM_GB}GB RAM e ${GPU_COUNT} GPU per un totale di circa ${VRAM_GB}GB VRAM (dettaglio: $(cat "$PROFILE")). Suggerisci, in 5 righe, che classe/dimensione di modelli LLM locali (GGUF, llama.cpp) posso far girare comodamente con -ngl 999 e --tensor-split, e un'idea di context size realistico. Sii specifico su compromessi qualita'/velocita'."

curl -s "${LLM_BASE_URL}/chat/completions" \
    -H "Content-Type: application/json" \
    -d "$(python3 -c "
import json,sys
print(json.dumps({'model': '$LLM_MODEL', 'messages': [{'role':'user','content': '''$PROMPT'''}]}))
")" | python3 -c "
import json,sys
try:
    d = json.load(sys.stdin)
    print(d['choices'][0]['message']['content'])
except Exception as e:
    print('Errore chiamando l\'endpoint LLM:', e, file=sys.stderr)
    print('Verifica AI_RIG_LLM_BASE_URL (default http://localhost:8080/v1) o esporta una API key esterna con AI_RIG_LLM_API_KEY/AI_RIG_LLM_BASE_URL.', file=sys.stderr)
"
