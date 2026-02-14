#!/bin/bash
set -euo pipefail

echo ""
echo "🤙 Installing Shaka..."
echo ""

# Check for Swift
if ! command -v swift &>/dev/null; then
    echo "Error: Swift is required."
    echo "Run: xcode-select --install"
    exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

echo "Cloning..."
git clone --depth 1 --quiet https://github.com/wes/shaka.git "$WORKDIR/shaka"
cd "$WORKDIR/shaka"

echo "Building (this may take a moment)..."
swift build -c release 2>&1

echo "Installing..."
mkdir -p Shaka.app/Contents/MacOS
cp .build/release/Shaka Shaka.app/Contents/MacOS/
cp Info.plist Shaka.app/Contents/
cp -r Shaka.app /Applications/

echo ""
echo "✅ Shaka installed to /Applications/Shaka.app"
echo ""
echo "  Open Shaka from Spotlight or /Applications."
echo "  Grant Accessibility permission when prompted."
echo "  Config: ~/.config/shaka/config.toml"
echo ""
