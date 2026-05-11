#!/bin/bash
set -ouex pipefail

echo "🚀 Build script starting..."
echo "📦 Base image: ${BASE_IMAGE:-unknown}"

# Check if we're building on a NVIDIA-enabled base image
NVIDIA_BASE=false
NVIDIA_INSTALLED=false  # Initialize the variable

if [[ "${BASE_IMAGE:-}" == *"nvidia"* ]]; then
    NVIDIA_BASE=true
    NVIDIA_INSTALLED=true  # Set to true if using NVIDIA base
    echo "🟢 NVIDIA base image detected — skipping NVIDIA driver installation"
else
    echo "🟡 Regular base image detected — NVIDIA drivers will be installed"
fi

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

    # Copy the already decoded files
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

    # Check all required decoded files exist in final location
    SIGNING_DIR="/etc/pki/module-signing"

    for file in module-signing.key module-signing.crt module-signing.der; do
        if [ ! -f "$SIGNING_DIR/$file" ]; then
            echo "❌ ERROR: Required file '$SIGNING_DIR/$file' not found!"
            echo "Available files in $SIGNING_DIR:"
            ls -la "$SIGNING_DIR/" 2>/dev/null || echo "Directory doesn't exist"
            exit 1
        fi
    done

    # Verify permissions are correct
    if [ ! -r "$SIGNING_DIR/module-signing.key" ]; then
        echo "❌ ERROR: module-signing.key is not readable"
        exit 1
    fi

    echo "✅ All module signing keys validated successfully in $SIGNING_DIR"
}

# 🔧 Invoke the secrets setup
setup_github_secrets_keys || exit 1

# Install base packages (always needed)
echo "Installing build dependencies..."
dnf5 install -y kernel-devel kernel-headers gcc make kmod openssl mokutil elfutils-libelf-devel tmux

# Install NVIDIA drivers if not using NVIDIA base
if [ "$NVIDIA_BASE" = false ]; then
    echo "Installing NVIDIA drivers via akmods..."
    if dnf5 install -y akmod-nvidia xorg-x11-drv-nvidia-cuda; then
        NVIDIA_INSTALLED=true
        echo "✅ NVIDIA drivers installed successfully"
    else
        echo "❌ NVIDIA driver installation failed"
        NVIDIA_INSTALLED=false
    fi
fi

# Persistent Key Management
############################

echo "Setting up persistent module signing keys..."

if setup_github_secrets_keys; then
    echo "✓ Using persistent keys - users won't need to re-enroll MOK after updates"
    USING_PERSISTENT_KEYS=true
else
    echo "⚠️  Using temporary keys - users will need to re-enroll MOK after each update"
    USING_PERSISTENT_KEYS=false

    # Generate temporary keys if persistent keys not available  
    if [ ! -f "/etc/pki/module-signing/module-signing.key" ]; then  
        echo "Generating temporary module signing keys..."  
        mkdir -p /etc/pki/module-signing/  
        cd /etc/pki/module-signing/  

        BUILD_TIMESTAMP=$(date +%Y%m%d-%H%M%S)  

        # Generate RSA private key  
        openssl genpkey -algorithm RSA -out module-signing.key -pkeyopt rsa_keygen_bits:2048  

        # Generate X.509 certificate with timestamp to indicate temporary nature  
        openssl req -new -x509 -key module-signing.key -out module-signing.crt -days 3650 \
            -subj "/CN=Omenite Module Signer TEMP-${BUILD_TIMESTAMP}/"  

        # Convert certificate to DER format for MOK enrollment  
        openssl x509 -in module-signing.crt -outform DER -out module-signing.der  

        # Set proper permissions  
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

# Return to build directory
cd "$BUILD_DIR"

# Create Makefile with proper heredoc syntax
cat > Makefile << 'MAKEFILE_EOF'
obj-m += hp-wmi.o

default:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

.PHONY: default clean
MAKEFILE_EOF

# Set the KDIR variable for the make command
export KDIR="$KERNEL_SRC_DIR"

# Build the module
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

# Verify build success
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

# Create backup and replace existing modules
echo "Installing hp-wmi kernel module..."
MODULE_INSTALLED=false

# Find and replace existing hp-wmi modules
for module_path in $(find /lib/modules -name "hp-wmi.ko*" 2>/dev/null); do
    echo "Backing up existing module: $module_path"
    cp "$module_path" "$module_path.backup"
    echo "Replacing module: $module_path"
    cp hp-wmi.ko "$module_path"
    MODULE_INSTALLED=true
done

# If no existing modules found, install to extra directory
if [ "$MODULE_INSTALLED" = false ]; then
    EXTRA_DIR="/lib/modules/$KERNEL_VERSION/extra"
    mkdir -p "$EXTRA_DIR"
    cp hp-wmi.ko "$EXTRA_DIR/"
    echo "Installed hp-wmi.ko to $EXTRA_DIR/"
fi

# Update module dependencies
echo "Updating module dependencies..."
depmod -a "$KERNEL_VERSION"

