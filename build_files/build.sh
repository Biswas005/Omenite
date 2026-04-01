#!/usr/bin/bash
set -euo pipefail
set -x

echo "🚀 Omenite build script starting..."

# Expect this Containerfile layout:
#   COPY build_files /ctx/build_files
#   COPY assets /ctx/assets
CTX_BUILD="/ctx/build_files"
CTX_ASSETS="/ctx/assets"
SECRET_PATH="/tmp/secrets"

HP_WMI_SRC="${CTX_BUILD}/hp-wmi.c"
LOGO_PNG="${CTX_ASSETS}/omenite-logo.png"
LOGO_SVG="${CTX_ASSETS}/omenite-logo.svg"

SIGNING_DIR="/etc/pki/module-signing"
BUILD_DIR="/tmp/hp-wmi-build"

# Base image hint only for logging; do not rely on it for core logic
BASE_IMAGE_VALUE="${BASE_IMAGE:-unknown}"
echo "📦 Base image: ${BASE_IMAGE_VALUE}"

NVIDIA_BASE=false
if [[ "${BASE_IMAGE_VALUE}" == *"nvidia"* ]]; then
    NVIDIA_BASE=true
    echo "🟢 NVIDIA base image detected"
else
    echo "🟡 Non-NVIDIA base image detected"
fi

# Detect kernel version
KERNEL_VERSION="$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' | head -n1)"
echo "🧠 Detected kernel version: ${KERNEL_VERSION}"

KERNEL_SRC_DIR="/usr/src/kernels/${KERNEL_VERSION}"
if [[ ! -d "${KERNEL_SRC_DIR}" ]]; then
    KERNEL_SRC_DIR="$(find /usr/src/kernels -mindepth 1 -maxdepth 1 -type d | head -n1 || true)"
fi

if [[ -z "${KERNEL_SRC_DIR}" || ! -d "${KERNEL_SRC_DIR}" ]]; then
    echo "❌ ERROR: Kernel source directory not found"
    exit 1
fi
echo "📚 Using kernel source from: ${KERNEL_SRC_DIR}"

# Install packages needed for build and runtime extras
# Do not manually install NVIDIA driver RPMs on a nvidia base image.
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
    tmux \
    toolbox \
    vim-enhanced \
    nvidia-container-toolkit \
    firefox

# Optional app installs
echo "📦 Installing Visual Studio Code repo..."
rpm --import https://packages.microsoft.com/keys/microsoft.asc
cat > /etc/yum.repos.d/vscode.repo <<'EOF'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
autorefresh=1
type=rpm-md
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF
dnf5 install -y code

# TLP power setup
dnf5 remove -y tuned tuned-ppd power-profiles-daemon || true
dnf5 -y install "https://repo.linrunner.de/fedora/tlp/repos/releases/tlp-release.fc$(rpm -E %fedora).noarch.rpm"
dnf5 install -y tlp tlp-pd tlp-rdw
systemctl mask power-profiles-daemon.service || true

# bootc rootfs config for disk builders
mkdir -p /usr/lib/bootc/install
cat > /usr/lib/bootc/install/00-omenite.toml <<'EOF'
[install.filesystem.root]
type = "xfs"
EOF

# Branding assets
mkdir -p /usr/share/pixmaps /usr/share/icons/hicolor/scalable/apps
install -m 0644 "${LOGO_PNG}" /usr/share/pixmaps/omenite-logo.png
install -m 0644 "${LOGO_SVG}" /usr/share/icons/hicolor/scalable/apps/omenite.svg

# Alias common logo lookups so Bazzite/Fedora artwork gets overridden
install -m 0644 "${LOGO_PNG}" /usr/share/pixmaps/distributor-logo.png || true
install -m 0644 "${LOGO_SVG}" /usr/share/icons/hicolor/scalable/apps/distributor-logo.svg || true
install -m 0644 "${LOGO_SVG}" /usr/share/icons/hicolor/scalable/apps/bazzite.svg || true
install -m 0644 "${LOGO_SVG}" /usr/share/icons/hicolor/scalable/apps/fedora-logo-icon.svg || true
install -m 0644 "${LOGO_PNG}" /usr/share/pixmaps/fedora-logo.png || true

# Keep machine-readable distro identity compatible for bootc-image-builder.
# Only change human-facing branding.
if [[ -f /usr/lib/os-release ]]; then
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
fi

