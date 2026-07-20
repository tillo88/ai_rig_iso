# Understory sul rig multiruolo

Understory e' installato come sidecar sperimentale accanto ad AutoMem. Il bundle
OKF vive in `/mnt/ai-rig-shared/understory/bundle`, quindi DEVIN, HERMES e
TEACHER vedono la stessa memoria anche se ciascun ruolo usa il proprio disco.

La condivisione e' federata, non indiscriminata: `shared/` contiene soltanto
lezioni verificate o confermate dall'utente; `agents/<ruolo>/raw` e
`agents/<ruolo>/quarantine` conservano l'esperienza completa senza contaminarne
il recall. Tutti i bot possono consultare ogni dominio verificato, mantenendo
sempre autore e prove. Vedi `docs/FEDERATED-MEMORY.md` e
`config/memory-policy.json`.

L'interfaccia comune viene chiamata **Librarian**: i bot gli chiedono di cercare,
aggiungere o aggiornare conoscenza senza dover conoscere OKF, indici e struttura
del bundle. Understory costituisce biblioteca e motore; il Librarian applica
policy, quality gate, provenienza e manutenzione.

Solo un ruolo e' avviato alla volta: c'e' quindi un solo processo Understory che
scrive nel bundle. L'immagine 0.1.0 non contiene il binario `git`: un timer host
attende almeno un minuto di quiete e crea commit ogni cinque minuti. Il timer di
backup produce inoltre Git bundle periodici.

## Accesso sicuro dalla workstation

Understory non implementa autenticazione applicativa; la porta e' esposta solo
su loopback. Aprire un tunnel:

```bash
ssh -L 3800:localhost:3800 tillo@192.168.1.100
```

Web UI e MCP diventano disponibili su `http://localhost:3800` e
`http://localhost:3800/mcp`.

Le applicazioni devono usare il gateway Librarian su `http://localhost:3810/mcp`.
La porta 3800 resta l'interfaccia amministrativa diretta di Understory; scrivere
li' bypasserebbe quality gate e quarantena.

## Rollback o disattivazione

- `ENABLE_UNDERSTORY=false` in `config/shared-disk.env` disabilita il sidecar.
- AutoMem resta installato e indipendente su porta 8001.
- La memoria si ripristina con Git dentro il bundle o dai file
  `/mnt/ai-rig-shared/backups/<ruolo>/understory-*.bundle`.
- L'immagine effettivamente scaricata e' registrata in
  `/var/lib/ai-rig/understory-image.txt`.

Il progetto upstream non pubblica ancora una licenza esplicita: per questo la
ISO non incorpora il sorgente, ma scarica l'immagine esterna configurata al primo
avvio. Rivalutare prima di redistribuire una ISO con l'immagine inclusa.
