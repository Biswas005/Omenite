#!/usr/bin/bash
set -euo pipefail

echo "=== hp-wmi Module Test ==="

if lsmod | grep -q hp_wmi; then
    echo "Unloading existing hp-wmi module..."
    sudo modprobe -r hp-wmi || true
fi

echo "Loading hp-wmi..."
if sudo modprobe hp-wmi; then
    echo ""
    echo "SUCCESS: hp-wmi module loaded."
    modinfo hp-wmi | head -12
else
    echo ""
    echo "FAILED to load hp-wmi. Possible causes:"
    echo "  • Secure Boot enabled but MOK not enrolled → run: ujust enroll-mok"
    echo "  • Signature mismatch after an image update"
    echo ""
    echo "Check:  sudo dmesg | tail -30"
    exit 1
fi
