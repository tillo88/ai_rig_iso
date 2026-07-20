# AI Rig — ISO multi-boot Ubuntu 24.04 (DEVIN / HERMES / TEACHER)

Una chiavetta USB che installa **3 sistemi Ubuntu Server separati su 3 dischi**,
ognuno con il suo modello AI, il suo llama-server e le sue dipendenze:

| Ruolo | Fa | Modello | Porta API |
|---|---|---|---|
| **DEVIN** | coding/debug agent | Ornith 35B (MoE) | 8080 |
| **HERMES** | chat con memoria, vision, immagini, web | DavidAU Deckard 40B | 8080 |
| **TEACHER** | reasoning/vision per una AI più piccola | Qwen3-VL 30B Thinking | 8080 |

Un solo sistema è acceso alla volta (stesso IP: `192.168.1.100`). Si sceglie quale
dal menu GRUB, da SSH, o dal telefono via bot Telegram. Il rig si accende da
spento via Wake-on-LAN.

- **📚 Indice di TUTTA la documentazione** → `docs/INDEX.md`
- **Installazione attuale (ISO leggera, modelli copiati dopo l'install)** → `docs/INSTALL-FLOW-LIGHT.md` ⭐
- **Dopo l'install** (bot, cambio ruolo, comandi agent, troubleshooting) → `docs/AFTER-INITIAL-SETUP.md`
- **Come si usa** → sei nel posto giusto, continua a leggere.
- **Perché è fatto così** (scelte tecniche, bug corretti, modelli) → `docs/DESIGN.md`
- **Come si collegano DEVIN AI IDE e ForgeStudio a questo rig** → `docs/PACCHETTO-UNIFICATO.md`
- **Bot Telegram sul Pi** → `pi-bot/README.md`
- **GRUB via rete (avanzato, opzionale)** → `scripts/README-netboot.md`

> ℹ️ **Nota flusso install:** dal 2026-07-16 la ISO è **leggera** (non baka i ~110GB
> di modelli): li copi dopo l'install con `populate-cache.sh`. Le PARTE 2–3 qui
> sotto restano valide per l'ordine dei passi; il dettaglio autoritativo del
> flusso attuale è in **`docs/INSTALL-FLOW-LIGHT.md`**. Rete definitiva: rig a
> **192.168.1.100**, gateway .254.

> ⚠️ **Tutti gli script si lanciano con `bash`, MAI con `python3`** (sono script
> di shell, anche se l'estensione può trarre in inganno).

> 📦 **Aggiornamenti del progetto**: gli zip di aggiornamento **non contengono
> mai** i tuoi `config/*.env` (seriali, MAC, parametri) né `cache/` — sono tuoi
> e non vengono sovrascritti. Per aggiornare basta scompattare sopra la
> cartella del progetto:
> ```bash
> unzip -o ai-rig-iso-build-update.zip -d ~/ai-rig-iso-build/
> ```
> Se un aggiornamento richiede una variabile nuova in un env, viene indicata a
> parte come riga da aggiungere a mano.

---

# PARTE 1 — Preparazione (sulla tua WSL/PC, senza il rig)

Puoi fare tutta questa parte **prima** che l'hardware sia pronto.

## 1.1 Scarica modelli, driver e checkpoint

```bash
cd ~/ai-rig-iso-build
bash scripts/download-cache.sh
```

- Riprende da dove era se cade la linea: rilancialo quante volte vuoi.
- Salta automaticamente ciò che hai già.
- Se qualcosa fallisce, prosegue e ti dà il riepilogo alla fine con gli URL da
  controllare a mano.

**Due cose restano manuali:**

1. **mmproj di Hermes** — se non l'hai già (`cache/models/hermes/mmproj-*.gguf`):
   scaricane UNO da [questa pagina](https://huggingface.co/DavidAU/Qwen3.6-40B-Claude-4.6-Opus-Deckard-Heretic-Uncensored-Thinking-NEO-CODE-Di-IMatrix-MAX-GGUF/tree/main)
   e verifica che il nome del file combaci con `ROLE_MMPROJ_FILE` in
   `config/roles/hermes.env`. Lo script controlla e ti avvisa se non combaciano.
2. **Chiave SSH del bot** — copia la `.pub` generata sul Raspberry in
   `cache/ai-rig-bot.pub`. Senza, il bot non potrà entrare via SSH.

## 1.2 Scegli il motore di inferenza (opzionale, c'è già un default)

In `config/rig.env`:

```bash
LLAMA_FLAVOR="beellama"   # default: fork con KV cache compressa ~7.5x
# LLAMA_FLAVOR="mainline" # llama.cpp ufficiale, se preferisci zero rischi
```

I tuoi modelli `.gguf` funzionano identici con entrambi. Puoi cambiare idea
anche DOPO l'installazione, senza rifare nulla (vedi Parte 4).

---

# PARTE 2 — Rig assemblato: dati reali e prima ISO

## 2.1 Raccogli seriali dischi e MAC (una volta sola)

Boota il rig con una USB Ubuntu qualsiasi (va bene anche questa, voce
"Try or Install Ubuntu Server"), apri una shell e:

```bash
bash scripts/00-preflight.sh
```

È **read-only**, non tocca nulla, rilanciabile all'infinito. Ti stampa:
- i **SERIAL** dei dischi → copiali in `config/disks.env`
- i **MAC** delle schede di rete → il MAC della NIC collegata al router va in
  `config/network.env` (sia `LAN_MAC` che `WOL_MAC`)
- le GPU rilevate (se mancano perché aspetti i riser: **non è un problema**,
  vengono ri-rilevate ad ogni avvio)

Il 4° disco (memoria condivisa/backup) è **opzionale**: se ce l'hai, metti il suo
seriale in `config/shared-disk.env`; se non ancora, lascia CHANGEME — si
aggiunge dopo senza reinstallare niente.

## 2.2 Costruisci la ISO

```bash
bash build-iso.sh
```

Fa tutto da solo: verifica la cache, pre-compila il motore scelto (una volta
sola, poi viene copiato su tutti e 3 i dischi), scarica la ISO Ubuntu ufficiale,
produce **`ubuntu-24.04-ai-rig-multiboot.iso`**.

Se hai lasciato dei CHANGEME ti avvisa e chiede conferma: puoi fare un build di
prova, ma IP statico/WOL/dischi non funzioneranno finché non compili i valori veri.

## 2.3 Scrivi la ISO su USB

Con `dd`, Rufus o balenaEtcher. La chiavetta viene sovrascritta.

---

# PARTE 3 — Installazione sul rig (3 dischi, uno alla volta)

## 3.1 Pulizia dischi (consigliata, una volta)

Boot dalla USB → voce di default **"Try or Install Ubuntu Server"** (NON le voci
"Install AI Rig") → premi `Ctrl+Alt+F2` per una shell → poi:

```bash
sudo bash /cdrom/scripts/01-wipe-disks.sh
```

- Tocca **SOLO** i dischi i cui seriali sono in `disks.env` (whitelist: la
  chiavetta non può essere colpita perché non è in lista).
- Chiede di digitare `WIPE` per confermare.
- Serve contro vecchie firme RAID/LVM che nasconderebbero i dischi. Dischi
  nuovi di fabbrica non ne hanno bisogno, ma male non fa.

## 3.2 Le 3 installazioni

Riavvia dalla USB. Nel menu vedi 3 voci: installale **una alla volta**, in
quest'ordine:

1. **Install AI Rig - DEVIN** → parte da sola e fa tutto: partiziona il disco
   giusto (lo trova per seriale), installa Ubuntu, poi al primo avvio: driver
   NVIDIA → **riavvio automatico** (è normale! non toccare) → CUDA → motore →
   rilevamento GPU → copia modello → avvio llama-server → verifica.
2. Quando DEVIN risponde (vedi 3.3), riavvia dalla USB → **Install AI Rig - HERMES**
3. Idem → **Install AI Rig - TEACHER**

Ogni voce tocca **solo il suo disco**: gli altri restano intatti anche se
fisicamente collegati.

## 3.3 Come sai che un ruolo è pronto

```bash
ssh tillo@192.168.1.100        # password iniziale: tillo
```

> 🔐 **Cambiala SUBITO con `passwd`** — il default esiste solo per il primo accesso.

Poi:
```bash
cat /var/log/ai-rig-verify.log      # report completo dell'ultimo controllo
curl http://localhost:8080/health   # 200 = llama-server operativo
```

Il primo avvio è lungo: modello 20-32GB da copiare + eventuale compilazione.
Con GPU parziali (riser non arrivati) Hermes/Teacher resteranno in
riavvio-continuo finché la VRAM non basta: **è atteso e innocuo**, si sistema da
solo quando aggiungi le schede e riavvii.

## 3.4 Unifica il menu di boot (una volta, alla fine)

Boota su DEVIN e:

```bash
sudo bash /opt/cache/scripts/grub-centralize.sh      # trova gli altri 2 sistemi
sudo bash /opt/cache/scripts/grub-stable-entries.sh  # crea le voci "devin/hermes/teacher"
```

Poi imposta DEVIN come primo disco di boot nel BIOS/UEFI (il secondo script ti
mostra il comando `efibootmgr` per farlo da terminale).

Da questo momento cambi sistema con:
```bash
sudo grub-reboot hermes && sudo reboot     # o devin, o teacher
```

## 3.5 Bot Telegram (dal telefono)

Deploy sul Pi: segui `pi-bot/README.md` (5 minuti). Poi da Telegram:

| Comando | Fa |
|---|---|
| `/wakeup` | accende il rig (ruolo di default) |
| `/devin` `/hermes` `/teacher` | accende se spento E passa a quel ruolo |
| `/status` | online? API pronta? quale ruolo è attivo? |
| `/verify` | ultimo report di verifica |

## 3.5b Bot Telegram dedicati per ruolo (sul rig)

Oltre al bot Pi (che accende/cambia ruolo), ogni ruolo del rig ha il **suo** bot,
con una **chat Telegram separata** — così non si impastano i contesti. Girano sul
disco del ruolo: partono da soli quando il rig boota in quel ruolo, e non esistono
sugli altri. Sono già abilitati dalla ISO; ti resta solo da dargli il token.

| Bot | Ruolo | A cosa serve | Comandi |
|---|---|---|---|
| `teacher-bot` | teacher | Non restare al buio quando ForgeStudio gira mentre sei fuori | `/status`, `/restart`, `/ask <testo>`, `/ask`+foto (vision), `/watch on\|off` |
| `hermes-bot` | hermes | Chattare con Hermes (memoria AutoMem + web) dal telefono | testo libero → risposta, `/status`, `/help` |
| `devin-bot` | devin | Pilotare la dashboard DEVIN dal telefono | `/project`, `/fixit`, `/status`, `/runs`, testo libero |

**Cosa fa il teacher-bot da solo (watchdog):** controlla il llama-server ogni 15s
e, se cade mentre sei fuori, ti manda un alert ("ForgeStudio è senza insegnante").
`/restart` riavvia il servizio; se il rig è bloccato del tutto, usi il bot Pi per
il reboot completo.

**Setup (una volta per bot, al primo boot del ruolo):**

1. Su [@BotFather](https://t.me/BotFather) crea un bot **separato** per ciascuno
   (token diverso) — è ciò che tiene le chat non impastate.
2. Via SSH sul rig, crea la config dall'esempio e incolla token + il tuo chat_id:
   ```bash
   # esempio per teacher (analogo per hermes/devin):
   sudo mkdir -p /etc/teacher-bot
   sudo cp /cdrom/rig-roles/teacher/teacher-bot.env.example /etc/teacher-bot/config.env  # o dal repo
   sudo nano /etc/teacher-bot/config.env    # BOT_TOKEN + ALLOWED_CHAT_IDS
   ```
3. Proprietario del file: **teacher-bot gira come root** (deve riavviare i servizi),
   **hermes-bot e devin-bot come `tillo`**. Regola i permessi di conseguenza
   (`chmod 600`, `chown` all'utente giusto).
4. Non serve `systemctl start`: il servizio ritenta ogni 30s, quindi appena la
   config è valida il bot sale da solo. (Se vuoi forzare: `sudo systemctl start teacher-bot`.)

Il tuo `chat_id` lo trovi scrivendo al bot e leggendo
`https://api.telegram.org/bot<TOKEN>/getUpdates`, campo `chat.id`.

## 3.6 Misura i cache type (una volta, quando hai tutte le GPU)

```bash
sudo bash /usr/local/bin/bench-kv-cache.sh
```

Ti dice, **sul tuo hardware e col tuo modello**, se la compressione KV di
BeeLlama conviene sulle tue GPU Pascal o se è meglio q8_0. Leggi le note che
stampa alla fine: spiegano come interpretare i numeri.

---

# PARTE 4 — Uso quotidiano e manutenzione

## Cambiare ruolo
- Dal telefono: `/devin` `/hermes` `/teacher` sul bot
- Da SSH: `sudo grub-reboot <ruolo> && sudo reboot`
- Da spento: `/wakeup` accende il default; poi eventualmente cambi ruolo

## Cambiare motore (beellama ↔ mainline) senza rifare la ISO
```bash
sudo bash /usr/local/bin/swap-llama-flavor.sh mainline   # o beellama
```
Ricompila e riavvia. **Non tocca i modelli.** Se la build fallisce, rimette da
solo la versione precedente. Le sessioni KV salvate (incompatibili tra i due)
vengono parcheggiate sul 4° disco e ripristinate se torni indietro.

> ⚠️ Unica cosa da NON fare mai: ri-quantizzare i pesi in TQ3_1S/TQ4_1S con
> `llama-quantize` — quello sì è irreversibile. I cache type turbo invece sono
> sicuri: non toccano i file.

## Aggiungere il 4° disco (quando arriva)
1. Guarda il seriale (dal tuo PC o con `lsblk -d -o NAME,SERIAL` sul rig)
2. Scrivilo in `/opt/cache/config/shared-disk.env` **su ogni disco** (o rifai la
   ISO con `config/shared-disk.env` compilato, per i prossimi reinstall)
3. Riavvia: viene formattato solo se vuoto, mai due volte, e ci finiscono
   AutoMem (memoria condivisa tra i 3 ruoli), i backup giornalieri e le
   sessioni KV parcheggiate.

## Se muore un disco
```bash
bash scripts/reinstall-role.sh hermes NUOVO_SERIALE   # sulla build machine
```
Aggiorna la config, ricostruisce la ISO. Poi installi SOLO quella voce: gli
altri 2 dischi non vengono toccati.

## DFlash (accelerazione futura)
Se esce un drafter per uno dei tuoi modelli: copialo in
`/opt/models/<ruolo>/dflash-drafter.gguf` e riavvia il servizio. Viene rilevato
da solo. (Oggi non esiste per nessuno dei tre — dettagli in `docs/DESIGN.md`.)

---

# Indice script — quale, dove, quando

### Sulla macchina di build (WSL/PC)
| Script | Quando | Root? |
|---|---|---|
| `scripts/download-cache.sh` | prima del build | no |
| `build-iso.sh` | ogni volta che cambi `config/` | sì (mount ISO) |
| `scripts/reinstall-role.sh <ruolo> <serial>` | disco morto | no |
| `scripts/recommend-stack.sh [--llm]` | pianificare un rig futuro | no |
| `scripts/05-generate-nocloud.sh` | automatico (lo chiama build-iso) | no |

### Nell'ambiente live (USB, prima di installare)
| Script | Quando | Note |
|---|---|---|
| `scripts/00-preflight.sh` | per primo | read-only, sicuro |
| `/cdrom/scripts/01-wipe-disks.sh` | prima delle install | **distruttivo**, whitelist + "WIPE" |

### Sul rig installato (`/usr/local/bin/` + `/opt/cache/scripts/`)
| Script | Quando |
|---|---|
| `10-…`→`70-…` | automatici (systemd), non lanciarli a mano |
| `90-verify.sh` | anche a mano, report al volo |
| `bench-kv-cache.sh` | una volta, con tutte le GPU |
| `swap-llama-flavor.sh <flavor>` | per cambiare motore |
| `/opt/cache/scripts/grub-centralize.sh` | una volta su DEVIN, dopo le 3 install |
| `/opt/cache/scripts/grub-stable-entries.sh` | subito dopo il precedente |

### Sul Raspberry Pi
| File | Note |
|---|---|
| `pi-bot/` | il bot — deploy in `pi-bot/README.md` |
| `scripts/pi-remote-boot-select.sh` | alternativa CLI al bot (cron/script) |

---

# Troubleshooting

**`SyntaxError: invalid decimal literal`** → hai usato `python3` su uno script
`.sh`. Usa `bash`.

**Dove sono i log?** Ogni fase ha il suo, sul disco del ruolo attivo:
```
/var/log/ai-rig-stage-driver.log        driver NVIDIA
/var/log/ai-rig-stage-cuda-llama.log    CUDA + compilazione motore
/var/log/ai-rig-stage-gpudetect.log     rilevamento GPU / tensor-split
/var/log/ai-rig-stage-shareddisk.log    4° disco
/var/log/ai-rig-stage-automem.log       AutoMem
/var/log/ai-rig-stage-role.log          copia modello + avvio servizio
/var/log/ai-rig-hermes-extras.log       (solo Hermes) agent/ComfyUI/SearXNG
/var/log/ai-rig-verify.log              report di verifica
/var/log/llama-server-<ruolo>.log       output del llama-server
```
Per i servizi: `journalctl -u ai-rig-stage-<nome> -n 50`

**Sembra bloccato dopo il primo riavvio** → normale: lo stage driver riavvia
apposta prima di usare `nvidia-smi`. Riprende da solo, aspetta.

**llama-server si riavvia in continuazione** → quasi sempre VRAM insufficiente.
Con GPU parziali è **atteso** per Hermes/Teacher. Controlla il log del server;
per farlo partire lo stesso puoi abbassare `ROLE_CTX_SIZE` in
`config/roles/<ruolo>.env` e rifare la ISO, o aspettare le altre GPU.

**Rieseguire una fase già completata** →
`sudo rm /var/lib/ai-rig/stage-<nome>-done` e riavvia (o
`sudo systemctl start ai-rig-stage-<nome>`).

**GPU rilevate ≠ 7** → il rilevamento gira a **ogni boot**: monta le schede
mancanti, riavvia, si ricalcola tutto da solo. Nessuna reinstallazione.

**`grub-reboot hermes` → "entry not found"** → non hai ancora eseguito
`grub-stable-entries.sh` su DEVIN, oppure stai bootando dal GRUB di un altro
disco (controlla `efibootmgr -v`).

**Bot: "Non autorizzato"** → il tuo chat_id non è in `ALLOWED_CHAT_IDS`
(`/etc/ai-rig-bot/config.env` sul Pi). Il chat_id giusto compare in
`journalctl -u ai-rig-wol-bot` ad ogni comando rifiutato.

**Download fallito con 404** → l'URL upstream è cambiato. Il riepilogo di
`download-cache.sh` ti dice quale: verificalo nel browser e aggiorna l'URL
nello script (per i driver NVIDIA: rispetta il vincolo Pascal, vedi
`docs/DESIGN.md`).

**Ho ri-quantizzato pesi in TQ e mainline non li apre** → irreversibile per
design. Riscarica il GGUF originale. (Per questo il README dice di non farlo.)

---

# Checklist rapida — cosa manca prima del primo boot

- [ ] `config/disks.env` — seriali reali dei 3 dischi (da `00-preflight.sh`)
- [ ] `config/network.env` — MAC reale della NIC
- [ ] `cache/` completa — `bash scripts/download-cache.sh` senza falliti
- [ ] mmproj Hermes presente e col nome giusto in `config/roles/hermes.env`
- [ ] `cache/ai-rig-bot.pub` — chiave del Pi
- [ ] `bash build-iso.sh` → ISO scritta su USB
- [ ] (dopo) `bench-kv-cache.sh` con tutte le GPU
- [ ] (opzionale) 4° disco in `config/shared-disk.env`
