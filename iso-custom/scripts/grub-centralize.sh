#!/bin/bash
# =============================================================================
# grub-centralize.sh — prepara DEVIN come boot manager UEFI centrale.
# Le entry dei tre ruoli vengono create da grub-stable-entries.sh; os-prober
# viene disabilitato per evitare duplicati e dipendenze da scansioni automatiche.
# =============================================================================
set -Eeuo pipefail
[ "$(id -u)" -eq 0 ] || { echo "!!! Esegui con sudo/root." >&2; exit 1; }

ROLE="$(cat /etc/ai-rig/role 2>/dev/null || true)"
[ "$ROLE" = "devin" ] || {
    echo "!!! grub-centralize.sh deve girare su DEVIN, ruolo attivo: '${ROLE:-sconosciuto}'." >&2
    exit 1
}

[ -d /sys/firmware/efi ] || {
    echo "!!! Sistema non avviato in modalità UEFI." >&2
    exit 1
}
mountpoint -q /boot/efi || {
    echo "!!! /boot/efi non è montata." >&2
    exit 1
}
command -v efibootmgr >/dev/null 2>&1 || {
    echo "!!! efibootmgr non installato." >&2
    exit 1
}

set_grub_key() {
    local key="$1" value="$2"
    if grep -qE "^[#[:space:]]*${key}=" /etc/default/grub; then
        sed -i -E "s|^[#[:space:]]*${key}=.*|${key}=${value}|" /etc/default/grub
    else
        printf '%s=%s\n' "$key" "$value" >> /etc/default/grub
    fi
}

# Le entry statiche sono la sola fonte di verità del menu centrale.
set_grub_key GRUB_DISABLE_OS_PROBER true

EFI_STATE="$(efibootmgr -v)"
BOOT_ORDER="$(awk '/^BootOrder:/{print toupper($2); exit}' <<<"$EFI_STATE")"
ESP_SOURCE="$(findmnt -no SOURCE /boot/efi 2>/dev/null || true)"
[ -b "$ESP_SOURCE" ] || {
    echo "!!! Impossibile determinare il device della ESP DEVIN." >&2
    exit 1
}
ESP_PARTUUID="$(blkid -s PARTUUID -o value "$ESP_SOURCE" 2>/dev/null || true)"
[ -n "$ESP_PARTUUID" ] || {
    echo "!!! PARTUUID della ESP DEVIN non disponibile." >&2
    exit 1
}
DEVIN_BOOT="$(grep -i "$ESP_PARTUUID" <<<"$EFI_STATE" | grep -oE 'Boot[0-9A-Fa-f]{4}' | head -n1 | sed 's/^Boot//' | tr '[:lower:]' '[:upper:]')"
[ -n "$DEVIN_BOOT" ] || {
    echo "!!! Entry EFI associata alla ESP DEVIN non trovata." >&2
    exit 1
}

NEW_ORDER="$DEVIN_BOOT"
IFS=',' read -ra ENTRIES <<<"$BOOT_ORDER"
for entry in "${ENTRIES[@]}"; do
    entry="${entry^^}"
    [ -n "$entry" ] || continue
    [ "$entry" = "$DEVIN_BOOT" ] && continue
    NEW_ORDER+=",$entry"
done

efibootmgr -o "$NEW_ORDER"
VERIFIED_ORDER="$(efibootmgr | awk '/^BootOrder:/{print toupper($2); exit}')"
[ "${VERIFIED_ORDER%%,*}" = "$DEVIN_BOOT" ] || {
    echo "!!! Impossibile mettere DEVIN (Boot$DEVIN_BOOT) al primo posto." >&2
    exit 1
}

echo "DEVIN impostato primo nel BootOrder UEFI: $VERIFIED_ORDER"
