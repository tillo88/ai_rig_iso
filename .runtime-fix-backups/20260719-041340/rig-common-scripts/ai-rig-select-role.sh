#!/bin/bash
# =============================================================================
# ai-rig-select-role.sh — imposta il PROSSIMO ruolo di boot (devin|hermes|teacher)
# scrivendo nel grubenv del GRUB CENTRALE, poi opzionalmente spegne.
#
# PERCHE' NON basta `grub-reboot` e basta: il boot manager centrale e' il GRUB
# del disco DEVIN (grub-centralize.sh + grub-stable-entries.sh). `grub-reboot`
# scrive nel grubenv del sistema SU CUI GIRA: lanciato da HERMES o TEACHER
# scriverebbe il LORO grubenv, che il GRUB di devin non legge mai -> il cambio
# ruolo sembrava fatto ma al reboot tornava il ruolo di prima. Questo script:
#   - se gira su DEVIN: grub-reboot normale (il grubenv giusto e' locale);
#   - se gira su HERMES/TEACHER: monta la partizione /boot del disco DEVIN
#     (trovata per SERIALE da disks.env, mai /dev/sdX) e scrive next_entry la'.
#
# Uso (dal bot Pi via SSH, o a mano):
#   sudo ai-rig-select-role.sh hermes              # solo imposta il prossimo boot
#   sudo ai-rig-select-role.sh hermes --poweroff   # imposta + spegne (cold boot:
#                                                  # il Pi aspetta, poi manda WOL)
#
# Exit code: 0 = next_entry impostato e VERIFICATO; !=0 = niente e' cambiato.
# Il bot NON deve spegnere/accendere se questo script fallisce.
# =============================================================================
set -euo pipefail

TARGET="${1:?Uso: $0 <devin|hermes|teacher> [--poweroff]}"
case "$TARGET" in
    devin|hermes|teacher) ;;
    *) echo "!!! Ruolo sconosciuto: '$TARGET' (validi: devin hermes teacher)" >&2; exit 2 ;;
esac

[ "$(id -u)" -eq 0 ] || { echo "!!! Serve root (sudo)." >&2; exit 3; }

CURRENT=$(cat /etc/ai-rig/role 2>/dev/null || echo "unknown")

verify_next_entry() {
    # $1 = comando grub-editenv "list" gia' formattato (file opzionale)
    local envfile="${1:-}"
    local out
    if [ -n "$envfile" ]; then
        out=$(grub-editenv "$envfile" list 2>/dev/null || true)
    else
        out=$(grub-editenv list 2>/dev/null || true)
    fi
    echo "$out" | grep -q "^next_entry=${TARGET}$"
}

if [ "$CURRENT" = "devin" ]; then
    # Il grubenv centrale e' il nostro /boot/grub/grubenv
    grub-reboot "$TARGET"
    if ! verify_next_entry; then
        echo "!!! grub-reboot eseguito ma next_entry=$TARGET NON risulta in grub-editenv list." >&2
        exit 4
    fi
    echo "OK: prossimo boot -> $TARGET (grubenv locale di devin)"
else
    # Siamo su hermes/teacher: dobbiamo scrivere il grubenv del disco DEVIN.
    source /opt/cache/config/disks.env 2>/dev/null || {
        echo "!!! /opt/cache/config/disks.env mancante: non posso trovare il disco devin." >&2
        exit 5
    }
    disk=$(lsblk -dno NAME,SERIAL | awk -v s="$DEVIN_DISK_SERIAL" '$2==s {print $1}' | head -n1)
    [ -n "$disk" ] || { echo "!!! Disco devin (serial $DEVIN_DISK_SERIAL) non trovato." >&2; exit 5; }

    # NIENTE indici di partizione fissi (il layout e' cambiato almeno una
    # volta: ora 1=bios_grub, 2=esp, 3=/boot, 4=root — vedi fix 2026-07-16).
    # Si risolve per CONTENUTO, come grub-stable-entries.sh: la /boot di
    # devin e' la ext4 che contiene grub/grubenv alla radice.
    MNT="/run/ai-rig-devin-boot"
    mkdir -p "$MNT"
    cleanup() { umount "$MNT" 2>/dev/null || true; }
    trap cleanup EXIT

    GRUBENV=""
    for part in $(lsblk -lno NAME,TYPE,FSTYPE "/dev/${disk}" | awk '$2=="part" && $3=="ext4" {print $1}'); do
        mount "/dev/${part}" "$MNT" 2>/dev/null || continue
        if [ -f "${MNT}/grub/grubenv" ]; then
            GRUBENV="${MNT}/grub/grubenv"
            break
        fi
        umount "$MNT"
    done
    [ -n "$GRUBENV" ] || { echo "!!! Nessuna partizione del disco devin contiene grub/grubenv (grub-stable-entries.sh mai eseguito su devin?)." >&2; exit 6; }

    grub-editenv "$GRUBENV" set next_entry="$TARGET"
    if ! verify_next_entry "$GRUBENV"; then
        echo "!!! Scrittura next_entry=$TARGET nel grubenv di devin NON verificata." >&2
        exit 4
    fi
    sync
    umount "$MNT"
    trap - EXIT
    echo "OK: prossimo boot -> $TARGET (grubenv del disco devin, scritto da $CURRENT)"
fi

if [ "${2:-}" = "--poweroff" ]; then
    echo "Spegnimento tra 2s (cold boot: riaccensione via WOL dal Pi)..."
    # systemd-run: il poweroff parte DOPO che questo script (e la sessione SSH
    # del bot) hanno fatto in tempo a chiudersi con exit code pulito.
    systemd-run --on-active=2s /usr/bin/systemctl poweroff >/dev/null 2>&1 || systemctl poweroff
fi
