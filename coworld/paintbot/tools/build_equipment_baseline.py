"""Build the public WASM baseline, `players/base_wasm.nim`, against the CTF sprite runtime.

Usage: python build_equipment_baseline.py /path/to/cogame-paintbot-cdx
Requires that checkout's Nimby dependencies and WASI_SDK_PATH (wasi-sdk 33).

The policy itself lives in this repository. Only the sprite-frame parser
(`players/baseline/baseline/protocols.nim`) and the ABI shim (`singlepod/baseline_wasm.nim`)
come from the upstream checkout, staged so `import baseline` resolves to our file.
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
players = root / "coworld/paintbot/players"
stage = root / "tmp" / "equipment-wasm-source"
if stage.exists():
    shutil.rmtree(stage)
(stage / "players/baseline/baseline").mkdir(parents=True)
(stage / "singlepod").mkdir()
shutil.copyfile(players / "base_wasm.nim", stage / "players/baseline/baseline.nim")
shutil.copyfile(
    source / "players/baseline/baseline/protocols.nim",
    stage / "players/baseline/baseline/protocols.nim",
)
for name in ("baseline_wasm.nim", "config.nims"):
    shutil.copyfile(source / "singlepod" / name, stage / "singlepod" / name)
(stage / "src").symlink_to(source / "src", target_is_directory=True)
config = (source / "nim.cfg").read_text()
config = config.replace('--path:"', '--path:"' + str(source) + "/")
(stage / "nim.cfg").write_text(config)
subprocess.run(
    ["nim", "c", "--hints:off", "singlepod/baseline_wasm.nim"],
    cwd=stage,
    env=os.environ.copy(),
    check=True,
)
artifact = players / "baseline.wasm"
shutil.copyfile(stage / "singlepod/baseline.wasm", artifact)
upstream = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
print("Upstream runtime revision:", upstream)
manifest = {
    "upstream_commit": upstream,
    "policy_sha256": hashlib.sha256((players / "base_wasm.nim").read_bytes()).hexdigest(),
    "protocols_sha256": hashlib.sha256(
        (source / "players/baseline/baseline/protocols.nim").read_bytes()
    ).hexdigest(),
    "wasm_sha256": hashlib.sha256(artifact.read_bytes()).hexdigest(),
}
artifact.with_suffix(".build.json").write_text(json.dumps(manifest, indent=2) + "\n")
