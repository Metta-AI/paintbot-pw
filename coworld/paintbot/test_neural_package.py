"""Neural archive boundary tests, independent of Wasmtime and the game binary."""
import hashlib
import io
import json
import random
import re
import struct
import sys
import unittest
import zipfile
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent / "runtime"))
from neural_package import (layer_norm_ops, token_norm_ops, token_pair_ops, unpack_package, MAX_MODEL_BYTES,
                            validate_user_inputs, user_inputs_contract_id, MAX_USER_INPUTS, USER_INPUT_LIMIT, RETIRED_USER_INPUTS,
                            validate_pwnet2, attention_ops, MAX_NEURAL_OPERATIONS, PWNET2_LIMITS,
                            USER_INPUTS_CONTRACT_HASHES, FFA_USER_INPUTS_CONTRACT_HASHES, user_input_feature,
                            user_inputs_row, segment_near_ops, neural_budget, attn_pool_ops,
                            LAYOUT_WORD_PREFIX, TEAMS_VIEW_1_SIZE, ACTION_SIZES, ACTION_SIZES_OFFSET, ACTION_SIZES_MOVE,
                            ACTION_CONTRACT_TEAMS_VIEW_1_MOVE, ACTION_CONTRACT_TEAMS_VIEW_1_MOVE_HASH,
                            OBSERVATION_CONTRACT_TEAMS_VIEW_1, OBSERVATION_CONTRACT_FFA_VIEW_1,
                            ACTION_CONTRACT_TEAMS_VIEW_1, ACTION_CONTRACT_TEAMS_VIEW_1_OFFSET,
                            ACTION_CONTRACT_FFA_VIEW_1_POINTER, OBSERVATION_CONTRACT_TEAMS_VIEW_1_HASH,
                            OBSERVATION_CONTRACT_FFA_VIEW_1_HASH, ACTION_CONTRACT_TEAMS_VIEW_1_HASH,
                            ACTION_CONTRACT_TEAMS_VIEW_1_OFFSET_HASH, ACTION_CONTRACT_FFA_VIEW_1_POINTER_HASH,
                            RETIRED_OBSERVATION_CONTRACTS, RETIRED_ACTION_CONTRACTS, RETIRED_CONTRACT_HASHES,
                            RETIRED_DECODER_OPTIONS, ACTION_CONTRACT_TEAMS_VIEW_1_TARGET,
                            ACTION_CONTRACT_TEAMS_VIEW_1_TARGET_HASH, pointer_k_ops, ACTION_CONTRACT_TEAMS_VIEW_1_RAW,
                            ACTION_CONTRACT_TEAMS_VIEW_1_RAW_HASH, OBSERVATION_CONTRACT_TEAMS_VIEW_1H,
                            OBSERVATION_CONTRACT_TEAMS_VIEW_1H_HASH, TEAMS_VIEW_1H_SIZE,
                            OBSERVATION_CONTRACT_TEAMS_VIEW_1S, OBSERVATION_CONTRACT_TEAMS_VIEW_1S_HASH,
                            TEAMS_VIEW_1S_SIZE, OBSERVATION_CONTRACT_TEAMS_VIEW_1T,
                            OBSERVATION_CONTRACT_TEAMS_VIEW_1T_HASH, TEAMS_VIEW_1T_SIZE,
                            OBSERVATION_CONTRACT_TEAMS_VIEW_1P, OBSERVATION_CONTRACT_TEAMS_VIEW_1P_HASH,
                            TEAMS_VIEW_1P_SIZE, OBSERVATION_CONTRACT_TEAMS_VIEW_1I,
                            OBSERVATION_CONTRACT_TEAMS_VIEW_1I_HASH, TEAMS_VIEW_1I_SIZE,
                            ACTION_CONTRACT_TEAMS_VIEW_1_SELF_DESTRUCT,
                            ACTION_CONTRACT_TEAMS_VIEW_1_SELF_DESTRUCT_HASH)

ROOT = Path(__file__).parents[2]
TEAMS, FFA = OBSERVATION_CONTRACT_TEAMS_VIEW_1_HASH, OBSERVATION_CONTRACT_FFA_VIEW_1_HASH
ACT, OFFSET, POINTER = (ACTION_CONTRACT_TEAMS_VIEW_1_HASH, ACTION_CONTRACT_TEAMS_VIEW_1_OFFSET_HASH,
                        ACTION_CONTRACT_FFA_VIEW_1_POINTER_HASH)
SCHEMA2 = {"schema": "paintbot-neural-basic/2"}
RETIRED = "retired for BASIC parity"


def sha(text):
    return hashlib.sha256(text.encode()).hexdigest()


def tv1u_hash(k):
    """Observation contract teams.view.1u<K>."""
    return sha(user_inputs_contract_id(k))


def fv1u_hash(k):
    """Observation contract ffa.view.1u<K>."""
    return sha(user_inputs_contract_id(k, OBSERVATION_CONTRACT_FFA_VIEW_1))


def actor_bytes(inputs, observation_hash, hidden=64, heads=ACTION_SIZES, action_hash=ACT):
    """A synthetic PWNET001 header (zero weights) with the given input count and observation hash."""
    outputs = sum(heads)
    parameters = inputs * hidden + 3 * hidden * hidden + outputs * hidden
    header = b"PWNET001" + b"".join(v.to_bytes(4, "little") for v in (1, inputs, hidden, outputs, len(heads), parameters))
    return (header + observation_hash.encode() + action_hash.encode() +
            b"".join(h.to_bytes(4, "little") for h in heads) + bytes(4 * parameters))


TEAMS_MODEL = actor_bytes(TEAMS_VIEW_1_SIZE, TEAMS)
OFFSET_MODEL = actor_bytes(TEAMS_VIEW_1_SIZE, TEAMS, heads=ACTION_SIZES_OFFSET, action_hash=OFFSET)
MOVE = ACTION_CONTRACT_TEAMS_VIEW_1_MOVE_HASH
MOVE_MODEL = actor_bytes(TEAMS_VIEW_1_SIZE, TEAMS, heads=ACTION_SIZES_MOVE, action_hash=MOVE)


def package(overrides=None, extra=None, model=TEAMS_MODEL):
    """A bundle over observation contract teams.view.1 + action contract teams.view.1 (a 512-input actor);
    the manifest's sha256 always follows `model` unless overridden."""
    source = b"idle = 1\n"
    manifest = {"schema": "paintbot-neural-basic/1", "observation_contract": TEAMS, "action_contract": ACT,
                "sha256": {"policy.bas": hashlib.sha256(source).hexdigest(),
                           "model.bin": hashlib.sha256(model).hexdigest()}}
    manifest.update(overrides or {})
    out = io.BytesIO()
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for name, value in {"manifest.json": json.dumps(manifest).encode(),
                            "policy.bas": source, "model.bin": model}.items():
            z.writestr(name, value)
        if extra:
            z.writestr(*extra)
    return out.getvalue()


def nim_strings(path, name):
    """The string literals of the Nim array constant `name*` in examples/paintbot/<path>."""
    source = (ROOT / "examples/paintbot" / path).read_text()
    block = source[source.index(name + "* = ["):]
    return re.findall(r'"([^"]*)"', block[:block.index("]")])


class PackageTests(unittest.TestCase):
    def test_valid_package(self):
        source, model, manifest = unpack_package(package())
        self.assertEqual(source, b"idle = 1\n")
        self.assertEqual(model, TEAMS_MODEL)
        self.assertEqual(manifest["observation_contract"], TEAMS)

    def test_hash_mismatch(self):
        with self.assertRaisesRegex(ValueError, "hash mismatch"):
            unpack_package(package({"sha256": {}}))

    def test_hash_object_required(self):
        for value in (None, [], "not-a-map"):
            with self.assertRaisesRegex(ValueError, "sha256 must be an object"):
                unpack_package(package({"sha256": value}))

    def test_no_paths_or_extra_entries(self):
        for name in ("../model.bin", "/policy.bas", "model.bin"):
            with self.assertRaisesRegex(ValueError, "exactly"):
                unpack_package(package(extra=(name, b"bad")))

    def test_contract_required(self):
        for field in ("observation_contract", "action_contract"):
            for value in ("invalid", "A" * 64, "a" * 63, None, 7):
                with self.assertRaisesRegex(ValueError, "invalid contract hash", msg=repr((field, value))):
                    unpack_package(package({field: value}))

    def test_schema_2_accepted_and_others_rejected(self):
        _, _, manifest = unpack_package(package(SCHEMA2))
        self.assertEqual(manifest["schema"], "paintbot-neural-basic/2")
        for schema in ("paintbot-neural-basic/3", "paintbot-neural-basic", None):
            with self.assertRaisesRegex(ValueError, "schema"):
                unpack_package(package({"schema": schema}))

    def test_decompression_bound(self):
        out = io.BytesIO()
        with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
            z.writestr("manifest.json", b"{}")
            z.writestr("policy.bas", b"idle=1")
            z.writestr("model.bin", b"x" * (MAX_MODEL_BYTES + 1))
        with self.assertRaisesRegex(ValueError, "oversized"):
            unpack_package(out.getvalue())

    def test_decoder_object(self):
        _, _, manifest = unpack_package(package({**SCHEMA2, "decoder": {}}))
        self.assertEqual(manifest["decoder"], {})
        with self.assertRaisesRegex(ValueError, "schema 2"):
            unpack_package(package({"decoder": {}}))
        with self.assertRaisesRegex(ValueError, "unknown decoder option: other"):
            unpack_package(package({**SCHEMA2, "decoder": {"sampling": {"mode": "categorical"}, "other": 1}}))
        for value in ([True], "sampling", None, 1):
            with self.assertRaisesRegex(ValueError, "decoder options must be an object"):
                unpack_package(package({**SCHEMA2, "decoder": value}))

    def test_retired_decoder_options_are_refused_by_name(self):
        # The native decoder rules were retired for BASIC parity: every key is refused whatever its value, alone
        # or beside kept options, and the message names the key.
        self.assertEqual(set(RETIRED_DECODER_OPTIONS), {"fire_hold_teammates", "strafe_legs", "aim_snap", "steady_shot",
                                                        "aim_retarget", "shot_gate", "spray_aim", "spray_gate"})
        for key in RETIRED_DECODER_OPTIONS:
            for value in (True, False, {}, {"radius": 150}, [], 0):
                for decoder in ({key: value}, {"sampling": {"mode": "categorical"}, key: value},
                                {key: value, "forbid_objectives": [9, 10]}):
                    with self.assertRaisesRegex(ValueError, r"^decoder\.%s was %s" % (key, RETIRED),
                                                msg=repr(decoder)):
                        unpack_package(package({**SCHEMA2, "decoder": decoder}))
            # Under every action contract, the ffa.view.1 pointer one included.
            with self.assertRaisesRegex(ValueError, r"decoder\.%s was %s" % (key, RETIRED)):
                unpack_package(package({**SCHEMA2, "action_contract": OFFSET, "decoder": {key: {}}}, model=OFFSET_MODEL))
            with self.assertRaisesRegex(ValueError, r"decoder\.%s was %s" % (key, RETIRED)):
                unpack_package(package({**SCHEMA2, "observation_contract": FFA, "action_contract": POINTER,
                                        "decoder": {key: {}}}, model=FFA_MODEL))

    def test_retired_decoder_options_match_the_engine(self):
        self.assertEqual(list(RETIRED_DECODER_OPTIONS), nim_strings("neural_host.nim", "RetiredDecoderOptions"))

    def test_sampling_option(self):
        for sampling in ({"mode": "categorical"},
                         {"mode": "categorical", "temperature": 0.5, "heads": [0, 2]},
                         {"mode": "categorical", "temperature": 10},
                         {"mode": "categorical", "temperature": 0.01, "heads": [4, 3, 2, 1, 0]}):
            _, _, manifest = unpack_package(package({**SCHEMA2, "decoder": {"forbid_objectives": [9], "sampling": sampling}}))
            self.assertEqual(manifest["decoder"]["sampling"], sampling)
        with self.assertRaisesRegex(ValueError, "schema 2"):
            unpack_package(package({"decoder": {"sampling": {"mode": "categorical"}}}))
        for sampling, message in (({}, "mode"), ({"mode": "argmax"}, "mode"), ({"mode": "categorical", "temperature": 0}, "within"),
                                  ({"mode": "categorical", "temperature": 11}, "within"), ({"mode": "categorical", "temperature": "1"}, "number"),
                                  ({"mode": "categorical", "temperature": True}, "number"), ({"mode": "categorical", "heads": []}, "non-empty"),
                                  ({"mode": "categorical", "heads": [7]}, "heads 7 and 8 need action contract teams.view.1 movement-offset"),
                                  ({"mode": "categorical", "heads": [10]}, r"indices 0 \.\. 9"), ({"mode": "categorical", "heads": [-1]}, "indices"),
                                  ({"mode": "categorical", "heads": [1, 1]}, "repeats"),
                                  ({"mode": "categorical", "heads": "all"}, "non-empty"), ({"mode": "categorical", "heads": [True]}, "indices"),
                                  ({"mode": "categorical", "seed": 1}, "unknown decoder.sampling field"), (True, "must be a dict"), ([], "must be a dict")):
            with self.assertRaisesRegex(ValueError, message, msg=repr(sampling)):
                unpack_package(package({**SCHEMA2, "decoder": {"sampling": sampling}}))

    def test_joint_sampling_option(self):
        stand = [1000] + [0] * 50
        for joint in ({"when": {"head": 2, "value": 1}, "head": 0, "offsets": stand},
                      {"when": {"head": 0, "value": 50}, "head": 1, "offsets": [0.5] * 25},
                      {"head": 4, "offsets": [-1000, 1000], "when": {"value": 0, "head": 3}}):
            _, _, manifest = unpack_package(package({**SCHEMA2, "decoder": {"joint_sampling": joint}}))
            self.assertEqual(manifest["decoder"]["joint_sampling"], joint)
        with self.assertRaisesRegex(ValueError, "schema 2"):
            unpack_package(package({"decoder": {"joint_sampling": {"when": {"head": 2, "value": 1}, "head": 0, "offsets": stand}}}))
        good = {"when": {"head": 2, "value": 1}, "head": 0, "offsets": stand}
        for joint, message in (({**good, "head": 2}, "differ"), ({**good, "when": {"head": 2, "value": 2}}, "choice of head"),
                               ({**good, "offsets": [0] * 25}, "must list 51"), ({**good, "offsets": [1001] + [0] * 50}, "within"),
                               ({**good, "offsets": ["0"] * 51}, "numbers"), ({**good, "offsets": [True] * 51}, "numbers"),
                               ({"when": good["when"], "head": 0}, "needs"), ({**good, "when": {"head": 2}}, "needs head and value"),
                               ({**good, "t": 1}, "unknown decoder.joint_sampling field"), ({**good, "when": {"head": 5, "value": 1}}, "head index"),
                               ({**good, "head": True}, "head index"), ({**good, "when": [2, 1]}, "must be an object"),
                               ([], "must be a dict")):
            with self.assertRaisesRegex(ValueError, message, msg=repr(joint)):
                unpack_package(package({**SCHEMA2, "decoder": {"joint_sampling": joint}}))

    def test_forbid_objectives_option(self):
        for forbid in ([9, 10], [0], [50, 1], list(range(50))):
            _, _, manifest = unpack_package(package({**SCHEMA2, "decoder": {"forbid_objectives": forbid}}))
            self.assertEqual(manifest["decoder"]["forbid_objectives"], forbid)
        with self.assertRaisesRegex(ValueError, "schema 2"):
            unpack_package(package({"decoder": {"forbid_objectives": [9, 10]}}))
        for forbid, message in (([], "non-empty"), ([51], "indices"), ([-1], "indices"), ([9.0], "indices"), ([True], "indices"),
                                (["9"], "indices"), ([9, 9], "repeats"), (list(range(51)), "leave an objective"),
                                ("9,10", "must be a list"), ({"9": 1}, "must be a list")):
            with self.assertRaisesRegex(ValueError, message, msg=repr(forbid)):
                unpack_package(package({**SCHEMA2, "decoder": {"forbid_objectives": forbid}}))

    def test_every_kept_option_together(self):
        decoder = {"sampling": {"mode": "categorical", "temperature": 0.7}, "forbid_objectives": [9, 10],
                   "joint_sampling": {"when": {"head": 2, "value": 1}, "head": 0, "offsets": [1000] + [0] * 50}}
        _, _, manifest = unpack_package(package({**SCHEMA2, "decoder": decoder}))
        self.assertEqual(manifest["decoder"], decoder)


