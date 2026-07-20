#!/bin/bash
set -e
REPORT="/var/log/ai-rig-verify.log"
ROLE=$(cat /etc/ai-rig/role 2>/dev/null || echo "unknown")
: > "$REPORT"
echo "=== AI Rig Verification (ruolo: $ROLE) - $(date) ===" | tee -a "$REPORT"

if [ -f "/etc/ai-rig/${ROLE}.env" ]; then
    # shellcheck disable=SC1090
    source "/etc/ai-rig/${ROLE}.env"
fi
PORT="${ROLE_LLAMA_PORT:-8080}"
http_code() {
    local code
    code="$(curl -sS -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || true)"
    [ -n "$code" ] && echo "$code" || echo 000
}

echo "Attendo le API (max 15 min)..." | tee -a "$REPORT"
for ((i=1; i<=180; i++)); do
    if ! systemctl is-active --quiet "llama-server@${ROLE}.service"; then
        echo "❌ llama-server@${ROLE} non attivo/crashato. Interrompo attesa." | tee -a "$REPORT"
        break
    fi
    if curl -fs "http://localhost:${PORT}/health" >/dev/null 2>&1; then
        echo "✅ API attive dopo $((i*5))s." | tee -a "$REPORT"
        break
    fi
    sleep 5
done

echo -e "\n--- llama-server@${ROLE} ---" | tee -a "$REPORT"
systemctl is-active --quiet "llama-server@${ROLE}.service" \
    && echo "✅ ATTIVO" | tee -a "$REPORT" || echo "❌ NON ATTIVO" | tee -a "$REPORT"

HEALTH="$(http_code "http://localhost:${PORT}/health")"
echo "API Health: HTTP ${HEALTH}" | tee -a "$REPORT"

echo -e "\n--- Understory (memoria OKF condivisa) ---" | tee -a "$REPORT"
USTORY_HEALTH="$(http_code "http://127.0.0.1:3800/api/tree")"
if [ "$USTORY_HEALTH" = "200" ]; then
    echo "✅ Understory attivo (HTTP 200)" | tee -a "$REPORT"
else
    echo "⚠️ Understory non pronto (HTTP ${USTORY_HEALTH}); controlla /var/log/ai-rig-stage-understory.log" | tee -a "$REPORT"
fi
if [ -d /mnt/ai-rig-shared/understory/bundle/.git ]; then
    echo "✅ Bundle condiviso versionato con Git" | tee -a "$REPORT"
else
    echo "⚠️ Bundle Understory/Git non trovato" | tee -a "$REPORT"
fi
LIBRARIAN_HEALTH="$(http_code "http://127.0.0.1:3810/health")"
if [ "$LIBRARIAN_HEALTH" = "200" ]; then
    echo "✅ Librarian MCP attivo su 127.0.0.1:3810" | tee -a "$REPORT"
else
    echo "⚠️ Librarian non pronto (HTTP ${LIBRARIAN_HEALTH})" | tee -a "$REPORT"
fi

echo -e "\n--- GPU ---" | tee -a "$REPORT"
LIVE_GPU_COUNT=""
if command -v nvidia-smi &> /dev/null; then
    nvidia-smi --query-gpu=index,name,memory.total,memory.used,temperature.gpu --format=csv,noheader | tee -a "$REPORT"
    LIVE_GPU_COUNT=$(nvidia-smi --query-gpu=count --format=csv,noheader | head -n1 | xargs)
else
    echo "❌ nvidia-smi non trovato" | tee -a "$REPORT"
fi

echo -e "\n--- Config GPU (/etc/ai-rig/gpu.env) ---" | tee -a "$REPORT"
if [ -f /etc/ai-rig/gpu.env ]; then
    # shellcheck disable=SC1091
    source /etc/ai-rig/gpu.env
    cat /etc/ai-rig/gpu.env | tee -a "$REPORT"
    if [ -n "$LIVE_GPU_COUNT" ]; then
        [ "$LIVE_GPU_COUNT" = "$GPU_COUNT" ] \
            && echo "✅ GPU live ($LIVE_GPU_COUNT) = config ($GPU_COUNT)" | tee -a "$REPORT" \
            || echo "❌ GPU live ($LIVE_GPU_COUNT) DIVERSE da config ($GPU_COUNT) — scheda sparita/non rilevata?" | tee -a "$REPORT"
    fi
