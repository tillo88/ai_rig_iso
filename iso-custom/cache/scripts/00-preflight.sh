#!/bin/bash
# =============================================================================
# Esegui questo script SUL RIG ASSEMBLATO (bootato da una live USB Ubuntu
# qualsiasi, anche la stessa ISO in modalita' "Try or Install" prima di lanciare
# l'autoinstall, oppure da un vecchio OS gia' presente).
# Serve a raccogliere i dati reali da mettere in config/disks.env e
# config/network.env PRIMA di generare la ISO definitiva.
# =============================================================================
echo "### DISCHI (usa la colonna SERIAL in config/disks.env) ###"
lsblk -d -o NAME,SIZE,MODEL,SERIAL,TRAN
echo
echo "### Se SERIAL e' vuoto per qualche disco, fallback su by-path: ###"
ls -la /dev/disk/by-path/ 2>/dev/null
echo
echo "### INTERFACCE DI RETE (MAC per config/network.env: LAN_MAC / WOL_MAC) ###"
ip -o link show | awk -F': ' '{print $2}' | grep -Ev '^lo$' | while read -r i; do
    mac=$(cat "/sys/class/net/${i}/address" 2>/dev/null)
    carrier=$(cat "/sys/class/net/${i}/carrier" 2>/dev/null || echo "?")
    echo "  $i  MAC=$mac  link=$carrier"
done
echo
echo "### GPU rilevate (verifica che siano tutte e 7) ###"
lspci | grep -i nvidia
echo
echo "### Se serve smartctl per il serial (dischi che non lo espongono via lsblk): ###"
echo "  sudo apt install -y smartmontools && sudo smartctl -i /dev/sdX | grep -i serial"

# --- Profilo hardware machine-readable, per scripts/recommend-stack.sh (vedi README) ---
PROFILE_OUT="${1:-./hardware-profile.json}"
RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
GPU_JSON=$(nvidia-smi --query-gpu=index,name,memory.total,compute_cap --format=csv,noheader,nounits 2>/dev/null \
    | awk -F', *' '{printf "%s{\"index\":%s,\"name\":\"%s\",\"vram_mb\":%s,\"compute_cap\":\"%s\"}", (NR>1?",":""), $1,$2,$3,$4}')
TOTAL_VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | awk '{s+=$1} END{print s+0}')
DISK_COUNT=$(lsblk -dno TYPE | grep -c disk || echo 0)

cat > "$PROFILE_OUT" << EOFJSON
{
  "ram_gb": ${RAM_GB:-0},
  "disk_count": ${DISK_COUNT:-0},
  "gpu_total_vram_mb": ${TOTAL_VRAM_MB:-0},
  "gpus": [${GPU_JSON}]
}
EOFJSON
echo
echo "### Profilo hardware salvato in: $PROFILE_OUT ###"
cat "$PROFILE_OUT"