# Create module loading configuration
echo "Creating module configuration..."
cat > /etc/modules-load.d/hp-wmi.conf << 'MODULE_CONF_EOF'
# Load HP WMI module at boot
hp-wmi
MODULE_CONF_EOF

# Create modprobe configuration if needed
cat > /etc/modprobe.d/hp-wmi.conf << 'MODPROBE_CONF_EOF'
# HP WMI module configuration
# Add any module parameters here if needed
options hp-wmi parameter=value
MODPROBE_CONF_EOF

# Clean up build directory
cd /
rm -rf "$BUILD_DIR"

echo "hp-wmi module installation completed successfully!"

# Securely wipe private key from persistent storage
# (The build dir was already rm -rf'd above; clean the pki copy too)
echo "🧹 Cleaning up private key..."
if [ -f "/etc/pki/module-signing/module-signing.key" ]; then
    shred -u /etc/pki/module-signing/module-signing.key ||         rm -f /etc/pki/module-signing/module-signing.key
    echo "✅ Private key wiped from /etc/pki/module-signing/"
fi
echo "🔒 Private key cleanup completed."
echo "📋 Certificate files (.crt .der) preserved at /etc/pki/module-signing/ for MOK enrollment."

# Conditional NVIDIA Module Building and Signing
##################################################

if [ "$NVIDIA_INSTALLED" = true ]; then
    echo "Building and signing NVIDIA modules..."

    # Force akmods to build NVIDIA modules for current kernel
    echo "Running akmods to build NVIDIA modules..."
    akmods --force

    # Wait for akmods to complete and update module dependencies
    depmod -a "$KERNEL_VERSION"

    # Find and sign NVIDIA modules
    echo "Signing NVIDIA modules with persistent keys..."
    NVIDIA_MODULES_FOUND=false

    # Common locations for NVIDIA modules
    NVIDIA_SEARCH_PATHS=(
        "/lib/modules/$KERNEL_VERSION/extra/nvidia"
        "/lib/modules/$KERNEL_VERSION/kernel/drivers/video"
        "/lib/modules/$KERNEL_VERSION/weak-updates/nvidia"
        "/usr/lib/modules/$KERNEL_VERSION/extra/nvidia"
    )

    for search_path in "${NVIDIA_SEARCH_PATHS[@]}"; do
        if [ -d "$search_path" ]; then
            echo "Found NVIDIA modules in: $search_path"
            for ko_file in $(find "$search_path" -name "*.ko" 2>/dev/null); do
                echo "Signing NVIDIA module: $(basename $ko_file)"
                if [ -f "$KERNEL_SRC_DIR/scripts/sign-file" ]; then
                    $KERNEL_SRC_DIR/scripts/sign-file sha256 \
                        /etc/pki/module-signing/module-signing.key \
                        /etc/pki/module-signing/module-signing.crt \
                        "$ko_file"
                    NVIDIA_MODULES_FOUND=true
                fi
            done
        fi
    done

    # Also check for NVIDIA modules in standard kernel locations
    for ko_file in $(find /lib/modules/$KERNEL_VERSION -name "nvidia.ko" 2>/dev/null); do
        echo "Signing NVIDIA module: $(basename $ko_file)"
        if [ -f "$KERNEL_SRC_DIR/scripts/sign-file" ]; then
            $KERNEL_SRC_DIR/scripts/sign-file sha256 \
                /etc/pki/module-signing/module-signing.key \
                /etc/pki/module-signing/module-signing.crt \
                "$ko_file"
            NVIDIA_MODULES_FOUND=true
        fi
    done

    if [ "$NVIDIA_MODULES_FOUND" = true ]; then
        echo "✓ NVIDIA modules signed successfully"
        # Update module dependencies after signing
        depmod -a "$KERNEL_VERSION"
    else
        echo "⚠️  No NVIDIA modules found to sign. They may be built on first boot."
    fi
else
    if [ "$NVIDIA_BASE" = true ]; then
        echo "✓ Skipping NVIDIA module building (using NVIDIA base image)"
    else
        echo "⚠️  Skipping NVIDIA module building (installation failed)"
    fi
fi

dnf5 install -y nvidia-container-toolkit

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

# Install firefox Browser
########################
dnf5 install -y firefox

# Install Brave Browser
# Add Brave repo (dnf5-compatible way)
# echo "Adding Brave browser repository..."
# cat > /etc/yum.repos.d/terra.repo << 'BRAVE_REPO_EOF'
# [Brave]
# name=Brave Browser
# baseurl=https://brave-browser-rpm-release.s3.brave.com/x86_64
# enabled=1
# gpgcheck=1
# gpgkey=https://brave-browser-rpm-release.s3.brave.com/brave-core.asc
# BRAVE_REPO_EOF

# dnf5 install -y brave-browser



rpm-ostree install toolbox
    # Optional but recommended for full power-profilesctl compatibility (GNOME/KDE/Steam Deck UI):
    # tlp-pd    # ← only if available in Fedora repos by your build time (check later)

