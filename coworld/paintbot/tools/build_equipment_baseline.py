"""Build the public WASM baseline with Paintbot territory objectives and equipment.

Usage: python build_equipment_baseline.py /path/to/cogame-paintbot-cdx
Requires that checkout's Nimby dependencies and WASI_SDK_PATH.
"""

import hashlib
import json
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


# Keep the territory adaptation reviewable in this repository. Match each
# insertion point exactly so an upstream update cannot silently drop the fix.
def replace_once(old, new):
    global code
    if code.count(old) != 1:
        raise ValueError(f"Upstream territory insertion point changed: {old}")
    code = code.replace(old, new)


replace_once(
    "proc decide(bot: Bot",
    (root / "coworld/paintbot/players/territory.nim").read_text()
    + "\nproc decide(bot: Bot",
)
replace_once(
    "  # Flag bookkeeping (two flags;",
    "  let territory = territoryGoal(client, me, bot.team)\n\n  # Flag bookkeeping (two flags;",
)
replace_once(
    "stealTarget = flagHome(enemy(bot.team))",
    "stealTarget = (if territory.active: territory.target else: flagHome(enemy(bot.team)))",
)
replace_once(
    '  var objMode = "attack"\n  if iCarry:',
    '  var objMode = "attack"\n  if territory.active:\n    target = territory.target\n    objMode = "control_heart"\n  elif iCarry:',
)
replace_once(
    "  # Stuck detection: if we have not moved",
    """  # Territory movement owns the destination even when CTF combat/role logic
  # would chase a static pedestal or pickup. Keep turret/equipment decisions.
  if territory.active and not nadeDanger:
    target = territory.target
    objMode = "control_heart"
    holdStill = dist(me, target) <= 20.0 and bot.gridRayClear(me, target)
    if holdStill:
      moveMask = 0
      bot.jinkUntil = 0
    else:
      moveMask = octantBits(bot.navSteer(client, me, target))
      if bot.tick < bot.jinkUntil:
        moveMask = bot.jinkBits

  # Stuck detection: if we have not moved""",
)
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

artifact = root / "coworld/paintbot/players/baseline.wasm"
manifest = {
    "upstream_commit": subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=source, text=True
    ).strip(),
    "upstream_baseline_sha256": hashlib.sha256(
        (source / "players/baseline/baseline.nim").read_bytes()
    ).hexdigest(),
    "adapted_baseline_sha256": hashlib.sha256(p.read_bytes()).hexdigest(),
    "wasm_sha256": hashlib.sha256(artifact.read_bytes()).hexdigest(),
}
artifact.with_suffix(".build.json").write_text(json.dumps(manifest, indent=2) + "\n")
