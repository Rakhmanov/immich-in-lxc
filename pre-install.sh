#!/bin/bash

# -------------------
# Include helper functions
# Such as git safe_git_checkout, choose_user
# -------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
source "$SCRIPT_DIR/helpers.sh"


# -------------------
# Must run as root
# -------------------
check_root () {
    if [ "$EUID" -ne 0 ]; then
        echo "Error: pre-install.sh must be run as root."
        echo "Try: sudo ./pre-install.sh"
        exit 1
    fi
}


# -------------------
# Fail before modifying an unsupported host
# -------------------
check_supported_os () {
    if [[ ! -f /etc/os-release ]]; then
        echo "Error: /etc/os-release not found." >&2
        exit 1
    fi

    . /etc/os-release
    case "${ID:-}:${VERSION_ID:-}" in
        ubuntu:24.04 | debian:13*) ;;
        debian:12*)
            echo "Debian 12 is not supported because its dependencies require unsafe cross-release package mixing (issue #10)." >&2
            echo "Upgrade using Debian's release procedure or create a fresh Debian 13 guest." >&2
            exit 1
            ;;
        *)
            echo "Unsupported operating system: ${PRETTY_NAME:-${ID:-unknown} ${VERSION_ID:-}}" >&2
            echo "Supported systems are Ubuntu 24.04 and Debian 13." >&2
            exit 1
            ;;
    esac
}


# -------------------
# Common variables
# -------------------
set_common_variables () {
    set -a
    REPO_URL="https://github.com/immich-app/base-images"
    APP_REPO_URL="https://github.com/immich-app/immich"
    THIS_REPO_URL="${THIS_REPO_URL:-https://github.com/Rakhmanov/immich-in-lxc.git}"

    # The Linux account that will own and run the Immich services. Build trees
    # live under that user's actual passwd home so pre-install.sh
    # can drop privileges for git ops without having to traverse a
    # root-owned working directory.
    #
    # Resolution order:
    #   1. $RUN_USER  — explicit override,
    #   2. $USER      — convenience, so someone running `sudo -E USER=foo ./pre-install.sh`
    #                   or an already-logged-in non-root user gets picked up; ignored
    #                   if it resolves to root/empty because that would be nonsensical,
    #   3. "immich"   — default.
    if [ -z "${RUN_USER:-}" ]; then
        if [ -n "${USER:-}" ] && [ "$USER" != "root" ]; then
            RUN_USER="$USER"
        else
            RUN_USER="immich"
        fi
    fi
    if id "$RUN_USER" >/dev/null 2>&1; then
        RUN_USER_HOME=$(getent passwd "$RUN_USER" | cut -d: -f6)
    else
        RUN_USER_HOME="/home/$RUN_USER"
    fi
    if [ -z "$RUN_USER_HOME" ]; then
        echo "Could not determine a home directory for '$RUN_USER'." >&2
        exit 1
    fi
    RUN_USER_REPO_DIR="$RUN_USER_HOME/immich-in-lxc"
    RUN_USER_BUILD_DIR="$RUN_USER_HOME/build"
    BASE_IMG_REPO_DIR="$RUN_USER_BUILD_DIR/base-images"
    SOURCE_DIR="$RUN_USER_BUILD_DIR/image-source"
    DB_PASSWORD_FILE="$RUN_USER_HOME/.config/immich-in-lxc/db-password"

    LD_LIBRARY_PATH=/usr/local/lib # :$LD_LIBRARY_PATH
    LD_RUN_PATH=/usr/local/lib # :c$LD_RUN_PATH
    MIMALLOC_REPO_URL="https://github.com/microsoft/mimalloc.git"
    MIMALLOC_TAG="${MIMALLOC_TAG:-v3.3.0}"
    VCHORD_VERSION="${VCHORD_VERSION:-0.5.3}"
    set +a
}


