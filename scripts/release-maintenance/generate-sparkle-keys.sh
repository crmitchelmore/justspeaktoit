#!/bin/bash
# Generate Sparkle EdDSA signing keys for auto-update
# Run this ONCE locally and store the private key securely

set -e

echo "Generating Sparkle EdDSA key pair..."
echo ""
echo "This script will generate:"
echo "  1. A PRIVATE key (keep SECRET - add to GitHub secrets)"
echo "  2. A PUBLIC key (embed in app's Info.plist)"
echo ""

# Check if Sparkle's generate_keys tool is available
if command -v generate_keys &> /dev/null; then
    generate_keys
elif [ -f ".build/artifacts/sparkle/Sparkle/bin/generate_keys" ]; then
    .build/artifacts/sparkle/Sparkle/bin/generate_keys
else
    echo "Sparkle generate_keys tool not found."
    echo ""
    echo "After adding Sparkle to the project, run:"
    echo "  swift build"
    echo "  .build/artifacts/sparkle/Sparkle/bin/generate_keys"
    echo ""
    echo "Or download Sparkle manually from:"
    echo "  https://github.com/sparkle-project/Sparkle/releases"
    echo "  and run: Sparkle.framework/Resources/bin/generate_keys"
    exit 1
fi
