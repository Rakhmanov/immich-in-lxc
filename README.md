# Immich in LXC without Docker

Install and update [Immich](https://github.com/immich-app/immich) directly in an LXC container, VM, or bare-metal host. The installer provides PostgreSQL, Redis, native media libraries, the Immich web server, machine learning, and systemd services without using Docker for the deployed instance.

This project is a fork of [loeeeee/immich-in-lxc](https://github.com/loeeeee/immich-in-lxc), inspired by [Immich Native](https://github.com/arter97/immich-native).

## Supported systems

- Ubuntu 24.04
- Debian 13
- systemd
- CPU machine learning by default
- Optional NVIDIA CUDA, AMD ROCm, and Intel OpenVINO machine learning

Debian 12 is not supported. Older releases of this installer could accidentally mix Debian releases; read [Debian recovery](docs/troubleshooting-and-recovery.md#debian-testing-repository-recovery) before changing an existing Debian 12 installation.

## Before you begin

Use a fresh container or VM and take a snapshot before installing. The commands below assume:

| Purpose | Path |
| --- | --- |
| Installer checkout | `/home/immich/immich-in-lxc` |
| Installed application | `/home/immich/app` |
| Immich source used for builds | `/home/immich/source` |
| Photos and Immich-generated media | `/mnt/photos` |
| Web interface | `http://<container-ip>:2283` |

Mount the media disk at `/mnt/photos` before installing. If you deliberately want everything on the container disk, use `/home/immich/upload` as `UPLOAD_DIR` instead.

The installation downloads and compiles large dependencies. Allow plenty of disk space and time.

## Install

Follow this recipe in order. Commands marked **root** must run from a root shell; do not add `sudo` unless your guest is already configured for it.

### 1. Bootstrap the host as root

```bash
apt-get update
apt-get install -y git
git clone https://github.com/Rakhmanov/immich-in-lxc.git /opt/immich-in-lxc-bootstrap
cd /opt/immich-in-lxc-bootstrap
./pre-install.sh
```

`pre-install.sh` asks for a password for the new `immich` Linux user and a password for the Immich PostgreSQL role. It then:

- creates the `immich` service account;
- installs and builds the system dependencies;
- configures PostgreSQL 17, VectorChord, and Redis;
- installs the systemd units and stable service launcher; and
- creates the working checkout at `/home/immich/immich-in-lxc`.

For unattended setup, provide `USER_PASSWORD` and `DB_PASSWORD` to `pre-install.sh`. Use `RUN_USER=name` only if you intentionally want a service user other than `immich`.

### 2. Verify the media mount as root

The `immich` user must be able to create files in the media directory:

```bash
test -d /mnt/photos
runuser -u immich -- test -w /mnt/photos
```

If either command fails, stop and fix the mount or LXC UID/GID mapping. Do not work around it by running `install.sh` as root. See [Storage and filesystem layout](docs/storage-and-layout.md).

### 3. Configure Immich as the service user

```bash
su - immich
cd ~/immich-in-lxc
test -f .env || cp example.env .env
nano .env
```

Use this configuration for the layout above:

```dotenv
REPO_TAG=v3.0.2
INSTALL_DIR=/home/immich
UPLOAD_DIR=/mnt/photos
isCUDA=false

PROXY_NPM=
PROXY_NPM_DIST=
PROXY_POETRY=
```

`INSTALL_DIR` is the deployment root, not the installer checkout. The installer creates `/home/immich/app/upload` as a symlink to `/mnt/photos`; do not create or replace that application symlink manually.

### 4. Build and deploy as the service user

```bash
./install.sh
```

Review `/home/immich/runtime.env` after installation, especially `TZ`. It contains the runtime database settings and is mode `0600`. Its stable systemd link is `/home/immich/.config/immich-in-lxc/runtime.env`.

Return to the root shell when the installer finishes:

```bash
exit
```

### 5. Start and verify as root

```bash
systemctl daemon-reload
systemctl enable --now immich-ml immich-web
systemctl --no-pager --full status immich-ml immich-web
curl --fail http://127.0.0.1:2283/api/server/ping
```

Open `http://<container-ip>:2283`, create the first admin account, then set:

`Administration > Settings > Machine Learning Settings > URL`

to:

```text
http://localhost:3003
```

Immich is now installed. Put a TLS reverse proxy in front of port `2283` before exposing it outside a trusted network.

## Update

This procedure refreshes both host dependencies and the deployed Immich application.

### 1. Back up and stop Immich as root

```bash
install -d -o postgres -g postgres -m 0700 /var/backups/immich
backup="/var/backups/immich/immich-$(date +%Y%m%d-%H%M%S).dump"
runuser -u postgres -- pg_dump --format=custom --file="$backup" immich
test -s "$backup"
echo "Database backup: $backup"
systemctl stop immich-web immich-ml
```

Copy the database dump off the guest and take a container/VM snapshot. If `/mnt/photos` is a separate mount, confirm that it has its own backup; a guest snapshot may not include it.

### 2. Update the installer checkout

```bash
su - immich
cd ~/immich-in-lxc
git pull --ff-only
nano .env
exit
```

Set `REPO_TAG` in `.env` to the version you intend to install. Compare it with `example.env` after pulling, but do not overwrite your `INSTALL_DIR`, `UPLOAD_DIR`, accelerator, or proxy settings.

### 3. Refresh host dependencies as root

```bash
cd /home/immich/immich-in-lxc
./pre-install.sh
```

The pre-install stage is safe to rerun. It preserves existing passwords unless password override variables are explicitly supplied.

### 4. Redeploy as the service user

```bash
su - immich
cd ~/immich-in-lxc
./install.sh
exit
```

The installer replaces `/home/immich/app`. It does not delete `UPLOAD_DIR`, but a backup and snapshot are still required safeguards.

### 5. Restart and verify as root

```bash
systemctl daemon-reload
systemctl restart immich-ml immich-web
systemctl --no-pager --full status immich-ml immich-web
curl --fail http://127.0.0.1:2283/api/server/ping
```

If either service fails, do not repeatedly rerun the installer. Capture the logs and follow [Troubleshooting and recovery](docs/troubleshooting-and-recovery.md).

## Optional configurations

- [Storage and filesystem layout](docs/storage-and-layout.md) — mounted disks, local SSD thumbnails, permissions, and what must be backed up
- [Hardware acceleration](docs/hardware-acceleration.md) — NVIDIA CUDA, AMD ROCm, Intel OpenVINO, and transcoding
- [Nginx reverse proxy](docs/nginx-reverse-proxy.md) — HTTPS termination and forwarding to port `2283`
- [Troubleshooting and recovery](docs/troubleshooting-and-recovery.md) — logs, health checks, Debian repository recovery, and older database migrations
- [Testing](docs/testing.md) — fast, full, systemd, Debian 13, and real CUDA Docker tests

## Important boundaries

- Run `pre-install.sh` as root.
- Run `install.sh` as the service user, never as root.
- The installer checkout can be replaced; the deployed app and media paths are separate.
- Never delete `UPLOAD_DIR` during an update.
- Do not expose port `2283` directly to the public internet.
- This is an unofficial community installer. Review Immich release notes before every version upgrade.
