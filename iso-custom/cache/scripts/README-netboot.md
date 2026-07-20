# Fase B — Scelta del ruolo via rete a rig SPENTO (opzionale, avanzata)

## Cosa ottieni, in parole povere

**Oggi (Fase A):** rig spento + `/hermes` sul bot = il rig si accende sul ruolo
di default, il bot entra via SSH, fa `grub-reboot hermes`, riavvia. **Due boot.**

**Con la Fase B:** il bot scrive "hermes" in un file sul Pi PRIMA di mandare il
WOL. Il rig si accende, GRUB (prima ancora di caricare qualsiasi sistema) legge
quel file dalla rete e avvia direttamente il ruolo giusto. **Un boot solo.**

Tutto qui: risparmi un riavvio quando parti da spento. Se il doppio boot non ti
pesa, puoi tranquillamente non fare mai questa fase.

## Prerequisiti — spunta tutto prima di iniziare

- [ ] La Fase A funziona: `/devin /hermes /teacher` dal bot cambiano ruolo correttamente
- [ ] `grub-stable-entries.sh` già eseguito su DEVIN (le voci `devin/hermes/teacher` esistono)
- [ ] Il rig boota in UEFI (lo fa: l'abbiamo impostato noi)
- [ ] Conosci l'IP del Pi (in questa guida uso `192.168.1.50` — **sostituiscilo ovunque col tuo**)
- [ ] Monitor + tastiera attaccati al rig per la durata del setup (solo per questo, poi mai più)

---

## STEP 0 — Test di fattibilità (5 minuti, decide tutto)

GRUB deve avere i moduli di rete. Il GRUB firmato di Ubuntu (quello usato con
Secure Boot attivo) spesso **non li include**. Va verificato PRIMA di perdere
tempo col resto:

1. Accendi il rig, e appena appare il menu GRUB premi **`c`** → si apre una
   console con prompt `grub>`
2. Digita, uno alla volta:
   ```
   insmod efinet
   insmod net
   insmod tftp
   ```
3. **Se non compare nessun errore** → sei a posto, digita `net_ls_cards`:
   dovresti vedere una scheda (tipo `efinet0`). Prendi nota del nome. Poi
   `normal` + Invio per tornare al menu e bootare normalmente. **Vai allo STEP 1.**
4. **Se compare `error: file ... not found`** → il tuo GRUB non ha i moduli.
   Due strade:
   - **Semplice**: disabilita Secure Boot nel BIOS (se non era già disattivo) e
     riprova lo STEP 0. Su un server headless in LAN domestica è un compromesso
     accettabile.
   - **Complessa**: buildare/firmare un GRUB custom (MOK enrollment). Non ne
     vale la pena per risparmiare un riavvio — in quel caso lascia perdere la
     Fase B e tieni la Fase A.
5. Mentre sei nel BIOS: cerca una voce tipo **"Network Stack"** o **"PXE Boot"**
   e abilitala — serve perché la NIC sia inizializzata prima che GRUB parta.
   (Sulla MSI X299 Pro di solito è in Settings → Advanced → Network Stack.)

---

## STEP 1 — Server TFTP sul Raspberry Pi

```bash
sudo apt install -y tftpd-hpa
sudo tee /etc/default/tftpd-hpa > /dev/null << 'TFTPEOF'
TFTP_USERNAME="tftp"
TFTP_DIRECTORY="/srv/tftp"
TFTP_ADDRESS=":69"
TFTP_OPTIONS="--secure --create"
TFTPEOF
sudo mkdir -p /srv/tftp
sudo touch /srv/tftp/grub_target
sudo chown -R tftp:tftp /srv/tftp
sudo systemctl enable --now tftpd-hpa
sudo systemctl restart tftpd-hpa
```

**Verifica subito** (da un altro PC in LAN, o dal Pi stesso):
```bash
# metti un contenuto di prova
echo 'set default="hermes"' | sudo tee /srv/tftp/grub_target
# leggilo via TFTP (installa il client se manca: sudo apt install tftp-hpa)
tftp 192.168.1.50 -c get grub_target && cat grub_target
```
Se vedi `set default="hermes"` → il server funziona. Se no, fermati e sistema
questo prima di andare avanti (`systemctl status tftpd-hpa`, firewall del Pi).

Il file scritto dal bot avrà sempre questo identico formato: una riga,
`set default="<ruolo>"`, dove `<ruolo>` è uno degli `--id` creati da
`grub-stable-entries.sh`. Per questo la Fase A è un prerequisito.

---

## STEP 2 — GRUB sul rig legge il file all'avvio

Sul rig, bootato su DEVIN:

```bash
sudo nano /etc/grub.d/40_custom
```

**In fondo al file** (DOPO le 3 menuentry create da `grub-stable-entries.sh` —
non toccarle), aggiungi:

```
# --- Fase B: leggi il ruolo scelto dal Pi via TFTP ---
insmod efinet
insmod net
insmod tftp
if net_bootp; then
    source (tftp,192.168.1.50)/grub_target
fi
```

Come funziona: `net_bootp` chiede un IP via DHCP; `source` include il contenuto
del file come fosse parte di grub.cfg (cioè esegue il `set default="..."`).
Punto chiave: **se il file è vuoto o il Pi è irraggiungibile, `source` non dà
errore** — GRUB prosegue col default salvato, come se la Fase B non esistesse.
Il fallimento è sempre innocuo.

Poi:
```bash
sudo update-grub
```

**Verifica senza riavviare a vuoto**: lascia `set default="hermes"` nel file di
prova dello STEP 1, riavvia il rig da monitor e guarda il menu GRUB: la voce
evidenziata deve essere HERMES (non l'ultima usata). Se boota su hermes → funziona.

**Se resta sul default vecchio**: quasi sempre è `net_bootp` che fallisce
(DHCP non risponde in ambiente pre-OS — capita). Sostituisci il blocco con la
variante a IP statico:

```
insmod efinet
insmod net
insmod tftp
net_add_addr efinet0:link efinet0 192.168.1.100
source (tftp,192.168.1.50)/grub_target
```

(`efinet0` è il nome visto con `net_ls_cards` allo STEP 0 — se era diverso,
usa quello.) Di nuovo `sudo update-grub` e riprova.

---

## STEP 3 — Test end-to-end da spento

1. Svuota il file di prova: `echo -n | sudo tee /srv/tftp/grub_target` (sul Pi)
2. Spegni il rig: `sudo poweroff`
3. Sul Pi, simula quello che farà il bot:
   ```bash
   echo 'set default="teacher"' | sudo tee /srv/tftp/grub_target
   wakeonlan AA:BB:CC:DD:EE:FF     # il tuo WOL_MAC
   sleep 20
   echo -n | sudo tee /srv/tftp/grub_target
   ```
4. Aspetta il boot, poi: `ssh tillo@192.168.1.100 cat /etc/ai-rig/role`
   → deve dire `teacher`.

Se dice il ruolo giusto: la Fase B funziona. Passa allo STEP 4.
Se no: riattacca il monitor e guarda cosa fa GRUB durante il boot (di solito
si vede l'errore a schermo per un paio di secondi).

---

## STEP 4 — Attiva il bot

Sul Pi, in `/etc/ai-rig-bot/config.env`:
```
ENABLE_NETBOOT_SELECT="true"
```
poi:
```bash
sudo systemctl restart ai-rig-wol-bot
```

Da ora, a rig spento, `/devin /hermes /teacher` fanno un solo boot diretto.
A rig acceso il comportamento non cambia (usa sempre SSH + grub-reboot).

**Nota timing**: il bot aspetta 15 secondi dopo il WOL prima di svuotare il
file (il rig deve fare in tempo a leggerlo). Se il tuo BIOS è lento a
inizializzare la rete, alza il valore in `netboot_select()` dentro
`ai-rig-wol-bot.py` (`time.sleep(15)`) — abbondare non costa nulla.

---

## Tornare indietro (rollback completo in 2 minuti)

1. Sul Pi: `ENABLE_NETBOOT_SELECT="false"` + `sudo systemctl restart ai-rig-wol-bot`
2. Sul rig: rimuovi il blocco aggiunto da `/etc/grub.d/40_custom` + `sudo update-grub`
3. (Facoltativo) `sudo apt remove tftpd-hpa` sul Pi

Nessuna delle due parti dipende dall'altra per funzionare: anche a metà
rollback, il peggio che succede è che GRUB prova a leggere un file che non c'è
e prosegue normalmente.

## Troubleshooting rapido

| Sintomo | Causa probabile | Fix |
|---|---|---|
| `insmod efinet` → file not found | GRUB firmato senza moduli rete | Disabilita Secure Boot, o rinuncia alla Fase B |
| `net_ls_cards` non mostra nulla | Network Stack disattivo nel BIOS | Abilitalo (STEP 0.5) |
| Boota sempre l'ultimo ruolo usato | `net_bootp` fallisce silenziosamente | Variante IP statico (STEP 2) |
| Funziona a caldo ma non da spento | BIOS lento a inizializzare la NIC | Alza il sleep del bot (STEP 4) |
| Boota il ruolo di DUE comandi fa | Il bot svuota il file troppo presto | Idem: alza il sleep |
