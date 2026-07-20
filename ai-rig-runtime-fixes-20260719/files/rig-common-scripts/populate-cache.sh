#!/usr/bin/env bash
# =============================================================================
# populate-cache.sh — copia selettiva dal 4TB al ruolo attivo, verifica il
# payload, abilita le stage pesanti e solo allora crea populate-cache-done.
# La cache deve appartenere alla stessa build della ISO installata.
# =============================================================================
set -Eeuo pipefail
[ "$(id -u)" -eq 0 ] || { echo "!!! Serve root (sudo)." >&2; exit 1; }

CACHE_LABEL="ai-rig-cache"
MNT="/run/ai-rig-cache-src"
AUTO_MOUNTED=0
SRC=""
REBOOT=1
STATE_DIR="/var/lib/ai-rig"
BUILD_ID_FILE="/etc/ai-rig/build-id"
SHARED_MOUNT_PATH="__SHARED_MOUNT_PATH__"

usage() {
    echo "Uso: sudo populate-cache.sh [--no-reboot] [/percorso/cache]"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --no-reboot) REBOOT=0 ;;
        --help|-h) usage; exit 0 ;;
        --*) echo "!!! Opzione sconosciuta: $1" >&2; usage >&2; exit 2 ;;
        *)
            [ -z "$SRC" ] || { echo "!!! Specifica una sola sorgente." >&2; exit 2; }
            SRC="$1"
            ;;
    esac
    shift
done

cleanup() {
    [ "$AUTO_MOUNTED" -eq 1 ] && umount "$MNT" 2>/dev/null || true
}
trap cleanup EXIT

die() { echo "!!! populate-cache: $*" >&2; exit 1; }
trim_file() { tr -d '\r\n[:space:]' < "$1"; }

if [ -z "$SRC" ]; then
    dev="$(blkid -L "$CACHE_LABEL" 2>/dev/null || true)"
    [ -n "$dev" ] || die "nessun disco con etichetta '$CACHE_LABEL'"
    mkdir -p "$MNT"
    if ! mountpoint -q "$MNT"; then
        mount -o ro "$dev" "$MNT"
        AUTO_MOUNTED=1
    fi
    if [ -d "$MNT/cache" ]; then
        SRC="$MNT/cache"
    else
        SRC="$MNT"
    fi
    echo "Disco-cache: $dev -> $SRC"
fi

[ -d "$SRC" ] || die "sorgente '$SRC' non valida"
[ -s "$BUILD_ID_FILE" ] || die "$BUILD_ID_FILE assente o vuoto"
[ -s "$SRC/BUILD_ID" ] || die "$SRC/BUILD_ID assente o vuoto"
EXPECTED_BUILD_ID="$(trim_file "$BUILD_ID_FILE")"
SOURCE_BUILD_ID="$(trim_file "$SRC/BUILD_ID")"
[ "$SOURCE_BUILD_ID" = "$EXPECTED_BUILD_ID" ] \
    || die "cache di una build diversa: ISO=$EXPECTED_BUILD_ID, cache=$SOURCE_BUILD_ID"

echo "Build ID verificato: $EXPECTED_BUILD_ID"

ROLE="$(cat /etc/ai-rig/role 2>/dev/null || true)"
if [ -z "$ROLE" ]; then
    ROLE="$(hostname 2>/dev/null | sed -n 's/.*-\(devin\|hermes\|teacher\)$/\1/p')"
    [ -n "$ROLE" ] && echo "$ROLE" > /etc/ai-rig/role
fi
case "$ROLE" in
    devin|hermes|teacher) ;;
    *) die "ruolo non determinabile o non valido: '${ROLE:-vuoto}'" ;;
esac

echo "== Ruolo $ROLE: validazione payload =="

REQUIRED_FILES=(
    "$SRC/BUILD_ID"
    "$SRC/nvidia-driver.run"
    "$SRC/cuda-toolkit.run"
    "$SRC/llama-prebuilt/bin/llama-server"
    "$SRC/scripts/install-nccl-runtime.sh"
    "$SRC/scripts/install-nccl-and-resume.sh"
)
REQUIRED_DIRS=(
    "$SRC/config"
    "$SRC/requirements"
    "$SRC/scripts"
    "$SRC/packages"
    "$SRC/llama-prebuilt"
    "$SRC/models/$ROLE"
)

for path in "${REQUIRED_FILES[@]}"; do
    [ -f "$path" ] || die "file obbligatorio assente: $path"
done
[ -x "$SRC/llama-prebuilt/bin/llama-server" ] \
    || die "llama-server precompilato non eseguibile: $SRC/llama-prebuilt/bin/llama-server"
for path in "${REQUIRED_DIRS[@]}"; do
    [ -d "$path" ] || die "directory obbligatoria assente: $path"
done
find "$SRC/models/$ROLE" -maxdepth 1 -type f -name '*.gguf' -print -quit | grep -q . \
    || die "nessun modello GGUF in $SRC/models/$ROLE"
find "$SRC/packages" -maxdepth 1 -type f -name 'libnccl2_*+cuda12.8_amd64.deb' -print -quit | grep -q . \
    || die "pacchetto libnccl2 per CUDA 12.8 assente in $SRC/packages"