if [[ -e /etc/os-release ]] && [[ "$(readlink -f /etc/os-release)" != "$(readlink -f /usr/lib/os-release)" ]]; then
    cp -f /usr/lib/os-release /etc/os-release
fi

mkdir -p /etc/issue.d
cat > /etc/issue.d/10-omenite.issue <<'EOF'
Omenite Linux
Custom Bazzite GNOME-based atomic image for HP Omen systems.
EOF

# Anaconda product branding
mkdir -p /etc/anaconda/product.d /usr/share/anaconda/pixmaps
install -m 0644 "${LOGO_PNG}" /usr/share/anaconda/pixmaps/product-logo.png || true
install -m 0644 "${LOGO_PNG}" /usr/share/anaconda/pixmaps/sidebar-logo.png || true
cat > /etc/anaconda/product.d/99-omenite.conf <<'EOF'
[Product]
productName = Omenite
productVersion = 43
productArch = x86_64
bugUrl = https://github.com/Biswas005/Omenite/issues
isFinal = true
EOF

# Validate required source
if [[ ! -f "${HP_WMI_SRC}" ]]; then
    echo "❌ ERROR: Required source file '${HP_WMI_SRC}' is missing"
    exit 1
fi

# Prepare build dir
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
cp "${HP_WMI_SRC}" "${BUILD_DIR}/hp-wmi.c"

# Signing material: prefer decoded secrets, otherwise generate temporary keys
mkdir -p "${SIGNING_DIR}"

USING_PERSISTENT_KEYS=false
if [[ -f "${SECRET_PATH}/module-signing.key" && -f "${SECRET_PATH}/module-signing.crt" && -f "${SECRET_PATH}/module-signing.der" ]]; then
    echo "✅ Found decoded module-signing secrets in ${SECRET_PATH}"
    install -m 0600 "${SECRET_PATH}/module-signing.key" "${SIGNING_DIR}/module-signing.key"
    install -m 0644 "${SECRET_PATH}/module-signing.crt" "${SIGNING_DIR}/module-signing.crt"
    install -m 0644 "${SECRET_PATH}/module-signing.der" "${SIGNING_DIR}/module-signing.der"
    USING_PERSISTENT_KEYS=true
else
    echo "⚠️ No decoded module-signing secrets found; generating temporary keys"
    openssl genpkey -algorithm RSA -out "${SIGNING_DIR}/module-signing.key" -pkeyopt rsa_keygen_bits:2048
    openssl req -new -x509 \
        -key "${SIGNING_DIR}/module-signing.key" \
        -out "${SIGNING_DIR}/module-signing.crt" \
        -days 3650 \
        -subj "/CN=Omenite Module Signer TEMP/"
    openssl x509 -in "${SIGNING_DIR}/module-signing.crt" -outform DER -out "${SIGNING_DIR}/module-signing.der"
    chmod 0600 "${SIGNING_DIR}/module-signing.key"
    chmod 0644 "${SIGNING_DIR}/module-signing.crt" "${SIGNING_DIR}/module-signing.der"
fi

echo "📜 Certificate subject:"
openssl x509 -in "${SIGNING_DIR}/module-signing.crt" -noout -subject || true
echo "🔑 Certificate fingerprint:"
openssl x509 -in "${SIGNING_DIR}/module-signing.crt" -fingerprint -noout || true

# Build hp-wmi
cd "${BUILD_DIR}"
cat > Makefile <<'EOF'
obj-m += hp-wmi.o

default:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

.PHONY: default clean
EOF

export KDIR="${KERNEL_SRC_DIR}"

echo "🔨 Building hp-wmi kernel module..."
make KDIR="${KERNEL_SRC_DIR}"

if [[ ! -f "${BUILD_DIR}/hp-wmi.ko" ]]; then
    echo "❌ ERROR: hp-wmi.ko not found after build"
    ls -la "${BUILD_DIR}"
    exit 1
fi

# Sign hp-wmi
if [[ -x "${KERNEL_SRC_DIR}/scripts/sign-file" ]]; then
    echo "🔏 Signing hp-wmi kernel module..."
    "${KERNEL_SRC_DIR}/scripts/sign-file" sha256 \
        "${SIGNING_DIR}/module-signing.key" \
        "${SIGNING_DIR}/module-signing.crt" \
        "${BUILD_DIR}/hp-wmi.ko"
