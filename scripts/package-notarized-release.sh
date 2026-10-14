#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${DEVELOPER_ID_APPLICATION:?Set DEVELOPER_ID_APPLICATION to an installed Developer ID Application identity}"
: "${NOTARYTOOL_PROFILE:?Set NOTARYTOOL_PROFILE to an xcrun notarytool keychain profile}"
WORK_DIR="$(mktemp -d -t control-deck-release)"
APP_ENTITLEMENTS="$ROOT/Resources/ControlDeck.entitlements"

cleanup() {
  if mount | grep -Fq "on /Volumes/ControlDeck Installer "; then
    hdiutil detach "/Volumes/ControlDeck Installer" >/dev/null 2>&1 || true
  fi
  if mount | grep -Fq "on $WORK_DIR/dmg-mount "; then
    hdiutil detach "$WORK_DIR/dmg-mount" >/dev/null 2>&1 || true
  fi
  [[ ! -d "$WORK_DIR" ]] || rm -r "$WORK_DIR" 2>/dev/null || true
}

trap cleanup EXIT

if [[ "${1:-}" != "--no-build" ]]; then
  "$ROOT/scripts/build-app.sh"
fi

package_and_notarize() {
  local app_name="$1"
  local app="$ROOT/dist/$app_name.app"
  local framework="$app/Contents/Frameworks/libopus.0.dylib"
  local app_submission="$WORK_DIR/$app_name-app.zip"
  local dmg="$WORK_DIR/$app_name.dmg"
  local writable_dmg="$WORK_DIR/$app_name-writable.dmg"
  local dmg_background="$WORK_DIR/dmg-background.png"
  local volume_name="$app_name Installer"
  local layout_mount_point="/Volumes/$volume_name"
  local mount_point="$WORK_DIR/dmg-mount"
  local zip="$WORK_DIR/$app_name.zip"

  local architecture
  for architecture in arm64 x86_64; do
    if ! lipo "$app/Contents/MacOS/control-deck" \
      -verify_arch "$architecture"; then
      print -u2 \
        "Refusing to package a development-only build; rebuild the universal app first."
      return 1
    fi
  done
  "$ROOT/scripts/verify-no-bundled-speech-models.sh" "$app"

  codesign \
    --force \
    --timestamp \
    --options runtime \
    --sign "$DEVELOPER_ID_APPLICATION" \
    "$framework"
  codesign \
    --force \
    --timestamp \
    --options runtime \
    --entitlements "$APP_ENTITLEMENTS" \
    --sign "$DEVELOPER_ID_APPLICATION" \
    "$app"
  codesign --verify --deep --strict --verbose=2 "$app"
  codesign -d --entitlements - "$app" 2>/dev/null |
    grep -q 'com.apple.security.device.audio-input'

  ditto -c -k --sequesterRsrc --keepParent "$app" "$app_submission"
  xcrun notarytool submit \
    "$app_submission" \
    --keychain-profile "$NOTARYTOOL_PROFILE" \
    --wait
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  spctl --assess --type execute --verbose=4 "$app"

  ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"

  sips \
    -s format png \
    "$ROOT/Resources/DMGBackground.svg" \
    --out "$dmg_background" >/dev/null

  hdiutil create \
    -size 128m \
    -fs HFS+ \
    -volname "$volume_name" \
    -ov \
    "$writable_dmg" >/dev/null

  [[ ! -e "$layout_mount_point" ]]
  hdiutil attach \
    -readwrite \
    -noverify \
    -noautoopen \
    "$writable_dmg" >/dev/null
  [[ -d "$layout_mount_point" ]]
  ditto "$app" "$layout_mount_point/$app_name.app"
  ln -s /Applications "$layout_mount_point/Applications"
  mkdir "$layout_mount_point/.background"
  cp "$dmg_background" "$layout_mount_point/.background/dmg-background.png"
  chflags hidden "$layout_mount_point/.background"
  mkdir -p "$layout_mount_point/.fseventsd"
  touch "$layout_mount_point/.fseventsd/no_log"
  chflags hidden "$layout_mount_point/.fseventsd"

  osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$volume_name"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set pathbar visible of container window to false
    set bounds of container window to {120, 120, 840, 580}
    set theViewOptions to icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 112
    set text size of theViewOptions to 13
    set background picture of theViewOptions to file ".background:dmg-background.png"
    set position of item "$app_name.app" of container window to {190, 250}
    set position of item "Applications" of container window to {530, 250}
    try
      set position of item ".background" of container window to {900, 650}
      set position of item ".fseventsd" of container window to {900, 760}
    end try
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
  sync
  hdiutil detach "$layout_mount_point" >/dev/null
  hdiutil convert \
    "$writable_dmg" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    -o "$dmg" >/dev/null
  codesign \
    --force \
    --timestamp \
    --sign "$DEVELOPER_ID_APPLICATION" \
    "$dmg"
  codesign --verify --verbose=2 "$dmg"
  xcrun notarytool submit \
    "$dmg" \
    --keychain-profile "$NOTARYTOOL_PROFILE" \
    --wait
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
  spctl \
    --assess \
    --type open \
    --context context:primary-signature \
    --verbose=4 \
    "$dmg"

  mkdir -p "$mount_point"
  hdiutil attach \
    -nobrowse \
    -readonly \
    -mountpoint "$mount_point" \
    "$dmg" >/dev/null
  local mount_validation=0
  codesign \
    --verify \
    --deep \
    --strict \
    --verbose=2 \
    "$mount_point/$app_name.app" || mount_validation=$?
  [[ "$(readlink "$mount_point/Applications")" == "/Applications" ]] || \
    mount_validation=1
  [[ -f "$mount_point/.background/dmg-background.png" ]] || \
    mount_validation=1
  [[ -f "$mount_point/.DS_Store" ]] || mount_validation=1
  hdiutil detach "$mount_point" >/dev/null || mount_validation=$?
  (( mount_validation == 0 ))

  mv -f "$zip" "$ROOT/dist/$app_name.zip"
  mv -f "$dmg" "$ROOT/dist/$app_name.dmg"
}

package_and_notarize "ControlDeck"

shasum -a 256 \
  "$ROOT/dist/ControlDeck.dmg" \
  "$ROOT/dist/ControlDeck.zip"
