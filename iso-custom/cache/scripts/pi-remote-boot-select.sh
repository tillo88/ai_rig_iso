#!/bin/bash
# =============================================================================
# Gira SUL RASPBERRY PI. ALTERNATIVA CLI al bot Telegram (che fa la stessa cosa con
# i comandi /devin /hermes /teacher). Utile per cron/script; per l'uso quotidiano
# usa il bot.
# Uso: pi-remote-boot-select.sh <devin|hermes|teacher>
#
# AGGIORNATO 2026-07-15 — COLD BOOT: con 7 GPU il reboot CALDO puo' bloccarsi
# sul logo MSI (reset PCIe incompleto dopo stress, visto sul campo dopo
# gpu-burn). Il cambio ruolo ora fa:
#   1. sul rig: ai-rig-select-role.sh <ruolo> --poweroff
#      (scrive il grubenv del GRUB CENTRALE di devin — anche se il ruolo attivo
#      e' hermes/teacher — VERIFICA, poi spegne; se fallisce NON spegne nulla)
#   2. attesa che il rig sia DAVVERO offline (non timer fisso dal poweroff)
#   3. COLD_WAIT secondi di scarica/assestamento PCIe
#   4. WOL ripetuto x3
#   5. attesa boot + conferma ruolo via SSH
#
# Richiede: chiave SSH del bot gia' autorizzata su tutti e 3 gli utenti tillo
# (vedi cache/ai-rig-bot.pub nel progetto ISO), wakeonlan installato sul Pi,
# e il sudoers NOPASSWD bakeato dalla ISO (/etc/sudoers.d/ai-rig-bot).
# =============================================================================
set -euo pipefail

TARGET="${1:?Uso: $0 <devin|hermes|teacher>}"
RIG_MAC="2c:f0:5d:56:08:bc"          # = WOL_MAC in config/network.env
RIG_IP="192.168.1.100"               # = STATIC_IP in config/network.env
RIG_USER="tillo"
SSH_OPTS="-o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i /home/pi/.ssh/ai_rig"

COLD_WAIT=120        # secondi a rig spento prima del WOL
OFFLINE_TIMEOUT=180  # max attesa spegnimento reale
ONLINE_TIMEOUT=300   # max attesa boot dopo WOL

case "$TARGET" in
    devin|hermes|teacher) ;;
    *) echo "ERRORE: ruolo sconosciuto '$TARGET'" >&2; exit 1 ;;
esac

is_up()        { ssh $SSH_OPTS "${RIG_USER}@${RIG_IP}" true 2>/dev/null; }
pingable()     { ping -c 1 -W 2 "$RIG_IP" >/dev/null 2>&1; }
current_role() { ssh $SSH_OPTS "${RIG_USER}@${RIG_IP}" cat /etc/ai-rig/role 2>/dev/null; }
wol_burst()    { for i in 1 2 3; do wakeonlan "$RIG_MAC"; sleep 2; done; }

wait_online() {
    local deadline=$(( $(date +%s) + $1 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        sleep 5
        pingable && return 0
    done
    return 1
}

wait_offline() {
    # 2 ping falliti consecutivi = spento (uno solo puo' essere un pacchetto perso)
    local deadline=$(( $(date +%s) + $1 )) misses=0
    while [ "$(date +%s)" -lt "$deadline" ]; do
        sleep 5
        if pingable; then misses=0; else
            misses=$((misses+1))
            [ "$misses" -ge 2 ] && return 0
        fi
    done
    return 1
}

# --- Rig spento? Accendi il default e riparti da li' ---
if ! is_up; then
    echo "Rig spento. Invio WOL (x3)..."
    wol_burst
    echo "Attendo il boot del ruolo salvato/default (max $((ONLINE_TIMEOUT/60)) min)..."
    wait_online "$ONLINE_TIMEOUT" || { echo "!!! Il rig non risponde dopo il WOL." >&2; exit 1; }
    # margine per SSH
    for i in $(seq 1 12); do is_up && break; sleep 5; done
fi

is_up || { echo "!!! Rig pinga ma SSH non risponde. Controllo manuale." >&2; exit 1; }

CURRENT=$(current_role || echo "sconosciuto")
echo "Ruolo attualmente attivo: $CURRENT"

if [ "$CURRENT" = "$TARGET" ]; then
    echo "Gia' sul ruolo richiesto ($TARGET). Nulla da fare."
    exit 0
fi

# --- 1) Selezione ruolo + poweroff (verificata sul rig; se fallisce NON spegne) ---
echo "Imposto prossimo boot = $TARGET e spengo (cold boot)..."
if ! ssh $SSH_OPTS "${RIG_USER}@${RIG_IP}" "sudo /usr/local/bin/ai-rig-select-role.sh '${TARGET}' --poweroff"; then
    echo "!!! Selezione ruolo FALLITA: il rig e' rimasto com'era, niente e' stato spento." >&2
    exit 1
fi

# --- 2) Attesa spegnimento reale ---
echo "Attendo che il rig sia davvero offline (max ${OFFLINE_TIMEOUT}s)..."
wait_offline "$OFFLINE_TIMEOUT" || {
    echo "!!! Il rig risponde ancora al ping: non mando WOL. Verifica a mano." >&2
    exit 1
}

# --- 3) Scarica/assestamento PCIe ---
echo "Rig spento. Attesa ${COLD_WAIT}s (scarica condensatori / reset PCIe, anti-blocco logo MSI)..."
sleep "$COLD_WAIT"

# --- 4) Riaccensione ---
echo "Invio WOL (x3)..."
wol_burst

# --- 5) Conferma ---
echo "Attendo che ${TARGET} risponda (max $((ONLINE_TIMEOUT/60)) min)..."
wait_online "$ONLINE_TIMEOUT" || {
    echo "!!! Il rig non risponde dopo il WOL. Se e' fermo sul logo MSI: guarda gli" >&2
    echo "!!! EZ Debug LED (VGA = GPU/riser) — vedi docs/POST-BIOS-NOTES.md." >&2
    exit 1
}
for i in $(seq 1 24); do
    if is_up && [ "$(current_role || true)" = "$TARGET" ]; then
        echo "✅ Cold boot completato. Rig ora su ruolo: $TARGET"
        exit 0
    fi
    sleep 5
done
echo "!!! Rig acceso ma ruolo non confermato ($TARGET atteso). Verifica manualmente." >&2
exit 1
