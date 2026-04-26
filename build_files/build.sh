#!/bin/bash
set -ouex pipefail

echo "🚀 Build script starting..."
echo "📦 Base image: ${BASE_IMAGE:-unknown}"

# Detect and verify kernel version
KERNEL_VERSION=$(rpm -q kernel --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}')
echo "🧠 Detected kernel version: $KERNEL_VERSION"

KERNEL_SRC_DIR="/usr/src/kernels/$KERNEL_VERSION"
if [ ! -d "$KERNEL_SRC_DIR" ]; then
    KERNEL_SRC_DIR=$(find /usr/src/kernels -maxdepth 1 -type d -name "*" | grep -v "^/usr/src/kernels$" | head -1)
    if [ -z "$KERNEL_SRC_DIR" ] || [ ! -d "$KERNEL_SRC_DIR" ]; then
        echo "❌ ERROR: Kernel source directory not found"
        exit 1
    fi
fi
echo "📚 Using kernel source from: $KERNEL_SRC_DIR"

BUILD_DIR="/tmp/hp-wmi-build"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Copy source files from /ctx
for file in hp-wmi.c; do
    if [ ! -f "/ctx/$file" ]; then
        echo "❌ ERROR: Required source file '/ctx/$file' is missing"
        exit 1
    fi
    cp "/ctx/$file" .
done

# Look for secrets in /tmp/secrets (created by Dockerfile)
SECRET_PATH="/tmp/secrets"
if [ -f "$SECRET_PATH/module-signing.key" ] && \
   [ -f "$SECRET_PATH/module-signing.crt" ] && \
   [ -f "$SECRET_PATH/module-signing.der" ]; then

    echo "✅ Found decoded secrets in $SECRET_PATH"

    cp "$SECRET_PATH/module-signing.key" .
    cp "$SECRET_PATH/module-signing.crt" .
    cp "$SECRET_PATH/module-signing.der" .

    chmod 600 module-signing.key

    echo "✅ Copied decoded module signing secrets successfully."
else
    echo "❌ ERROR: Module signing secrets not found in $SECRET_PATH!"
    ls -la "$SECRET_PATH/" 2>/dev/null || echo "Directory doesn't exist"
    exit 1
fi

# Create target dir and copy decoded files
mkdir -p /etc/pki/module-signing/
cp module-signing.key /etc/pki/module-signing/
cp module-signing.crt /etc/pki/module-signing/
cp module-signing.der /etc/pki/module-signing/

chmod 600 /etc/pki/module-signing/module-signing.key
chmod 644 /etc/pki/module-signing/module-signing.crt
chmod 644 /etc/pki/module-signing/module-signing.der

echo "✅ Copied decoded keys and certs to /etc/pki/module-signing/"

# --- Persistent Key Setup ---
setup_github_secrets_keys() {
    echo "🔐 Validating module signing keys in /etc/pki/module-signing/..."

    SIGNING_DIR="/etc/pki/module-signing"

    for file in module-signing.key module-signing.crt module-signing.der; do
        if [ ! -f "$SIGNING_DIR/$file" ]; then
            echo "❌ ERROR: Required file '$SIGNING_DIR/$file' not found!"
            echo "Available files in $SIGNING_DIR:"
            ls -la "$SIGNING_DIR/" 2>/dev/null || echo "Directory doesn't exist"
            exit 1
        fi
    done

    if [ ! -r "$SIGNING_DIR/module-signing.key" ]; then
        echo "❌ ERROR: module-signing.key is not readable"
        exit 1
    fi

    echo "✅ All module signing keys validated successfully in $SIGNING_DIR"
}

# 🔧 Invoke the secrets setup
setup_github_secrets_keys || exit 1

# Install base packages
echo "Installing build dependencies..."
dnf5 install -y kernel-devel kernel-headers gcc make kmod openssl mokutil elfutils-libelf-devel tmux

# Persistent Key Management
############################

echo "Setting up persistent module signing keys..."

if setup_github_secrets_keys; then
    echo "✓ Using persistent keys - users won't need to re-enroll MOK after updates"
    USING_PERSISTENT_KEYS=true
