#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-module-cache"

if ! xcrun --find actool >/dev/null 2>&1; then
    echo "Building the Icon Composer app icon requires full Xcode 26 or newer." >&2
    exit 1
fi

SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:--}"
if [[ -n "${NOTARYTOOL_PROFILE:-}" && "$SIGNING_IDENTITY" == "-" ]]; then
    echo "Notarization requires CODE_SIGN_IDENTITY to identify a Developer ID Application certificate." >&2
    exit 1
fi

# Explicit deployment targets and two slices make the same bundle usable on
# both Intel and Apple silicon Macs, independently of the build machine.
BINARIES=()
for ARCH in arm64 x86_64; do
    BUILD_ARGS=(--disable-sandbox -c release -debug-info-format none
        --scratch-path "$PWD/.build/$ARCH" --triple "$ARCH-apple-macosx13.0")
    swift build "${BUILD_ARGS[@]}"
    BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
    BINARIES+=("$BIN_DIR/Unquarantine")
done

mkdir -p "$PWD/build"
STAGING="$(mktemp -d "$PWD/build/.build.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/Unquarantine.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/Unquarantine"
for ARCH in arm64 x86_64; do
    xcrun lipo "$APP/Contents/MacOS/Unquarantine" -verify_arch "$ARCH"
done
# Some Swift toolchains add their local library directory as an rpath. The app
# uses only macOS libraries, so do not ship build-machine search paths.
while IFS= read -r RPATH; do
    case "$RPATH" in
        /usr/lib/swift|@*) ;;
        *) xcrun install_name_tool -delete_rpath "$RPATH" "$APP/Contents/MacOS/Unquarantine" ;;
    esac
done < <(xcrun otool -arch all -l "$APP/Contents/MacOS/Unquarantine" | awk '
    /cmd LC_RPATH/ { in_rpath = 1; next }
    in_rpath && $1 == "path" {
        sub(/^[[:space:]]*path /, "")
        sub(/ \(offset [0-9]+\)$/, "")
        print
        in_rpath = 0
    }
' | sort -u)
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/clear.svg "$APP/Contents/Resources/clear.svg"
# Compile the layered icon and its fallback for macOS versions before Tahoe.
xcrun actool "$PWD/Unquarantine.icon" \
    --compile "$APP/Contents/Resources" \
    --output-format human-readable-text --notices --warnings \
    --output-partial-info-plist "$STAGING/icon-info.plist" \
    --app-icon Unquarantine --include-all-app-icons \
    --enable-on-demand-resources NO --development-region en \
    --target-device mac --minimum-deployment-target 13.0 --platform macosx
/usr/libexec/PlistBuddy -c "Merge \"$STAGING/icon-info.plist\"" "$APP/Contents/Info.plist"
/usr/bin/plutil -lint "$APP/Contents/Info.plist"

SIGNING_ARGS=(--force --options runtime --sign "$SIGNING_IDENTITY")
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
    SIGNING_ARGS+=(--timestamp)
fi
/usr/bin/codesign "${SIGNING_ARGS[@]}" "$APP"
/usr/bin/codesign --verify --strict --verbose=2 "$APP"

if [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
    # Notarization needs a temporary archive, which is never published.
    ZIP="$STAGING/Unquarantine.zip"
    /usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARYTOOL_PROFILE" --wait
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    /usr/sbin/spctl --assess --type execute --verbose=2 "$APP"
    rm "$ZIP"
fi
# Publish only after compilation, signing, and any requested notarization pass.
rm -rf "$PWD/build/Unquarantine.app"
mv "$APP" "$PWD/build/Unquarantine.app"
echo "$PWD/build/Unquarantine.app"
if [[ -z "${NOTARYTOOL_PROFILE:-}" ]]; then
    echo "Built without notarization. Downloaded copies may need quarantine removed (see README.md)." >&2
fi