class ContractTests(unittest.TestCase):
    """Only teams.view.1 (+ teams.view.1u<K>) with action teams.view.1 or its aim-offset variant, and ffa.view.1
    with ffa.view.1 pointer, are staged; neural_contract.nim / neural_host.nim hold the same rules."""

    def test_contract_hashes_match_the_engine(self):
        # neural_contract.nim holds each id; the hash actors and manifests carry is the SHA-256 of the id.
        source = (ROOT / "examples/paintbot/neural_contract.nim").read_text()
        ids = dict(re.findall(r'^  (\w+)\* = "([^"]*)"', source, re.M))
        for name, ours, ours_hash in (
                ("ObservationContractTeamsView1", OBSERVATION_CONTRACT_TEAMS_VIEW_1, TEAMS),
                ("ObservationContractFfaView1", OBSERVATION_CONTRACT_FFA_VIEW_1, FFA),
                ("ActionContractTeamsView1", ACTION_CONTRACT_TEAMS_VIEW_1, ACT),
                ("ActionContractTeamsView1Offset", ACTION_CONTRACT_TEAMS_VIEW_1_OFFSET, OFFSET),
                ("ActionContractFfaView1Pointer", ACTION_CONTRACT_FFA_VIEW_1_POINTER, POINTER)):
            self.assertEqual(ids[name], ours, name)
            self.assertEqual(sha(ids[name]), ours_hash, name)
            self.assertRegex(source, r"(?m)^  %sHash\* = sha256Hex\(%s\)$" % (name, name))
        self.assertEqual(OBSERVATION_CONTRACT_TEAMS_VIEW_1, "paintbot-pw.teams.view.1")
        self.assertEqual(OBSERVATION_CONTRACT_FFA_VIEW_1, "paintbot-pw.ffa.view.1")
        self.assertEqual(len({TEAMS, FFA, ACT, OFFSET, POINTER}), 5)
        # Widths and heads.
        self.assertEqual(TEAMS_VIEW_1_SIZE, 512)
        self.assertIn("doAssert TeamsViewSize == 512", source)
        self.assertEqual(ACTION_SIZES, (51, 25, 2, 2, 2))
        self.assertEqual(ACTION_SIZES_OFFSET, ACTION_SIZES + (23, 23))
        self.assertRegex(source, r"(?m)^  ActionSizes\* = \[51, 25, 2, 2, 2\]$")
        self.assertRegex(source, r"(?m)^  AimOffsetBins\* = 23$")
        self.assertRegex(source, r"(?m)^  ActionSizesOffset\* = \[51, 25, 2, 2, 2, AimOffsetBins, AimOffsetBins\]$")

    def test_retired_contracts_match_the_engine(self):
        self.assertEqual(list(RETIRED_OBSERVATION_CONTRACTS), nim_strings("neural_contract.nim", "RetiredObservationContractIds"))
        self.assertEqual(list(RETIRED_ACTION_CONTRACTS), nim_strings("neural_contract.nim", "RetiredActionContractIds"))
        source = (ROOT / "examples/paintbot/neural_contract.nim").read_text()
        self.assertIn('retiredHashes.add sha256Hex("paintbot-pw.rules39.obs.v2u" & $k)', source)
        self.assertIn('retiredHashes.add sha256Hex("paintbot-pw.rules43.obs.v3u" & $k)', source)
        self.assertEqual(len(RETIRED_CONTRACT_HASHES), 5 + 3 + 2 * RETIRED_USER_INPUTS)
        self.assertEqual(RETIRED_USER_INPUTS, 128)
        self.assertFalse(RETIRED_CONTRACT_HASHES & ({TEAMS, FFA, ACT, OFFSET, POINTER} | set(USER_INPUTS_CONTRACT_HASHES)))

    def test_each_retired_observation_contract_is_refused(self):
        # Refused by name before anything else is read (the model here is not even an actor).
        retired = [sha(c) for c in RETIRED_OBSERVATION_CONTRACTS]
        retired += [sha("paintbot-pw.rules39.obs.v2u%d" % k) for k in range(1, RETIRED_USER_INPUTS + 1)]
        retired += [sha("paintbot-pw.rules43.obs.v3u%d" % k) for k in range(1, RETIRED_USER_INPUTS + 1)]
        self.assertEqual(sha("paintbot-pw.rules37.obs.v2.float506"), retired[1])
        self.assertEqual(sha("paintbot-pw.rules39.obs.v2u1"), "bd80f4d35088c1f5e673e9b91d16df826e1cfb0e590185dbf4d8bf59af0bdb04")
        self.assertEqual(sha("paintbot-pw.rules43.obs.v3u1"), "8086b6f36b9c2cf07e9e6586e97221e484f809e08669075663c5dcf9cb63ac36")
        for digest in retired:
            for action in (ACT, POINTER):
                with self.assertRaisesRegex(ValueError, "^neural observation contract was %s" % RETIRED, msg=digest):
                    unpack_package(package({**SCHEMA2, "observation_contract": digest, "action_contract": action,
                                            "user_inputs": {"count": 3, "init": [0, 0, 0]}}, model=b"x"))

    def test_each_retired_action_contract_is_refused(self):
        self.assertEqual([sha(c) for c in RETIRED_ACTION_CONTRACTS],
                         [sha("paintbot-pw.rules37.action.v1.51-25-2-2-2"), sha("paintbot-pw.rules37.action.v2.51-25-2-2-2"),
                          sha("paintbot-pw.rules48.action.ffa.v2.pointer")])
        for contract in RETIRED_ACTION_CONTRACTS:
            for observation in (TEAMS, FFA, tv1u_hash(3)):
                with self.assertRaisesRegex(ValueError, "^neural action contract was %s" % RETIRED, msg=contract):
                    unpack_package(package({"observation_contract": observation, "action_contract": sha(contract)}))
        # A retired pair names the observation first, as the host does.
        with self.assertRaisesRegex(ValueError, "^neural observation contract was %s" % RETIRED):
            unpack_package(package({"observation_contract": sha(RETIRED_OBSERVATION_CONTRACTS[0]),
                                    "action_contract": sha(RETIRED_ACTION_CONTRACTS[0])}))

    def test_unknown_contracts_are_refused(self):
        for digest in ("a" * 64, sha("paintbot-pw.teams.view.2"), sha(user_inputs_contract_id(0)),
                       sha(user_inputs_contract_id(MAX_USER_INPUTS + 1)), sha("paintbot-pw.ffa.view.1u0"),
                       sha("paintbot-pw.ffa.view.1u257"), ACT, POINTER):
            with self.assertRaisesRegex(ValueError, "unknown neural observation contract", msg=digest):
                unpack_package(package({"observation_contract": digest}))
        for digest in ("b" * 64, TEAMS, FFA, sha("paintbot-pw.teams.view.1.action.51-25-2-2-2-23"),
                       sha("paintbot-pw.ffa.view.1.action.51-25-2-2-2")):
            with self.assertRaisesRegex(ValueError, "unknown neural action contract", msg=digest):
                unpack_package(package({"action_contract": digest}))

    def test_pairings_are_enforced(self):
        pairing = "teams.view.1 goes with action contract teams.view.1"
        ffa = {"observation_contract": FFA, "action_contract": POINTER}
        # The accepted pairs.
        unpack_package(package())
        unpack_package(package({"action_contract": OFFSET}, model=OFFSET_MODEL))
        unpack_package(package(ffa, model=FFA_MODEL))
        k = 3
        inputs = {**SCHEMA2, "observation_contract": tv1u_hash(k), "user_inputs": {"count": k, "init": [0] * k}}
        unpack_package(package(inputs, model=actor_bytes(TEAMS_VIEW_1_SIZE + k, tv1u_hash(k))))
        unpack_package(package({**inputs, "action_contract": OFFSET},
                               model=actor_bytes(TEAMS_VIEW_1_SIZE + k, tv1u_hash(k), heads=ACTION_SIZES_OFFSET,
                                                 action_hash=OFFSET)))
        # The crossed ones.
        for observation, action in ((TEAMS, POINTER), (tv1u_hash(k), POINTER), (FFA, ACT), (FFA, OFFSET)):
            overrides = {"observation_contract": observation, "action_contract": action}
            if observation == tv1u_hash(k):
                overrides.update(SCHEMA2, user_inputs={"count": k, "init": [0] * k})
            with self.assertRaisesRegex(ValueError, pairing, msg=(observation, action)):
                unpack_package(package(overrides, model=FFA_MODEL))

    def test_teams_view_1_checks_its_actor(self):
        for schema in ("paintbot-neural-basic/1", "paintbot-neural-basic/2"):
            for overrides, model in (({}, TEAMS_MODEL), ({"action_contract": OFFSET}, OFFSET_MODEL)):
                _, staged, manifest = unpack_package(package({"schema": schema, **overrides}, model=model))
                self.assertEqual(int.from_bytes(staged[12:16], "little"), TEAMS_VIEW_1_SIZE)
        with self.assertRaisesRegex(ValueError, "input count must be 512 for observation contract teams.view.1$"):
            unpack_package(package(model=actor_bytes(506, TEAMS)))
        with self.assertRaisesRegex(ValueError, "input count must be 512"):
            unpack_package(package(model=actor_bytes(513, TEAMS)))
        with self.assertRaisesRegex(ValueError, "package and actor contract mismatch"):
            unpack_package(package(model=actor_bytes(TEAMS_VIEW_1_SIZE, FFA)))
        with self.assertRaisesRegex(ValueError, "package and actor contract mismatch"):
            unpack_package(package(model=actor_bytes(TEAMS_VIEW_1_SIZE, sha(RETIRED_OBSERVATION_CONTRACTS[1]))))
        with self.assertRaisesRegex(ValueError, "invalid neural actor magic"):
            unpack_package(package(model=b"neutral fixture"))
        with self.assertRaisesRegex(ValueError, "empty neural model"):
            unpack_package(package(model=b""))

    def test_sampling_heads_5_and_6_need_the_aim_offset_contract(self):
        offset = {**SCHEMA2, "action_contract": OFFSET}
        for heads in ([5], [6], [5, 6], [0, 1, 2, 3, 4, 5, 6], [6, 0]):
            sampling = {"mode": "categorical", "heads": heads}
            _, _, manifest = unpack_package(package({**offset, "decoder": {"sampling": sampling}}, model=OFFSET_MODEL))
            self.assertEqual(manifest["decoder"]["sampling"]["heads"], heads)
            with self.assertRaisesRegex(ValueError, "heads 5 and 6 need action contract teams.view.1 aim-offset"):
                unpack_package(package({**SCHEMA2, "decoder": {"sampling": sampling}}))
            with self.assertRaisesRegex(ValueError, "heads 5 and 6 need action contract teams.view.1 aim-offset"):
                unpack_package(package({**SCHEMA2, "observation_contract": FFA, "action_contract": POINTER,
                                        "decoder": {"sampling": sampling}}, model=FFA_MODEL))
        with self.assertRaisesRegex(ValueError, "heads 7 and 8 need action contract teams.view.1 movement-offset"):
            unpack_package(package({**offset, "decoder": {"sampling": {"mode": "categorical", "heads": [7]}}},
                                   model=OFFSET_MODEL))
        with self.assertRaisesRegex(ValueError, r"indices 0 \.\. 9"):
            unpack_package(package({**offset, "decoder": {"sampling": {"mode": "categorical", "heads": [10]}}},
                                   model=OFFSET_MODEL))
        # The other selection options keep reading the five fixed heads under the aim-offset contract.
        _, _, manifest = unpack_package(package({**offset, "decoder": {"forbid_objectives": [9]}}, model=OFFSET_MODEL))
        self.assertEqual(manifest["decoder"]["forbid_objectives"], [9])
        with self.assertRaisesRegex(ValueError, "head index 0 .. 4"):
            unpack_package(package({**offset, "decoder": {"joint_sampling": {"when": {"head": 5, "value": 1}, "head": 0,
                                                                             "offsets": [0] * 51}}}, model=OFFSET_MODEL))

    def test_movement_offset_contract(self):
        """Action contract teams.view.1 movement-offset (14): nine heads; sampling heads 5 .. 8; the engine's id."""
        source = (ROOT / "examples/paintbot/neural_contract.nim").read_text()
        ids = dict(re.findall(r'^  (\w+)\* = "([^"]*)"', source, re.M))
        self.assertEqual(ids["ActionContractTeamsView1Move"], ACTION_CONTRACT_TEAMS_VIEW_1_MOVE)
        self.assertEqual(sha(ACTION_CONTRACT_TEAMS_VIEW_1_MOVE), MOVE)
        self.assertRegex(source, r"(?m)^  ActionContractTeamsView1MoveHash\* = sha256Hex\(ActionContractTeamsView1Move\)$")
        self.assertEqual(ACTION_SIZES_MOVE, ACTION_SIZES_OFFSET + (23, 23))
        self.assertRegex(source, r"(?m)^  ActionSizesMove\* = \[51, 25, 2, 2, 2, AimOffsetBins, AimOffsetBins, "
                                 r"MoveOffsetBins, MoveOffsetBins\]$")
        self.assertEqual(len({ACT, OFFSET, MOVE, POINTER}), 4)
        move = {**SCHEMA2, "action_contract": MOVE}
        _, _, manifest = unpack_package(package(move, model=MOVE_MODEL))
        self.assertEqual(manifest["action_contract"], MOVE)
        for heads in ([7], [8], [5, 7], [0, 1, 2, 3, 4, 5, 6, 7, 8]):
            sampling = {"mode": "categorical", "heads": heads}
            _, _, manifest = unpack_package(package({**move, "decoder": {"sampling": sampling}}, model=MOVE_MODEL))
            self.assertEqual(manifest["decoder"]["sampling"]["heads"], heads)
        with self.assertRaisesRegex(ValueError, "observation contract teams.view.1 goes with"):
            unpack_package(package({**SCHEMA2, "observation_contract": FFA, "action_contract": MOVE}, model=MOVE_MODEL))
        # The fixed-head selection options still read heads 0 .. 4.
        with self.assertRaisesRegex(ValueError, "head index 0 .. 4"):
            unpack_package(package({**move, "decoder": {"joint_sampling": {"when": {"head": 7, "value": 1}, "head": 0,
                                                                           "offsets": [0] * 51}}}, model=MOVE_MODEL))

    def test_ffa_view_1_pointer_takes_sampling_only(self):
        ffa = {**SCHEMA2, "observation_contract": FFA, "action_contract": POINTER}
        _, _, manifest = unpack_package(package({**ffa, "decoder": {"sampling": {"mode": "categorical", "temperature": 0.5}}},
                                                model=FFA_MODEL))
        self.assertEqual(manifest["decoder"]["sampling"]["temperature"], 0.5)
        for decoder in ({"forbid_objectives": [9]},
                        {"joint_sampling": {"when": {"head": 2, "value": 1}, "head": 0, "offsets": [0] * 51}}):
            with self.assertRaisesRegex(ValueError, "not available under action contract ffa.view.1 pointer"):
                unpack_package(package({**ffa, "decoder": decoder}, model=FFA_MODEL))
        with self.assertRaisesRegex(ValueError, "user_inputs need observation contract ffa.view.1u<K>"):
            unpack_package(package({**ffa, "user_inputs": {"count": 1, "init": [0]}}, model=FFA_MODEL))


