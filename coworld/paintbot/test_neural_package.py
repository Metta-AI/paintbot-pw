"""Neural archive boundary tests, independent of Wasmtime and the game binary."""
import hashlib
import io
import json
import re
import sys
import unittest
import zipfile
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent / "runtime"))
from neural_package import (unpack_package, validate_aim_retarget, validate_shot_gate, validate_fire_hold, MAX_MODEL_BYTES,
                            validate_spray_aim, validate_spray_gate, SPRAY_AIM_DEFAULTS, SPRAY_GATE_DEFAULTS, SPRAY_LIMITS,
                            AIM_RETARGET_DEFAULTS, MAX_RETARGET_RANGE, MAX_RETARGET_WEIGHT, SHOT_GATE_DEFAULTS,
                            MAX_SHOT_GATE_RANGE, validate_user_inputs, user_inputs_contract_id, MAX_USER_INPUTS,
                            USER_INPUT_LIMIT, OBSERVATION_V2_SIZE, validate_pwnet2, attention_ops,
                            MAX_NEURAL_OPERATIONS, PWNET2_LIMITS, USER_INPUTS_CONTRACT_HASHES, segment_near_ops,
                            OBSERVATION_V3_SIZE, OBSERVATION_CONTRACT_V3, OBSERVATION_CONTRACT_V3_HASH,
                            v3_user_inputs_contract_id, V3_USER_INPUTS_CONTRACT_HASHES)
import random
import struct


def actor_bytes(inputs, observation_hash, hidden=64, outputs=82):
    """A synthetic PWNET001 header (zero weights) with the given input count and observation hash."""
    heads = [51, 25, 2, 2, 2]
    parameters = inputs * hidden + 3 * hidden * hidden + outputs * hidden
    header = b"PWNET001" + b"".join(v.to_bytes(4, "little") for v in (1, inputs, hidden, outputs, len(heads), parameters))
    return (header + observation_hash.encode() + ("b" * 64).encode() +
            b"".join(h.to_bytes(4, "little") for h in heads) + bytes(4 * parameters))


def v2u_hash(k):
    return hashlib.sha256(user_inputs_contract_id(k).encode()).hexdigest()


def v3u_hash(k):
    return hashlib.sha256(v3_user_inputs_contract_id(k).encode()).hexdigest()


