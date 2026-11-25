#!/usr/bin/env bash
set -euo pipefail

# LongTake Release & Sparkle 2.10.1 OTA Publisher
# Usage:
#   ./scripts/release-ota.sh [--sign-identity "<identity>"] [--sparkle-account com.kahlilhazel.LongTake] [--install-local]

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SIGN_IDENTITY="${LONGAKE_SIGN_IDENTITY:-}"
SPARKLE_ACCOUNT="${LONGAKE_SPARKLE_ACCOUNT:-com.kahlilhazel.LongTake}"
INSTALL_LOCAL="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sign-identity) SIGN_IDENTITY="$2"; shift 2 ;;
    --sparkle-account) SPARKLE_ACCOUNT="$2"; shift 2 ;;
    --install-local) INSTALL_LOCAL="1"; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -n 1 || true)"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -n 1 || true)"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
  echo "No valid codesigning identity found in Keychain." >&2
  exit 1
fi

DERIVED="$ROOT/.build-release"
DIST="$ROOT/dist"
rm -rf "$DERIVED" "$DIST"
mkdir -p "$DIST"

echo "[release-ota] Building Release with Xcode (Sparkle 2.10.1+)..."
xcodebuild \
  -project QuickRecorder.xcodeproj \
  -scheme QuickRecorder \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  build

BUILT_APP="$DERIVED/Build/Products/Release/QuickRecorder.app"
STAGED_APP="$DIST/LongTake.app"
cp -R "$BUILT_APP" "$STAGED_APP"

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$STAGED_APP/Contents/Info.plist")"
BUILD_NUM="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$STAGED_APP/Contents/Info.plist")"
echo "[release-ota] Signing LongTake v$VERSION ($BUILD_NUM) inside-out with: $SIGN_IDENTITY"

# Inside-out code signing (preserves Sparkle XPC helpers + TeamIdentifier match without --options runtime for Apple Dev certs)
CODESIGN_EXTRA=()
if [[ "$SIGN_IDENTITY" == Developer\ ID\ Application:* ]]; then
  CODESIGN_EXTRA+=(--options runtime --timestamp)
fi

SPARKLE_FW="$STAGED_APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE_FW" ]]; then
  for helper in \
    "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc" \
    "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc" \
    "$SPARKLE_FW/Versions/B/Updater.app" \
    "$SPARKLE_FW/Versions/B/Autoupdate"; do
    if [[ -e "$helper" ]]; then
      codesign --force --sign "$SIGN_IDENTITY" ${CODESIGN_EXTRA[@]+"${CODESIGN_EXTRA[@]}"} "$helper"
    fi
  done
  codesign --force --sign "$SIGN_IDENTITY" ${CODESIGN_EXTRA[@]+"${CODESIGN_EXTRA[@]}"} "$SPARKLE_FW"
fi

KB_BUNDLE="$STAGED_APP/Contents/Resources/KeyboardShortcuts_KeyboardShortcuts.bundle"
if [[ -d "$KB_BUNDLE" ]]; then
  codesign --force --sign "$SIGN_IDENTITY" ${CODESIGN_EXTRA[@]+"${CODESIGN_EXTRA[@]}"} "$KB_BUNDLE"
fi

codesign --force --sign "$SIGN_IDENTITY" ${CODESIGN_EXTRA[@]+"${CODESIGN_EXTRA[@]}"} \
  --entitlements "$ROOT/QuickRecorder/QuickRecorder.entitlements" \
  "$STAGED_APP"

codesign --verify --deep --strict --verbose=2 "$STAGED_APP"

ARCHIVE_NAME="LongTake-${VERSION}-macOS.zip"
ARCHIVE_PATH="$DIST/$ARCHIVE_NAME"
ditto -c -k --sequesterRsrc --keepParent "$STAGED_APP" "$ARCHIVE_PATH"

SIGN_UPDATE="$(find "$DERIVED/SourcePackages/artifacts" "$HOME/Library/Developer/Xcode/DerivedData" -type f -perm +111 -name "sign_update" 2>/dev/null | head -n 1 || true)"
if [[ -z "$SIGN_UPDATE" ]]; then
  echo "Could not locate Sparkle sign_update binary." >&2
  exit 1
fi

ED_SIG_OUTPUT="$("$SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" "$ARCHIVE_PATH")"
echo "[release-ota] Sparkle signature: $ED_SIG_OUTPUT"
ED_SIG="$(echo "$ED_SIG_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
ARCHIVE_LEN="$(stat -f%z "$ARCHIVE_PATH")"
PUB_DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

cat > "$ROOT/appcast.xml" <<EOF
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <title>LongTake Updates</title>
    <link>https://github.com/HazelKahlil/LongTake</link>
    <description>Crash-resilient macOS screen &amp; dual-track audio recorder updates</description>
    <language>zh-cn</language>
    <item>
      <title>LongTake ${VERSION}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${BUILD_NUM}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>12.3</sparkle:minimumSystemVersion>
      <description><![CDATA[
        <h2>LongTake v${VERSION} (Build ${BUILD_NUM})</h2>
        <ul>
          <li>Session-isolated recording state machine &amp; callback draining before AVAssetWriter finalization</li>
          <li>Unified monotonic pause/resume timeline across video, system audio, and microphone</li>
          <li>Zero-copy buffer use-after-free fix, 64-bit &gt;24h offline mixing, collision-free file allocation, and full Quit protection</li>
          <li>Sparkle 2.10.1 self-hosted EdDSA OTA channel for HazelKahlil/LongTake with active-recording relaunch guard</li>
        </ul>
      ]]></description>
      <enclosure
        url="https://github.com/HazelKahlil/LongTake/releases/download/v${VERSION}/${ARCHIVE_NAME}"
        sparkle:edSignature="${ED_SIG}"
        length="${ARCHIVE_LEN}"
        type="application/octet-stream" />
    </item>
  </channel>
</rss>
EOF

# Unregister intermediate DerivedData app from LaunchServices before cleanup
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREG" && -d "$BUILT_APP" ]]; then
  "$LSREG" -u "$BUILT_APP" >/dev/null 2>&1 || true
fi

if [[ "$INSTALL_LOCAL" == "1" ]]; then
  echo "[release-ota] Installing signed LongTake.app to /Applications/LongTake.app..."
  rm -rf /Applications/LongTake.app
  cp -R "$STAGED_APP" /Applications/LongTake.app
  "$LSREG" -f /Applications/LongTake.app >/dev/null 2>&1 || true
fi

echo "[release-ota] Done. Archive: $ARCHIVE_PATH ($ARCHIVE_LEN bytes), appcast: $ROOT/appcast.xml"
