#!/bin/bash
# =============================================================================
# 4° disco condiviso tra i 3 ruoli — dati AutoMem (FalkorDB+Qdrant), modelli,
# receipt e sessioni KV.
#
# IDENTITA': UUID del filesystem, non il serial dell'hardware.
# Il serial cambia quando cambia enclosure; lo UUID no. Dopo l'incidente del
# 2026-08-10 (OP-DEVIN-USB-ASMEDIA-RESET-002) il disco si e' ri-enumerato con un
# nome di device diverso e un bridge diverso: l'unica identita' sopravvissuta e'
# stata lo UUID del filesystem.
#
# FAIL-CLOSED: se il disco e' dichiarato necessario e non si trova, questo stage
# FALLISCE. Prima usciva 0 e la unit restava "active (exited)" pur avendo saltato
# il disco: un PASS che non provava niente.
#
# Formatta SOLO un disco davvero vergine, e solo quando e' stato individuato per
# serial (primo boot). Un disco gia' nostro viene trovato per UUID o label e non
# viene mai toccato.
# =============================================================================
set -uo pipefail
exec >> /var/log/ai-rig-stage-shareddisk.log 2>&1
echo "=== Stage shared-disk - $(date -Is) ==="

mkdir -p /var/lib/ai-rig

SERIAL="__SHARED_DISK_SERIAL__"
MOUNT_PATH="__SHARED_MOUNT_PATH__"
# I due parametri seguenti non passano dal generatore: arrivano da
# /opt/cache/config/shared-disk.env, che e' gia' installato e gia' letto qui
# sotto. Cosi' si aggiornano su un rig gia' installato senza rifare la ISO.
SHARED_DISK_UUID="${SHARED_DISK_UUID:-}"
SHARED_DISK_REQUIRED="${SHARED_DISK_REQUIRED:-true}"
SHARED_DISK_LABEL="ai-rig-shared"

# Uno UUID e' valido solo se ne ha la forma. Non si confronta col testo del
# placeholder: il generatore sostituisce anche quello, e la sentinella
# sparirebbe insieme al controllo che doveva proteggere.
_uuid_valido() { [[ "${1:-}" =~ ^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$ ]]; }

# Override post-install: aggiornare /opt/cache/config/shared-disk.env e riavviare
# basta, senza rigenerare la ISO. E' la via per registrare un nuovo UUID o un
# nuovo enclosure sui ruoli gia' installati.
# shellcheck disable=SC1091
[ -f /opt/cache/config/shared-disk.env ] && source /opt/cache/config/shared-disk.env

case "${SHARED_DISK_REQUIRED,,}" in
    false|no|0) REQUIRED=0 ;;
    *)          REQUIRED=1 ;;
esac

# --- uscita unica, cosi' l'esito e' sempre esplicito ------------------------
_giu() {  # $1 = messaggio
    echo "!!! $1" >&2
    if [ "$REQUIRED" -eq 1 ]; then
        echo "AI_RIG_SHARED_DISK=FAIL reason=$2" >&2
        echo "!!! Il disco condiviso e' dichiarato necessario (SHARED_DISK_REQUIRED)." >&2
        echo "!!! Questo stage fallisce di proposito: un disco assente non deve" >&2
        echo "!!! sembrare uno stage riuscito. Per un rig senza 4° disco impostare" >&2
        echo "!!! SHARED_DISK_REQUIRED=false in /opt/cache/config/shared-disk.env." >&2
        exit 1
    fi
    echo "AI_RIG_SHARED_DISK=SKIP reason=$2 (SHARED_DISK_REQUIRED=false, scelta dichiarata)"
    exit 0
}

# --- 1) identita' primaria: UUID del filesystem -----------------------------
part=""
modo=""
if _uuid_valido "$SHARED_DISK_UUID"; then
    # udev puo' non aver ancora ricreato il symlink dopo una ri-enumerazione:
    # si prova by-uuid e, se manca, si interroga blkid direttamente.
    if [ -e "/dev/disk/by-uuid/${SHARED_DISK_UUID}" ]; then
        part=$(readlink -f "/dev/disk/by-uuid/${SHARED_DISK_UUID}")
        modo="uuid"
    else
        p=$(blkid -U "$SHARED_DISK_UUID" 2>/dev/null || true)
        if [ -n "$p" ]; then
            part="$p"
            modo="uuid-blkid"
            echo "Nota: /dev/disk/by-uuid/${SHARED_DISK_UUID} assente, risolto via blkid (udev in ritardo?)."
        fi
    fi
    [ -n "$part" ] && echo "Disco condiviso individuato per UUID: $part (UUID $SHARED_DISK_UUID)"
fi

# --- 2) identita' secondaria: label, anch'essa indipendente dall'enclosure ---
if [ -z "$part" ]; then
    p=$(blkid -o device -t "LABEL=${SHARED_DISK_LABEL}" 2>/dev/null | head -n1 || true)
    if [ -n "$p" ]; then
        part="$p"
        modo="label"
        echo "Disco condiviso individuato per label ${SHARED_DISK_LABEL}: $part"
        u=$(blkid -s UUID -o value "$part" 2>/dev/null || true)
        [ -n "$u" ] && echo "    UUID effettivo: $u  <-- registrarlo come SHARED_DISK_UUID"
    fi
fi

