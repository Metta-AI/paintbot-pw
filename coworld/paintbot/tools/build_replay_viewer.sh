#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../../.." && pwd)"
output="${1:?Output directory required}"
export POLYWORLD_DEPS="${POLYWORLD_DEPS:-$root/tmp/coworld/deps}"
cd "$root"
nim c -d:emscripten -d:replayViewer examples/paintbot/paintbot.nim
mkdir -p "$output"
cp examples/paintbot/emscripten/paintbot.{js,wasm} "$output/"
python3 - "$root" "$output" <<'PY'
from pathlib import Path
import sys
root,out=map(Path,sys.argv[1:])
html=(root/'examples/paintbot/emscripten/paintbot.html').read_text()
hud='''<style>
#hud{position:absolute;top:20px;left:24px;right:24px;display:flex;justify-content:space-between;pointer-events:none;font:700 14px system-ui;letter-spacing:.1em;text-transform:uppercase;color:#c0d7dd}
#score{font-size:32px;letter-spacing:.15em;color:#fff}#score b:first-child{color:#f55960}#score b:last-child{color:#42bbf6}
#controls{position:absolute;bottom:20px;left:24px;right:24px;display:flex;gap:16px;align-items:center;background:#0d1b27e8;padding:14px 18px;border:1px solid #36505c;border-radius:10px;font:14px system-ui;color:#c0d7dd}
#controls button,#controls select{background:#243d49;color:#e3f5f6;border:1px solid #4c6974;border-radius:5px;padding:8px 14px}#scrub{flex:1;accent-color:#70d3c1}#tick{min-width:100px;font-variant-numeric:tabular-nums}
</style><div id="hud"><div>Paintbot PW<br><small>Capture the heart · first to 3</small></div><div id="score"><b id="red">0</b> : <b id="blue">0</b></div><div>Polyworld<br><small>Verified action replay</small></div></div>
<div id="controls"><button id="play">Pause</button><select id="speed" aria-label="Playback speed"><option value="1">1×</option><option value="4">4×</option><option value="16">16×</option><option value="32">32×</option></select><input id="scrub" aria-label="Replay position" type="range" min="0" value="0"><span id="tick">0 / 0</span></div>
<script>
let playing=true;
document.getElementById('play').onclick=()=>{playing=!playing;Module._pw_play(+playing);document.getElementById('play').textContent=playing?'Pause':'Play';};
document.getElementById('speed').onchange=e=>Module._pw_speed(+e.target.value);
document.getElementById('scrub').oninput=e=>Module._pw_seek(+e.target.value);
Module.paintbotHud=(tick,total,red,blue)=>{document.getElementById('red').textContent=red;document.getElementById('blue').textContent=blue;document.getElementById('scrub').max=total;document.getElementById('scrub').value=tick;document.getElementById('tick').textContent=tick+' / '+total;};
</script>'''
html=html.replace('</body>',hud+'</body>')
(out/'index.html').write_text(html)
PY
