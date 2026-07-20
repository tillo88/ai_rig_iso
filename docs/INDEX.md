# AI Rig — Indice della documentazione

Mappa di tutti i doc del progetto. Rete: rig **192.168.1.100**, Pi **192.168.1.86**,
gateway **.254**. Un ruolo (devin/hermes/teacher) acceso alla volta, API su `:8080`.

## Parti da qui
- **[../README.md](../README.md)** — guida principale: preparazione, build ISO, install, uso quotidiano, troubleshooting, indice script.
- **[INSTALL-FLOW-LIGHT.md](INSTALL-FLOW-LIGHT.md)** ⭐ — **flusso di install ATTUALE**: ISO leggera (~5GB, non baka i 110GB) + `populate-cache.sh` per i modelli.
- **[AFTER-INITIAL-SETUP.md](AFTER-INITIAL-SETUP.md)** — dopo l'install: come si comandano gli agent, bot Telegram, cambio ruolo, manutenzione, diagnostica, trappole (incl. host key SSH dopo reinstall).

## Architettura e scelte
- **[DESIGN.md](DESIGN.md)** — decisioni di design e storia del progetto: perché beellama, driver Pascal, modelli scelti, bug corretti.
- **[PACCHETTO-UNIFICATO.md](PACCHETTO-UNIFICATO.md)** — mappa dell'ecosistema: il rig e i suoi 3 client (devin_ai_ide, ForgeStudio), vincolo un-ruolo-alla-volta, specifiche hardware corrette.

## Memoria condivisa
- **[FEDERATED-MEMORY.md](FEDERATED-MEMORY.md)** — memoria federata DEVIN/TEACHER/HERMES: `shared/` (verificato) vs `agents/<ruolo>/{raw,quarantine}`, policy.
- **[UNDERSTORY.md](UNDERSTORY.md)** — sidecar Understory (bundle OKF) + gateway **Librarian** con quality gate; accesso via tunnel SSH, rollback.

## Roadmap e ricerca
- **[ROADMAP-INTELLIGENCE.md](ROADMAP-INTELLIGENCE.md)** — avvicinare i bot a un agente forte con hardware locale.
- **[ADAPTIVE-REASONING.md](ADAPTIVE-REASONING.md)** — agente forte con un modello "strozzato": reasoning adattivo.

## Hardware / BIOS
- **[POST-BIOS-NOTES.md](POST-BIOS-NOTES.md)** — note operative su POST, BIOS (MSI X299), hardware, WOL.

## Bot e rete (Raspberry Pi)
- **[../pi-bot/README.md](../pi-bot/README.md)** — deploy del bot Telegram WOL/cambio-ruolo sul Pi.
- **[../pi-bot/NETWORK-SETUP.md](../pi-bot/NETWORK-SETUP.md)** — rete del Pi: MAC, IP fisso sul Fastgate, watchdog, requisiti WOL.

## Avanzato / opzionale
- **[../scripts/README-netboot.md](../scripts/README-netboot.md)** — Fase B: scelta del ruolo via rete (TFTP) a rig spento, un boot solo. Opzionale.
- **[../cache/README.md](../cache/README.md)** — cosa contiene `cache/` (modelli, driver, prebuilt).
- **[../evaluation/README.md](../evaluation/README.md)** — harness di valutazione.

## Storico
- **[../BUILD-VALIDATION-20260714.md](../BUILD-VALIDATION-20260714.md)** — snapshot di validazione build del 2026-07-14 (storico; riporta l'IP e lo stato di allora, non aggiornato di proposito).
