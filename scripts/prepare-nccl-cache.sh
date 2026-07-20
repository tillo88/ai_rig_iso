#!/usr/bin/env bash
# Download the NCCL runtime for CUDA 12.8 into cache/packages and copy the
# runtime/rescue helpers into cache/scripts. Run on the build machine/WSL.
set -Eeuo pipefail

[ "$(id -u)" -eq 0 ] || { echo "ERRORE: eseguire con sudo." >&2; exit 1; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
CUDA_SERIES="12.8"
PREFERRED_VERSION="2.26.2-1+cuda12.8"
DEST="${1:-}"

if [ -z "$DEST" ] && [ -f "$PROJECT_ROOT/config/rig.env" ]; then
    # shellcheck disable=SC1091
    source "$PROJECT_ROOT/config/rig.env"
    DEST="${CACHE_DIR:-}"
fi

if [ -z "$DEST" ]; then
    cat >&2 <<'EOU'
Uso: sudo scripts/prepare-nccl-cache.sh /percorso/cache
Esempio: sudo scripts/prepare-nccl-cache.sh /mnt/ai-rig-cache/cache
EOU
    exit 2
fi

mkdir -p "$DEST/packages" "$DEST/scripts"
DEST="$(readlink -f "$DEST")"

for cmd in wget dpkg apt-get apt-cache dpkg-deb sha256sum; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "ERRORE: comando mancante: $cmd" >&2; exit 1; }
done

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

KEYRING_NAME="cuda-keyring_1.1-1_all.deb"
KEYRING_URL="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/$KEYRING_NAME"

echo "Scarico/verifico keyring NVIDIA..."
wget -q --https-only "$KEYRING_URL" -O "$TMP/$KEYRING_NAME"
dpkg-deb -f "$TMP/$KEYRING_NAME" Package | grep -Fxq cuda-keyring \
    || { echo "ERRORE: keyring scaricato non valido." >&2; exit 1; }
install -m 0644 "$TMP/$KEYRING_NAME" "$DEST/packages/$KEYRING_NAME"
dpkg -i "$TMP/$KEYRING_NAME"
apt-get update

if apt-cache madison libnccl2 | awk '{print $3}' | grep -Fxq "$PREFERRED_VERSION"; then
    NCCL_VERSION="$PREFERRED_VERSION"
else
    NCCL_VERSION="$(apt-cache madison libnccl2 | awk -v s="+cuda${CUDA_SERIES}" 'length($3)>=length(s) && substr($3,length($3)-length(s)+1)==s {print $3}' | sort -V | tail -n1)"
fi
[ -n "$NCCL_VERSION" ] || {
    echo "ERRORE: nessuna versione libnccl2 per CUDA ${CUDA_SERIES}." >&2
    exit 1
}

echo "Scarico libnccl2 $NCCL_VERSION..."
(
    cd "$TMP"
    apt-get download "libnccl2=$NCCL_VERSION"
)
NCCL_DEB="$(find "$TMP" -maxdepth 1 -type f -name "libnccl2_*+cuda${CUDA_SERIES}_amd64.deb" -print -quit)"
[ -n "$NCCL_DEB" ] || { echo "ERRORE: .deb NCCL non trovato dopo il download." >&2; exit 1; }
[ "$(dpkg-deb -f "$NCCL_DEB" Package)" = "libnccl2" ] || { echo "ERRORE: pacchetto NCCL non valido." >&2; exit 1; }
[ "$(dpkg-deb -f "$NCCL_DEB" Architecture)" = "amd64" ] || { echo "ERRORE: architettura NCCL non valida." >&2; exit 1; }
install -m 0644 "$NCCL_DEB" "$DEST/packages/$(basename "$NCCL_DEB")"

install -m 0755 "$SCRIPT_DIR/install-nccl-runtime.sh" "$DEST/scripts/install-nccl-runtime.sh"
install -m 0755 "$SCRIPT_DIR/install-nccl-and-resume.sh" "$DEST/scripts/install-nccl-and-resume.sh"

(
    cd "$DEST/packages"
    sha256sum "$KEYRING_NAME" "$(basename "$NCCL_DEB")" > SHA256SUMS.tmp
    mv -f SHA256SUMS.tmp SHA256SUMS
)

cat > "$DEST/packages/NCCL-INFO.txt" <<EOFINFO
cuda_series=$CUDA_SERIES
libnccl2_version=$NCCL_VERSION
prepared_at=$(date -Iseconds)
EOFINFO

echo
echo "OK: cache NCCL pronta in $DEST"
ls -lh "$DEST/packages/$KEYRING_NAME" "$DEST/packages/$(basename "$NCCL_DEB")"
echo "Helper pronto: $DEST/scripts/install-nccl-and-resume.sh"