class UserInputTests(unittest.TestCase):
    """Observation contract teams.view.1u<K>: teams.view.1's 512 floats, then K user inputs (512 + K)."""

    def inputs_package(self, k=3, init=None, observation=None, inputs=None, schema="paintbot-neural-basic/2",
                       user_inputs="default", action=ACT):
        observation = observation or tv1u_hash(k)
        heads = ACTION_SIZES_OFFSET if action == OFFSET else ACTION_SIZES
        model = actor_bytes(TEAMS_VIEW_1_SIZE + k if inputs is None else inputs, observation, heads=heads,
                            action_hash=action)
        overrides = {"schema": schema, "observation_contract": observation, "action_contract": action}
        if user_inputs == "default":
            overrides["user_inputs"] = {"count": k, "init": init if init is not None else [0] * k}
        elif user_inputs is not None:
            overrides["user_inputs"] = user_inputs
        return package(overrides, model=model)

    def test_valid_user_inputs(self):
        for k in (1, 3, 32, 33, 64, 65, MAX_USER_INPUTS):
            for action in (ACT, OFFSET):
                _, model, manifest = unpack_package(self.inputs_package(
                    k, init=[USER_INPUT_LIMIT] + [-USER_INPUT_LIMIT] * (k - 1), action=action))
                self.assertEqual(manifest["user_inputs"]["count"], k)
                self.assertEqual(int.from_bytes(model[12:16], "little"), 512 + k)

    def test_user_inputs_field_rules(self):
        for value, message in (([], "must be an object"), ({"init": []}, "count is required"),
                               ({"count": 0, "init": []}, "within 1 .. 256"), ({"count": 257, "init": [0] * 257}, "within 1 .. 256"),
                               ({"count": 2.0, "init": [0, 0]}, "must be an integer"), ({"count": True, "init": [0]}, "integer"),
                               ({"count": 2}, "init is required"), ({"count": 2, "init": 5}, "init must be an array"),
                               ({"count": 2, "init": [0]}, "count entries"), ({"count": 1, "init": [1000001]}, "within -1000000"),
                               ({"count": 1, "init": [-1000001]}, "within"), ({"count": 1, "init": [0.5]}, "integers"),
                               ({"count": 1, "init": [0], "scale": 1}, "unknown user_inputs field")):
            with self.assertRaisesRegex(ValueError, message, msg=repr(value)):
                validate_user_inputs(value)
            with self.assertRaisesRegex(ValueError, message, msg=repr(value)):
                unpack_package(self.inputs_package(2, user_inputs=value))

    def test_user_inputs_need_schema_2_and_the_matching_contract(self):
        with self.assertRaisesRegex(ValueError, "need package schema 2"):
            unpack_package(self.inputs_package(schema="paintbot-neural-basic/1"))
        with self.assertRaisesRegex(ValueError, "user_inputs need observation contract teams.view.1u<K>"):
            unpack_package(self.inputs_package(observation=TEAMS, inputs=TEAMS_VIEW_1_SIZE))
        with self.assertRaisesRegex(ValueError, "teams.view.1u3 needs manifest user_inputs"):
            unpack_package(self.inputs_package(3, user_inputs=None))
        with self.assertRaisesRegex(ValueError, "does not match observation contract teams.view.1u3"):
            unpack_package(self.inputs_package(3, user_inputs={"count": 2, "init": [0, 0]}))

    def test_teams_view_1h_packages(self):
        """teams.view.1h (203): 612 floats (teams.view.1 + 100 history), and its u<K> variants at 612 + K."""
        self.assertEqual(TEAMS_VIEW_1H_SIZE, TEAMS_VIEW_1_SIZE + 100)
        h = OBSERVATION_CONTRACT_TEAMS_VIEW_1H_HASH
        self.assertEqual(h, sha("paintbot-pw.teams.view.1h"))
        unpack_package(self.inputs_package(observation=h, inputs=TEAMS_VIEW_1H_SIZE, user_inputs=None))
        hu = sha(user_inputs_contract_id(244, OBSERVATION_CONTRACT_TEAMS_VIEW_1H))
        unpack_package(self.inputs_package(244, observation=hu, inputs=TEAMS_VIEW_1H_SIZE + 244))
        with self.assertRaisesRegex(ValueError, "input count must be 856 for observation contract teams.view.1hu244"):
            unpack_package(self.inputs_package(244, observation=hu, inputs=TEAMS_VIEW_1_SIZE + 244))
        with self.assertRaisesRegex(ValueError, "input count must be 612 for observation contract teams.view.1h"):
            unpack_package(self.inputs_package(observation=h, inputs=TEAMS_VIEW_1_SIZE, user_inputs=None))

    def test_teams_view_1s_packages(self):
        """teams.view.1s (204): 740 floats (teams.view.1h + 128 stop clocks), and its u<K> variants at 740 + K."""
        self.assertEqual(TEAMS_VIEW_1S_SIZE, TEAMS_VIEW_1H_SIZE + 128)
        s = OBSERVATION_CONTRACT_TEAMS_VIEW_1S_HASH
        self.assertEqual(s, sha("paintbot-pw.teams.view.1s"))
        unpack_package(self.inputs_package(observation=s, inputs=TEAMS_VIEW_1S_SIZE, user_inputs=None))
        su = sha(user_inputs_contract_id(109, OBSERVATION_CONTRACT_TEAMS_VIEW_1S))
        unpack_package(self.inputs_package(109, observation=su, inputs=TEAMS_VIEW_1S_SIZE + 109))
        with self.assertRaisesRegex(ValueError, "input count must be 849 for observation contract teams.view.1su109"):
            unpack_package(self.inputs_package(109, observation=su, inputs=TEAMS_VIEW_1H_SIZE + 109))
        with self.assertRaisesRegex(ValueError, "input count must be 740 for observation contract teams.view.1s"):
            unpack_package(self.inputs_package(observation=s, inputs=TEAMS_VIEW_1H_SIZE, user_inputs=None))

    def test_teams_view_1t_packages(self):
        """teams.view.1t (205): 751 floats (teams.view.1s + 11 hunt clocks), and its u<K> variants at 751 + K."""
        self.assertEqual(TEAMS_VIEW_1T_SIZE, TEAMS_VIEW_1S_SIZE + 11)
        t = OBSERVATION_CONTRACT_TEAMS_VIEW_1T_HASH
        self.assertEqual(t, sha("paintbot-pw.teams.view.1t"))
        self.assertEqual(OBSERVATION_CONTRACT_TEAMS_VIEW_1T, "paintbot-pw.teams.view.1t")
        unpack_package(self.inputs_package(observation=t, inputs=TEAMS_VIEW_1T_SIZE, user_inputs=None))
        tu = sha(user_inputs_contract_id(43, OBSERVATION_CONTRACT_TEAMS_VIEW_1T))
        self.assertEqual(tu, sha("paintbot-pw.teams.view.1tu43"))
        unpack_package(self.inputs_package(43, observation=tu, inputs=TEAMS_VIEW_1T_SIZE + 43))
        with self.assertRaisesRegex(ValueError, "input count must be 794 for observation contract teams.view.1tu43"):
            unpack_package(self.inputs_package(43, observation=tu, inputs=TEAMS_VIEW_1S_SIZE + 43))
        with self.assertRaisesRegex(ValueError, "input count must be 751 for observation contract teams.view.1t"):
            unpack_package(self.inputs_package(observation=t, inputs=TEAMS_VIEW_1S_SIZE, user_inputs=None))
        with self.assertRaisesRegex(ValueError, "teams.view.1tu43 needs manifest user_inputs"):
            unpack_package(self.inputs_package(observation=tu, inputs=TEAMS_VIEW_1T_SIZE + 43, user_inputs=None))
        with self.assertRaisesRegex(ValueError, "user_inputs need observation contract teams.view.1tu<K>"):
            unpack_package(self.inputs_package(3, observation=t, inputs=TEAMS_VIEW_1T_SIZE + 3))

    def test_teams_view_1p_packages(self):
        """teams.view.1p (206): 755 floats (teams.view.1t + 4 own true timers), and its u<K> variants at 755 + K."""
        self.assertEqual(TEAMS_VIEW_1P_SIZE, TEAMS_VIEW_1T_SIZE + 4)
        p = OBSERVATION_CONTRACT_TEAMS_VIEW_1P_HASH
        self.assertEqual(p, sha("paintbot-pw.teams.view.1p"))
        self.assertEqual(OBSERVATION_CONTRACT_TEAMS_VIEW_1P, "paintbot-pw.teams.view.1p")
        unpack_package(self.inputs_package(observation=p, inputs=TEAMS_VIEW_1P_SIZE, user_inputs=None))
        pu = sha(user_inputs_contract_id(110, OBSERVATION_CONTRACT_TEAMS_VIEW_1P))
        self.assertEqual(pu, sha("paintbot-pw.teams.view.1pu110"))
        unpack_package(self.inputs_package(110, observation=pu, inputs=TEAMS_VIEW_1P_SIZE + 110))
        with self.assertRaisesRegex(ValueError, "input count must be 865 for observation contract teams.view.1pu110"):
            unpack_package(self.inputs_package(110, observation=pu, inputs=TEAMS_VIEW_1T_SIZE + 110))
        with self.assertRaisesRegex(ValueError, "input count must be 755 for observation contract teams.view.1p"):
            unpack_package(self.inputs_package(observation=p, inputs=TEAMS_VIEW_1T_SIZE, user_inputs=None))
        with self.assertRaisesRegex(ValueError, "teams.view.1pu110 needs manifest user_inputs"):
            unpack_package(self.inputs_package(observation=pu, inputs=TEAMS_VIEW_1P_SIZE + 110, user_inputs=None))
        with self.assertRaisesRegex(ValueError, "user_inputs need observation contract teams.view.1pu<K>"):
            unpack_package(self.inputs_package(3, observation=p, inputs=TEAMS_VIEW_1P_SIZE + 3))
        # 206 is not retired: engine state beyond BASIC by the operator's decision, refused nowhere
        self.assertNotIn(p, RETIRED_CONTRACT_HASHES)

    def test_teams_view_1i_packages(self):
        """teams.view.1i (207): 837 floats (teams.view.1p + cooldown / 288 + the 81-float item block), u<K> at 837 + K."""
        self.assertEqual(TEAMS_VIEW_1I_SIZE, TEAMS_VIEW_1P_SIZE + 1 + 81)
        i = OBSERVATION_CONTRACT_TEAMS_VIEW_1I_HASH
        self.assertEqual(i, sha("paintbot-pw.teams.view.1i"))
        self.assertEqual(OBSERVATION_CONTRACT_TEAMS_VIEW_1I, "paintbot-pw.teams.view.1i")
        unpack_package(self.inputs_package(observation=i, inputs=TEAMS_VIEW_1I_SIZE, user_inputs=None))
        iu = sha(user_inputs_contract_id(109, OBSERVATION_CONTRACT_TEAMS_VIEW_1I))
        self.assertEqual(iu, sha("paintbot-pw.teams.view.1iu109"))
        unpack_package(self.inputs_package(109, observation=iu, inputs=TEAMS_VIEW_1I_SIZE + 109))
        with self.assertRaisesRegex(ValueError, "input count must be 946 for observation contract teams.view.1iu109"):
            unpack_package(self.inputs_package(109, observation=iu, inputs=TEAMS_VIEW_1P_SIZE + 109))
        with self.assertRaisesRegex(ValueError, "input count must be 837 for observation contract teams.view.1i"):
            unpack_package(self.inputs_package(observation=i, inputs=TEAMS_VIEW_1P_SIZE, user_inputs=None))
        with self.assertRaisesRegex(ValueError, "teams.view.1iu109 needs manifest user_inputs"):
            unpack_package(self.inputs_package(observation=iu, inputs=TEAMS_VIEW_1I_SIZE + 109, user_inputs=None))
        with self.assertRaisesRegex(ValueError, "user_inputs need observation contract teams.view.1iu<K>"):
            unpack_package(self.inputs_package(3, observation=i, inputs=TEAMS_VIEW_1I_SIZE + 3))
        self.assertNotIn(i, RETIRED_CONTRACT_HASHES)

    def test_user_inputs_check_the_actor_input_count_and_contract(self):
        with self.assertRaisesRegex(ValueError, "input count must be 515 for observation contract teams.view.1u3"):
            unpack_package(self.inputs_package(3, inputs=TEAMS_VIEW_1_SIZE))
        with self.assertRaisesRegex(ValueError, "input count must be 515"):
            unpack_package(self.inputs_package(3, inputs=506 + 3))
        observation = tv1u_hash(3)
        with self.assertRaisesRegex(ValueError, "package and actor contract mismatch"):
            unpack_package(package({**SCHEMA2, "observation_contract": observation,
                                    "user_inputs": {"count": 3, "init": [0, 0, 0]}},
                                   model=actor_bytes(TEAMS_VIEW_1_SIZE + 3, tv1u_hash(2))))
        with self.assertRaisesRegex(ValueError, "package and actor contract mismatch"):
            unpack_package(package({**SCHEMA2, "observation_contract": observation,
                                    "user_inputs": {"count": 3, "init": [0, 0, 0]}},
                                   model=actor_bytes(TEAMS_VIEW_1_SIZE + 3, TEAMS)))
        with self.assertRaisesRegex(ValueError, "invalid neural actor magic"):
            unpack_package(package({**SCHEMA2, "observation_contract": observation,
                                    "user_inputs": {"count": 3, "init": [0, 0, 0]}}, model=b"neutral fixture"))

    def test_user_inputs_contract_ids_match_the_engine(self):
        source = (ROOT / "examples/paintbot/neural_contract.nim").read_text()
        self.assertIn('proc userInputsContractId*(k: int, base = ocTeamsView1): string =', source)
        self.assertIn('  observationContractId(base) & "u" & $k', source)
        self.assertEqual(user_inputs_contract_id(7), "paintbot-pw.teams.view.1u7")
        self.assertEqual(user_inputs_contract_id(5, OBSERVATION_CONTRACT_FFA_VIEW_1), "paintbot-pw.ffa.view.1u5")
        self.assertEqual(user_inputs_contract_id(244, OBSERVATION_CONTRACT_TEAMS_VIEW_1H), "paintbot-pw.teams.view.1hu244")
        consts = {name: int(value.replace("_", "")) for name, value in
                  re.findall(r"^  (\w+)\* = ([0-9_]+)(?:'i32)?$", source, re.M)}
        self.assertEqual((MAX_USER_INPUTS, USER_INPUT_LIMIT), (consts["MaxUserInputs"], consts["UserInputLimit"]))
        self.assertEqual(RETIRED_USER_INPUTS, consts["RetiredUserInputsMax"])
        self.assertEqual(MAX_USER_INPUTS, 256)
        self.assertEqual(USER_INPUTS_CONTRACT_HASHES, {tv1u_hash(k): k for k in range(1, 257)})
        self.assertNotIn(tv1u_hash(257), USER_INPUTS_CONTRACT_HASHES)
        # teams.view.1u257 is no contract (refused before the manifest's count is read); a count of 257 is refused
        # under any contract.
        with self.assertRaisesRegex(ValueError, "unknown neural observation contract"):
            unpack_package(self.inputs_package(257))
        with self.assertRaisesRegex(ValueError, "within 1 .. 256"):
            unpack_package(self.inputs_package(256, user_inputs={"count": 257, "init": [0] * 257}))
        with self.assertRaisesRegex(ValueError, "unknown neural observation contract"):
            unpack_package(self.inputs_package(256, observation=tv1u_hash(257)))

    def test_packages_without_user_inputs_are_unaffected(self):
        _, model, manifest = unpack_package(package(SCHEMA2))
        self.assertEqual(model, TEAMS_MODEL)
        self.assertNotIn("user_inputs", manifest)

    def test_user_input_feature_mirrors_the_engine(self):
        # float32(clamp(v)) / 1000 in float32 (neural_contract.nim userInputFeature, clampUserInput).
        f32 = lambda x: struct.unpack("<f", struct.pack("<f", x))[0]
        self.assertEqual(user_input_feature(1500), 1.5)
        self.assertEqual(user_input_feature(-2000), -2.0)
        self.assertEqual(user_input_feature(0), 0.0)
        self.assertEqual(user_input_feature(5), f32(0.005))
        self.assertEqual(user_input_feature(5_000_000), 1000.0)
        self.assertEqual(user_input_feature(-5_000_000), -1000.0)
        self.assertEqual(user_inputs_row([0.25, -1.0], [1500, -700]), [0.25, -1.0, 1.5, f32(-0.7)])
        self.assertEqual(user_inputs_row([0.25], []), [0.25])


