"""One pod: Polyworld native engine/BASIC VMs plus isolated WASM instances."""

import argparse
import hashlib
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
from pathlib import Path
import wasmtime
from oracle import MAX_ANSWER, Oracle, flatten
from wasm_policy import Policy, load_seats, verified_policy, write_json
from sprite import SpriteView


def forfeit_seat(slot, reason, policies, views):
    """Reports a structured player-contract failure and drops the seat from active play.

    The engine already staged every WASM seat's file as the idle BASIC fallback, so once a
    slot is out of `policies`/`views` the native side just runs that idle bot for it instead
    of crashing the whole episode.
    """
    write_json(
        os.environ["COGAME_PLAYER_FAILURE_URI"],
        {"message": reason, "failed_policy_index": slot},
    )
    policy = policies.pop(slot, None)
    if policy is not None:
        policy.close()
    views.pop(slot, None)


def basic_oracle_round(oracle, world, pending):
    """Forward this tick's BASIC asks and collect settled answers as flattened replies."""
    replies = []
    for ask in world.get("oracle") or []:
        slot, request_id, body = ask["slot"], ask["id"], ask["body"]
        if slot in pending or not oracle.ask(slot, world.get("tick"), json.dumps(body).encode(), request_id):
            replies.append({"slot": slot, "id": request_id, "status": -1, "answers": {}})
            continue
        pending[slot] = (request_id, body["questions"])
    for slot, (request_id, questions) in list(pending.items()):
        status, answer = oracle.poll(slot, request_id, MAX_ANSWER)
        if status == 0:
            continue
        del pending[slot]
        answers = flatten(json.loads(answer), questions) if status > 0 else {}
        replies.append(
            {"slot": slot, "id": request_id, "status": len(answers) if status > 0 else -1, "answers": answers}
        )
    return replies


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
    oracle = Oracle.from_env()
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
                        policies[slot] = Policy(runtime, modules[digest], slot, oracle)
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
                    # A seat that fails to load forfeits itself: fall back to the same
                    # idle BASIC stub a good WASM seat stages, and never step it. The
                    # episode still starts and scores the seats that did load.
                    forfeit_seat(
                        slot,
                        "Policy initialization failed: " + type(e).__name__,
                        policies,
                        views,
                    )
                    seat.update(
                        file_uri=dummy.as_uri(),
                        size_bytes=dummy.stat().st_size,
                        content_hash="sha256:"
                        + hashlib.sha256(dummy.read_bytes()).hexdigest(),
                    )
            seatfile = tmp / "seats.json"
            seatfile.write_text(json.dumps(staged))
            parent, other = socket.socketpair()
            other.set_inheritable(True)
            env = dict(
                os.environ,
                COGAME_PLAYER_SEATS_URI=seatfile.as_uri(),
                PW_POLICY_FD=str(other.fileno()),
            )
            if oracle is not None:
                # BASIC seats draft asks inside the engine; the host asks on their behalf.
                env.update(PW_ORACLE="1", PW_ORACLE_INTERVAL=str(oracle.min_interval))
            basic_asks = {}  # slot -> (request id, questions) awaiting an answer
            child = subprocess.Popen([engine], env=env, pass_fds=(other.fileno(),))
            other.close()
            with parent, parent.makefile("rw") as stream:
                for line in stream:
                    w = json.loads(line)
                    commands = []
                    for slot in list(policies):
                        p = policies[slot]
                        try:
                            replies = p.step(views[slot].frame(w), w.get("tick"))
                        except Exception as e:
                            # A policy that traps forfeits only its own seat; the engine
                            # keeps running its idle fallback for this slot from here on,
                            # and the episode still finishes and scores the rest.
                            forfeit_seat(
                                slot, "WASM policy failed: " + type(e).__name__,
                                policies, views,
                            )
                            continue
                        commands.append(
                            {
                                "slot": slot,
                                "command": views[slot].command(w, replies),
                                "chat": [
                                    r[3:].decode("utf-8", errors="replace")
                                    for r in replies
                                    if r[0] == 0x81
                                ],
                            }
                        )
                    if oracle is None:
                        stream.write(json.dumps(commands) + "\n")
                    else:
                        replies = basic_oracle_round(oracle, w, basic_asks)
                        stream.write(json.dumps({"commands": commands, "oracle": replies}) + "\n")
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
        if oracle is not None:
            print(f"oracle: {oracle.requests} requests, {oracle.failures} failures", file=sys.stderr)
            oracle.close()
        for module in modules.values():
            module.close()
        runtime.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--engine", default="/usr/local/bin/paintbot")
    raise SystemExit(run(parser.parse_args().engine))
