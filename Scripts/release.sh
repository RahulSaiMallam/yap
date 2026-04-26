#!/bin/zsh
#
# Build, package, and publish a Yap release in one step.
#
# Usage:
#   ./scripts/release.sh 0.1.0
#
# What it does:
#   1. Bumps MARKETING_VERSION in the Xcode project
#   2. Builds + signs the .app via run.sh
#   3. Wraps it in a polished DMG via scripts/make_dmg.sh
#   4. Creates a git tag and pushes it
#   5. Creates a GitHub Release on rahulsaimallam/yap with the DMG attached
#
# Prerequisites:
#   - gh CLI installed and authenticated as rahulsaimallam
#     (gh auth login → choose rahulsaimallam)
#   - origin remote pointing at https://github.com/rahulsaimallam/yap.git
#   - master branch is up to date and clean

set -e

VERSION="${1}"
if [[ -z "$VERSION" ]]; then
    echo "usage: $0 <version>"
    echo "example: $0 0.1.0"
    exit 1
fi

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "version must be semver (e.g. 0.1.0), got: $VERSION"
    exit 1
fi

REPO="rahulsaimallam/yap"
TAG="v${VERSION}"
DMG_PATH="./dist/Yap-${VERSION}.dmg"

# Verify gh is authenticated as the right user
if ! gh auth status 2>&1 | grep -q "rahulsaimallam"; then
    echo "gh CLI is not authenticated as rahulsaimallam."
    echo "Run: gh auth login → choose rahulsaimallam"
    exit 1
fi

# Verify the working tree is clean (avoid releasing uncommitted changes)
if [[ -n "$(git status --porcelain)" ]]; then
    echo "Working tree has uncommitted changes. Commit or stash them first:"
    git status --short
    exit 1
fi

echo "==> Bumping MARKETING_VERSION to ${VERSION}..."
sed -i '' "s/MARKETING_VERSION = [^;]*/MARKETING_VERSION = ${VERSION}/g" \
    OpenSuperWhisper.xcodeproj/project.pbxproj
git add OpenSuperWhisper.xcodeproj/project.pbxproj
git commit -m "Bump version to ${VERSION}"

echo "==> Building DMG..."
./scripts/make_dmg.sh "${VERSION}"

if [[ ! -f "${DMG_PATH}" ]]; then
    echo "DMG not produced at ${DMG_PATH}"
    exit 1
fi

echo "==> Tagging and pushing..."
git tag -a "${TAG}" -m "Release ${VERSION}"
git push origin master
git push origin "${TAG}"

echo "==> Creating GitHub release..."
NOTES_FILE=$(mktemp)
cat > "${NOTES_FILE}" <<EOF
## Yap ${VERSION}

A free, open-source dictation app for macOS. Hold a key, speak, and your words land in any app — locally.

### Install

1. Download \`Yap-${VERSION}.dmg\` below
2. Open the DMG and drag Yap to your Applications folder
3. Right-click Yap in Applications → choose **Open** (one-time Gatekeeper bypass since the app isn't notarized)
4. Grant **Microphone**, **Accessibility**, and **Input Monitoring** when prompted
5. Hold \`Fn\` to talk

Apple Silicon Mac · macOS 14 or later.

[Landing page](https://rahulsaimallam.github.io/yap) · [What's different from upstream OpenSuperWhisper](https://github.com/${REPO}/blob/master/Readme.md)
EOF

gh release create "${TAG}" "${DMG_PATH}" "${DMG_PATH}.sha256" \
    --repo "${REPO}" \
    --title "Yap ${VERSION}" \
    --notes-file "${NOTES_FILE}"

rm -f "${NOTES_FILE}"

echo ""
echo "Done. Release URL:"
echo "  https://github.com/${REPO}/releases/tag/${TAG}"
echo ""
echo "Direct DMG link (latest):"
echo "  https://github.com/${REPO}/releases/latest/download/Yap-${VERSION}.dmg"
