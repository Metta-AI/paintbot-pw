"""Engine vs Python mirror for FFA speech: action contract ffa.view.1 pointer shout (15) and observation contract
ffa.view.1h / ffa.view.1hu<K> (203).

The mirror is runtime/neural_package.py: the contract ids and hashes staging binds, SHOUT_VOCABULARY / SHOUT_CLASSES
(the shout head) and shout_class (the behaviour-cloning label of a shout text). This builds the real native training
library and checks:
  - every contract hash the library writes equals the mirror's (action contracts 11 .. 15; 201, 202, 203;
    ffa.view.1hu<K>, K = 1 .. MAX_USER_INPUTS);
  - under 15 the action heads are the plain pointer heads, then SHOUT_CLASSES;
  - caller-driven seats choosing head-5 class c are labelled c by pw_seat_shouts: shout_class of the text the
    reference decode said, SHOUT_VOCABULARY[c - 1];
  - a 203 handle stepped in lockstep with a 202 handle (the same caller heads, every seat shouting at random under
    15 on the 203 handle) plays the same world, and each row's first floats are the 202 row byte for byte; the
    heard rows that follow are well formed (valid rows first, one class column each).
"""

import ctypes
import random
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).parent / "runtime"))
from neural_package import (ACTION_CONTRACT_TEAMS_VIEW_1_HASH, ACTION_CONTRACT_FFA_VIEW_1_POINTER_HASH,  # noqa: E402
                            ACTION_CONTRACT_TEAMS_VIEW_1_OFFSET_HASH, ACTION_CONTRACT_TEAMS_VIEW_1_MOVE_HASH,
                            ACTION_CONTRACT_FFA_VIEW_1_POINTER_SHOUT_HASH, OBSERVATION_CONTRACT_TEAMS_VIEW_1_HASH,
                            OBSERVATION_CONTRACT_FFA_VIEW_1_HASH, FFA_HEARD_CONTRACT_HASHES, FFA_HEARD_ROWS,
                            FFA_HEARD_WIDTH, MAX_USER_INPUTS, SHOUT_CLASSES, SHOUT_VOCABULARY, shout_class)

TICKS = 120
HEARTLAND = b'{"mode": "ffa_kin", "kin_layout": "cousins"}'


class ShoutMirrorTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="paintbot-shout-mirror-")
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
                ("pw_destroy", [p], None),
                ("pw_set_rules", [p, ctypes.c_int], ctypes.c_int),
                ("pw_set_config_json", [p, cp, i32, cp, i32], ctypes.c_int),
                ("pw_reset", [p, i32, i32], ctypes.c_int),
                ("pw_seats", [p], ctypes.c_int),
                ("pw_handle_observation_size", [p], ctypes.c_int),
                ("pw_action_layout", [p, i32p], ctypes.c_int),
                ("pw_action_layout_ext", [p, i32p], ctypes.c_int),
                ("pw_set_action_contract", [p, i32], ctypes.c_int),
                ("pw_seat_shouts", [p, ctypes.c_int, i32p], ctypes.c_int),
                ("pw_observe", [p, f32p, f32p], ctypes.c_int),
                ("pw_step", [p, i32p, f32p, f32p], ctypes.c_int),
                ("pw_state_hash", [p], ctypes.c_uint32),
                ("pw_action_contract_hash", [i32, cp, i32], ctypes.c_int),
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

    def heartland(self, version, contract):
        lib = self.lib
        h = lib.pw_create_observation(7, 0, version)
        self.assertTrue(h)
        self.assertEqual(lib.pw_set_config_json(h, HEARTLAND, len(HEARTLAND), None, 0), 0)
        self.assertEqual(lib.pw_reset(h, 2026, TICKS), 0)
        self.assertEqual(lib.pw_set_action_contract(h, contract), 0)
        return h

    def test_contract_hashes_engine_equals_mirror(self):
        lib = self.lib
        for version, digest in ((11, ACTION_CONTRACT_TEAMS_VIEW_1_HASH), (12, ACTION_CONTRACT_FFA_VIEW_1_POINTER_HASH),
                                (13, ACTION_CONTRACT_TEAMS_VIEW_1_OFFSET_HASH), (14, ACTION_CONTRACT_TEAMS_VIEW_1_MOVE_HASH),
                                (15, ACTION_CONTRACT_FFA_VIEW_1_POINTER_SHOUT_HASH)):
            self.assertEqual(self.hash_of(lib.pw_action_contract_hash, version), digest)
        self.assertEqual(self.hash_of(lib.pw_observation_contract_hash, 201), OBSERVATION_CONTRACT_TEAMS_VIEW_1_HASH)
        self.assertEqual(self.hash_of(lib.pw_observation_contract_hash, 202), OBSERVATION_CONTRACT_FFA_VIEW_1_HASH)
        heard = {k: v for v, k in FFA_HEARD_CONTRACT_HASHES.items()}
        self.assertEqual(self.hash_of(lib.pw_observation_contract_hash, 203), heard[0])
        for k in range(1, MAX_USER_INPUTS + 1):
            self.assertEqual(self.hash_of(lib.pw_user_inputs_contract_hash_v, 203, k), heard[k])
        out = ctypes.create_string_buffer(65)
        self.assertEqual(lib.pw_action_contract_hash(16, out, 65), -1)

    def test_heads_and_labels_engine_equals_mirror(self):
        lib = self.lib
        h = self.heartland(202, 15)
        plain = (ctypes.c_int32 * 8)()
        ext = (ctypes.c_int32 * 10)()
        self.assertEqual(lib.pw_action_layout(h, plain), -1)
        self.assertEqual(lib.pw_action_layout_ext(h, ext), 0)
        heads = list(ext[1:1 + ext[0]])
        self.assertEqual(ext[0], 6)
        self.assertEqual(heads[5], SHOUT_CLASSES)
        self.assertEqual(ext[8], sum(heads))
        p = self.heartland(202, 12)
        self.assertEqual(lib.pw_action_layout(p, plain), 0)
        self.assertEqual(list(plain[1:6]), heads[:5])
        lib.pw_destroy(p)
        seats, n = lib.pw_seats(h), lib.pw_handle_observation_size(h)
        rows = (ctypes.c_float * (seats * n))()
        resets = (ctypes.c_float * seats)()
        actions = (ctypes.c_int32 * (seats * 6))()
        rewards, terminals = (ctypes.c_float * seats)(), (ctypes.c_float * seats)()
        said = (ctypes.c_int32 * 4)()
        rng, labelled = random.Random(3), {c: 0 for c in range(SHOUT_CLASSES)}
        for tick in range(TICKS - 1):
            self.assertEqual(lib.pw_observe(h, rows, resets), 0)
            floats = struct.unpack("<%df" % (seats * n), bytes(rows))
            alive = [floats[s * n + 5] > 0 for s in range(seats)]  # ffa.view.1 header column 5: selfHp > 0
            for s in range(seats):
                for head in range(5):
                    actions[s * 6 + head] = rng.randrange(heads[head])
                actions[s * 6 + 5] = rng.randrange(SHOUT_CLASSES)
            self.assertEqual(lib.pw_step(h, actions, rewards, terminals), 0)
            for s in range(seats):
                self.assertEqual(lib.pw_seat_shouts(h, s, said), 0)
                c = actions[s * 6 + 5]
                if not alive[s]:
                    self.assertEqual(list(said), [0, 0, 0, 0])
                    continue
                text = SHOUT_VOCABULARY[c - 1] if c else None
                want = [shout_class(text), 1 << (shout_class(text) - 1), 1, 0] if text else [0, 0, 0, 0]
                self.assertEqual(list(said), want, "seat %d tick %d" % (s, tick))
                labelled[c] += 1
        self.assertTrue(all(v > 0 for v in labelled.values()), labelled)
        lib.pw_destroy(h)

    def test_ffa_view_1h_rows_extend_ffa_view_1(self):
        lib = self.lib
        heard, base = self.heartland(203, 15), self.heartland(202, 12)
        seats = lib.pw_seats(heard)
        n, nb = lib.pw_handle_observation_size(heard), lib.pw_handle_observation_size(base)
        self.assertEqual(n, nb + FFA_HEARD_ROWS * FFA_HEARD_WIDTH)
        ext = (ctypes.c_int32 * 10)()
        self.assertEqual(lib.pw_action_layout_ext(heard, ext), 0)
        heads = list(ext[1:7])
        rows, base_rows = (ctypes.c_float * (seats * n))(), (ctypes.c_float * (seats * nb))()
        resets = (ctypes.c_float * seats)()
        act6, act5 = (ctypes.c_int32 * (seats * 6))(), (ctypes.c_int32 * (seats * 5))()
        rewards, terminals = (ctypes.c_float * seats)(), (ctypes.c_float * seats)()
        rng, heard_rows = random.Random(4), [0] * SHOUT_CLASSES
        for tick in range(TICKS - 1):
            self.assertEqual(lib.pw_observe(heard, rows, resets), 0)
            self.assertEqual(lib.pw_observe(base, base_rows, resets), 0)
            got, want = bytes(rows), bytes(base_rows)
            for s in range(seats):
                self.assertEqual(got[s * 4 * n:s * 4 * n + 4 * nb], want[s * 4 * nb:(s + 1) * 4 * nb],
                                 "seat %d tick %d" % (s, tick))
                block = struct.unpack("<%df" % (n - nb), got[s * 4 * n + 4 * nb:(s + 1) * 4 * n])
                valid = [block[i * FFA_HEARD_WIDTH] for i in range(FFA_HEARD_ROWS)]
                self.assertEqual(valid, sorted(valid, reverse=True))  # valid rows first
                for i in range(FFA_HEARD_ROWS):
                    row = block[i * FFA_HEARD_WIDTH:(i + 1) * FFA_HEARD_WIDTH]
                    if row[0] == 0:
                        self.assertEqual(set(row), {0.0})
                        continue
                    self.assertEqual(sorted(row[1:4]), [0.0, 0.0, 1.0])
                    self.assertEqual(row[3], 0.0)  # the decode says only vocabulary texts
                    heard_rows[row.index(1.0, 1, 4)] += 1
            for s in range(seats):
                for head in range(5):
                    act6[s * 6 + head] = act5[s * 5 + head] = rng.randrange(heads[head])
                act6[s * 6 + 5] = rng.randrange(SHOUT_CLASSES)
            self.assertEqual(lib.pw_step(heard, act6, rewards, terminals), 0)
            self.assertEqual(lib.pw_step(base, act5, rewards, terminals), 0)
            self.assertEqual(lib.pw_state_hash(heard), lib.pw_state_hash(base))
        self.assertGreater(heard_rows[1], 0)
        self.assertGreater(heard_rows[2], 0)
        lib.pw_destroy(heard)
        lib.pw_destroy(base)


if __name__ == "__main__":
    unittest.main()
