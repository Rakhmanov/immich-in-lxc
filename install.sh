#!/bin/bash

# -------------------
# Include helper functions
# Such as git git_checkout_repo
# -------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
source "$SCRIPT_DIR/helpers.sh"


# -------------------
# Check services are off
# -------------------

check_services_off() {
    local services=(
        "immich-web.service"
        "immich-ml.service"
    )

    for svc in "${services[@]}"; do
        # Does the unit exist?
        if systemctl list-unit-files --type=service | grep -q "^${svc}"; then
            # Unit exists — check if running
            if systemctl is-active --quiet "$svc"; then
                echo "Service $svc is RUNNING — expected OFF."
                echo "To stop services (as root):"
                echo "systemctl stop $svc"
                return 1
            else
                echo "Service $svc exists and is OFF."
            fi
        else
            # Unit not found — treat as safely off
            echo "Service $svc does not exist yet — treating as OFF."
        fi
    done

    return 0
}

# -------------------
# Check current user
# -------------------

check_user_id () {
    if [ "$EUID" -eq 0 ]; then
        echo "Error: This script should NOT be run as root."
        exit 1
    fi
}


# -------------------
# Create env file if it does not exists
# -------------------
create_install_env_file () {
    # Check if env file exists
    if [ ! -f $SCRIPT_DIR/.env ]; then
        echo "Error: .env file not found"
        echo "Create one by modifying an example file example.env"
        echo "cp example.env .env"
        exit 1
    fi
}


# -------------------
# Load environment variables from env file
# -------------------

load_environment_variables () {
    # Read the .env file into variables
    cd $SCRIPT_DIR
    set -a
    . ./.env
    set +a
}


# -------------------
# Common variables
# -------------------
set_common_variables () {
    set -a
    INSTALL_DIR_src=$INSTALL_DIR/source
    INSTALL_DIR_app=$INSTALL_DIR/app
    INSTALL_DIR_ml=$INSTALL_DIR_app/machine-learning
    INSTALL_DIR_geo=$INSTALL_DIR/geodata
    TMP_DIR=/tmp/$(whoami)/immich-in-lxc/
    REPO_URL="https://github.com/immich-app/immich"
    NODE_OPTIONS="--max-old-space-size=8192"
    # Shared with pre-install.sh so we don't clone base-images twice.
    # $HOME here is the run-user's home (install.sh runs as $RUN_USER).
    RUN_USER_BUILD_DIR="$HOME/build"
    BASE_IMG_REPO_DIR="$RUN_USER_BUILD_DIR/base-images"
    DB_PASSWORD_FILE="${DB_PASSWORD_FILE:-$HOME/.config/immich-in-lxc/db-password}"
    set +a
}


# -------------------
# Review environment variables
# -------------------

review_install_information () {
    echo ------------------Installation Configuration from .env------------------
    # Install Version
    echo Desired version: $REPO_TAG
    # Install Location
    echo Install Location: $INSTALL_DIR
    # Upload Location
    echo Upload Location: $UPLOAD_DIR
    # Cuda or CPU
    echo isCUDA: $isCUDA
    # npm proxy
    echo PROXY_NPM: $PROXY_NPM
    # npm dist proxy (used by node-gyp)
    echo PROXY_NPM_DIST: $PROXY_NPM_DIST
    # poetry proxy
    echo PROXY_POETRY: $PROXY_POETRY
    echo
}


# -------------------
# Check if node are installed
# -------------------

install_node () {
    # node.js
    if ! command -v node &> /dev/null; then
        echo "ERROR: Node.js is not installed."
        echo "Installing Node.js for current user"
        curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
        \. "$HOME/.nvm/nvm.sh"
        # use $PROXY_NPM_DIST 
        NVM_NODEJS_ORG_MIRROR=$PROXY_NPM_DIST
        nvm install --lts
        echo "Finish installing latest LTS node"
    fi

    if ! command -v corepack &> /dev/null; then
        echo "Installing Corepack"
        npm install -g corepack@latest
    fi
    corepack enable pnpm
    echo ------------------Current versions------------------
    echo "npm version: {$(npm -v)}"
    echo "node version: {$(node -v)}"
    echo "corepack version: {$(corepack -v)}"
    echo
}


