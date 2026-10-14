#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${TMPDIR:-/tmp}/control-deck-tilt-run-smoke"

swiftc \
  -framework AppKit \
  -framework WebKit \
  -o "$OUTPUT" \
  "$ROOT/Tests/ControlDeckTests/TiltRunWebKitSmoke.swift"

"$OUTPUT" "$ROOT/Sources/ControlDeck/Resources/GyroGame"

for locale in zh-Hans ja; do
  "$OUTPUT" "$ROOT/Sources/ControlDeck/Resources/GyroGame" "$locale"
done
