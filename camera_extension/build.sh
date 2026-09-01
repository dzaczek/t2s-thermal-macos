#!/bin/bash
#
# Builds T2SCamera and installs it to /Applications.
#
# Why not just `xcodebuild`:
#   * The project file is generated from project.yml by xcodegen, so it is
#     regenerated here rather than kept in the repo.
#   * System Extensions can only be activated from an app in /Applications,
#     and macOS resolves the app by bundle ID -- so if a second copy is left
#     registered elsewhere, activation fails with a confusing
#     "cannot allow apps outside /Applications". The build copy is therefore
#     unregistered and deleted after every build.
#   * Release, never Debug: unoptimised Swift takes 151ms per frame here
#     against 12ms optimised, which is the difference between 6fps and 25.
#
# Usage:
#   ./build.sh                 build, sign for development, install
#   ./build.sh --run           ... and launch it
#   ./build.sh --release       Developer ID build, notarise, produce a .dmg
#
# Configuration (all optional, override in build.config -- see
# build.config.example; that file is git-ignored so local paths stay local):
#   T2S_DEVELOPER_DIR   Xcode to build with (default: xcode-select -p)
#   T2S_TEAM_ID         signing team (default: detected from the keychain)
#   T2S_NOTARY_PROFILE  notarytool keychain profile, for --release
#   T2S_ASC_KEY_PATH    App Store Connect API key (.p8) -- lets --release
#   T2S_ASC_KEY_ID      create the Developer ID provisioning profile without
#   T2S_ASC_ISSUER_ID   an interactive Xcode session

set -euo pipefail
cd "$(dirname "$0")"

[ -f build.config ] && . ./build.config

MODE="${1:-}"

# --- toolchain -------------------------------------------------------------
DEVELOPER_DIR_PATH="${T2S_DEVELOPER_DIR:-$(xcode-select -p)}"
if [ ! -d "$DEVELOPER_DIR_PATH" ]; then
    echo "Xcode not found at $DEVELOPER_DIR_PATH." >&2
    echo "Set T2S_DEVELOPER_DIR in build.config to your Xcode's Contents/Developer." >&2
    exit 1
fi

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "xcodegen not found. Install it with:  brew install xcodegen" >&2
    exit 1
fi

# --- signing team ----------------------------------------------------------
# App Groups embed the team identifier, so the build needs to know it. Taking
# it from the keychain means a fork builds without editing any source.
team_from_keychain() {
    security find-identity -v -p codesigning 2>/dev/null \
        | sed -nE "s/.*\"$1: .*\(([A-Z0-9]{10})\)\".*/\1/p" | head -1
}
if [ -z "${T2S_TEAM_ID:-}" ]; then
    # Developer ID first: on a machine with several Apple IDs the development
    # certificates can belong to a different team than the one the App Group
    # was provisioned under, and picking the wrong one breaks the frame handoff
    # in a way that looks like the extension is simply dead.
    T2S_TEAM_ID=$(team_from_keychain "Developer ID Application")
    [ -z "$T2S_TEAM_ID" ] && T2S_TEAM_ID=$(team_from_keychain "Apple Development")
fi
if [ -z "${T2S_TEAM_ID:-}" ]; then
    echo "No signing identity found in the keychain." >&2
    echo "Set T2S_TEAM_ID in build.config, or sign in to Xcode with your Apple ID." >&2
    exit 1
fi

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
APP="/Applications/T2SCamera.app"
# Local, so the path does not depend on Xcode's per-machine DerivedData hash.
DERIVED_ROOT=".build"
DERIVED="$DERIVED_ROOT/Build/Products/Release"

