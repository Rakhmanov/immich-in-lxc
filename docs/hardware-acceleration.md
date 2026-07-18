# Hardware acceleration

Complete GPU pass-through and verify the device inside the LXC guest before enabling an accelerated Immich build. Start with the CPU installation from the README if you do not need acceleration.

The `isCUDA` setting controls the machine-learning dependency set:

| Value | Machine learning backend |
| --- | --- |
| `false` | CPU |
| `true` | NVIDIA CUDA |
| `rocm` | AMD ROCm |
| `openvino` | Intel OpenVINO |

Video transcoding is configured separately in the Immich administration interface.

## NVIDIA CUDA

First make the NVIDIA GPU available inside the guest. `nvidia-smi` must succeed there.

After cloning the installer but before running `install.sh`, install the supported CUDA user-space runtime as root:

```bash
cd /home/immich/immich-in-lxc
./scripts/install-cuda-runtime.sh
```

For a first install, the same helper may be run from `/opt/immich-in-lxc-bootstrap` immediately before `pre-install.sh`.

Set this in `.env`:

```dotenv
isCUDA=true
```

Then run the normal `install.sh` procedure as the `immich` user.

The helper installs CUDA 12.9 user-space libraries and cuDNN 9.10.2.21 for Immich v3.0.2. Debian 13 is a special case: NVIDIA's Debian 13 repository starts at CUDA 13, so the helper temporarily uses NVIDIA's signed Ubuntu 24.04 CUDA 12 user-space packages and removes that foreign repository afterward. It does not install a guest kernel driver or the CUDA compiler toolkit.

Real CUDA inference with CPU fallback disabled is covered by the optional Docker test described in [Testing](testing.md).

## AMD ROCm

Pass the AMD render device into the guest and ensure the `immich` user can access the `video` and `render` groups. Set:

```dotenv
isCUDA=rocm
```

Then use the normal install procedure. ROCm host and LXC device setup varies by GPU, kernel, and Proxmox configuration and is not automated by this repository. Treat the backend as unverified until an actual ML job completes and logs show the ROCm execution provider.

## Intel OpenVINO

Pass the Intel GPU/render device into the guest, then run as root:

```bash
cd /home/immich/immich-in-lxc
./dep-intel.sh
```

Set:

```dotenv
isCUDA=openvino
```

Then use the normal install procedure. This path has community success reports but is not part of the repository owner's current full test matrix.

## Hardware video transcoding

Machine-learning acceleration does not automatically select a video encoder. After Immich starts, open:

`Administration > Settings > Video Transcoding Settings > Hardware Acceleration > Acceleration API`

Choose the API appropriate for the passed-through device, such as NVENC for NVIDIA or Quick Sync for Intel. Submit a real video transcoding job and inspect the Immich logs and device utilization; the presence of a device alone does not prove hardware transcoding is active.