else
    echo "⚠️ sign-file not found; hp-wmi.ko will remain unsigned"
fi

# Install only into the current kernel extra directory
EXTRA_DIR="/lib/modules/${KERNEL_VERSION}/extra"
mkdir -p "${EXTRA_DIR}"
install -m 0644 "${BUILD_DIR}/hp-wmi.ko" "${EXTRA_DIR}/hp-wmi.ko"
depmod -a "${KERNEL_VERSION}"

# Module loading config
mkdir -p /etc/modules-load.d /etc/modprobe.d
cat > /etc/modules-load.d/hp-wmi.conf <<'EOF'
hp-wmi
EOF

cat > /etc/modprobe.d/omenite-hp-wmi.conf <<'EOF'
# Omenite custom hp-wmi module configuration
EOF

# NVIDIA modules: only sign what already exists on nvidia base image
if [[ "${NVIDIA_BASE}" == true ]]; then
    echo "🟢 Signing existing NVIDIA modules if present..."
    NVIDIA_MODULES_FOUND=false
    while IFS= read -r -d '' ko_file; do
        echo "Signing NVIDIA module: ${ko_file}"
        if [[ -x "${KERNEL_SRC_DIR}/scripts/sign-file" ]]; then
            "${KERNEL_SRC_DIR}/scripts/sign-file" sha256 \
                "${SIGNING_DIR}/module-signing.key" \
                "${SIGNING_DIR}/module-signing.crt" \
                "${ko_file}"
            NVIDIA_MODULES_FOUND=true
        fi
    done < <(find "/lib/modules/${KERNEL_VERSION}" "/usr/lib/modules/${KERNEL_VERSION}" \
        -type f \( -name 'nvidia*.ko' -o -name 'nvidia*.ko.xz' -o -name 'nvidia*.ko.zst' \) -print0 2>/dev/null || true)

    depmod -a "${KERNEL_VERSION}" || true

    if [[ "${NVIDIA_MODULES_FOUND}" == true ]]; then
        echo "✅ NVIDIA modules signed"
    else
        echo "⚠️ No NVIDIA modules found to sign during build"
    fi
fi

# Services
systemctl enable podman.socket
systemctl enable tlp.service || true

# ujust helpers
mkdir -p /usr/share/ublue-os/just
cat > /usr/share/ublue-os/just/60-omenite.just <<'EOF'
enroll-omenite-mok:
	#!/usr/bin/bash
	set -euo pipefail
	sudo mokutil --import /etc/pki/module-signing/module-signing.der

check-omenite-mok:
	#!/usr/bin/bash
	set -euo pipefail
	mokutil --list-enrolled | grep -i 'Omenite Module Signer' || true

remove-omenite-mok:
	#!/usr/bin/bash
	set -euo pipefail
	sudo mokutil --delete /etc/pki/module-signing/module-signing.der

test-omenite-hp-wmi:
	#!/usr/bin/bash
	set -euo pipefail
	sudo modprobe -r hp-wmi || true
	sudo modprobe hp-wmi
	modinfo hp-wmi | sed -n '1,20p'

test-omenite-nvidia:
	#!/usr/bin/bash
	set -euo pipefail
	modinfo nvidia | sed -n '1,20p' || true
	modinfo nvidia_drm | sed -n '1,20p' || true
EOF

# Clean temporary build artifacts
cd /
rm -rf "${BUILD_DIR}"

# Best-effort private key cleanup outside final persistent location
if [[ -f "${SECRET_PATH}/module-signing.key" ]]; then
    shred -u "${SECRET_PATH}/module-signing.key" || rm -f "${SECRET_PATH}/module-signing.key"
fi

echo "✅ Build completed successfully"
echo "Base Image: ${BASE_IMAGE_VALUE}"
echo "Kernel: ${KERNEL_VERSION}"
if [[ "${NVIDIA_BASE}" == true ]]; then
    echo "NVIDIA: using NVIDIA base image"
else
    echo "NVIDIA: non-NVIDIA base image"
fi
if [[ "${USING_PERSISTENT_KEYS}" == true ]]; then
    echo "Module signing keys: persistent"
else
    echo "Module signing keys: temporary"
fi
echo "MOK certificate: /etc/pki/module-signing/module-signing.der"
echo "ujust helper: /usr/share/ublue-os/just/60-omenite.just"