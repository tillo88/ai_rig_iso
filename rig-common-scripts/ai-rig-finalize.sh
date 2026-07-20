#!/bin/bash
# =============================================================================
# ai-rig-finalize.sh — coordinatore della catena AUTO.
# - registra il ruolo completato nello stato della BUILD corrente sul 4TB;
# - finché manca un ruolo imposta BootNext verso la chiavetta installer;
# - quando tutti i ruoli sono completi trasferisce il controllo a DEVIN;
# - la finalizzazione GRUB globale viene eseguita esclusivamente su DEVIN.
# =============================================================================
set -Eeuo pipefail
exec >> /var/log/ai-rig-finalize.log 2>&1

CACHE_LABEL="ai-rig-cache"
CACHE_MNT="/run/ai-rig-cache-final"
ESP_GUID="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
ROLES=(devin hermes teacher)
LOCAL_STATE="/var/lib/ai-rig"
BUILD_ID_FILE="/etc/ai-rig/build-id"

mkdir -p "$LOCAL_STATE"
echo "=== finalize $(date -Iseconds) ==="

die() { echo "!!! finalize: $*" >&2; exit 1; }
trim() { awk '{$1=$1; print}' <<<"${1:-}"; }
trim_file() { tr -d '\r\n[:space:]' < "$1"; }

ROLE="$(cat /etc/ai-rig/role 2>/dev/null || true)"
case "$ROLE" in
    devin|hermes|teacher) ;;
    *) die "ruolo non valido o assente: '${ROLE:-vuoto}'" ;;
esac
[ -s "$BUILD_ID_FILE" ] || die "$BUILD_ID_FILE assente o vuoto"
BUILD_ID="$(trim_file "$BUILD_ID_FILE")"
[[ "$BUILD_ID" =~ ^[A-Za-z0-9._-]+$ ]] || die "BUILD_ID non valido: '$BUILD_ID'"

CACHE_DEV="$(blkid -L "$CACHE_LABEL" 2>/dev/null || true)"
if [ -z "$CACHE_DEV" ]; then
    echo "Cache '$CACHE_LABEL' assente: modalità manuale, nessuna catena automatica."
    exit 0
fi

mkdir -p "$CACHE_MNT"
AUTO_MOUNTED=0
if ! mountpoint -q "$CACHE_MNT"; then
    mount "$CACHE_DEV" "$CACHE_MNT"
    AUTO_MOUNTED=1
fi
cleanup() {
    if [ "$AUTO_MOUNTED" -eq 1 ]; then
        umount "$CACHE_MNT" 2>/dev/null || true
        AUTO_MOUNTED=0
    fi
}
trap cleanup EXIT

[ -s "$CACHE_MNT/cache/BUILD_ID" ] || die "BUILD_ID assente sul disco-cache"
CACHE_BUILD_ID="$(trim_file "$CACHE_MNT/cache/BUILD_ID")"
[ "$CACHE_BUILD_ID" = "$BUILD_ID" ] \
    || die "cache di una build diversa: sistema=$BUILD_ID, cache=$CACHE_BUILD_ID"

STATE_DIR="$CACHE_MNT/cache/.installed/$BUILD_ID"
GLOBAL_PENDING="$STATE_DIR/global-finalize-pending"
GLOBAL_DONE="$STATE_DIR/global-finalize-done"
mkdir -p "$STATE_DIR"

if [ -f "$GLOBAL_DONE" ]; then
    touch "$LOCAL_STATE/global-finalize-done" "$LOCAL_STATE/finalize-done"
    echo "Finalizzazione globale già completata per build $BUILD_ID."
    exit 0
fi

# Il marker viene scritto solo dopo stage-role-done, condizione della unit systemd.
touch "$STATE_DIR/$ROLE"
sync
printf 'Ruolo completato registrato: %s (build %s)\n' "$ROLE" "$BUILD_ID"

all_roles_done() {
    local r
    for r in "${ROLES[@]}"; do
        [ -f "$STATE_DIR/$r" ] || return 1
    done
    return 0
}

entry_for_partuuid() {
    local uuid="$1"
    efibootmgr -v 2>/dev/null \
        | grep -i "$uuid" \
        | grep -oE 'Boot[0-9A-Fa-f]{4}' \
        | head -n1 \
        | sed 's/^Boot//'
}

set_verified_bootnext() {
    local number="${1^^}" actual
    [ -n "$number" ] || die "numero EFI BootNext vuoto"
    efibootmgr --bootnext "$number"
    actual="$(efibootmgr 2>/dev/null | awk '/^BootNext:/{print toupper($2); exit}')"
    [ "$actual" = "$number" ] \
        || die "BootNext non verificato: richiesto $number, letto '${actual:-vuoto}'"
    echo "BootNext verificato: Boot$number"
}

reboot_after_unmount() {
    sync
    cleanup
    trap - EXIT
    sleep 2
    systemctl reboot
}

