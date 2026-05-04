compose := "podman-compose"
compose_file := "packtly-infra/podman-compose.yml"
container_engine := "podman"
packtly_repo_dir := "packtly-infra"
secrets_dir := justfile_directory() / ".dev-secrets"
volume_name := "packtly_data"

default: list

list:
    @just --list

[private]
_build-service service:
    #!/usr/bin/env bash
    set -eu
    extra=""
    if [ -n "${RELEASE_VERSION:-}" ]; then
        extra="--build-arg VERSION=${RELEASE_VERSION}"
    fi
    {{ compose }} --file "{{ compose_file }}" build $extra "{{ service }}"

[private]
_remove-service-image service:
    #!/usr/bin/env bash
    set -eu
    command -v yq >/dev/null 2>&1 || { echo "Error: 'yq' not found in PATH"; exit 1; }
    image="$(yq -r '.services["{{ service }}"].image // empty' "{{ compose_file }}")"

    if [ -z "$image" ]; then
        echo "No image defined for {{ service }}, skipping."
        exit 0
    fi

    if podman image exists "$image"; then
        echo "Removing image: $image"
        podman rmi "$image" || echo "Warning: Could not remove $image."
    else
        echo "Image $image does not exist, skipping."
    fi

all: setup-image secrets-create volume-create _service-up create-repos service-logs

clean: service-stop volume-rm setup-rmimage service-rmimage

