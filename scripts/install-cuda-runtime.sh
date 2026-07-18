#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run this CUDA runtime installer as root." >&2
    exit 1
fi

. /etc/os-release
needs_legacy_key_policy=false
case "${ID}:${VERSION_ID}" in
    ubuntu:24.04) cuda_repo=ubuntu2404 ;;
    # NVIDIA's Debian 13 repository starts at CUDA 13, while Immich v3.0.2's
    # ONNX Runtime build requires CUDA 12. The Ubuntu 24.04 repository provides
    # the same architecture-only CUDA user-space libraries with a current key.
    debian:13)
        cuda_repo=ubuntu2404
        needs_legacy_key_policy=true
        ;;
    *)
        echo "CUDA runtime installation is supported on Ubuntu 24.04 and Debian 13." >&2
        exit 1
        ;;
esac

if [[ "$(dpkg --print-architecture)" != amd64 ]]; then
    echo "The NVIDIA CUDA runtime helper currently supports amd64 only." >&2
    exit 1
fi

keyring_deb=/tmp/cuda-keyring_1.1-1_all.deb
apt-get update
apt-get install --no-install-recommends -y ca-certificates wget
wget -qO "$keyring_deb" \
    "https://developer.download.nvidia.com/compute/cuda/repos/${cuda_repo}/x86_64/cuda-keyring_1.1-1_all.deb"
dpkg -i "$keyring_deb"

cuda_source=$(dpkg -L cuda-keyring | awk '/\/sources.list.d\/.*\.list$/ { print; exit }')
if [[ -z "$cuda_source" || ! -f "$cuda_source" ]]; then
    echo "The CUDA keyring did not install an APT source file." >&2
    exit 1
fi

cleanup_cuda_source() {
    if [[ "$needs_legacy_key_policy" == true ]]; then
        rm -f "$cuda_source"
        dpkg --remove cuda-keyring >/dev/null 2>&1 || true
    fi
}
trap cleanup_cuda_source EXIT

if [[ "$needs_legacy_key_policy" == true ]]; then
    # Debian 13 rejects NVIDIA's otherwise-current CUDA 12 signing certificate
    # because its key binding uses SHA-1. Relax only that binding check, only
    # while loading NVIDIA's isolated index; Release signatures stay verified.
    policy_file=/tmp/apt-sequoia-cuda.config
    sed -E \
        's/^(sha1\.second_preimage_resistance[[:space:]]*=[[:space:]]*).*/\12099-02-01/' \
        /usr/share/apt/default-sequoia.config > "$policy_file"
    APT_SEQUOIA_CRYPTO_POLICY="$policy_file" apt-get update \
        -o "Dir::Etc::sourcelist=$cuda_source" \
        -o 'Dir::Etc::sourceparts=-' \
        -o 'APT::Get::List-Cleanup=0'
else
    apt-get update
fi

# ONNX Runtime GPU needs the CUDA runtime, cuBLAS, cuFFT, cuRAND, and cuDNN.
# Immich v3.0.2 continues to pin cuDNN 9.10 because 9.11 dropped Pascal support.
apt-get install --no-install-recommends -y \
    cuda-cudart-12-9 \
    libcublas-12-9 \
    libcufft-12-9 \
    libcurand-12-9 \
    libcudnn9-cuda-12=9.10.2.21-1
cleanup_cuda_source
trap - EXIT
ldconfig

echo "CUDA 12 runtime and cuDNN 9.10 installation completed."
