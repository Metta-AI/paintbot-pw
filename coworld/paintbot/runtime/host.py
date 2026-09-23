"""One pod: the Polyworld native engine running sixteen BASIC seats, bridged to the advisor oracle.

Every seat is a UTF-8 BASIC source file or a validated neural BASIC bundle. The host fetches and verifies each seat's file, stages
it for the engine, launches the engine as a child, and then answers one JSON line per tick over
the `PW_POLICY_FD` socket: the engine sends `{"rulesVersion", "tick", "oracle": [asks...]}` and
the host always replies `{"oracle": [replies...]}` (an empty list when no oracle is configured).
"""

import argparse
import hashlib
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from oracle import MAX_ANSWER, Oracle, flatten
from seats import load_seats, verified_policy, write_json
from neural_package import stage_package

MAX_SOURCE = 128 * 1024  # BASIC source limit per seat; matches maxSourceBytes in bots.nim
WASM_MAGIC = b"\x00asm"


class SourceRejected(ValueError):
    """A seat's file is not an acceptable BASIC source; the message is player-facing."""


def forfeit_seat(slot, reason):
    """Reports a structured player-contract failure for one seat.

    The caller stages the idle BASIC stub in the seat's place, so the engine runs that idle bot
    for the slot instead of the episode failing for all sixteen seats.
    """
    write_json(
        os.environ["COGAME_PLAYER_FAILURE_URI"],
        {"message": reason, "failed_policy_index": slot},
    )


def check_source(data):
    """Raise SourceRejected with the player-facing reason when `data` is not an acceptable BASIC file."""
    if data.startswith(WASM_MAGIC):
        raise SourceRejected("WASM modules are no longer accepted; submit a BASIC source file")
    if len(data) > MAX_SOURCE:
        # Stated from the constant, so the message cannot drift from the limit it enforces.
        raise SourceRejected(f"BASIC source exceeds {MAX_SOURCE // 1024} KiB")
    try:
        data.decode("utf-8")
    except UnicodeDecodeError:
        raise SourceRejected("BASIC source is not UTF-8") from None


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
        answers = {}
        if status > 0:
            # A reply that cannot be flattened is that ask's failure. It must never leave this loop:
            # an exception here ends the episode for all sixteen seats.
            try:
                answers = flatten(json.loads(answer), questions)
            except Exception as e:  # noqa: BLE001
                oracle.unusable(slot, f"reply could not be flattened: {type(e).__name__}: {e}")
            else:
                if not answers:
                    oracle.unusable(slot, "reply held no usable answer")
        # The engine reads status 0 as "still pending", so an empty reply is a failed one.
        replies.append({"slot": slot, "id": request_id, "status": len(answers) or -1, "answers": answers})
    return replies


def run(engine):
    doc = load_seats(os.environ["COGAME_PLAYER_SEATS_URI"])
    if len(doc["seats"]) != 16:
        raise ValueError("Paintbot requires 16 seats")
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
                    source = tmp / f"player-{slot}.bas"
                    if data.startswith(b"PK\x03\x04"):
                        data = stage_package(data, source)
                        check_source(data)
                        seat.update(size_bytes=len(data), content_hash="sha256:" + hashlib.sha256(data).hexdigest())
                    else:
                        check_source(data)
                        source.write_bytes(data)
                    seat["file_uri"] = source.as_uri()
                except Exception as e:
                    # A seat that fails to load forfeits itself and falls back to the idle stub,
                    # so the episode still starts and scores the seats that did load. A rejected
                    # source names its reason; anything else (a hash mismatch, a failed download)
                    # reports the exception type, as before.
                    why = str(e) if isinstance(e, SourceRejected) else type(e).__name__
                    forfeit_seat(slot, "Policy initialization failed: " + why)
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
            # Local evaluation aid: pace the bridge so a tick takes at least this long. The hosted
            # league runs in real time; an unpaced local engine runs several times faster, which
            # makes oracle answers land tens of ticks late instead of a handful.
            tick_seconds = float(os.environ.get("COGAME_TICK_SECONDS", "0") or 0)
            with parent, parent.makefile("rw") as stream:
                next_tick = time.monotonic()
                for line in stream:
                    if tick_seconds > 0:
                        next_tick += tick_seconds
                        delay = next_tick - time.monotonic()
                        if delay > 0:
                            time.sleep(delay)
                        elif delay < -2 * tick_seconds:
                            next_tick = time.monotonic()
                    w = json.loads(line)
                    replies = [] if oracle is None else basic_oracle_round(oracle, w, basic_asks)
                    stream.write(json.dumps({"oracle": replies}) + "\n")
                    stream.flush()
            return child.wait()
    finally:
        if child is not None and child.poll() is None:
            child.terminate()
            child.wait(timeout=10)
        if oracle is not None:
            print(f"oracle: {oracle.requests} requests, {oracle.failures} failures", file=sys.stderr)
            oracle.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--engine", default="/usr/local/bin/paintbot")
    raise SystemExit(run(parser.parse_args().engine))
