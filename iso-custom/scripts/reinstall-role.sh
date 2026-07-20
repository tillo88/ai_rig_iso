#!/bin/bash
# =============================================================================
# scripts/reinstall-role.sh <devin|hermes|teacher> <nuovo_seriale>
#
# L'isolamento per-ruolo esiste GIA' nell'architettura: ogni voce di boot
# (Install AI Rig - DEVIN/HERMES/TEACHER) fa match sul disco per SERIALE, non
# per posizione. Se muore un disco, gli altri due non vengono mai toccati da
# una reinstallazione mirata — questo script automatizza solo i passi di
# aggiornamento config + rebuild ISO, non introduce niente di nuovo.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

ROLE="${1:?Uso: $0 <devin|hermes|teacher> <nuovo_seriale>}"
NEW_SERIAL="${2:?Uso: $0 <devin|hermes|teacher> <nuovo_seriale>}"

case "$ROLE" in
    devin)   VAR="DEVIN_DISK_SERIAL" ;;
    hermes)  VAR="HERMES_DISK_SERIAL" ;;
    teacher) VAR="TEACHER_DISK_SERIAL" ;;
    *) echo "Ruolo sconosciuto: $ROLE (devin|hermes|teacher)" >&2; exit 1 ;;
esac

cp config/disks.env "config/disks.env.bak.$(date +%s)"
sed -i "s|^${VAR}=.*|${VAR}=\"${NEW_SERIAL}\"|" config/disks.env
echo "Aggiornato ${VAR}=${NEW_SERIAL} in config/disks.env (backup salvato)."

./build-iso.sh

echo
echo "=== Fatto. IMPORTANTE: ==="
echo "Scrivi la nuova ISO sulla USB e boota SOLO la voce 'Install AI Rig - ${ROLE^^}'."
echo "Gli altri 2 dischi (seriali invariati) non vengono toccati da questa voce,"
echo "anche se restano fisicamente collegati durante l'installazione."
