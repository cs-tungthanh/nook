#!/bin/bash
set -euo pipefail

# Builds Nook, removes any installed copy, installs the new one to
# /Applications and launches it.
#
#   ./install.sh            build, reinstall and launch
#   ./install.sh --uninstall quit and remove Nook only

APP_NAME="Nook"
BUNDLE_ID="com.nook.app"
INSTALL_PATH="/Applications/${APP_NAME}.app"

cd "$(dirname "$0")"

quit_running_app() {
    if pgrep -x "$APP_NAME" >/dev/null; then
        echo "Quitting running ${APP_NAME}..."
        # Quit politely (not kill) so an unsaved recording gets its save prompt.
        # Keep asking: each quit reaches one copy, and the repo build and the
        # installed one may both be running.
        for i in {1..20}; do
            pgrep -x "$APP_NAME" >/dev/null || return 0
            if (( i % 4 == 1 )); then
                osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
            fi
            sleep 0.5
        done
        echo "${APP_NAME} didn't quit in time (is a save dialog open?)." >&2
        echo "Finish or cancel it, then run this script again." >&2
        exit 1
    fi
}

remove_installed_app() {
    if [ -d "$INSTALL_PATH" ]; then
        echo "Removing ${INSTALL_PATH}..."
        rm -rf "$INSTALL_PATH"
    fi
}

if [ "${1:-}" = "--uninstall" ]; then
    quit_running_app
    remove_installed_app
    echo "${APP_NAME} uninstalled."
    exit 0
fi

./build.sh

quit_running_app
remove_installed_app

echo "Installing to ${INSTALL_PATH}..."
cp -R "${APP_NAME}.app" "$INSTALL_PATH"

echo "Launching ${APP_NAME}..."
open "$INSTALL_PATH"

echo ""
echo "Installed. If screen recording stops working after an update, remove Nook"
echo "under System Settings › Privacy & Security › Screen & System Audio Recording,"
echo "then allow it again (each build has a new ad-hoc signature)."
