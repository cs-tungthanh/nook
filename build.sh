#!/bin/bash

# Build script for PowerOffTimer app

echo "Building PowerOffTimer..."

# Compile the Swift code
swiftc -O \
    -parse-as-library \
    -target arm64-apple-macos13.0 \
    -import-objc-header /dev/null \
    -o PowerOffTimer.app/Contents/MacOS/PowerOffTimer \
    PowerOffTimer.swift

# Copy Info.plist
cp Info.plist PowerOffTimer.app/Contents/

echo "Build complete!"
echo ""
echo "To run the app:"
echo "  open PowerOffTimer.app"
echo ""
echo "To install to Applications:"
echo "  cp -r PowerOffTimer.app /Applications/"
