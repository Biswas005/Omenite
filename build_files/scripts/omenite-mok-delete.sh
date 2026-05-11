#!/usr/bin/bash
set -euo pipefail

MOK_KEY="/etc/pki/module-signing/module-signing.der"

if [ ! -f "$MOK_KEY" ]; then
    echo "ERROR: MOK certificate not found at $MOK_KEY"
    exit 1
fi

echo "Requesting removal of Omenite module-signing certificate from MOK database..."
if sudo mokutil --delete "$MOK_KEY"; then
    echo "Removal queued. Reboot and follow the MOK Manager prompts to complete."
else
    echo "ERROR: mokutil --delete failed."
    exit 1
fi