def pwnet2(inputs, heads, layers, obs=TEAMS, act=ACT):
    """layers = [(type, [params], [extra u32], n_floats)] with deterministic small weights."""
    out = b"PWNET002" + struct.pack("<4I", 2, inputs, sum(heads), len(heads)) + struct.pack("<%dI" % len(heads), *heads)
    out += obs.encode() + act.encode() + struct.pack("<I", len(layers))
    rng = random.Random(1)
    for code, params, extra, floats in layers:
        out += struct.pack("<9I", code, *(list(params) + [0] * (8 - len(params))))
        out += struct.pack("<%dI" % len(extra), *extra)
        out += struct.pack("<%df" % floats, *(rng.uniform(-0.1, 0.1) for _ in range(floats)))
    return out


# A minimal ffa.view.1 pointer actor (staging leaves its layout to the engine).
FFA_MODEL = pwnet2(40, [21, 24, 2, 2, 2], [(1, [40, 51], [], 40 * 51)], obs=FFA, act=POINTER)
EPS = struct.unpack("<I", struct.pack("<f", 1e-5))[0]


def attn(groups, d, heads, blocks, ff, pass_offset, pass_length):
    extra = [x for g in groups for x in g]
    floats = sum(d * g[3] + d for g in groups) + blocks * (d + 3 * d * d + 3 * d + d * d + d + d + ff * d + ff + d * ff + d)
    return (5, [len(groups), d, heads, blocks, ff, pass_offset, pass_length, EPS], extra, floats)


