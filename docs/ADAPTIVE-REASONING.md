# Adaptive reasoning: un agente forte con un modello strozzato

Un modello locale piu' piccolo non va caricato di un enorme prompt che gli
chiede di essere contemporaneamente pianificatore, archivista, esecutore e
giudice. Il rig esternalizza queste funzioni in un harness comune.

## Ciclo

`recall -> frame -> plan -> act -> verify -> reflect -> publish`

1. **Recall**: consulta il Librarian se la seed indica memoria pertinente.
2. **Frame**: separa fatti, ipotesi, vincoli e incognite.
3. **Plan**: sceglie il minimo piano utile in base al rischio.
4. **Act**: usa strumenti deterministici e compie un passo osservabile.
5. **Verify**: misura l'esito; il self-report non vale come prova.
6. **Reflect**: classifica il fallimento e cambia strategia, non solo parole.
7. **Publish**: salva una lezione soltanto dopo il quality gate.

## Profondita' adattiva

- Basso rischio: risposta diretta e sanity check.
- Medio: piano breve, strumenti e verifica oggettiva.
- Alto: conferma indipendente/umana prima di mutazioni irreversibili.

Il modello non deve mostrare una lunga catena di pensiero. Deve invece produrre
artefatti controllabili: piano breve, azioni, evidenze, stato e prossima scelta.

## Anti-loop

Dopo due fallimenti con la stessa strategia deve cambiare approccio. Dopo tre
errori equivalenti deve escalare o fermarsi. Un retry e' ammesso solo con nuova
evidenza, nuovi parametri o uno strumento diverso.

## Divisione del lavoro

- Librarian: recall, provenienza, consolidamento e quality gate.
- Modello attivo: comprensione semantica e scelta della prossima azione.
- Tool/verificatori: fatti osservabili.
- Teacher/modello maggiore: critica ed escalation dei casi difficili.
- Memoria: apprendimento persistente senza modificare continuamente i pesi.

La policy eseguibile e' `config/cognitive-policy.json`.
