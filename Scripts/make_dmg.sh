#!/bin/bash
# Build a drag-to-Applications DMG from the packaged .app.
# Run Scripts/package_app.sh first so the signed .app exists.
set -euo pipefail

APP_NAME="PortKiller"
BUILD_DIR=".build/release"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"
DIST_DIR="dist"
DMG_PATH="${DIST_DIR}/${APP_NAME}.dmg"

if [ ! -d "${APP_DIR}" ]; then
    echo "error: ${APP_DIR} not found — run Scripts/package_app.sh first" >&2
    exit 1
fi

STAGING="$(mktemp -d)"
trap 'rm -rf "${STAGING}"' EXIT

cp -R "${APP_DIR}" "${STAGING}/"
ln -s /Applications "${STAGING}/Applications"

mkdir -p "${DIST_DIR}"
rm -f "${DMG_PATH}"

hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${STAGING}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}" >/dev/null

echo "${DMG_PATH}"
