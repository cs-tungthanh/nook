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

# Copy Info.plist, stamping the version when NOOK_VERSION is set (release builds)
cp Info.plist Nook.app/Contents/
if [ -n "${NOOK_VERSION:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${NOOK_VERSION}" Nook.app/Contents/Info.plist
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${NOOK_VERSION}" Nook.app/Contents/Info.plist
fi

# Nook's Google OAuth client ID (an "iOS" client for com.nook.app), which lets
# Music sign in to YouTube and list your playlists. Taken from the environment
# or from the gitignored .env file, so it stays out of the repo. Without it,
# the build works but can't connect a YouTube account.
if [ -z "${NOOK_YOUTUBE_CLIENT_ID:-}" ] && [ -f .env ]; then
    NOOK_YOUTUBE_CLIENT_ID="$(sed -n 's/^NOOK_YOUTUBE_CLIENT_ID=//p' .env | tail -1 | tr -d "\"' ")"
fi
if [ -n "${NOOK_YOUTUBE_CLIENT_ID:-}" ]; then
    /usr/libexec/PlistBuddy -c "Add :NookYouTubeClientID string ${NOOK_YOUTUBE_CLIENT_ID}" Nook.app/Contents/Info.plist
fi

# Copy the app icon (regenerate with icon/make-icon.swift)
mkdir -p Nook.app/Contents/Resources
cp icon/AppIcon.icns Nook.app/Contents/Resources/

# Sign the whole bundle so Info.plist is bound and the app gets its bundle
# identity — UserNotifications silently refuses linker-signed binaries.
# Prefer a real certificate: privacy grants (Screen Recording, Microphone) are
# tied to the signature, and an ad-hoc one changes on every build, so macOS
# would forget the grant after each rebuild. Override with NOOK_SIGN_IDENTITY
# (use "-" to force ad-hoc).
SIGN_IDENTITY="${NOOK_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/"Apple Development|"Developer ID Application/ { print $2; exit }')}"
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY="-"
    echo "No signing certificate found; signing ad-hoc (privacy permissions reset on every build)."
fi
codesign --force --deep --sign "$SIGN_IDENTITY" Nook.app

echo "Build complete!"
echo ""
echo "To run the app:"
echo "  open Nook.app"
echo ""
echo "To install to Applications:"
echo "  cp -r Nook.app /Applications/"