[ -s "$SRC/packages/SHA256SUMS" ] \
    || die "manifest SHA256SUMS assente in $SRC/packages"
(
    cd "$SRC/packages"
    sha256sum -c SHA256SUMS
) || die "checksum pacchetti NCCL non valido"

mkdir -p /opt/cache /opt/cache/models "$STATE_DIR"

RSYNC_OPTS=(-a --partial --partial-dir=.rsync-partial --info=progress2)
copy_item() {
    local source="$1" destination="$2" label="$3"
    echo "  [$label] $(basename "$source")"
    rsync "${RSYNC_OPTS[@]}" "$source" "$destination"
}

# Payload obbligatorio condiviso.
for item in BUILD_ID nvidia-driver.run cuda-toolkit.run llama-prebuilt config requirements scripts packages; do
    copy_item "$SRC/$item" /opt/cache/ shared
done

# Payload facoltativo condiviso.
for item in drivedb ai-rig-bot.pub; do
    [ -e "$SRC/$item" ] && copy_item "$SRC/$item" /opt/cache/ optional
done

copy_item "$SRC/models/$ROLE" /opt/cache/models/ role

if [ "$ROLE" = "hermes" ] && [ -d "$SRC/comfyui-models" ]; then
    mountpoint -q "$SHARED_MOUNT_PATH" \
        || die "disco condiviso non montato: $SHARED_MOUNT_PATH"

    SHARED_COMFY="$SHARED_MOUNT_PATH/comfyui-models"
    mkdir -p "$SHARED_COMFY"
    echo "  [hermes] comfyui-models -> $SHARED_COMFY"
    rsync "${RSYNC_OPTS[@]}" \
        "$SRC/comfyui-models/" \
        "$SHARED_COMFY/"

    # Verifica metadati/dimensioni senza rileggere tutti i 31 GB con checksum.
    VERIFY_LIST="$(mktemp)"
    if ! rsync -aHn --delete --itemize-changes \
        "$SRC/comfyui-models/" "$SHARED_COMFY/" > "$VERIFY_LIST"; then
        rm -f "$VERIFY_LIST"
        die "errore durante la verifica ComfyUI"
    fi
    if [ -s "$VERIFY_LIST" ]; then
        sed -n '1,20p' "$VERIFY_LIST" >&2
        rm -f "$VERIFY_LIST"
        die "verifica ComfyUI fallita: sorgente e disco condiviso differiscono"
    fi
    rm -f "$VERIFY_LIST"
fi

# Verifica destinazione prima di abilitare alcun servizio.
[ "$(trim_file /opt/cache/BUILD_ID)" = "$EXPECTED_BUILD_ID" ] || die "BUILD_ID copiato non valido"
[ -f /opt/cache/nvidia-driver.run ] || die "driver non copiato"
[ -f /opt/cache/cuda-toolkit.run ] || die "CUDA toolkit non copiato"
[ -x /opt/cache/llama-prebuilt/bin/llama-server ] \
    || die "llama-server precompilato assente/non eseguibile dopo la copia"
[ -x /opt/cache/scripts/install-nccl-runtime.sh ] \
    || die "installer NCCL assente/non eseguibile dopo la copia"
find /opt/cache/packages -maxdepth 1 -type f -name 'libnccl2_*+cuda12.8_amd64.deb' -print -quit | grep -q . \
    || die "pacchetto NCCL assente dopo la copia"
(
    cd /opt/cache/packages
    sha256sum -c SHA256SUMS
) || die "checksum pacchetti NCCL copiati non valido"
find "/opt/cache/models/$ROLE" -maxdepth 1 -type f -name '*.gguf' -print -quit | grep -q . \
    || die "modello $ROLE assente dopo la copia"

REQUIRED_UNITS=(
    ai-rig-stage-driver.service
    ai-rig-stage-cuda-llama.service
    ai-rig-stage-gpudetect.service
    ai-rig-stage-role.service
)
OPTIONAL_UNITS=(
    ai-rig-stage-automem.service
    ai-rig-stage-understory.service
    ai-rig-librarian.service
    gtx1080-powerlimit.service
    ai-rig-understory-commit.timer
)
[ "$ROLE" = "hermes" ] && OPTIONAL_UNITS+=(ai-rig-hermes-extras.service)

systemctl daemon-reload
for unit in "${REQUIRED_UNITS[@]}"; do
    systemctl cat "$unit" >/dev/null 2>&1 || die "unit obbligatoria assente: $unit"
    systemctl enable "$unit" >/dev/null
    echo "  enabled $unit"
done
for unit in "${OPTIONAL_UNITS[@]}"; do
    if systemctl cat "$unit" >/dev/null 2>&1; then
        if systemctl enable "$unit" >/dev/null; then
            echo "  enabled $unit"
        else
            echo "  attenzione: impossibile abilitare $unit" >&2
        fi
    else
        echo "  opzionale assente: $unit"
    fi
done

touch "$STATE_DIR/populate-cache-done" "$STATE_DIR/first-boot-done"
sync

echo "== Cache verificata e stage abilitate =="
if [ "$REBOOT" -eq 1 ]; then
    echo "Riavvio tra 5 secondi..."
    cleanup
    trap - EXIT
    sleep 5
    systemctl reboot
else
    echo "Riavvia quando vuoi: sudo systemctl reboot"
fi
