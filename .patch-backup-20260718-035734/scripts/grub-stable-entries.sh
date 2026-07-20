#!/bin/bash
# =============================================================================
# grub-stable-entries.sh — crea su DEVIN le entry stabili devin/hermes/teacher.
# DEVIN carica direttamente kernel/initrd della propria /boot; HERMES e TEACHER
# caricano il grub.cfg presente sulla rispettiva partizione /boot.
# =============================================================================
set -Eeuo pipefail
[ "$(id -u)" -eq 0 ] || { echo "!!! Esegui con sudo/root." >&2; exit 1; }

ROLE="$(cat /etc/ai-rig/role 2>/dev/null || true)"
[ "$ROLE" = "devin" ] || {
    echo "!!! grub-stable-entries.sh deve girare su DEVIN, ruolo attivo: '${ROLE:-sconosciuto}'." >&2
    exit 1
}

CONFIG_LOCAL="$(dirname "$0")/../config/disks.env"
if [ -f "$CONFIG_LOCAL" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_LOCAL"
elif [ -f /opt/cache/config/disks.env ]; then
    # shellcheck disable=SC1091
    source /opt/cache/config/disks.env
else
    echo "!!! disks.env non trovato." >&2
    exit 1
fi

if [ "$DEVIN_DISK_SERIAL" = "$HERMES_DISK_SERIAL" ] \
   || [ "$DEVIN_DISK_SERIAL" = "$TEACHER_DISK_SERIAL" ] \
   || [ "$HERMES_DISK_SERIAL" = "$TEACHER_DISK_SERIAL" ]; then
    echo "!!! Seriali duplicati in disks.env." >&2
    exit 1
fi

trim() { awk '{$1=$1; print}' <<<"${1:-}"; }
_smart_serial() {
    local dev="$1" dtype="$2"
    smartctl -i -d "$dtype" "$dev" 2>/dev/null \
        | awk -F: '/^Serial Number:/{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}'
}

disk_for_serial() {
    local want="$1" dev serial dtype matched
    local -a matches=()
    while read -r dev; do
        matched=0
        serial="$(trim "$(lsblk -dno SERIAL "$dev" 2>/dev/null | head -n1)")"
        if [ "$serial" = "$want" ]; then
            matched=1
        elif command -v smartctl >/dev/null 2>&1; then
            for dtype in auto sntrealtek; do
                serial="$(trim "$(_smart_serial "$dev" "$dtype" || true)")"
                if [ "$serial" = "$want" ]; then
                    matched=1
                    break
                fi
            done
        fi
        [ "$matched" -eq 1 ] && matches+=("$dev")
    done < <(lsblk -dnpo NAME,TYPE | awk '$2=="disk"{print $1}')

    case "${#matches[@]}" in
        1) echo "${matches[0]}" ;;
        0) echo "!!! Disco con seriale $want non trovato." >&2; return 1 ;;
        *) echo "!!! Seriale $want associato a più dischi: ${matches[*]}" >&2; return 1 ;;
    esac
}

part_uuid() {
    local serial="$1" which="$2" disk idx part
    case "$which" in
        boot) idx=1 ;;
        root) idx=2 ;;
        *) echo "!!! part_uuid: usare boot o root." >&2; return 1 ;;
    esac
    disk="$(disk_for_serial "$serial")" || return 1
    part="$(
        lsblk -rno NAME,TYPE,FSTYPE,PARTN "$disk" \
            | awk '$2=="part" && $3=="ext4"{print $4, $1}' \
            | sort -n \
            | awk -v n="$idx" 'NR==n{print $2}'
    )"
    [ -n "$part" ] || {
        echo "!!! Partizione ext4 '$which' non trovata su $disk." >&2
        return 1
    }
    blkid -s UUID -o value "/dev/$part"
}

DEVIN_BOOT_UUID="$(part_uuid "$DEVIN_DISK_SERIAL" boot)"
DEVIN_ROOT_UUID="$(part_uuid "$DEVIN_DISK_SERIAL" root)"
HERMES_BOOT_UUID="$(part_uuid "$HERMES_DISK_SERIAL" boot)"
TEACHER_BOOT_UUID="$(part_uuid "$TEACHER_DISK_SERIAL" boot)"

# Sceglie la coppia kernel/initrd più recente realmente completa.
DEVIN_KERNEL=""
DEVIN_INITRD=""
while read -r kernel; do
    [ -n "$kernel" ] || continue
    version="${kernel#vmlinuz-}"
    if [ -f "/boot/initrd.img-$version" ]; then
        DEVIN_KERNEL="$kernel"
        DEVIN_INITRD="initrd.img-$version"
        break
    fi
