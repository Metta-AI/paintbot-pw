#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
game_dir="$1"
entry="$2"
output_dir="$3"
python3 - "$repo_dir" "$output_dir" <<'PYSAFE'
from pathlib import Path
import sys
root, output = map(Path, sys.argv[1:])
if not output.is_absolute() or output.resolve() in [root, *root.parents]:
    raise SystemExit('Replay bundle output must be a separate absolute directory')
if output.is_symlink():
    raise SystemExit('Replay bundle output must not be a symlink')
PYSAFE
export POLYWORLD_DEPS="${POLYWORLD_DEPS:-$repo_dir/tmp/coworld/deps}"
export POLYWORLD_DATA="${POLYWORLD_DATA:-$repo_dir/../polyworld_data}"
python3 "$repo_dir/coworld/tools/sync_dependencies.py"
python3 - "$repo_dir" "$POLYWORLD_DATA" <<'PY'
import json, subprocess, sys
from pathlib import Path
root, data = map(Path, sys.argv[1:])
revision = json.loads((root / 'coworld/assets.json').read_text())['revision']
actual = subprocess.check_output(['git', '-C', str(data), 'rev-parse', 'HEAD'], text=True).strip()
if actual != revision:
    raise SystemExit(f'Asset revision mismatch: expected {revision}, got {actual}')
PY
cd "$repo_dir"
rm -rf "$output_dir"
mkdir -p "$output_dir"
nim c -d:emscripten -d:replayViewer "examples/$game_dir/$entry.nim"
for suffix in js wasm data; do
  cp "examples/$game_dir/emscripten/$entry.$suffix" "$output_dir/"
done
cp "examples/$game_dir/emscripten/$entry.html" "$output_dir/index.html"