# -------------------
# Create immich user with password
# -------------------
# Idempotent:
#   - skips creation if user already exists,
#   - skips the password prompt if a usable password is already set, unless
#     $USER_PASSWORD is provided (which always wins and rewrites it),
#     or $FORCE_USER_PASSWORD=1 is set to force a re-prompt.
# `passwd -S <user>` reports the second field as the account state:
#   P  = password set,  L = locked,  NP = no password.
create_immich_user () {
    if id "$RUN_USER" &>/dev/null; then
        echo "User '$RUN_USER' already exists. Skipping creation."
    else
        echo "Creating user '$RUN_USER' with home $RUN_USER_HOME..."
        adduser --shell /bin/bash --disabled-password --gecos "Immich Mich" "$RUN_USER"
    fi

    # Suppress xtrace so passwords never end up in the trace output.
    { set +x; } 2>/dev/null

    local pw_state
    pw_state=$(passwd -S "$RUN_USER" 2>/dev/null | awk '{print $2}')

    if [ -n "${USER_PASSWORD:-}" ]; then
        # Explicit override always wins.
        echo "$RUN_USER:$USER_PASSWORD" | chpasswd
        echo "Password for '$RUN_USER' set from \$USER_PASSWORD."
    elif [ "$pw_state" = "P" ] && [ "${FORCE_USER_PASSWORD:-0}" != "1" ]; then
        echo "Password for '$RUN_USER' already set — keeping existing one."
        echo "    (Set FORCE_USER_PASSWORD=1 or USER_PASSWORD=... to change it.)"
    else
        echo "Set a password for the '$RUN_USER' Linux user (used for su / ssh login):"
        # passwd reads twice and exits non-zero on mismatch; let set -e catch it
        passwd "$RUN_USER"
    fi
    set -x

    # Groups needed for GPU passthrough. Minimal containers may not have
    # render yet because the graphics packages are installed later.
    getent group video >/dev/null || groupadd --system video
    getent group render >/dev/null || groupadd --system render
    usermod -aG video,render "$RUN_USER"
    RUN_GROUP=$(id -gn "$RUN_USER")
    export RUN_GROUP
}


# -------------------
# Prepare the build directory under $RUN_USER_HOME and arrange for
# subsequent safe_git_checkout calls to drop privileges to $RUN_USER.
# Call AFTER create_immich_user, BEFORE the first safe_git_checkout.
# -------------------
prepare_build_dir () {
    install -d -o "$RUN_USER" -g "$RUN_GROUP" -m 0755 "$RUN_USER_BUILD_DIR"

    # RUN_USER is already set; re-export it so choose_user picks it up when
    # helpers.sh was sourced in a sub-shell that didn't see `set -a`.
    export RUN_USER
}


# -------------------
# Dependencies required before the first HTTPS git checkout
# -------------------
install_bootstrap_dependencies () {
    apt-get update
    apt-get install --no-install-recommends -y adduser ca-certificates git passwd
}


# -------------------
# Remove build folder function
# -------------------

function remove_build_folder () {
    cd $1
    if [ -d "build" ]; then
        rm -r build
    fi
}

# -------------------
# Install runtime component
# -------------------

install_runtime_component () {
    cd $SCRIPT_DIR

    # Redis
    apt install --no-install-recommends -y\
        redis
}


# -------------------
# Install build dependency
# -------------------

