#!/bin/bash
# =============================================================================
# Genera, per ciascun ruolo (devin/hermes/teacher):
#   - nocloud/<role>/user-data + meta-data   (autoinstall)
#   - rig-roles/<role>/scripts/start-llama-<role>.sh
#   - rig-roles/<role>/scripts/role-provision.sh
# a partire da config/*.env, packages/*.apt, requirements/*.txt e templates/*.
# Va rieseguito ogni volta che cambi un file in config/ prima di ricostruire la ISO.
# =============================================================================
set -Eeuo pipefail
cd "$(dirname "$0")/.."
ROOT_DIR="$(pwd)"

source config/rig.env
source config/network.env
source config/disks.env
source config/shared-disk.env

# Guardia seriali duplicati (audit 2026-07-10): due ruoli con lo stesso seriale
# = due autoinstall sullo STESSO disco, la seconda distrugge la prima. Meglio
# fermarsi al build che scoprirlo a install fatta. (CHANGEME e' gia' gestito a
# parte dal check placeholder di build-iso.sh, qui blocco solo i duplicati reali.)
for pair in "DEVIN:HERMES" "DEVIN:TEACHER" "HERMES:TEACHER"; do
    a="${pair%%:*}_DISK_SERIAL"; b="${pair##*:}_DISK_SERIAL"
    if [ -n "${!a}" ] && [[ "${!a}" != CHANGEME* ]] && [ "${!a}" = "${!b}" ]; then
        echo "!!! disks.env: ${pair%%:*} e ${pair##*:} hanno lo STESSO seriale (${!a})." >&2
        echo "!!! Due install sullo stesso disco si distruggerebbero a vicenda. Correggi." >&2
        exit 1
    fi
done

# Il 4° disco condiviso NON deve coincidere con un disco ruolo: verrebbe
# formattato dall'autoinstall del ruolo e/o riformattato da 50-shared-disk.sh.
if [ -n "${SHARED_DISK_SERIAL:-}" ] && [[ "${SHARED_DISK_SERIAL}" != CHANGEME* ]]; then
    for role_var in DEVIN_DISK_SERIAL HERMES_DISK_SERIAL TEACHER_DISK_SERIAL; do
        if [ "${SHARED_DISK_SERIAL}" = "${!role_var}" ]; then
            echo "!!! Il disco CONDIVISO ha lo stesso seriale di ${role_var%%_DISK_SERIAL} (${SHARED_DISK_SERIAL})." >&2
            echo "!!! Collisione: correggi shared-disk.env o disks.env." >&2
            exit 1
        fi
    done
fi

DNS_YAML=$(echo "$DNS_SERVERS" | tr ' ' ',' | sed 's/,/, /g')

# #23 audit: valori con & | \ rompono la sostituzione sed (& = intero match,
# | = delimitatore usato qui, \ = escape). _sedq rende sicuro un valore da usare
# come RIMPIAZZO in "s|...|VAL|". Applicato ai valori free-text (arg llama, path,
# repo, nomi file); gli altri (ruolo, porte, temp, flavor) sono safe-by-construction.
_sedq() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

