#!/bin/bash

set -xeuo pipefail # Make my life easier

# Install dependencies for Debian 13 without mixing Debian releases.

. /etc/os-release
if [[ "${ID:-}" != debian || "${VERSION_ID:-}" != 13* ]]; then
    echo "This installer supports Debian 13 only." >&2
    echo "Debian 12 required mixing Trixie packages into Bookworm, which could partially upgrade the OS (issue #10)." >&2
    echo "Upgrade the guest to Debian 13 using Debian's release procedure, or create a fresh Debian 13 guest." >&2
    exit 1
fi

# Update before install from new sources
apt update

# libjpeg62-turbo-dev
apt install --no-install-recommends -y \
        libjpeg62-turbo-dev
## libjpeg-turbo is faster than libjpeg

# Dockerfile 35
apt install --no-install-recommends -yqq \
        libdav1d-dev \
        libhwy-dev \
        libwebp-dev \
        libio-compress-brotli-perl

## Dockerfile 92
apt install --no-install-recommends -y \
        libio-compress-brotli-perl \
        libwebp7 \
        libwebpdemux2 \
        libwebpmux3 \
        libhwy1t64

## Dockerfile 104
# apt install -t stable --no-install-recommends -y \
#         intel-media-va-driver