install_build_dependency () {
    cd $SCRIPT_DIR
    # Source the os-release file to get access to its variables
    if [ -f /etc/os-release ]; then
        # $ID comes from here
        . /etc/os-release
    else
        echo "Error: /etc/os-release not found."
        exit 1
    fi

    apt-get update

    # Base utilities
    apt-get install --no-install-recommends -y \
        curl git python3-venv python3-dev unzip \
        wget jq cpanminus

    ## Install common build components
    apt-get install --no-install-recommends -y \
        autoconf \
        automake \
        build-essential \
        g++ \
        cmake \
        meson \
        ninja-build \
        pkg-config \
        libtool \
        libltdl-dev \
        zlib1g-dev \
        libbrotli-dev \
        libde265-dev \
        libexif-dev \
        libexpat1-dev \
        libglib2.0-dev \
        libgsf-1-dev \
        libspng-dev \
        librsvg2-dev

    # Install for imagick & sharp
    apt-get install --no-install-recommends -y \
        libaom-dev \
        libx265-dev \
        libgif-dev \
        libpango1.0-dev \
        libjpeg-dev \
        libpng-dev \
        libtiff-dev \
        liblcms2-dev \
        libxml2-dev \
        libfftw3-dev \
        libopenexr-dev \
        libzip-dev \
        libssl-dev \
        libimagequant-dev

    # Added later – required for vips pkg-config resolution
    apt-get install --no-install-recommends -y \
        libcfitsio-dev \
        libcairo2-dev \
        libfontconfig1-dev \
        libmatio-dev \
        libopenjp2-7-dev \
        libcgif-dev \
        libpoppler-glib8 \
        libopenslide0

    ldconfig

    # Check the ID and execute the corresponding script
    case "$ID" in
        ubuntu)
            echo "Detected Ubuntu. Running Ubuntu-specific script..."
            ./dep-ubuntu.sh
            JPEGLI_LIBJPEG_LIBRARY_SOVERSION="8"
            JPEGLI_LIBJPEG_LIBRARY_VERSION="8.2.2"
            ;;
        debian)
            echo "Detected Debian. Running Debian-specific script..."
            ./dep-debian.sh
            JPEGLI_LIBJPEG_LIBRARY_SOVERSION="62"
            JPEGLI_LIBJPEG_LIBRARY_VERSION="62.3.0"
            ;;
        fedora)
            echo "Detected Fedora. Not supported, please open issue."
            exit 1
            ;;
        centos)
            echo "Detected CentOS. Not supported, please open issue."
            exit 1
            ;;
        rhel)
            echo "Detected RHEL. Not supported, please open issue."
            exit 1
            ;;
        arch)
            echo "Detected Arch Linux. Not supported, please open issue."
            neofetch # Top priority
            exit 1
            ;;
        *)
            echo "Unsupported OS ID: $ID"
            exit 1
            ;;
    esac
}


# -------------------
# Install ffmpeg automatically
# -------------------

install_ffmpeg () {
    # Don't install ffmpeg over and over again
    if ! command -v ffmpeg &> /dev/null; then
        export SKIP_CONFIRM=true
        curl https://repo.jellyfin.org/install-debuntu.sh | sed '/apt install --yes jellyfin/,$d' | bash
        unset $SKIP_CONFIRM
        # Installation
        apt install -y jellyfin-ffmpeg7
        # Link to common location
        ln -s /usr/lib/jellyfin-ffmpeg/ffmpeg  /usr/bin/ffmpeg
        ln -s /usr/lib/jellyfin-ffmpeg/ffprobe  /usr/bin/ffprobe
    else
        echo "Skipping ffmpeg installation, because it is already installed"
    fi

}


# -------------------
# Install PostgreSQL with VectorCord
# -------------------

install_postgresql () {
    # PostgreSQL
    # [official guide](https://www.postgresql.org/download/linux/ubuntu/)
    apt install -y postgresql-common
    /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y
    apt install -y postgresql-17 postgresql-17-pgvector

    # VectorCord
    # [*VectorChord Installation Documentation*](https://docs.vectorchord.ai/vectorchord/getting-started/installation.html#debian-packages)
    PG_VC_FILE_NAME=postgresql-17-vchord_${VCHORD_VERSION}-1_$(dpkg --print-architecture).deb
    if [ ! -f "$PG_VC_FILE_NAME" ]; then
        wget -P /root/ https://github.com/tensorchord/VectorChord/releases/download/${VCHORD_VERSION}/$PG_VC_FILE_NAME
    fi
    apt install -y /root/$PG_VC_FILE_NAME

    # On hosts without systemd (WSL2, some containers), the postgresql-17
    # package's post-install does not start the cluster. Make sure it is up
    # before we try to talk to it.
    service_start postgresql.service
    sleep 2

    # Config PostgreSQL to use VectorCord
    runuser -u postgres -- psql -c 'ALTER SYSTEM SET shared_preload_libraries = "vchord"'
    service_restart postgresql.service
    # Wait for restart
    sleep 5
    runuser -u postgres -- psql -c 'CREATE EXTENSION IF NOT EXISTS vchord CASCADE'
}