else
    echo "⚠️  Using temporary keys - users will need to re-enroll MOK after each update"
    USING_PERSISTENT_KEYS=false

    if [ ! -f "/etc/pki/module-signing/module-signing.key" ]; then
        echo "Generating temporary module signing keys..."
        mkdir -p /etc/pki/module-signing/
        cd /etc/pki/module-signing/

        BUILD_TIMESTAMP=$(date +%Y%m%d-%H%M%S)

        openssl genpkey -algorithm RSA -out module-signing.key -pkeyopt rsa_keygen_bits:2048

        openssl req -new -x509 -key module-signing.key -out module-signing.crt -days 3650 \
            -subj "/CN=Bazzite Omen Module Signer TEMP-${BUILD_TIMESTAMP}/"

        openssl x509 -in module-signing.crt -outform DER -out module-signing.der

        chmod 600 module-signing.key
        chmod 644 module-signing.crt module-signing.der

        echo "Generated temporary signing keys in PEM and DER formats"
    fi
fi

# Show key information for debugging
echo "Certificate Information:"
echo "Subject: $(openssl x509 -in /etc/pki/module-signing/module-signing.crt -noout -subject)"
echo "Fingerprint: $(openssl x509 -in /etc/pki/module-signing/module-signing.crt -fingerprint -noout)"

# Build Custom HP-WMI Module
#############################

cd "$BUILD_DIR"

cat > Makefile << 'MAKEFILE_EOF'
obj-m += hp-wmi.o

default:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

.PHONY: default clean
MAKEFILE_EOF

export KDIR="$KERNEL_SRC_DIR"

echo "Building hp-wmi kernel module..."
echo "Using KDIR: $KDIR"
if ! make KDIR="$KERNEL_SRC_DIR"; then
    echo "ERROR: Failed to build hp-wmi module"
    echo "Makefile contents:"
    cat Makefile
    echo "Current directory: $(pwd)"
    echo "Files in directory:"
    ls -la
    exit 1
fi

if [ ! -f "hp-wmi.ko" ]; then
    echo "ERROR: hp-wmi.ko not found after build"
    echo "Files in build directory:"
    ls -la
    exit 1
fi

# Sign the kernel module
echo "Signing hp-wmi kernel module..."
if [ -f "$KERNEL_SRC_DIR/scripts/sign-file" ]; then
    $KERNEL_SRC_DIR/scripts/sign-file sha256 \
        /etc/pki/module-signing/module-signing.key \
        /etc/pki/module-signing/module-signing.crt \
        hp-wmi.ko
    echo "Module signed successfully"
else
    echo "WARNING: Module signing script not found - module will be unsigned"
fi

echo "Successfully built hp-wmi.ko"

# Install the module
echo "Installing hp-wmi kernel module..."
MODULE_INSTALLED=false

for module_path in $(find /lib/modules -name "hp-wmi.ko*" 2>/dev/null); do
    echo "Backing up existing module: $module_path"
    cp "$module_path" "$module_path.backup"
    echo "Replacing module: $module_path"
    cp hp-wmi.ko "$module_path"
    MODULE_INSTALLED=true
done

if [ "$MODULE_INSTALLED" = false ]; then
    EXTRA_DIR="/lib/modules/$KERNEL_VERSION/extra"
    mkdir -p "$EXTRA_DIR"
    cp hp-wmi.ko "$EXTRA_DIR/"
    echo "Installed hp-wmi.ko to $EXTRA_DIR/"
fi

echo "Updating module dependencies..."
depmod -a "$KERNEL_VERSION"

echo "Creating module configuration..."
cat > /etc/modules-load.d/hp-wmi.conf << 'MODULE_CONF_EOF'
# Load HP WMI module at boot
hp-wmi
MODULE_CONF_EOF

cat > /etc/modprobe.d/hp-wmi.conf << 'MODPROBE_CONF_EOF'
# HP WMI module configuration
# Add any module parameters here if needed
options hp-wmi parameter=value
MODPROBE_CONF_EOF

# Clean up build directory
cd /
rm -rf "$BUILD_DIR"

echo "hp-wmi module installation completed successfully!"

# Securely delete private key files after use
echo "🧹 Cleaning up private key files..."

if [ -f "$BUILD_DIR/module-signing.key" ]; then
    shred -u "$BUILD_DIR/module-signing.key" || rm -f "$BUILD_DIR/module-signing.key"
    echo "✅ Deleted build directory private key securely."
fi

if [ -f "/tmp/secrets/module-signing.key" ]; then
    shred -u "/tmp/secrets/module-signing.key" || rm -f "/tmp/secrets/module-signing.key"
    echo "✅ Deleted /tmp/secrets private key securely."
