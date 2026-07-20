# Memoria federata di DEVIN, TEACHER e HERMES

La memoria del rig non e' un unico calderone e non e' composta da tre silos.
E' federata: ogni agente conserva la propria esperienza completa, ma condivide
solo lezioni tipizzate e verificate. Tutti possono leggere la parte condivisa.

## Esempio: Hermes consulta DEVIN

Se l'utente chiede a HERMES di controllare velocemente uno script, HERMES:

1. riconosce il dominio `software-engineering`;
2. cerca prima nella memoria condivisa verificata, anche se la fonte e' DEVIN;
3. riceve contenuto, polarita, autore, prove e confidenza;
4. usa le lezioni positive e gli anti-pattern pertinenti;
5. risponde come HERMES, senza fingere di aver eseguito test che appartengono a DEVIN.

La specializzazione influenza il ranking, non il permesso di lettura: DEVIN e'
favorito sul codice, TEACHER su visione/valutazione, HERMES su conversazione e
pianificazione, ma nessuno e' confinato nel proprio ambito.

## Livelli di memoria

- **Episodica privata** (`agents/<bot>/raw`): tentativi, conversazioni, log,
  correzioni e prove complete. Non entra nel recall degli altri bot.
- **Quarantena** (`agents/<bot>/quarantine`): candidate e casi inconcludenti.
- **Conoscenza condivisa** (`shared/<domain>`): solo `verified_success`,
  `human_confirmed` e `verified_failure` esplicitamente negativo.
- **Audit**: record revocati o sostituiti restano ricostruibili, ma sono esclusi
  dal recall operativo.

## Regole di fiducia

- Il self-report del modello non basta mai.
- "Il comando e' partito" non equivale a "la soluzione e' corretta".
- Una lezione positiva richiede test oggettivo, verificatore di fase, conferma
  umana o prova riproducibile.
- Un fallimento utile viene condiviso come anti-pattern, con contesto e
  condizioni; non viene trasformato in verita positiva.
- Ogni memoria condivisa deve dichiarare origine, dominio, stato, polarita,
  prove, confidenza e data.
- Una revoca cambia lo stato e impedisce il recall, senza cancellare la storia.

Il contratto machine-readable e' `config/memory-policy.json`; una copia viene
installata nel bundle Understory condiviso come `policy/memory-policy.json`.

## Il Librarian

Understory indicizza bene la conoscenza Markdown, ma non e' da solo un sistema
di autorizzazione/validazione. I client dei bot devono quindi passare da un
agente di servizio comune chiamato **Librarian**, che:

1. valida metadati e transizioni di stato;
2. mantiene raw/quarantena fuori dall'indice condiviso;
3. pubblica soltanto stati ammessi in `shared/<domain>`;
4. filtra il recall ed espone sempre la provenienza;
5. registra revoche e sostituzioni.

Il nome descrive anche il confine corretto: gli altri bot non devono conoscere
la struttura OKF o manipolare direttamente indici e collegamenti. Chiedono al
Librarian, che trova, cataloga e mantiene la biblioteca.

Seguendo l'architettura descritta dal creatore di Understory, il Librarian deve
inoltre:

- usare regole deterministiche e chiamare l'LLM soltanto per decisioni semantiche;
- esporre permessi minimi diversi per `query`, `add`, `update` e `maintain`;
- fornire a ogni bot una breve **seed memory** all'avvio, affinche' sappia quali
  concetti sono disponibili e interroghi la memoria invece di rispondere solo
  dai pesi del modello;
- applicare `enrich before create`, evitando un file nuovo per ogni fatto;
- creare collegamenti bidirezionali solo quando la relazione e' reale;
- registrare le trace di retrieval e controllare orfani, link rotti e
  contraddizioni.

Rispetto all'implementazione mostrata nel video, il rig aggiunge un quality gate:
il Librarian non puo' promuovere nella memoria condivisa il semplice self-report
di un modello. Servono prova oggettiva, conferma umana o evidenza riproducibile.

Finche' il Librarian completo non e' attivo, la scrittura automatica nella memoria condivisa
deve restare conservativa; il salvataggio umano esplicito vale come
`human_confirmed`.

## Stato dell'integrazione

- Il core Librarian e' incluso nella ISO come `ai-rig-librarian.service` su
  `127.0.0.1:3810`.
- DEVIN usa il gateway tramite tunnel/endpoint 3810.
- Hermes-Agent riceve il server MCP HTTP `librarian` e non scrive piu'
  direttamente tramite il connettore AutoMem.
- TEACHER/ForgeStudio conserva gia' correzioni tipizzate; il publisher dei soli
  record verificati verso Librarian e' il prossimo adapter applicativo.