# -------------------
# Create immich DB role + database
# -------------------
# Idempotent:
#   - uses DO blocks / IF NOT EXISTS for the role and database objects,
#   - skips the password prompt (and the ALTER ROLE) if the 'immich' role
#     already exists, unless $DB_PASSWORD is provided (which always
#     wins), or $FORCE_DB_PASSWORD=1 is set to force a re-prompt.
setup_immich_database () {
    # Suppress xtrace so the DB password never lands in trace output.
    { set +x; } 2>/dev/null

    local role_exists="f"
    if runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='immich'" 2>/dev/null | grep -q 1; then
        role_exists="t"
    fi

    local set_password="t"
    if [ -n "${DB_PASSWORD:-}" ]; then
        :   # explicit override always wins — fall through and set it
    elif [ "$role_exists" = "t" ] && [ -s "$DB_PASSWORD_FILE" ] && [ "${FORCE_DB_PASSWORD:-0}" != "1" ]; then
        echo "Role 'immich' already exists — keeping existing DB password."
        echo "    (Set FORCE_DB_PASSWORD=1 or DB_PASSWORD=... to change it.)"
        set_password="f"
    else
        echo "Set a password for the PostgreSQL 'immich' role (used by the app to connect):"
        local p1 p2
        while :; do
            read -rs -p "DB password: " p1; echo
            read -rs -p "Confirm    : " p2; echo
            [ "$p1" = "$p2" ] && [ -n "$p1" ] && { DB_PASSWORD="$p1"; break; }
            echo "Passwords empty or do not match, try again."
        done
        export DB_PASSWORD
    fi

    # `install -d` applies ownership only to its final path. Create the parent
    # explicitly (also repairing older installs) so run-user tools can create
    # sibling config directories, for example uv's fish integration.
    install -d -o "$RUN_USER" -g "$RUN_GROUP" -m 0700 "$RUN_USER_HOME/.config"

    if [ "$set_password" = "t" ]; then
        # Validate before changing PostgreSQL or writing the credential file.
        shell_env_escape "$DB_PASSWORD" >/dev/null

        # Escape single quotes for the SQL literal.
        local esc_pw="${DB_PASSWORD//\'/\'\'}"
        runuser -u postgres -- psql -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'immich') THEN
        CREATE ROLE immich WITH LOGIN SUPERUSER PASSWORD '${esc_pw}';
    ELSE
        ALTER ROLE immich WITH LOGIN SUPERUSER PASSWORD '${esc_pw}';
    END IF;
END
\$\$;
SQL

        local old_umask
        install -d -o "$RUN_USER" -g "$RUN_GROUP" -m 0700 "$(dirname "$DB_PASSWORD_FILE")"
        old_umask=$(umask)
        umask 077
        printf '%s\n' "$DB_PASSWORD" > "$DB_PASSWORD_FILE"
        umask "$old_umask"
        chown "$RUN_USER:$RUN_GROUP" "$DB_PASSWORD_FILE"
        chmod 0600 "$DB_PASSWORD_FILE"
    fi

    if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_database WHERE datname='immich'" | grep -q 1; then
        runuser -u postgres -- psql -v ON_ERROR_STOP=1 -c "CREATE DATABASE immich OWNER immich"
    fi
    runuser -u postgres -- psql -v ON_ERROR_STOP=1 -c "GRANT ALL PRIVILEGES ON DATABASE immich TO immich"
    set -x
}


