"""JSONL training bridge over Paintbot's versioned native simulator ABI."""

import argparse
import ctypes
import hashlib
import json
import sys
from pathlib import Path


SEATS = 16
OBSERVATION_SIZE = 506
ACTION_SIZES = (51, 25, 2, 2, 2)
ACTION_NAMES = ("move", "aim", "fire", "grenade", "sneak")
OPPONENT = Path(__file__).resolve().parents[3] / "examples/paintbot/players/base.bas"


class Bridge:
    def __init__(self, library: Path, variant: str, ticks: int | None):
        manifest = json.loads((Path(__file__).resolve().parents[1] / "coworld_manifest_template.json").read_text())
        config = (
            manifest["certification"]["game_config"]
            if variant == "certification"
            else next(entry["game_config"] for entry in manifest["variants"] if entry["id"] == variant)
        )
        self.ticks = config["max_ticks"] if ticks is None else ticks
        if self.ticks < 1 or self.ticks > config["max_ticks"]:
            raise ValueError("Training ticks must fit the selected Coworld variant")
        self.library = ctypes.CDLL(str(library.resolve()))
        self.library.pw_create_observation.argtypes = [ctypes.c_int32, ctypes.c_int32, ctypes.c_int32]
        self.library.pw_create_observation.restype = ctypes.c_void_p
        self.library.pw_destroy.argtypes = [ctypes.c_void_p]
        self.library.pw_set_action_contract.argtypes = [ctypes.c_void_p, ctypes.c_int32]
        self.library.pw_set_action_contract.restype = ctypes.c_int
        self.library.pw_observe_seats.argtypes = [
            ctypes.c_void_p, ctypes.c_uint32, ctypes.POINTER(ctypes.c_float), ctypes.POINTER(ctypes.c_float)
        ]
        self.library.pw_observe_seats.restype = ctypes.c_int
        self.library.pw_bot_actions.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.POINTER(ctypes.c_int32)]
        self.library.pw_bot_actions.restype = ctypes.c_int
        self.library.pw_set_seat_script.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_int32]
        self.library.pw_set_seat_script.restype = ctypes.c_int
        self.library.pw_step.argtypes = [
            ctypes.c_void_p, ctypes.POINTER(ctypes.c_int32), ctypes.POINTER(ctypes.c_float), ctypes.POINTER(ctypes.c_float)
        ]
        self.library.pw_step.restype = ctypes.c_int
        self.library.pw_results.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_float)]
        self.library.pw_results.restype = ctypes.c_int
        self.handle = None
        self.decision_id = 0
        self.values = []
        self.reset_mask = 0.0

    def close(self):
        if self.handle is not None:
            self.library.pw_destroy(self.handle)
            self.handle = None

    def decision(self):
        observations = (ctypes.c_float * (SEATS * OBSERVATION_SIZE))()
        resets = (ctypes.c_float * SEATS)()
        if self.library.pw_observe_seats(self.handle, 1, observations, resets) != 0:
            raise RuntimeError("Paintbot native observation failed")
        self.values = list(observations[:OBSERVATION_SIZE])
        self.reset_mask = resets[0]
        results = (ctypes.c_float * 8)()
        if self.library.pw_results(self.handle, results) != 0:
            raise RuntimeError("Paintbot native results failed")
        self.decision_id += 1
        return {
            "kind": "decision", "game": "paintbot-pw", "decision_id": self.decision_id,
            "seat": 0, "engine_seat": 0, "turn": int(results[0]),
            "semantic_view": {
                "observation_contract": "paintbot-pw.rules37.obs.v2.float506",
                "action_contract": "paintbot-pw.rules37.action.v2.51-25-2-2-2",
                "values": self.values, "state_reset": self.reset_mask,
            },
            "inbox": [], "messages": [], "speech_messages": [],
            "action_schema": {
                "type": "object", "required": list(ACTION_NAMES),
                "properties": {
                    name: {"type": "integer", "minimum": 0, "maximum": size - 1}
                    for name, size in zip(ACTION_NAMES, ACTION_SIZES, strict=True)
                },
            },
            "typed_question": None,
        }

    def handle_request(self, command):
        kind = command["kind"]
        if kind == "reset":
            if command["players"] != SEATS:
                raise ValueError("Paintbot requires 16 seats")
            self.close()
            seed = int.from_bytes(hashlib.sha256(command["seed"].encode()).digest()[:4], "big") & 0x7FFFFFFF
            self.handle = self.library.pw_create_observation(seed, self.ticks, 2)
            if self.handle is None:
                raise RuntimeError("Paintbot native create failed")
            if self.library.pw_set_action_contract(self.handle, 2) != 0:
                raise RuntimeError("Paintbot action contract v2 is unavailable")
            opponent = OPPONENT.read_bytes()
            for seat in range(1, SEATS):
                if self.library.pw_set_seat_script(self.handle, seat, opponent, len(opponent)) != 0:
                    raise RuntimeError(f"Paintbot baseline failed to compile for seat {seat}")
            self.decision_id = 0
            return self.decision()
        if self.handle is None:
            raise ValueError("Reset before requesting a decision")
        if kind == "encode":
            return {
                "decision_id": self.decision_id,
                "values": self.values,
                "action_heads": [
                    {"name": name, "choices": list(range(size))}
                    for name, size in zip(ACTION_NAMES, ACTION_SIZES, strict=True)
                ],
            }
        if kind == "teacher":
            actions = (ctypes.c_int32 * (SEATS * len(ACTION_NAMES)))()
            if self.library.pw_bot_actions(self.handle, 0, 2, actions) != 0:
                raise RuntimeError("Paintbot native teacher action failed")
            return {"response": json.dumps(dict(zip(ACTION_NAMES, actions[:5], strict=True)))}
        if kind != "step":
            raise ValueError("Unknown bridge command")
        if command["decision_id"] != self.decision_id:
            raise ValueError("Decision ID does not match the current tick")
        action = json.loads(command["response"])
        if set(action) != set(ACTION_NAMES) or any(
            type(action[name]) is not int or not 0 <= action[name] < size
            for name, size in zip(ACTION_NAMES, ACTION_SIZES, strict=True)
        ):
            return {"kind": "rejected", "reason": "Action must contain five in-range integer heads"}
        actions = (ctypes.c_int32 * (SEATS * len(ACTION_NAMES)))()
        for index, name in enumerate(ACTION_NAMES):
            actions[index] = action[name]
        rewards = (ctypes.c_float * SEATS)()
        terminals = (ctypes.c_float * SEATS)()
        if self.library.pw_step(self.handle, actions, rewards, terminals) != 0:
            raise RuntimeError("Paintbot native step failed")
        if terminals[0]:
            results = (ctypes.c_float * 8)()
            if self.library.pw_results(self.handle, results) != 0:
                raise RuntimeError("Paintbot native terminal results failed")
            observation = {
                "kind": "terminal",
                "scores": {str(seat): results[2 + seat % 2] for seat in range(SEATS)},
            }
        else:
            observation = self.decision()
        return {"kind": "accepted", "action": action, "observation": observation}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--library", required=True, type=Path)
    parser.add_argument("--variant", default="certification")
    parser.add_argument("--ticks", type=int)
    args = parser.parse_args()
    bridge = Bridge(args.library, args.variant, args.ticks)
    try:
        for line in sys.stdin:
            print(json.dumps(bridge.handle_request(json.loads(line)), separators=(",", ":")), flush=True)
    finally:
        bridge.close()


if __name__ == "__main__":
    main()
