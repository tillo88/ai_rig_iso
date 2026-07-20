\
    #!/usr/bin/env bash
    # Imposta DEVIN/HERMES/TEACHER a 32768 token nella sorgente del progetto,
    # rigenera gli script derivati e valida la sintassi.
    set -Eeuo pipefail

    ROOT="${1:-$PWD}"
    cd "$ROOT"

    [ -d config/roles ] || {
        echo "ERRORE: esegui questo script dalla root di ai-rig-iso-build" >&2
        echo "oppure passa la root come argomento." >&2
        exit 1
    }
    [ -f scripts/05-generate-nocloud.sh ] || {
        echo "ERRORE: manca scripts/05-generate-nocloud.sh" >&2
        exit 1
    }

    stamp="$(date +%Y%m%d-%H%M%S)"

    set_ctx() {
        local role="$1"
        local file="config/roles/${role}.env"

        [ -f "$file" ] || {
            echo "ERRORE: manca $file" >&2
            exit 1
        }

        grep -q '^ROLE_CTX_SIZE=' "$file" || {
            echo "ERRORE: ROLE_CTX_SIZE assente in $file" >&2
            exit 1
        }

        cp -a "$file" "${file}.bak.${stamp}"
        sed -i 's/^ROLE_CTX_SIZE=.*/ROLE_CTX_SIZE=32768/' "$file"

        echo "$role: $(grep '^ROLE_CTX_SIZE=' "$file")"
    }

    set_ctx devin
    set_ctx hermes
    set_ctx teacher

    echo
    echo "Rigenero nocloud/ e rig-roles/ dalla sorgente config/roles/..."
    bash scripts/05-generate-nocloud.sh

    echo
    echo "Valido gli script generati..."
    while IFS= read -r -d '' file; do
        bash -n "$file"
    done < <(
        find rig-roles -type f \
          \( -name 'role-provision.sh' -o -name 'start-llama-*.sh' \) \
          -print0
    )

    echo
    echo "Contesti generati:"
    grep -Rsn '^ROLE_CTX_SIZE=' \
        config/roles \
        rig-roles/devin/scripts/role-provision.sh \
        rig-roles/hermes/scripts/role-provision.sh \
        rig-roles/teacher/scripts/role-provision.sh

    echo
    echo "OK: tutti i ruoli impostati a 32768 e script validati."
