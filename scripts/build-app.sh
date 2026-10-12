#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MACOS="$ROOT/macos"
CONFIGURATION=${PAIRDESK_CONFIGURATION:-release}
OUTPUT=${PAIRDESK_APP_OUTPUT:-"$ROOT/dist/PairDesk.app"}
STAGING="$ROOT/dist/.PairDesk.app.staging.$$"
SIGNING_IDENTITY=${DEVELOPER_SIGNING_IDENTITY:-}
LOCAL_SIGNING_IDENTITY="PairDesk Local Signing"
WHISPER_RUNTIME="$ROOT/.cache/whisper/runtime"
BUILD_PATH=${PAIRDESK_BUILD_PATH:-"$MACOS/.build"}
FRAMEWORKS_SOURCE="$BUILD_PATH/artifacts"
MODEL_SHA1="bd577a113a864445d4c299885e0cb97d4ba92b5f"

fail() {
  echo "build-app: $*" >&2
  exit 1
}

if [ -e "$OUTPUT" ]; then
  fail "$OUTPUT already exists; move or remove it before packaging another build"
fi

# Prefer a stable identity: macOS ties keychain and privacy approvals to the
# signature, and an ad-hoc signature changes with every build. Set
# DEVELOPER_SIGNING_IDENTITY=- to force ad-hoc signing.
if [ -z "$SIGNING_IDENTITY" ]; then
  if security find-identity -p codesigning | grep -F "\"$LOCAL_SIGNING_IDENTITY\"" >/dev/null; then
    SIGNING_IDENTITY=$LOCAL_SIGNING_IDENTITY
  else
    SIGNING_IDENTITY=-
    echo "build-app: ad-hoc signing. macOS will treat this build as a new app: the saved sign-in asks for the Mac password and permissions may need approval again. Run scripts/create-signing-identity.sh once to avoid this." >&2
  fi
fi

if [ "${PAIRDESK_SKIP_BUILD:-0}" != "1" ]; then
  (cd "$MACOS" && swift build --scratch-path "$BUILD_PATH" -c "$CONFIGURATION")
fi
BIN_PATH=${PAIRDESK_BIN_PATH:-$(cd "$MACOS" && swift build --scratch-path "$BUILD_PATH" --show-bin-path -c "$CONFIGURATION")}
EXECUTABLE="$BIN_PATH/PairDesk"
test -x "$EXECUTABLE" || fail "SwiftPM executable is missing at $EXECUTABLE"

test -x "$WHISPER_RUNTIME/whisper-cli" || fail "run scripts/prepare-whisper.sh first"
test -f "$WHISPER_RUNTIME/ggml-tiny.bin" || fail "Whisper Tiny model is missing"
ACTUAL_MODEL_SHA1=$(shasum -a 1 "$WHISPER_RUNTIME/ggml-tiny.bin" | awk '{print $1}')
test "$ACTUAL_MODEL_SHA1" = "$MODEL_SHA1" || fail "Whisper Tiny model checksum mismatch"

mkdir -p "$ROOT/dist"
mkdir -p "$STAGING/Contents/MacOS" "$STAGING/Contents/Frameworks" "$STAGING/Contents/Resources/whisper" "$STAGING/Contents/Resources/ThirdPartyNotices"
cleanup() {
  if [ -d "$STAGING" ]; then rm -rf "$STAGING"; fi
}
trap cleanup EXIT HUP INT TERM

CONTENTS="$STAGING/Contents"
FRAMEWORKS="$CONTENTS/Frameworks"
RESOURCES="$CONTENTS/Resources"
APP_EXECUTABLE="$CONTENTS/MacOS/PairDesk"
ditto "$EXECUTABLE" "$APP_EXECUTABLE"
ditto "$MACOS/Info.plist" "$CONTENTS/Info.plist"
if [ -n "${PAIRDESK_DEFAULT_SERVER:-}" ]; then
  python3 - "$CONTENTS/Info.plist" "$PAIRDESK_DEFAULT_SERVER" <<'PYURL'
import plistlib, sys, urllib.parse
url = urllib.parse.urlsplit(sys.argv[2])
if url.scheme != 'https' or not url.hostname or url.username or url.password or url.query or url.fragment or url.path not in ['', '/']:
    raise SystemExit('PAIRDESK_DEFAULT_SERVER must be an HTTPS API origin')
with open(sys.argv[1], 'rb') as stream:
    info = plistlib.load(stream)
info['PairDeskServerURL'] = sys.argv[2]
with open(sys.argv[1], 'wb') as stream:
    plistlib.dump(info, stream)
PYURL
fi
ditto "$WHISPER_RUNTIME/whisper-cli" "$RESOURCES/whisper/whisper-cli"
ditto "$WHISPER_RUNTIME/ggml-tiny.bin" "$RESOURCES/whisper/ggml-tiny.bin"
chmod 755 "$APP_EXECUTABLE" "$RESOURCES/whisper/whisper-cli"

# SwiftPM resource bundles carry Package.resolved resources such as LiveKit's
# privacy manifest. Copy every top-level bundle emitted with the executable.
find "$BIN_PATH" -maxdepth 1 -type d -name '*.bundle' -print | while IFS= read -r bundle; do
  ditto "$bundle" "$RESOURCES/$(basename "$bundle")"
done

