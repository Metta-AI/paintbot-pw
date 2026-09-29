"""Exercise the exact hosted handoff locally with BASIC file seats."""

import argparse
import hashlib
import json
import os
import subprocess
import time
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument("--policy", action="append", default=[])
p.add_argument("--ticks", type=int, default=14400)
p.add_argument("--seed", type=int, default=2026)
p.add_argument("--output", type=Path, required=True)
p.add_argument("--port", type=int, default=8088)
p.add_argument("--mode", choices=["teams", "ffa_kin"], default="teams")
p.add_argument("--seats", type=int, default=16, help="roster size, 2 .. 256")
p.add_argument("--map", help='the config\'s "map" (absent: the default arena)')
p.add_argument(
    "--kin-layout",
    choices=["sampled", "fours", "pairs", "trios_loner", "cousins", "strangers", "clones", "tribes"],
    help='FFA-kin only: the config\'s "kin_layout" (absent: a layout is sampled per seed)',
)
a = p.parse_args()
root = Path(__file__).resolve().parents[2]
out = a.output.resolve()
out.mkdir(parents=True, exist_ok=False)
policies = a.policy or [str(root / "examples/paintbot/players/base.bas")]
if len(policies) == 1:
    policies *= a.seats
if len(policies) != a.seats:
    raise ValueError(f"Supply one shared policy or {a.seats} file paths")
seats = []
for i, file in enumerate(policies):
    f = Path(file).resolve()
    data = f.read_bytes()
    seats.append(
        dict(
            slot=i,
            file_uri=f.as_uri(),
            content_hash="sha256:" + hashlib.sha256(data).hexdigest(),
            size_bytes=len(data),
            log_uri=(out / f"player-{i}.log").as_uri(),
            artifact_uri=(out / f"player-{i}.zip").as_uri(),
        )
    )
(out / "seats.json").write_text(
    json.dumps(
        dict(
            schema="coworld-player-seats/1",
            seats=seats,
            player_status_uri=(out / "status.json").as_uri(),
        )
    )
)
config = dict(
    players=[dict(name=f"Player {i}") for i in range(a.seats)],
    tokens=[str(i) for i in range(a.seats)],
    seed=a.seed,
    max_ticks=a.ticks,
    mode=a.mode,
)
if a.map is not None:
    config["map"] = a.map
if a.kin_layout is not None:
    config["kin_layout"] = a.kin_layout
(out / "config.json").write_text(json.dumps(config))
env = dict(
    os.environ,
    COGAME_CONFIG_URI=(out / "config.json").as_uri(),
    COGAME_PLAYER_SEATS_URI=(out / "seats.json").as_uri(),
    COGAME_RESULTS_URI=(out / "results.json").as_uri(),
    COGAME_SAVE_REPLAY_URI=(out / "replay.bin").as_uri(),
    COGAME_PLAYER_FAILURE_URI=(out / "failure.json").as_uri(),
    COGAME_PORT=str(a.port),
)
with (out / "game.log").open("w") as log:
    child = subprocess.Popen(
        [
            os.sys.executable,
            str(root / "coworld/paintbot/runtime/host.py"),
            "--engine",
            str(root / "tmp/paintbot-coworld"),
        ],
        env=env,
        stdout=log,
        stderr=log,
        start_new_session=True,
    )
    try:
        deadline = time.monotonic() + 600
        while not (out / "results.json").exists():
            if child.poll() is not None:
                raise RuntimeError((out / "game.log").read_text())
            if time.monotonic() > deadline:
                raise TimeoutError("Episode exceeded ten minutes")
            time.sleep(0.2)
        print((out / "results.json").read_text())
    finally:
        import signal

        if child.poll() is None:
            os.killpg(child.pid, signal.SIGTERM)
        child.wait(timeout=15)