class Pwnet2Tests(unittest.TestCase):
    """PWNET002 staging validation mirrors neural_actor.nim's loader and the host's budget check."""

    def example(self):
        # The documented example transformer (neural_actor.md): 3,307,774 operations.
        return pwnet2(506, [51, 25, 2, 2, 2], [
            attn([(24, 8, 10, 8, 0), (104, 8, 16, 8, 0)], 64, 4, 2, 64, 0, 24),
            (6, [232, 274], [], 0),
            (3, [426, 128, 0, 1], [], 2 * 128 * 426 + 2 * 128),
            (1, [128, 82, 1, 0], [], 128 * 82 + 82)])

    def test_example_transformer_cost(self):
        info = validate_pwnet2(self.example())
        self.assertEqual(info["operations"], 3307774)
        self.assertEqual((info["state"], info["layers"]), (128, 4))

    def test_pwnet001_shape_costs_the_pwnet001_formula(self):
        i, h, o = 448, 128, 82
        info = validate_pwnet2(pwnet2(i, [51, 25, 2, 2, 2], [
            (1, [i, h], [], i * h), (3, [h, h, 1, 0], [], 3 * h * h), (1, [h, o], [], o * h)]))
        self.assertEqual(info["operations"], 2 * (i * h + 3 * h * h + o * h) + 32 * h)

    def test_staging_accepts_and_rejects(self):
        # The example's shape over teams.view.1's 512 inputs (the concatenated slice covers the last 280).
        model = pwnet2(TEAMS_VIEW_1_SIZE, [51, 25, 2, 2, 2], [
            attn([(24, 8, 10, 8, 0), (104, 8, 16, 8, 0)], 64, 4, 2, 64, 0, 24),
            (6, [232, 280], [], 0),
            (3, [432, 128, 0, 1], [], 2 * 128 * 432 + 2 * 128),
            (1, [128, 82, 1, 0], [], 128 * 82 + 82)])
        self.assertEqual(unpack_package(package(model=model))[1], model)
        offset = pwnet2(TEAMS_VIEW_1_SIZE, list(ACTION_SIZES_OFFSET), [(1, [512, 128], [], 512 * 128)], act=OFFSET)
        self.assertEqual(unpack_package(package({"action_contract": OFFSET}, model=offset))[1], offset)
        # The manifest's contracts must be the actor's.
        with self.assertRaisesRegex(ValueError, "contract mismatch"):
            unpack_package(package({"observation_contract": FFA, "action_contract": POINTER}, model=model))
        with self.assertRaisesRegex(ValueError, "contract mismatch"):
            unpack_package(package({"action_contract": OFFSET}, model=model))
        with self.assertRaisesRegex(ValueError, "contract mismatch"):
            unpack_package(package(model=offset))
        with self.assertRaisesRegex(ValueError, "input count must be 512"):
            unpack_package(package(model=self.example()))
        big = pwnet2(TEAMS_VIEW_1_SIZE, [51, 25, 2, 2, 2], [
            attn([(24, 8, 10, 8, 0), (104, 8, 16, 8, 0), (232, 5, 32, 5, 0)], 128, 4, 2, 256, 0, 24),
            (1, [280, 82], [], 280 * 82)])
        with self.assertRaisesRegex(ValueError, "exceeds native operation budget"):
            unpack_package(package(model=big))
        # A PWNET001 actor is checked by its header only (the host's loader reads the rest).
        self.assertEqual(unpack_package(package())[1], TEAMS_MODEL)

    def test_structural_rejections(self):
        heads = [2, 2, 2]
        good = pwnet2(64, heads, [(1, [64, 16, 1], [], 64 * 16 + 16), (3, [16, 16, 1], [], 3 * 16 * 16),
                                  (1, [16, 6], [], 96)])
        validate_pwnet2(good)
        cases = [
            (good[:-1], "truncated"), (good + b"\0" * 4, "trailing"),
            (pwnet2(64, heads, [(1, [64, 7], [], 64 * 7)]), "last layer width"),
            (pwnet2(64, heads, [(1, [63, 6], [], 63 * 6)]), "DENSE input"),
            (pwnet2(64, heads, []), "layer count"),
            (pwnet2(64, heads, [(1, [64, 6, 2], [], 64 * 6)]), "must be 0 or 1"),
            (pwnet2(64, heads, [(1, [64, 6, 0, 0, 0, 0, 0, 1], [], 64 * 6)]), "unused parameter"),
            (pwnet2(64, heads, [(99, [], [], 0)]), "unknown layer type"),
            (pwnet2(64, heads, [(3, [64, 32, 1], [], 3 * 32 * 64), (1, [32, 6], [], 192)]), "highway"),
            (pwnet2(64, heads, [(1, [64, 6], [], 384), (4, [1], [], 0)]), "earlier layer"),
            (pwnet2(64, heads, [(1, [64, 2], [], 128), (6, [60, 5], [], 0)]), "outside the input"),
            (pwnet2(64, heads, [(2, [64, 0], [], 64), (1, [64, 6], [], 384)]), "eps"),
            (pwnet2(64, heads, [attn([(60, 8, 1, 8, 0)], 8, 2, 1, 8, 0, 0), (1, [16, 6], [], 96)]), "outside the input"),
            (pwnet2(64, heads, [attn([(0, 8, 8, 8, 8)], 8, 2, 1, 8, 0, 0), (1, [16, 6], [], 96)]), "valid index"),
            (pwnet2(64, heads, [attn([(0, 8, 8, 8, 0)], 8, 3, 1, 8, 0, 0), (1, [16, 6], [], 96)]), "heads"),
            (pwnet2(300, heads, [attn([(0, 1, 200, 4, 0), (0, 1, 57, 4, 0)], 8, 2, 1, 8, 0, 0), (1, [16, 6], [], 96)]),
             "tokens exceed 256"),
            (pwnet2(64, heads, [(1, [64, 6], [], 384)], obs="G" * 64), "contract hash"),
        ]
        for model, fragment in cases:
            with self.assertRaisesRegex(ValueError, fragment):
                validate_pwnet2(model)
        nonfinite = bytearray(good)
        nonfinite[-4:] = struct.pack("<f", float("inf"))
        with self.assertRaisesRegex(ValueError, "nonfinite"):
            validate_pwnet2(bytes(nonfinite))

    @staticmethod
    def token_mlp(tokens, segments, valid, widths):
        n, floats = sum(seg[2] for seg in segments), 0
        for o in widths:
            floats += o * n + o
            n = o
        return (7, [tokens, len(segments), valid[0], valid[1], len(widths)],
                [x for seg in segments for x in seg] + list(widths), floats)

    def entity_factored_layers(self, inputs=538):
        segments = [(104, 8, 8), (470, 2, 2), (0, 0, 24), (448, 0, 2), (506, 1, 1), (522, 1, 1)]
        return [
            self.token_mlp(16, segments, (0, 0), [128, 128]),
            (6, [0, inputs], [], 0),
            (1, [256 + inputs, 128], [], (256 + inputs) * 128),
            (3, [128, 128, 1, 0], [], 3 * 128 * 128),
            (8, [0, 64], [], 64 * 128 + 64 + 64 * 128),
            (1, [256, 82, 1, 0], [], 256 * 82 + 82),
            (9, [4, 52], [], 65)]

    def entity_factored(self, inputs=538):
        # neural_actor.md's entity-factored example (538 inputs): 1,327,278 operations (test_paintbot_neural_net2).
        return pwnet2(inputs, [51, 25, 2, 2, 2], self.entity_factored_layers(inputs))

    def test_token_layers_cost_and_structure(self):
        info = validate_pwnet2(self.entity_factored())
        self.assertEqual(info["operations"], 1327278)
        self.assertEqual((info["state"], info["layers"]), (128, 7))
        heads = [2, 2, 2, 3]
        mlp = self.token_mlp(5, [(0, 8, 6), (50, 0, 3)], (0, 0), [8, 5])
        mix = (8, [0, 4], [], 4 * 5 + 4 + 4 * 10)
        good = [mlp, mix, (1, [18, 9, 1], [], 18 * 9 + 9), (9, [1, 3], [], 5)]
        validate_pwnet2(pwnet2(64, heads, good))
        cases = [
            ([self.token_mlp(0, [(0, 8, 6)], (0, 0), [4]), (1, [8, 9], [], 72)], "tokens"),
            ([self.token_mlp(9, [(0, 8, 6)], (0, 0), [4]), (1, [8, 9], [], 72)], "outside the input"),
            ([self.token_mlp(5, [(0, 65, 6)], (0, 0), [4]), (1, [8, 9], [], 72)], "length/stride"),
            ([self.token_mlp(5, [(0, 8, 6)], (1, 0), [4]), (1, [8, 9], [], 72)], "valid flag"),
            ([self.token_mlp(5, [(0, 8, 6)], (0, 6), [4]), (1, [8, 9], [], 72)], "valid flag"),
            ([self.token_mlp(5, [(0, 8, 6)], (0xFFFFFFFF, 1), [4]), (1, [8, 9], [], 72)], "valid index 0"),
            ([self.token_mlp(5, [(0, 8, 6)], (0, 0), [300]), (1, [600, 9], [], 5400)], "widths"),
            ([self.token_mlp(5, [(0, 8, 6)], (0, 0), [4, 4, 4, 4, 4]), (1, [8, 9], [], 72)], "layers"),
            ([mlp, (8, [0, 4], [], 64), (1, [18, 9, 1], [], 171), (9, [2, 3], [], 5)], "earlier TOKEN_MIX"),
            ([mlp, (8, [0, 4], [], 64), (1, [18, 9, 1], [], 171), (9, [1, 6], [], 5)], "exceeds width"),
            ([(1, [64, 10], [], 640), (8, [0, 4], [], 60), (1, [18, 9], [], 162)], "earlier TOKEN_MLP"),
            ([mlp, (8, [0, 0], [], 0), (1, [10, 9], [], 90)], "TOKEN_MIX width"),
        ]
        for layers, fragment in cases:
            with self.assertRaisesRegex(ValueError, fragment):
                validate_pwnet2(pwnet2(64, heads, layers))
        wide = [self.token_mlp(1, [(0, 0, 200)] * 6, (0, 0), [4]), (1, [8, 9], [], 72)]
        with self.assertRaisesRegex(ValueError, "token input"):
            validate_pwnet2(pwnet2(200, heads, wide))

    def test_pointer_k_and_the_target_offset_contract(self):
        """POINTER_K (layer 15): K logits per token, its cost, its structure; action contract 15 (818 logits)."""
        source = (ROOT / "examples/paintbot/neural_contract.nim").read_text()
        ids = dict(re.findall(r'^  (\w+)\* = "([^"]*)"', source, re.M))
        self.assertEqual(ids["ActionContractTeamsView1Target"], ACTION_CONTRACT_TEAMS_VIEW_1_TARGET)
        self.assertEqual(sha(ACTION_CONTRACT_TEAMS_VIEW_1_TARGET), ACTION_CONTRACT_TEAMS_VIEW_1_TARGET_HASH)
        mlp = self.token_mlp(5, [(0, 8, 6), (50, 0, 3)], (0, 0), [8, 5])
        mix = (8, [0, 4], [], 4 * 5 + 4 + 4 * 10)
        good = [mlp, mix, (1, [18, 15, 1], [], 18 * 15 + 15), (15, [1, 0, 3], [], 3 * 4 + 3)]
        info = validate_pwnet2(pwnet2(64, [7, 8], good))
        base = validate_pwnet2(pwnet2(64, [7, 8], good[:3]))
        self.assertEqual(info["operations"] - base["operations"], pointer_k_ops(5, 4, 15, 3))
        self.assertEqual(pointer_k_ops(5, 4, 15, 3), 15 + 5 * 3 * 10)
        cases = [([mlp, mix, (1, [18, 15, 1], [], 285), (15, [2, 0, 3], [], 15)], "POINTER_K source"),
                 ([mlp, mix, (1, [18, 15, 1], [], 285), (15, [1, 0, 0], [], 0)], "logits per token"),
                 ([mlp, mix, (1, [18, 15, 1], [], 285), (15, [1, 1, 3], [], 15)], "exceeds width"),
                 ([mlp, mix, (1, [18, 15, 1], [], 285), (15, [1, 0, 3, 1], [], 15)], "unused")]
        for layers, fragment in cases:
            with self.assertRaisesRegex(ValueError, fragment):
                validate_pwnet2(pwnet2(64, [7, 8], layers))
        target = {**SCHEMA2, "action_contract": ACTION_CONTRACT_TEAMS_VIEW_1_TARGET_HASH}
        model = pwnet2(TEAMS_VIEW_1_SIZE, [51, 25, 2, 2, 2, 368, 368], [(1, [TEAMS_VIEW_1_SIZE, 818, 1, 0], [], TEAMS_VIEW_1_SIZE * 818 + 818)],
                       act=ACTION_CONTRACT_TEAMS_VIEW_1_TARGET_HASH)
        _, _, manifest = unpack_package(package({**target, "decoder": {"sampling": {"mode": "categorical",
                                                                                     "heads": [5, 6]}}}, model=model))
        self.assertEqual(manifest["action_contract"], ACTION_CONTRACT_TEAMS_VIEW_1_TARGET_HASH)
        with self.assertRaisesRegex(ValueError, "heads 7 and 8 need"):
            unpack_package(package({**target, "decoder": {"sampling": {"mode": "categorical", "heads": [7]}}}, model=model))

    def test_raw_contract(self):
        """Action contract 16 (raw): 63 x 7 u identity rows, walk direction / distance, look direction; heads 7 .. 9."""
        source = (ROOT / "examples/paintbot/neural_contract.nim").read_text()
        ids = dict(re.findall(r'^  (\w+)\* = "([^"]*)"', source, re.M))
        self.assertEqual(ids["ActionContractTeamsView1Raw"], ACTION_CONTRACT_TEAMS_VIEW_1_RAW)
        self.assertEqual(sha(ACTION_CONTRACT_TEAMS_VIEW_1_RAW), ACTION_CONTRACT_TEAMS_VIEW_1_RAW_HASH)
        raw = {**SCHEMA2, "action_contract": ACTION_CONTRACT_TEAMS_VIEW_1_RAW_HASH}
        model = pwnet2(TEAMS_VIEW_1_SIZE, [51, 25, 2, 2, 2, 1008, 1008, 256, 8, 128],
                       [(1, [TEAMS_VIEW_1_SIZE, 2490, 1, 0], [], TEAMS_VIEW_1_SIZE * 2490 + 2490)],
                       act=ACTION_CONTRACT_TEAMS_VIEW_1_RAW_HASH)
        for heads in ([9], [7, 8, 9], [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]):
            _, _, manifest = unpack_package(package({**raw, "decoder": {"sampling": {"mode": "categorical",
                                                                                    "heads": heads}}}, model=model))
            self.assertEqual(manifest["decoder"]["sampling"]["heads"], heads)
        with self.assertRaisesRegex(ValueError, "heads 9 needs action contract teams.view.1 raw"):
            unpack_package(package({**SCHEMA2, "action_contract": MOVE, "decoder": {"sampling": {
                "mode": "categorical", "heads": [9]}}}, model=MOVE_MODEL))

    def test_self_destruct_contract(self):
        """Action contract 17 (self-destruct): teams.view.1's five heads, then head 5 (2 bins); sampling head 5 only."""
        source = (ROOT / "examples/paintbot/neural_contract.nim").read_text()
        ids = dict(re.findall(r'^  (\w+)\* = "([^"]*)"', source, re.M))
        self.assertEqual(ids["ActionContractTeamsView1SelfDestruct"], ACTION_CONTRACT_TEAMS_VIEW_1_SELF_DESTRUCT)
        self.assertEqual(sha(ACTION_CONTRACT_TEAMS_VIEW_1_SELF_DESTRUCT), ACTION_CONTRACT_TEAMS_VIEW_1_SELF_DESTRUCT_HASH)
        sd = {**SCHEMA2, "action_contract": ACTION_CONTRACT_TEAMS_VIEW_1_SELF_DESTRUCT_HASH}
        model = pwnet2(TEAMS_VIEW_1_SIZE, [51, 25, 2, 2, 2, 2],
                       [(1, [TEAMS_VIEW_1_SIZE, 84, 1, 0], [], TEAMS_VIEW_1_SIZE * 84 + 84)],
                       act=ACTION_CONTRACT_TEAMS_VIEW_1_SELF_DESTRUCT_HASH)
        _, _, manifest = unpack_package(package(sd, model=model))
        self.assertEqual(manifest["action_contract"], ACTION_CONTRACT_TEAMS_VIEW_1_SELF_DESTRUCT_HASH)
        for heads in ([5], [0, 1, 2, 3, 4], [0, 1, 2, 3, 4, 5]):
            _, _, manifest = unpack_package(package({**sd, "decoder": {"sampling": {"mode": "categorical",
                                                                                   "heads": heads}}}, model=model))
            self.assertEqual(manifest["decoder"]["sampling"]["heads"], heads)
        for heads in ([6], [5, 6], [9]):
            with self.assertRaisesRegex(ValueError, "past 5 are not heads of action contract teams.view.1 self-destruct"):
                unpack_package(package({**sd, "decoder": {"sampling": {"mode": "categorical", "heads": heads}}},
                                       model=model))

    def test_token_layer_norm_cost_and_structure(self):
        # Params 6 = norm (0 or 1) and 7 = eps (FP32 bits) of TOKEN_MLP and TOKEN_MIX: a LayerNorm (gain, shift)
        # before the relu, T*(8*d + 32) operations per normalised width (neural_actor.layerNormOps).
        heads = [2, 2, 2, 3]
        mlp = self.token_mlp(5, [(0, 8, 6), (50, 0, 3)], (0, 0), [8, 5])
        mix = (8, [0, 4], [], 4 * 5 + 4 + 4 * 10)
        tail = [(1, [18, 9, 1], [], 18 * 9 + 9), (9, [1, 3], [], 5)]
        base = validate_pwnet2(pwnet2(64, heads, [mlp, mix] + tail))["operations"]
        norm_mlp = (7, mlp[1] + [0, 1, EPS], mlp[2], mlp[3] + 2 * 8 + 2 * 5)
        norm_mix = (8, [0, 4, 0, 0, 0, 0, 1, EPS], [], mix[3] + 2 * 4)
        info = validate_pwnet2(pwnet2(64, heads, [norm_mlp, norm_mix] + tail))
        self.assertEqual(layer_norm_ops(8), 96)
        self.assertEqual(info["operations"], base + token_norm_ops(5, [8, 5]) + token_norm_ops(5, [4]))
        self.assertEqual(info["operations"], base + 5 * (96 + 72) + 5 * 64)
        cases = [
            ([(7, mlp[1] + [0, 2, EPS], mlp[2], norm_mlp[3]), mix] + tail, "parameter 6 must be 0 or 1"),
            ([(7, mlp[1] + [0, 1, 0], mlp[2], norm_mlp[3]), mix] + tail, "eps must be finite and positive"),
            ([mlp, (8, [0, 4, 0, 0, 0, 0, 1, 0xFF800000], [], norm_mix[3])] + tail, "eps must be finite and positive"),
            ([(7, mlp[1] + [0, 0, EPS], mlp[2], mlp[3]), mix] + tail, "unused parameter 7"),
            ([mlp, (8, [0, 4, 0, 0, 0, 0, 0, EPS], [], mix[3])] + tail, "unused parameter 7"),
            ([(7, mlp[1] + [1], mlp[2], mlp[3]), mix] + tail, "unused parameter 5"),
            ([mlp, (8, [0, 4, 1], [], mix[3])] + tail, "unused parameter 2"),
            ([norm_mlp, (8, [0, 4, 0, 0, 0, 0, 1, EPS], [], mix[3])] + tail, "unknown layer type|truncated|trailing"),
        ]
        for layers, fragment in cases:
            with self.assertRaisesRegex(ValueError, fragment):
                validate_pwnet2(pwnet2(64, heads, layers))
        # The eps word is FP32 bits, never a layout word.
        word_eps = (8, [0, 4, 0, 0, 0, 0, 1, 0xFFFE0000], [], norm_mix[3])
        with self.assertRaisesRegex(ValueError, "eps must be finite and positive"):
            validate_pwnet2(pwnet2(64, heads, [mlp, word_eps] + tail))

    def test_token_pair_cost_and_structure(self):
        # TOKEN_PAIR (14): params source, p, geo_base, geo_stride, x, z, self_pairs; A [p, d], B [p, d], C [p, 10], b [p].
        heads = [2, 2, 2, 3]
        mlp = self.token_mlp(5, [(0, 8, 6), (50, 0, 3)], (0, 0), [8])     # rows 8, out 16
        pair = (14, [0, 4, 0, 8, 1, 2, 0], [], 2 * 4 * 8 + 4 * 10 + 4)    # rows 8 + 8 = 16, out 16 + 32 = 48
        mix = (8, [1, 4], [], 4 * 16 + 4 + 4 * 48)                      # 48 + 8 = 56
        tail = [(1, [56, 9, 1], [], 56 * 9 + 9), (9, [2, 3], [], 5)]
        info = validate_pwnet2(pwnet2(64, heads, [mlp, pair, mix] + tail))
        self.assertEqual(token_pair_ops(5, 8, 4, 16),
                         16 + 5 * (4 * 8 * 4 + 2 + 8) + 25 * (18 + 80 + 24) + 5 * (8 + 4) + (5 + 2 * 5 * 16 + 16 + 8))
        ops = (validate_pwnet2(pwnet2(64, heads, [mlp, (1, [16, 9, 1], [], 16 * 9 + 9)]))["operations"]
               - (2 * 16 * 9 + 9 + 9))
        self.assertEqual(info["operations"], ops + token_pair_ops(5, 8, 4, 16) + (2 * 48 * 4 + 48 + 5 * (2 * 16 * 4 + 12)
                         + 5 + 2 * 5 * 4 + 4 + 8) + (2 * 56 * 9 + 9 + 9) + (9 + 5 * (2 * 4 + 2)))
        cases = [
            ([mlp, (14, [0, 0, 0, 8, 1, 2], [], 0)] + tail, "TOKEN_PAIR width"),
            ([mlp, (14, [0, 4, 0, 8, 8, 2], [], pair[3])] + tail, "geometry stride"),
            ([mlp, (14, [0, 4, 40, 8, 1, 2], [], pair[3])] + tail, "geometry outside the input"),
            ([mlp, (14, [0, 4, 0, 8, 1, 2, 2], [], pair[3])] + tail, "parameter 6 must be 0 or 1"),
            ([(1, [64, 10], [], 640), (14, [0, 4, 0, 8, 1, 2], [], pair[3])] + tail, "TOKEN_PAIR source"),
        ]
        for layers, fragment in cases:
            with self.assertRaisesRegex(ValueError, fragment):
                validate_pwnet2(pwnet2(64, heads, layers))

    def test_delay_cost_state_and_structure(self):
        # DELAY (16): params offset, len; weights init [len]; y = [x, prev]; state len + 1 floats; cost len.
        heads = [2, 2, 2, 3]
        body = [(1, [64, 20, 1, 0], [], 64 * 20 + 20), (3, [20, 20, 1, 0], [], 3 * 20 * 20)]
        tail = [(1, [23, 9, 1], [], 23 * 9 + 9)]
        base = validate_pwnet2(pwnet2(64, heads, body + [(1, [20, 9, 1], [], 20 * 9 + 9)]))
        info = validate_pwnet2(pwnet2(64, heads, body + [(16, [5, 3], [], 3)] + tail))
        self.assertEqual(base["state"], 20)
        self.assertEqual(info["state"], 20 + 3 + 1)
        self.assertEqual(info["parameters"], base["parameters"] + 3 + 3 * 9)
        self.assertEqual(info["operations"], base["operations"] - (2 * 20 * 9 + 9) + 3 + (2 * 23 * 9 + 9))
        two = validate_pwnet2(pwnet2(64, heads, [(16, [0, 64], [], 64), (16, [60, 68], [], 68),
                                                 (1, [196, 9, 1], [], 196 * 9 + 9)]))
        self.assertEqual(two["state"], 65 + 69)
        cases = [
            ([(16, [0, 0], [], 0)] + [(1, [64, 9], [], 64 * 9)], "DELAY slice outside"),
            ([(16, [60, 5], [], 5)] + [(1, [69, 9], [], 69 * 9)], "DELAY slice outside"),
            ([(16, [65, 1], [], 1)] + [(1, [65, 9], [], 65 * 9)], "DELAY slice outside"),
            ([(16, [0, 4, 1], [], 4)] + [(1, [68, 9], [], 68 * 9)], "unused parameter 2"),
            ([(16, [0, w], [], w) for w in (64, 128, 256, 512, 1024, 2048)]     # state 4038 of 4096
             + [(1, [4096, 64], [], 4096 * 64), (16, [0, 64], [], 64), (1, [128, 9], [], 128 * 9)],
             "recurrent state exceeds"),
            ([(1, [64, 4000], [], 64 * 4000), (16, [0, 200], [], 200), (1, [4200, 9], [], 4200 * 9)], "output exceeds"),
            (body + [(16, [5, 3], [], 2)] + tail, ""),
        ]
        for layers, fragment in cases:
            with self.assertRaisesRegex(ValueError, fragment):
                validate_pwnet2(pwnet2(64, heads, layers))
        with self.assertRaisesRegex(ValueError, "COND_HEAD layers must come after"):
            validate_pwnet2(pwnet2(64, [2, 2, 2, 3], [(1, [64, 9], [], 576), (13, [0, 1], [], 4), (16, [0, 1], [], 1),
                                                       (1, [10, 9], [], 90)]))

    def test_cond_head_cost_and_structure(self):
        # COND_HEAD (13): params (condition head, re-selected head), weights size(head) x size(condition head),
        # passes the vector through; costs the copy of the width and the column add. After every other layer.
        heads = [51, 25, 2, 2, 2]
        body = [(1, [64, 82, 1, 0], [], 64 * 82 + 82)]
        base = validate_pwnet2(pwnet2(64, heads, body))
        info = validate_pwnet2(pwnet2(64, heads, body + [(13, [2, 0], [], 51 * 2)]))
        self.assertEqual(info["operations"], base["operations"] + 82 + 51)
        self.assertEqual(info["parameters"], base["parameters"] + 102)
        self.assertEqual(info["conditionals"], [(2, 0)])
        chain = body + [(13, [2, 0], [], 102), (13, [0, 1], [], 25 * 51)]
        self.assertEqual(validate_pwnet2(pwnet2(64, heads, chain))["conditionals"], [(2, 0), (0, 1)])
        cases = [
            (body + [(13, [2, 2], [], 4)], "must differ"),
            (body + [(13, [5, 0], [], 102)], "COND_HEAD heads must be"),
            (body + [(13, [2, 0, 1], [], 102)], "unused parameter 2"),
            (body + [(13, [2, 0], [], 102), (13, [3, 0], [], 102)], "already re-selected"),
            (body + [(13, [2, 0], [], 102), (13, [0, 2], [], 102)], "earlier COND_HEAD's condition"),
            ([(13, [2, 0], [], 102)] + [(1, [64, 82, 1, 0], [], 64 * 82 + 82)], "must come after every other layer"),
            (body + [(13, [2, 0], [], 100)], "truncated|trailing|unknown layer type"),
        ]
        for layers, fragment in cases:
            with self.assertRaisesRegex(ValueError, fragment):
                validate_pwnet2(pwnet2(64, heads, layers))

    def test_cond_head_and_joint_sampling_are_exclusive(self):
        model = pwnet2(512, [51, 25, 2, 2, 2], [(1, [512, 82, 1, 0], [], 512 * 82 + 82), (13, [2, 0], [], 102)])
        joint = {"when": {"head": 2, "value": 1}, "head": 0, "offsets": [0.0] * 51}
        unpack_package(package(SCHEMA2, model=model))
        with self.assertRaisesRegex(ValueError, "cannot be combined with the model's COND_HEAD"):
            unpack_package(package(dict(SCHEMA2, decoder={"joint_sampling": joint}), model=model))

    def test_cond_head_names_only_heads_0_to_4(self):
        # Under the aim-offset contract the actor has seven heads; COND_HEAD may still name only the five fixed ones.
        heads = list(ACTION_SIZES_OFFSET)
        body = [(1, [512, 128, 1, 0], [], 512 * 128 + 128)]

        def bundle(cond):
            model = pwnet2(512, heads, body + [(13, list(cond), [], heads[cond[1]] * heads[cond[0]])], act=OFFSET)
            return model, package({"action_contract": OFFSET}, model=model)
        model, staged = bundle((2, 0))
        self.assertEqual(unpack_package(staged)[1], model)
        model, staged = bundle((4, 1))
        self.assertEqual(unpack_package(staged)[1], model)
        for cond in ((5, 0), (0, 5), (2, 6), (6, 5)):
            model, staged = bundle(cond)
            self.assertEqual(validate_pwnet2(model)["conditionals"], [cond])  # structurally valid ...
            with self.assertRaisesRegex(ValueError, r"COND_HEAD layers may name only heads 0 \.\. 4", msg=cond):
                unpack_package(staged)  # ... but not staged

    @staticmethod
    def near(tokens=4, base=0, stride=8, xi=1, zi=2, vi=0, ei=6, ci=3, scale_x=2.0, scale_z=4.0, radius=1.0, dst=32,
             dst_stride=2):
        f = lambda v: struct.unpack("<I", struct.pack("<f", v))[0]  # noqa: E731
        return (10, [tokens, base, stride, xi, zi, vi, ei, ci], [f(scale_x), f(scale_z), f(radius), dst, dst_stride], 0)

    def test_segment_near_cost_and_structure(self):
        # SEGMENT_NEAR costs I + 12*T*T + 8*T: in front of the entity-factored example, 1,327,278 + 3,738.
        model = self.entity_factored()
        layers = [self.near(16, 104, 8, 1, 2, 0, 6, 3, 16000.0, 9600.0, 150.0, 522, 1)]
        for code, params, extra, floats in self.entity_factored_layers():
            if code in (4, 8, 9):
                params = [params[0] + 1] + params[1:]
            layers.append((code, params, extra, floats))
        info = validate_pwnet2(pwnet2(538, [51, 25, 2, 2, 2], layers))
        self.assertEqual(info["operations"], 1331016)
        self.assertEqual(info["operations"] - validate_pwnet2(model)["operations"], 538 + 12 * 16 * 16 + 8 * 16)
        self.assertEqual((info["state"], info["layers"]), (128, 8))
        heads = [20, 20]
        self.assertEqual(validate_pwnet2(pwnet2(40, heads, [self.near()]))["operations"], 40 + 12 * 16 + 8 * 4)
        accepted = [self.near(base=8, dst=0, dst_stride=1), self.near(dst=33), self.near(radius=0.0),
                    self.near(radius=-0.0), self.near(ei=0xFFFFFFFF), self.near(1, base=8, dst=39, dst_stride=0)]
        for layer in accepted:
            validate_pwnet2(pwnet2(40, heads, [layer]))
        nan, inf = float("nan"), float("inf")
        cases = [
            ([(1, [40, 40], [], 1600), self.near()], "layer 1: SEGMENT_NEAR must be layer 0"),
            ([self.near(), self.near()], "layer 1: SEGMENT_NEAR must be layer 0"),
            ([self.near(0)], "SEGMENT_NEAR tokens must be 1..256"),
            ([self.near(stride=0)], "SEGMENT_NEAR stride"),
            ([self.near(base=9)], "SEGMENT_NEAR tokens outside the input"),
            ([self.near(base=41)], "outside the input"),
            ([self.near(stride=11)], "outside the input"),
            ([self.near(xi=8)], "SEGMENT_NEAR index outside the token"),
            ([self.near(zi=8)], "index outside the token"),
            ([self.near(vi=8)], "index outside the token"),
            ([self.near(ei=8)], "index outside the token"),
            ([self.near(ei=0xFFFFFFFE)], "index outside the token"),
            ([self.near(ci=8)], "index outside the token"),
            ([self.near(dst=34)], "SEGMENT_NEAR flags outside the input"),
            ([self.near(dst=40)], "flags outside the input"),
            ([self.near(dst_stride=0)], "flags outside the input"),
            ([self.near(dst_stride=41)], "flags outside the input"),
            ([self.near(1, dst=40, dst_stride=0)], "flags outside the input"),
        ]
        for bad in (0.0, -1.0, nan, inf, -inf, -0.0):
            cases += [([self.near(scale_x=bad)], "SEGMENT_NEAR scales must be finite and positive"),
                      ([self.near(scale_z=bad)], "SEGMENT_NEAR scales must be finite and positive")]
        for bad in (-1.0, nan, inf, -inf, -1e-30):
            cases.append(([self.near(radius=bad)], "SEGMENT_NEAR radius must be finite and >= 0"))
        for layers, fragment in cases:
            with self.assertRaisesRegex(ValueError, fragment):
                validate_pwnet2(pwnet2(40, heads, layers))
        with self.assertRaisesRegex(ValueError, "tokens must be"):
            validate_pwnet2(pwnet2(600, [300, 300], [self.near(257)]))
        good = pwnet2(40, heads, [self.near()])
        with self.assertRaisesRegex(ValueError, "truncated"):
            validate_pwnet2(good[:-4])
        with self.assertRaisesRegex(ValueError, "trailing bytes"):
            validate_pwnet2(good + bytes(4))

    def test_pwnet002_with_user_inputs(self):
        # A PWNET002 actor with obs contract teams.view.1u<K> (512 + K inputs): the header is read through
        # validate_pwnet2 and the op count includes the K extra inputs.
        k = 3
        heads = [51, 25, 2, 2, 2]

        def bundle(model, count=k, observation=None):
            observation = observation or tv1u_hash(k)
            return package({**SCHEMA2, "observation_contract": observation,
                            "user_inputs": {"count": count, "init": [0] * count}}, model=model)

        width = TEAMS_VIEW_1_SIZE + k
        model = pwnet2(width, heads, [(6, [0, 24], [], 0), (1, [width + 24, 82], [], (width + 24) * 82)], obs=tv1u_hash(k))
        self.assertEqual(unpack_package(bundle(model))[1], model)
        self.assertEqual(validate_pwnet2(model)["operations"], 24 + 2 * (width + 24) * 82)
        short = pwnet2(TEAMS_VIEW_1_SIZE, heads, [(1, [TEAMS_VIEW_1_SIZE, 82], [], TEAMS_VIEW_1_SIZE * 82)], obs=tv1u_hash(k))
        with self.assertRaisesRegex(ValueError, "input count must be 515 for observation contract teams.view.1u3"):
            unpack_package(bundle(short))
        other = pwnet2(width, heads, [(1, [width, 82], [], width * 82)], obs=tv1u_hash(2))
        with self.assertRaisesRegex(ValueError, "package and actor contract mismatch"):
            unpack_package(bundle(other))
        with self.assertRaisesRegex(ValueError, "does not match observation contract teams.view.1u3"):
            unpack_package(bundle(model, count=2))

    def test_constants_match_the_engine(self):
        source = (ROOT / "examples/paintbot/neural_actor.nim").read_text()
        consts = {m.group(1): int(m.group(2).replace("_", ""))
                  for m in re.finditer(r"^\s+(Max\w+|TranscendentalOps|MinGruUnitOps)\* = ([0-9_]+)", source, re.M)}
        self.assertEqual(PWNET2_LIMITS, dict(parameters=consts["MaxNet2Parameters"], layers=consts["MaxNet2Layers"],
                                             width=consts["MaxNet2Width"], state=consts["MaxNet2State"],
                                             mingru_hidden=consts["MaxMinGruHidden"], groups=consts["MaxAttnGroups"],
                                             tokens=consts["MaxAttnTokens"], d_model=consts["MaxAttnModel"],
                                             blocks=consts["MaxAttnBlocks"], ff=consts["MaxAttnFeedForward"],
                                             token_segments=consts["MaxTokenSegments"],
                                             token_input=consts["MaxTokenInput"], token_model=consts["MaxTokenModel"],
                                             token_mlp_layers=consts["MaxTokenMlpLayers"],
                                             pool_heads=consts["MaxAttnPoolHeads"], pool_width=consts["MaxAttnPoolWidth"]))
        self.assertEqual((consts["TranscendentalOps"], consts["MinGruUnitOps"]), (8, 32))
        # SEGMENT_NEAR's published count: one formula in the loader, staging and neural_actor.md.
        self.assertIn("int64(inputs) + int64(tokens)*int64(tokens)*12 + int64(tokens)*8", source)
        self.assertIn("| SEGMENT_NEAR | `I + 12*T*T + 8*T` |", (ROOT / "examples/paintbot/neural_actor.md").read_text())
        self.assertEqual(segment_near_ops(538, 16), 538 + 12 * 16 * 16 + 8 * 16)
        host = (ROOT / "examples/paintbot/neural_host.nim").read_text()
        self.assertIn("MaxNeuralOperations* = %s'i64" % format(MAX_NEURAL_OPERATIONS, "_"), host)


