# AFTER INITIAL SETUP — tutto quello che serve dopo il primo install

Riferimento unico, nudo e crudo. Rete: **rig = 192.168.1.100**, **Pi = 192.168.1.86**,
gateway .254. MAC rig (WOL) = `2c:f0:5d:56:08:bc`. Utente `tillo` ovunque.
(Per il flusso di INSTALL vedi `INSTALL-FLOW-LIGHT.md`; qui si parte a install fatti.)

---

## 0. COME SI COMANDANO GLI AGENT (interfacce principali)

Un ruolo attivo alla volta; l'API llama e' sempre su `192.168.1.100:8080`.

- **DEVIN** (coding agent):
  - Dashboard web → `http://192.168.1.100:5000` (interfaccia principale: chat,
    progetti, run, diff). Oppure dal PC via `devin_ai_ide` desktop.
  - Telegram **devin-bot**: `/project` `/fixit` `/runs` `/status` + testo = chat.
  - API diretta: `POST http://192.168.1.100:8080/v1/chat/completions`.
- **HERMES** (assistente generale + tool + ComfyUI):
  - CLI sul rig: `hermes -z` (persona/tool/memoria AutoMem).
  - Telegram **hermes-bot**: testo = chat con memoria; `/status`.
  - Tool: web search SearXNG `:8081`, ComfyUI (immagini), firecrawl `:3002`.
- **TEACHER** (vision / validator):
  - Telegram **teacher-bot**: `/ask <testo>` o `/ask` + FOTO = query vision.
  - Usato in automatico da **ForgeStudio** in escalation (quando UI-TARS locale
    non ce la fa) — vedi il progetto ForgeStudio.
  - API vision: `:8080` con immagine nel messaggio.

Per passare da un agent all'altro → **Cambio ruolo** (sezione 4).

---

## 1. SETUP dopo l'install base (checklist)

### 1a. Cache + modelli — per OGNI ruolo (4TB collegato)
Avvia il ruolo (menu GRUB) → login `tillo`/`tillo` → :
```bash
sudo populate-cache.sh        # trova il 4TB per etichetta, copia il SUO modello, accende le stage, riavvia
```
Aspetta che le stage pesanti finiscano (driver→reboot→cuda/llama→modello):
```bash
journalctl -u llama-server@$(cat /etc/ai-rig/role) -f   # finche' "API attive"
tail -f /var/log/ai-rig-stage-*.log                      # dettaglio stage
```
Ripeti per devin, hermes, teacher.

### 1b. GRUB centrale (sul disco DEVIN, tutti e 3 i dischi collegati)
```bash
bash /opt/cache/scripts/grub-centralize.sh
bash /opt/cache/scripts/grub-stable-entries.sh
sudo reboot
```

### 1c. Password e sicurezza (su ogni ruolo)
```bash
passwd                         # cambia la default tillo/tillo
```

---

## 2. BOT TELEGRAM PER RUOLO (uno per ruolo, gira solo col ruolo attivo)

Ogni ruolo ha il suo bot. Config in `/etc/<ruolo>-bot/config.env` (BOT_TOKEN da
@BotFather, un bot diverso per ruolo; ALLOWED_CHAT_IDS = il tuo, da @userinfobot).
Se erano gia' bakeati al build → gia' pronti. Altrimenti:
```bash
ls -l /etc/devin-bot/config.env          # (o hermes-bot / teacher-bot)
sudo nano /etc/<ruolo>-bot/config.env    # BOT_TOKEN=... ALLOWED_CHAT_IDS=...
sudo systemctl restart <ruolo>-bot
sudo systemctl status  <ruolo>-bot
```

### Comandi dei bot ruolo (su Telegram)
- **devin-bot** (chat con la dashboard DEVIN):
  `/status` stato rig+modelli · `/runs` ultimi run · `/project` progetto a fuoco ·
  `/fixit` genera patch dalla chat del progetto e riprova · `/help` · testo libero = chat
- **hermes-bot** (ponte verso hermes, chat con memoria AutoMem):
  `/status` stato modello+ruolo · `/help` · testo libero = chat con hermes
- **teacher-bot** (watchdog + vision, gira come root):
  `/status` health+VRAM+ruolo · `/restart` riavvia llama-server@teacher ·
  `/ask <testo>` domanda al teacher · `/ask` + FOTO (con didascalia) = query vision ·
  `/watch` · `/help`

---

## 3. RASPBERRY PI — bot WOL + cambio ruolo (sempre acceso, IP .86)

### Installazione (una volta, sul Pi)
```bash
sudo apt install -y python3 wakeonlan
sudo mkdir -p /home/tillo/ai-rig-wol-bot /etc/ai-rig-bot
sudo cp pi-bot/ai-rig-wol-bot.py /home/tillo/ai-rig-wol-bot/
sudo cp pi-bot/config.env /etc/ai-rig-bot/config.env
sudo nano /etc/ai-rig-bot/config.env     # BOT_TOKEN, RIG_MAC=2c:f0:5d:56:08:bc, RIG_IP=192.168.1.100, ALLOWED_CHAT_IDS
sudo chmod 600 /etc/ai-rig-bot/config.env
# chiave SSH del bot (se non c'e'): la .pub deve stare in cache/ai-rig-bot.pub PRIMA del build
sudo -u tillo ssh-keygen -t ed25519 -f /home/tillo/.ssh/ai_rig -N ""    # se serve
sudo cp pi-bot/ai-rig-wol-bot.service /etc/systemd/system/
sudo systemctl enable --now ai-rig-wol-bot
journalctl -u ai-rig-wol-bot -f          # scrivi /help al bot per testare
```

