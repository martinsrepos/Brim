#!/bin/bash
# Builds Brim.app using only the Xcode Command Line Tools (no Xcode project needed).
#
#   ./build.sh           build into ./build/Brim.app
#   ./build.sh run       build and launch
#   ./build.sh install   build, copy to /Applications and launch
#   ./build.sh dmg       build for Apple silicon and Intel, and pack build/Brim-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Brim"
APP="build/$APP_NAME.app"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Install Apple's Command Line Tools first:"
  echo "  xcode-select --install"
  exit 1
fi

MODE="${1:-}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
# A DMG is for other Macs too: build for both kinds of processor.
if [[ "$MODE" == "dmg" ]]; then ARCHS="arm64 x86_64"; else ARCHS="$(uname -m)"; fi

rm -rf "$APP" build/obj
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for ARCH in $ARCHS; do
echo "Compiling $APP_NAME for $ARCH..."
mkdir -p "build/obj/$ARCH"
swiftc Sources/*.swift \
  -module-name "$APP_NAME" \
  -o "build/obj/$ARCH/$APP_NAME" \
  -sdk "$SDK" \
  -target "$ARCH-apple-macos14.0" \
  -parse-as-library \
  -O \
  -framework AppKit \
  -framework SwiftUI \
  -framework IOKit \
  -framework IOBluetooth \
  -framework ServiceManagement \
  -framework Security \
  -framework EventKit \
  -framework CoreAudio \
  -framework CoreMediaIO \
  -framework CoreBluetooth \
  -framework CoreLocation \
  -framework AVFoundation \
  -framework PDFKit \
  -framework Speech \
  -lsqlite3
done
# One binary holding every architecture built.
lipo -create build/obj/*/"$APP_NAME" -output "$APP/Contents/MacOS/$APP_NAME"

cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Vendor/mediaremote-adapter/LICENSE "$APP/Contents/Resources/mediaremote-adapter-LICENSE.txt"

# Now Playing helper (Vendor/mediaremote-adapter, BSD license): lets Brim see
# what any app is playing, browsers included. Optional: if it doesn't build,
# Brim still works with Spotify and Apple Music.
ADAPTER="Vendor/mediaremote-adapter"
FW="$APP/Contents/Frameworks/MediaRemoteAdapter.framework"
echo "Compiling Now Playing helper..."
mkdir -p "$FW/Versions/A/Resources"
ARCH_FLAGS=()
for ARCH in $ARCHS; do ARCH_FLAGS+=(-arch "$ARCH"); done
if clang -fobjc-arc -fvisibility=default -dynamiclib \
     "${ARCH_FLAGS[@]}" -isysroot "$SDK" -mmacosx-version-min=14.0 \
     -install_name "@rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter" \
     -I "$ADAPTER/include" -I "$ADAPTER/src" \
     "$ADAPTER"/src/adapter/*.m "$ADAPTER"/src/private/*.m "$ADAPTER"/src/utility/*.m \
     -framework Foundation -framework CoreFoundation -framework AppKit -framework UniformTypeIdentifiers \
     -o "$FW/Versions/A/MediaRemoteAdapter" 2> build/adapter.log; then
  ln -sfn A "$FW/Versions/Current"
  ln -sfn Versions/Current/MediaRemoteAdapter "$FW/MediaRemoteAdapter"
  ln -sfn Versions/Current/Resources "$FW/Resources"
  cat > "$FW/Versions/A/Resources/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>MediaRemoteAdapter</string>
    <key>CFBundleIdentifier</key><string>app.brim.MediaRemoteAdapter</string>
    <key>CFBundleName</key><string>MediaRemoteAdapter</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
</dict>
</plist>
PLIST
  cp "$ADAPTER/bin/mediaremote-adapter.pl" "$APP/Contents/Resources/"
else
  echo "Note: the Now Playing helper didn't build. Brim will still work with"
  echo "      Spotify and Apple Music. The reason (also in build/adapter.log):"
  grep -m 8 -E "error|Error|ld:" build/adapter.log | sed 's/^/      /' || tail -n 8 build/adapter.log
  rm -rf "$APP/Contents/Frameworks"
fi

# Signing. macOS remembers permissions (Full Disk Access, Automation) per
# signature. An ad-hoc signature ("-") changes on every build, so you'd have to
# re-grant after each rebuild. Create a self-signed certificate once (see README)
# and set BRIM_SIGN_IDENTITY to its name (HALO_SIGN_IDENTITY still works) to keep permissions across rebuilds.
IDENTITY="${BRIM_SIGN_IDENTITY:-${HALO_SIGN_IDENTITY:--}}"
if [[ -d "$FW" ]]; then
  codesign --force --sign "$IDENTITY" "$FW" >/dev/null
fi
codesign --force --sign "$IDENTITY" "$APP" >/dev/null
echo "Built $APP"

case "$MODE" in
  run)
    pkill -x "$APP_NAME" 2>/dev/null || true
    open "$APP"
    ;;
  install)
    pkill -x "$APP_NAME" 2>/dev/null || true
    # Brim used to be called Halo: the old app goes (its settings and
    # scripts move over to Brim on first launch).
    if [[ -d "/Applications/Halo.app" ]]; then
      pkill -x Halo 2>/dev/null || true
      rm -rf "/Applications/Halo.app"
      echo "Removed the old Halo.app"
    fi
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" /Applications/
    open "/Applications/$APP_NAME.app"
    echo "Installed to /Applications and launched."
    ;;
  dmg)
    if [[ "$IDENTITY" == "-" ]]; then
      echo "Warning: signing ad hoc. Brim's Update button only installs releases signed with"
      echo "the same certificate as the copy people have, so publish with BRIM_SIGN_IDENTITY set."
    fi
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist 2>/dev/null || echo 1.0)"
    DMG="build/$APP_NAME-$VERSION.dmg"
    STAGE="build/dmg"
    rm -rf "$STAGE" "$DMG" build/rw.dmg
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    # A writable image first, so Finder can lay out the window...
    hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDRW build/rw.dmg >/dev/null
    MOUNT="$(hdiutil attach -readwrite -noverify -noautoopen build/rw.dmg | awk -F'\t' '/\/Volumes\// {print $NF; exit}')"
    # ...the app on the left, Applications on the right, big icons. If Finder
    # can't be scripted (no permission), the DMG still works, just unarranged.
    osascript >/dev/null 2>&1 <<APPLESCRIPT || echo "Note: couldn't arrange the DMG window (Finder automation); it still works."
tell application "Finder"
  tell disk "$APP_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 760, 460}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set position of item "$APP_NAME.app" of container window to {140, 160}
    set position of item "Applications" of container window to {420, 160}
    close
  end tell
end tell
APPLESCRIPT
    sync
    hdiutil detach "$MOUNT" -quiet || hdiutil detach "$MOUNT" -force -quiet
    # ...then compressed and read-only, which is what people download.
    hdiutil convert build/rw.dmg -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
    rm -f build/rw.dmg
    rm -rf "$STAGE"
    codesign --force --sign "$IDENTITY" "$DMG" >/dev/null 2>&1 || true
    echo "Made $DMG ($(lipo -archs "$APP/Contents/MacOS/$APP_NAME"))"
    ;;
esac
