#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OPUS_VERSION="1.6.1"
OPUS_SHA256="6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1"
OPUS_LICENSE_SHA256="01e1167d54a096d123cf6dfbbeb19587278845c6481d2d66d545669846079551"
DEPLOYMENT_TARGET="14.0"
SOURCE_URL="https://downloads.xiph.org/releases/opus/opus-$OPUS_VERSION.tar.gz"
CACHE_DIR="${OPUS_SOURCE_CACHE_DIR:-$ROOT/.build/vendor-cache}"
BUILD_ROOT="$ROOT/.build/vendor/opus-$OPUS_VERSION-macos$DEPLOYMENT_TARGET"
OUTPUT_PREFIX="$BUILD_ROOT/universal"
OUTPUT_DYLIB="$OUTPUT_PREFIX/lib/libopus.0.dylib"
STAMP="$OUTPUT_PREFIX/.build-stamp"
EXPECTED_STAMP="opus=$OPUS_VERSION sha256=$OPUS_SHA256 macos=$DEPLOYMENT_TARGET archs=arm64,x86_64"
REPOSITORY_LICENSE="$ROOT/Resources/ThirdPartyLicenses/Opus-COPYING.txt"

if [[ "${1:-}" == "--print-prefix" ]]; then
  print -r -- "$OUTPUT_PREFIX"
  exit 0
fi

