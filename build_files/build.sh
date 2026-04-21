#!/bin/bash
set -ouex pipefail

echo "🚀 Omenite Build Script Starting..."
echo "📦 Base image: ${BASE_IMAGE:-unknown}"

# ================================
# 🧠 Kernel Detection
# ================================
KERNEL_VERSION=$(rpm -q kernel --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}')
echo "Detected kernel version: $KERNEL_VERSION"

KERNEL_SRC_DIR="/usr/src/kernels/$KERNEL_VERSION"
if [ ! -d "$KERNEL_SRC_DIR" ]; then
    KERNEL_SRC_DIR=$(find /usr/src/kernels -maxdepth 1 -type d | head -1)
fi

echo "Using kernel source: $KERNEL_SRC_DIR"

# ================================
# 📦 Install Dependencies
# ================================
dnf5 install -y \
    kernel-devel kernel-headers gcc make kmod \
    openssl mokutil elfutils-libelf-devel tmux \
    nvidia-container-toolkit

# ================================
# 🎨 Omenite Branding
# ================================
echo "Applying Omenite branding..."

mkdir -p /usr/share/omenite
cp /ctx/assets/omenite-logo.png /usr/share/omenite/
cp /ctx/assets/omenite-logo.svg /usr/share/omenite/

# Replace system logos (common locations)
LOGO_TARGETS=(
    "/usr/share/pixmaps/fedora-logo.png"
    "/usr/share/pixmaps/system-logo.png"
    "/usr/share/anaconda/pixmaps/fedora-logo.png"
)

for target in "${LOGO_TARGETS[@]}"; do
    if [ -f "$target" ]; then
        cp /ctx/assets/omenite-logo.png "$target"
        echo "Replaced: $target"
    fi
done

# OS Release Branding
cat > /etc/os-release <<EOF
NAME="Omenite"
VERSION="1.0"
ID=omenite
ID_LIKE=fedora
PRETTY_NAME="Omenite Linux"
ANSI_COLOR="0;35"
HOME_URL="https://github.com/yourrepo/omenite"
DOCUMENTATION_URL="https://github.com/yourrepo/omenite"
SUPPORT_URL="https://github.com/yourrepo/omenite/issues"
BUG_REPORT_URL="https://github.com/yourrepo/omenite/issues"
EOF

echo "✅ Branding applied"

# ================================
# 🔐 Module Signing Setup
# ================================
mkdir -p /etc/pki/module-signing

cp /ctx/module-signing.key /etc/pki/module-signing/
cp /ctx/module-signing.crt /etc/pki/module-signing/
cp /ctx/module-signing.der /etc/pki/module-signing/

chmod 600 /etc/pki/module-signing/module-signing.key

# ================================
# 🔧 Build hp-wmi Module
# ================================
BUILD_DIR="/tmp/hp-wmi-build"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

cp /ctx/hp-wmi.c .

cat > Makefile << 'EOF'
obj-m += hp-wmi.o
default:
	$(MAKE) -C $(KDIR) M=$(PWD) modules
clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
EOF

export KDIR="$KERNEL_SRC_DIR"

make

# Sign module
$KERNEL_SRC_DIR/scripts/sign-file sha256 \
    /etc/pki/module-signing/module-signing.key \
    /etc/pki/module-signing/module-signing.crt \
    hp-wmi.ko

# Install module
mkdir -p /lib/modules/$KERNEL_VERSION/extra
cp hp-wmi.ko /lib/modules/$KERNEL_VERSION/extra/

depmod -a

echo "hp-wmi installed and signed"

# ================================
# 🧹 Cleanup Keys
# ================================
shred -u /etc/pki/module-signing/module-signing.key || true

# ================================
# ⚙️ Enable Services
# ================================
systemctl enable podman.socket

# ================================
# 🧾 Final Summary
# ================================
echo ""
echo "=============================="
echo "✅ Omenite Build Complete"
echo "=============================="
echo "Distro: Omenite"
echo "Kernel: $KERNEL_VERSION"
echo "GPU: Toolkit enabled (no drivers)"
echo "Module: hp-wmi signed"
echo ""
