#!/bin/bash
set -euo pipefail

# Build script for Nook app

echo "Building Nook..."

# Compile the Swift code
mkdir -p Nook.app/Contents/MacOS
swiftc -O \
    -parse-as-library \
    -target arm64-apple-macos13.0 \
    -import-objc-header /dev/null \
    -o Nook.app/Contents/MacOS/Nook \
    Nook.swift

# Copy Info.plist
cp Info.plist Nook.app/Contents/

# Copy the app icon (regenerate with icon/make-icon.swift)
mkdir -p Nook.app/Contents/Resources
cp icon/AppIcon.icns Nook.app/Contents/Resources/

# Ad-hoc sign the whole bundle so Info.plist is bound and the app gets its
# bundle identity — UserNotifications silently refuses linker-signed binaries
codesign --force --deep --sign - Nook.app

echo "Build complete!"
echo ""
echo "To run the app:"
echo "  open Nook.app"
echo ""
echo "To install to Applications:"
echo "  cp -r Nook.app /Applications/"
