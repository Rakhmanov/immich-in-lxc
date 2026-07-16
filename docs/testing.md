# Testing

The Docker harness tests the installer in disposable Ubuntu 24.04 or Debian 13 containers. Docker is used only for tests; the resulting production installation remains native.

## Fast smoke test

```bash
./scripts/test-in-docker.sh
```

This runs:

1. a normal container without systemd, exercising the compatibility path; and
2. a privileged container with systemd as PID 1, exercising unit installation and stable service dispatch.

The fast test checks configuration validation, secret handling, custom install paths, PostgreSQL service fallback selection, and systemd startup with lightweight test fixtures. It does not compile Immich, start the real web application, or load the browser UI.

## Debian 13 smoke test

```bash
TEST_OS=debian-13 BASE_IMAGE=debian:13 ./scripts/test-in-docker.sh
```

This verifies the Debian 13 dependency and systemd paths without running the long native build.

## Full native install and web API test

```bash
FULL_INSTALL=1 ./scripts/test-in-docker.sh
```

This performs native dependency installation, builds Immich, starts PostgreSQL, Redis, machine learning, and the web service, then requires this endpoint to respond:

```text
http://127.0.0.1:2283/api/server/ping
```

The full test can take well over 30 minutes. A successful API ping proves that the real web service loaded and answered; it does not automate first-user creation or exercise every browser workflow.

To combine the full build with Debian 13:

```bash
TEST_OS=debian-13 BASE_IMAGE=debian:13 FULL_INSTALL=1 ./scripts/test-in-docker.sh
```

## Full NVIDIA CUDA test

On a host with an NVIDIA GPU and NVIDIA Container Toolkit configured:

```bash
FULL_INSTALL=1 CUDA_TEST=1 ./scripts/test-in-docker.sh
```

This installs the guest CUDA runtime, selects Immich's CUDA ML dependencies, starts the real services, verifies the web API, and requires a real ONNX CUDA inference with CPU fallback disabled.

## Docker systemd requirements

The systemd test needs privileged mode, the host cgroup namespace, and a writable `/sys/fs/cgroup` mount. The harness configures these automatically. If Docker itself is unavailable, it exits before changing the host.

## What remains environment-specific

Docker cannot fully reproduce an unprivileged Proxmox LXC's UID/GID mapping, host bind mounts, device cgroup policy, boot ordering, reverse proxy, or DNS configuration. After container tests pass, verify on the target guest:

- mounted-media write access as `immich`;
- service auto-start after a guest reboot;
- the web login and administration pages in a browser;
- a real photo upload, thumbnail generation, and machine-learning job;
- hardware transcoding and GPU utilization, when enabled; and
- database and media backup restoration.