# -------------------
# Check if dependency are met
# -------------------

review_dependency () {
    # ffmpeg
    if ! command -v ffmpeg &> /dev/null; then
        echo "ERROR: ffmpeg is not installed."
        echo "Please run pre-install.sh first"
        exit 1
    fi

    # node.js
    if ! command -v node &> /dev/null; then
        echo "ERROR: Node.js is not installed."
        exit 1
    fi

    # python3
    if ! command -v python3 &> /dev/null; then
        echo "ERROR: Python is not installed."
        exit 1
    fi

    # git
    if ! command -v git &> /dev/null; then
        echo "ERROR: Git is not installed."
        exit 1
    fi

    # (Optional) Nvidia Driver
    if [ $isCUDA = true ]; then
        if ! nvidia-smi &> /dev/null; then
            echo "ERROR: Nvidia driver is not installed, and isCUDA is set to true"
            exit 1
        fi
    fi

    echo "Dependency check passed!"
}



# -------------------
# Clean previous build
# -------------------

clean_previous_build () {
    confirm_destruction "$INSTALL_DIR_app"
    rm -rf $INSTALL_DIR_app
}


# -------------------
# Common variables
# -------------------

create_folders () {
    # No need to create source folder
    mkdir -p $INSTALL_DIR_app

    # Upload directory
    if [ ! -d "$UPLOAD_DIR" ]; then
        echo "$UPLOAD_DIR does not exists, creating one"
        mkdir -p $UPLOAD_DIR
    else
        echo "$UPLOAD_DIR already exists, skip creation"
    fi

    # GeoNames
    mkdir -p $INSTALL_DIR_geo

    # Create a temporary folder for the json files
    mkdir -p $TMP_DIR
}

# -------------------
# Apply version specific git patches
# -------------------

