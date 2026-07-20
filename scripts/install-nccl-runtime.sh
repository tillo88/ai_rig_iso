#!/usr/bin/env bash
# Install the NCCL runtime required by the BeeLlama prebuilt.
# Prefers the offline package in /opt/cache/packages; falls back to NVIDIA APT.
set -Eeuo pipefail

[ "$(id -u)" -eq 0 ] || { echo "ERRORE: eseguire come root (sudo)." >&2; exit 1; }

CUDA_SERIES="12.8"
PREFERRED_VERSION="2.26.2-1+cuda12.8"
CACHE_LABEL="ai-rig-cache"
AUTO_MNT="/run/ai-rig-nccl-cache"
AUTO_MOUNTED=0
EXPLICIT_CACHE=""

usage() {
    cat <<'EOU'
Uso: sudo install-nccl-runtime.sh [--cuda 12.8] [--cache /percorso/cache]
Installa soltanto libnccl2 e verifica libnccl.so.2. Non riavvia servizi.
EOU
}

while [ $# -gt 0 ]; do
    case "$1" in
        --cuda)
            [ $# -ge 2 ] || { echo "ERRORE: --cuda richiede un valore." >&2; exit 2; }
            CUDA_SERIES="$2"; shift 2 ;;
        --cache)
            [ $# -ge 2 ] || { echo "ERRORE: --cache richiede un percorso." >&2; exit 2; }
            EXPLICIT_CACHE="$2"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) echo "ERRORE: argomento sconosciuto: $1" >&2; usage >&2; exit 2 ;;
    esac
done

case "$CUDA_SERIES" in
    12.8) ;;
    *) echo "ERRORE: serie CUDA non supportata da questo pacchetto: $CUDA_SERIES" >&2; exit 2 ;;
esac

cleanup() {
    if [ "$AUTO_MOUNTED" -eq 1 ]; then
        umount "$AUTO_MNT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

have_nccl() {
    ldconfig -p 2>/dev/null | grep -q 'libnccl\.so\.2'
}

if have_nccl; then
    echo "NCCL gia' presente:"
    ldconfig -p | grep 'libnccl\.so\.2'
    exit 0
fi

CACHE_CANDIDATES=()
[ -n "$EXPLICIT_CACHE" ] && CACHE_CANDIDATES+=("$EXPLICIT_CACHE")
CACHE_CANDIDATES+=("/opt/cache" "/run/ai-rig-cache-src/cache")

# If needed, mount the 4 TB cache read-only and add it to the search paths.
if [ -z "$EXPLICIT_CACHE" ] && ! mountpoint -q "$AUTO_MNT" 2>/dev/null; then
    cache_dev="$(blkid -L "$CACHE_LABEL" 2>/dev/null || true)"
    if [ -n "$cache_dev" ]; then
        mkdir -p "$AUTO_MNT"
        if mount -o ro "$cache_dev" "$AUTO_MNT"; then
            AUTO_MOUNTED=1
            if [ -d "$AUTO_MNT/cache" ]; then
                CACHE_CANDIDATES+=("$AUTO_MNT/cache")
            else
                CACHE_CANDIDATES+=("$AUTO_MNT")
            fi
        fi
    fi
fi

verify_manifest_for_file() {
    local file="$1" dir manifest base expected actual
    dir="$(dirname "$file")"
    manifest="$dir/SHA256SUMS"
    base="$(basename "$file")"
    [ -f "$manifest" ] || return 0
    expected="$(awk -v f="$base" '$2==f || $2=="*"f {print $1; exit}' "$manifest")"
    [ -n "$expected" ] || return 0
    actual="$(sha256sum "$file" | awk '{print $1}')"
    [ "$actual" = "$expected" ] || {
        echo "ERRORE: checksum non valido per $file" >&2
        return 1
    }
    echo "SHA-256 OK: $base"
}

find_cached_deb() {
    local base file
    for base in "${CACHE_CANDIDATES[@]}"; do
        [ -d "$base/packages" ] || continue
        while IFS= read -r file; do
            [ -n "$file" ] || continue
            printf '%s\n' "$file"
            return 0
        done < <(find "$base/packages" -maxdepth 1 -type f \
            -name "libnccl2_*+cuda${CUDA_SERIES}_amd64.deb" -print | sort -V -r)
    done
    return 1
}

install_cached() {
    local deb="$1" pkg arch version
    verify_manifest_for_file "$deb"
    pkg="$(dpkg-deb -f "$deb" Package 2>/dev/null || true)"
    arch="$(dpkg-deb -f "$deb" Architecture 2>/dev/null || true)"
    version="$(dpkg-deb -f "$deb" Version 2>/dev/null || true)"
    [ "$pkg" = "libnccl2" ] || { echo "ERRORE: pacchetto inatteso: $pkg" >&2; return 1; }
    [ "$arch" = "amd64" ] || { echo "ERRORE: architettura inattesa: $arch" >&2; return 1; }
    case "$version" in
        *"+cuda${CUDA_SERIES}") ;;
        *) echo "ERRORE: versione NCCL non abbinata a CUDA ${CUDA_SERIES}: $version" >&2; return 1 ;;
    esac
    echo "Installo NCCL offline: $version"
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$deb"
}

ensure_nvidia_repo() {
    local keyring="" base candidate tmp
    if [ -f /usr/share/keyrings/cuda-archive-keyring.gpg ] && \
       ls /etc/apt/sources.list.d/cuda-ubuntu2404-* >/dev/null 2>&1; then
        return 0
    fi

    for base in "${CACHE_CANDIDATES[@]}"; do
        candidate="$base/packages/cuda-keyring_1.1-1_all.deb"
        if [ -f "$candidate" ]; then
            keyring="$candidate"
            break
        fi
    done

    if [ -z "$keyring" ]; then
        tmp="$(mktemp -d)"
        keyring="$tmp/cuda-keyring_1.1-1_all.deb"
        echo "Scarico il keyring NVIDIA..."
        wget -q --https-only \
            https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb \
            -O "$keyring"
    else
        verify_manifest_for_file "$keyring"
    fi
    dpkg -i "$keyring"
}

install_online() {
    local candidate
    ensure_nvidia_repo
    apt-get update

    if apt-cache madison libnccl2 | awk '{print $3}' | grep -Fxq "$PREFERRED_VERSION"; then
        candidate="$PREFERRED_VERSION"
    else
        candidate="$(apt-cache madison libnccl2 | awk -v s="+cuda${CUDA_SERIES}" 'length($3)>=length(s) && substr($3,length($3)-length(s)+1)==s {print $3}' | sort -V | tail -n1)"
    fi
    [ -n "$candidate" ] || {
        echo "ERRORE: nessuna versione libnccl2 per CUDA ${CUDA_SERIES} nel repository NVIDIA." >&2
        return 1
    }
    echo "Installo NCCL online: $candidate"
    DEBIAN_FRONTEND=noninteractive apt-get install -y "libnccl2=$candidate"
}

cached_deb="$(find_cached_deb || true)"
if [ -n "$cached_deb" ]; then
    install_cached "$cached_deb"
else
    echo "Pacchetto NCCL offline non trovato; uso il repository NVIDIA."
    install_online
fi

ldconfig
have_nccl || { echo "ERRORE: libnccl.so.2 ancora assente dopo l'installazione." >&2; exit 1; }

echo "NCCL installata correttamente:"
ldconfig -p | grep 'libnccl\.so\.2'
