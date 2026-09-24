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
                            AIM_RETARGET_DEFAULTS, MAX_RETARGET_RANGE, MAX_RETARGET_WEIGHT, SHOT_GATE_DEFAULTS,
                            MAX_SHOT_GATE_RANGE)


def package(overrides=None, extra=None):
    source, model = b"idle = 1\n", b"neutral fixture"
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


if __name__ == "__main__":
    unittest.main()