find_usb_efi_entry() {
    local disk name ptype uuid number iso_part

    # Percorso principale: chiavetta/disco marcato removable.
    while read -r disk; do
        while read -r name ptype; do
            [ "${ptype,,}" = "$ESP_GUID" ] || continue
            uuid="$(blkid -s PARTUUID -o value "/dev/$name" 2>/dev/null || true)"
            [ -n "$uuid" ] || continue
            number="$(entry_for_partuuid "$uuid" || true)"
            [ -n "$number" ] && { echo "$number"; return 0; }
        done < <(lsblk -rno NAME,PARTTYPE "/dev/$disk" 2>/dev/null)
    done < <(lsblk -dno NAME,RM | awk '$2==1{print $1}')

    # Fallback dedicato alla ISO: risale dal volume ISO9660 al disco padre.
    iso_part="$(blkid -L 'Ubuntu 24.04 AI Rig' 2>/dev/null || true)"
    if [ -n "$iso_part" ]; then
        disk="$(lsblk -no PKNAME "$iso_part" 2>/dev/null | head -n1)"
        if [ -n "$disk" ]; then
            while read -r name ptype; do
                [ "${ptype,,}" = "$ESP_GUID" ] || continue
                uuid="$(blkid -s PARTUUID -o value "/dev/$name" 2>/dev/null || true)"
                [ -n "$uuid" ] || continue
                number="$(entry_for_partuuid "$uuid" || true)"
                [ -n "$number" ] && { echo "$number"; return 0; }
            done < <(lsblk -rno NAME,PARTTYPE "/dev/$disk" 2>/dev/null)
        fi
    fi

    return 1
}

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
        0) return 1 ;;
        *) die "seriale '$want' associato a più dischi: ${matches[*]}" ;;
    esac
}

efi_entry_for_disk() {
    local disk="$1" part ptype uuid number
    while read -r part ptype; do
        [ "${ptype,,}" = "$ESP_GUID" ] || continue
        uuid="$(blkid -s PARTUUID -o value "$part" 2>/dev/null || true)"
        [ -n "$uuid" ] || continue
        number="$(entry_for_partuuid "$uuid" || true)"
        [ -n "$number" ] && { echo "$number"; return 0; }
    done < <(lsblk -lnpo NAME,PARTTYPE "$disk" 2>/dev/null)
    return 1
}

if ! all_roles_done; then
    echo "Ruoli ancora mancanti: preparo il ritorno alla USB installer."
    USB_NUM="$(find_usb_efi_entry || true)"
    [ -n "$USB_NUM" ] || die "voce EFI della USB installer non trovata; avvia manualmente 'Install AI Rig (AUTO)'"
    set_verified_bootnext "$USB_NUM"
    echo "Riavvio verso la USB: AUTO installerà il prossimo ruolo incompleto."
    reboot_after_unmount
    exit 0
fi

# Tutti completi: il GRUB centrale deve essere costruito su DEVIN, mai sull'ultimo
# ruolo installato (normalmente TEACHER).
touch "$GLOBAL_PENDING"
sync

if [ "$ROLE" != "devin" ]; then
    CONFIG="/opt/cache/config/disks.env"
    [ -f "$CONFIG" ] || die "$CONFIG assente: impossibile localizzare DEVIN"
    # shellcheck disable=SC1090
    source "$CONFIG"
    [ -n "${DEVIN_DISK_SERIAL:-}" ] || die "DEVIN_DISK_SERIAL assente in disks.env"
    DEVIN_DISK="$(disk_for_serial "$DEVIN_DISK_SERIAL" || true)"
    [ -n "$DEVIN_DISK" ] || die "disco DEVIN non trovato"
    DEVIN_NUM="$(efi_entry_for_disk "$DEVIN_DISK" || true)"
    [ -n "$DEVIN_NUM" ] || die "entry EFI del disco DEVIN non trovata"
    set_verified_bootnext "$DEVIN_NUM"
    echo "Tutti i ruoli completi: riavvio su DEVIN per il finalize globale."
    reboot_after_unmount
    exit 0
fi

echo "DEVIN attivo: eseguo la finalizzazione globale."
# Prima crea e verifica il menu; solo dopo mette DEVIN al primo posto nel firmware.
for script in grub-stable-entries.sh grub-centralize.sh; do
    path="/opt/cache/scripts/$script"
    [ -x "$path" ] || die "script obbligatorio assente/non eseguibile: $path"
    bash "$path"
done

# Verifica finale indipendente dai messaggi degli script.
for role in "${ROLES[@]}"; do
    grep -qE "menuentry .*AI Rig - ${role^^}.*--id ${role}([[:space:]]|\\{)" /boot/grub/grub.cfg \
        || die "entry GRUB $role assente o senza ID stabile"
done
command -v grub-script-check >/dev/null 2>&1 \
    && grub-script-check /boot/grub/grub.cfg

touch "$GLOBAL_DONE" "$LOCAL_STATE/global-finalize-done" "$LOCAL_STATE/finalize-done"
rm -f "$GLOBAL_PENDING"
sync

echo "=== CATENA COMPLETA (build $BUILD_ID): DEVIN è boot manager e default. ==="