# --- 3) ultima risorsa: serial interno, solo per il primo boot ---------------
# Serve unicamente a individuare un disco NUOVO da inizializzare. Il tipo
# smartctl non e' piu' un'assunzione fissa sul bridge: si provano i tipi noti.
DEV=""
if [ -z "$part" ] && [ -n "$SERIAL" ] && [ "$SERIAL" != "CHANGEME_SHARED_SERIAL" ] \
   && [[ "$SERIAL" != __*__ ]]; then
    _smart_serial() { smartctl -i -d "$2" "$1" 2>/dev/null \
        | awk -F: '/^Serial Number:/{gsub(/^[ \t]+|[ \t]+$/,"",$2);print $2;exit}'; }
    if command -v smartctl >/dev/null 2>&1; then
        while read -r dev; do
            for t in auto sat sntasmedia sntrealtek scsi; do
                s=$(_smart_serial "$dev" "$t" || true)
                if [ "$s" = "$SERIAL" ]; then DEV="$dev"; break 2; fi
                [ -n "$s" ] && break
            done
        done < <(lsblk -dnpo NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}')
    else
        echo "!!! smartctl assente: fallback su lsblk (dietro un enclosure USB legge il serial del bridge)." >&2
        d=$(lsblk -dno NAME,SERIAL 2>/dev/null | awk -v s="$SERIAL" '$2==s {print $1}' | head -n1)
        [ -n "$d" ] && DEV="/dev/${d}"
    fi
    [ -n "$DEV" ] && { modo="serial"; echo "Disco individuato per serial interno: $DEV (serial $SERIAL)"; }
fi

[ -z "$part" ] && [ -z "$DEV" ] && _giu \
    "Disco condiviso non trovato: ne' per UUID (${SHARED_DISK_UUID:-non impostato}), ne' per label ${SHARED_DISK_LABEL}, ne' per serial ${SERIAL:-non impostato}." \
    "not-found"

mkdir -p "$MOUNT_PATH"

# --- inizializzazione: solo per un disco trovato per serial e davvero vergine -
# Tre stadi a prova di dati altrui. Un disco gia' nostro non arriva mai qui:
# e' stato risolto per UUID o label sopra.
if [ -z "$part" ]; then
    if lsblk -no FSTYPE,PTTYPE "$DEV" 2>/dev/null | grep -q '[^[:space:]]'; then
        _giu "$DEV contiene partizioni o filesystem che non sono nostri (nessuna label ${SHARED_DISK_LABEL}, nessuno UUID atteso). NON formatto niente. Se va inizializzato: salva i dati, 'wipefs -a $DEV', poi riavvia." "foreign-data"
    fi
    echo "Disco $DEV realmente vuoto: creo GPT + ext4 (prima volta)."
    parted -s "$DEV" mklabel gpt || _giu "parted mklabel fallito su $DEV" "parted-failed"
    parted -s "$DEV" mkpart primary ext4 0% 100% || _giu "parted mkpart fallito su $DEV" "parted-failed"
    partprobe "$DEV"; sleep 2
    part="${DEV}1"; [ -e "$part" ] || part="${DEV}p1"
    mkfs.ext4 -F -L "$SHARED_DISK_LABEL" "$part" || _giu "mkfs.ext4 fallito su $part" "mkfs-failed"
    modo="serial-init"
fi

UUID=$(blkid -s UUID -o value "$part" 2>/dev/null || true)
[ -n "$UUID" ] || _giu "impossibile determinare lo UUID di $part" "no-uuid"

# Se conoscevamo gia' uno UUID atteso, quello trovato deve coincidere: montare
# un disco diverso al posto dello shared sarebbe peggio che non montarlo.
if _uuid_valido "$SHARED_DISK_UUID" && [ "$UUID" != "$SHARED_DISK_UUID" ]; then
    _giu "UUID inatteso su $part: trovato $UUID, atteso $SHARED_DISK_UUID." "uuid-mismatch"
fi

grep -q "$UUID" /etc/fstab 2>/dev/null || \
    echo "UUID=${UUID}  ${MOUNT_PATH}  ext4  defaults,nofail  0  2" >> /etc/fstab

mount -a

# --- verifica reale del mount ------------------------------------------------
# findmnt + UUID sono l'autorita' stabilita dall'incidente del 2026-08-10.
montato=$(findmnt -no SOURCE --target "$MOUNT_PATH" 2>/dev/null || true)
[ -n "$montato" ] || _giu "${MOUNT_PATH} non risulta montato dopo 'mount -a'." "mount-failed"
uuid_montato=$(blkid -s UUID -o value "$montato" 2>/dev/null || true)
[ "$uuid_montato" = "$UUID" ] || _giu \
    "${MOUNT_PATH} e' montato da $montato (UUID ${uuid_montato:-ignoto}), non dal disco condiviso (UUID $UUID)." \
    "wrong-device-mounted"

mkdir -p \
    "${MOUNT_PATH}/automem/falkordb" \
    "${MOUNT_PATH}/automem/qdrant" \
    "${MOUNT_PATH}/understory/bundle" \
    "${MOUNT_PATH}/understory/runtime" \
    "${MOUNT_PATH}/librarian/agents/devin" \
    "${MOUNT_PATH}/librarian/agents/teacher" \
    "${MOUNT_PATH}/librarian/agents/hermes" \
    "${MOUNT_PATH}/understory/bundle/shared/software-engineering" \
    "${MOUNT_PATH}/understory/bundle/shared/gui-automation" \
    "${MOUNT_PATH}/understory/bundle/shared/general" \
    "${MOUNT_PATH}/understory/bundle/policy" \
    "${MOUNT_PATH}/kv-sessions-shared"

echo "AI_RIG_SHARED_DISK=PASS mount=${MOUNT_PATH} device=${montato} uuid=${UUID} mode=${modo}"
echo "=== Shared disk pronto su ${MOUNT_PATH} (UUID $UUID, via ${modo}) - $(date -Is) ==="
