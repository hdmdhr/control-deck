#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_KIND="${1:-universal}"
case "$BUILD_KIND" in
  --development|development)
    BUILD_KIND="development"
    ;;
  --universal|universal)
    BUILD_KIND="universal"
    ;;
  *)
    print -u2 "usage: $0 [--development|--universal]"
    exit 2
    ;;
esac

# Prefer the complete, internally matched Xcode toolchain when it is present.
# A partially updated CommandLineTools SDK/compiler pair can otherwise make an
# unattended reload fail before compilation begins.
if [[ -z "${DEVELOPER_DIR:-}" &&
      -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi
SWIFT=(xcrun swift)
BINARY=""
RESOURCE_BUNDLE=""
ARM64_TRIPLE="arm64-apple-macosx14.0"
X86_64_TRIPLE="x86_64-apple-macosx14.0"
ARM64_SCRATCH="$ROOT/.build/release-arm64"
X86_64_SCRATCH="$ROOT/.build/release-x86_64"
UNIVERSAL_OUTPUT="$ROOT/.build/release-universal/control-deck"
OPUS_PREFIX="$("$ROOT/scripts/build-opus.sh" --print-prefix)"
OPUS_DYLIB="$OPUS_PREFIX/lib/libopus.0.dylib"
OPUS_DEPLOYMENT_TARGET="14.0"
APP_ENTITLEMENTS="$ROOT/Resources/ControlDeck.entitlements"
DEVELOPMENT_SIGNING_IDENTITY_FILE="${CONTROLDECK_DEVELOPMENT_SIGNING_IDENTITY_FILE:-$ROOT/.codex/development-signing-identity}"
DEVELOPMENT_SIGNING_IDENTITY="${CONTROLDECK_DEVELOPMENT_SIGNING_IDENTITY:-}"

if [[ "$BUILD_KIND" == "development" &&
      -z "$DEVELOPMENT_SIGNING_IDENTITY" &&
      -r "$DEVELOPMENT_SIGNING_IDENTITY_FILE" ]]; then
  IFS= read -r DEVELOPMENT_SIGNING_IDENTITY \
    < "$DEVELOPMENT_SIGNING_IDENTITY_FILE"
fi

minimum_macos_version() {
  local binary="$1"
  local architecture="$2"
  otool -arch "$architecture" -l "$binary" |
    awk '
      $1 == "cmd" && $2 == "LC_BUILD_VERSION" { in_build_version = 1; next }
      in_build_version && $1 == "minos" { print $2; exit }
    '
}

verify_bundled_opus() {
  local binary="$1"

  local architecture
  for architecture in arm64 x86_64; do
    lipo "$binary" -verify_arch "$architecture"
    [[ "$(minimum_macos_version "$binary" "$architecture")" == \
      "$OPUS_DEPLOYMENT_TARGET" ]]
    [[ "$(otool -arch "$architecture" -D "$binary" | sed -n '2p')" == \
      "@rpath/libopus.0.dylib" ]]
  done
}

verify_universal_executable() {
  local binary="$1"

  local architecture
  for architecture in arm64 x86_64; do
    lipo "$binary" -verify_arch "$architecture"
    [[ "$(minimum_macos_version "$binary" "$architecture")" == \
      "$OPUS_DEPLOYMENT_TARGET" ]]
  done
}

verify_development_executable() {
  local binary="$1"
  local architecture
  architecture="$(uname -m)"

  lipo "$binary" -verify_arch "$architecture"
  [[ "$(minimum_macos_version "$binary" "$architecture")" == \
    "$OPUS_DEPLOYMENT_TARGET" ]]
}

package_app() {
  local app_name="$1"
  local plist="$2"
  local bundle_id="$3"
  local icon="${4:-}"
  local app="$ROOT/dist/$app_name.app"
  local contents="$app/Contents"
  local macos="$contents/MacOS"
  local frameworks="$contents/Frameworks"
  local resources="$contents/Resources"
  local licenses="$resources/ThirdPartyLicenses"
  local signing_identity="-"
  local signing_options=()
  local signing_requirements=(
    --requirements "=designated => identifier \"$bundle_id\""
  )

  if [[ "$BUILD_KIND" == "development" &&
        -n "$DEVELOPMENT_SIGNING_IDENTITY" ]]; then
    signing_identity="$DEVELOPMENT_SIGNING_IDENTITY"
    signing_options=(--options runtime)
    signing_requirements=()
  fi

  rm -rf "$app"
  mkdir -p "$macos" "$frameworks" "$resources" "$licenses"
  cp "$BINARY" "$macos/control-deck"
  cp "$OPUS_DYLIB" "$frameworks/libopus.0.dylib"
  cp \
    "$ROOT/Resources/ThirdPartyLicenses/Opus-COPYING.txt" \
    "$licenses/Opus-COPYING.txt"
  cp \
    "$ROOT/.build/checkouts/FluidAudio/LICENSE" \
    "$licenses/FluidAudio-Apache-2.0.txt"
  cp \
    "$ROOT/.build/checkouts/argmax-oss-swift/LICENSE" \
    "$licenses/WhisperKit-MIT.txt"
  cp \
    "$ROOT/.build/checkouts/argmax-oss-swift/NOTICES" \
    "$licenses/WhisperKit-NOTICES.txt"
  cp \
    "$ROOT/Resources/ThirdPartyLicenses/Parakeet-MODEL-NOTICE.txt" \
    "$licenses/Parakeet-MODEL-NOTICE.txt"
  cp "$plist" "$contents/Info.plist"
  if [[ -n "$icon" ]]; then
    cp "$icon" "$resources/$(basename "$icon")"
  fi
  cp -R "$RESOURCE_BUNDLE" "$resources/ControlDeck_ControlDeck.bundle"
  # SwiftUI's app-level controls look up localized literals in Bundle.main.
  # Model/status strings use the same tables in the SwiftPM resource bundle.
  local locale localization
  for locale in en zh-Hans ja; do
    localization="$RESOURCE_BUNDLE/Contents/Resources/$locale.lproj"
    if [[ ! -d "$localization" ]]; then
      localization="$RESOURCE_BUNDLE/$locale.lproj"
    fi
    if [[ ! -s "$localization/Localizable.strings" ||
          ! -s "$localization/InfoPlist.strings" ]]; then
      print -u2 "Missing localization resources: $locale"
      exit 1
    fi
    cp -R "$localization" "$resources/"
  done
  local opus_load_path
  opus_load_path="$(otool -L "$macos/control-deck" | awk '/libopus/{print $1; exit}')"
  install_name_tool \
    -change "$opus_load_path" \
    "@rpath/libopus.0.dylib" \
    "$macos/control-deck"
  install_name_tool \
    -add_rpath "@executable_path/../Frameworks" \
    "$macos/control-deck"
  install_name_tool \
    -id "@rpath/libopus.0.dylib" \
    "$frameworks/libopus.0.dylib"
  # Development signing is explicit and local-only. A configured stable
  # identity keeps macOS TCC permissions attached across reloads; contributors
  # without one still get an ad-hoc runnable bundle. The release script remains
  # the only path that discovers release credentials, timestamps, notarizes,
  # staples, or publishes an artifact.
  codesign \
    --force \
    "${signing_options[@]}" \
    --sign "$signing_identity" \
    "$frameworks/libopus.0.dylib"
  codesign \
    --force \
    "${signing_options[@]}" \
    --sign "$signing_identity" \
    --entitlements "$APP_ENTITLEMENTS" \
    "${signing_requirements[@]}" \
    "$app"
  verify_bundled_opus "$frameworks/libopus.0.dylib"
  "$ROOT/scripts/verify-no-bundled-speech-models.sh" "$app"
  codesign --verify --deep --strict "$app"
  codesign -d --entitlements - "$app" 2>/dev/null |
    grep -q 'com.apple.security.device.audio-input'
  if [[ "$BUILD_KIND" == "universal" ]]; then
    verify_universal_executable "$macos/control-deck"
  else
    verify_development_executable "$macos/control-deck"
  fi
  echo "$app"
}

cd "$ROOT"
"$ROOT/scripts/build-opus.sh"
export PKG_CONFIG_PATH="$OPUS_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
if [[ "$BUILD_KIND" == "development" ]]; then
  "${SWIFT[@]}" build \
    -c debug \
    --product control-deck
  DEVELOPMENT_BINARY_DIR="$(
    "${SWIFT[@]}" build \
      -c debug \
      --product control-deck \
      --show-bin-path
  )"
  BINARY="$DEVELOPMENT_BINARY_DIR/control-deck"
  RESOURCE_BUNDLE="$DEVELOPMENT_BINARY_DIR/ControlDeck_ControlDeck.bundle"
  verify_development_executable "$BINARY"
else
  "${SWIFT[@]}" build \
    -c release \
    --product control-deck \
    --triple "$ARM64_TRIPLE" \
    --scratch-path "$ARM64_SCRATCH"
  "${SWIFT[@]}" build \
    -c release \
    --product control-deck \
    --triple "$X86_64_TRIPLE" \
    --scratch-path "$X86_64_SCRATCH"
  ARM64_BINARY_DIR="$(
    "${SWIFT[@]}" build \
      -c release \
      --product control-deck \
      --triple "$ARM64_TRIPLE" \
      --scratch-path "$ARM64_SCRATCH" \
      --show-bin-path
  )"
  X86_64_BINARY_DIR="$(
    "${SWIFT[@]}" build \
      -c release \
      --product control-deck \
      --triple "$X86_64_TRIPLE" \
      --scratch-path "$X86_64_SCRATCH" \
      --show-bin-path
  )"
  mkdir -p "$(dirname "$UNIVERSAL_OUTPUT")"
  lipo \
    -create \
    "$ARM64_BINARY_DIR/control-deck" \
    "$X86_64_BINARY_DIR/control-deck" \
    -output "$UNIVERSAL_OUTPUT"
  BINARY="$UNIVERSAL_OUTPUT"
  RESOURCE_BUNDLE="$ARM64_BINARY_DIR/ControlDeck_ControlDeck.bundle"
  verify_universal_executable "$BINARY"
fi
mkdir -p "$ROOT/dist"

package_app \
  "ControlDeck" \
  "$ROOT/Resources/Info.plist" \
  "com.ianhansel.controldeck" \
  "$ROOT/Resources/AppIcon.icns"
