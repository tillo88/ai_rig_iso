#!/usr/bin/env bash
# =============================================================================
# Imposta il prossimo ruolo nel grubenv centrale DEVIN e forza il prossimo
# ingresso firmware sulla ESP DEVIN, localizzata dinamicamente per seriale e
# PARTUUID. Nessun BootXXXX o /dev/sdX hardcoded.
# =============================================================================
set -Eeuo pipefail

usage() { echo "Uso: $0 <devin|hermes|teacher> [--poweroff]"; }
TARGET="${1:-}"
ACTION="${2:-}"
case "$TARGET" in devin|hermes|teacher) ;; *) usage >&2; exit 2 ;; esac
case "$ACTION" in ""|--poweroff) ;; *) usage >&2; exit 2 ;; esac
[ "$(id -u)" -eq 0 ] || { echo "!!! Serve root (sudo)." >&2; exit 3; }
[ -d /sys/firmware/efi ] || { echo "!!! Sistema non avviato in UEFI." >&2; exit 3; }
command -v efibootmgr >/dev/null 2>&1 || { echo "!!! efibootmgr assente." >&2; exit 3; }

CURRENT="$(cat /etc/ai-rig/role 2>/dev/null || echo unknown)"
CONFIG="/opt/cache/config/disks.env"
[ -f "$CONFIG" ] || { echo "!!! $CONFIG mancante." >&2; exit 5; }
# shellcheck disable=SC1090
source "$CONFIG"
[ -n "${DEVIN_DISK_SERIAL:-}" ] || { echo "!!! DEVIN_DISK_SERIAL assente." >&2; exit 5; }

trim() { awk '{$1=$1; print}' <<<"${1:-}"; }
disk_for_serial() {
    local want="$1" dev serial
    local -a matches=()
    while read -r dev; do
        serial="$(trim "$(lsblk -dno SERIAL "$dev" 2>/dev/null | head -n1)")"
        [ "$serial" = "$want" ] && matches+=("$dev")
    done < <(lsblk -dnpo NAME,TYPE | awk '$2=="disk"{print $1}')
    [ "${#matches[@]}" -eq 1 ] || {
        echo "!!! Disco DEVIN non univoco per seriale '$want': ${matches[*]:-nessuno}" >&2
        return 1
    }
    echo "${matches[0]}"
}

entry_for_partuuid() {
    local want="${1,,}" line
    while IFS= read -r line; do
        if [[ "${line,,}" == *"$want"* ]] && [[ "$line" =~ ^Boot([0-9A-Fa-f]{4}) ]]; then
            printf '%s\n' "${BASH_REMATCH[1]^^}"
            return 0
        fi
    done < <(efibootmgr -v 2>/dev/null)
    return 1
}

DEVIN_DISK="$(disk_for_serial "$DEVIN_DISK_SERIAL")"
ESP_GUID="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
DEVIN_ESP=""
while read -r part ptype; do
    if [ "${ptype,,}" = "$ESP_GUID" ]; then DEVIN_ESP="$part"; break; fi
done < <(lsblk -lnpo NAME,PARTTYPE "$DEVIN_DISK")
[ -b "$DEVIN_ESP" ] || { echo "!!! ESP DEVIN non trovata su $DEVIN_DISK." >&2; exit 6; }
DEVIN_ESP_PARTUUID="$(blkid -s PARTUUID -o value "$DEVIN_ESP" 2>/dev/null || true)"
[ -n "$DEVIN_ESP_PARTUUID" ] || { echo "!!! PARTUUID ESP DEVIN assente." >&2; exit 6; }
DEVIN_BOOT="$(entry_for_partuuid "$DEVIN_ESP_PARTUUID" || true)"
[ -n "$DEVIN_BOOT" ] || { echo "!!! Entry EFI DEVIN non trovata per PARTUUID $DEVIN_ESP_PARTUUID." >&2; exit 6; }

ENVFILE=""
MNT="/run/ai-rig-devin-boot"
AUTO_MOUNTED=0
cleanup() {
    if [ "$AUTO_MOUNTED" -eq 1 ]; then umount "$MNT" 2>/dev/null || true; fi
}
trap cleanup EXIT

