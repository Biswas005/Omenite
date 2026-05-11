#!/usr/bin/bash
set -euo pipefail

MOK_KEY="/etc/pki/module-signing/module-signing.der"

if [ ! -f "$MOK_KEY" ]; then
    echo "ERROR: MOK certificate not found at $MOK_KEY"
    echo "Ensure the Omenite image was built with module-signing secrets."
    exit 1
fi

echo "=== Omenite Secure Boot MOK Enrollment ==="
echo ""
echo "This will enroll the Omenite kernel-module signing certificate"
echo "into your firmware's Machine Owner Key (MOK) database."
echo ""
echo "You will be asked to set a one-time password."
echo "Write it down — you'll need it on the NEXT BOOT in the MOK Manager."
echo ""

if sudo mokutil --import "$MOK_KEY"; then
    echo ""
    echo "SUCCESS: Certificate queued for enrollment."
    echo ""
    echo "NEXT STEPS:"
    echo "  1.  sudo systemctl reboot"
    echo "  2.  On the blue MOK Manager screen: Enroll MOK → Continue → Yes"
    echo "  3.  Enter the password you just set"
    echo "  4.  Select Reboot"
    echo ""
    echo "After reboot the hp-wmi and NVIDIA modules will load without SB errors."
else
    echo "ERROR: mokutil --import failed. Check dmesg for details."
    exit 1
fi