# -------------------
# Clone this repo into immich's home and seed .env
# -------------------
# After pre-install.sh finishes, the user logs in as 'immich' and runs
# install.sh from $RUN_USER_REPO_DIR. We clone a fresh copy there owned by
# immich so that user does not need to deal with permissions.
setup_immich_repo () {
    # Clone (or update) the repo into immich's home as the immich user so the
    # working tree ends up with the right ownership.
    local repo_ref="${THIS_REPO_REF:-}"
    if [ -z "$repo_ref" ]; then
        repo_ref=$(git -C "$SCRIPT_DIR" branch --show-current 2>/dev/null || true)
    fi
    repo_ref="${repo_ref:-main}"

    su - "$RUN_USER" -c "
        set -e
        if [ -d '$RUN_USER_REPO_DIR/.git' ]; then
            echo 'Repo already exists at $RUN_USER_REPO_DIR, updating $repo_ref.'
            cd '$RUN_USER_REPO_DIR'
            git fetch origin '$repo_ref'
            git checkout '$repo_ref'
            git pull --ff-only origin '$repo_ref'
        else
            git clone --branch '$repo_ref' '$THIS_REPO_URL' '$RUN_USER_REPO_DIR'
        fi
    "

    # Seed .env from the in-repo template if one is not already present.
    local env_src env_dst seeded_env="0"
    env_dst="$RUN_USER_REPO_DIR/.env"
    if [ -f "$RUN_USER_REPO_DIR/example.env" ]; then
        env_src="$RUN_USER_REPO_DIR/example.env"
    else
        env_src=""
    fi

    if [ ! -f "$env_dst" ] && [ -n "$env_src" ]; then
        cp "$env_src" "$env_dst"
        chown "$RUN_USER:$RUN_GROUP" "$env_dst"
        seeded_env="1"
    fi

    if [ "$seeded_env" = "1" ]; then
        replace_key_value_line "$env_dst" "INSTALL_DIR" "$RUN_USER_HOME"
        replace_key_value_line "$env_dst" "UPLOAD_DIR" "$RUN_USER_HOME/upload"
        chown "$RUN_USER:$RUN_GROUP" "$env_dst"
    fi

}


# -------------------
# Copy service files (for systemd compatibility)
# -------------------

copy_service_files () {
    local escaped_home escaped_user escaped_group unit_dir run_group launcher_dir

    unit_dir="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
    launcher_dir="${SERVICE_LAUNCH_DIR:-/usr/local/libexec/immich-in-lxc}"
    mkdir -p "$unit_dir"
    install -d -o root -g root -m 0755 "$launcher_dir"
    install -o root -g root -m 0755 "$SCRIPT_DIR/service-launch.sh" "$launcher_dir/service-launch.sh"

    # Remove deprecated service
    rm -f "$unit_dir/immich-microservices.service"

    escaped_home="${RUN_USER_HOME//\//\\/}"
    escaped_user="${RUN_USER//&/\\&}"
    run_group="${RUN_GROUP:-$RUN_USER}"
    escaped_group="${run_group//&/\\&}"

    sed \
        -e "s/User=immich/User=$escaped_user/" \
        -e "s/Group=immich/Group=$escaped_group/" \
        -e "s|/home/immich|$escaped_home|g" \
        -e "s|/usr/local/libexec/immich-in-lxc|$launcher_dir|g" \
        "$SCRIPT_DIR/immich-ml.service" > "$unit_dir/immich-ml.service"
    sed \
        -e "s/User=immich/User=$escaped_user/" \
        -e "s/Group=immich/Group=$escaped_group/" \
        -e "s|/home/immich|$escaped_home|g" \
        -e "s|/usr/local/libexec/immich-in-lxc|$launcher_dir|g" \
        "$SCRIPT_DIR/immich-web.service" > "$unit_dir/immich-web.service"
}


# -------------------
# Create log directory
# -------------------

create_log_directory () {
    mkdir -p /var/log/immich
    chown "$RUN_USER:$RUN_GROUP" /var/log/immich
    chmod 755 /var/log/immich
}

