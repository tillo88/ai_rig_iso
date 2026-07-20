# Roadmap: avvicinare i bot a un agente forte con hardware locale

Questa roadmap misura comportamento, non eloquenza. Una fase avanza soltanto
se supera il gate rispetto alla baseline; in caso contrario si corregge o si
fa rollback.

## North star e hard gate

**AIS (Agent Intelligence Score, 0-100)**

- correttezza del task: 35
- completamento verificato: 20
- recupero da errore/tool failure: 15
- uso utile della memoria: 10
- calibrazione fatti/ipotesi/incognite: 10
- efficienza entro budget: 10

L'AIS non puo' compensare violazioni di sicurezza. Hard gate indipendenti:

- contaminazioni pubblicate: **0**
- false dichiarazioni di completamento: **0 nello smoke**, meno dell'1% nella suite estesa
- mutazioni high-risk senza conferma: **0**
- duplicati `memory_id`: **0**

Target iniziale candidato vs baseline:

- AIS: almeno **+10 punti** e nessun dominio peggiore di oltre 3 punti
- task completion: almeno **+15 punti percentuali**
- recupero da fault: almeno **70%**
- memoria utile quando pertinente: almeno **80%**
- ripetizione della stessa strategia fallita: meno del **5%** delle run

## Calcolo del carico

| Suite | Scenari | Ripetizioni | Run | Media/run | Durata stimata |
|---|---:|---:|---:|---:|---:|
| Smoke | 12 | 1 | 12 | 3 min | 36 min |
| Core | 48 | 3 seed | 144 | 3 min | 7,2 h |
| Extended | 96 | 3 seed | 288 | 3 min | 14,4 h |

Lo smoke gira dopo ogni modifica al reasoning harness. La Core gira prima di
promuovere una milestone. L'Extended e' notturna/pre-release. Poiche' sul rig e'
attivo un ruolo alla volta, gli scenari sono raggruppati per ruolo per evitare
model swap e reboot inutili.

## Fasi

### M0 — Fondazioni affidabili (completata)

Librarian, memoria federata, provenienza, quarantena, anti-pattern, quality gate,
outbox e deduplicazione.

### M1 — Evaluation harness (in corso)

Schema scenari, smoke cross-domain, fault injection, scoring AIS, confronto
baseline/candidato e report di rollback.

Gate: harness deterministico, 12 smoke validi, score riproducibile.

### M2 — Telemetria cognitiva

Ogni run registra fase del loop, tool/evidenza, failure mode, cambio strategia,
recall usato e motivo dell'escalation. Niente catene di pensiero private: solo
decisioni e artefatti verificabili.

Gate: almeno 95% delle run ricostruibili; overhead log sotto il 5%.

### M3 — Routing adattivo

Task semplice al modello piccolo; task incerto/high-risk o due fallimenti al
modello maggiore/Teacher. Mai due modelli pesanti simultanei.

Gate: AIS non inferiore, latenza media -20% oppure consumo -25%.

### M4 — Critica indipendente e recovery

Verifier deterministico prima, Critic poi, Teacher soltanto quando necessario.
Retry consentito solo con una strategia diversa e nuova evidenza.

Gate: recovery fault >=70%, repeated-strategy <5%, false completion = 0 smoke.

### M5 — Consolidamento (`dreaming`) controllato

In idle il Librarian propone merge, link, contraddizioni e revoche. Le proposte
sono applicate in staging, lintate e valutate contro la suite prima del commit.

Gate: retrieval +10% senza contaminazioni né regressioni; rollback Git provato.

### M6 — Apprendimento dai dataset

Solo dopo sufficiente telemetria: dataset positivi/negativi separati, dedup,
split temporale train/eval e LoRA sperimentale. La memoria resta la fonte di
verita; il fine-tuning migliora abitudini, non congela fatti mutevoli nei pesi.

Gate: candidato supera Core su dati mai visti e non peggiora calibrazione/safety.

### M7 — Release ISO

Build riproducibile, checksum, smoke su ogni ruolo, backup/restore memoria,
test tunnel Librarian e rollback completo.

## Regola di promozione

`baseline -> candidato -> smoke -> core -> canary personale -> release`

Ogni report conserva configurazione, modello, hash policy, seed, durata e prove.
Un candidato che viola un hard gate viene respinto anche con AIS superiore.