fi

echo "🔒 Private key cleanup completed."
echo "📋 Certificate files (.crt and .der) preserved for MOK enrollment."

# Install Visual Studio Code
##############################

echo "Installing Visual Studio Code..."
rpm --import https://packages.microsoft.com/keys/microsoft.asc

cat > /etc/yum.repos.d/vscode.repo << 'VSCODE_REPO_EOF'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
autorefresh=1
type=rpm-md
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
VSCODE_REPO_EOF

dnf5 install -y code
echo "Visual Studio Code installed successfully!"

# Install Firefox
dnf5 install -y firefox

# Replace power-profiles-daemon → TLP
dnf5 remove -y tuned tuned-ppd power-profiles-daemon

dnf5 -y install https://repo.linrunner.de/fedora/tlp/repos/releases/tlp-release.fc$(rpm -E %fedora).noarch.rpm
dnf5 install -y tlp tlp-pd tlp-rdw
rpm-ostree install toolbox

systemctl mask power-profiles-daemon.service || true

# Enable services
systemctl enable podman.socket

# Create ujust recipe for MOK enrollment
echo "Creating ujust recipe for MOK enrollment..."
mkdir -p /usr/share/ublue-os/just

cat > /usr/share/ublue-os/just/60-hp-wmi-mok.just << 'UJUST_RECIPE_EOF'
# HP WMI Module Signing and MOK Management

# Enroll HP WMI module signing certificate in MOK (Machine Owner Key) database
enroll-hp-wmi-mok:
#!/usr/bin/bash
set -euo pipefail

MOK_KEY="/etc/pki/module-signing/module-signing.der"

if [ ! -f "$MOK_KEY" ]; then
    echo "ERROR: MOK certificate not found at $MOK_KEY"
    echo "Please ensure the hp-wmi module build script has been run first."
    exit 1
fi

echo "Enrolling HP WMI module signing certificate in MOK database..."
echo "You will be prompted to set a password for MOK enrollment."
echo "Remember this password - you'll need it during the next boot."
echo ""

if sudo mokutil --import "$MOK_KEY"; then
    echo ""
    echo "SUCCESS: Certificate enrolled in MOK database."
    echo ""
    echo "NEXT STEPS:"
    echo "1. Reboot your system: sudo systemctl reboot"
    echo "2. During boot, you'll see a blue MOK Manager screen"
    echo "3. Select 'Enroll MOK' -> 'Continue' -> 'Yes'"
    echo "4. Enter the password you just set"
    echo "5. Select 'Reboot'"
    echo ""
    echo "After reboot, your custom hp-wmi module will load without issues."
else
    echo "ERROR: Failed to enroll certificate"
    exit 1
fi

# Check MOK enrollment status
check-hp-wmi-mok:
#!/usr/bin/bash
set -euo pipefail

echo "Checking MOK database for HP WMI certificate..."

if mokutil --list-enrolled | grep -q "Bazzite Omen Module Signer"; then
    echo "✓ HP WMI module signing certificate is enrolled in MOK database"
else
    echo "✗ HP WMI module signing certificate is NOT enrolled in MOK database"
    echo "Run 'ujust enroll-hp-wmi-mok' to enroll it"
fi

echo ""
echo "Secure Boot status:"
if mokutil --sb-state | grep -q "SecureBoot enabled"; then
    echo "✓ Secure Boot is enabled"
else
    echo "✗ Secure Boot is disabled"
fi

# Remove HP WMI certificate from MOK database
remove-hp-wmi-mok:
#!/usr/bin/bash
set -euo pipefail

MOK_KEY="/etc/pki/module-signing/module-signing.der"

if [ ! -f "$MOK_KEY" ]; then
    echo "ERROR: MOK certificate not found at $MOK_KEY"
    exit 1
fi

echo "Removing HP WMI module signing certificate from MOK database..."
echo "You will be prompted to set a password for MOK removal."
echo ""

if sudo mokutil --delete "$MOK_KEY"; then
    echo ""
    echo "SUCCESS: Certificate removal request submitted."
    echo "Reboot and follow the MOK Manager prompts to complete removal."
else
    echo "ERROR: Failed to request certificate removal"
    exit 1
fi

# Test HP WMI module loading
test-hp-wmi-module:
#!/usr/bin/bash
set -euo pipefail

