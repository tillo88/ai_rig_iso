#!/bin/bash
# =============================================================================
# scripts/01-wipe-disks.sh
# Da eseguire da una shell live (boot USB -> "Try or Install Ubuntu Server" ->
# Ctrl+Alt+F2 per la shell), PRIMA di lanciare le 3 install autoinstall.
#
# SICUREZZA: whitelist, non blacklist. Wipa SOLO i dischi il cui SERIAL e'
# esplicitamente elencato in disks.env (DEVIN/HERMES/TEACHER). Non tocca nulla
# che non sia in quella lista — quindi non serve "indovinare" quale disco sia
# la chiavetta: la chiavetta semplicemente non e' mai nella whitelist.
# =============================================================================
set -euo pipefail

# Girato nell'ambiente LIVE (prima di qualunque install) — i pacchetti in packages/*.apt
# valgono solo per il sistema installato, NON per questo ambiente. sgdisk/mdadm/lvm2
# di solito ci sono gia' nel live di Subiquity, ma meglio non fidarsi ciecamente.
for tool_pkg in "sgdisk:gdisk" "mdadm:mdadm" "pvs:lvm2"; do
    tool="${tool_pkg%%:*}"; pkg="${tool_pkg##*:}"
    command -v "$tool" &>/dev/null || { echo "Installo $pkg (manca $tool nel live env)..."; apt-get update -qq && apt-get install -y -qq "$pkg"; }
done

DISKS_ENV="${1:-/cdrom/cache/config/disks.env}"
if [ ! -f "$DISKS_ENV" ]; then
    echo "!!! Non trovo $DISKS_ENV. Passa il path come argomento:" >&2
    echo "    sudo bash 01-wipe-disks.sh /percorso/a/disks.env" >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$DISKS_ENV"

resolve_disk() {
    # Serial prima; fallback by-path (audit 2026-07-10: 05-generate-nocloud.sh
    # supporta ROLE_DISK_BYPATH_VAR quando il seriale non e' esposto — tipico
    # dei bridge USB economici — ma il wipe risolveva SOLO via seriale: ora
    # sono coerenti).
    local serial="$1" bypath="$2"
    local disk
    disk=$(lsblk -dno NAME,SERIAL | awk -v s="$serial" '$2==s {print $1}' | head -n1)
    if [ -z "$disk" ] && [ -n "$bypath" ] && [[ "$bypath" != CHANGEME* ]] && [ -e "$bypath" ]; then
        disk=$(basename "$(readlink -f "$bypath")")
    fi
    echo "$disk"
}

declare -A TARGETS=(
    [DEVIN]="$DEVIN_DISK_SERIAL"
    [HERMES]="$HERMES_DISK_SERIAL"
    [TEACHER]="$TEACHER_DISK_SERIAL"
)
declare -A TARGET_BYPATH=(
    [DEVIN]="${DEVIN_DISK_BYPATH:-}"
    [HERMES]="${HERMES_DISK_BYPATH:-}"
    [TEACHER]="${TEACHER_DISK_BYPATH:-}"
)

# Guardia seriali duplicati (audit 2026-07-10): stesso seriale su due ruoli =
# stesso disco wipato/installato due volte. Fermati subito.
if [ "$DEVIN_DISK_SERIAL" = "$HERMES_DISK_SERIAL" ] || \
   [ "$DEVIN_DISK_SERIAL" = "$TEACHER_DISK_SERIAL" ] || \
   [ "$HERMES_DISK_SERIAL" = "$TEACHER_DISK_SERIAL" ]; then
    echo "!!! Seriali DUPLICATI in disks.env: due ruoli puntano allo stesso disco." >&2
    echo "!!! Esco senza toccare nulla." >&2
    exit 1
fi

# Guardia 4° disco condiviso (audit 2026-07-10, punto 6): il disco AutoMem/backup
# non deve MAI essere nella whitelist di wipe come disco ruolo.
SHARED_ENV="$(dirname "$DISKS_ENV")/shared-disk.env"
if [ -f "$SHARED_ENV" ]; then
    # shellcheck disable=SC1090
    source "$SHARED_ENV"
    if [ -n "${SHARED_DISK_SERIAL:-}" ] && [[ "${SHARED_DISK_SERIAL}" != CHANGEME* ]]; then
        for role_serial in "$DEVIN_DISK_SERIAL" "$HERMES_DISK_SERIAL" "$TEACHER_DISK_SERIAL"; do
            if [ "$SHARED_DISK_SERIAL" = "$role_serial" ]; then
                echo "!!! Il disco CONDIVISO (AutoMem/backup) coincide con un disco ruolo ($SHARED_DISK_SERIAL)." >&2
                echo "!!! Esco senza toccare nulla — correggi shared-disk.env o disks.env." >&2
                exit 1
            fi
        done
    fi
