"""One pod: Polyworld native engine/BASIC VMs plus isolated WASM instances."""

import argparse
import hashlib
import json
import os
import socket
import subprocess
import tempfile
import threading
from pathlib import Path
import wasmtime
from wasm_policy import Policy, load_seats, verified_policy, write_json
from sprite import SpriteView


def run(engine):
    doc = load_seats(os.environ["COGAME_PLAYER_SEATS_URI"])
    if len(doc["seats"]) != 16:
        raise ValueError("Paintbot requires 16 seats")
    config = wasmtime.Config()
    config.consume_fuel = True
    config.epoch_interruption = True
    runtime = wasmtime.Engine(config)
    stop = threading.Event()

    def clock():
        while not stop.wait(0.01):
            runtime.increment_epoch()

    thread = threading.Thread(target=clock, daemon=True)
    thread.start()
    policies = {}
    views = {}
    modules = {}
    child = None
    try:
        with tempfile.TemporaryDirectory(prefix="paintbot-pw-") as tmp:
            tmp = Path(tmp)
            dummy = tmp / "idle.bas"
            dummy.write_text("idle = 1\n")
            staged = json.loads(json.dumps(doc))
            for seat in staged["seats"]:
                slot = seat["slot"]
                try:
                    data = verified_policy(seat)
                    if data.startswith(b"\x00asm"):
                        digest = hashlib.sha256(data).digest()
                        if digest not in modules:
                            modules[digest] = wasmtime.Module(runtime, data)
                        policies[slot] = Policy(runtime, modules[digest], slot)
                        views[slot] = SpriteView(slot)
                        seat.update(
                            file_uri=dummy.as_uri(),
                            size_bytes=dummy.stat().st_size,
                            content_hash="sha256:"
                            + hashlib.sha256(dummy.read_bytes()).hexdigest(),
                        )
                    else:
                        if len(data) > 65536:
                            raise ValueError("BASIC source exceeds 64 KiB")
                        data.decode("utf-8")
                        source = tmp / f"player-{slot}.bas"
                        source.write_bytes(data)
                        seat["file_uri"] = source.as_uri()
                except Exception as e:
                    write_json(
                        os.environ["COGAME_PLAYER_FAILURE_URI"],
                        {
                            "message": "Policy initialization failed: "
                            + type(e).__name__,
                            "failed_policy_index": slot,
                        },
                    )
                    raise
            seatfile = tmp / "seats.json"
            seatfile.write_text(json.dumps(staged))
            parent, other = socket.socketpair()
            other.set_inheritable(True)
            env = dict(
                os.environ,
                COGAME_PLAYER_SEATS_URI=seatfile.as_uri(),
                PW_POLICY_FD=str(other.fileno()),
            )
            child = subprocess.Popen([engine], env=env, pass_fds=(other.fileno(),))
            other.close()
            with parent, parent.makefile("rw") as stream:
                for line in stream:
                    w = json.loads(line)
                    commands = []
                    for slot, p in policies.items():
                        try:
                            replies = p.step(views[slot].frame(w))
                        except Exception as e:
                            failure = {
                                "message": "WASM policy failed: " + type(e).__name__,
                                "failed_policy_index": slot,
                            }
                            write_json(os.environ["COGAME_PLAYER_FAILURE_URI"], failure)
                            raise
                        commands.append(
                            {"slot": slot, "command": views[slot].command(w, replies)}
                        )
                    stream.write(json.dumps(commands) + "\n")
                    stream.flush()
            return child.wait()
    finally:
        stop.set()
        thread.join()
        if child is not None and child.poll() is None:
            child.terminate()
            child.wait(timeout=10)
        for p in policies.values():
            p.close()
        for module in modules.values():
            module.close()
        runtime.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--engine", default="/usr/local/bin/paintbot")
    raise SystemExit(run(parser.parse_args().engine))
