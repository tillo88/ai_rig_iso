# scripts/deploy — portare una correzione su un rig gia' installato

La ISO si rifa' raramente. Quando una correzione riguarda uno script di
`rig-common-scripts/`, il rig che sta girando continua a eseguire la versione
con cui fu installato finche' qualcuno non ce la porta: e' cosi' che il
difetto #707 e' rimasto vivo 26 avvii su 26 pur essendo gia' corretto nel
repo.

Qui stanno i generatori che producono un installer autoportante per quel
passaggio.

## Disco condiviso (#707)

```
bash scripts/deploy/genera-installer-shared-disk.sh /tmp/rig-installa-shared-disk.sh
```

Produce uno script unico, da copiare sul rig ed eseguire **come file**
(legge il proprio sorgente incorporato da `$0`, quindi passato su stdin non
funziona e lo dice).

Sul rig:

```
bash /tmp/rig-installa-shared-disk.sh --dry-run     # sola lettura, non serve root
sudo bash /tmp/rig-installa-shared-disk.sh          # installa
```

Cosa garantisce, in ordine:

1. **provenienza** — ricalcola il git blob sha1 del sorgente incorporato e lo
   confronta con quello che il generatore ha scritto dentro. Offline, senza
   git e senza rete. Un installer modificato a mano dopo la generazione si
   rifiuta di partire;
2. **la resa e' quella giusta** — zero placeholder residui, marker attesi
   presenti, punto di mount coerente con quello che poi verifica;
3. **e' il momento giusto** — lo UUID dichiarato deve essere quello del
   filesystem davvero montato, altrimenti si ferma invece di installare una
   sonda che fallirebbe per `uuid-mismatch`;
4. **si puo' tornare indietro** — backup di script, env e `fstab` prima di
   toccarli, permessi lasciati come li trova;
5. **la verifica e' il punto** — riavvia la unit, rilegge **solo le righe
   nuove** del log e pretende `AI_RIG_SHARED_DISK=PASS`. Se non lo trova
   rimette indietro tutto e lo dice.

Prova: `bash tests/test_installer_shared_disk.sh` (33 scenari, nessun
privilegio, nessun rig reale; uno solo dei 33 finisce con l'installazione
riuscita).