fi

declare -A RESOLVED
echo "=== Dischi nella whitelist (da $DISKS_ENV) ==="
for role in "${!TARGETS[@]}"; do
    serial="${TARGETS[$role]}"
    if [ -z "$serial" ] || [[ "$serial" == CHANGEME* ]]; then
        echo "!!! $role: seriale non compilato in disks.env. Esco senza toccare nulla." >&2
        exit 1
    fi
    disk=$(resolve_disk "$serial" "${TARGET_BYPATH[$role]}")
    if [ -z "$disk" ]; then
        echo "!!! $role: nessun disco trovato con serial '$serial' (ne' via by-path). Esco senza toccare nulla." >&2
        exit 1
    fi
    RESOLVED[$role]="$disk"
done

# Anche i dischi RISOLTI devono essere distinti (caso: seriali diversi in env
# ma by-path che punta allo stesso device fisico).
if [ "$(printf '%s\n' "${RESOLVED[@]}" | sort -u | wc -l)" -ne "${#RESOLVED[@]}" ]; then
    echo "!!! Due ruoli risolvono sullo STESSO device: ${RESOLVED[*]}. Esco senza toccare nulla." >&2
    exit 1
fi

for role in "${!RESOLVED[@]}"; do
    disk="${RESOLVED[$role]}"
    echo "  $role -> /dev/$disk  ($(lsblk -dno SIZE,MODEL "/dev/$disk"))"
done

echo
echo "=== Guardia anti-chiavetta ==="
for role in "${!RESOLVED[@]}"; do
    disk="${RESOLVED[$role]}"
    # Se una qualunque partizione di questo disco e' montata su /cdrom o e' iso9660,
    # e' quasi certamente il supporto di boot: fermati, qualcosa non torna in disks.env.
    if lsblk -no MOUNTPOINT,FSTYPE "/dev/$disk" | grep -qE '/cdrom|iso9660'; then
        echo "!!! /dev/$disk sembra essere il supporto di boot (montato su /cdrom o iso9660)." >&2
        echo "!!! disks.env ha un seriale sbagliato. Esco senza toccare nulla." >&2
        exit 1
    fi
done
echo "OK: nessuno dei 3 dischi target risulta essere il supporto di boot."

echo
echo "=== ATTENZIONE ==="
echo "Sto per CANCELLARE IRREVERSIBILMENTE tabelle di partizione, filesystem,"
echo "firme RAID/LVM su questi ${#RESOLVED[@]} dischi:"
for role in "${!RESOLVED[@]}"; do
    echo "  - $role: /dev/${RESOLVED[$role]}"
done
echo
read -rp "Scrivi WIPE (maiuscolo) per confermare, qualunque altra cosa annulla: " confirm
if [ "$confirm" != "WIPE" ]; then
    echo "Annullato. Nessuna modifica effettuata."
    exit 0
fi

for role in "${!RESOLVED[@]}"; do
    disk="/dev/${RESOLVED[$role]}"
    echo ">>> Pulizia $role ($disk)..."

    # Ferma eventuali RAID software che usano questo disco
    for md in /dev/md*; do
        [ -e "$md" ] || continue
        if mdadm --detail "$md" 2>/dev/null | grep -q "$disk"; then
            mdadm --stop "$md" || true
        fi
    done
    mdadm --zero-superblock "${disk}"* 2>/dev/null || true

    # Disattiva eventuali volumi LVM che usano questo disco
    for pv in $(pvs --noheadings -o pv_name 2>/dev/null | tr -d ' '); do
        if [[ "$pv" == "$disk"* ]]; then
            vg=$(pvs --noheadings -o vg_name "$pv" 2>/dev/null | tr -d ' ')
            [ -n "$vg" ] && vgremove -f "$vg" 2>/dev/null || true
            pvremove -ff -y "$pv" 2>/dev/null || true
        fi
    done

    wipefs -a "$disk" || true
    sgdisk --zap-all "$disk" || true

    # TRIM completo se SSD/NVMe (ROTA=0) — opzionale, salta silenziosamente sui rotativi
    if [ "$(lsblk -dno ROTA "$disk" 2>/dev/null)" = "0" ]; then
        blkdiscard "$disk" 2>/dev/null || echo "  (blkdiscard non supportato su $disk, continuo)"
    fi

    partprobe "$disk" 2>/dev/null || blockdev --rereadpt "$disk" 2>/dev/null || true
    echo "  $role: fatto."
done

echo
echo "=== Completato. Dischi pronti per l'autoinstall (DEVIN/HERMES/TEACHER). ==="
lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE "${RESOLVED[DEVIN]:+/dev/${RESOLVED[DEVIN]}}" \
    "/dev/${RESOLVED[HERMES]}" "/dev/${RESOLVED[TEACHER]}" 2>/dev/null || true