git_patch () {
    if [ -d "$SCRIPT_DIR/git-patches/$REPO_TAG" ]; then
        (
            cd $INSTALL_DIR_src
            git apply $SCRIPT_DIR/git-patches/$REPO_TAG/*.patch
        )
    fi
}

# -------------------
# Remove mise tools that we do not need for server install
# -------------------
mise_local_override() {
    cd $INSTALL_DIR_src

    cat > mise.local.toml <<'EOF'
[settings]
disable_tools = [
  "flutter",
  "java",
  "node",
  "pnpm",
  "opentofu",
  "terragrunt",
  "github:jellyfin/jellyfin-ffmpeg"
]
EOF

}

# -------------------
# Install immich-web-server
# -------------------

install_immich_web_server_pnpm () {
    cd $INSTALL_DIR_src

    # Set mirror for pnpm (if needed)
    if [ ! -z "${PROXY_NPM}" ]; then
        corepack pnpm config set registry=$PROXY_NPM
    fi

    # Install dependencies
    corepack pnpm install --frozen-lockfile
    echo "pnpm version selected from package.json: $(corepack pnpm -v)"

    # Immich v3 added @immich/plugin-sdk as a server build dependency.
    if [ -f "packages/plugin-sdk/package.json" ]; then
        SHARP_IGNORE_GLOBAL_LIBVIPS=true corepack pnpm \
            --filter @immich/sdk --filter @immich/plugin-sdk --filter immich build
    else
        corepack pnpm --filter immich build
    fi

    # Build SDK
    corepack pnpm --filter @immich/sdk --filter immich-web build

    # Build and deploy the server component.
    corepack pnpm --filter immich --prod deploy "$INSTALL_DIR_app"
    # sharp was compiled against the global libvips during the frozen workspace
    # install. Do not mutate the deployed v3 lockfile: its injected workspace
    # dependency snapshots are not valid standalone `pnpm add` resolver input.

    # Build and deploy the CLI.
    corepack pnpm --filter @immich/sdk --filter @immich/cli build
    corepack pnpm --filter @immich/cli --prod --no-optional deploy $INSTALL_DIR_app/cli

    ln -s ../cli/bin/immich $INSTALL_DIR_app/bin/immich

    # Copy the built Web UI to the target directory.
    cp -a web/build $INSTALL_DIR_app/www

    cp -a LICENSE $INSTALL_DIR_app/
    cp -a i18n $INSTALL_DIR/
    cp -a server/bin/get-cpus.sh server/bin/start.sh $INSTALL_DIR_app/

    # Build the bundled plugin. Immich v3 moved it into packages/plugin-core
    # and changed the runtime path to /build/plugins/immich-plugin-core.
    npm install -g @jdxcode/mise

    if [ -d "packages/plugin-core" ]; then
        mise trust --all --yes
        mise //:plugins

        mkdir -p "$INSTALL_DIR_app/plugins/immich-plugin-core/dist"
        cp -a ./packages/plugin-core/dist/. "$INSTALL_DIR_app/plugins/immich-plugin-core/dist/"
        cp -a ./packages/plugin-core/manifest.json "$INSTALL_DIR_app/plugins/immich-plugin-core/manifest.json"
    elif [ -d "plugins" ]; then
        (
            cd plugins
            corepack pnpm install
            mise trust --all --yes
            mise build
        )

        # Copy results to app folder.
        mkdir -p "$INSTALL_DIR_app/corePlugin/dist"
        cp -a ./plugins/dist/. "$INSTALL_DIR_app/corePlugin/dist/"
        cp -a ./plugins/manifest.json "$INSTALL_DIR_app/corePlugin/manifest.json"
    else
        echo "Bundled plugin source not found — skipping plugin build."
    fi

    # Unset mirror for pnpm (if it was set)
    if [ ! -z "${PROXY_NPM}" ]; then
        corepack pnpm config delete registry
    fi
}


# -------------------
# Generate build-lock
# -------------------

generate_build_lock () {
    # Resolve Nest's Warning "Failed to read /home/immich/app/build-lock.json"
    cd $SCRIPT_DIR

    REPO_URL_BASE_IMG="https://github.com/immich-app/base-images"

    tag=$(grep -oP '(?<=immich-app/base-server-dev:)[0-9]+' $INSTALL_DIR_src/server/Dockerfile)

    # Reuse the tree pre-install.sh populated under $HOME/build/base-images.
    # safe_git_checkout is idempotent — if the directory is missing (e.g.
    # install.sh is being run without pre-install.sh), it will clone fresh.
    mkdir -p "$(dirname "$BASE_IMG_REPO_DIR")"

    if [ -d "$BASE_IMG_REPO_DIR/.git" ]; then
        echo "Updating existing base-images repo at $BASE_IMG_REPO_DIR..."
        git -C "$BASE_IMG_REPO_DIR" fetch --tags
        git -C "$BASE_IMG_REPO_DIR" checkout "$tag" || git -C "$BASE_IMG_REPO_DIR" fetch origin "refs/tags/$tag:refs/tags/$tag" && git -C "$BASE_IMG_REPO_DIR" checkout "$tag"
    else
        echo "Cloning fresh base-images repo at tag $tag into $BASE_IMG_REPO_DIR..."
        safe_git_checkout "$REPO_URL_BASE_IMG" "$BASE_IMG_REPO_DIR" "$tag"
    fi

    cd "$BASE_IMG_REPO_DIR/server/"

    # From base-images/server/Dockerfile line 110
    jq -s '.' packages/*.json > $TMP_DIR/packages.json
    jq -s '.' sources/*.json > $TMP_DIR/sources.json
    jq -n \
        --slurpfile sources $TMP_DIR/sources.json \
        --slurpfile packages $TMP_DIR/packages.json \
        '{sources: $sources[0], packages: $packages[0]}' \
        > $INSTALL_DIR_app/build-lock.json
}


# -------------------
# Install Immich-machine-learning
# -------------------

install_immich_machine_learning () {
    cd $INSTALL_DIR_src/machine-learning

    # Install uv for the current user if not already present
    if ! command -v uv &> /dev/null; then
        echo "Installing uv..."
        curl -LsSf https://astral.sh/uv/install.sh | sh
        . "$HOME/.local/bin/env" 2>/dev/null || export PATH="$HOME/.local/bin:$PATH"
    fi

    # Create the venv that the runtime start.sh expects to activate
    python3 -m venv $INSTALL_DIR_ml/venv

    (
    # Point uv at the existing venv instead of creating a project-local .venv
    export VIRTUAL_ENV=$INSTALL_DIR_ml/venv

    # Honour PROXY_POETRY as the package index (name kept for .env back-compat)
    if [ ! -z "${PROXY_POETRY}" ]; then
        export UV_INDEX_URL=$PROXY_POETRY
    fi

    # Pick the extra matching the target accelerator
    case "$isCUDA" in
        true)     extra=cuda ;;
        openvino) extra=openvino ;;
        rocm)     extra=cpu ;;  # rocm onnxruntime comes from AMD's repo below
        *)        extra=cpu ;;
    esac

    uv sync --frozen --extra "$extra" --no-dev --no-editable --no-install-project --compile-bytecode --active

    if [ "$isCUDA" = "rocm" ]; then
        # https://rocm.docs.amd.com/projects/radeon/en/latest/docs/install/native_linux/install-onnx.html
        uv pip install onnxruntime-rocm --find-links https://repo.radeon.com/rocm/manylinux/rocm-rel-6.4.4/
        # ROCm needs numpy < 2
        uv pip install "numpy<2.3.4"
        "$VIRTUAL_ENV/bin/python3" -c "import onnxruntime as ort; print(ort.get_available_providers())"
    fi
    )

    # Copy results
    cd $INSTALL_DIR_src
    cp -a machine-learning/ann machine-learning/immich_ml $INSTALL_DIR_ml/
}


# -------------------
# Replace /usr/src
# -------------------

# Honestly, I do not understand what does this part of the script does.

replace_usr_src () {
    cd $INSTALL_DIR_app
    grep -Rl /usr/src | xargs -n1 sed -i -e "s@/usr/src@$INSTALL_DIR@g"
    ln -sf $INSTALL_DIR_app/resources $INSTALL_DIR/
    mkdir -p $INSTALL_DIR/cache

    sed -i -e "s@\"/cache\"@\"$INSTALL_DIR/cache\"@g" $INSTALL_DIR_ml/immich_ml/config.py

    grep -RlE "\"/build\"|'/build'" | xargs -n1 sed -i -e "s@\"/build\"@\"$INSTALL_DIR_app\"@g" -e "s@'/build'@'$INSTALL_DIR_app'@g"
}


# -------------------
# Setup upload directory
# -------------------

setup_upload_folder () {
    ln -s $UPLOAD_DIR $INSTALL_DIR_app/upload
    ln -s $UPLOAD_DIR $INSTALL_DIR_ml/upload
}


# -------------------
# Download GeoNames
# -------------------

download_geonames () {
    cd $INSTALL_DIR_geo
    if [ ! -f "cities500.zip" ] || [ ! -f "admin1CodesASCII.txt" ] || [ ! -f "admin2Codes.txt" ] || [ ! -f "ne_10m_admin_0_countries.geojson" ]; then
        echo "incomplete geodata, start downloading"
        wget -o - https://download.geonames.org/export/dump/admin1CodesASCII.txt &
        wget -o - https://download.geonames.org/export/dump/admin2Codes.txt &
        wget -o - https://download.geonames.org/export/dump/cities500.zip &
        wget -o - https://raw.githubusercontent.com/nvkelso/natural-earth-vector/v5.1.2/geojson/ne_10m_admin_0_countries.geojson &
        wait
        unzip cities500.zip
        date --iso-8601=seconds | tr -d "\n" > geodata-date.txt
    else
        echo "geodata exists, skip downloading"
    fi

    cd $INSTALL_DIR
    # Link the folder
    ln -s $INSTALL_DIR_geo $INSTALL_DIR_app/
}


# -------------------
# Create custom start.sh script
# -------------------

create_custom_start_script () {
    # Immich web and microservices
    cat <<EOF > $INSTALL_DIR_app/start.sh
#!/bin/bash

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

set -a
. $INSTALL_DIR/runtime.env
set +a

cd $INSTALL_DIR_app
exec node $INSTALL_DIR_app/dist/main "\$@"
EOF

    # Machine learning
    cat <<EOF > $INSTALL_DIR_ml/start.sh
#!/bin/bash

set -a
. $INSTALL_DIR/runtime.env
set +a

cd $INSTALL_DIR_ml
. venv/bin/activate

: "\${MACHINE_LEARNING_HOST:=127.0.0.1}"
: "\${MACHINE_LEARNING_PORT:=3003}"
: "\${MACHINE_LEARNING_WORKERS:=1}"
: "\${MACHINE_LEARNING_WORKER_TIMEOUT:=120}"

exec gunicorn immich_ml.main:app \
        -k immich_ml.config.CustomUvicornWorker \
        -w "\$MACHINE_LEARNING_WORKERS" \
        -b "\$MACHINE_LEARNING_HOST":"\$MACHINE_LEARNING_PORT" \
        -t "\$MACHINE_LEARNING_WORKER_TIMEOUT" \
        --log-config-json log_conf.json \
        --graceful-timeout 0
EOF

    chmod 775 $INSTALL_DIR_ml/start.sh
}


# -------------------
# Create runtime environment file
# -------------------

create_runtime_env_file () {
    local escaped_password runtime_env_link

    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    if [ ! -s "$DB_PASSWORD_FILE" ]; then
        echo "Database password file not found: $DB_PASSWORD_FILE" >&2
        echo "Run pre-install.sh first or set DB_PASSWORD_FILE in .env." >&2
        exit 1
    fi

    # Check if env file exists
    if [ ! -f runtime.env ]; then
        # If not, create a new one based on the template
        if [ -f $SCRIPT_DIR/runtime.env ]; then
            cp "$SCRIPT_DIR/runtime.env" runtime.env
            sed -i "s|^MACHINE_LEARNING_CACHE_FOLDER=.*|MACHINE_LEARNING_CACHE_FOLDER=$INSTALL_DIR/ml-models|" runtime.env
            echo "New secure runtime.env file created from the template"
        else
            echo "runtime.env not found, please clone the entire repo, exiting"
            exit 1
        fi
    fi

    # Keep an existing runtime file synchronized if pre-install rotated the
    # database password, while preserving every other user-managed setting.
    IFS= read -r DB_PASSWORD < "$DB_PASSWORD_FILE"
    escaped_password="$(shell_env_escape "$DB_PASSWORD")"
    replace_key_value_line runtime.env DB_PASSWORD "$escaped_password"
    chmod 0600 runtime.env

    # Give systemd a stable EnvironmentFile path even when INSTALL_DIR is a
    # custom mount. The link and its parent stay private to the service user.
    runtime_env_link="$HOME/.config/immich-in-lxc/runtime.env"
    mkdir -p "$(dirname "$runtime_env_link")"
    chmod 0700 "$(dirname "$runtime_env_link")"
    ln -sfn "$INSTALL_DIR/runtime.env" "$runtime_env_link"
}


# -------------------
# Helper function that checks user consent
# -------------------

confirm_destruction() {
    local target="${1:-}"

    if [[ -z "$target" ]]; then
        echo "Error: no target path provided to confirm_destruction()" >&2
        exit 1
    fi

    echo "⚠️  WARNING: This operation would permanently DELETE everything under:"
    echo "    $target"
    echo
    read -rp "Are you sure you want to continue? Type 'Y' to proceed: " confirm

    if [[ "$confirm" != "Y" ]]; then
        echo "Aborted. Nothing will be deleted."
        exit 1
    fi
    return 0
}

main() {
    set -euo pipefail
    # set -x # Print each command (Debugging)

    check_user_id
    check_services_off
    create_install_env_file
    load_environment_variables
    set_common_variables
    review_install_information
    create_runtime_env_file

    install_node
    review_dependency
    clean_previous_build
    create_folders
    safe_git_checkout "$REPO_URL" "$INSTALL_DIR_src" "$REPO_TAG"
    mise_local_override
    git_patch
    install_immich_web_server_pnpm
    generate_build_lock
    install_immich_machine_learning
    replace_usr_src
    setup_upload_folder
    download_geonames
    create_custom_start_script

    echo "----------------------------------------------------------------"
    echo "Installation/Upgrade Completed"
    echo "----------------------------------------------------------------"
    echo "If this was a first installation, review $INSTALL_DIR/runtime.env if needed."
    echo "Then start the services (as root):"
    echo "systemctl daemon-reload"
    echo "systemctl start immich-ml immich-web"
    echo "systemctl enable immich-ml immich-web"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
