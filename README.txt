FIX BUILD_ID v2
===============

Corregge build-iso.sh affinche', dopo una build riuscita, aggiorni automaticamente
solo cache/BUILD_ID sul disco con etichetta ai-rig-cache, senza ricopiare la cache
pesante quando non viene usato --cache-disk.

Applicazione:
  bash build-iso-build-id-fix-v2/APPLICA-FIX.sh ~/ai-rig-iso-build

Il programma crea automaticamente un backup timestampato del build-iso.sh attuale.