### Comandi del bot Pi (su Telegram)
- `/wakeup` accende il rig (ruolo di default)
- `/status` stato rig + ruolo attivo
- `/verify` ultimo report di verifica
- `/devin` `/hermes` `/teacher` → **cambio ruolo con COLD BOOT** (poweroff → attesa
  offline → 120s scarica PCIe → WOL → conferma; ~4-6 min, con aggiornamenti in chat)
- `/help`

---

## 4. CAMBIO RUOLO — i tre modi

Il rig fa UN ruolo alla volta. Cambio = COLD BOOT (spegne, aspetta, riaccende via
WOL: evita il blocco POST del reset caldo con 7 GPU).

**A. Dal telefono (bot Pi)** — il modo normale:
> `/hermes`   (o `/devin` / `/teacher`)

**B. Dal rig via SSH/CLI** (dal PC o dal Pi):
```bash
ssh tillo@192.168.1.100
sudo /usr/local/bin/ai-rig-select-role.sh hermes --poweroff   # imposta prossimo boot + spegne
# poi il Pi (o tu) manda il WOL: wakeonlan 2c:f0:5d:56:08:bc
```

**C. Dal Pi via CLI** (equivale al bot, per cron/script):
```bash
/home/tillo/ai-rig-wol-bot/pi-remote-boot-select.sh hermes
```

Verifica ruolo attivo, ovunque:
```bash
cat /etc/ai-rig/role
```

---

## 5. MANUTENZIONE

### Aggiornare il modello di un ruolo (a caldo, sul ruolo attivo)
```bash
sudo swap-model.sh <gguf url|path locale> [--mmproj <url|path>]
# aggiorna anche config/roles/<ruolo>.env sulla build machine per le re-install
```

### Cambiare motore llama (beellama <-> mainline)
```bash
sudo /usr/local/bin/swap-llama-flavor.sh    # vedi README, cache type turbo*/q8_0
```

### Deploy/aggiorna DEVIN AI IDE sul rig (dalla build machine)
```bash
bash scripts/deploy-devin-webapp.sh ~/devin_ai_ide tillo@192.168.1.100
# dashboard: http://192.168.1.100:5000
```

### Ripopolare/aggiornare la cache di un ruolo (4TB collegato)
```bash
sudo populate-cache.sh                       # ricopia + riabilita stage
```

---

## 6. DIAGNOSTICA RAPIDA

```bash
# stato servizi ruolo
systemctl status llama-server@$(cat /etc/ai-rig/role)
curl -fs http://localhost:8080/health && echo OK          # API llama

# GPU + power limit 1080 instabile
nvidia-smi
journalctl -t gtx1080-powerlimit -n 5                     # conferma 180W applicati

# stage di primo boot
ls -l /var/log/ai-rig-stage-*.log
sudo systemctl restart ai-rig-stage-<nome>                # rilancia una stage fallita

# 4o disco condiviso (AutoMem) + SMART enclosure
ai-rig-smart.sh -H                                        # salute NVMe in enclosure USB
lsblk -f | grep ai-rig-shared

# rete
ip a ; ping 192.168.1.100 ; cat /etc/ai-rig/role

# report completo di verifica
cat /var/log/ai-rig-verify.log
```

---

## 7. NOTE / TRAPPOLE

- **Install richiede rete cablata**: l'autoinstall fa DHCP solo su `en*`; il dongle
  WiFi NON e' usabile durante l'install (serve un cavo LAN per scaricare gli apt).
  Dopo l'install puoi passare al WiFi.
- **Stesso IP su cavo e WiFi**: ok solo se non sono mai su entrambi insieme. Il
  cavo e' STATICO .100; per il WiFi metti la prenotazione DHCP .100 sul MAC del
  dongle. Quando torni al cavo: stacca il dongle PRIMA.
- **Cambio ruolo lento (~4-6 min)**: e' il cold boot voluto (7 GPU). Normale.
- **Bot non risponde "non autorizzato"**: il tuo chat_id non e' in ALLOWED_CHAT_IDS
  → guardalo in `journalctl -u <bot>` e aggiungilo alla config.
- **Token bot**: uno diverso per ogni bot (4 bot: Pi + devin + hermes + teacher).
- **SSH "REMOTE HOST IDENTIFICATION HAS CHANGED"** dopo una REINSTALLAZIONE: e'
  normale, NON un attacco. Reinstallare un ruolo rigenera le chiavi host SSH del
  rig, ma il tuo PC ha ancora quella vecchia in `known_hosts`. Fix (dal PC):
  ```
  ssh-keygen -R 192.168.1.100      # rimuove la chiave vecchia (idem .86 per il Pi)
  ssh tillo@192.168.1.100          # riaccetta la nuova: digita "yes"
  ```
  Stessa cosa vale per il Pi (`ssh-keygen -R 192.168.1.86`) se lo reinstalli.