build_mimalloc () {
    cd "$SCRIPT_DIR"

    SOURCE="$SOURCE_DIR/mimalloc"

    safe_git_checkout "$MIMALLOC_REPO_URL" "$SOURCE" "$MIMALLOC_TAG"

    rm -rf "$SOURCE/build"
    mkdir -p "$SOURCE/build"
    cd "$SOURCE/build"

    cmake .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DMI_BUILD_SHARED=ON \
        -DMI_BUILD_STATIC=OFF \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DCMAKE_INSTALL_LIBDIR=lib/x86_64-linux-gnu

    echo "Building mimalloc using $(nproc) threads"
    cmake --build . -- -j"$(nproc)"
    cmake --install .

    ldconfig

    if [ ! -e /usr/lib/x86_64-linux-gnu/libmimalloc.so.3 ]; then
        echo "ERROR: libmimalloc.so.3 was not installed correctly"
        exit 1
    fi

    if ! readelf -d /usr/lib/x86_64-linux-gnu/libmimalloc.so.3 | grep -q 'SONAME.*libmimalloc.so.3'; then
        echo "ERROR: installed mimalloc SONAME is not libmimalloc.so.3"
        exit 1
    fi
}

# -------------------
# Setup folders
# -------------------

setup_folders () {
    cd $SCRIPT_DIR

    if [ ! -d "$SOURCE_DIR" ]; then
        mkdir $SOURCE_DIR
    fi
    chown -R "$RUN_USER:$RUN_GROUP" "$SOURCE_DIR"
}


# -------------------
# Change locale
# -------------------

change_locale () {
    sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
    locale-gen
}


# -------------------
# Build libjxl
# -------------------

build_libjxl () {
    (
    set -e
    cd $SCRIPT_DIR

    SOURCE=$SOURCE_DIR/libjxl

    # This is set based on distro, or which libjpeg-dev is available (ABI 62 or 80)
    echo $JPEGLI_LIBJPEG_LIBRARY_SOVERSION
    echo $JPEGLI_LIBJPEG_LIBRARY_VERSION

    : "${LIBJXL_REVISION:=$(jq -cr '.revision' $BASE_IMG_REPO_DIR/server/sources/libjxl.json)}"

    safe_git_checkout https://github.com/libjxl/libjxl.git $SOURCE $LIBJXL_REVISION true

    cd $SOURCE

    # Apply patches idempotently: skip if already applied
    for patch in $BASE_IMG_REPO_DIR/server/sources/libjxl-patches/jpegli-empty-dht-marker.patch \
                 $BASE_IMG_REPO_DIR/server/sources/libjxl-patches/jpegli-icc-warning.patch; do
        if git apply --check "$patch" 2>/dev/null; then
            git apply "$patch"
        else
            echo "Patch already applied or not applicable: $patch"
        fi
    done

    remove_build_folder $SOURCE
    
    mkdir build
    cd build
    cmake \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_TESTING=OFF \
    -DJPEGXL_ENABLE_DOXYGEN=OFF \
    -DJPEGXL_ENABLE_MANPAGES=OFF \
    -DJPEGXL_ENABLE_PLUGIN_GIMP210=OFF \
    -DJPEGXL_ENABLE_BENCHMARK=OFF \
    -DJPEGXL_ENABLE_EXAMPLES=OFF \
    -DJPEGXL_FORCE_SYSTEM_BROTLI=ON \
    -DJPEGXL_FORCE_SYSTEM_HWY=ON \
    -DJPEGXL_ENABLE_JPEGLI=ON \
    -DJPEGXL_ENABLE_JPEGLI_LIBJPEG=ON \
    -DJPEGXL_INSTALL_JPEGLI_LIBJPEG=ON \
    -DJPEGXL_ENABLE_PLUGINS=ON \
    -DJPEGLI_LIBJPEG_LIBRARY_SOVERSION="${JPEGLI_LIBJPEG_LIBRARY_SOVERSION}" \
    -DJPEGLI_LIBJPEG_LIBRARY_VERSION="${JPEGLI_LIBJPEG_LIBRARY_VERSION}" \
    -DLIBJPEG_TURBO_VERSION_NUMBER=2001005 \
    ..
    # Move the following flag to above if one's system support AVX512
    # -DJPEGXL_ENABLE_AVX512=ON \
    # -DJPEGXL_ENABLE_AVX512_ZEN4=ON \
    echo "Building libjxl using $(nproc) threads"
    cmake --build . -- -j"$(nproc)"
    cmake --install .

    ldconfig /usr/local/lib

    # Clean up builds
    make clean
    remove_build_folder $SOURCE
    rm -rf $SOURCE/third_party/
    )
}


