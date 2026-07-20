#!/bin/bash
# =============================================================================
# build-iso.sh — Ubuntu 24.04 AI Rig, ISO multi-boot (DEVIN / HERMES / TEACHER)
# Sostituisce build-ai-rig-iso-v3.7.7.sh. Vedi README.md per il flusso completo.
# =============================================================================
set -Eeuo pipefail
cd "$(dirname "$0")"
ROOT_DIR="$(pwd)"

source config/rig.env

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
step()  { echo -e "${CYAN}[STEP]${NC} $1"; }

# =============================================================================
# Modalità produzione (fail-closed) + verifica integrità SHA-256.
# STRICT=1 (flag --production): placeholder, modelli/driver mancanti, download
# falliti e checksum assenti diventano ERRORI invece di warning. Un mismatch di
# checksum è SEMPRE un errore (anche in build normale): significa file corrotto.
# =============================================================================
STRICT=0
SHA_FILE="${ROOT_DIR}/config/artifacts.sha256"
BUILD_ID_FILE="${CACHE_DIR}/BUILD_ID"
CACHE_ID_SYNC_TARGET=""

usage() {
    cat <<EOF
Uso: $0 [--production] [--full] [--cache-disk /mnt/4tb] [--help]
  --production, -p   Build fail-closed: placeholder non compilati, payload o
                     checksum mancanti e prebuild fallita diventano bloccanti.
  --full             Include l'intera cache pesante nella ISO.
  --cache-disk PATH  Sincronizza l'intera cache sul 4TB dopo la build.
                     Senza questo flag viene comunque sincronizzato BUILD_ID.
  --help, -h         Questo messaggio.
EOF
}

strict_fail_or_warn() {
    if [ "$STRICT" -eq 1 ]; then
        error "$1"
    else
        warn "$1 [in --production sarebbe bloccante]"
    fi
}

prepare_build_id() {
    step "Genero identificatore univoco della build..."
    local raw git_rev
    git_rev="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"
    raw="${AI_RIG_BUILD_ID:-$(date -u +%Y%m%dT%H%M%SZ)-${git_rev}}"
    raw="$(printf '%s' "$raw" | tr -cd 'A-Za-z0-9._-')"
    [ -n "$raw" ] || error "BUILD_ID vuoto dopo la normalizzazione"
    mkdir -p "$CACHE_DIR"
    printf '%s\n' "$raw" > "$BUILD_ID_FILE"
    info "BUILD_ID: $raw"
}

sha_lookup() {  # $1 = basename -> hash atteso (o stringa vuota); ignora i commenti
    [ -f "$SHA_FILE" ] || { echo ""; return; }
    awk -v f="$1" '$0 !~ /^[[:space:]]*#/ && $2==f {print $1; exit}' "$SHA_FILE"
}

verify_sha() {  # $1 = percorso completo. Mismatch = errore sempre; assente = strict/warn.
    local path="$1" base expected actual
    [ -f "$path" ] || return 0
    base="$(basename "$path")"
    expected="$(sha_lookup "$base")"
    if [ -z "$expected" ]; then
        strict_fail_or_warn "SHA-256 assente per '$base' — aggiungi la riga in config/artifacts.sha256 (sha256sum '$base')"
        return 0
    fi
    actual="$(sha256sum "$path" | awk '{print $1}')"
    if [ "$actual" != "$expected" ]; then
        error "SHA-256 NON combacia per '$base' — download corrotto o file manomesso, cancellalo e riscarica.
  atteso:  $expected
  trovato: $actual"
    fi
    info "SHA-256 OK: $base"
}

