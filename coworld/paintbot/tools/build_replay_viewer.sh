#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../../.." && pwd)"
output="${1:?Output directory required}"
export POLYWORLD_DATA="${POLYWORLD_DATA:-$root/../polyworld_data}"
export POLYWORLD_DEPS="${POLYWORLD_DEPS:-$root/tmp/coworld/deps}"
python3 - "$root" "$POLYWORLD_DATA" <<'ASSETS'
import json, subprocess, sys
from pathlib import Path
root, data = map(Path, sys.argv[1:])
expected = json.loads((root / "coworld/assets.json").read_text())["revision"]
actual = subprocess.check_output(["git", "-C", str(data), "rev-parse", "HEAD"], text=True).strip()
if actual != expected:
    raise SystemExit(f"Expected Polyworld art revision {expected}; got {actual}")
ASSETS
cd "$root"
python3 coworld/paintbot/tools/build_cover.py
python3 coworld/paintbot/tools/build_cog.py
python3 coworld/paintbot/tools/build_round_village.py
nim c -d:emscripten -d:replayIndexer examples/paintbot/indexer.nim
nim c -d:emscripten -d:replayViewer examples/paintbot/paintbot.nim
mkdir -p "$output"
cp examples/paintbot/emscripten/paintbot.{js,wasm,data} "$output/"
cp examples/paintbot/emscripten/paintbot-index.{js,wasm} "$output/"
cp "$root/coworld/paintbot/"{viewer.js,startup.js,index-worker.js} "$output/"
cp "$POLYWORLD_DATA/fonts/"Rubik-{Regular,Bold}.ttf "$output/"
cp "$root/coworld/paintbot/art/paint-crew.png" "$output/portrait.png"
python3 - "$root" "$output" <<'PY'
from pathlib import Path
import sys
root,out=map(Path,sys.argv[1:])
html=(root/'examples/paintbot/emscripten/paintbot.html').read_text()
hud=(root/'coworld/paintbot/viewer.html').read_text()
html=html.replace('</body>',hud+'</body>')
(out/'index.html').write_text(html)
PY

# GotA's live demo uses the ordinary browser client and shared webinputs loader.
nim c -d:emscripten examples/paintbot/paintbot.nim
mkdir -p "$output/play"
cp examples/paintbot/emscripten/paintbot.{js,wasm,data} "$output/play/"
cp examples/paintbot/players/base.bas "$output/play/base.bas"
cp "$output/"{viewer.js,portrait.png,Rubik-Regular.ttf,Rubik-Bold.ttf} "$output/play/"
python3 - "$root" "$output" <<'PLAY'
from pathlib import Path
import sys
root,out=map(Path,sys.argv[1:])
html=(root/'examples/paintbot/emscripten/paintbot.html').read_text()
hud=(root/'coworld/paintbot/viewer.html').read_text()
# Standalone defaults match GotA's demo: fill all seats with bundled BASIC bots.
bootstrap = """<script>
if (!location.search) location.replace('?bot=base.bas:16');
</script>"""
html=html.replace('</head>',bootstrap+'</head>')
(out/'play/index.html').write_text(html.replace('</body>',hud+'</body>'))
PLAY

# Compress the opaque Emscripten archive explicitly: the static content server
# does not apply HTTP compression to application/octet-stream. Both clients use
# the same asset layout; share the compressed package across replay and live.
python3 "$root/coworld/paintbot/tools/package_viewer.py" "$output"