# -------------------
# Build libheif
# -------------------

build_libheif () {
    (
    set -e
    cd $SCRIPT_DIR

    SOURCE=$SOURCE_DIR/libheif

    : "${LIBHEIF_REVISION:=$(jq -cr '.revision' $BASE_IMG_REPO_DIR/server/sources/libheif.json)}"

    safe_git_checkout https://github.com/strukturag/libheif.git $SOURCE $LIBHEIF_REVISION

    cd $SOURCE

    remove_build_folder $SOURCE

    mkdir build
    cd build
    cmake --preset=release-noplugins \
        -DWITH_DAV1D=ON \
        -DENABLE_PARALLEL_TILE_DECODING=ON \
        -DWITH_LIBSHARPYUV=ON \
        -DWITH_LIBDE265=ON \
        -DWITH_AOM_DECODER=OFF \
        -DWITH_AOM_ENCODER=ON \
        -DWITH_X265=ON \
        -DWITH_EXAMPLES=OFF \
        ..
    make install -j "$(nproc)"
    ldconfig /usr/local/lib

    # Clean up builds
    make clean
    remove_build_folder $SOURCE
    )
}


# -------------------
# Build libraw
# -------------------

build_libraw() {
    (
    set -e
    cd "$SCRIPT_DIR"

    SOURCE="$SOURCE_DIR/libraw"

    : "${LIBRAW_REVISION:=$(jq -cr '.revision' "$BASE_IMG_REPO_DIR/server/sources/libraw.json")}"

    safe_git_checkout "https://github.com/libraw/libraw.git" "$SOURCE" "$LIBRAW_REVISION"

    cd "$SOURCE"
    autoreconf --install

    # Create an out-of-source build directory
    mkdir -p build
    cd build

    ../configure
    echo "Building libraw using $(nproc) threads"
    make -j"$(nproc)"
    # Sharp is built later as the unprivileged service user. Do not let a
    # restrictive umask inherited by pre-install.sh make these headers
    # unsearchable (for example /usr/local/include/libraw mode 0700).
    # Autotools honours the process umask while creating install directories.
    umask 022
    make install
    ldconfig /usr/local/lib

    # Clean up builds
    make clean
    cd ..
    remove_build_folder $SOURCE
    )
}



# -------------------
# Build image magick
# -------------------

build_image_magick () {
    (
    set -e
    cd $SCRIPT_DIR

    SOURCE=$SOURCE_DIR/image-magick

    : "${IMAGEMAGICK_REVISION:=$(jq -cr '.revision' $BASE_IMG_REPO_DIR/server/sources/imagemagick.json)}"

    safe_git_checkout https://github.com/ImageMagick/ImageMagick.git $SOURCE $IMAGEMAGICK_REVISION

    cd $SOURCE

    ./configure --with-raw --with-modules
    echo "Building ImageMagick using $(nproc) threads"
    make -j"$(nproc)"
    make install
    ldconfig /usr/local/lib
    
    # With --with-modules, libraw is linked by the DNG coder rather than the
    # main magick executable. Verify the component that actually loads it.
    local raw_coder
    raw_coder=$(find /usr/local/lib -path '*/ImageMagick-*/modules-*/coders/dng.so' -print -quit)
    if [ -z "$raw_coder" ]; then
        echo "ImageMagick DNG coder was not installed." >&2
        exit 1
    fi
    ldd "$raw_coder" | grep -q libraw

    # Clean up builds
    make clean
    )
}


# -------------------
# Build libvips
# -------------------

build_libvips () {
    (
    set -e

    cd $SCRIPT_DIR

    SOURCE=$SOURCE_DIR/libvips

    : "${LIBVIPS_REVISION:=$(jq -cr '.revision' $BASE_IMG_REPO_DIR/server/sources/libvips.json)}"

    safe_git_checkout https://github.com/libvips/libvips.git $SOURCE $LIBVIPS_REVISION

    cd $SOURCE
    
    remove_build_folder $SOURCE
    
    # -Djpeg-xl=disabled is added because previous broken install will break libvips
    meson setup build --buildtype=release --libdir=lib -Dintrospection=disabled -Dtiff=disabled
    cd build
    ninja install
    ldconfig /usr/local/lib

    # Clean up builds
    remove_build_folder $SOURCE
    )
}

