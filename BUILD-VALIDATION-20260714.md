# Validazione build ISO AI Rig — 2026-07-14

## Risultato

- Stato: **PASS**, pronta per collaudo sul rig in modalita UEFI.
- ISO: `ubuntu-24.04-ai-rig-multiboot.iso`
- Dimensione: `156364212224` byte (circa 146 GiB).
- SHA-256: `b071356c64c7b60ee26ae70ca5ad53cc3d61386411be596e631ba3200e62d837`
- Rollback: `ubuntu-24.04-ai-rig-multiboot-pre-librarian-20260713.iso`

## Verifiche superate

- Tutti gli artefatti production hanno superato i checksum configurati:
  ISO Ubuntu 24.04.4, driver NVIDIA 570.86.10, CUDA 12.8 e cinque file
  modello/mmproj.
- Test ISO/Librarian/policy/evaluation: 16/16.
- Test ForgeStudio: 118/118.
- Test DEVIN: 24 passati, 1 saltato come previsto.
- Boot catalog: El Torito BIOS + UEFI, MBR ibrido + GPT.
- Menu GRUB: DEVIN, HERMES e TEACHER, una voce ciascuno.
- NoCloud: tre ruoli con i rispettivi seriali disco.
- Password iniziale `tillo`: hash SHA-512-crypt verificato.
- Rete: `192.168.111.177/24`, gateway `192.168.111.254`; nessun
  riferimento residuo a `192.168.1.100` nei payload controllati.
- Librarian: servizio presente e abilitato in tutti i ruoli, endpoint Hermes
  `http://localhost:3810/mcp`.
- Nessun MCP AutoMem diretto attivo in Hermes.
- Policy `memory-policy.json` e `cognitive-policy.json` valide.
- File critici estratti dalla ISO identici byte per byte all'albero
  `iso-custom`.
- Modelli visibili nell'indice ISO con dimensioni complete, inclusi file oltre
  4 GiB (ISO Level 3).

## Correzioni alla pipeline

- Eliminato il falso negativo `isolinux` causato da
  `dpkg -l | grep -q` insieme a `pipefail`.
- Reso `WORK_DIR` relativo a `ROOT_DIR`, quindi la build funziona anche se
  viene eseguita come root per il mount della ISO.

## Note non bloccanti

- Con 146 GiB la ISO puo non avviarsi in modalita MBR su BIOS molto vecchi.
  Sul rig usare **UEFI**, disabilitare CSM/Legacy e scegliere la voce USB UEFI.
- Il volume label contiene spazi e non e strettamente ISO-9660; Linux/UEFI lo
  gestiscono correttamente.
- Tre symlink Ubuntu non sono esposti nella vista Joliet, ma restano presenti
  nella vista Rock Ridge usata da Linux.
- Alcuni testi di aiuto Hermes chiamano ancora la memoria “AutoMem”; la
  configurazione attiva usa esclusivamente Librarian. Correzione cosmetica da
  distribuire con il primo update.
- Usare una chiavetta **da 256 GB**: una 128 GB non contiene l'immagine.

## Primo collaudo

Installare un ruolo alla volta e verificare, prima di passare al successivo:

```bash
cat /etc/ai-rig/role
systemctl --failed
systemctl status ai-rig-librarian --no-pager
curl -fsS http://127.0.0.1:3810/health
nvidia-smi
cat /var/log/ai-rig-verify.log
```

Cambiare subito la password iniziale con `passwd`.
