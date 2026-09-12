#!/usr/bin/env bash
# Prova di rig-common-scripts/50-shared-disk.sh con comandi finti.
#
# Lo script puo' partizionare e formattare, quindi cio' che conta di piu' qui
# non e' che funzioni: e' che NON formatti quando non deve. Un solo scenario
# degli otto deve toccare parted/mkfs — il disco genuinamente vergine.
#
# Nessun privilegio, nessun disco reale: parted, mkfs.ext4, blkid, lsblk,
# findmnt, mount e smartctl sono sostituiti in PATH.
#
# Uso:  bash tests/test_50_shared_disk.sh

set -uo pipefail

QUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$QUI/../rig-common-scripts/50-shared-disk.sh"
[ -f "$SCRIPT" ] || { echo "script non trovato: $SCRIPT"; exit 1; }

UUID_OK=d22a821d-5352-44e1-921e-1dff9e666ce0
UUID_NO=99999999-aaaa-bbbb-cccc-dddddddddddd
SERIALE=2210VC0S036H0163
BASE="$(mktemp -d)"
trap 'rm -rf "$BASE"' EXIT
PASSATI=0; FALLITI=0

_scrivi() { printf '%s\n' "$2" > "$1"; chmod +x "$1"; }

_mock_comuni() { # $1 = dir bin
    _scrivi "$1/parted"     '#!/bin/bash'$'\n''echo "parted $*" >> "$FORMATTATO"'
    _scrivi "$1/mkfs.ext4"  '#!/bin/bash'$'\n''echo "mkfs.ext4 $*" >> "$FORMATTATO"'
    _scrivi "$1/partprobe"  '#!/bin/bash'
    _scrivi "$1/mount"      '#!/bin/bash'
    _scrivi "$1/smartctl"   '#!/bin/bash'
    _scrivi "$1/lsblk"      '#!/bin/bash'
    _scrivi "$1/findmnt"    '#!/bin/bash'$'\n''exit 1'
    _scrivi "$1/blkid"      '#!/bin/bash'$'\n''exit 2'
}

# blkid finto: $1=dir  $2=risposta a -U  $3=risposta a LABEL=  $4=risposta a -s UUID
_mock_blkid() {
    { echo '#!/bin/bash'
      echo 'case "$*" in'
      [ -n "$2" ] && echo "  *\"-U \"*) echo $2 ;;" || echo '  *"-U "*) exit 2 ;;'
      [ -n "$3" ] && echo "  *\"LABEL=\"*) echo $3 ;;" || echo '  *"LABEL="*) exit 2 ;;'
      [ -n "$4" ] && echo "  *\"-s UUID\"*) echo $4 ;;" || echo '  *"-s UUID"*) exit 2 ;;'
      echo '  *) exit 2 ;;'
      echo 'esac'
    } > "$1/blkid"
    chmod +x "$1/blkid"
}

# lsblk finto che espone un disco: $1=dir  $2=contenuto FSTYPE/PTTYPE ("" = vergine)
_mock_lsblk_disco() {
    { echo '#!/bin/bash'
      echo 'case "$*" in'
      echo '  *"NAME,TYPE"*) echo "/dev/sdd disk" ;;'
      echo "  *FSTYPE*) echo \"$2\" ;;"
      echo 'esac'
    } > "$1/lsblk"
    chmod +x "$1/lsblk"
}

verifica() { # $1 nome $2 uuid_cfg $3 required $4 rc atteso $5 marker atteso $6 formatta atteso
    local nome="$1" ucfg="$2" req="$3" rc_att="$4" marker_att="$5" fmt_att="$6"
    local d="$BASE/$nome"
    local rc reason fmt esito=OK

    PATH="$d/bin:/usr/bin:/bin" FORMATTATO="$d/FORMATTATO" bash "$d/script.sh"
    rc=$?
    reason=$(grep -oE 'AI_RIG_SHARED_DISK=[A-Z]+( reason=[a-z-]+)?' "$d/stage.log" 2>/dev/null | tail -1)
    fmt=$([ -s "$d/FORMATTATO" ] && echo si || echo no)

    [ "$rc" = "$rc_att" ] || esito=FAIL
    [ "$fmt" = "$fmt_att" ] || esito=FAIL
    [[ "$reason" == *"$marker_att"* ]] || esito=FAIL

    if [ "$esito" = OK ]; then
        PASSATI=$((PASSATI+1))
        printf '  OK    %-24s rc=%s  formatta=%-3s %s\n' "$nome" "$rc" "$fmt" "$reason"
    else
        FALLITI=$((FALLITI+1))
        printf '  FAIL  %-24s rc=%s (atteso %s)  formatta=%s (atteso %s)  %s (atteso ~%s)\n' \
            "$nome" "$rc" "$rc_att" "$fmt" "$fmt_att" "${reason:-nessuno}" "$marker_att"
    fi
}

