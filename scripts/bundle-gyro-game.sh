#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GAME="$ROOT/Sources/ControlDeck/Resources/GyroGame"
npx --yes esbuild@0.25.12 "$GAME/game.js" --bundle --minify --format=iife --outfile="$GAME/game.bundle.js"
# Three.js embeds GLSL with mixed indentation/trailing spaces. Normalize only
# whitespace at line edges to keep the generated bundle free of diff warnings.
python3 - "$GAME/game.bundle.js" <<'PY'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
path.write_text('\n'.join(re.sub(r'^ +(?=\t)', '', line.rstrip()) for line in path.read_text().splitlines()) + '\n')
PY