def layout_word(section, field, addend=0):
    """neural_actor.layoutWord."""
    return LAYOUT_WORD_PREFIX | (section << 12) | (field << 8) | addend


class FfaView1PackageTests(unittest.TestCase):
    """Observation contract ffa.view.1 + action contract ffa.view.1 pointer bundles, layout words, ATTN_POOL, PAD,
    token caps of 256 and the seat-scaled budget: staging mirrors neural_host.nim / neural_actor.nim."""

    def bundle(self, model, decoder=None, obs=FFA, act=POINTER, seats=16):
        overrides = {**SCHEMA2, "observation_contract": obs, "action_contract": act}
        if decoder is not None:
            overrides["decoder"] = decoder
        return unpack_package(package(overrides, model=model), seats)

    def test_contract_ids(self):
        self.assertEqual(FFA, sha("paintbot-pw.ffa.view.1"))
        self.assertEqual(POINTER, sha("paintbot-pw.ffa.view.1.action.pointer"))

    def test_pairing_and_pointer_decoder_options(self):
        self.assertEqual(self.bundle(FFA_MODEL)[1], FFA_MODEL)
        self.bundle(FFA_MODEL, {"sampling": {"mode": "categorical", "temperature": 0.5}})
        with self.assertRaisesRegex(ValueError, "not available under action contract ffa.view.1 pointer"):
            self.bundle(FFA_MODEL, {"forbid_objectives": [9]})
        with self.assertRaisesRegex(ValueError, "aim_snap was %s" % RETIRED):
            self.bundle(FFA_MODEL, {"aim_snap": {}})
        pairing = "ffa.view.1 with ffa.view.1 pointer"
        with self.assertRaisesRegex(ValueError, pairing):
            self.bundle(pwnet2(40, [21, 24, 2, 2, 2], [(1, [40, 51], [], 40 * 51)], obs=FFA, act=ACT), act=ACT)
        with self.assertRaisesRegex(ValueError, pairing):
            self.bundle(pwnet2(40, [21, 24, 2, 2, 2], [(1, [40, 51], [], 40 * 51)], obs=TEAMS, act=POINTER), obs=TEAMS)
        with self.assertRaisesRegex(ValueError, "contract mismatch"):
            self.bundle(pwnet2(40, [21, 24, 2, 2, 2], [(1, [40, 51], [], 40 * 51)], obs=TEAMS, act=ACT))

    def test_layout_words_are_left_to_the_engine(self):
        words = pwnet2(layout_word(14, 0), [2, 2, 2], [(7, [layout_word(0, 0), 1, 0, 0, 1],
                                                        [layout_word(0, 1), layout_word(0, 2), 44, 8], 8 * 44 + 8),
                                                       (1, [16, 6], [], 16 * 6)], obs=FFA, act=POINTER)
        info = validate_pwnet2(words)
        self.assertTrue(info["layout_dependent"])
        self.assertEqual(info["observation_contract"], FFA)
        self.bundle(words)
        with self.assertRaisesRegex(ValueError, "contract mismatch"):
            validate_pwnet2(words, TEAMS, ACT)
        # Layout words need ffa.view.1: the same actor over teams.view.1 is refused.
        teams_words = pwnet2(layout_word(14, 0), [2, 2, 2], [(7, [layout_word(0, 0), 1, 0, 0, 1],
                                                              [layout_word(0, 1), layout_word(0, 2), 44, 8], 8 * 44 + 8),
                                                             (1, [16, 6], [], 16 * 6)])
        with self.assertRaisesRegex(ValueError, "layout words need observation contract ffa.view.1"):
            unpack_package(package(model=teams_words))

    def test_attn_pool_pad_and_exposed_attention_cost_as_the_engine(self):
        # neural_actor.nim's test model (test_paintbot_neural_layers): 17,686 operations.
        model = pwnet2(64, [4, 8], [
            attn([(0, 8, 8, 8, 0)], 8, 2, 1, 8, 0, 0),
            (8, [0, 6], [], 6 * 8 + 6 + 6 * 16),
            (11, [0, 2, 4, 3], [], 8 * 28 + 8 + 8 * 8 + 8 + 6 * 8 + 6),
            (1, [34, 12], [], 34 * 12),
            (9, [0, 4], [], 8 + 1)], obs=FFA, act=POINTER)
        info = validate_pwnet2(model)
        self.assertEqual(info["operations"], 17686)
        self.assertEqual(attn_pool_ops(8, 8, 28, 2, 4, 3), 2836)
        padded = pwnet2(8, [2, 2, 2, 2], [(1, [8, 4], [], 32), (12, [2, 4], [], 0)], obs=FFA, act=POINTER)
        self.assertEqual(validate_pwnet2(padded)["operations"], 2 * 8 * 4 + 8)
        with self.assertRaisesRegex(ValueError, "PAD position beyond width"):
            validate_pwnet2(pwnet2(8, [2, 2, 2, 2], [(1, [8, 4], [], 32), (12, [5, 4], [], 0)], obs=FFA, act=POINTER))
        with self.assertRaisesRegex(ValueError, "ATTN_POOL source"):
            validate_pwnet2(pwnet2(8, [2, 2, 2], [(1, [8, 4], [], 32), (11, [0, 1, 2, 2], [], 0)], obs=FFA, act=POINTER))

    def test_token_cap_is_256(self):
        ok = pwnet2(512, [2, 2, 2], [(7, [256, 1, 0, 0, 1], [0, 2, 2, 4], 4 * 2 + 4), (1, [8, 6], [], 48)],
                    obs=FFA, act=POINTER)
        validate_pwnet2(ok)
        with self.assertRaisesRegex(ValueError, "TOKEN_MLP tokens must be 1..256"):
            validate_pwnet2(pwnet2(1024, [2, 2, 2], [(7, [257, 1, 0, 0, 1], [0, 2, 2, 4], 4 * 2 + 4), (1, [8, 6], [], 48)],
                                   obs=FFA, act=POINTER))

    def test_budget_scales_with_seats(self):
        self.assertEqual((neural_budget(16), neural_budget(8), neural_budget(50)), (4000000, 4000000, 12500000))
        # 2 * 2000 * 1024 = 4,096,000 operations: over the 16-seat budget, within 50 seats'.
        big = pwnet2(2000, [512, 512], [(1, [2000, 1024], [], 2000 * 1024)], obs=FFA, act=POINTER)
        with self.assertRaisesRegex(ValueError, "operation budget"):
            self.bundle(big)
        self.bundle(big, seats=50)


