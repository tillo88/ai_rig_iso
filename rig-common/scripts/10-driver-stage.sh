#!/bin/bash
# =============================================================================
# STAGE 1/4 — Driver NVIDIA (a DUE FASI, per non inchiodare la console)
# Bug sul campo (devin 2026-07-17): installare il .run mentre nouveau e' ANCORA
# caricato (la blacklist vale solo dal boot dopo) fa wedge della console GPU su
# rig multi-GPU -> cursore fisso, ping ok, ssh giu'. Si auto-guariva col reboot
# finale, ma e' un freeze brutto. Percio' due boot separati:
#   FASE A: blacklist nouveau + update-initramfs -> REBOOT (nessun driver qui).
#   FASE B: al boot pulito (nouveau assente) -> installa il .run -> REBOOT.
# NON chiama nvidia-smi qui: il modulo e' attivo solo dopo il reboot di FASE B.
# =============================================================================
set -e
exec >> /var/log/ai-rig-stage-driver.log 2>&1
echo "=== Stage 1 (driver) - $(date) ==="

mkdir -p /var/lib/ai-rig

if [ -f /var/lib/ai-rig/stage-driver-done ]; then
    echo "Stage driver gia' completato, esco."
    exit 0
fi

# ---------------------------------------------------------------------------
# FASE A — blacklist nouveau e riavvia, SENZA installare niente (nessun tocco
# alla GPU: solo initramfs, quindi niente wedge della console).
# ---------------------------------------------------------------------------
if [ ! -f /var/lib/ai-rig/stage-driver-prep-done ]; then
    echo "FASE A: blacklist nouveau + rigenero initramfs, poi reboot."
    cat > /etc/modprobe.d/blacklist-nouveau.conf << 'EOF'
blacklist nouveau
options nouveau modeset=0
EOF
    update-initramfs -u
    touch /var/lib/ai-rig/stage-driver-prep-done
    echo "=== FASE A completata - $(date). Riavvio tra 5s per bootare senza nouveau. ==="
    sleep 5
    systemctl reboot
    exit 0
fi

# ---------------------------------------------------------------------------
# FASE B — boot pulito: verifica che nouveau NON sia caricato, poi installa.
# ---------------------------------------------------------------------------
if lsmod | grep -q '^nouveau'; then
    echo "!!! nouveau ANCORA caricato dopo il reboot di FASE A: NON installo (eviterei" >&2
    echo "!!! il wedge). Controlla /etc/modprobe.d/blacklist-nouveau.conf + initramfs e riavvia." >&2
    exit 1
fi

if [ -f /opt/cache/nvidia-driver.run ]; then
    echo "FASE B: nouveau assente, installo driver NVIDIA..."
    sh /opt/cache/nvidia-driver.run --silent --dkms --no-opengl-files
    systemctl enable nvidia-persistenced.service 2>/dev/null || echo "(nvidia-persistenced non presente, salto — non blocca nulla)"
else
    echo "!!! /opt/cache/nvidia-driver.run non trovato. Impossibile procedere." >&2
    exit 1
fi

rm -f /opt/cache/nvidia-driver.run   # installer usa-e-getta: libera ~400MB (se serve re-install, ri-lancia populate-cache)
touch /var/lib/ai-rig/stage-driver-done
echo "=== Stage 1 completato (FASE B) - $(date). Riavvio tra 5s per attivare il modulo. ==="
sleep 5
systemctl reboot
