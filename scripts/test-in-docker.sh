#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
IMAGE="immich-in-lxc-smoke:${TEST_OS:-ubuntu-24.04}"
CONTAINER="immich-in-lxc-systemd-smoke-$$"

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "Docker Engine is unavailable. In WSL2, enable Docker Desktop integration for this distribution and retry." >&2
    exit 1
fi

cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker build \
    --build-arg "BASE_IMAGE=${BASE_IMAGE:-ubuntu:24.04}" \
    -f "$REPO_DIR/tests/docker/Dockerfile" \
    -t "$IMAGE" \
    "$REPO_DIR"

echo "Running non-systemd compatibility smoke test..."
docker run --rm \
    -v "$REPO_DIR:/workspace:ro" \
    "$IMAGE" \
    /workspace/tests/container-smoke.sh non-systemd

echo "Booting a privileged container with systemd as PID 1..."
gpu_args=()
if [[ "${CUDA_TEST:-0}" == 1 ]]; then
    gpu_args+=(--runtime=nvidia --gpus all -e TEST_CUDA=1)
fi
docker run -d \
    --name "$CONTAINER" \
    --privileged \
    --cgroupns=host \
    "${gpu_args[@]}" \
    --tmpfs /run \
    --tmpfs /run/lock \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    -v "$REPO_DIR:/workspace:ro" \
    "$IMAGE" >/dev/null

for _ in $(seq 1 30); do
    if docker exec "$CONTAINER" systemctl is-system-running --quiet 2>/dev/null; then
        break
    fi
    state="$(docker exec "$CONTAINER" systemctl is-system-running 2>/dev/null || true)"
    if [[ "$state" == degraded ]]; then
        break
    fi
    sleep 1
done

pid1="$(docker exec "$CONTAINER" cat /proc/1/comm 2>/dev/null || true)"
if [[ "$pid1" != systemd ]]; then
    docker logs "$CONTAINER"
    echo "systemd did not start inside the test container." >&2
    exit 1
fi

docker exec "$CONTAINER" /workspace/tests/container-smoke.sh systemd

if [[ "${FULL_INSTALL:-0}" == 1 ]]; then
    if [[ "${CUDA_TEST:-0}" == 1 ]]; then
        echo "Running the full CUDA Immich installation, inference, and web health check..."
    else
        echo "Running the full native Immich installation and web health check..."
    fi
    docker exec "$CONTAINER" timeout "${FULL_INSTALL_TIMEOUT:-7200}" \
        /workspace/tests/full-install-smoke.sh
fi

echo "Docker smoke tests passed."