else
    echo "❌ gpu.env non trovato (stage 3 non completato?)" | tee -a "$REPORT"
fi

echo -e "\n--- SMART 4° disco condiviso (enclosure USB RTL9220) ---" | tee -a "$REPORT"
if command -v smartctl >/dev/null 2>&1 && [ -x /usr/local/bin/ai-rig-smart.sh ]; then
    # -H = solo salute: veloce, non stressa il bridge. Dettagli: ai-rig-smart.sh -x
    if SMART_OUT=$(/usr/local/bin/ai-rig-smart.sh -H 2>/dev/null); then
        if echo "$SMART_OUT" | grep -qiE "PASSED|OK"; then
            echo "✅ SMART: salute OK" | tee -a "$REPORT"
        else
            echo "❌ SMART: controlla! ($(echo "$SMART_OUT" | grep -i result | head -n1))" | tee -a "$REPORT"
        fi
    else
        echo "⚠️ SMART non leggibile (4° disco staccato? vedi ai-rig-smart.sh)" | tee -a "$REPORT"
    fi
else
    echo "⚠️ smartctl/ai-rig-smart.sh non disponibili" | tee -a "$REPORT"
fi


echo -e "\n--- Spazio dischi ---" | tee -a "$REPORT"
df -hT / /mnt/ai-rig-shared 2>&1 | tee -a "$REPORT"
ROOT_USE="$(df -P / | awk 'NR==2 {gsub(/%/, "", $5); print $5}')"
if [ "${ROOT_USE:-0}" -ge 90 ]; then
    echo "❌ Root critica: ${ROOT_USE}% usato" | tee -a "$REPORT"
elif [ "${ROOT_USE:-0}" -ge 80 ]; then
    echo "⚠️ Root alta: ${ROOT_USE}% usato" | tee -a "$REPORT"
else
    echo "✅ Spazio root nella norma: ${ROOT_USE}% usato" | tee -a "$REPORT"
fi
if mountpoint -q /mnt/ai-rig-shared; then
    echo "✅ Disco condiviso montato" | tee -a "$REPORT"
else
    echo "❌ Disco condiviso NON montato" | tee -a "$REPORT"
fi
for path in /var/lib/containerd /var/lib/docker /opt/cache; do
    [ -e "$path" ] && du -sh "$path" 2>/dev/null | tee -a "$REPORT" || true
done

echo -e "\n--- RAM ---" | tee -a "$REPORT"
free -h | tee -a "$REPORT"

echo -e "\n--- Modello (${ROLE}) ---" | tee -a "$REPORT"
ls -lh "/opt/models/${ROLE}/"*.gguf 2>/dev/null | tee -a "$REPORT" || echo "⚠️ Nessun modello trovato in /opt/models/${ROLE}/" | tee -a "$REPORT"

echo -e "\n--- Processo llama-server ---" | tee -a "$REPORT"
if pgrep -fa llama-server > /tmp/llama_proc.txt; then
    cat /tmp/llama_proc.txt | tee -a "$REPORT"
else
    echo "❌ Processo llama-server non trovato" | tee -a "$REPORT"
fi

echo -e "\n--- Tensor Split ---" | tee -a "$REPORT"
if [ -n "${TENSOR_SPLIT:-}" ]; then
    IFS=',' read -ra SPLIT <<< "$TENSOR_SPLIT"
    CHECK_AGAINST="${LIVE_GPU_COUNT:-$GPU_COUNT}"
    [ "${#SPLIT[@]}" -eq "$CHECK_AGAINST" ] \
        && echo "✅ Tensor split coerente (${#SPLIT[@]} valori / $CHECK_AGAINST GPU)" | tee -a "$REPORT" \
        || echo "❌ Tensor split NON coerente (${#SPLIT[@]} valori / $CHECK_AGAINST GPU)" | tee -a "$REPORT"
else
    echo "⚠️ TENSOR_SPLIT non definito" | tee -a "$REPORT"
fi

echo -e "\n=== VERIFICA COMPLETATA — report in $REPORT ===" | tee -a "$REPORT"