check_deps() {
    step "Controllo prerequisiti..."
    # fdisk serve a rebuild_iso per localizzare la ESP dentro la ISO ufficiale.
    # isolinux/isohdpfx.bin NON serve piu' (fix 2026-07-16: boot ricostruito con
    # --grub2-mbr + append_partition, come le ISO Ubuntu ufficiali >= 20.10).
    local deps=("wget" "curl" "xorriso" "sed" "git" "rsync" "python3" "fdisk" "dd" "sha256sum" "blkid" "findmnt" "mountpoint" "mount" "umount" "install" "cmp" "readlink")
    for dep in "${deps[@]}"; do
        command -v "$dep" &> /dev/null || error "Manca: $dep"
    done
    # Spazio richiesto: ISO Ubuntu estratta (~3GB) + copia INTERA della cache
    # dentro iso-custom + ISO finale (≈ cache + 3GB). Con i modelli attuali la
    # cache pesa ~110GB → servono oltre 2x quella cifra. Calcolo dinamico.
    local cache_gb iso_est_gb needed_gb free_space
    cache_gb=$(du -sBG "$CACHE_DIR" 2>/dev/null | cut -f1 | tr -d 'G')
    cache_gb=${cache_gb:-0}
    if [ "${FULL_ISO:-0}" = "1" ]; then
        iso_est_gb=$((cache_gb + 4))
        needed_gb=$((cache_gb * 2 + 15))
    else
        # ISO LEGGERA: la cache pesante NON entra nella ISO → serve poco spazio.
        iso_est_gb=6
        needed_gb=20
    fi
    free_space=$(df -BG "$ROOT_DIR" 2>/dev/null | awk 'NR==2 {print $4}' | tr -d 'G')
    info "Cache: ~${cache_gb}GB → ISO stimata: ~${iso_est_gb}GB → spazio richiesto: ~${needed_gb}GB (liberi: ${free_space:-?}GB)"
    [ -n "$free_space" ] && [ "$free_space" -ge "$needed_gb" ] || \
        error "Servono ~${needed_gb}GB liberi in $ROOT_DIR (trovati: ${free_space:-?}GB). Libera spazio o sposta WORK_DIR su un disco piu' grande."
    warn "La chiavetta USB dovra' essere da almeno ${iso_est_gb}GB (scritta raw con dd/Etcher, il filesystem FAT non c'entra)."
    info "Prerequisiti OK."
}

check_placeholders() {
    step "Controllo placeholder non compilati in config/..."
    local found=0
    grep -q 'CHANGEME' config/disks.env && { warn "config/disks.env ha ancora seriali CHANGEME — vedi scripts/00-preflight.sh"; found=1; }
    grep -q 'AA:BB:CC:DD:EE:FF' config/network.env && { warn "config/network.env ha ancora MAC placeholder"; found=1; }
    if [ "$found" -eq 1 ]; then
        if [ "$STRICT" -eq 1 ]; then
            error "Placeholder non compilati in config/ e modalità --production attiva. Compila seriali/MAC (scripts/00-preflight.sh) e rilancia."
        fi
        warn "Puoi comunque proseguire per un build di TEST, ma l'IP statico e il WOL non funzioneranno finche' non compili questi valori e rilanci."
        read -rp "Continuare comunque? [y/N] " ans
        [[ "$ans" =~ ^[Yy]$ ]] || exit 1
    fi
}