# Resolve the app's @rpath-linked SDK frameworks from SwiftPM's built products
# or the selected macOS XCFramework slices. Fail closed on unknown dependencies.
otool -L "$EXECUTABLE" | awk '/compatibility version/ { print $1 }' | sort -u | while IFS= read -r dependency; do
  case "$dependency" in
    /System/*|/usr/lib/*|@loader_path/*|@executable_path/*) continue ;;
    @rpath/*) ;;
    *) fail "unhandled linked dependency: $dependency" ;;
  esac

  relative=${dependency#@rpath/}
  component=${relative%%/*}
  destination="$FRAMEWORKS/$component"
  if [ -e "$destination" ]; then continue; fi

  source=""
  if [ -e "$BIN_PATH/$component" ]; then
    source="$BIN_PATH/$component"
  elif [ -e "$BIN_PATH/PackageFrameworks/$component" ]; then
    source="$BIN_PATH/PackageFrameworks/$component"
  elif [ -d "$FRAMEWORKS_SOURCE" ]; then
    source=$(find "$FRAMEWORKS_SOURCE" -type d -name "$component" -path '*/macos-*/*' -print -quit)
    if [ -z "$source" ]; then source=$(find "$FRAMEWORKS_SOURCE" -type f -name "$component" -print -quit); fi
  fi
  [ -n "$source" ] && [ -e "$source" ] || fail "could not locate linked dependency $component"
  ditto "$source" "$destination"
done

# SwiftPM binaries refer to developer toolchain Swift libraries. Embed the
# platform Swift runtime that the binary actually needs for a standalone app.
xcrun swift-stdlib-tool --copy --platform macosx --destination "$FRAMEWORKS" --scan-executable "$APP_EXECUTABLE"
install_name_tool -add_rpath '@executable_path/../Frameworks' "$APP_EXECUTABLE"
otool -l "$APP_EXECUTABLE" | awk '/cmd LC_RPATH/ { getline; getline; print $2 }' | sort -u | while IFS= read -r build_rpath; do
  case "$build_rpath" in
    "$BIN_PATH/PackageFrameworks"|*/Xcode.app/Contents/Developer/Toolchains/*)
      install_name_tool -delete_rpath "$build_rpath" "$APP_EXECUTABLE"
      ;;
  esac
done
if otool -l "$APP_EXECUTABLE" | grep -E '/(Xcode\.app|\.build)/' >/dev/null; then
  fail "build or toolchain rpath remained in the app executable"
fi

NOTICES="$RESOURCES/ThirdPartyNotices"
CHECKOUTS="$BUILD_PATH/checkouts"
copy_notice() {
  source=$1
  target=$2
  test -f "$source" || fail "missing third-party notice: $source"
  ditto "$source" "$NOTICES/$target"
}
copy_notice "$ROOT/vendor/livekit-client-swift/LICENSE" "LiveKit-Client-LICENSE.txt"
copy_notice "$ROOT/vendor/livekit-client-swift/NOTICE" "LiveKit-Client-NOTICE.txt"
copy_notice "$CHECKOUTS/webrtc-xcframework/LICENSE" "LiveKit-WebRTC-LICENSE.txt"
copy_notice "$CHECKOUTS/livekit-uniffi-xcframework/LICENSE" "LiveKit-UniFFI-LICENSE.txt"
copy_notice "$ROOT/.cache/whisper/source/LICENSE" "whisper.cpp-LICENSE.txt"
copy_notice "$MACOS/Resources/ThirdPartyNotices/OpenAI-Whisper-LICENSE.txt" "OpenAI-Whisper-LICENSE.txt"
copy_notice "$ROOT/THIRD_PARTY_NOTICES.md" "THIRD_PARTY_NOTICES.md"

plutil -lint "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$CONTENTS/Info.plist" | grep -Fx 'app.internal.pairdesk' >/dev/null
/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$CONTENTS/Info.plist" | grep -Fx '14.0' >/dev/null
if /usr/libexec/PlistBuddy -c 'Print :NSCameraUsageDescription' "$CONTENTS/Info.plist" >/dev/null 2>&1; then
  fail "camera usage description must not be present"
fi
ARCHS=$(lipo -archs "$APP_EXECUTABLE")
for framework in "$FRAMEWORKS"/*.framework; do
  [ -d "$framework" ] || continue
  framework_binary="$framework/$(basename "$framework" .framework)"
  for arch in $ARCHS; do
    lipo -verify_arch "$arch" "$framework_binary" || fail "$(basename "$framework") is missing $arch"
  done
done

# The frameworks are individually signed before the app seals the whole bundle.
for framework in "$FRAMEWORKS"/*.framework; do
  [ -d "$framework" ] || continue
  codesign --force --deep --sign "$SIGNING_IDENTITY" "$framework"
done
find "$FRAMEWORKS" -maxdepth 1 -type f -name '*.dylib' -print | while IFS= read -r library; do
  codesign --force --sign "$SIGNING_IDENTITY" "$library"
done
codesign --force --sign "$SIGNING_IDENTITY" "$RESOURCES/whisper/whisper-cli"
codesign --force --deep --sign "$SIGNING_IDENTITY" "$STAGING"
codesign --verify --deep --strict --verbose=2 "$STAGING"

# Do not expose a partially packaged app; publish only after validation/signing.
mv "$STAGING" "$OUTPUT"
trap - EXIT HUP INT TERM
echo "Packaged $OUTPUT ($CONFIGURATION, $ARCHS); signing identity: $SIGNING_IDENTITY"