prepara() { # $1 nome $2 uuid_cfg $3 required
    local d="$BASE/$1"
    mkdir -p "$d/bin" "$d/mnt" "$d/byuuid"
    : > "$d/fstab"; : > "$d/FORMATTATO"
    _mock_comuni "$d/bin"
    # UUID e REQUIRED arrivano dal file di override, come sul rig vero
    { [ -n "$2" ] && echo "SHARED_DISK_UUID=\"$2\""
      echo "SHARED_DISK_REQUIRED=$3"; } > "$d/override.env"
    sed -e "s|__SHARED_DISK_SERIAL__|$SERIALE|g" \
        -e "s|__SHARED_MOUNT_PATH__|$d/mnt|g" \
        -e "s|/var/log/ai-rig-stage-shareddisk.log|$d/stage.log|" \
        -e "s|/etc/fstab|$d/fstab|g" \
        -e "s|/dev/disk/by-uuid/|$d/byuuid/|g" \
        -e "s|/opt/cache/config/shared-disk.env|$d/override.env|g" \
        "$SCRIPT" > "$d/script.sh"
    echo "$d"
}

echo
echo "  scenario                   esito     formattazione   marker"
echo "  --------------------------------------------------------------------------"

d=$(prepara trovato_per_uuid "$UUID_OK" true)
_mock_blkid "$d/bin" /dev/sdd1 "" "$UUID_OK"; _scrivi "$d/bin/findmnt" '#!/bin/bash'$'\n''echo /dev/sdd1'
verifica trovato_per_uuid "$UUID_OK" true 0 PASS no

d=$(prepara trovato_per_label "$UUID_OK" true)
_mock_blkid "$d/bin" "" /dev/sdd1 "$UUID_OK"; _scrivi "$d/bin/findmnt" '#!/bin/bash'$'\n''echo /dev/sdd1'
verifica trovato_per_label "$UUID_OK" true 0 PASS no

d=$(prepara uuid_diverso "$UUID_OK" true)
_mock_blkid "$d/bin" /dev/sdd1 "" "$UUID_NO"; _scrivi "$d/bin/findmnt" '#!/bin/bash'$'\n''echo /dev/sdd1'
verifica uuid_diverso "$UUID_OK" true 1 reason=uuid-mismatch no

d=$(prepara mount_non_avvenuto "$UUID_OK" true)
_mock_blkid "$d/bin" /dev/sdd1 "" "$UUID_OK"
verifica mount_non_avvenuto "$UUID_OK" true 1 reason=mount-failed no

d=$(prepara disco_assente "$UUID_OK" true)
verifica disco_assente "$UUID_OK" true 1 reason=not-found no

d=$(prepara disco_assente_dichiarato "$UUID_OK" false)
verifica disco_assente_dichiarato "$UUID_OK" false 0 SKIP no

d=$(prepara dati_altrui "" true)
_mock_lsblk_disco "$d/bin" "ntfs gpt"
_scrivi "$d/bin/smartctl" '#!/bin/bash'$'\n'"echo \"Serial Number:    $SERIALE\""
verifica dati_altrui "" true 1 reason=foreign-data no

d=$(prepara disco_vergine "" true)
_mock_lsblk_disco "$d/bin" ""
_scrivi "$d/bin/smartctl" '#!/bin/bash'$'\n'"echo \"Serial Number:    $SERIALE\""
_mock_blkid "$d/bin" "" "" "$UUID_OK"; _scrivi "$d/bin/findmnt" '#!/bin/bash'$'\n''echo /dev/sdd1'
verifica disco_vergine "" true 0 PASS si

echo "  --------------------------------------------------------------------------"
echo "  $PASSATI passati, $FALLITI falliti"
echo
[ $FALLITI -eq 0 ] || exit 1
echo "  AI_RIG_SHARED_DISK_TESTS=PASS scenari=$PASSATI formattazioni=1"
