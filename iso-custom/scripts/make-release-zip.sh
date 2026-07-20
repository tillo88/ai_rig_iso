#!/bin/bash
# =============================================================================
# make-release-zip.sh — crea lo zip di aggiornamento SENZA i file di proprieta'
# dell'utente (config compilate con seriali/MAC/parametri suoi, cache modelli).
#
# Regola concordata: gli .env non viaggiano piu' negli zip. Se una modifica
# introduce una VARIABILE NUOVA in un env esistente, va comunicata a parte
# (riga da aggiungere a mano), MAI sovrascrivendo il file.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-/tmp/ai-rig-iso-build-update.zip}"

rm -f "$OUT"
zip -r -q "$OUT" . \
    -x '.git/*' \
    -x '*__pycache__*' \
    -x 'config/*.env' \
    -x 'config/roles/*.env' \
    -x 'pi-bot/config.env' \
    -x 'cache/*' \
    -x 'nocloud/*' \
    -x 'rig-common/*' \
    -x 'rig-roles/*/scripts/role-provision.sh' \
    -x 'rig-roles/*/scripts/start-llama-*.sh' \
    -x 'rig-roles/*/scripts/40-hermes-extras.sh' \
    -x 'rig-roles/*/systemd/ai-rig-hermes-extras.service' \
    -x 'iso-mount/*' -x 'iso-custom/*' -x 'llama-prebuild/*' \
    -x '*.iso'

echo "Creato: $OUT"
echo "Contiene .env?"
unzip -l "$OUT" | grep -E '\.env$' && echo "!!! ERRORE: env presenti!" && exit 1 || echo "  no (corretto)"
unzip -l "$OUT" | tail -1
