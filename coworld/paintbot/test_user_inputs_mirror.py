"""Engine vs Python mirror for the user-input observation contracts (teams.view.1u<K>, ffa.view.1u<K>).

The mirror is runtime/neural_package.py: the contract ids and hashes staging binds, and user_inputs_row /
user_input_feature (the K columns a policy.bas writes with neuralInput, appended to the base contract's row).
This builds the real native training library and checks, byte for byte:
  - every contract hash the library writes equals the mirror's (201 / 202 bases, K = 1 .. MAX_USER_INPUTS);
  - ffa.view.1u5 and ffa.view.1u16 handles (version 202 + K) stepped in lockstep with a plain ffa.view.1 handle:
    every seat's row is the mirror's user_inputs_row(the plain handle's row, the seat's inputs): the base floats
    unchanged, then float32(clamp(v)) / 1000 of what seat 0's policy.bas wrote one tick earlier, zeros for every
    other seat.
"""

import ctypes
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).parent / "runtime"))
from neural_package import (FFA_USER_INPUTS_CONTRACT_HASHES, USER_INPUTS_CONTRACT_HASHES,  # noqa: E402
                            OBSERVATION_CONTRACT_TEAMS_VIEW_1_HASH, OBSERVATION_CONTRACT_FFA_VIEW_1_HASH,
                            ACTION_CONTRACT_FFA_VIEW_1_POINTER_HASH, MAX_USER_INPUTS, user_inputs_row,
                            OBSERVATION_CONTRACT_TEAMS_VIEW_1H_HASH, TEAMS_H_USER_INPUTS_CONTRACT_HASHES,
                            OBSERVATION_CONTRACT_TEAMS_VIEW_1S_HASH, TEAMS_S_USER_INPUTS_CONTRACT_HASHES,
                            OBSERVATION_CONTRACT_TEAMS_VIEW_1T_HASH, TEAMS_T_USER_INPUTS_CONTRACT_HASHES)

KS = (5, 16)
TICKS = 80
HEARTLAND = b'{"mode": "ffa_kin", "kin_layout": "cousins"}'
DECODER = (ROOT / "examples/paintbot/players/neural_decode_ffa.bas").read_text()
POLICY = ("paintbot_observe(neuralObservation())\n"
          "run_neural_net(neuralModel(), neuralObservation(), neuralLogits(), neuralState())\n"
          "neuralSample()\n" + DECODER)
# What seat 0's policy.bas writes on tick t (the mirror predicts it from t alone); inputs 5.. are left at init.
WRITES = ("neuralInput(0, worldTick * 1000)\nneuralInput(1, 0 - worldTick)\nneuralInput(2, 1500)\n"
          "neuralInput(3, 2000000)\nneuralInput(4, -700)\n")


def init(k):
    return [(-1) ** j * (j + 1) * 37 for j in range(k)]


def written(tick, k):
    return [tick * 1000, -tick, 1500, 2000000, -700] + init(k)[5:]


def manifest(observation, user_inputs=None):
    text = ('{"schema": "paintbot-neural-basic/2", "observation_contract": "%s", "action_contract": "%s"'
            % (observation, ACTION_CONTRACT_FFA_VIEW_1_POINTER_HASH))
    if user_inputs:
        text += ', "user_inputs": {"count": %d, "init": %s}' % (len(user_inputs), list(user_inputs))
    return (text + "}").encode()


class UserInputsMirrorTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="paintbot-user-inputs-mirror-")
        suffix = ".dylib" if sys.platform == "darwin" else ".so"
        library = Path(cls.directory.name) / f"paintbot{suffix}"
        subprocess.run(["nim", "c", "--app:lib", "--mm:arc", "--threads:on", "-d:pwTraining", "-d:headless",
                        f"-o:{library}", "examples/paintbot/native_env.nim"],
                       cwd=ROOT, check=True, capture_output=True, text=True)
        lib = ctypes.CDLL(str(library))
        p, i32, f32p, i32p, cp = (ctypes.c_void_p, ctypes.c_int32, ctypes.POINTER(ctypes.c_float),
                                  ctypes.POINTER(ctypes.c_int32), ctypes.c_char_p)
        for name, args, res in (
                ("pw_create_observation", [i32, i32, i32], p),
                ("pw_create_observation_inputs_v", [i32, i32, i32, i32], p),
                ("pw_destroy", [p], None),
                ("pw_set_rules", [p, ctypes.c_int], ctypes.c_int),
                ("pw_set_config_json", [p, cp, i32, cp, i32], ctypes.c_int),
                ("pw_reset", [p, i32, i32], ctypes.c_int),
                ("pw_seats", [p], ctypes.c_int),
                ("pw_handle_observation_size", [p], ctypes.c_int),
                ("pw_handle_user_inputs", [p], ctypes.c_int),
                ("pw_action_layout", [p, i32p], ctypes.c_int),
                ("pw_set_seat_script", [p, ctypes.c_int, cp, i32], ctypes.c_int),
                ("pw_set_seat_policy_script", [p, ctypes.c_int, cp, i32, cp, i32], ctypes.c_int),
                ("pw_observe", [p, f32p, f32p], ctypes.c_int),
                ("pw_step_logits", [p, i32p, f32p, f32p, f32p], ctypes.c_int),
                ("pw_state_hash", [p], ctypes.c_uint32),
                ("pw_observation_contract_hash", [i32, cp, i32], ctypes.c_int),
                ("pw_user_inputs_contract_hash_v", [i32, i32, cp, i32], ctypes.c_int)):
            fn = getattr(lib, name)
            fn.argtypes, fn.restype = args, res
        cls.lib = lib

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def hash_of(self, call, *args):
        out = ctypes.create_string_buffer(65)
        self.assertEqual(call(*args, out, 65), 0)
        return out.value.decode()

    def test_contract_hashes_engine_equals_mirror(self):
        lib = self.lib
        self.assertEqual(self.hash_of(lib.pw_observation_contract_hash, 201), OBSERVATION_CONTRACT_TEAMS_VIEW_1_HASH)
        self.assertEqual(self.hash_of(lib.pw_observation_contract_hash, 202), OBSERVATION_CONTRACT_FFA_VIEW_1_HASH)
        teams = {v: k for k, v in USER_INPUTS_CONTRACT_HASHES.items()}
        ffa = {v: k for k, v in FFA_USER_INPUTS_CONTRACT_HASHES.items()}
        for k in range(1, MAX_USER_INPUTS + 1):
            self.assertEqual(self.hash_of(lib.pw_user_inputs_contract_hash_v, 201, k), teams[k])
            self.assertEqual(self.hash_of(lib.pw_user_inputs_contract_hash_v, 202, k), ffa[k])
        self.assertEqual(self.hash_of(lib.pw_observation_contract_hash, 203), OBSERVATION_CONTRACT_TEAMS_VIEW_1H_HASH)
        teams_h = {v: k for k, v in TEAMS_H_USER_INPUTS_CONTRACT_HASHES.items()}
        for k in range(1, MAX_USER_INPUTS + 1):
            self.assertEqual(self.hash_of(lib.pw_user_inputs_contract_hash_v, 203, k), teams_h[k])
        self.assertEqual(self.hash_of(lib.pw_observation_contract_hash, 204), OBSERVATION_CONTRACT_TEAMS_VIEW_1S_HASH)
        teams_s = {v: k for k, v in TEAMS_S_USER_INPUTS_CONTRACT_HASHES.items()}
        for k in range(1, MAX_USER_INPUTS + 1):
            self.assertEqual(self.hash_of(lib.pw_user_inputs_contract_hash_v, 204, k), teams_s[k])
        self.assertEqual(self.hash_of(lib.pw_observation_contract_hash, 205), OBSERVATION_CONTRACT_TEAMS_VIEW_1T_HASH)
        teams_t = {v: k for k, v in TEAMS_T_USER_INPUTS_CONTRACT_HASHES.items()}
        for k in range(1, MAX_USER_INPUTS + 1):
            self.assertEqual(self.hash_of(lib.pw_user_inputs_contract_hash_v, 205, k), teams_t[k])
        out = ctypes.create_string_buffer(65)
        for version, k in ((202, 0), (202, MAX_USER_INPUTS + 1), (203, 0), (203, MAX_USER_INPUTS + 1), (204, 0), (204, MAX_USER_INPUTS + 1),
                           (205, 0), (205, MAX_USER_INPUTS + 1), (206, 1)):
            self.assertEqual(lib.pw_user_inputs_contract_hash_v(version, k, out, 65), -1)

    def heartland(self, user_inputs):
        lib = self.lib
        h = (lib.pw_create_observation(7, 0, 202) if not user_inputs
             else lib.pw_create_observation_inputs_v(7, 0, 202, user_inputs))
        self.assertTrue(h)
        self.assertEqual(lib.pw_set_config_json(h, HEARTLAND, len(HEARTLAND), None, 0), 0)
        self.assertEqual(lib.pw_reset(h, 2026, TICKS), 0)
        self.assertEqual(lib.pw_handle_user_inputs(h), user_inputs)
        base = (ROOT / "coworld/heartland/players/ffa.bas").read_bytes()
        for seat in range(1, lib.pw_seats(h)):
            self.assertEqual(lib.pw_set_seat_script(h, seat, base, len(base)), 0)
        if user_inputs:
            source, man = (WRITES + POLICY).encode(), manifest(FFA_CONTRACTS[user_inputs], init(user_inputs))
        else:
            source, man = POLICY.encode(), manifest(OBSERVATION_CONTRACT_FFA_VIEW_1_HASH)
        self.assertEqual(lib.pw_set_seat_policy_script(h, 0, source, len(source), man, len(man)), 0)
        return h

    def test_ffa_view_1u_k_rows_engine_equals_mirror(self):
        for k in KS:
            with self.subTest(k=k):
                self.lockstep(k)

    def lockstep(self, K):
        lib = self.lib
        u, b = self.heartland(K), self.heartland(0)
        seats = lib.pw_seats(u)
        n, nb = lib.pw_handle_observation_size(u), lib.pw_handle_observation_size(b)
        self.assertEqual(n, nb + K)
        layout = (ctypes.c_int32 * 8)()
        self.assertEqual(lib.pw_action_layout(u, layout), 0)
        rows = (ctypes.c_float * (seats * n))()
        base_rows = (ctypes.c_float * (seats * nb))()
        resets = (ctypes.c_float * seats)()
        actions = (ctypes.c_int32 * (seats * 5))()
        logits = (ctypes.c_float * (seats * layout[6]))()
        rewards, terminals = (ctypes.c_float * seats)(), (ctypes.c_float * seats)()
        inputs, exact, steps = init(K), 0, 0
        while True:
            self.assertEqual(lib.pw_observe(u, rows, resets), 0)
            self.assertEqual(lib.pw_observe(b, base_rows, resets), 0)
            got = bytes(rows)
            base = struct.unpack("<%df" % (seats * nb), bytes(base_rows))
            alive0 = base[5] > 0  # ffa.view.1 header column 5: selfHp > 0
            for seat in range(seats):
                want = user_inputs_row(base[seat * nb:(seat + 1) * nb], inputs if seat == 0 else [0] * K)
                packed = struct.pack("<%df" % n, *want)
                if seat == 0 and steps > 0 and not was_alive0:
                    # The seat's script may not have run on a tick it was dead: the base floats must
                    # still match; its inputs are whatever it last wrote.
                    self.assertEqual(got[:4 * nb], packed[:4 * nb], "seat 0 base floats, tick %d" % steps)
                    continue
                self.assertEqual(got[seat * 4 * n:(seat + 1) * 4 * n], packed, "seat %d tick %d" % (seat, steps))
                if seat == 0 and steps > 0:
                    exact += 1
            code = lib.pw_step_logits(u, actions, logits, rewards, terminals)
            self.assertEqual(lib.pw_step_logits(b, actions, logits, rewards, terminals), code)
            if code != 0:
                break
            self.assertEqual(lib.pw_state_hash(u), lib.pw_state_hash(b))
            was_alive0 = alive0
            if alive0:
                inputs = written(steps, K)
            steps += 1
        self.assertEqual(steps, TICKS)
        self.assertGreater(exact, TICKS // 2)
        lib.pw_destroy(u)
        lib.pw_destroy(b)


FFA_CONTRACTS = {k: v for v, k in FFA_USER_INPUTS_CONTRACT_HASHES.items()}

if __name__ == "__main__":
    unittest.main()