if [[ $# -ne 0 ]]; then
  print -u2 "usage: $0 [--print-prefix]"
  exit 64
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

verify_universal_library() {
  local binary="$1"

  [[ -f "$binary" ]] || return 1
  local architecture
  for architecture in arm64 x86_64; do
    lipo "$binary" -verify_arch "$architecture" >/dev/null || return 1
    [[ "$(minimum_macos_version "$binary" "$architecture")" == "$DEPLOYMENT_TARGET" ]] ||
      return 1
    [[ "$(otool -arch "$architecture" -D "$binary" | sed -n '2p')" == \
      "@rpath/libopus.0.dylib" ]] || return 1
  done
}

verify_repository_license() {
  [[ -f "$REPOSITORY_LICENSE" ]] &&
    [[ "$(shasum -a 256 "$REPOSITORY_LICENSE" | awk '{print $1}')" == \
      "$OPUS_LICENSE_SHA256" ]]
}

if [[ -f "$STAMP" ]] &&
  [[ "$(<"$STAMP")" == "$EXPECTED_STAMP" ]] &&
  verify_universal_library "$OUTPUT_DYLIB" &&
  verify_repository_license &&
  cmp -s \
    "$REPOSITORY_LICENSE" \
    "$OUTPUT_PREFIX/share/licenses/opus/COPYING"; then
  print "Using cached universal Opus $OPUS_VERSION: $OUTPUT_DYLIB"
  exit 0
fi

command -v curl >/dev/null || {
  print -u2 "curl is required to download the official Opus source archive."
  exit 1
}
command -v make >/dev/null || {
  print -u2 "make is required to build Opus."
  exit 1
}
command -v lipo >/dev/null || {
  print -u2 "lipo is required to create the universal Opus library."
  exit 1
}

mkdir -p "$CACHE_DIR"
ARCHIVE="$CACHE_DIR/opus-$OPUS_VERSION.tar.gz"

if [[ ! -f "$ARCHIVE" ]] ||
  [[ "$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')" != "$OPUS_SHA256" ]]; then
  DOWNLOAD="$ARCHIVE.download.$$"
  trap 'rm -f "$DOWNLOAD"' EXIT INT TERM
  print "Downloading official Opus $OPUS_VERSION source..."
  curl \
    --fail \
    --location \
    --proto '=https' \
    --show-error \
    --silent \
    --tlsv1.2 \
    --output "$DOWNLOAD" \
    "$SOURCE_URL"

  ACTUAL_SHA256="$(shasum -a 256 "$DOWNLOAD" | awk '{print $1}')"
  if [[ "$ACTUAL_SHA256" != "$OPUS_SHA256" ]]; then
    print -u2 "Opus source checksum mismatch."
    print -u2 "Expected: $OPUS_SHA256"
    print -u2 "Actual:   $ACTUAL_SHA256"
    exit 1
  fi
  mv "$DOWNLOAD" "$ARCHIVE"
  trap - EXIT INT TERM
fi

SOURCE_DIR="$BUILD_ROOT/source"
rm -rf "$BUILD_ROOT"
mkdir -p "$SOURCE_DIR"
tar -xzf "$ARCHIVE" -C "$SOURCE_DIR" --strip-components=1

ACTUAL_LICENSE_SHA256="$(shasum -a 256 "$SOURCE_DIR/COPYING" | awk '{print $1}')"
if [[ "$ACTUAL_LICENSE_SHA256" != "$OPUS_LICENSE_SHA256" ]]; then
  print -u2 "The license in the Opus source archive does not match the pinned release."
  exit 1
fi
if [[ ! -f "$REPOSITORY_LICENSE" ]] ||
  ! cmp -s "$SOURCE_DIR/COPYING" "$REPOSITORY_LICENSE"; then
  print -u2 "Resources/ThirdPartyLicenses/Opus-COPYING.txt must exactly match Opus $OPUS_VERSION COPYING."
  exit 1
fi

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
CLANG="$(xcrun --find clang)"
JOBS="$(sysctl -n hw.logicalcpu 2>/dev/null || print 4)"

build_architecture() {
  local architecture="$1"
  local host="$2"
  local build_dir="$BUILD_ROOT/build-$architecture"
  local prefix="$BUILD_ROOT/prefix-$architecture"
  local architecture_flags="-O2 -arch $architecture -mmacosx-version-min=$DEPLOYMENT_TARGET -isysroot $SDK_PATH"
  local linker_flags="-arch $architecture -mmacosx-version-min=$DEPLOYMENT_TARGET -isysroot $SDK_PATH"

  mkdir -p "$build_dir"
  print "Building Opus $OPUS_VERSION for $architecture (macOS $DEPLOYMENT_TARGET)..."
  (
    cd "$build_dir"
    CC="$CLANG" \
      CFLAGS="$architecture_flags" \
      LDFLAGS="$linker_flags" \
      "$SOURCE_DIR/configure" \
        "--host=$host" \
        "--prefix=$prefix" \
        --enable-shared \
        --disable-static \
        --disable-extra-programs \
        --disable-doc
    make "-j$JOBS"
    make install
  )
}

build_architecture "arm64" "arm64-apple-darwin"
build_architecture "x86_64" "x86_64-apple-darwin"

ARM_PREFIX="$BUILD_ROOT/prefix-arm64"
INTEL_PREFIX="$BUILD_ROOT/prefix-x86_64"
mkdir -p \
  "$OUTPUT_PREFIX/include" \
  "$OUTPUT_PREFIX/lib/pkgconfig" \
  "$OUTPUT_PREFIX/share/licenses/opus"
cp -R "$ARM_PREFIX/include/" "$OUTPUT_PREFIX/include/"
cp "$ARM_PREFIX/lib/pkgconfig/opus.pc" "$OUTPUT_PREFIX/lib/pkgconfig/opus.pc"
perl -pi -e "s{^prefix=.*}{prefix=$OUTPUT_PREFIX}" "$OUTPUT_PREFIX/lib/pkgconfig/opus.pc"
cp "$REPOSITORY_LICENSE" "$OUTPUT_PREFIX/share/licenses/opus/COPYING"

lipo -create \
  "$ARM_PREFIX/lib/libopus.0.dylib" \
  "$INTEL_PREFIX/lib/libopus.0.dylib" \
  -output "$OUTPUT_DYLIB"
install_name_tool -id "@rpath/libopus.0.dylib" "$OUTPUT_DYLIB"
ln -s "libopus.0.dylib" "$OUTPUT_PREFIX/lib/libopus.dylib"

verify_universal_library "$OUTPUT_DYLIB" || {
  print -u2 "The universal Opus library failed architecture, deployment target, or install-name validation."
  exit 1
}

print -r -- "$EXPECTED_STAMP" >"$STAMP"
print "Built universal Opus $OPUS_VERSION: $OUTPUT_DYLIB"