def package(overrides=None, extra=None, model=b"neutral fixture"):
    source = b"idle = 1\n"
    manifest = {"schema": "paintbot-neural-basic/1", "observation_contract": "a" * 64,
                "action_contract": "b" * 64,
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


class PackageTests(unittest.TestCase):
    def test_valid_package(self):
        source, model, manifest = unpack_package(package())
        self.assertEqual(source, b"idle = 1\n")
        self.assertEqual(model, b"neutral fixture")

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
        with self.assertRaisesRegex(ValueError, "contract"):
            unpack_package(package({"action_contract": "invalid"}))

    def test_schema_2_accepted_and_others_rejected(self):
        _, _, manifest = unpack_package(package({"schema": "paintbot-neural-basic/2"}))
        self.assertEqual(manifest["schema"], "paintbot-neural-basic/2")
        for schema in ("paintbot-neural-basic/3", "paintbot-neural-basic", None):
            with self.assertRaisesRegex(ValueError, "schema"):
                unpack_package(package({"schema": schema}))

    def test_contract_hashes_are_sha256_of_their_ids(self):
        # neural_contract.nim exports each contract id next to its hash; the hash is the
        # SHA-256 of the id string and is what actors and manifests carry.
        source = (Path(__file__).parents[2] / "examples/paintbot/neural_contract.nim").read_text()
        consts = dict(re.findall(r'^  (\w+)\* = "([^"]*)"', source, re.M))
        pairs = [("ObservationContract", "ObservationContractHash"), ("ActionContract", "ActionContractHash"),
                 ("ActionContractV2", "ActionContractV2Hash"), ("ObservationContractV2", "ObservationContractV2Hash"),
                 ("ObservationContractFfaV1", "ObservationContractFfaV1Hash"),
                 ("ObservationContractV3", "ObservationContractV3Hash")]
        for name, hashed in pairs:
            self.assertEqual(consts[hashed], hashlib.sha256(consts[name].encode()).hexdigest(), name)
        self.assertEqual(consts["ActionContractV2"], "paintbot-pw.rules37.action.v2.51-25-2-2-2")
        self.assertNotEqual(consts["ActionContractHash"], consts["ActionContractV2Hash"])
        self.assertEqual(consts["ObservationContractV2"], "paintbot-pw.rules37.obs.v2.float506")
        self.assertNotEqual(consts["ObservationContractHash"], consts["ObservationContractV2Hash"])

    def test_decoder_options(self):
        schema2 = {"schema": "paintbot-neural-basic/2"}
        _, _, manifest = unpack_package(package({**schema2, "decoder": {"fire_hold_teammates": True}}))
        self.assertEqual(manifest["decoder"], {"fire_hold_teammates": True})
        _, _, manifest = unpack_package(package({**schema2, "decoder": {"fire_hold_teammates": False}}))
        self.assertEqual(manifest["decoder"], {"fire_hold_teammates": False})
        _, _, manifest = unpack_package(package({**schema2, "decoder": {}}))
        self.assertEqual(manifest["decoder"], {})
        with self.assertRaisesRegex(ValueError, "schema 2"):
            unpack_package(package({"decoder": {"fire_hold_teammates": True}}))
        with self.assertRaisesRegex(ValueError, "unknown decoder option"):
            unpack_package(package({**schema2, "decoder": {"fire_hold_teammates": True, "other": 1}}))
        for value in (1, 0, "true", None, [True]):
            with self.assertRaisesRegex(ValueError, "must be a bool"):
                unpack_package(package({**schema2, "decoder": {"fire_hold_teammates": value}}))
        for value in ([True], "fire_hold_teammates", None):
            with self.assertRaisesRegex(ValueError, "must be an object"):
                unpack_package(package({**schema2, "decoder": value}))

    def test_decompression_bound(self):
        out = io.BytesIO()
        with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
            z.writestr("manifest.json", b"{}")
            z.writestr("policy.bas", b"idle=1")
            z.writestr("model.bin", b"x" * (MAX_MODEL_BYTES + 1))
        with self.assertRaisesRegex(ValueError, "oversized"):
            unpack_package(out.getvalue())


    def test_sampling_option(self):
        schema2 = {"schema": "paintbot-neural-basic/2"}
        for sampling in ({"mode": "categorical"},
                         {"mode": "categorical", "temperature": 0.5, "heads": [0, 2]},
                         {"mode": "categorical", "temperature": 10},
                         {"mode": "categorical", "temperature": 0.01, "heads": [4, 3, 2, 1, 0]}):
            _, _, manifest = unpack_package(package({**schema2, "decoder": {"fire_hold_teammates": True, "sampling": sampling}}))
            self.assertEqual(manifest["decoder"]["sampling"], sampling)
        with self.assertRaisesRegex(ValueError, "schema 2"):
            unpack_package(package({"decoder": {"sampling": {"mode": "categorical"}}}))
        for sampling, message in (({}, "mode"), ({"mode": "argmax"}, "mode"), ({"mode": "categorical", "temperature": 0}, "within"),
                                  ({"mode": "categorical", "temperature": 11}, "within"), ({"mode": "categorical", "temperature": "1"}, "number"),
                                  ({"mode": "categorical", "temperature": True}, "number"), ({"mode": "categorical", "heads": []}, "non-empty"),
                                  ({"mode": "categorical", "heads": [5]}, "indices"), ({"mode": "categorical", "heads": [1, 1]}, "repeats"),
                                  ({"mode": "categorical", "heads": "all"}, "non-empty"), ({"mode": "categorical", "heads": [True]}, "indices"),
                                  ({"mode": "categorical", "seed": 1}, "unknown decoder.sampling field"), (True, "must be a dict"), ([], "must be a dict")):
            with self.assertRaisesRegex(ValueError, message, msg=repr(sampling)):
                unpack_package(package({**schema2, "decoder": {"sampling": sampling}}))

    def test_joint_sampling_option(self):
        schema2 = {"schema": "paintbot-neural-basic/2"}
        stand = [1000] + [0] * 50
        for joint in ({"when": {"head": 2, "value": 1}, "head": 0, "offsets": stand},
                      {"when": {"head": 0, "value": 50}, "head": 1, "offsets": [0.5] * 25},
                      {"head": 4, "offsets": [-1000, 1000], "when": {"value": 0, "head": 3}}):
            _, _, manifest = unpack_package(package({**schema2, "decoder": {"joint_sampling": joint}}))
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
                unpack_package(package({**schema2, "decoder": {"joint_sampling": joint}}))

    def test_forbid_objectives_option(self):
        schema2 = {"schema": "paintbot-neural-basic/2"}
        for forbid in ([9, 10], [0], [50, 1], list(range(50))):
            _, _, manifest = unpack_package(package({**schema2, "decoder": {"forbid_objectives": forbid}}))
            self.assertEqual(manifest["decoder"]["forbid_objectives"], forbid)
        with self.assertRaisesRegex(ValueError, "schema 2"):
            unpack_package(package({"decoder": {"forbid_objectives": [9, 10]}}))
        for forbid, message in (([], "non-empty"), ([51], "indices"), ([-1], "indices"), ([9.0], "indices"), ([True], "indices"),
                                (["9"], "indices"), ([9, 9], "repeats"), (list(range(51)), "leave an objective"),
                                ("9,10", "must be a list"), ({"9": 1}, "must be a list")):
            with self.assertRaisesRegex(ValueError, message, msg=repr(forbid)):
                unpack_package(package({**schema2, "decoder": {"forbid_objectives": forbid}}))

    def test_strafe_legs_option(self):
        schema2 = {"schema": "paintbot-neural-basic/2"}
        for strafe in ({}, {"range": 5250, "legs": [3, 6], "shot_legs": [6, 9], "reverse_permille": 800},
                       {"range": 1, "legs": [1, 1], "shot_legs": [6, 6], "reverse_permille": 0},
                       {"range": 20000, "legs": [72, 72], "shot_legs": [72, 72], "reverse_permille": 1000}):
            _, _, manifest = unpack_package(package({**schema2, "decoder": {"forbid_objectives": [9, 10], "strafe_legs": strafe}}))
            self.assertEqual(manifest["decoder"]["strafe_legs"], strafe)
        with self.assertRaisesRegex(ValueError, "schema 2"):
            unpack_package(package({"decoder": {"strafe_legs": {}}}))
        for strafe, message in (({"range": 0}, "range must be within"), ({"range": 20001}, "range must be within"),
                                ({"range": 5250.0}, "integer"), ({"range": True}, "integer"), ({"legs": [0, 6]}, "legs must be"),
                                ({"legs": [7, 6]}, "legs must be"), ({"legs": [3, 73]}, "legs must be"), ({"legs": [3]}, r"\[min, max\]"),
                                ({"legs": "3-6"}, r"\[min, max\]"), ({"legs": [3, 6.0]}, "integer"), ({"shot_legs": [5, 9]}, "shot_legs must be"),
                                ({"shot_legs": [9, 8]}, "shot_legs must be"), ({"reverse_permille": 1001}, "reverse_permille"),
                                ({"reverse_permille": -1}, "reverse_permille"), ({"seed": 1}, "unknown decoder.strafe_legs field"),
                                (True, "must be a dict"), ([], "must be a dict")):
            with self.assertRaisesRegex(ValueError, message, msg=repr(strafe)):
                unpack_package(package({**schema2, "decoder": {"strafe_legs": strafe}}))

    def test_aim_snap_option(self):
        schema2 = {"schema": "paintbot-neural-basic/2"}
        for snap in ({}, {"max_angle_deg": 22.5}, {"max_angle_deg": 30}, {"max_angle_deg": 0.001},
                     {"max_angle_deg": 90}, {"max_angle_deg": 12.345}):
            _, _, manifest = unpack_package(package({**schema2, "decoder": {"aim_snap": snap}}))
            self.assertEqual(manifest["decoder"]["aim_snap"], snap)
        with self.assertRaisesRegex(ValueError, "schema 2"):
            unpack_package(package({"decoder": {"aim_snap": {}}}))
        for snap, message in (({"max_angle_deg": 0}, "multiple of 0.001 within"), ({"max_angle_deg": -5}, "within"),
                              ({"max_angle_deg": 90.001}, "within"), ({"max_angle_deg": 22.5001}, "multiple of 0.001"),
                              ({"max_angle_deg": float("nan")}, "within"), ({"max_angle_deg": 10 ** 400}, "within"),
                              ({"max_angle_deg": "22.5"}, "must be a number"), ({"max_angle_deg": True}, "must be a number"),
                              ({"degrees": 22.5}, "unknown decoder.aim_snap field"), (True, "must be a dict"), ([], "must be a dict")):
            with self.assertRaisesRegex(ValueError, message, msg=repr(snap)):
                unpack_package(package({**schema2, "decoder": {"aim_snap": snap}}))

    def test_steady_shot_option(self):
        schema2 = {"schema": "paintbot-neural-basic/2"}
        for decoder in ({"steady_shot": {}}, {"steady_shot": {}, "forbid_objectives": [9, 10], "aim_snap": {},
                                              "sampling": {"mode": "categorical"}, "strafe_legs": {}, "fire_hold_teammates": True}):
            _, _, manifest = unpack_package(package({**schema2, "decoder": decoder}))
            self.assertEqual(manifest["decoder"], decoder)
        with self.assertRaisesRegex(ValueError, "schema 2"):
            unpack_package(package({"decoder": {"steady_shot": {}}}))
        for steady, message in (({"ticks": 6}, "unknown decoder.steady_shot field"), (True, "must be a dict"), ([], "must be a dict")):
            with self.assertRaisesRegex(ValueError, message, msg=repr(steady)):
                unpack_package(package({**schema2, "decoder": {"steady_shot": steady}}))
        for forbid in ([0], [0, 9, 10], [10, 0]):
            with self.assertRaisesRegex(ValueError, "steady_shot needs movement index 0"):
                unpack_package(package({**schema2, "decoder": {"steady_shot": {}, "forbid_objectives": forbid}}))

    def test_fire_hold_radius_option(self):
        schema2 = {"schema": "paintbot-neural-basic/2"}
        # The boolean form is unchanged; the object form turns the hold on, radius 55 by default.
        self.assertEqual(validate_fire_hold(True), (True, 55))
        self.assertEqual(validate_fire_hold(False), (False, 55))
        self.assertEqual(validate_fire_hold({}), (True, 55))
        self.assertEqual(validate_fire_hold({"radius": 150}), (True, 150))
        for hold in (True, False, {}, {"radius": 150}, {"radius": 1}, {"radius": 2000}, {"radius": 55}):
            _, _, manifest = unpack_package(package({**schema2, "decoder": {"fire_hold_teammates": hold}}))
            self.assertEqual(manifest["decoder"]["fire_hold_teammates"], hold)
        with self.assertRaisesRegex(ValueError, "schema 2"):
            unpack_package(package({"decoder": {"fire_hold_teammates": {"radius": 150}}}))
        for hold, message in (({"radius": 0}, "radius must be within 1 .. 2000"), ({"radius": -150}, "within"),
                              ({"radius": 2001}, "within"), ({"radius": 10 ** 12}, "within"),
                              ({"radius": 150.0}, "radius must be an integer"), ({"radius": "150"}, "must be an integer"),
                              ({"radius": True}, "must be an integer"), ({"radius": None}, "must be an integer"),
                              ({"range": 150}, "unknown decoder.fire_hold_teammates field"),
                              (150, "must be a bool or a dict"), ([150], "must be a bool or a dict"), ("true", "must be a bool")):
            with self.assertRaisesRegex(ValueError, message, msg=repr(hold)):
                unpack_package(package({**schema2, "decoder": {"fire_hold_teammates": hold}}))

    def test_fire_hold_radius_limits_match_the_engine(self):
        source = (Path(__file__).parents[2] / "examples/paintbot/neural_contract.nim").read_text()
        self.assertRegex(source, r"(?m)^  MaxFireHoldRadius\* = 2000'i32$")
        self.assertRegex(source, r"(?m)^static: doAssert FireHoldRadius == 55$")

    def test_spray_options(self):
        schema2 = {"schema": "paintbot-neural-basic/2"}
        # Defaults exact: the spray reach; at least one enemy and no teammate in the cone.
        self.assertEqual(validate_spray_aim({}), {"max_range": 850})
        self.assertEqual(validate_spray_gate({}), {"max_teammates": 0, "min_enemies": 1})
        self.assertEqual(validate_spray_gate({"max_teammates": 2}), {"max_teammates": 2, "min_enemies": 1})
        for name, value in (("spray_aim", {}), ("spray_aim", {"max_range": 1}), ("spray_aim", {"max_range": 850}),
                            ("spray_gate", {}), ("spray_gate", {"max_teammates": 7, "min_enemies": 8}),
                            ("spray_gate", {"max_teammates": 0, "min_enemies": 0})):
            _, _, manifest = unpack_package(package({**schema2, "decoder": {name: value}}))
            self.assertEqual(manifest["decoder"][name], value)
        for name in ("spray_aim", "spray_gate"):
            with self.assertRaisesRegex(ValueError, "schema 2"):
                unpack_package(package({"decoder": {name: {}}}))
        for name, value, message in (("spray_aim", {"max_range": 0}, "max_range must be within 1 .. 850"),
                                     ("spray_aim", {"max_range": 851}, "within"), ("spray_aim", {"max_range": -1}, "within"),
                                     ("spray_aim", {"max_range": 850.0}, "must be an integer"),
                                     ("spray_aim", {"max_range": "850"}, "must be an integer"),
                                     ("spray_aim", {"max_range": True}, "must be an integer"),
                                     ("spray_aim", {"range": 850}, "unknown decoder.spray_aim field"),
                                     ("spray_aim", True, "must be a dict"), ("spray_aim", [], "must be a dict"),
                                     ("spray_gate", {"max_teammates": -1}, "max_teammates must be within 0 .. 7"),
                                     ("spray_gate", {"max_teammates": 8}, "within"),
                                     ("spray_gate", {"min_enemies": 9}, "min_enemies must be within 0 .. 8"),
                                     ("spray_gate", {"min_enemies": -1}, "within"),
                                     ("spray_gate", {"min_enemies": 1.0}, "must be an integer"),
                                     ("spray_gate", {"max_teammates": None}, "must be an integer"),
                                     ("spray_gate", {"teammates": 0}, "unknown decoder.spray_gate field"),
                                     ("spray_gate", 1, "must be a dict")):
            with self.assertRaisesRegex(ValueError, message, msg=repr((name, value))):
                unpack_package(package({**schema2, "decoder": {name: value}}))

    def test_spray_defaults_match_the_engine(self):
        source = (Path(__file__).parents[2] / "examples/paintbot/neural_contract.nim").read_text()
        consts = {name: int(value.replace("_", "")) for name, value in
                  re.findall(r"^  (\w+)\* = ([0-9_]+)'i32", source, re.M)}
        self.assertEqual(SPRAY_AIM_DEFAULTS["max_range"], consts["DefaultSprayAimRange"])
        self.assertEqual(SPRAY_GATE_DEFAULTS, {"max_teammates": consts["DefaultSprayMaxTeammates"],
                                               "min_enemies": consts["DefaultSprayMinEnemies"]})
        self.assertEqual(SPRAY_LIMITS["max_teammates"], (0, consts["MaxSprayTeammates"]))
        self.assertEqual(SPRAY_LIMITS["min_enemies"], (0, consts["MaxSprayEnemies"]))
        mech = (Path(__file__).parents[2] / "examples/paintbot/mechanics.nim").read_text()
        self.assertRegex(mech, r"(?m)^  SprayReach\* = %d$" % SPRAY_LIMITS["max_range"][1])

    def test_aim_retarget_option(self):
        schema2 = {"schema": "paintbot-neural-basic/2"}
        # The defaults are exactly base.bas's rule and pw-diag3's counterfactual.
        self.assertEqual(validate_aim_retarget({}), {"max_range": 5250, "hp_weight": 160000, "carry_weight": 2500000})
        self.assertEqual(validate_aim_retarget({"hp_weight": 0}), {"max_range": 5250, "hp_weight": 0, "carry_weight": 2500000})
        for retarget in ({}, {"max_range": 5250, "hp_weight": 160000, "carry_weight": 2500000}, {"max_range": 1},
                         {"max_range": 20000}, {"hp_weight": 0, "carry_weight": 0},
                         {"hp_weight": 1000000000, "carry_weight": 1000000000}):
            _, _, manifest = unpack_package(package({**schema2, "decoder": {"aim_retarget": retarget}}))
            self.assertEqual(manifest["decoder"]["aim_retarget"], retarget)
        with self.assertRaisesRegex(ValueError, "schema 2"):
            unpack_package(package({"decoder": {"aim_retarget": {}}}))
        for retarget, message in (({"max_range": 0}, "max_range must be within 1 .. 20000"),
                                  ({"max_range": -5250}, "max_range must be within"), ({"max_range": 20001}, "max_range must be within"),
                                  ({"hp_weight": -1}, "hp_weight must be within 0 .. 1000000000"),
                                  ({"hp_weight": 1000000001}, "hp_weight must be within"),
                                  ({"carry_weight": -1}, "carry_weight must be within 0 .. 1000000000"),
                                  ({"carry_weight": 2 ** 40}, "carry_weight must be within"),
                                  ({"max_range": 5250.0}, "max_range must be an integer"), ({"max_range": "5250"}, "must be an integer"),
                                  ({"max_range": True}, "must be an integer"), ({"hp_weight": 1.5}, "hp_weight must be an integer"),
                                  ({"carry_weight": None}, "carry_weight must be an integer"),
                                  ({"range": 5250}, "unknown decoder.aim_retarget field"), (True, "must be a dict"),
                                  ([], "must be a dict"), (5250, "must be a dict")):
            with self.assertRaisesRegex(ValueError, message, msg=repr(retarget)):
                unpack_package(package({**schema2, "decoder": {"aim_retarget": retarget}}))

    def test_shot_gate_option(self):
        schema2 = {"schema": "paintbot-neural-basic/2"}
        self.assertEqual(validate_shot_gate({}), {"max_range": 5250})
        for gate in ({}, {"max_range": 5250}, {"max_range": 1}, {"max_range": 20000}):
            _, _, manifest = unpack_package(package({**schema2, "decoder": {"shot_gate": gate}}))
            self.assertEqual(manifest["decoder"]["shot_gate"], gate)
        with self.assertRaisesRegex(ValueError, "schema 2"):
            unpack_package(package({"decoder": {"shot_gate": {}}}))
        for gate, message in (({"max_range": 0}, "max_range must be within 1 .. 20000"), ({"max_range": -1}, "within"),
                              ({"max_range": 20001}, "within"), ({"max_range": 5250.5}, "must be an integer"),
                              ({"max_range": "5250"}, "must be an integer"), ({"max_range": False}, "must be an integer"),
                              ({"range": 5250}, "unknown decoder.shot_gate field"), (True, "must be a dict"),
                              ([], "must be a dict"), (5250, "must be a dict")):
            with self.assertRaisesRegex(ValueError, message, msg=repr(gate)):
                unpack_package(package({**schema2, "decoder": {"shot_gate": gate}}))
        # The full lever set pw-diag3 measured, together.
        decoder = {"fire_hold_teammates": True, "sampling": {"mode": "categorical"}, "forbid_objectives": [9, 10],
                   "aim_snap": {"max_angle_deg": 22.5}, "steady_shot": {}, "strafe_legs": {}, "aim_retarget": {},
                   "shot_gate": {"max_range": 5250}}
        _, _, manifest = unpack_package(package({**schema2, "decoder": decoder}))
        self.assertEqual(manifest["decoder"], decoder)

    def test_retarget_and_gate_defaults_match_the_engine(self):
        # neural_contract.nim holds the host's defaults and limits; the packager must agree.
        source = (Path(__file__).parents[2] / "examples/paintbot/neural_contract.nim").read_text()
        consts = {name: int(value.replace("_", "")) for name, value in
                  re.findall(r"^  (\w+)\* = ([0-9_]+)'i32", source, re.M)}
        self.assertEqual(AIM_RETARGET_DEFAULTS, {"max_range": consts["DefaultRetargetRange"],
                                                 "hp_weight": consts["DefaultRetargetHpWeight"],
                                                 "carry_weight": consts["DefaultRetargetCarryWeight"]})
        self.assertEqual((MAX_RETARGET_RANGE, MAX_RETARGET_WEIGHT), (consts["MaxRetargetRange"], consts["MaxRetargetWeight"]))
        self.assertEqual(SHOT_GATE_DEFAULTS, {"max_range": consts["DefaultShotGateRange"]})
        self.assertEqual(MAX_SHOT_GATE_RANGE, consts["MaxShotGateRange"])


class UserInputTests(unittest.TestCase):
    def inputs_package(self, k=3, init=None, observation=None, inputs=None, schema="paintbot-neural-basic/2",
                       user_inputs="default"):
        observation = observation or v2u_hash(k)
        model = actor_bytes(OBSERVATION_V2_SIZE + k if inputs is None else inputs, observation)
        overrides = {"schema": schema, "observation_contract": observation}
        if user_inputs == "default":
            overrides["user_inputs"] = {"count": k, "init": init if init is not None else [0] * k}
        elif user_inputs is not None:
            overrides["user_inputs"] = user_inputs
        return package(overrides, model=model)

    def test_valid_user_inputs(self):
        for k in (1, 3, 32, 33, 34, MAX_USER_INPUTS):
            _, _, manifest = unpack_package(self.inputs_package(k, init=[USER_INPUT_LIMIT] + [-USER_INPUT_LIMIT] * (k - 1)))
            self.assertEqual(manifest["user_inputs"]["count"], k)

    def test_user_inputs_field_rules(self):
        for value, message in (([], "must be an object"), ({"init": []}, "count is required"),
                               ({"count": 0, "init": []}, "within 1 .. 64"), ({"count": 65, "init": [0] * 65}, "within 1 .. 64"),
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
        with self.assertRaisesRegex(ValueError, "need observation contract v2u"):
            unpack_package(self.inputs_package(observation="a" * 64))
        with self.assertRaisesRegex(ValueError, "v2u3 needs manifest user_inputs"):
            unpack_package(self.inputs_package(3, user_inputs=None))
        with self.assertRaisesRegex(ValueError, "does not match observation contract v2u3"):
            unpack_package(self.inputs_package(3, user_inputs={"count": 2, "init": [0, 0]}))

    def test_user_inputs_check_the_actor_input_count_and_contract(self):
        with self.assertRaisesRegex(ValueError, "input count must be 509 for 3 user inputs"):
            unpack_package(self.inputs_package(3, inputs=OBSERVATION_V2_SIZE))
        observation = v2u_hash(3)
        model = actor_bytes(OBSERVATION_V2_SIZE + 3, v2u_hash(2))
        with self.assertRaisesRegex(ValueError, "package and actor contract mismatch"):
            unpack_package(package({"schema": "paintbot-neural-basic/2", "observation_contract": observation,
                                    "user_inputs": {"count": 3, "init": [0, 0, 0]}}, model=model))
        with self.assertRaisesRegex(ValueError, "invalid neural actor magic"):
            unpack_package(package({"schema": "paintbot-neural-basic/2", "observation_contract": observation,
                                    "user_inputs": {"count": 3, "init": [0, 0, 0]}}))

    def test_user_inputs_contract_ids_match_the_engine(self):
        # neural_contract.nim lists the v2u<K> hashes; each is the SHA-256 of its id.
        source = (Path(__file__).parents[2] / "examples/paintbot/neural_contract.nim").read_text()
        block = source[source.index("UserInputsContractHashes*"):]
        block = block[block.index("= ["):]
        hashes = re.findall(r'"([0-9a-f]{64})"', block[:block.index("]")])
        self.assertEqual(hashes, [v2u_hash(k) for k in range(1, MAX_USER_INPUTS + 1)])
        self.assertIn('"paintbot-pw.rules39.obs.v2u" & $k', source)
        consts = {name: int(value.replace("_", "")) for name, value in
                  re.findall(r"^  (\w+)\* = ([0-9_]+)(?:'i32)?$", source, re.M)}
        self.assertEqual((MAX_USER_INPUTS, USER_INPUT_LIMIT), (consts["MaxUserInputs"], consts["UserInputLimit"]))

    def test_user_input_cap_is_64_and_the_original_32_contracts_are_unchanged(self):
        # Raising the cap from 32 to 64 appends v2u33 .. v2u64; v2u1 .. v2u32 keep their hashes (pinned here),
        # so every existing K <= 32 bundle stages exactly as before.
        self.assertEqual(MAX_USER_INPUTS, 64)
        self.assertEqual(v2u_hash(1), "bd80f4d35088c1f5e673e9b91d16df826e1cfb0e590185dbf4d8bf59af0bdb04")
        self.assertEqual(hashlib.sha256("".join(v2u_hash(k) for k in range(1, 33)).encode()).hexdigest(),
                         "3e49fd8df675ca9c5b21ccb81e3ef3ca78767fab6de847672a3775bec03f9fda")
        self.assertEqual(v2u_hash(64), "18a5141bf7d78fdf93524757bf261f367cfebe3b489fb6f2988936375bb8f4aa")
        self.assertEqual(sorted(USER_INPUTS_CONTRACT_HASHES.values()), list(range(1, 65)))
        self.assertEqual(USER_INPUTS_CONTRACT_HASHES[v2u_hash(34)], 34)
        self.assertNotIn(hashlib.sha256(user_inputs_contract_id(65).encode()).hexdigest(), USER_INPUTS_CONTRACT_HASHES)
        with self.assertRaisesRegex(ValueError, "within 1 .. 64"):
            unpack_package(self.inputs_package(65))
        with self.assertRaisesRegex(ValueError, "need observation contract v2u"):
            unpack_package(self.inputs_package(64, observation=hashlib.sha256(user_inputs_contract_id(65).encode()).hexdigest()))

    def test_packages_without_user_inputs_are_unaffected(self):
        # (v3, which checks its actor at staging, is in ObservationV3Tests.)
        # An ordinary contract hash with the model never parsed, exactly as before.
        _, model, _ = unpack_package(package({"schema": "paintbot-neural-basic/2"}))
        self.assertEqual(model, b"neutral fixture")
OBS, ACT = "a" * 64, "b" * 64


def pwnet2(inputs, heads, layers, obs=OBS, act=ACT):
    """layers = [(type, [params], [extra u32], n_floats)] with deterministic small weights."""
    out = b"PWNET002" + struct.pack("<4I", 2, inputs, sum(heads), len(heads)) + struct.pack("<%dI" % len(heads), *heads)
    out += obs.encode() + act.encode() + struct.pack("<I", len(layers))
    rng = random.Random(1)
    for code, params, extra, floats in layers:
        out += struct.pack("<9I", code, *(list(params) + [0] * (8 - len(params))))
        out += struct.pack("<%dI" % len(extra), *extra)
        out += struct.pack("<%df" % floats, *(rng.uniform(-0.1, 0.1) for _ in range(floats)))
    return out


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
        model = self.example()
        overrides = {"sha256": {"policy.bas": hashlib.sha256(b"idle = 1\n").hexdigest(),
                                "model.bin": hashlib.sha256(model).hexdigest()}}
        self.assertEqual(unpack_package(package(overrides, model=model))[1], model)
        other = {"observation_contract": "c" * 64, **overrides}
        with self.assertRaisesRegex(ValueError, "contract mismatch"):
            unpack_package(package(other, model=model))
        big = pwnet2(506, [51, 25, 2, 2, 2], [
            attn([(24, 8, 10, 8, 0), (104, 8, 16, 8, 0), (232, 5, 32, 5, 0)], 128, 4, 2, 256, 0, 24),
            (1, [280, 82], [], 280 * 82)])
        big_overrides = {"sha256": {"policy.bas": hashlib.sha256(b"idle = 1\n").hexdigest(),
                                    "model.bin": hashlib.sha256(big).hexdigest()}}
        with self.assertRaisesRegex(ValueError, "exceeds native operation budget"):
            unpack_package(package(big_overrides, model=big))
        # Non-PWNET002 models are left to the host loader, exactly as before.
        self.assertEqual(unpack_package(package())[1], b"neutral fixture")

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
            (pwnet2(64, heads, [attn([(0, 1, 60, 4, 0), (0, 1, 10, 4, 0)], 8, 2, 1, 8, 0, 0), (1, [16, 6], [], 96)]),
             "tokens"),
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
        # neural_actor.md's entity-factored example over v2u32: 1,327,278 operations (test_paintbot_neural_net2).
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
            ([mlp, (8, [0, 4], [], 64), (1, [18, 9, 1], [], 171), (9, [0, 3], [], 5)], "earlier TOKEN_MIX"),
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
            ([self.near(0)], "SEGMENT_NEAR tokens must be 1..64"),
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
            validate_pwnet2(pwnet2(600, [300, 300], [self.near(65)]))
        good = pwnet2(40, heads, [self.near()])
        with self.assertRaisesRegex(ValueError, "truncated"):
            validate_pwnet2(good[:-4])
        with self.assertRaisesRegex(ValueError, "trailing bytes"):
            validate_pwnet2(good + bytes(4))

    def test_pwnet002_with_user_inputs(self):
        # A PWNET002 actor with obs contract v2u<K> (506 + K inputs): the header is read through validate_pwnet2 and
        # the op count includes the K extra inputs.
        k = 3
        heads = [51, 25, 2, 2, 2]

        def bundle(model, count=k, observation=None):
            observation = observation or v2u_hash(k)
            return package({"schema": "paintbot-neural-basic/2", "observation_contract": observation, "action_contract": ACT,
                            "user_inputs": {"count": count, "init": [0] * count},
                            "sha256": {"policy.bas": hashlib.sha256(b"idle = 1\n").hexdigest(),
                                       "model.bin": hashlib.sha256(model).hexdigest()}}, model=model)

        model = pwnet2(OBSERVATION_V2_SIZE + k, heads, [(6, [0, 24], [], 0), (1, [OBSERVATION_V2_SIZE + k + 24, 82], [],
                                                         (OBSERVATION_V2_SIZE + k + 24) * 82)], obs=v2u_hash(k))
        self.assertEqual(unpack_package(bundle(model))[1], model)
        self.assertEqual(validate_pwnet2(model)["operations"], 24 + 2 * (OBSERVATION_V2_SIZE + k + 24) * 82)
        short = pwnet2(OBSERVATION_V2_SIZE, heads, [(1, [OBSERVATION_V2_SIZE, 82], [], OBSERVATION_V2_SIZE * 82)],
                       obs=v2u_hash(k))
        with self.assertRaisesRegex(ValueError, "input count must be 509 for 3 user inputs"):
            unpack_package(bundle(short))
        other = pwnet2(OBSERVATION_V2_SIZE + k, heads, [(1, [OBSERVATION_V2_SIZE + k, 82], [], (OBSERVATION_V2_SIZE + k) * 82)],
                       obs=v2u_hash(2))
        with self.assertRaisesRegex(ValueError, "package and actor contract mismatch"):
            unpack_package(bundle(other))
        with self.assertRaisesRegex(ValueError, "does not match observation contract v2u3"):
            unpack_package(bundle(model, count=2))

    def test_constants_match_the_engine(self):
        source = (Path(__file__).parents[2] / "examples/paintbot/neural_actor.nim").read_text()
        consts = {m.group(1): int(m.group(2).replace("_", ""))
                  for m in re.finditer(r"^\s+(Max\w+|TranscendentalOps|MinGruUnitOps)\* = ([0-9_]+)", source, re.M)}
        self.assertEqual(PWNET2_LIMITS, dict(parameters=consts["MaxNet2Parameters"], layers=consts["MaxNet2Layers"],
                                             width=consts["MaxNet2Width"], state=consts["MaxNet2State"],
                                             mingru_hidden=consts["MaxMinGruHidden"], groups=consts["MaxAttnGroups"],
                                             tokens=consts["MaxAttnTokens"], d_model=consts["MaxAttnModel"],
                                             blocks=consts["MaxAttnBlocks"], ff=consts["MaxAttnFeedForward"],
                                             token_segments=consts["MaxTokenSegments"],
                                             token_input=consts["MaxTokenInput"], token_model=consts["MaxTokenModel"],
                                             token_mlp_layers=consts["MaxTokenMlpLayers"]))
        self.assertEqual((consts["TranscendentalOps"], consts["MinGruUnitOps"]), (8, 32))
        # SEGMENT_NEAR's published count: one formula in the loader, staging and neural_actor.md.
        self.assertIn("int64(inputs) + int64(tokens)*int64(tokens)*12 + int64(tokens)*8", source)
        self.assertIn("| SEGMENT_NEAR | `I + 12*T*T + 8*T` |",
                      (Path(__file__).parents[2] / "examples/paintbot/neural_actor.md").read_text())
        self.assertEqual(segment_near_ops(538, 16), 538 + 12 * 16 * 16 + 8 * 16)
        host = (Path(__file__).parents[2] / "examples/paintbot/neural_host.nim").read_text()
        self.assertIn("MaxNeuralOperations* = %s'i64" % format(MAX_NEURAL_OPERATIONS, "_"), host)


if __name__ == "__main__":
    unittest.main()


class ObservationV3Tests(unittest.TestCase):
    """Observation contract v3 (v2 + an 8-float scoreboard) and v3u<K>; neural_host.nim holds the same rules."""

    def v3_package(self, observation=None, inputs=OBSERVATION_V3_SIZE, actor_observation=None, user_inputs=None,
                   schema="paintbot-neural-basic/2"):
        observation = observation or OBSERVATION_CONTRACT_V3_HASH
        overrides = {"schema": schema, "observation_contract": observation}
        if user_inputs is not None:
            overrides["user_inputs"] = user_inputs
        return package(overrides, model=actor_bytes(inputs, actor_observation or observation))

    def test_contract_id_hash_and_width_match_the_engine(self):
        source = (Path(__file__).parents[2] / "examples/paintbot/neural_contract.nim").read_text()
        consts = dict(re.findall(r'^  (\w+)\* = "([^"]*)"', source, re.M))
        self.assertEqual(consts["ObservationContractV3"], OBSERVATION_CONTRACT_V3)
        self.assertEqual(consts["ObservationContractV3Hash"], OBSERVATION_CONTRACT_V3_HASH)
        self.assertEqual(OBSERVATION_CONTRACT_V3, "paintbot-pw.rules43.obs.v3.float514")
        self.assertEqual(OBSERVATION_CONTRACT_V3_HASH, "06f16d62adedda6995d393696c0d2ed257aa9380b86341e73d1d6a3c7ea374f1")
        self.assertEqual(OBSERVATION_V3_SIZE, OBSERVATION_V2_SIZE + 8)
        sizes = {name: int(value) for name, value in re.findall(r"^  (\w+)\* = (\d+)$", source, re.M)}
        self.assertEqual(sizes["ScoreboardBlockSize"], 8)
        # The v3u<K> table: each hash is the SHA-256 of its id, and none is a v2u<K> hash.
        block = source[source.index("V3UserInputsContractHashes*"):]
        block = block[block.index("= ["):]
        hashes = re.findall(r'"([0-9a-f]{64})"', block[:block.index("]")])
        self.assertEqual(hashes, [v3u_hash(k) for k in range(1, MAX_USER_INPUTS + 1)])
        self.assertIn('"paintbot-pw.rules43.obs.v3u" & $k', source)
        self.assertEqual(sorted(V3_USER_INPUTS_CONTRACT_HASHES.values()), list(range(1, 65)))
        self.assertFalse(set(V3_USER_INPUTS_CONTRACT_HASHES) & set(USER_INPUTS_CONTRACT_HASHES))
        self.assertEqual(v3u_hash(1), "8086b6f36b9c2cf07e9e6586e97221e484f809e08669075663c5dcf9cb63ac36")

    def test_v3_accepted_with_a_514_input_actor(self):
        for schema in ("paintbot-neural-basic/1", "paintbot-neural-basic/2"):
            _, model, manifest = unpack_package(self.v3_package(schema=schema))
            self.assertEqual(manifest["observation_contract"], OBSERVATION_CONTRACT_V3_HASH)
            self.assertEqual(int.from_bytes(model[12:16], "little"), 514)

    def test_v3_rejects_a_wrong_actor(self):
        with self.assertRaisesRegex(ValueError, "input count must be 514 for observation contract v3"):
            unpack_package(self.v3_package(inputs=OBSERVATION_V2_SIZE))
        with self.assertRaisesRegex(ValueError, "package and actor contract mismatch"):
            unpack_package(self.v3_package(actor_observation=hashlib.sha256(b"paintbot-pw.rules37.obs.v2.float506").hexdigest()))
        with self.assertRaisesRegex(ValueError, "invalid neural actor magic"):
            unpack_package(package({"observation_contract": OBSERVATION_CONTRACT_V3_HASH}))
        with self.assertRaisesRegex(ValueError, "user_inputs need observation contract v2u<K> or v3u<K>"):
            unpack_package(self.v3_package(user_inputs={"count": 1, "init": [0]}))

    def test_v3u_accepted_for_every_k(self):
        for k in (1, 3, 32, 63, 64):
            _, _, manifest = unpack_package(self.v3_package(observation=v3u_hash(k), inputs=OBSERVATION_V3_SIZE + k,
                                                            user_inputs={"count": k, "init": [7] * k}))
            self.assertEqual(manifest["user_inputs"]["count"], k)

    def test_v3u_rules_mirror_v2u(self):
        with self.assertRaisesRegex(ValueError, "observation contract v3u3 needs manifest user_inputs"):
            unpack_package(self.v3_package(observation=v3u_hash(3), inputs=517))
        with self.assertRaisesRegex(ValueError, "does not match observation contract v3u3"):
            unpack_package(self.v3_package(observation=v3u_hash(3), inputs=517, user_inputs={"count": 2, "init": [0, 0]}))
        with self.assertRaisesRegex(ValueError, "input count must be 517 for 3 user inputs"):
            unpack_package(self.v3_package(observation=v3u_hash(3), inputs=OBSERVATION_V2_SIZE + 3,
                                           user_inputs={"count": 3, "init": [0, 0, 0]}))
        with self.assertRaisesRegex(ValueError, "package and actor contract mismatch"):
            unpack_package(self.v3_package(observation=v3u_hash(3), inputs=517, actor_observation=v2u_hash(3),
                                           user_inputs={"count": 3, "init": [0, 0, 0]}))
        with self.assertRaisesRegex(ValueError, "need package schema 2"):
            unpack_package(self.v3_package(observation=v3u_hash(3), inputs=517, schema="paintbot-neural-basic/1",
                                           user_inputs={"count": 3, "init": [0, 0, 0]}))
        # v2u<K> keeps v2's width: a v2u3 manifest over a 517-input actor is refused as before.
        with self.assertRaisesRegex(ValueError, "input count must be 509 for 3 user inputs"):
            unpack_package(self.v3_package(observation=v2u_hash(3), inputs=517, user_inputs={"count": 3, "init": [0, 0, 0]}))