verify_next_entry() {
    local out
    if [ -n "$ENVFILE" ]; then out="$(grub-editenv "$ENVFILE" list 2>/dev/null || true)"
    else out="$(grub-editenv list 2>/dev/null || true)"; fi
    grep -q "^next_entry=${TARGET}$" <<<"$out"
}
unset_next_entry() {
    if [ -n "$ENVFILE" ]; then grub-editenv "$ENVFILE" unset next_entry 2>/dev/null || true
    else grub-editenv unset next_entry 2>/dev/null || true; fi
}

if [ "$CURRENT" = devin ]; then
    grub-reboot "$TARGET"
else
    mkdir -p "$MNT"
    while read -r part fstype; do
        [ "$fstype" = ext4 ] || continue
        mount "$part" "$MNT" 2>/dev/null || continue
        AUTO_MOUNTED=1
        if [ -f "$MNT/grub/grubenv" ]; then ENVFILE="$MNT/grub/grubenv"; break; fi
        umount "$MNT"
        AUTO_MOUNTED=0
    done < <(lsblk -lnpo NAME,FSTYPE "$DEVIN_DISK")
    [ -n "$ENVFILE" ] || { echo "!!! grubenv centrale DEVIN non trovato." >&2; exit 6; }
    grub-editenv "$ENVFILE" set next_entry="$TARGET"
fi

verify_next_entry || { unset_next_entry; echo "!!! next_entry=$TARGET non verificata." >&2; exit 4; }

# Mantiene DEVIN primo anche se il firmware ha riordinato le entry.
BOOT_ORDER="$(efibootmgr | awk '/^BootOrder:/{print toupper($2); exit}')"
NEW_ORDER="$DEVIN_BOOT"
IFS=',' read -ra ENTRIES <<<"$BOOT_ORDER"
for entry in "${ENTRIES[@]}"; do
    entry="${entry^^}"
    [ -n "$entry" ] || continue
    [ "$entry" = "$DEVIN_BOOT" ] && continue
    NEW_ORDER+=",$entry"
done
if [ "${BOOT_ORDER%%,*}" != "$DEVIN_BOOT" ]; then
    if ! efibootmgr --bootorder "$NEW_ORDER"; then
        unset_next_entry
        echo "!!! Impossibile mettere DEVIN primo nel BootOrder." >&2
        exit 7
    fi
fi
VERIFIED_ORDER="$(efibootmgr | awk '/^BootOrder:/{print toupper($2); exit}')"
if [ "${VERIFIED_ORDER%%,*}" != "$DEVIN_BOOT" ]; then
    unset_next_entry
    echo "!!! BootOrder non verificato: $VERIFIED_ORDER" >&2
    exit 7
fi

if ! efibootmgr --bootnext "$DEVIN_BOOT"; then
    unset_next_entry
    echo "!!! Impostazione BootNext DEVIN fallita." >&2
    exit 8
fi
ACTUAL_NEXT="$(efibootmgr | awk '/^BootNext:/{print toupper($2); exit}')"
if [ "$ACTUAL_NEXT" != "$DEVIN_BOOT" ]; then
    unset_next_entry
    echo "!!! BootNext non verificato: richiesto $DEVIN_BOOT, letto ${ACTUAL_NEXT:-vuoto}." >&2
    exit 8
fi

sync
cleanup
AUTO_MOUNTED=0
trap - EXIT
printf 'OK: prossimo ruolo=%s; BootNext=Boot%s (ESP DEVIN %s); BootOrder=%s\n' \
    "$TARGET" "$DEVIN_BOOT" "$DEVIN_ESP_PARTUUID" "$VERIFIED_ORDER"

if [ "$ACTION" = --poweroff ]; then
    echo "Spegnimento tra 2s; il Pi attendera' il periodo OFF prima del WOL."
    systemd-run --on-active=2s /usr/bin/systemctl poweroff >/dev/null 2>&1 \
        || systemctl poweroff
fi
