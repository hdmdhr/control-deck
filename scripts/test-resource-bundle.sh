#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/control-deck-resources.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
ulimit -c 0

# Build the production resource/image loaders in a dependency-free SwiftPM
# fixture. A real generated Bundle.module accessor is essential to this test.
FIXTURE="$SCRATCH/fixture"
SOURCE="$FIXTURE/Sources/ControlDeck"
mkdir -p "$SOURCE"
cp "$ROOT/Sources/ControlDeck/AppResources.swift" "$SOURCE/"
cp "$ROOT/Sources/ControlDeck/DesignSupport.swift" "$SOURCE/"
cp "$ROOT/Tests/ControlDeckTests/ResourceBundleSmoke.swift" "$SOURCE/"
cp -R "$ROOT/Sources/ControlDeck/Resources" "$SOURCE/Resources"
cat > "$FIXTURE/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "ControlDeck",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(
        name: "ControlDeck", resources: [.process("Resources")]
    )],
    swiftLanguageModes: [.v5]
)
SWIFT

xcrun swift build --package-path "$FIXTURE" -c release
BIN="$(xcrun swift build --package-path "$FIXTURE" -c release --show-bin-path)"
"$BIN/ControlDeck"

# Newer SwiftPM versions also search Contents/Resources. Exercise the Swift 6.2
# accessor used by v1.1.1 as well, so a toolchain upgrade cannot hide a regression.
cat > "$SCRATCH/legacy_resource_bundle_accessor.swift" <<SWIFT
import Foundation
extension Foundation.Bundle {
    static let module: Bundle = {
        let mainPath = Bundle.main.bundleURL
            .appendingPathComponent("ControlDeck_ControlDeck.bundle").path
        let buildPath = #"$BIN/ControlDeck_ControlDeck.bundle"#
        guard let bundle = Bundle(path: mainPath) ?? Bundle(path: buildPath) else {
            Swift.fatalError("could not load resource bundle: from \\(mainPath) or \\(buildPath)")
        }
        return bundle
    }()
}
SWIFT
xcrun swiftc -parse-as-library -swift-version 5 -O \
  "$SOURCE/AppResources.swift" "$SOURCE/DesignSupport.swift" \
  "$SOURCE/ResourceBundleSmoke.swift" \
  "$SCRATCH/legacy_resource_bundle_accessor.swift" \
  -o "$SCRATCH/legacy-loader"
"$SCRATCH/legacy-loader"

APP="$SCRATCH/Relocated App/ControlDeck.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/ControlDeck" "$APP/Contents/MacOS/ControlDeck"
cp -R "$BIN/ControlDeck_ControlDeck.bundle" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.ianhansel.controldeck.resource-test</string>
<key>CFBundleExecutable</key><string>ControlDeck</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST

LEGACY_APP="$SCRATCH/Relocated App/Legacy.app"
cp -R "$APP" "$LEGACY_APP"
cp "$SCRATCH/legacy-loader" "$LEGACY_APP/Contents/MacOS/ControlDeck"

# Remove the build-time fallback entirely, as on a user's fresh installation.
mv "$FIXTURE/.build" "$SCRATCH/unavailable-build"
cd "$SCRATCH"
"$LEGACY_APP/Contents/MacOS/ControlDeck"
"$APP/Contents/MacOS/ControlDeck"

# A broken installation should use the existing UI/error fallbacks, not trap.
mv "$LEGACY_APP/Contents/Resources/ControlDeck_ControlDeck.bundle" "$SCRATCH/legacy-resources"
"$LEGACY_APP/Contents/MacOS/ControlDeck" --expect-missing
mv "$APP/Contents/Resources/ControlDeck_ControlDeck.bundle" "$SCRATCH/resources"
"$APP/Contents/MacOS/ControlDeck" --expect-missing