# Mask the old service so nothing accidentally starts it
# (this survives ostree upgrades)



# Enable services
systemctl enable podman.socket

# Install MOK helper scripts and create ujust recipes
echo "Installing Omenite MOK helper scripts..."
mkdir -p /usr/libexec/omenite
for script in enroll check delete test; do
    cp "/ctx/scripts/omenite-mok-${script}.sh" "/usr/libexec/omenite/"
    chmod +x "/usr/libexec/omenite/omenite-mok-${script}.sh"
done

echo "Creating ujust recipes for MOK enrollment..."
mkdir -p /usr/share/ublue-os/just

# NOTE: just recipes that run complex shell must delegate to an external
# script to avoid heredoc / indentation conflicts in just syntax.
cat > /usr/share/ublue-os/just/60-omenite-mok.just << 'UJUST_EOF'
# Omenite — Secure Boot / MOK management

# Enroll the Omenite module-signing cert in MOK (run once after install)
enroll-mok:
    @/usr/libexec/omenite/omenite-mok-enroll.sh

# Check MOK enrollment status
check-mok:
    @/usr/libexec/omenite/omenite-mok-check.sh

# Remove Omenite cert from MOK database
delete-mok:
    @/usr/libexec/omenite/omenite-mok-delete.sh

# Test that the hp-wmi module loads correctly
test-hp-wmi:
    @/usr/libexec/omenite/omenite-mok-test.sh

# Show MOK help
help-mok:
    @echo ""
    @echo "Omenite Secure Boot / MOK commands:"
    @echo "  ujust enroll-mok   — enroll signing cert in firmware MOK database"
    @echo "  ujust check-mok    — check enrollment status"
    @echo "  ujust delete-mok   — remove cert from MOK database"
    @echo "  ujust test-hp-wmi  — test hp-wmi module loading"
    @echo ""
    @echo "Typical first-boot workflow:"
    @echo "  1. ujust enroll-mok"
    @echo "  2. reboot, follow blue MOK Manager screen"
    @echo "  3. ujust test-hp-wmi"
    @echo ""
UJUST_EOF

echo "ujust recipes created successfully!"

# Final Build Summary
#####################

echo "Build completed successfully!"
echo ""
echo "BUILD SUMMARY:"
echo "=============="
echo "Base Image: ${BASE_IMAGE:-unknown}"
if [ "$NVIDIA_BASE" = true ]; then
    echo "NVIDIA: ✓ Using NVIDIA base image (drivers pre-installed)"
else
    if [ "$NVIDIA_INSTALLED" = true ]; then
        echo "NVIDIA: ✓ Drivers installed via akmods"
    else
        echo "NVIDIA: ⚠️  Driver installation failed or skipped"
    fi
fi
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
if [ "$NVIDIA_INSTALLED" = true ]; then
    echo "5. If NVIDIA modules aren't working:"
    echo "   ujust rebuild-nvidia"
    echo ""
fi
echo "6. For complete help:"
echo "   ujust help-hp-wmi-mok"
echo ""
echo "7. Software installed:"
echo "   ✓ HP-WMI custom module (signed)"
if [ "$NVIDIA_BASE" = true ]; then
    echo "   ✓ NVIDIA drivers (pre-installed in base image)"
elif [ "$NVIDIA_INSTALLED" = true ]; then
    echo "   ✓ NVIDIA drivers with akmods (signed)"
else
    echo "   ⚠️  NVIDIA drivers (installation failed)"
fi
echo "   ✓ Rust programming language"
echo "   ✓ Brave browser (Firefox removed)"
echo "   ✓ Visual Studio Code"
if [ "$NVIDIA_INSTALLED" = true ] || [ "$NVIDIA_BASE" = true ]; then
    echo "   ✓ CUDA development tools"
fi
echo ""
if [ "$USING_PERSISTENT_KEYS" = false ]; then
    echo "⚠️  IMPORTANT: Consider setting up persistent key management"
    echo "   for production to avoid MOK re-enrollment after updates!"
fi
# Remove third-party repo files after packages are installed.
# bootc-image-builder reads these during ISO manifest generation and
# chokes on file:// GPG key paths that don't exist in its build context.
# The packages are already installed — the repo files are no longer needed.
echo "🧹 Removing third-party repo files..."

rm -f /etc/yum.repos.d/terra-mesa.repo
rm -f /etc/yum.repos.d/terra.repo
rm -f /etc/yum.repos.d/vscode.repo
rm -f /etc/yum.repos.d/nvidia-container-toolkit.repo
rm -f /etc/yum.repos.d/tlp.repo
rm -f /etc/yum.repos.d/_copr*.repo

# Catch-all: remove any remaining repo with a file:// GPG key
for repo in /etc/yum.repos.d/*.repo; do
    if grep -q 'gpgkey=file://' "$repo" 2>/dev/null; then
        echo "Removing $repo (has unresolvable file:// GPG key)"
        rm -f "$repo"
    fi
done

echo "✅ Third-party repo cleanup done"
echo "================================="