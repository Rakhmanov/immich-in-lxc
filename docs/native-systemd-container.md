# Native installer inside a persistent systemd container

This pattern runs the normal native installer inside a supported Ubuntu 24.04
or Debian 13 userspace while using Docker only as the outer guest/container
manager. It is not the official Immich Docker Compose deployment.

Use it when the physical host OS is unsupported by this installer but can run a
privileged systemd container with the required devices and persistent bind
mounts. A VM or LXC remains the simpler production choice when available.

## What remains native

Inside the guest, `pre-install.sh` and `install.sh` provide the same layout and
services as an LXC/VM install:

- systemd is PID 1;
- PostgreSQL 17, Redis, Immich web, and Immich ML are guest services;
- the deployed app is under `INSTALL_DIR`, normally `/home/immich/app`;
- the stable service launcher and runtime environment are installed normally;
- media is mounted at `UPLOAD_DIR`, normally `/mnt/photos`.

Do not combine this procedure with Immich's official compose stack or official
application images in the same guest.

## Required outer-container features

A real systemd guest requires:

```text
--privileged
--cgroupns=host
--tmpfs /run
--tmpfs /run/lock
-v /sys/fs/cgroup:/sys/fs/cgroup:rw
--stop-signal SIGRTMIN+3
```

For NVIDIA ML, prefer a current Docker GPU device request:

```text
--gpus all
```

Add `--runtime=nvidia` only on a host that actually registers the legacy
`nvidia` runtime. CDI/device-request hosts commonly use the default runtime.

## Persistence boundary

At minimum, persist these paths outside the systemd container:

| Guest path | Purpose |
| --- | --- |
| `/home/immich` | app, source, runtime configuration, ML environment, model cache |
| `/var/lib/postgresql` | PostgreSQL cluster |
| `/var/log/immich` | native service logs |
| `/mnt/photos` | originals and generated Immich media |

The outer container should have a restart policy such as `unless-stopped`, and
the inner Immich systemd units should be enabled only after restore/cutover is
complete.

The installer checkout may be bind-mounted read-only at a control path such as
`/workspace`; the deployed services do not depend on that bind after the stable
launcher is installed.

## UID/GID and network filesystems

Match the inner `immich` UID/GID to the ownership contract of the mounted media.
Ubuntu base images commonly reserve UID 1000 for `ubuntu`; remove or remap that
unused account before creating `immich` as UID/GID 1000 when the media mount is
forced to 1000.

For SMB/CIFS, `uid=`, `gid=`, `forceuid`, and `forcegid` control the client-side
view. They do not bypass server-side permissions. Every parent directory still
needs traverse permission for the SMB identity, and the server must authorize
file reads/writes.

Test the actual workload directories as the service user:

```bash
for dir in library upload thumbs encoded-video profile; do
  probe="/mnt/photos/$dir/.immich-write-test-$$"
  runuser -u immich -- touch "$probe"
  runuser -u immich -- rm "$probe"
done
```

The media root itself does not need to be writable when all required children
already exist.

## Safe database staging and worker ownership

Database and media must move as one logical state. When the media tree is shared
but PostgreSQL is local to each host, transfer database authority explicitly.

Immich supports an API-only server process with:

```dotenv
IMMICH_WORKERS_INCLUDE=api
```

Use that on a staged target so API/schema/media checks cannot consume background
jobs. Keep the source authoritative until the target has restored a dump and
passed validation.

For final cutover:

1. stop source web/ML workers;
2. take and validate a final PostgreSQL dump;
3. record and verify a checksum after copying it to target-local storage;
4. stop target web/ML, replace its database, and verify counts;
5. remove the API-only restriction from the target;
6. start/enable target services;
7. switch routing;
8. disable source services so reboot cannot cause split-brain workers.

Never run unrestricted workers on two hosts backed by independently changing
PostgreSQL databases. Do not empty queues merely to make a migration appear
complete.

## Native validation gates

The full harness includes these checks and they should also be repeated on a
persistent target:

- systemd is PID 1;
- PostgreSQL, Redis, web, and ML service state;
- `/api/server/ping` inside and outside the guest;
- GPU visibility and CUDA-only ONNX inference when CUDA is enabled;
- ImageMagick DNG coder linkage to `/usr/local/lib/libraw_r.so`;
- deployed Sharp addon linkage to global libvips and libraw;
- real JPEG, AVIF, and JPEG-XL buffer encodes;
- media write/delete probes;
- restored database counts;
- correct worker include/exclude environment.

Sharp v0.34 exposes AVIF through the HEIF encoder alias. Capability checks must
use `sharp.format.heif.output.buffer`, not `sharp.format.avif.output`. A real
`.avif().toBuffer()` is the final proof.

## Test-cache and failure-retention lessons

Use:

```bash
PERSISTENT_CACHE=1 KEEP_FAILED_CONTAINER=1 \
FULL_INSTALL=1 CUDA_TEST=1 TEST_REPO_TAG=v3.0.3 \
  ./scripts/test-in-docker.sh
```

Persistent test volumes preserve apt/CUDA packages, native source repositories,
NVM downloads, pnpm's store, and uv/user caches. Native libraries still compile
cleanly so linkage is tested rather than assumed.

Docker creates nested volume mountpoints before the service user exists. The
test harness must create/chown the home, `.cache`, `.local`, and `.nvm` parent
directories, not only the mounted leaves.

Ubuntu's container apt hook deletes downloaded packages. Persistent-cache mode
removes only `/etc/apt/apt.conf.d/docker-clean` and enables apt's downloaded
package retention inside the disposable test guest.

Failed-container retention is intentionally opt-in. A successful run always
removes its disposable container. A retained failure should print both the
container name and its explicit removal command.

## Script invocation rule

Installer scripts resolve their own checkout via `BASH_SOURCE` and must work
when invoked by absolute path from `/`, systemd automation, or another control
directory. Do not reintroduce `source ./helpers.sh` or `SCRIPT_DIR=$PWD`; those
make automation depend on the caller's current directory.

## Security boundaries

- Treat a privileged systemd container as a trusted workload, not a hostile
  multitenant sandbox.
- Keep the installer bind read-only where possible.
- Generate unattended Linux and database passwords at runtime; do not commit
  them to orchestration scripts.
- Keep `runtime.env` and the private database password file mode `0600`.
- Do not publish PostgreSQL or Redis ports on the outer host.
- Put a reverse proxy in front of port 2283 and validate upload-size/WebSocket
  settings.
- Keep a checksum-verified final database dump and a tested reverse-routing
  path until the migration observation window ends.

## Scope not reproduced by the disposable harness

The full Docker harness proves the supported userspace, native build, systemd,
GPU, codec, ML, and API paths. It does not reproduce:

- Proxmox unprivileged UID maps;
- a particular SMB/NFS server's authorization rules;
- production DNS caching and compatibility routing;
- boot ordering of host mounts versus outer-container restart;
- real library job completion or a production rollback.

Those remain deployment-specific acceptance tests.