# -------------------
# Remove build dependency
# -------------------
# We cant remove build deps here as we are rebuilding sharp later.
# Either sharp builds here and then moved to app folder, or we delete
# after the install and then re-install when doing another upgrade.
# For now, keep everything
# Ideas is to build sharp to not use pre bundled vips and instead rely
# on the manually build version where all the codecs are correctly linked.
# In perfect universe we dont need anything from here to run Immich:
# But the updates happen so frequently and sharp is rebuilt every time, 
# This would be time consuming to redownload it every time. 

# apt-get purge -y \
#     build-essential \
#     g++ \
#     autoconf \
#     cmake \
#     meson \
#     ninja-build \
#     pkg-config \
#     libtool \
#     python3-dev \
#     libbrotli-dev \
#     libde265-dev \
#     libexif-dev \
#     libexpat1-dev \
#     libglib2.0-dev \
#     libgsf-1-dev \
#     libspng-dev \
#     librsvg2-dev \
#     libaom-dev \
#     libx265-dev \
#     libgif-dev \
#     libpango1.0-dev \
#     libjpeg-dev \
#     libpng-dev \
#     libtiff-dev \
#     liblcms2-dev \
#     libxml2-dev \
#     libfftw3-dev \
#     libopenexr-dev \
#     libzip-dev \
#     libssl-dev \
#     libimagequant-dev \
#     libcfitsio-dev \
#     libcairo2-dev \
#     libfontconfig1-dev \
#     libmatio-dev \
#     libopenjp2-7-dev \
#     libcgif-dev \
#     libheif-dev \
#     libdav1d-dev \
#     libhwy-dev \
#     libwebp-dev

# apt-get clean
# rm -rf /var/lib/apt/lists/*

remove_build_dependency () {
    apt-get purge -y libvips-dev libmimalloc2.0 libmimalloc-dev
    apt-get autoremove -y
}

# -------------------
# Add runtime dependency
# -------------------

add_runtime_dependency () {
    apt-get update

    apt-get install --no-install-recommends -yqq \
        libde265-0 \
        libexif12 \
        libexpat1 \
        libgcc-s1 \
        libglib2.0-0 \
        libgomp1 \
        libgsf-1-114 \
        liblcms2-2 \
        liblqr-1-0 \
        libltdl7 \
        libopenexr-3-1-30 \
        libopenjp2-7 \
        librsvg2-2 \
        libspng0 \
        mesa-utils \
        mesa-va-drivers \
        mesa-vulkan-drivers \
        tini \
        wget \
        zlib1g \
        ocl-icd-libopencl1

    apt-get install --no-install-recommends -y \
        libio-compress-brotli-perl \
        libwebp7 \
        libwebpdemux2 \
        libwebpmux3 \
        libhwy1t64
}

main() {
    set -xeuo pipefail # Make people's life easier

    check_root
    set_common_variables
    check_supported_os
    install_bootstrap_dependencies
    create_immich_user
    prepare_build_dir
    safe_git_checkout "$REPO_URL" "$BASE_IMG_REPO_DIR" main
    install_runtime_component
    install_build_dependency
    install_ffmpeg
    install_postgresql
    setup_immich_database
    setup_folders
    change_locale
    build_libjxl
    build_libheif
    build_libraw
    build_mimalloc
    build_image_magick
    build_libvips
    remove_build_dependency
    add_runtime_dependency
    setup_immich_repo
    copy_service_files
    create_log_directory

    set +x
    echo
    echo "===================================================================="
    echo "pre-install complete."
    echo
    echo "Log in as the service user to continue:"
    echo "    su - $RUN_USER"
    echo "    cd $RUN_USER_REPO_DIR"
    echo "    ./install.sh"
    echo "===================================================================="
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
