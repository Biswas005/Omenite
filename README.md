# Omenite

Omenite is a custom Bazzite GNOME-based atomic / Bazzite GNOME-derived image for HP Omen laptops. It bakes in the custom `hp-wmi` kernel module, ships GNOME by default, and keeps the repo aligned with the current `ublue-os/image-template` layout.

## What is included

- Bazzite GNOME NVIDIA-based atomic image build
- Custom HP Omen `hp-wmi` module compiled into the image
- Omenite branding and logo assets
- GitHub Actions for OCI image, QCOW2, and Anaconda ISO builds
- Bootc disk-image fixes for `xfs` rootfs and the missing `disk_config/iso.toml` path

## Important paths

- `build_files/hp-wmi.c` — custom driver source
- `build_files/build.sh` — image customization script
- `disk_config/disk.toml` — qcow2/raw image builder config
- `disk_config/iso.toml` — anaconda ISO config used by GitHub Actions

## GitHub secrets

Optional but recommended for image signing:

- `SIGNING_SECRET` — cosign private key for signing published container images
- `COSIGN_PASSWORD` — only needed if `SIGNING_SECRET` contains an encrypted cosign key

Optional for persistent Secure Boot signing of the custom module:

- `MODULE_SIGNING_KEY_B64`
- `MODULE_SIGNING_CRT_B64`
- `MODULE_SIGNING_DER_B64`

If those module-signing secrets are not provided, the build generates a fresh local keypair and embeds the public cert and DER file in the image for later MOK enrollment.

## Notes

The disk-image workflow expects the container image to be published first, then it converts `ghcr.io/<owner>/omenite:latest` into QCOW2 and Anaconda ISO artifacts.


## Installer notes

The Anaconda ISO configuration lives at `disk_config/iso.toml` only.
The installer UI has Storage, Network, Security, Services, Users, Subscription, and Timezone modules enabled.


## Default base image

The repo now defaults to `ghcr.io/ublue-os/bazzite-gnome-nvidia:stable`, so NVIDIA support comes from the base image rather than manual RPM layering in `build.sh`.
