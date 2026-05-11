#!/usr/bin/bash
set -euo pipefail

echo "=== Omenite MOK Status ==="
echo ""

SB_STATE=$(mokutil --sb-state 2>/dev/null || echo "unknown")
echo "Secure Boot: $SB_STATE"
echo ""

echo "Enrolled keys matching 'Omenite':"
if mokutil --list-enrolled 2>/dev/null | grep -i "Omenite\|omenite\|HP Omen"; then
    echo ""
    echo "Certificate IS enrolled in MOK database."
else
    echo "(none)"
    echo ""
    echo "Certificate is NOT enrolled. Run:  ujust enroll-mok"
fi
