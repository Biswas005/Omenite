# Omenite

Omenite is a custom Bazzite GNOME-based atomic / Bazzite GNOME-derived OS image optimized specifically for HP Omen laptops. It bakes in the custom `hp-wmi` kernel module out-of-the-box, ships with GNOME by default, and keeps the repository aligned with the current `ublue-os/image-template` layout.

## Features

- **Optimized for HP Omen Laptops:** Pre-compiled and integrated `hp-wmi` driver for full hardware control.
- **NVIDIA Support Included:** Built upon the Bazzite GNOME NVIDIA-based atomic image to ensure seamless GPU support.
- **Custom Branding:** Bespoke Omenite logos, Fastfetch configs, and boot splash screens to replace standard Bazzite branding.
- **Automated ISO Generation:** GitHub Actions automatically builds the OCI image, QCOW2 disk images, and a bootable Anaconda ISO.
- **Secure Boot Ready:** Generates and embeds Secure Boot signing keys for the custom `hp-wmi` module, ready for MOK enrollment upon installation.
- **Bootc Enhancements:** Built-in disk-image fixes for `xfs` rootfs and proper ISO configurations.

## Installation

### Method 1: Fresh Installation via ISO (Recommended)
You can download the bootable Anaconda ISO from the GitHub Actions artifacts once the CI pipeline finishes building.
1. Flash the ISO to a USB drive.
2. Boot from the USB drive.
3. Install the OS via the Anaconda installer.
4. On first boot, enroll the MOK (Machine Owner Key) if prompted, to allow the `hp-wmi` module to load with Secure Boot enabled.

### Method 2: Rebase from an existing Atomic Fedora/Bazzite Install
If you are already running an rpm-ostree based system (Silverblue, Kinoite, Bazzite), you can rebase directly:
```bash
rpm-ostree rebase ostree-unverified-registry:ghcr.io/biswas005/omenite:latest
systemctl reboot
```

## Important Paths & Structure

- `build_files/hp-wmi.c` — The custom driver source code for HP Omen laptops.
- `build_files/build.sh` — The main image customization and compilation script.
- `disk_config/disk.toml` — Configuration for qcow2/raw image builders.
- `disk_config/iso.toml` — Configuration for the Anaconda ISO builder used by GitHub Actions.
- `Containerfile` — The main OCI build instructions defining the layers, branding, and package installations.

## GitHub Secrets

For maintaining your own fork, the following GitHub repository secrets are optional but recommended for image signing:

- `SIGNING_SECRET` — cosign private key for signing published container images.
- `COSIGN_PASSWORD` — only needed if `SIGNING_SECRET` contains an encrypted cosign key.

Optional secrets for persistent Secure Boot signing of the custom module:
- `MODULE_SIGNING_KEY_B64`
- `MODULE_SIGNING_CRT_B64`
- `MODULE_SIGNING_DER_B64`

*Note: If those module-signing secrets are not provided, the build generates a fresh local keypair and embeds the public cert and DER file in the image for later MOK enrollment.*

## Licensing and Compliance

This project is licensed under the **Apache License 2.0**. 

However, please note that Omenite is a Linux distribution that aggregates various software components with different licenses:
- **`hp-wmi.c`** and other compiled Linux kernel modules are licensed under the **GPL** (General Public License).
- The base image (Bazzite/Fedora) includes software under various open-source licenses (GPL, MIT, BSD, etc.).

The Apache 2.0 license applies specifically to the build scripts, configuration files, branding assets, and custom integration code provided in this repository. This dual-licensing nature is standard for Linux distribution build repositories and is fully compliant.

## Acknowledgements

- Built using [BlueBuild](https://blue-build.org/) and the [ublue-os/image-template](https://github.com/ublue-os/image-template).
- Based on [Bazzite](https://bazzite.gg/).