render_role_scripts() {
    local role="$1"; shift
    local model_file="$1" mmproj_file="$2" port="$3" ctx="$4" temp="$5" top_p="$6" rp="$7" extra="$8"

    local out_dir="${ROOT_DIR}/rig-roles/${role}/scripts"
    local systemd_dir="${ROOT_DIR}/rig-roles/${role}/systemd"
    mkdir -p "$out_dir" "$systemd_dir"

    sed \
        -e "s|__ROLE_NAME__|${role}|g" \
        -e "s|__ROLE_MODEL_FILE__|$(_sedq "${model_file}")|g" \
        -e "s|__ROLE_MMPROJ_FILE__|$(_sedq "${mmproj_file}")|g" \
        -e "s|__ROLE_LLAMA_PORT__|${port}|g" \
        -e "s|__ROLE_CTX_SIZE__|${ctx}|g" \
        -e "s|__ROLE_TEMP__|${temp}|g" \
        -e "s|__ROLE_TOP_P__|${top_p}|g" \
        -e "s|__ROLE_REPEAT_PENALTY__|${rp}|g" \
        -e "s|__ROLE_EXTRA_ARGS__|$(_sedq "${extra}")|g" \
        -e "s|__ROLE_REASONING_FORMAT__|${ROLE_REASONING_FORMAT:-none}|g" \
        -e "s|__ROLE_REASONING_BUDGET__|${ROLE_REASONING_BUDGET:-}|g" \
        -e "s|__ROLE_CHAT_TEMPLATE_KWARGS__|$(_sedq "${ROLE_CHAT_TEMPLATE_KWARGS:-}")|g" \
        -e "s|__ROLE_JINJA__|${ROLE_JINJA:-0}|g" \
        -e "s|__LLAMA_FLAVOR__|${LLAMA_FLAVOR}|g" \
        -e "s|__LLAMA_CACHE_TYPE_K__|${LLAMA_CACHE_TYPE_K}|g" \
        -e "s|__LLAMA_CACHE_TYPE_V__|${LLAMA_CACHE_TYPE_V}|g" \
        -e "s|__LLAMA_FLASH_ATTN__|${LLAMA_FLASH_ATTN}|g" \
        templates/role-provision.sh.tmpl > "${out_dir}/role-provision.sh"

    sed \
        -e "s|__ROLE_NAME__|${role}|g" \
        templates/start-llama-role.sh.tmpl > "${out_dir}/start-llama-${role}.sh"

    chmod +x "${out_dir}/role-provision.sh" "${out_dir}/start-llama-${role}.sh"

    # Extra solo per hermes (Hermes-Agent + ComfyUI)
    if [ "$role" = "hermes" ] && [ -f templates/hermes-extras.sh.tmpl ]; then
        sed \
            -e "s|__ROLE_LLAMA_PORT__|${port}|g" \
            -e "s|__ROLE_CTX_SIZE__|${ctx}|g" \
            -e "s|__SHARED_MOUNT_PATH__|$(_sedq "${SHARED_MOUNT_PATH}")|g" \
            templates/hermes-extras.sh.tmpl > "${out_dir}/40-hermes-extras.sh"
        chmod +x "${out_dir}/40-hermes-extras.sh"
        sed \
            -e "s|__SHARED_MOUNT_PATH__|$(_sedq "${SHARED_MOUNT_PATH}")|g" \
            templates/ai-rig-hermes-extras.service.tmpl > "${systemd_dir}/ai-rig-hermes-extras.service"
    fi
}