echo "Testing HP WMI module..."

if lsmod | grep -q hp_wmi; then
    echo "Unloading existing hp-wmi module..."
    sudo modprobe -r hp-wmi || true
fi

echo "Loading hp-wmi module..."
if sudo modprobe hp-wmi; then
    echo "✓ hp-wmi module loaded successfully"

    if lsmod | grep -q hp_wmi; then
        echo "✓ hp-wmi module is active"
        echo ""
        echo "Module information:"
        modinfo hp-wmi | head -10
    else
        echo "✗ hp-wmi module failed to stay loaded"
    fi
else
    echo "✗ Failed to load hp-wmi module"
    echo ""
    echo "This might be due to:"
    echo "1. Secure Boot is enabled but certificate is not enrolled in MOK"
    echo "2. Module signature verification failed"
    echo "3. Module compatibility issues"
    echo ""
    echo "Check dmesg for more details: dmesg | tail -20"
fi

# Show help for HP WMI MOK management
help-hp-wmi-mok:
	@echo "HP WMI Module MOK (Machine Owner Key) Management Commands:"
	@echo ""
	@echo "ujust enroll-hp-wmi-mok    - Enroll signing certificate in MOK database"
	@echo "ujust check-hp-wmi-mok     - Check MOK enrollment status"
	@echo "ujust remove-hp-wmi-mok    - Remove certificate from MOK database"
	@echo "ujust test-hp-wmi-module   - Test loading the hp-wmi module"
	@echo "ujust help-hp-wmi-mok      - Show this help message"
	@echo ""
	@echo "Typical workflow:"
	@echo "1. Build and install the custom hp-wmi module (build script)"
	@echo "2. Enroll the signing certificate: ujust enroll-hp-wmi-mok"
	@echo "3. Reboot and complete MOK enrollment in firmware"
	@echo "4. Test module loading: ujust test-hp-wmi-module"
UJUST_RECIPE_EOF

echo "ujust recipes created successfully!"

# Final Build Summary
#####################

echo "Build completed successfully!"
echo ""
echo "BUILD SUMMARY:"
echo "=============="
echo "Base Image: ${BASE_IMAGE:-unknown}"
echo ""
echo "IMPORTANT NOTES:"
echo "==============="
echo "1. Module signing keys have been generated/loaded:"
if [ "$USING_PERSISTENT_KEYS" = true ]; then
    echo "   ✓ Using PERSISTENT keys - MOK enrollment survives updates"
else
    echo "   ⚠️  Using TEMPORARY keys - MOK must be re-enrolled after updates"
fi
echo "   - Certificate: /etc/pki/module-signing/module-signing.crt"
echo "   - DER format: /etc/pki/module-signing/module-signing.der"
echo ""
echo "2. If Secure Boot is enabled, enroll the signing certificate:"
echo "   ujust enroll-hp-wmi-mok"
echo ""
echo "3. Check MOK enrollment status:"
echo "   ujust check-hp-wmi-mok"
echo ""
echo "4. Test module loading:"
echo "   ujust test-hp-wmi-module"
echo ""
echo "5. For complete help:"
echo "   ujust help-hp-wmi-mok"
echo ""
echo "6. Software installed:"
echo "   ✓ HP-WMI custom module (signed)"
echo "   ✓ Firefox"
echo "   ✓ Visual Studio Code"
echo ""
if [ "$USING_PERSISTENT_KEYS" = false ]; then
    echo "⚠️  IMPORTANT: Consider setting up persistent key management"
    echo "   for production to avoid MOK re-enrollment after updates!"
fi

# Remove third-party repo files after packages are installed.
# bootc-image-builder reads these during ISO manifest generation and
# chokes on file:// GPG key paths that don't exist in its build context.
echo "🧹 Removing third-party repo files..."

rm -f /etc/yum.repos.d/terra-mesa.repo
rm -f /etc/yum.repos.d/terra.repo
rm -f /etc/yum.repos.d/vscode.repo
rm -f /etc/yum.repos.d/tlp.repo
rm -f /etc/yum.repos.d/_copr*.repo

for repo in /etc/yum.repos.d/*.repo; do
    if grep -q 'gpgkey=file://' "$repo" 2>/dev/null; then
        echo "Removing $repo (has unresolvable file:// GPG key)"
        rm -f "$repo"
    fi
done

echo "✅ Third-party repo cleanup done"
echo "================================="
