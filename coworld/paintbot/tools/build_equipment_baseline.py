"""Build the CTF WASM baseline with Paintbot PW equipment tuning.

Usage: python build_equipment_baseline.py /path/to/cogame-paintbot-cdx
Requires that checkout's Nimby dependencies and WASI_SDK_PATH.
"""

import os
from pathlib import Path
import shutil
import subprocess
import sys

source = Path(sys.argv[1]).resolve()
root = Path(__file__).resolve().parents[3]
stage = root / "tmp" / "equipment-wasm-source"
stage.mkdir(parents=True, exist_ok=True)
(stage / "players").mkdir(exist_ok=True)
shutil.copytree(
    source / "players/baseline", stage / "players/baseline", dirs_exist_ok=True
)
(stage / "singlepod").mkdir(exist_ok=True)
for name in ("baseline_wasm.nim", "config.nims"):
    shutil.copyfile(source / "singlepod" / name, stage / "singlepod" / name)
if not (stage / "src").exists():
    (stage / "src").symlink_to(source / "src", target_is_directory=True)
config = (source / "nim.cfg").read_text()
config = config.replace('--path:"', '--path:"' + str(source) + "/")
(stage / "nim.cfg").write_text(config)
p = stage / "players/baseline/baseline.nim"
code = p.read_text()
for old, new in {
    "bot.tick - bot.lastShoutTick >= 26": "bot.tick - bot.lastShoutTick >= 78",
    "NadeMaxRange = 240.0": "NadeMaxRange = 256.0",
    "NadePickupDetour = 90.0": "NadePickupDetour = 220.0",
    "SpraypaintDetour = 70.0": "SpraypaintDetour = 180.0",
    "SpraypaintReach = 187.0": "SpraypaintReach = 170.0",
}.items():
    if old not in code:
        raise ValueError(f"Upstream tuning point changed: {old}")
    code = code.replace(old, new)
p.write_text(code)
env = os.environ.copy()
subprocess.run(
    ["nim", "c", "--hints:off", "singlepod/baseline_wasm.nim"],
    cwd=stage,
    env=env,
    check=True,
)
shutil.copyfile(
    stage / "singlepod/baseline.wasm", root / "coworld/paintbot/players/baseline.wasm"
)
print(
    "Source revision:",
    subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=source, text=True
    ).strip(),
)