check_model_cache() {
    step "Verifico cache modelli/driver..."
    mkdir -p "$CACHE_DIR"/{models/devin,models/hermes,models/teacher,comfyui-models}
    for role_file in config/roles/*.env; do
        # shellcheck disable=SC1090
        source "$role_file"
        local mpath="${CACHE_DIR}/models/${ROLE_NAME}/${ROLE_MODEL_FILE}"
        if [ -f "$mpath" ]; then
            verify_sha "$mpath"
        else
            strict_fail_or_warn "Modello mancante: $mpath (il ruolo ${ROLE_NAME} non partira' senza)"
        fi
        if [ -n "$ROLE_MMPROJ_FILE" ]; then
            local mmpath="${CACHE_DIR}/models/${ROLE_NAME}/${ROLE_MMPROJ_FILE}"
            if [ -f "$mmpath" ]; then
                verify_sha "$mmpath"
            else
                strict_fail_or_warn "mmproj mancante: $mmpath"
            fi
        fi
    done
    [ -f "${CACHE_DIR}/nvidia-driver.run" ] || warn "Driver NVIDIA mancante in cache (verra' scaricato)."
    [ -f "${CACHE_DIR}/cuda-toolkit.run" ] || warn "CUDA toolkit mancante in cache (verra' scaricato)."
    [ -f "${CACHE_DIR}/ai-rig-bot.pub" ] || warn "Chiave SSH del bot (ai-rig-bot.pub) non trovata: SSH passwordless dal Pi non sara' configurato."
}

download_deps() {
    step "Scarico dipendenze mancanti..."
    if [ ! -f "$UBUNTU_ISO_PATH" ]; then
        info "Scarico Ubuntu 24.04 Server ISO..."
        wget -c --show-progress "$UBUNTU_ISO_URL" -O "$UBUNTU_ISO_PATH"
    fi
    if [ ! -f "${CACHE_DIR}/nvidia-driver.run" ]; then
        wget -c --show-progress "$NVIDIA_DRIVER_URL" -O "${CACHE_DIR}/nvidia-driver.run" \
            || strict_fail_or_warn "download driver NVIDIA fallito (la ISO partirebbe senza driver)"
    fi
    if [ ! -f "${CACHE_DIR}/cuda-toolkit.run" ]; then
        wget -c --show-progress "$CUDA_TOOLKIT_URL" -O "${CACHE_DIR}/cuda-toolkit.run" \
            || strict_fail_or_warn "download CUDA toolkit fallito"
    fi
}

# Verifica integrità (SHA-256) di ISO/driver/CUDA — cattura sia i download appena
# fatti sia i file già in cache (una copia corrotta da un download precedente
# interrotto entrerebbe altrimenti nella ISO senza segnali).
verify_downloads() {
    step "Verifico integrità (SHA-256) di ISO base, driver e CUDA..."
    verify_sha "$UBUNTU_ISO_PATH"
    verify_sha "${CACHE_DIR}/nvidia-driver.run"
    verify_sha "${CACHE_DIR}/cuda-toolkit.run"
}

try_prebuild_llama() {
    step "Pre-compilo ${LLAMA_FLAVOR} (una volta sola, poi copiato su tutti e 3 i dischi)..."
    if [ -x "${CACHE_DIR}/llama-prebuilt/bin/llama-server" ]; then
        local built_flavor
        built_flavor=$(cat "${CACHE_DIR}/llama-prebuilt/FLAVOR" 2>/dev/null || echo "sconosciuto")
        if [ "$built_flavor" = "$LLAMA_FLAVOR" ]; then
            info "Build ${LLAMA_FLAVOR} gia' in cache, salto."
            return 0
        fi
        warn "In cache c'e' una build '${built_flavor}' ma ora vuoi '${LLAMA_FLAVOR}': la rifaccio."
        rm -rf "${CACHE_DIR}/llama-prebuilt"
    fi
    command -v nvcc &> /dev/null || { warn "nvcc non trovato: verra' compilato su ogni disco al primo boot (molto lento con beellama)."; return 1; }
    local build_dir="${ROOT_DIR}/llama-prebuild"
    rm -rf "$build_dir"; mkdir -p "$build_dir"
    git clone --depth 1 "$LLAMA_REPO" "$build_dir"
    cd "$build_dir"
    # shellcheck disable=SC2086
    cmake -B build -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES="${CUDA_ARCHS}" \
        -DGGML_CUDA_FORCE_MMQ=ON ${LLAMA_CMAKE_EXTRA} \
        -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF
    cmake --build build --config Release -j"$(nproc)"
    mkdir -p "${CACHE_DIR}/llama-prebuilt"
    cp -r build/bin "${CACHE_DIR}/llama-prebuilt/"
    echo "$LLAMA_FLAVOR" > "${CACHE_DIR}/llama-prebuilt/FLAVOR"
    cd "$ROOT_DIR"
    [ -x "${CACHE_DIR}/llama-prebuilt/bin/llama-server" ] && info "${LLAMA_FLAVOR} pre-compilato OK." || { warn "pre-build fallita"; rm -rf "${CACHE_DIR}/llama-prebuilt"; return 1; }
}

generate_nocloud() {
    step "Genero nocloud/, rig-common/, rig-roles/ da config/ + templates/..."
    # 'bash' esplicito: non dipende dal bit +x, che si perde copiando i file a mano
    bash ./scripts/05-generate-nocloud.sh
}

validate_generated_artifacts() {
    step "Valido script e YAML generati..."
    local script
    while IFS= read -r -d '' script; do
        bash -n "$script" || error "Sintassi Bash non valida: $script"
    done < <(find scripts rig-common rig-roles -type f -name '*.sh' -print0)

    if python3 -c 'import yaml' >/dev/null 2>&1; then
        python3 - <<'PYVALIDATE'
from pathlib import Path
import yaml
for path in sorted(Path("nocloud").glob("*/user-data")):
    with path.open("r", encoding="utf-8") as fh:
        data = yaml.safe_load(fh)
    if not isinstance(data, dict) or "autoinstall" not in data:
        raise SystemExit(f"user-data non valido: {path}")
print("YAML NoCloud validi")
PYVALIDATE
    else
        strict_fail_or_warn "Modulo Python PyYAML assente: impossibile validare i user-data"
    fi

    for role in devin hermes teacher; do
        grep -q '__ROLE__\|__TARGET_SERIAL__' "nocloud/$role/user-data" \
            && error "Placeholder runtime residuo in nocloud/$role/user-data"
    done
    grep -q '__ROLE__' nocloud/auto/user-data \
        || error "Placeholder __ROLE__ assente in nocloud/auto/user-data"
    grep -q '__TARGET_SERIAL__' nocloud/auto/user-data \
        || error "Placeholder __TARGET_SERIAL__ assente in nocloud/auto/user-data"
    [ -s "$BUILD_ID_FILE" ] || error "BUILD_ID non generato"
    for role in auto devin hermes teacher; do
        grep -q '/etc/ai-rig/build-id' "nocloud/$role/user-data" \
            || error "Persistenza BUILD_ID assente in nocloud/$role/user-data"
    done
    grep -q 'BUILD_ID_FILE="/cdrom/cache/BUILD_ID"' rig-common/scripts/select-next-role.sh \
        || error "select-next-role generato senza controllo BUILD_ID"

    info "Validazione statica completata."
}

