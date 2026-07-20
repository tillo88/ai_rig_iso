# POST, BIOS e hardware — note operative (2026-07-15)

Rig attivo con **7 GPU** su MSI X299 Pro + i9-10900X. Questa pagina raccoglie
quello che serve quando il rig non parte o va verificato dopo stress test.

## 1. Blocco sul logo MSI dopo stress (visto sul campo)

Sintomo: dopo sessioni lunghe di carico (es. gpu-burn), al riavvio il rig resta
fisso sul logo MSI prima del POST. Causa piu' probabile con 7 GPU: warm reset
PCIe incompleto — una GPU o un riser non si resetta e il POST si blocca in
inizializzazione (non e' il Fast Boot).

**Mitigazione adottata nel progetto**: il cambio ruolo dal bot Pi ora fa sempre
**cold boot** — `poweroff` → attesa offline reale → **120 s** di scarica →
WOL ×3 (vedi `pi-bot/ai-rig-wol-bot.py` e `rig-common-scripts/ai-rig-select-role.sh`).
Mai piu' warm reboot per il cambio ruolo.

**Recovery manuale se resta bloccato**:

1. Da un altro PC: `ping <IP>` / `ssh tillo@<IP>` — se risponde, e' partito e si
   e' bloccato solo il video, non il POST.
2. `DEL` = BIOS, `F11` = boot menu, `ESC`/`TAB` = nasconde il logo e mostra i
   messaggi POST.
3. Reset elettrico completo: power 5 s → interruttore PSU off → stacca la
   corrente → premi il tasto power 10-15 s (scarica condensatori) → 1 min di
   attesa → ricollega e riaccendi.
4. Guarda gli **EZ Debug LED** vicino al connettore ATX: `VGA` = GPU/riser/linea
   PCIe (il piu' probabile con 7 schede), `BOOT` = POST ok ma problema
   disco/bootloader, `DRAM` = training memoria, `CPU` = alimentazione/CPU.
5. Se insiste con LED `VGA`: stacca le USB non necessarie (enclosure incluse) e
   riprova; poi prova con 6 GPU (rimuovi fisicamente la scheda o il suo
   adattatore M.2, non solo il cavo di alimentazione).

## 2. Impostazioni BIOS di riferimento

| Impostazione | Valore | Perche' |
|---|---|---|
| Above 4G Decoding | **Enabled** | obbligatorio con 7 GPU (BAR sopra i 4GB) |
| Resize BAR | **Disabled** | inutile per llama.cpp, con mix Pascal/Turing/Ampere complica solo l'allocazione |
| Fast Boot | **Disabled** | POST completo = init PCIe piu' affidabile |
| PEG Link Speed | Gen3 | stabilita' con riser |
| Wake on LAN / Resume by PCI-E | **Enabled** | il Pi accende il rig via WOL |
| ErP Ready | **Disabled** | ErP toglie lo standby alla NIC = WOL morto |
| Restore after AC Power Loss | **Power Off** | il rig deve accendersi SOLO via WOL |

## 3. Monitor errori PCIe/GPU durante stress test

Comando usato sul campo (a mano, durante gpu-burn o sessioni lunghe):

```bash
sudo journalctl -kf | grep --line-buffered -Ei \
  'NVRM|Xid|PCIe Bus Error|AER|fallen off|link.*down|training'
```

Se compaiono `Xid` (errori driver NVIDIA), `AER` (errori bus PCIe) o `GPU has
fallen off the bus`: annota QUALE GPU (bus id) — e' la prima indiziata per i
blocchi POST. Scelta deliberata: nessun servizio/watchdog sempre acceso per
questo, si lancia a mano quando serve.

## 4. Enclosure USB 4° disco (Saichi G800 NVME 2TB)

Bridge **Realtek RTL9220** (`0bda:9220`), USB 3.2 Gen 2x2.

- **SMART**: il drivedb pacchettizzato da Ubuntu 24.04 non conosce il bridge →
  `smartctl --scan-open` non lo mostra. Risolto nella ISO: drivedb aggiornato al
  primo boot (`55-smart-drivedb.sh`) + wrapper che forza il tipo giusto:

  ```bash
  ai-rig-smart.sh          # identita' + salute
  ai-rig-smart.sh -x       # report esteso
  # equivalente manuale: sudo smartctl -x -d sntrealtek /dev/sdX
  ```

- **Benchmark misurato (2026-07-15, iobench O_DIRECT)**: 8 thread × 64 read ×
  19 MB = 1.3 GB in 1.09 s → **~1.17 GB/s** (~17 ms effettivi/blocco da 19 MB).
  Piu' che sufficiente per AutoMem + stash KV + backup; il collo di bottiglia
  dei modelli resta il caricamento in VRAM, non questo disco.

## 5. Cold boot / cambio ruolo — riferimenti

- `rig-common-scripts/ai-rig-select-role.sh` — scrive il grubenv del GRUB
  centrale (disco devin) da QUALSIASI ruolo attivo, verifica, opzionale
  `--poweroff`. Fix del bug: `grub-reboot` lanciato da hermes/teacher scriveva
  il grubenv locale che il GRUB centrale non legge.
- `pi-bot/ai-rig-wol-bot.py` — `/devin` `/hermes` `/teacher` = cold boot con
  aggiornamenti in chat. Tempi configurabili in `config.env`
  (`COLD_BOOT_WAIT`, `OFFLINE_TIMEOUT`, `ONLINE_TIMEOUT`, `WOL_REPEAT`).
- `scripts/pi-remote-boot-select.sh` — stessa sequenza, via CLI dal Pi.
- Sudoers bakeato dalla ISO (`/etc/sudoers.d/ai-rig-bot`): il bot puo' eseguire
  senza password SOLO `ai-rig-select-role.sh`, `grub-reboot`,
  `systemctl poweroff|reboot`.


## Fix runtime consolidati 2026-07-19

- Il cambio ruolo scrive `next_entry` nel GRUB centrale e imposta dinamicamente `BootNext` sulla ESP DEVIN tramite seriale/PARTUUID.
- DEVIN viene riportato al primo posto nel `BootOrder` senza numeri `BootXXXX` hardcoded.
- Il bot Pi accetta una sola operazione distruttiva alla volta, ignora duplicati/comandi vecchi e mantiene 60 secondi di OFF reale prima del WOL.
- ComfyUI usa modelli e output sul disco condiviso; non conserva più i 31 GB dei modelli sulla root HERMES.
- AutoMem non usa più `make dev` al boot e non ripete `make install` se gli input non cambiano.
