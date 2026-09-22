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
from neural_package import unpack_package, MAX_MODEL_BYTES


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
                 ("ActionContractV2", "ActionContractV2Hash")]
        for name, hashed in pairs:
            self.assertEqual(consts[hashed], hashlib.sha256(consts[name].encode()).hexdigest(), name)
        self.assertEqual(consts["ActionContractV2"], "paintbot-pw.rules37.action.v2.51-25-2-2-2")
        self.assertNotEqual(consts["ActionContractHash"], consts["ActionContractV2Hash"])

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


if __name__ == "__main__":
    unittest.main()