render_common_scripts() {
    mkdir -p "${ROOT_DIR}/rig-common/scripts" "${ROOT_DIR}/rig-common/systemd"
    for f in rig-common-scripts/*.sh; do
        sed \
            -e "s|__CUDA_ARCHS__|${CUDA_ARCHS}|g" \
            -e "s|__WOL_MAC__|${WOL_MAC}|g" \
            -e "s|__LAN_MAC__|${LAN_MAC}|g" \
            -e "s|__STATIC_IP__|${STATIC_IP}|g" \
            -e "s|__GATEWAY__|${GATEWAY}|g" \
            -e "s|__DNS_SERVERS_YAML__|${DNS_YAML}|g" \
            -e "s|__SHARED_DISK_SERIAL__|${SHARED_DISK_SERIAL}|g" \
            -e "s|__SHARED_MOUNT_PATH__|$(_sedq "${SHARED_MOUNT_PATH}")|g" \
            -e "s|__LLAMA_FLAVOR__|${LLAMA_FLAVOR}|g" \
            -e "s|__LLAMA_REPO__|$(_sedq "${LLAMA_REPO}")|g" \
            -e "s|__LLAMA_CMAKE_EXTRA__|$(_sedq "${LLAMA_CMAKE_EXTRA}")|g" \
            -e "s|__LLAMA_CACHE_TYPE_K__|${LLAMA_CACHE_TYPE_K}|g" \
            -e "s|__LLAMA_CACHE_TYPE_V__|${LLAMA_CACHE_TYPE_V}|g" \
            -e "s|__LLAMA_FLASH_ATTN__|${LLAMA_FLASH_ATTN}|g" \
            "$f" > "${ROOT_DIR}/rig-common/scripts/$(basename "$f")"
        chmod +x "${ROOT_DIR}/rig-common/scripts/$(basename "$f")"
    done
    # select-next-role.sh — early-command della voce AUTO (catena auto-install).
    # Bakea i 3 seriali-ruolo (whitelist). Finisce in /cdrom/rig-common/scripts/.
    if [ -f templates/select-next-role.sh.tmpl ]; then
        sed \
            -e "s|__DEVIN_DISK_SERIAL__|${DEVIN_DISK_SERIAL}|g" \
            -e "s|__HERMES_DISK_SERIAL__|${HERMES_DISK_SERIAL}|g" \
            -e "s|__TEACHER_DISK_SERIAL__|${TEACHER_DISK_SERIAL}|g" \
            templates/select-next-role.sh.tmpl > "${ROOT_DIR}/rig-common/scripts/select-next-role.sh"
        chmod +x "${ROOT_DIR}/rig-common/scripts/select-next-role.sh"
    fi
    cp rig-common-scripts/*.py "${ROOT_DIR}/rig-common/scripts/" 2>/dev/null || true
    cp rig-common-systemd/*.service rig-common-systemd/*.timer "${ROOT_DIR}/rig-common/systemd/" 2>/dev/null || \
    cp rig-common-systemd/*.service "${ROOT_DIR}/rig-common/systemd/"
    # systemd template unit (llama-server@.service) copiato cosi' com'e', nessuna sostituzione: usa %i
    cp templates/llama-server@.service.tmpl "${ROOT_DIR}/rig-common/systemd/llama-server@.service"
}

build_apt_yaml() {
    local common_file="$1" role_file="$2"
    { grep -vE '^\s*#|^\s*$' "$common_file" 2>/dev/null || true
      grep -vE '^\s*#|^\s*$' "$role_file" 2>/dev/null || true
    } | sed 's/^/    - /'
}

generate_user_data() {
    local role="$1" hostname="$2" disk_serial="$3" disk_bypath="$4" apt_file="$5"
    mkdir -p "${ROOT_DIR}/nocloud/${role}"
    touch "${ROOT_DIR}/nocloud/${role}/meta-data"

    local disk_match
    if [ -n "$disk_bypath" ]; then
        disk_match="          path: \"${disk_bypath}\""
    else
        # FIX 2026-07-16 (visto sul campo: "seriale non trovato" al primo
        # install reale): subiquity confronta match.serial con l'ID_SERIAL
        # udev COMPLETO (MODELLO_SERIALE, es. PNY_CS900_..._PNY2138...),
        # NON col SERIAL corto di lsblk che usiamo in disks.env. Il match
        # supporta il globbing, quindi *seriale* matcha entrambi i formati.
        # (Il seriale corto e' unico per disco: nessun rischio di doppio match.)
        disk_match="          serial: \"*${disk_serial}*\""
    fi

    local apt_yaml
    apt_yaml=$(build_apt_yaml "packages/common.apt" "$apt_file")

    local extra_enable=""
    # ai-rig-hermes-extras (ComfyUI) e' PESANTE (serve i modelli): NON qui,
    # la abilita populate-cache.sh dopo la copia cache. Solo il bot resta leggero.
    # Bot Telegram dedicato al ruolo: si abilita insieme al ruolo, quindi parte
    # da solo all'avvio. Finche' /etc/<role>-bot/config.env non ha un BOT_TOKEN
    # valido lo script esce con errore e systemd ritenta ogni RestartSec (30s):
    # nel momento in cui riempi la config, il bot sale da solo senza start manuale.
    case "$role" in
        devin)   extra_enable="${extra_enable} devin-bot.service" ;;
        hermes)  extra_enable="${extra_enable} hermes-bot.service" ;;
        teacher) extra_enable="${extra_enable} teacher-bot.service" ;;
    esac

    # Token bot bakeati (2026-07-11): se esiste config/<role>-bot.env (compilato
    # da te, NON versionato), il build lo copia in cache/config/ e la late-command
    # sotto lo mette in /etc/<role>-bot/config.env sul disco del ruolo. Owner:
    # teacher-bot gira come root, devin/hermes come l'utente di default.
    local bot_owner="$DEFAULT_USERNAME"
    [ "$role" = "teacher" ] && bot_owner="root"

    cat > "${ROOT_DIR}/nocloud/${role}/user-data" << EOFUSERDATA
#cloud-config
autoinstall:
  version: 1
  locale: it_IT.UTF-8
  keyboard:
    layout: it
  network:
    version: 2
    ethernets:
      any-en:
        match:
          name: "en*"
        dhcp4: true
        optional: true
  # storage (fix 2026-07-16): rimosso "flag: root" (NON esiste nello schema
  # curtin: i flag validi sono solo logical/extended/boot/bios_grub/swap/lvm/
  # raid/home/prep/msftres — la validazione avrebbe abortito l'install).
  # Aggiunta partizione bios_grub da 1M: con GPT serve se l'installer parte in
  # Legacy/CSM (grub-pc su GPT la richiede), innocua se parte in UEFI.
  storage:
    config:
      - type: disk
        id: disk0
        match:
${disk_match}
        ptable: gpt
        wipe: superblock-recursive
        grub_device: true
        preserve: false
      - type: partition
        id: bios-grub-partition
        device: disk0
        size: 1M
        flag: bios_grub
      - type: partition
        id: esp-partition
        device: disk0
        size: 512M
        flag: boot
        grub_device: true
      - type: partition
        id: boot-partition
        device: disk0
        size: 1G
      - type: partition
        id: root-partition
        device: disk0
        size: -1
      - type: format
        id: esp-format
        volume: esp-partition
        fstype: fat32
      - type: format
        id: boot-format
        volume: boot-partition
        fstype: ext4
      - type: format
        id: root-format
        volume: root-partition
        fstype: ext4
      - type: mount
        id: root-mount
        device: root-format
        path: /
      - type: mount
        id: boot-mount
        device: boot-format
        path: /boot
      - type: mount
        id: esp-mount
        device: esp-format
        path: /boot/efi
  identity:
    hostname: ${hostname}
    username: ${DEFAULT_USERNAME}
    password: '${DEFAULT_PASSWORD_HASH}'
  ssh:
    install-server: true
    allow-pw: true
  packages:
${apt_yaml}
  late-commands:
    - mkdir -p /target/opt/cache /target/opt/ai-rig /target/etc/ai-rig /target/usr/local/bin
    # Scrivi SUBITO il ruolo (serve a populate-cache prima che la stage-role
    # giri; la stage-role e' gated sulla catena pesante driver->cuda->gpudetect).
    - curtin in-target --target=/target -- bash -c 'echo ${role} > /etc/ai-rig/role'
    - cp /cdrom/cache/BUILD_ID /target/etc/ai-rig/build-id
    # ISO LEGGERA (2026-07-16): NON si copiano piu' i ~110GB di cache
    # (modelli/driver/cuda/llama/comfyui) durante l'install — copiare tanto da
    # USB in fase di installazione e' fragile e abortiva le late-command (bug
    # visto sul campo: provisioning a zero). Qui solo i pezzi PICCOLI che
    # servono subito (config bot, requirements, pubkey, scripts). La cache
    # pesante la copia DOPO, con populate-cache.sh, da una sorgente esterna.
    # Config, requirements e scripts sono obbligatori: se mancano, l'installazione
    # deve fermarsi invece di produrre un sistema parziale. Solo la pubkey è opzionale.
    - cp -a /cdrom/cache/config /target/opt/cache/
    - cp -a /cdrom/cache/requirements /target/opt/cache/
    - cp -a /cdrom/cache/scripts /target/opt/cache/
    - cp /cdrom/cache/ai-rig-bot.pub /target/opt/cache/ 2>/dev/null || true
    - cp -a /cdrom/rig-common/scripts/. /target/usr/local/bin/
    - cp -a /cdrom/rig-roles/${role}/scripts/. /target/usr/local/bin/
    - curtin in-target --target=/target -- bash -c 'chmod +x /usr/local/bin/*.sh'
    - cp -a /cdrom/rig-common/systemd/. /target/etc/systemd/system/
    - cp -a /cdrom/rig-roles/${role}/systemd/. /target/etc/systemd/system/
    - >-
      curtin in-target --target=/target -- bash -c '
      if [ -f /opt/cache/config/${role}-bot.env ]; then
      mkdir -p /etc/${role}-bot;
      cp /opt/cache/config/${role}-bot.env /etc/${role}-bot/config.env;
      chown ${bot_owner}:${bot_owner} /etc/${role}-bot/config.env;
      chmod 600 /etc/${role}-bot/config.env;
      echo "bot config ${role} bakeata in /etc/${role}-bot/config.env";
      else echo "nessun config/${role}-bot.env: token bot da mettere a mano post-install"; fi'
    - >-
      curtin in-target --target=/target -- bash -c '
      mkdir -p /home/${DEFAULT_USERNAME}/.ssh && chmod 700 /home/${DEFAULT_USERNAME}/.ssh;
      if [ -f /opt/cache/ai-rig-bot.pub ]; then
      cat /opt/cache/ai-rig-bot.pub >> /home/${DEFAULT_USERNAME}/.ssh/authorized_keys;
      chmod 600 /home/${DEFAULT_USERNAME}/.ssh/authorized_keys;
      fi;
      chown -R ${DEFAULT_USERNAME}:${DEFAULT_USERNAME} /home/${DEFAULT_USERNAME}/.ssh'
    - >-
      curtin in-target --target=/target -- bash -c '
      printf "%s\n" "${DEFAULT_USERNAME} ALL=(root) NOPASSWD: /usr/local/bin/ai-rig-select-role.sh *, /usr/local/bin/90-verify.sh, /usr/bin/systemctl poweroff, /usr/bin/systemctl reboot, /usr/sbin/grub-reboot *" > /etc/sudoers.d/ai-rig-bot;
      chmod 0440 /etc/sudoers.d/ai-rig-bot;
      visudo -cf /etc/sudoers.d/ai-rig-bot || rm -f /etc/sudoers.d/ai-rig-bot'
    - curtin in-target --target=/target -- systemctl daemon-reload
    # LEGGERE (abilitate all'install, girano senza modelli/driver): rete, WOL,
    # 4o disco, SMART, marker ruolo, backup, bot. Le PESANTI (driver, CUDA,
    # llama, gpudetect, automem, understory, librarian, powerlimit, comfyui)
    # NON si abilitano qui: le abilita populate-cache.sh DOPO aver copiato la
    # cache — altrimenti al primo boot fallirebbero (niente modelli/driver).
    - curtin in-target --target=/target -- systemctl enable
        ai-rig-stage-network.service ai-rig-stage-wol.service
        ai-rig-stage-shareddisk.service ai-rig-stage-smart.service
        ai-rig-stage-role.service ai-rig-backup.timer${extra_enable}
EOFUSERDATA

    echo "  -> generato nocloud/${role}/user-data (disk match: $([ -n "$disk_bypath" ] && echo "path=$disk_bypath" || echo "serial=$disk_serial"))"
}

echo "== Rendering script comuni (rig-common/) =="
render_common_scripts

echo "== Rendering ruoli =="
for role_file in config/roles/*.env; do
    # shellcheck disable=SC1090
    source "$role_file"
    render_role_scripts "$ROLE_NAME" "$ROLE_MODEL_FILE" "$ROLE_MMPROJ_FILE" \
        "$ROLE_LLAMA_PORT" "$ROLE_CTX_SIZE" "$ROLE_TEMP" "$ROLE_TOP_P" \
        "$ROLE_REPEAT_PENALTY" "$ROLE_EXTRA_ARGS"

    disk_serial_var="${ROLE_DISK_SERIAL_VAR}"
    disk_bypath_var="${ROLE_DISK_BYPATH_VAR}"
    generate_user_data "$ROLE_NAME" "$ROLE_HOSTNAME" "${!disk_serial_var}" "${!disk_bypath_var}" "$ROLE_APT_FILE"
done

echo "== Controlli statici sui file generati =="
while IFS= read -r -d '' script; do
    bash -n "$script"
done < <(find rig-common rig-roles -type f -name '*.sh' -print0)

for role in devin hermes teacher; do
    grep -q '__ROLE__\|__TARGET_SERIAL__' "nocloud/$role/user-data" && {
        echo "!!! Placeholder runtime inatteso in nocloud/$role/user-data" >&2
        exit 1
    }
done

[ -f nocloud/auto/user-data ] || {
    echo "!!! nocloud/auto/user-data assente" >&2
    exit 1
}
grep -q '__ROLE__' nocloud/auto/user-data || {
    echo "!!! placeholder __ROLE__ assente da nocloud/auto/user-data" >&2
    exit 1
}
grep -q '__TARGET_SERIAL__' nocloud/auto/user-data || {
    echo "!!! placeholder __TARGET_SERIAL__ assente da nocloud/auto/user-data" >&2
    exit 1
}
for role in auto devin hermes teacher; do
    grep -q '/etc/ai-rig/build-id' "nocloud/$role/user-data" || {
        echo "!!! Persistenza BUILD_ID assente in nocloud/$role/user-data" >&2
        exit 1
    }
done
grep -q 'BUILD_ID_FILE="/cdrom/cache/BUILD_ID"' rig-common/scripts/select-next-role.sh || {
    echo "!!! select-next-role generato senza controllo BUILD_ID" >&2
    exit 1
}
if grep -qE 'wipefs|sgdisk[[:space:]]+--zap-all' rig-common/scripts/select-next-role.sh; then
    echo "!!! Wipe anticipato rilevato in select-next-role.sh" >&2
    exit 1
fi

echo "== Fatto. Verifica placeholder di configurazione non compilati: =="
grep -rl 'CHANGEME\|AA:BB:CC:DD:EE:FF' nocloud/ rig-common/ rig-roles/ 2>/dev/null \
    || echo "  nessun placeholder di configurazione residuo trovato."
