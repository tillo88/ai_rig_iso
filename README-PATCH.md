# AI Rig — Flow Fix Pack

Pacchetto correttivo per il flusso dedicato **DEVIN → HERMES → TEACHER**.

Correzioni principali:

- nessun wipe prima della validazione di Subiquity/Curtin;
- selezione disco univoca e fallback `smartctl` corretto;
- marker `populate-cache-done` creato solo dopo una copia riuscita;
- copie grandi riprendibili con `rsync --partial`;
- BootNext verificato prima del riavvio;
- finalizzazione globale eseguita esclusivamente su DEVIN;
- DEVIN impostato come primo boot UEFI e default GRUB;
- kernel e initrd scelti come coppia della stessa versione;
- entry GRUB verificate prima di dichiarare la catena completa;
- smoke test di `llama-server` prima del marker CUDA/llama;
- controlli Bash/YAML e verifica BIOS/UEFI della ISO durante il build.

## Applicazione

Dalla cartella estratta:

```bash
bash APPLICA-PATCH.sh /percorso/ai-rig-iso-build
```

Lo script crea un backup, sovrascrive i file corretti, rigenera `nocloud/`,
`rig-common/` e `rig-roles/`, quindi controlla sintassi Bash e YAML.
