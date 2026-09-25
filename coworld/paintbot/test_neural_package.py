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
                            MAX_NEURAL_OPERATIONS, PWNET2_LIMITS)
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
                 ("ActionContractV2", "ActionContractV2Hash"), ("ObservationContractV2", "ObservationContractV2Hash")]
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
        for k in (1, 3, MAX_USER_INPUTS):
            _, _, manifest = unpack_package(self.inputs_package(k, init=[USER_INPUT_LIMIT] + [-USER_INPUT_LIMIT] * (k - 1)))
            self.assertEqual(manifest["user_inputs"]["count"], k)

    def test_user_inputs_field_rules(self):
        for value, message in (([], "must be an object"), ({"init": []}, "count is required"),
                               ({"count": 0, "init": []}, "within 1 .. 32"), ({"count": 33, "init": [0] * 33}, "within 1 .. 32"),
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

    def test_packages_without_user_inputs_are_unaffected(self):
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
            (pwnet2(64, heads, [(9, [], [], 0)]), "unknown layer type"),
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
                                             blocks=consts["MaxAttnBlocks"], ff=consts["MaxAttnFeedForward"]))
        self.assertEqual((consts["TranscendentalOps"], consts["MinGruUnitOps"]), (8, 32))
        host = (Path(__file__).parents[2] / "examples/paintbot/neural_host.nim").read_text()
        self.assertIn("MaxNeuralOperations* = %s'i64" % format(MAX_NEURAL_OPERATIONS, "_"), host)


if __name__ == "__main__":
    unittest.main()