done < <(find /boot -maxdepth 1 -type f -name 'vmlinuz-*' -printf '%f\n' | sort -Vr)

[ -n "$DEVIN_KERNEL" ] && [ -n "$DEVIN_INITRD" ] || {
    echo "!!! Nessuna coppia kernel/initrd completa trovata in /boot." >&2
    exit 1
}

# Conserva i parametri kernel configurati localmente.
GRUB_CMDLINE_LINUX=""
GRUB_CMDLINE_LINUX_DEFAULT=""
# shellcheck disable=SC1091
source /etc/default/grub
KERNEL_ARGS="$(printf '%s %s' "${GRUB_CMDLINE_LINUX:-}" "${GRUB_CMDLINE_LINUX_DEFAULT:-}" | xargs)"

CUSTOM_FILE="/etc/grub.d/40_custom"
TMP_FILE="$(mktemp /etc/grub.d/40_custom.XXXXXX)"
trap 'rm -f "$TMP_FILE"' EXIT

cat > "$TMP_FILE" <<EOFCUSTOM
#!/bin/sh
exec tail -n +3 \$0
# Generato da grub-stable-entries.sh. Non modificare a mano.

menuentry "AI Rig - DEVIN" --id devin {
    insmod part_gpt
    insmod ext2
    search --no-floppy --fs-uuid --set=root ${DEVIN_BOOT_UUID}
    linux /${DEVIN_KERNEL} root=UUID=${DEVIN_ROOT_UUID} ro ${KERNEL_ARGS}
    initrd /${DEVIN_INITRD}
}

menuentry "AI Rig - HERMES" --id hermes {
    insmod part_gpt
    insmod ext2
    search --no-floppy --fs-uuid --set=root ${HERMES_BOOT_UUID}
    configfile /grub/grub.cfg
}

menuentry "AI Rig - TEACHER" --id teacher {
    insmod part_gpt
    insmod ext2
    search --no-floppy --fs-uuid --set=root ${TEACHER_BOOT_UUID}
    configfile /grub/grub.cfg
}
EOFCUSTOM

chmod 0755 "$TMP_FILE"
[ -f "$CUSTOM_FILE" ] && cp -a "$CUSTOM_FILE" "${CUSTOM_FILE}.bak.$(date +%s)"
mv -f "$TMP_FILE" "$CUSTOM_FILE"
trap - EXIT

set_grub_key() {
    local key="$1" value="$2"
    if grep -qE "^[#[:space:]]*${key}=" /etc/default/grub; then
        sed -i -E "s|^[#[:space:]]*${key}=.*|${key}=${value}|" /etc/default/grub
    else
        printf '%s=%s\n' "$key" "$value" >> /etc/default/grub
    fi
}

set_grub_key GRUB_DEFAULT saved
set_grub_key GRUB_SAVEDEFAULT false
set_grub_key GRUB_DISABLE_OS_PROBER true

update-grub
command -v grub-script-check >/dev/null 2>&1 \
    && grub-script-check /boot/grub/grub.cfg

for name in DEVIN HERMES TEACHER; do
    grep -q "AI Rig - $name" /boot/grub/grub.cfg || {
        echo "!!! Entry AI Rig - $name assente dopo update-grub." >&2
        exit 1
    }
done

grub-set-default devin
if command -v grub-editenv >/dev/null 2>&1; then
    grub-editenv list | grep -q '^saved_entry=devin$' || {
        echo "!!! Default GRUB 'devin' non verificato." >&2
        exit 1
    }
fi

HOOK_SRC="/opt/cache/scripts/grub-stable-entries.sh"
for hook_dir in /etc/kernel/postinst.d /etc/kernel/postrm.d; do
    mkdir -p "$hook_dir"
    cat > "$hook_dir/zz-ai-rig-stable-entries" <<EOFHOOK
#!/bin/sh
# Rigenera le entry AI Rig dopo installazione/rimozione kernel su DEVIN.
[ -x "$HOOK_SRC" ] && "$HOOK_SRC" >> /var/log/ai-rig-grub-entries.log 2>&1 || true
EOFHOOK
    chmod 0755 "$hook_dir/zz-ai-rig-stable-entries"
done

echo "Entry stabili create e verificate. Default persistente: DEVIN."
echo "Cambio one-shot: sudo grub-reboot hermes|teacher|devin && sudo reboot"
