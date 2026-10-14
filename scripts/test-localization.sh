#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/control-deck-localization.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
APP="$SCRATCH/ControlDeck.app"
RESOURCES="$APP/Contents/Resources"
mkdir -p "$APP/Contents/MacOS" "$RESOURCES/ControlDeck_ControlDeck.bundle"
xcrun swiftc -parse-as-library -framework AppKit \
  "$ROOT/Sources/ControlDeck/AppResources.swift" \
  "$ROOT/Sources/ControlDeck/Models.swift" \
  "$ROOT/Sources/ControlDeck/InputMappingModels.swift" \
  "$ROOT/Sources/ControlDeck/GyroModels.swift" \
  "$ROOT/Sources/ControlDeck/ExpandedProfileCatalog.swift" \
  "$ROOT/Tests/ControlDeckTests/LocalizationSmoke.swift" \
  -o "$APP/Contents/MacOS/control-deck"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
for locale in en zh-Hans ja; do
  cp -R "$ROOT/Sources/ControlDeck/Resources/$locale.lproj" "$RESOURCES/"
  cp -R "$ROOT/Sources/ControlDeck/Resources/$locale.lproj" "$RESOURCES/ControlDeck_ControlDeck.bundle/"
done
cat > "$RESOURCES/ControlDeck_ControlDeck.bundle/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleIdentifier</key><string>com.controldeck.localization-test</string>
</dict></plist>
PLIST
# Optionally validate the actual packaged tables instead of the source fixture.
if [[ $# -gt 0 ]]; then
  rm -rf "$RESOURCES"
  cp -R "$1/Contents/Resources" "$RESOURCES"
fi
# Process-local overrides only: never alter the user's system/app language defaults.
for locale in en zh-Hans ja fr; do
  "$APP/Contents/MacOS/control-deck" "$locale" -AppleLanguages "($locale)"
done
