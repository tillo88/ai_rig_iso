# Flusso di installazione — ISO LEGGERA (dal 2026-07-16)

Cambio architetturale: la ISO **non baka piu' i ~110GB di modelli/driver/cuda/
llama/comfyui**. Copiarli da USB durante l'install era fragile e faceva abortire
il provisioning (bug visto sul campo: install base OK ma zero script/servizi).

Ora la cache pesante si copia **dopo** l'install, disk-to-disk (veloce,
ripetibile), con `populate-cache.sh`. La ISO resta ~5GB.

## Cosa c'e' nella ISO leggera
- Ubuntu 24.04 base + pacchetti apt (deps).
- I nostri script (`/usr/local/bin`), unit systemd, config, requirements, pubkey bot.
- Le stage LEGGERE abilitate all'install: rete, WOL, 4o disco, SMART, marker
  ruolo, backup, bot Telegram.
- NON abilitate (servono i modelli/driver): driver, CUDA, llama, gpudetect,
  automem, understory, librarian, powerlimit GTX1080, ComfyUI (hermes).

## Passi

### 0. Prepara il 4TB UNA volta sola (disco-cache permanente)
Il 4TB NON tiene la ISO (quella va su una chiavetta piccola) — tiene solo la
cache. Formattalo ext4 con etichetta `ai-rig-cache`, una volta (ci stanno
decine di copie):
```bash
sudo mkfs.ext4 -L ai-rig-cache /dev/sdX1     # <-- il disco GIUSTO!
sudo mkdir -p /mnt/disco4tb && sudo mount /dev/sdX1 /mnt/disco4tb
```

### 1. Build ISO leggera + cache sul 4TB — UN COLPO SOLO
```bash
cd ~/ai-rig-iso-build
bash scripts/05-generate-nocloud.sh                        # rigenera nocloud/
bash build-iso.sh --production --cache-disk /mnt/disco4tb  # ISO leggera + riempie il 4TB
# (senza --cache-disk fa solo la ISO; --full = baka i 110GB nella ISO, sconsigliato)
```
`--cache-disk` fa tutto insieme: costruisce la ISO leggera (~5GB) E copia la
cache sul 4TB. La **ISO** va su una **chiavetta piccola** (dd/Etcher); il **4TB**
resta il disco-cache. Nessuna doppia formattazione.

### 2. Installa i 3 ruoli (col 4TB collegato)
Installa devin, hermes, teacher sui rispettivi dischi (match per seriale). Ogni
install e' veloce (niente 110GB). A fine install il sistema boota: rete su,
SSH attivo (tillo/tillo), ma i modelli non ci sono ancora.

### 3. (In alternativa al --cache-disk) riempi il 4TB a parte
Se non hai usato `--cache-disk` al build, riempi il 4TB dopo:
```bash
bash scripts/sync-cache-to-disk.sh /mnt/disco4tb   # rsync cache/ -> 4TB/cache
```
Struttura risultante: `4TB/cache/{models/{devin,hermes,teacher}, nvidia-driver.run,
cuda-toolkit.run, llama-prebuilt/, comfyui-models/, drivedb/, config/, requirements/}`.

### 4. Popola la cache + abilita le stage pesanti (per OGNI ruolo)
Colleghi il 4TB al rig, booti il ruolo, poi:
```bash
sudo populate-cache.sh                # trova il 4TB per etichetta, copia SELETTIVO, reboot
# (sudo populate-cache.sh /mnt/x/cache   per sorgente esplicita)
# (sudo populate-cache.sh --no-reboot    per non riavviare subito)
```
populate-cache copia SOLO cio' che serve al ruolo corrente: parti condivise
(driver/CUDA/llama/drivedb/config) + il SUO modello (models/<ruolo>) + ComfyUI
solo su hermes. Cosi' ogni disco riceve i suoi GB, non 3x.
Al reboot partono in ordine driver -> CUDA -> llama -> gpudetect -> automem ->
understory -> librarian -> powerlimit GTX1080 (+ ComfyUI su hermes). Segui con
`journalctl -f` o `tail -f /var/log/ai-rig-stage-*.log`.

Ripeti per hermes e teacher (cambi ruolo, ricolleghi/lasci il 4TB, rilanci populate-cache).

### 5. GRUB centrale + entry stabili
Sul disco DEVIN (boot manager centrale), dopo aver installato tutti e 3:
```bash
bash /opt/cache/scripts/grub-centralize.sh      # os-prober trova gli altri 2
bash /opt/cache/scripts/grub-stable-entries.sh  # id fissi devin/hermes/teacher
```

## Note
- GPU GTX1080 instabile: `gtx1080-powerlimit.service` la porta a 180W (a 210W
  dava errori sotto gpu-burn). Abilitata da populate-cache (dopo il driver).
- Rete definitiva: 192.168.1.100/24, gw 192.168.1.254 (rig a casa).
- Se una stage fallisce: `/var/log/ai-rig-stage-<nome>.log` ha il dettaglio;
  si rilancia con `sudo systemctl restart ai-rig-stage-<nome>`.
