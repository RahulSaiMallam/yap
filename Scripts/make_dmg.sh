#!/bin/zsh
#
# Builds Yap, signs it with the local self-signed cert, and packages it
# into a polished DMG with a custom background and a drag-to-Applications
# layout. No Apple Developer ID required.
#
# Usage:
#   ./scripts/make_dmg.sh [version]
#
# Output: ./dist/Yap-<version>.dmg

set -e

VERSION="${1:-0.1.0}"
APP_NAME="Yap"
DIST_DIR="./dist"
DMG_NAME="Yap-${VERSION}.dmg"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"
APP_PATH="./build/Build/Products/Debug/${APP_NAME}.app"

if ! command -v create-dmg >/dev/null 2>&1; then
    echo "create-dmg not found. Install with: brew install create-dmg"
    exit 1
fi

echo "Building ${APP_NAME}..."
./run.sh build

if [[ ! -d "$APP_PATH" ]]; then
    echo "Build did not produce ${APP_PATH}"
    exit 1
fi

mkdir -p "${DIST_DIR}"
rm -f "${DMG_PATH}"

# create-dmg refuses to overwrite, so a separate cleanup is needed for
# the partial files it leaves behind on a previous failed run.
rm -f "${DIST_DIR}/rw.${DMG_NAME}"

echo "Building DMG at ${DMG_PATH}..."
create-dmg \
    --volname "${APP_NAME} ${VERSION}" \
    --window-pos 200 120 \
    --window-size 540 360 \
    --icon-size 96 \
    --icon "${APP_NAME}.app" 140 170 \
    --hide-extension "${APP_NAME}.app" \
    --app-drop-link 400 170 \
    --no-internet-enable \
    "${DMG_PATH}" \
    "${APP_PATH}"

if [[ ! -f "${DMG_PATH}" ]]; then
    echo "DMG creation failed"
    exit 1
fi

# Sign the DMG itself with the same self-signed identity so the volume
# carries a verifiable signature. The .app inside is already signed by
# run.sh with its designated requirement.
DEV_IDENTITY="OpenSuperWhisper Dev"
echo "Signing DMG..."
codesign --force --sign "${DEV_IDENTITY}" "${DMG_PATH}"

# Generate a SHA256 alongside so it can be referenced from a landing page
# or Homebrew cask later.
shasum -a 256 "${DMG_PATH}" > "${DMG_PATH}.sha256"

SIZE_MB=$(du -m "${DMG_PATH}" | cut -f1)
echo ""
echo "DMG ready:"
echo "  ${DMG_PATH} (${SIZE_MB} MB)"
echo "  ${DMG_PATH}.sha256"