class FfaUserInputTests(unittest.TestCase):
    """Observation contract ffa.view.1u<K>: the match's ffa.view.1 floats, then K user inputs (default off)."""

    def ffa_package(self, k=5, observation=None, user_inputs="default", action=POINTER):
        observation = observation or fv1u_hash(k)
        heads = [21, 24, 2, 2, 2] if action == POINTER else list(ACTION_SIZES)
        model = pwnet2(40, heads, [(1, [40, sum(heads)], [], 40 * sum(heads))], obs=observation, act=action)
        overrides = {**SCHEMA2, "observation_contract": observation, "action_contract": action}
        if user_inputs == "default":
            overrides["user_inputs"] = {"count": k, "init": [0] * k}
        elif user_inputs is not None:
            overrides["user_inputs"] = user_inputs
        return package(overrides, model=model)

    def test_ids_and_hashes_match_the_engine(self):
        self.assertEqual(fv1u_hash(5), sha("paintbot-pw.ffa.view.1u5"))
        self.assertEqual(FFA_USER_INPUTS_CONTRACT_HASHES, {fv1u_hash(k): k for k in range(1, MAX_USER_INPUTS + 1)})
        self.assertFalse(set(FFA_USER_INPUTS_CONTRACT_HASHES) & (set(USER_INPUTS_CONTRACT_HASHES) | RETIRED_CONTRACT_HASHES
                                                                | {TEAMS, FFA, ACT, OFFSET, POINTER}))
        # The base contracts and the teams family are unchanged.
        self.assertEqual(FFA, sha("paintbot-pw.ffa.view.1"))
        self.assertEqual(TEAMS, sha("paintbot-pw.teams.view.1"))
        self.assertEqual(USER_INPUTS_CONTRACT_HASHES, {sha("paintbot-pw.teams.view.1u%d" % k): k for k in range(1, MAX_USER_INPUTS + 1)})

    def test_staged_with_pointer_and_matching_user_inputs(self):
        for k in (1, 5, 64, MAX_USER_INPUTS):
            _, _, manifest = unpack_package(self.ffa_package(k))
            self.assertEqual(manifest["user_inputs"]["count"], k)
            self.assertEqual(manifest["observation_contract"], fv1u_hash(k))

    def test_refusals(self):
        with self.assertRaisesRegex(ValueError, "ffa.view.1u5 needs manifest user_inputs"):
            unpack_package(self.ffa_package(5, user_inputs=None))
        with self.assertRaisesRegex(ValueError, "does not match observation contract ffa.view.1u5"):
            unpack_package(self.ffa_package(5, user_inputs={"count": 4, "init": [0] * 4}))
        with self.assertRaisesRegex(ValueError, "user_inputs need observation contract ffa.view.1u<K>"):
            unpack_package(self.ffa_package(5, observation=FFA))
        with self.assertRaisesRegex(ValueError, "goes with"):
            unpack_package(self.ffa_package(5, action=ACT))
        with self.assertRaisesRegex(ValueError, "user_inputs need package schema 2"):
            unpack_package(package({"schema": "paintbot-neural-basic/1", "observation_contract": fv1u_hash(5),
                                    "action_contract": POINTER, "user_inputs": {"count": 5, "init": [0] * 5}},
                                   model=pwnet2(40, [21, 24, 2, 2, 2], [(1, [40, 51], [], 40 * 51)], obs=fv1u_hash(5),
                                                act=POINTER)))
        # A teams.view.1u<K> hash under the pointer contract is still refused.
        with self.assertRaisesRegex(ValueError, "goes with"):
            unpack_package(self.ffa_package(5, observation=tv1u_hash(5)))


if __name__ == "__main__":
    unittest.main()