# Monotonic build number, bumped on every build and shown in About.
BUILD_FILE="build_number.txt"
BUILD_NUMBER=$(( $(cat "$BUILD_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$BUILD_NUMBER" > "$BUILD_FILE"

echo "==> Generating Xcode project from project.yml"
xcodegen generate

if [ "$MODE" = "--release" ]; then
    DIST="dist"
    rm -rf "$DIST"; mkdir -p "$DIST"

    # Developer ID goes through archive + exportArchive rather than a plain
    # build. A system extension needs a provisioning profile carrying the
    # System Extension capability: manual signing fails without one already
    # made by hand, and forcing a Developer ID identity onto an automatically
    # signed build collides with its development profile. Exporting with
    # method "developer-id" is the path where Xcode produces the right profile
    # itself.
    cat > "$DIST/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$T2S_TEAM_ID</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
PLIST

    # A system extension carries a restricted entitlement, which only a
    # provisioning profile can authorise. Creating that profile needs account
    # access; an API key gives xcodebuild it without a signed-in GUI session.
    # Expanded with the ${a[@]+...} guard below: macOS still ships bash 3.2,
    # where expanding an empty array under `set -u` is an error.
    AUTH_ARGS=()
    if [ -n "${T2S_ASC_KEY_PATH:-}" ]; then
        AUTH_ARGS=(-authenticationKeyPath "$T2S_ASC_KEY_PATH"
                   -authenticationKeyID "$T2S_ASC_KEY_ID"
                   -authenticationKeyIssuerID "$T2S_ASC_ISSUER_ID")
    fi

    echo "==> Archiving (build $BUILD_NUMBER, team $T2S_TEAM_ID)"
    env DEVELOPER_DIR="$DEVELOPER_DIR_PATH" xcodebuild \
        -project T2SCamera.xcodeproj \
        -scheme T2SCameraApp \
        -configuration Release \
        -derivedDataPath "$DERIVED_ROOT" \
        -archivePath "$DIST/T2SCamera.xcarchive" \
        -allowProvisioningUpdates \
        CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
        DEVELOPMENT_TEAM="$T2S_TEAM_ID" \
        ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} \
        archive

    echo "==> Exporting Developer ID build"
    if ! env DEVELOPER_DIR="$DEVELOPER_DIR_PATH" xcodebuild \
        -exportArchive \
        -archivePath "$DIST/T2SCamera.xcarchive" \
        -exportOptionsPlist "$DIST/ExportOptions.plist" \
        -exportPath "$DIST" \
        -allowProvisioningUpdates \
        ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"}; then
        cat >&2 <<EOF

==> Export failed.
    A system extension needs a Developer ID provisioning profile carrying the
    System Extension capability, and xcodebuild can only create one if it can
    reach your developer account. Either:

      * set T2S_ASC_KEY_PATH / T2S_ASC_KEY_ID / T2S_ASC_ISSUER_ID in
        build.config (App Store Connect -> Users and Access -> Integrations
        -> Keys), or

      * do the first Developer ID export once from Xcode:
        Window -> Organizer -> select the archive -> Distribute App ->
        Direct Distribution. That creates and caches the profile, after which
        this script works on its own.

    The archive is kept at $DIST/T2SCamera.xcarchive so you can export it
    from Organizer without rebuilding.
EOF
        exit 1
    fi
    rm -rf "$DIST/T2SCamera.xcarchive" "$DIST/ExportOptions.plist"

    echo "==> Verifying signature"
    codesign --verify --deep --strict --verbose=2 "$DIST/T2SCamera.app"

    if [ -z "${T2S_NOTARY_PROFILE:-}" ]; then
        cat >&2 <<EOF

==> Built but NOT notarised: T2S_NOTARY_PROFILE is not set.
    Without notarisation Gatekeeper blocks the app on other machines.
    Create a profile once:
      xcrun notarytool store-credentials T2SCamera \\
        --apple-id <your-apple-id> --team-id $T2S_TEAM_ID --password <app-specific-password>
    then set T2S_NOTARY_PROFILE=T2SCamera in build.config and re-run.
EOF
        exit 1
    fi

    echo "==> Notarising"
    ditto -c -k --keepParent "$DIST/T2SCamera.app" "$DIST/T2SCamera.zip"
    env DEVELOPER_DIR="$DEVELOPER_DIR_PATH" xcrun notarytool submit \
        "$DIST/T2SCamera.zip" --keychain-profile "$T2S_NOTARY_PROFILE" --wait
    env DEVELOPER_DIR="$DEVELOPER_DIR_PATH" xcrun stapler staple "$DIST/T2SCamera.app"
    rm -f "$DIST/T2SCamera.zip"

    echo "==> Building disk image"
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
        "$DIST/T2SCamera.app/Contents/Info.plist")
    DMG="$DIST/T2SCamera-$VERSION-$BUILD_NUMBER.dmg"
    # A symlink to /Applications: the app must live there or the system
    # extension refuses to activate.
    ln -s /Applications "$DIST/Applications"
    hdiutil create -volname "T2S+ Thermal Camera" -srcfolder "$DIST" \
        -ov -format UDZO "$DMG" >/dev/null
    rm -f "$DIST/Applications"

    echo "==> Done: $DMG"
    exit 0
fi

echo "==> Building (build $BUILD_NUMBER, team $T2S_TEAM_ID)"
env DEVELOPER_DIR="$DEVELOPER_DIR_PATH" xcodebuild \
    -project T2SCamera.xcodeproj \
    -scheme T2SCameraApp \
    -configuration Release \
    -derivedDataPath "$DERIVED_ROOT" \
    -allowProvisioningUpdates \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    DEVELOPMENT_TEAM="$T2S_TEAM_ID" \
    build

echo "==> Installing to /Applications"
pkill -9 -f "T2SCamera" 2>/dev/null || true
sleep 1
rm -rf "$APP"
cp -R "$DERIVED/T2SCamera.app" "$APP"

# Leaving the build copy registered breaks extension activation.
"$LSREGISTER" -u "$DERIVED/T2SCamera.app" 2>/dev/null || true
rm -rf "$DERIVED/T2SCamera.app"
"$LSREGISTER" -f "$APP"
sleep 1

echo "==> Registered copies (should list only /Applications):"
"$LSREGISTER" -dump 2>/dev/null | grep -i "t2scamera" | grep "path:" | sort -u || true

echo "==> Done: $APP"

if [ "$MODE" = "--run" ]; then
    echo "==> Launching"
    open "$APP"
fi
