#!/bin/bash

# -------------------
# Include helper functions
# Such as git safe_git_checkout, set_user_to_run
# -------------------
source "./helpers.sh"


# -------------------
# Common variables
# -------------------
set_common_variables () {
    set -a
    SCRIPT_DIR=$PWD
    REPO_URL="https://github.com/immich-app/base-images"
    APP_REPO_URL="https://github.com/immich-app/immich"
    BASE_IMG_REPO_DIR=$SCRIPT_DIR/base-images
    SOURCE_DIR=$SCRIPT_DIR/image-source
    LD_LIBRARY_PATH=/usr/local/lib # :$LD_LIBRARY_PATH
    LD_RUN_PATH=/usr/local/lib # :c$LD_RUN_PATH
    set_user_to_run # Sets $USER_TO_RUN
    set +a
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

    # From immich/base-image
    ## Install common tools
    apt-get install --no-install-recommends -y\
        curl git python3-venv python3-dev unzip

    ## Install common build components
    apt-get install --no-install-recommends -y\
        autoconf \
        build-essential \
        cmake \
        jq \
        libbrotli-dev \
        libde265-dev \
        libexif-dev \
        libexpat1-dev \
        libglib2.0-dev \
        libgsf-1-dev \
        liblcms2-2 \
        libspng-dev \
        librsvg2-dev \
        meson \
        ninja-build \
        pkg-config \
        wget \
        zlib1g \
        cpanminus

    # Install for imagick & sharp
    apt-get install --no-install-recommends -y\
        libtool \
        libheif-dev \
        libaom-dev \
        libde265-dev \
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
        libde265-dev \
        libvips-dev \
        g++ \
        libimagequant-dev


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
    PG_VC_FILE_NAME=postgresql-17-vchord_0.4.3-1_$(dpkg --print-architecture).deb
    if [ ! -f "$PG_VC_FILE_NAME" ]; then
        wget -P /root/ https://github.com/tensorchord/VectorChord/releases/download/0.4.3/$PG_VC_FILE_NAME
    fi
    apt install -y /root/$PG_VC_FILE_NAME

    # Config PostgreSQL to use VectorCord
    runuser -u postgres -- psql -c 'ALTER SYSTEM SET shared_preload_libraries = "vchord"'
    systemctl restart postgresql.service
    # Wait for restart
    sleep 5
    runuser -u postgres -- psql -c 'CREATE EXTENSION IF NOT EXISTS vchord CASCADE'
}

# -------------------
# Change lock file permission
# -------------------

change_permission () {
    # Change file permission so that install script could copy the content
    chmod 666 $BASE_IMG_REPO_DIR/server/sources/*.json
}


# -------------------
# Setup folders
# -------------------

setup_folders () {
    cd $SCRIPT_DIR

    if [ ! -d "$SOURCE_DIR" ]; then
        mkdir $SOURCE_DIR
    fi
    sudo chown -R $USER_TO_RUN:$USER_TO_RUN $SOURCE_DIR
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
    cd $SCRIPT_DIR

    SOURCE=$SOURCE_DIR/libjxl

    set -e

    # This is set based on distro, or which libjpeg-dev is available (ABI 62 or 80)
    echo $JPEGLI_LIBJPEG_LIBRARY_SOVERSION
    echo $JPEGLI_LIBJPEG_LIBRARY_VERSION

    : "${LIBJXL_REVISION:=$(jq -cr '.revision' $BASE_IMG_REPO_DIR/server/sources/libjxl.json)}"
    set +e

    safe_git_checkout https://github.com/libjxl/libjxl.git $SOURCE $LIBJXL_REVISION

    cd $SOURCE

    git submodule update --init --recursive --depth 1 --recommend-shallow

    git apply $BASE_IMG_REPO_DIR/server/sources/libjxl-patches/jpegli-empty-dht-marker.patch
    git apply $BASE_IMG_REPO_DIR/server/sources/libjxl-patches/jpegli-icc-warning.patch

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
}


# -------------------
# Build libheif
# -------------------

build_libheif () {
    cd $SCRIPT_DIR

    SOURCE=$SOURCE_DIR/libheif

    set -e
    : "${LIBHEIF_REVISION:=$(jq -cr '.revision' $BASE_IMG_REPO_DIR/server/sources/libheif.json)}"
    set +e

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
}


# -------------------
# Build libraw
# -------------------

build_libraw() {
    cd "$SCRIPT_DIR"

    SOURCE="$SOURCE_DIR/libraw"

    set -e
    : "${LIBRAW_REVISION:=$(jq -cr '.revision' "$BASE_IMG_REPO_DIR/server/sources/libraw.json")}"
    set +e

    safe_git_checkout "https://github.com/libraw/libraw.git" "$SOURCE" "$LIBRAW_REVISION"

    cd "$SOURCE"
    autoreconf --install

    # Create an out-of-source build directory
    mkdir -p build
    cd build

    ../configure
    echo "Building libraw using $(nproc) threads"
    make -j"$(nproc)"
    make install
    ldconfig /usr/local/lib

    # Clean up builds
    make clean
    cd ..
    remove_build_folder "$SOURCE"
}



# -------------------
# Build image magick
# -------------------

build_image_magick () {
    cd $SCRIPT_DIR

    SOURCE=$SOURCE_DIR/image-magick

    set -e
    : "${IMAGEMAGICK_REVISION:=$(jq -cr '.revision' $BASE_IMG_REPO_DIR/server/sources/imagemagick.json)}"
    set +e

    safe_git_checkout https://github.com/ImageMagick/ImageMagick.git $SOURCE $IMAGEMAGICK_REVISION

    cd $SOURCE

    ./configure --with-raw --with-modules
    echo "Building ImageMagick using $(nproc) threads"
    make -j"$(nproc)"
    make install
    ldconfig /usr/local/lib
    
    # Check
    ldd $(which magick) | grep libraw

    # Clean up builds
    make clean
}


# -------------------
# Build libvips
# -------------------

build_libvips () {

    cd $SCRIPT_DIR

    SOURCE=$SOURCE_DIR/libvips

    set -e
    : "${LIBVIPS_REVISION:=$(jq -cr '.revision' $BASE_IMG_REPO_DIR/server/sources/libvips.json)}"
    set +e

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
}

# -------------------
# Remove build dependency
# -------------------

remove_build_dependency () {
    apt-get remove -y \
        libbrotli-dev \
        libde265-dev \
        libexif-dev \
        libexpat1-dev \
        libgsf-1-dev \
        liblcms2-2 \
        librsvg2-dev \
        libspng-dev
    apt-get remove -y \
        libdav1d-dev \
        libhwy-dev \
        libwebp-dev \
        libio-compress-brotli-perl
    apt-get remove -y \
        libtool \
        liblcms2-dev \
        libgif-dev \
        libpango1.0-dev \
        libjpeg-dev \
        libpng-dev \
        libtiff-dev \
        libxml2-dev \
        libfftw3-dev \
        libopenexr-dev \
        libzip-dev \
        libde265-dev 
}


# -------------------
# Add runtime dependency
# -------------------

add_runtime_dependency () {
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
        libmimalloc2.0 \
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


set -xeuo pipefail # Make people's life easier

set_common_variables
safe_git_checkout "$REPO_URL" "$BASE_IMG_REPO_DIR" main
install_runtime_component
install_build_dependency
install_ffmpeg
install_postgresql
change_permission
setup_folders
change_locale
build_libjxl
build_libheif
build_libraw
build_image_magick
build_libvips
# remove_build_dependency <- currently required by install step
add_runtime_dependency