clean-all: clean
    rm -rf "{{ secrets_dir }}"/*

setup-image:
    just _build-service packtly-setup

setup-rmimage:
    just _remove-service-image packtly-setup

secrets-create:
    #!/usr/bin/env bash
    set -euo pipefail

    SECRETS_DIR="{{ secrets_dir }}"
    CONTAINER_NAME="packtly-setup"
    GPG_USER="embtom"
    GPG_EMAIL="user@example.com"
    API_USER="admin"
    GPG_PASS="1234"
    API_PASS="1234"

    mkdir -p "${SECRETS_DIR}/ssh" "${SECRETS_DIR}/private" "${SECRETS_DIR}/public"
    chmod 0700 "${SECRETS_DIR}"

    gpg_key_missing=false
    ssh_key_missing=false
    api_creds_missing=false
    [[ ! -f "${SECRETS_DIR}/private/repo_signing_private.key" ]] && gpg_key_missing=true
    [[ ! -f "${SECRETS_DIR}/ssh/id_ed25519" ]] && ssh_key_missing=true
    [[ ! -f "${SECRETS_DIR}/public/.htpasswd" ]] && api_creds_missing=true

    if ! $gpg_key_missing && ! $ssh_key_missing && ! $api_creds_missing; then
        echo "All secrets already exist, nothing to do."
        exit 0
    fi

    {{ compose }} \
        --file "{{ compose_file }}" \
        run --detach \
        --volume "${SECRETS_DIR}:/opt/packtly" \
        --volume "${SECRETS_DIR}/private:/run/secrets" \
        --name "${CONTAINER_NAME}" \
        packtly-setup
    
    trap '{{ container_engine }} rm -f "${CONTAINER_NAME}" 2>/dev/null || true' EXIT

    if $ssh_key_missing; then
        {{ container_engine }} exec -t "${CONTAINER_NAME}" \
            bash -euo pipefail -c '
                test -f /opt/packtly/ssh/id_ed25519 \
                    || dropbearkey -C "noname" -q -t ed25519 -N "" \
                        -f /opt/packtly/ssh/id_ed25519
                test -f /opt/packtly/ssh/id_ed25519.openssh \
                    || dropbearconvert dropbear openssh \
                        /opt/packtly/ssh/id_ed25519 \
                        /opt/packtly/ssh/id_ed25519.openssh
            '
    fi

    if $gpg_key_missing; then
        {{ container_engine }} exec "${CONTAINER_NAME}" \
            gen_gpg \
            --name "${GPG_USER}" \
            --email "${GPG_EMAIL}" \
            --pass "${GPG_PASS}"
    fi

    if $api_creds_missing; then
        {{ container_engine }} exec "${CONTAINER_NAME}" \
            gen_htpasswd "${API_USER}" "${API_PASS}"
    fi

volume-create recreate="false":
    #!/usr/bin/env bash
    set -euo pipefail

    SECRETS_DIR="{{ secrets_dir }}"
    VOLUME="{{ volume_name }}"
    
    # Optionally reset existing resources
    if [ "{{ recreate }}" = "true" ]; then
        echo "==> Removing existing volume and secrets"
        podman volume rm "${VOLUME}" 2>/dev/null || true
        podman secret rm packtly_gpg_private_key 2>/dev/null || true
        podman secret rm packtly_gpg_passphrase 2>/dev/null || true
    fi

    # Ensure Podman volume exists
    podman volume exists "${VOLUME}" || podman volume create "${VOLUME}"
    MOUNTPOINT="$(podman volume inspect "${VOLUME}" | jq -r '.[0].Mountpoint')"

    # Create directory structure inside volume
    mkdir -p "${MOUNTPOINT}/public" "${MOUNTPOINT}/ssh"
    chmod 0755 "${MOUNTPOINT}/public" "${MOUNTPOINT}/ssh"

    # Copy public files into volume
    echo "==> Copying public files into volume"
    cp "${SECRETS_DIR}/public/repo_signing.key" "${MOUNTPOINT}/public/repo_signing.key"
    chmod 0644 "${MOUNTPOINT}/public/repo_signing.key"

    cp "${SECRETS_DIR}/ssh/id_ed25519.pub" "${MOUNTPOINT}/ssh/id_ed25519.pub"
    chmod 0644 "${MOUNTPOINT}/ssh/id_ed25519.pub"

    cp "${SECRETS_DIR}/public/.htpasswd" "${MOUNTPOINT}/public/.htpasswd"
    chmod 0644 "${MOUNTPOINT}/public/.htpasswd"

    # Create Podman secrets
    echo "==> Creating Podman secrets"
    podman secret rm packtly_gpg_private_key 2>/dev/null || true
    podman secret create packtly_gpg_private_key \
        "${SECRETS_DIR}/private/repo_signing_private.key"

    podman secret rm packtly_gpg_passphrase 2>/dev/null || true
    podman secret create packtly_gpg_passphrase \
        "${SECRETS_DIR}/private/repo_signing_private_pass"

    echo "==> Provision complete"

volume-rm:
    #!/usr/bin/env bash
    set -euo pipefail
    VOLUME="{{ volume_name }}"
    podman volume rm "${VOLUME}" 2>/dev/null || true
    podman secret rm packtly_gpg_private_key 2>/dev/null || true
    podman secret rm packtly_gpg_passphrase 2>/dev/null || true

create-repos:
    #!/usr/bin/env bash
    set -euo pipefail

    echo "==> Importing GPG key"
    {{ compose }} -f "{{ compose_file }}" exec packtly \
        /usr/local/bin/entrypoint_gpg

    echo "==> Creating repos"
    {{ compose }} -f "{{ compose_file }}" exec packtly \
        create_repo -d trixie-apollo -c main -m "Embtom trixie" -n trixie-apollo-main
    {{ compose }} -f "{{ compose_file }}" exec packtly \
        create_repo -d trixie-apollo -c contrib -m "Embtom trixie" -n trixie-apollo-contrib

    echo "==> Publishing repos"
    {{ compose }} -f "{{ compose_file }}" exec packtly \
        publish_repo -r trixie-apollo-main,trixie-apollo-contrib

    echo "==> Repos created and published"

[private]
_service-up:
    {{ compose }} --file "{{ compose_file }}" up -d packtly

service-start: _service-up service-logs

service-logs:
    {{ compose }} --file "{{ compose_file }}" logs -f packtly

service-stop:
    {{ compose }} --file "{{ compose_file }}" down packtly

service-rmimage:
    just _remove-service-image packtly