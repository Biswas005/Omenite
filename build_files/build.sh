#!/usr/bin/bash
set -euo pipefail
set -x

KERNEL_VERSION="$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' | head -n1)"
KDIR="/usr/src/kernels/${KERNEL_VERSION}"
BUILD_DIR="/tmp/hp-wmi-build"
SIGN_DIR="/etc/pki/module-signing"

# Do not install NVIDIA RPMs here; the selected Bazzite base already includes NVIDIA integration.
dnf5 install -y \
  akmods \
  elfutils-libelf-devel \
  gcc \
  git \
  just \
  "kernel-devel-${KERNEL_VERSION}" \
  kernel-headers \
  kmod \
  make \
  mokutil \
  openssl \
  toolbox \
  tmux \
  vim-enhanced

mkdir -p /usr/lib/bootc/install
cat > /usr/lib/bootc/install/00-omenite.toml <<'EOT'
[install.filesystem.root]
type = "xfs"
EOT

mkdir -p /usr/share/pixmaps /usr/share/icons/hicolor/scalable/apps
install -m 0644 /ctx/assets/omenite-logo.png /usr/share/pixmaps/omenite-logo.png
install -m 0644 /ctx/assets/omenite-logo.svg /usr/share/icons/hicolor/scalable/apps/omenite.svg
# Common distro-logo aliases so existing lookups stop resolving to Bazzite/Fedora artwork
install -m 0644 /ctx/assets/omenite-logo.png /usr/share/pixmaps/distributor-logo.png || true
install -m 0644 /ctx/assets/omenite-logo.png /usr/share/pixmaps/fedora-logo.png || true
install -m 0644 /ctx/assets/omenite-logo.svg /usr/share/icons/hicolor/scalable/apps/distributor-logo.svg || true
install -m 0644 /ctx/assets/omenite-logo.svg /usr/share/icons/hicolor/scalable/apps/fedora-logo-icon.svg || true
install -m 0644 /ctx/assets/omenite-logo.svg /usr/share/icons/hicolor/scalable/apps/bazzite.svg || true

# Keep Fedora/Bazzite machine-readable identity fields required by bootc-image-builder.
# Only override human-facing branding fields.
if [ -f /usr/lib/os-release ]; then
  sed -i \
    -e 's/^NAME=.*/NAME="Omenite"/' \
    -e 's/^PRETTY_NAME=.*/PRETTY_NAME="Omenite Linux"/' \
    -e 's/^VARIANT=.*/VARIANT="Omenite"/' \
    -e 's/^VARIANT_ID=.*/VARIANT_ID=omenite/' \
    /usr/lib/os-release || true

  if grep -q '^LOGO=' /usr/lib/os-release; then
    sed -i 's/^LOGO=.*/LOGO=omenite/' /usr/lib/os-release
  else
    echo 'LOGO=omenite' >> /usr/lib/os-release
  fi

  if [ -f /etc/os-release ]; then
    cp -f /usr/lib/os-release /etc/os-release
  fi
fi

mkdir -p /etc/anaconda/product.d /usr/share/anaconda/pixmaps
cat > /etc/anaconda/product.d/99-omenite.conf <<'EOT'
[Product]
productName = Omenite
productVersion = 43
productArch = x86_64
bugUrl = https://github.com/Biswas005/Omenite/issues
isFinal = true
EOT
install -m 0644 /ctx/assets/omenite-logo.png /usr/share/anaconda/pixmaps/product-logo.png || true
install -m 0644 /ctx/assets/omenite-logo.png /usr/share/anaconda/pixmaps/sidebar-logo.png || true

mkdir -p /etc/issue.d
cat > /etc/issue.d/10-omenite.issue <<'EOT'
Omenite Linux
Custom Bazzite GNOME-based atomic image for HP Omen systems.
EOT

mkdir -p "${SIGN_DIR}"
if [ -f /ctx/build_files/module-signing.key ] && \
   [ -f /ctx/build_files/module-signing.crt ] && \
   [ -f /ctx/build_files/module-signing.der ]; then
  install -m 0600 /ctx/build_files/module-signing.key "${SIGN_DIR}/module-signing.key"
  install -m 0644 /ctx/build_files/module-signing.crt "${SIGN_DIR}/module-signing.crt"
  install -m 0644 /ctx/build_files/module-signing.der "${SIGN_DIR}/module-signing.der"
else
  openssl genpkey -algorithm RSA \
    -out "${SIGN_DIR}/module-signing.key" \
    -pkeyopt rsa_keygen_bits:2048
  openssl req -new -x509 \
    -key "${SIGN_DIR}/module-signing.key" \
    -out "${SIGN_DIR}/module-signing.crt" \
    -days 3650 \
    -subj "/CN=Omenite Module Signer/"
  openssl x509 \
    -in "${SIGN_DIR}/module-signing.crt" \
    -outform DER \
    -out "${SIGN_DIR}/module-signing.der"
  chmod 0600 "${SIGN_DIR}/module-signing.key"
  chmod 0644 "${SIGN_DIR}/module-signing.crt" "${SIGN_DIR}/module-signing.der"
fi

test -d "${KDIR}"

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
cp /ctx/build_files/hp-wmi.c "${BUILD_DIR}/"

cat > "${BUILD_DIR}/Makefile" <<EOT
obj-m += hp-wmi.o

all:
	\$(MAKE) -C ${KDIR} M=\$(PWD) modules

clean:
	\$(MAKE) -C ${KDIR} M=\$(PWD) clean
EOT

make -C "${KDIR}" M="${BUILD_DIR}" modules

if [ -x "${KDIR}/scripts/sign-file" ]; then
  "${KDIR}/scripts/sign-file" sha256 \
    "${SIGN_DIR}/module-signing.key" \
    "${SIGN_DIR}/module-signing.crt" \
    "${BUILD_DIR}/hp-wmi.ko"
fi

mkdir -p "/usr/lib/modules/${KERNEL_VERSION}/extra"
install -m 0644 "${BUILD_DIR}/hp-wmi.ko" "/usr/lib/modules/${KERNEL_VERSION}/extra/hp-wmi.ko"
depmod -a "${KERNEL_VERSION}"

mkdir -p /etc/modules-load.d /etc/modprobe.d
cat > /etc/modules-load.d/hp-wmi.conf <<'EOT'
hp-wmi
EOT

cat > /etc/modprobe.d/omenite-hp-wmi.conf <<'EOT'
# Prefer the custom Omenite hp-wmi module from /usr/lib/modules/*/extra.
EOT

mkdir -p /usr/share/ublue-os/just
cat > /usr/share/ublue-os/just/60-omenite.just <<'EOT'
enroll-omenite-mok:
	#!/usr/bin/bash
	set -euo pipefail
	sudo mokutil --import /etc/pki/module-signing/module-signing.der

check-omenite-mok:
	#!/usr/bin/bash
	set -euo pipefail
	mokutil --list-enrolled | grep -i 'Omenite Module Signer' || true

test-omenite-hp-wmi:
	#!/usr/bin/bash
	set -euo pipefail
	sudo modprobe -r hp-wmi || true
	sudo modprobe hp-wmi
	modinfo hp-wmi | sed -n '1,20p'
EOT

systemctl enable podman.socket
