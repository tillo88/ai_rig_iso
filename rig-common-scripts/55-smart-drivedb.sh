#!/bin/bash
# =============================================================================
# SMART per il 4° disco in enclosure USB (bridge Realtek RTL9220, 0bda:9220).
# Problema visto sul campo (2026-07-15): smartctl --scan-open NON riconosce
# automaticamente il bridge perche' il drivedb.h pacchettizzato da Ubuntu 24.04
# (7.3/5528) e' precedente all'aggiunta dell'ID 0x9220 upstream. Con drivedb
# aggiornato l'autodetect funziona; in ogni caso il wrapper ai-rig-smart.sh
# forza -d sntrealtek, quindi il seriale/salute si leggono SEMPRE.
#
# Strategia a 2 livelli (nessuno dei due e' bloccante):
#   1. drivedb.h "bakeato" nella ISO al build (cache/drivedb/drivedb.h,
#      scaricato da download-cache.sh) -> installato qui se supera il check
#      sintassi di smartctl. Funziona anche OFFLINE.
#   2. update-smart-drivedb (ufficiale, con verifica firma GPG) -> best-effort
#      se c'e' internet; se fallisce resta il drivedb del punto 1.
# =============================================================================
set -e
exec >> /var/log/ai-rig-stage-smart.log 2>&1
echo "=== Stage smart-drivedb - $(date) ==="

if ! command -v smartctl >/dev/null 2>&1; then
    echo "!!! smartctl non installato (packages/common.apt?). Salto." >&2
    exit 0
fi

DB_DIR="/var/lib/smartmontools/drivedb"
DB="${DB_DIR}/drivedb.h"
BAKED="/opt/cache/drivedb/drivedb.h"
mkdir -p "$DB_DIR"

# --- 1) drivedb bakeato dalla ISO (offline-friendly) ---
if [ -f "$BAKED" ]; then
    # smartctl -B file -P showall = stesso check sintassi di update-smart-drivedb:
    # se il formato del db nuovo non e' compatibile con questo smartctl, NON lo installo.
    if smartctl -B "$BAKED" -P showall >/dev/null 2>&1; then
        if [ ! -f "$DB" ] || ! cmp -s "$BAKED" "$DB"; then
            [ -f "$DB" ] && cp -a "$DB" "${DB}.pre-baked.bak"
            cp "$BAKED" "$DB"
            chmod 0644 "$DB"
            echo "drivedb bakeato installato in $DB"
        else
            echo "drivedb bakeato identico a quello presente: nulla da fare."
        fi
    else
        echo "!!! drivedb bakeato RIFIUTATO dal check sintassi di smartctl (formato incompatibile?). Non installato." >&2
    fi
else
    echo "Nessun drivedb bakeato in $BAKED (download-cache.sh non l'ha scaricato?)."
fi

# --- 2) update ufficiale, best-effort (serve internet; verifica firma GPG) ---
# Guardie anti-rallentamento boot: questo stage blocca multi-user.target, quindi
# (a) salta se il db attivo ha meno di 30 giorni, (b) timeout duro 90s (offline
# con DNS lento il wget interno puo' restare appeso a lungo).
if command -v update-smart-drivedb >/dev/null 2>&1; then
    if [ -f "$DB" ] && [ -n "$(find "$DB" -mtime -30 2>/dev/null)" ]; then
        echo "drivedb attivo aggiornato meno di 30 giorni fa: salto update-smart-drivedb."
    elif timeout 90 update-smart-drivedb; then
        echo "update-smart-drivedb: OK"
    else
        echo "update-smart-drivedb fallito/timeout (offline o URL cambiato) — resta il drivedb attuale. Non e' un errore fatale."
    fi
else
    echo "update-smart-drivedb non presente in questo pacchetto smartmontools."
fi

# --- Diagnostica: l'ID del bridge dell'enclosure e' nel db attivo? ---
if [ -f "$DB" ] && grep -q "0x9220" "$DB"; then
    echo "OK: ID USB 0x9220 (RTL9220) presente nel drivedb attivo -> autodetect possibile."
else
    echo "NOTA: 0x9220 non trovato nel drivedb attivo. L'autodetect non funzionera', ma ai-rig-smart.sh usa comunque -d sntrealtek."
fi

echo "=== Stage smart-drivedb completato - $(date) ==="
