# AI Rig — fix runtime consolidati 2026-07-19

Questo pacchetto modifica **solo i sorgenti autorevoli**. Non tocca direttamente DEVIN, HERMES, TEACHER o WolPi e non include token reali.

## Fix inclusi

- ComfyUI: modelli direttamente su `__SHARED_MOUNT_PATH__/comfyui-models`; output su `comfyui-output`; niente copia da 31 GB nella root HERMES.
- Ordinamento first boot: `populate-cache` parte dopo lo stage del disco condiviso.
- HERMES extras: dipendenze Docker/shared disk, retry su errore, timeout 60 minuti e installazione ComfyUI realmente verificata.
- AutoMem: `make install` con hash/stamp, niente `make dev`, `docker compose up -d`, dati sul disco condiviso e controllo preventivo dello spazio root.
- Cambio ruolo: grubenv centrale + rilevamento dinamico ESP DEVIN tramite seriale/PARTUUID + `BootNext` verificato + DEVIN primo nel `BootOrder`.
- Bot WolPi: una sola operazione distruttiva, niente coda di duplicati, comandi vecchi ignorati, polling Telegram non bloccato, OFF reale 60 s, conferma ruolo e API.
- `/verify`: report rigenerato al momento; aggiunto controllo spazio root/shared disk.
- Teacher bot: grace di boot predefinita 15 minuti e reset dello stato watchdog a ogni nuovo boot.
- systemd: `StartLimitIntervalSec`/`StartLimitBurst` spostati nella sezione corretta del template llama-server.
- Aggiunto `config/teacher-bot.env.example` privo di segreti.

## Applicazione

```bash
cd ~/ai-rig-iso-build
bash /percorso/ai-rig-runtime-fixes-20260719/apply.sh "$PWD"
```

Lo script verifica gli SHA-256 dei sorgenti analizzati, crea un backup in `.runtime-fix-backups/`, copia i file e valida Bash/Python. Se i file locali sono cambiati nel frattempo, si ferma senza sovrascriverli.

Dopo la revisione:

```bash
bash scripts/05-generate-nocloud.sh
git diff --check
git diff
```

## Sicurezza importante

Nell'archivio sorgente ricevuto erano presenti credenziali Telegram reali nei file di configurazione TEACHER. Questo pacchetto non le contiene. Il token va revocato/rigenerato tramite BotFather e i file `config/*-bot.env` devono restare fuori da Git.

## Non incluso

L'audit precedente segnalava anche `rig-roles/devin/systemd/devin-webapp.service` con direttive StartLimit nella sezione sbagliata, ma quel file non era presente nell'archivio fornito e quindi non viene modificato alla cieca.
