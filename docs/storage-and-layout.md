# Storage and filesystem layout

The installer checkout, deployed application, and photo library are separate on purpose. Keeping those boundaries clear makes upgrades predictable.

## Recommended layout

```text
/home/immich/
├── immich-in-lxc/     installer checkout
├── source/            Immich source used during builds
├── app/               replaceable deployed application
├── geodata/           reverse-geocoding data
├── runtime.env        generated runtime configuration
└── thumbs/            optional local-SSD thumbnail target

/mnt/photos/           persistent mounted media root (UPLOAD_DIR)
```

Use:

```dotenv
INSTALL_DIR=/home/immich
UPLOAD_DIR=/mnt/photos
```

`install.sh` creates these links:

```text
/home/immich/app/upload -> /mnt/photos
/home/immich/app/machine-learning/upload -> /mnt/photos
```

Do not set `INSTALL_DIR` to the checkout directory. The checkout contains only this project's install and update scripts; the systemd services launch the deployed application through `/usr/local/libexec/immich-in-lxc/service-launch.sh`.

## Mount and permission requirements

Mount persistent storage before running `install.sh`. Confirm that the service account can write to it:

```bash
runuser -u immich -- test -w /mnt/photos
runuser -u immich -- touch /mnt/photos/.immich-write-test
rm /mnt/photos/.immich-write-test
```

In an unprivileged LXC, ownership on the host is translated through the container's UID/GID map. Fix permissions at the mount or host mapping rather than making the media directory world-writable.

The `immich` user belongs to the `video` and `render` groups for hardware access. Verify the device group mapping separately when using a GPU.

## Keep thumbnails on local SSD

Immich stores generated thumbnails below `UPLOAD_DIR/thumbs`. To keep originals on a mounted HDD but thumbnails on the container's SSD, create a target and link it into the media root before the first install or before restoring data:

```bash
install -d -o immich -g immich /home/immich/thumbs
runuser -u immich -- ln -s /home/immich/thumbs /mnt/photos/thumbs
```

If `/mnt/photos/thumbs` already exists, move or copy its contents to `/home/immich/thumbs` first, verify the copy, and only then replace the old directory with the symlink. Take a snapshot before doing this.

## What is replaceable

| Path | Role | Backup expectation |
| --- | --- | --- |
| `/home/immich/immich-in-lxc` | Installer checkout | Replaceable from Git |
| `/home/immich/source` | Build source | Replaceable by installer |
| `/home/immich/app` | Deployed application | Replaced on every install/update |
| `/home/immich/runtime.env` | Runtime configuration and DB password | Protect and back up securely |
| `/mnt/photos` | Originals and generated media | Persistent; must be backed up |
| PostgreSQL database | Library metadata and user data | Persistent; must be backed up |

A usable recovery requires both the database and the media tree from compatible points in time. A copy of `/home/immich/app` is not a backup of an Immich library.

## Using a differently named checkout

An existing checkout such as `/home/immich/immich-in-lxc-v2` can run the scripts. The deployment remains under `INSTALL_DIR`, and systemd does not need the checkout to have a particular name after `pre-install.sh` has installed the stable launcher.

The README deliberately uses `/home/immich/immich-in-lxc` as the single standard path so future updates are easy to follow.