# Cleanup mount ISO (audit #19, 2026-07-10): se una copia fallisce dopo il
# mount, il loop device restava montato fino a riavvio/umount manuale.
_cleanup_iso_mount() {
    if mountpoint -q "$ISO_MOUNT" 2>/dev/null; then
        sudo umount "$ISO_MOUNT" 2>/dev/null || true
    fi
}
trap _cleanup_iso_mount EXIT INT TERM

extract_iso() {
    step "Estraggo ISO Ubuntu..."
    rm -rf "$ISO_MOUNT" "$ISO_CUSTOM"
    mkdir -p "$ISO_MOUNT" "$ISO_CUSTOM"
    sudo mount -o loop,ro -t iso9660 "$UBUNTU_ISO_PATH" "$ISO_MOUNT"
    cp -rT "$ISO_MOUNT" "$ISO_CUSTOM"
    sudo umount "$ISO_MOUNT"
    chmod -R u+w "$ISO_CUSTOM"
    info "ISO estratta."
}

copy_payload_to_iso() {
    step "Copio nocloud/, rig-common/, rig-roles/, scripts/ nella ISO..."
    cp -r "$NOCLOUD_DIR" "$ISO_CUSTOM/"
    cp -r "$ROOT_DIR/rig-common" "$ISO_CUSTOM/"
    cp -r "$ROOT_DIR/rig-roles" "$ISO_CUSTOM/"
    mkdir -p "$ISO_CUSTOM/cache/requirements" "$ISO_CUSTOM/cache/config"

    # ISO LEGGERA (default 2026-07-16): NON si bakano piu' i ~110GB di cache
    # (modelli/driver/cuda/llama/comfyui). Copiarli da USB durante l'install era
    # fragile e abortiva il provisioning (bug sul campo). La cache pesante la
    # copia `populate-cache.sh` DOPO l'install, disk-to-disk. Nella ISO restano
    # solo i pezzi PICCOLI. Per la vecchia ISO "tutto-incluso": build-iso.sh --full.
    if [ "${FULL_ISO:-0}" = "1" ]; then
        step "Modalita' FULL: baco l'intera cache (~110GB) nella ISO..."
        rsync -a --info=progress2 "$CACHE_DIR"/ "$ISO_CUSTOM/cache"/ \
            || error "Copia cache fallita (spazio? permessi?) — vedi output rsync sopra."
    else
        info "ISO LEGGERA: cache pesante ESCLUSA (models/driver/cuda/llama/comfyui). Usa populate-cache.sh dopo l'install."
        # solo i pezzi piccoli e necessari a boot/provisioning:
        cp "$BUILD_ID_FILE" "$ISO_CUSTOM/cache/BUILD_ID"
        [ -f "$CACHE_DIR/ai-rig-bot.pub" ] && cp "$CACHE_DIR/ai-rig-bot.pub" "$ISO_CUSTOM/cache/" || true
        [ -d "$CACHE_DIR/drivedb" ] && cp -r "$CACHE_DIR/drivedb" "$ISO_CUSTOM/cache/" || true
    fi

    [ -s "$ISO_CUSTOM/cache/BUILD_ID" ] || cp "$BUILD_ID_FILE" "$ISO_CUSTOM/cache/BUILD_ID"
    cp requirements/*.txt "$ISO_CUSTOM/cache/requirements/"
    cp config/*.env config/*.json "$ISO_CUSTOM/cache/config/"
    # scripts/ accessibile live da /cdrom/scripts/ (01-wipe-disks.sh, 00-preflight.sh)
    # e sopravvive sul disco installato in /opt/cache/scripts/ (grub-stable-entries.sh ecc.)
    cp -r "$ROOT_DIR/scripts" "$ISO_CUSTOM/"
    cp -r "$ROOT_DIR/scripts" "$ISO_CUSTOM/cache/"
    du -sh "$ISO_CUSTOM/cache"
}

patch_bootloader() {
    step "Aggiungo 3 voci di boot (DEVIN / HERMES / TEACHER) a GRUB + isolinux..."
    local grub_cfg="$ISO_CUSTOM/boot/grub/grub.cfg"
    if [ -f "$grub_cfg" ]; then
        local tmp="${grub_cfg}.tmp"
        {
            echo "menuentry \"Install AI Rig (AUTO - catena 3 ruoli)\" {"
            echo "    set gfxpayload=keep"
            echo "    linux /casper/vmlinuz autoinstall ds=nocloud\\;s=/cdrom/nocloud/auto/ ---"
            echo "    initrd /casper/initrd"
            echo "}"
            for role in devin hermes teacher; do
                echo "menuentry \"Install AI Rig - ${role^^}\" {"
                echo "    set gfxpayload=keep"
                echo "    linux /casper/vmlinuz autoinstall ds=nocloud\\;s=/cdrom/nocloud/${role}/ ---"
                echo "    initrd /casper/initrd"
                echo "}"
            done
            echo ""
            cat "$grub_cfg"
        } > "$tmp"
        mv "$tmp" "$grub_cfg"
        info "GRUB patched (3 entry)."
    fi
    local isolinux_cfg="$ISO_CUSTOM/isolinux/txt.cfg"
    if [ -f "$isolinux_cfg" ]; then
        local tmp="${isolinux_cfg}.tmp"
        {
            echo "label auto-install-auto"
            echo "  menu label ^Install AI Rig (AUTO - catena 3 ruoli)"
            echo "  kernel /casper/vmlinuz"
            echo "  append autoinstall ds=nocloud;s=/cdrom/nocloud/auto/ initrd=/casper/initrd quiet ---"
            echo ""
            for role in devin hermes teacher; do
                echo "label auto-install-${role}"
                echo "  menu label ^Install AI Rig - ${role^^}"
                echo "  kernel /casper/vmlinuz"
                echo "  append autoinstall ds=nocloud;s=/cdrom/nocloud/${role}/ initrd=/casper/initrd quiet ---"
                echo ""
            done
            cat "$isolinux_cfg"
        } > "$tmp"
        mv "$tmp" "$isolinux_cfg"
        info "ISOLINUX patched (3 entry)."
    fi
}

rebuild_iso() {
    step "Ricostruisco ISO (Level 3, file >4GB, boot BIOS+UEFI con layout ufficiale Ubuntu)..."
    # =========================================================================
    # FIX (2026-07-16): la vecchia invocazione usava
    #     -e EFI/boot/bootx64.efi -no-emul-boot -isohybrid-gpt-basdat
    # cioe' passava a El Torito il SINGOLO ESEGUIBILE PE bootx64.efi come
    # "immagine EFI". Il firmware UEFI si aspetta invece una vera immagine
    # filesystem FAT (una ESP con dentro \EFI\BOOT\BOOTX64.EFI). Risultato:
    # sul supporto scritto raw la "partizione EFI" (944,5 KiB, FSTYPE vuoto)
    # conteneva solo il binario shim -> nessun firmware la montava -> il disco
    # USB non compariva mai tra le voci di boot UEFI.
    # Ora estraiamo dalla ISO Ubuntu originale la ESP vera (efi.img) e il
    # template MBR GRUB2, e replichiamo il layout ufficiale delle ISO Ubuntu
    # >= 20.10 (ricetta xorriso: --grub2-mbr + -append_partition ... GPT).
    # Non serve piu' isolinux/isohdpfx.bin.
    # =========================================================================
    local mbr_img="${WORK_DIR}/boot-mbr-grub2.img"
    local efi_img="${WORK_DIR}/boot-esp.img"
    local esp_skip esp_size
    step "Estraggo MBR GRUB2 + partizione ESP dalla ISO ufficiale..."
    dd if="$UBUNTU_ISO_PATH" bs=1 count=432 of="$mbr_img" status=none
    esp_skip=$(fdisk -l "$UBUNTU_ISO_PATH" 2>/dev/null | awk '/EFI System/ {print $2; exit}')
    esp_size=$(fdisk -l "$UBUNTU_ISO_PATH" 2>/dev/null | awk '/EFI System/ {print $4; exit}')
    { [ -n "$esp_skip" ] && [ -n "$esp_size" ]; } || \
        error "Partizione 'EFI System' non trovata in $UBUNTU_ISO_PATH (fdisk -l). ISO base corrotta o layout inatteso."
    dd if="$UBUNTU_ISO_PATH" bs=512 skip="$esp_skip" count="$esp_size" of="$efi_img" status=none
    info "ESP estratta: $(du -h "$efi_img" | cut -f1) (settori ${esp_skip}..$((esp_skip + esp_size - 1)))"

    cd "$ISO_CUSTOM"
    xorriso -as mkisofs \
        -iso-level 3 -r -V "Ubuntu 24.04 AI Rig" \
        -o "$OUTPUT_ISO" \
        -J -joliet-long \
        --grub2-mbr "$mbr_img" \
        -partition_offset 16 \
        --mbr-force-bootable \
        -append_partition 2 28732ac11ff8d211ba4b00a0c93ec93b "$efi_img" \
        -appended_part_as_gpt \
        -iso_mbr_part_type a2a0d0ebe5b9334487c068b6b72699c7 \
        -c '/boot.catalog' \
        -b '/boot/grub/i386-pc/eltorito.img' \
        -no-emul-boot -boot-load-size 4 -boot-info-table --grub2-boot-info \
        -eltorito-alt-boot \
        -e '--interval:appended_partition_2:::' \
        -no-emul-boot \
        .
    cd "$ROOT_DIR"
    rm -f "$mbr_img" "$efi_img"
    info "ISO creata: $OUTPUT_ISO"
    ls -lh "$OUTPUT_ISO"
}

verify_built_iso() {
    step "Verifico struttura BIOS/UEFI e integrità della ISO finale..."
    [ -s "$OUTPUT_ISO" ] || error "ISO finale assente o vuota: $OUTPUT_ISO"
    local report="${OUTPUT_ISO}.boot-report.txt"
    xorriso -indev "$OUTPUT_ISO" -report_el_torito plain > "$report" 2>&1 \
        || error "xorriso non riesce a leggere la ISO finale"
    grep -qi 'UEFI\|EFI' "$report" \
        || error "Nessuna entry EFI rilevata nel report El Torito"
    fdisk -l "$OUTPUT_ISO" 2>/dev/null | grep -q 'EFI System' \
        || error "Partizione EFI System assente dalla ISO finale"
    sha256sum "$OUTPUT_ISO" > "${OUTPUT_ISO}.sha256"
    info "ISO verificata; checksum: ${OUTPUT_ISO}.sha256"
}

sync_cache_to_disk() {
    [ -n "${CACHE_DISK_MNT:-}" ] || return 0   # solo se --cache-disk passato
    step "Riempio il disco-cache (${CACHE_DISK_MNT}) con la cache — stesso build, un colpo solo..."
    [ -d "$CACHE_DISK_MNT" ] || error "--cache-disk: '${CACHE_DISK_MNT}' non esiste."
    mountpoint -q "$CACHE_DISK_MNT" \
        || error "--cache-disk: '${CACHE_DISK_MNT}' non è un mountpoint; blocco per non copiare sulla root per errore."
    local lbl cache_source
    cache_source="$(findmnt -no SOURCE --target "$CACHE_DISK_MNT" 2>/dev/null || true)"
    [ -n "$cache_source" ] || error "Impossibile determinare il device montato su $CACHE_DISK_MNT"
    lbl="$(lsblk -no LABEL "$cache_source" 2>/dev/null || true)"
    if [ "$lbl" != "ai-rig-cache" ]; then
        if [ "$STRICT" -eq 1 ]; then
            error "Etichetta disco cache non valida: '${lbl:-nessuna}' (attesa: ai-rig-cache)"
        fi
        warn "Etichetta disco = '${lbl:-nessuna}' (attesa: ai-rig-cache)."
    fi
    [ -s "$BUILD_ID_FILE" ] || error "BUILD_ID assente prima della sincronizzazione cache"
    mkdir -p "${CACHE_DISK_MNT}/cache"
    rsync -a --partial --partial-dir=.rsync-partial --info=progress2 "$CACHE_DIR"/ "${CACHE_DISK_MNT}/cache"/ \
        || error "Copia cache sul 4TB fallita (spazio? disco pieno?) — vedi rsync sopra."
    info "Cache sul 4TB pronta:"; du -sh "${CACHE_DISK_MNT}/cache" 2>/dev/null || true
}


sync_build_id_to_cache_disk() {
    step "Sincronizzo BUILD_ID sul disco-cache ai-rig-cache..."
    local dev target label tmp auto_mounted=0

    [ -s "$BUILD_ID_FILE" ] || error "BUILD_ID locale assente o vuoto: $BUILD_ID_FILE"

    if [ -n "${CACHE_DISK_MNT:-}" ]; then
        target="$CACHE_DISK_MNT"
        mountpoint -q "$target" \
            || error "--cache-disk: '$target' non è un mountpoint"
        dev="$(findmnt -rn -o SOURCE --target "$target" 2>/dev/null | head -n1)"
        [ -n "$dev" ] || error "Impossibile determinare il device montato su $target"
    else
        dev="$(blkid -L ai-rig-cache 2>/dev/null || true)"
        if [ -z "$dev" ]; then
            strict_fail_or_warn "Disco-cache 'ai-rig-cache' non rilevato: impossibile sincronizzare cache/BUILD_ID"
            return 0
        fi
        dev="$(readlink -f "$dev")"
        target="$(findmnt -rn -S "$dev" -o TARGET 2>/dev/null | head -n1 || true)"
        if [ -z "$target" ]; then
            target="/run/ai-rig-cache-build"
            mkdir -p "$target"
            mount -o rw "$dev" "$target" \
                || error "Impossibile montare $dev in lettura/scrittura su $target"
            auto_mounted=1
        fi
    fi

    label="$(blkid -s LABEL -o value "$dev" 2>/dev/null || true)"
    if [ "$label" != "ai-rig-cache" ]; then
        if [ "$auto_mounted" -eq 1 ]; then
            umount "$target" 2>/dev/null || true
        fi
        error "Disco cache inatteso: label '${label:-nessuna}', attesa 'ai-rig-cache'"
    fi

    mkdir -p "$target/cache" || {
        [ "$auto_mounted" -eq 1 ] && umount "$target" 2>/dev/null || true
        error "Impossibile creare $target/cache"
    }

    tmp="$target/cache/.BUILD_ID.tmp.$$"
    if ! install -m 0644 "$BUILD_ID_FILE" "$tmp"; then
        [ "$auto_mounted" -eq 1 ] && umount "$target" 2>/dev/null || true
        error "Copia temporanea BUILD_ID fallita su $target/cache"
    fi
    if ! mv -f "$tmp" "$target/cache/BUILD_ID"; then
        rm -f "$tmp" 2>/dev/null || true
        [ "$auto_mounted" -eq 1 ] && umount "$target" 2>/dev/null || true
        error "Sostituzione atomica BUILD_ID fallita su $target/cache"
    fi
    if ! cmp -s "$BUILD_ID_FILE" "$target/cache/BUILD_ID"; then
        [ "$auto_mounted" -eq 1 ] && umount "$target" 2>/dev/null || true
        error "Verifica BUILD_ID fallita: ISO/cache locale e 4TB non coincidono"
    fi

    sync
    CACHE_ID_SYNC_TARGET="$dev:/cache/BUILD_ID"
    info "BUILD_ID sincronizzato e verificato: $CACHE_ID_SYNC_TARGET"

    if [ "$auto_mounted" -eq 1 ]; then
        umount "$target" || error "BUILD_ID scritto, ma umount di $target fallito"
    fi
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --production|-p) STRICT=1 ;;
            --full) FULL_ISO=1 ;;   # baka l'intera cache (~110GB) nella ISO (vecchio comportamento)
            --cache-disk)
                [ $# -ge 2 ] || error "--cache-disk richiede un percorso"
                CACHE_DISK_MNT="$2"
                shift
                ;;
            --help|-h) usage; exit 0 ;;
            *) error "Argomento sconosciuto: $1 (usa --help)" ;;
        esac
        shift
    done

    # Ripristina i bit di esecuzione (si perdono copiando i file a mano) — difensivo
    chmod +x scripts/*.sh rig-common-scripts/*.sh build-iso.sh 2>/dev/null || true

    # Log completo + log filtrato di soli warning/errori
    BUILD_LOG="${ROOT_DIR}/build.log"
    BUILD_WARN_LOG="${ROOT_DIR}/build-warnings.log"
    exec > >(tee "$BUILD_LOG") 2>&1

    echo "========================================"
    echo " Build AI Rig ISO — Multi-boot v4.0"
    echo " DEVIN + HERMES + TEACHER"
    echo "========================================"
    [ "$STRICT" -eq 1 ] && step "Modalità PRODUCTION (fail-closed) attiva: warning critici → errori."
    check_deps
    check_placeholders
    prepare_build_id
    check_model_cache
    download_deps
    verify_downloads
    if ! try_prebuild_llama; then
        [ "$STRICT" -eq 1 ] && error "Prebuild ${LLAMA_FLAVOR} fallita in modalità production"
        warn "Prebuild fallita: la build di TEST resta possibile, ma la catena AUTO richiede il prebuilt sul 4TB"
    fi
    generate_nocloud
    validate_generated_artifacts
    extract_iso
    copy_payload_to_iso
    patch_bootloader
    rebuild_iso
    verify_built_iso
    sync_cache_to_disk   # con --cache-disk: sincronizza l'intera cache
    sync_build_id_to_cache_disk  # sempre: allinea almeno cache/BUILD_ID sul 4TB

    # Estrai solo errori/warning "veri" dal log, escludendo il rumore noto e
    # innocuo della compilazione (double-promotion nei test, unused-parameter,
    # missing-declarations, deprecation nvcc per sm_61 — attesa su Pascal).
    grep -inE 'error|warn|fail|denied|cannot|not found|no such' "$BUILD_LOG" \
        | grep -viE 'double-promotion|unused-parameter|missing-declarations|missing-field-initializers|deprecated-gpu-targets|diag-suppress|#177-D|Wno-|declared but never referenced|no previous declaration' \
        > "$BUILD_WARN_LOG" || true

    echo ""
    echo "========================================"
    echo " BUILD COMPLETATA: $OUTPUT_ISO"
    echo " BUILD_ID: $(cat "$BUILD_ID_FILE")"
    echo "========================================"
    if [ -s "$BUILD_WARN_LOG" ]; then
        echo " ⚠️  Warning/errori rilevanti filtrati in: $BUILD_WARN_LOG ($(wc -l < "$BUILD_WARN_LOG") righe)"
        echo "    (log completo: $BUILD_LOG)"
    else
        echo " ✅ Nessun warning/errore rilevante (log completo: $BUILD_LOG)"
    fi
    echo "ISO LEGGERA (~5GB): scrivila su una CHIAVETTA PICCOLA (dd/Etcher)."
    if [ -n "${CACHE_DISK_MNT:-}" ]; then
        echo "Cache completa sincronizzata sul 4TB (${CACHE_DISK_MNT}/cache)."
    else
        echo "Cache pesante non ricopiata (gia' presente); BUILD_ID sincronizzato su: ${CACHE_ID_SYNC_TARGET:-non disponibile}."
    fi
    echo "Avvia la voce 'Install AI Rig (AUTO - catena 3 ruoli)' con chiavetta e 4TB collegati."
    echo "La catena installerà DEVIN -> HERMES -> TEACHER e tornerà su DEVIN per il GRUB centrale."
    echo "Fallback manuale: usa le tre voci ruolo e poi sudo populate-cache.sh su ciascun sistema."
}

main "$@"
