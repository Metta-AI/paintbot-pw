"""Smoke tests for the Heartland kinship eval tooling (tools/kin_eval.py, tools/kin_replay_stats.py,
tools/kin_replay_counters.nim, coworld/paintbot/players/ffa_blind.bas).

Builds the training library and the replay tool into a temporary directory, runs every eval suite
with 2 short episodes, a synthetic neural bundle through the genes_only suite, and checks that the
counters recomputed from a recorded replay equal the counters of the same match played live.

    python tools/test_kin_eval.py
"""

import array
import json
import random
import re
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import kin_eval  # noqa: E402
import kin_replay_stats  # noqa: E402
import make_ffa_blind  # noqa: E402

PLAYERS = ROOT / "coworld/paintbot/players"
ACTION_CONTRACT_V2 = "51f602ef167919ca825595f9d81777cb807afbb0938a20102457d0594e2b4317"
ACTION_SIZES = (51, 25, 2, 2, 2)
TICKS = "400"


def nim(*args):
    subprocess.run(["nim", "c", "--mm:arc", "--threads:on", "-d:pwTraining", "-d:headless", "-d:release",
                    "--hints:off", *args], cwd=ROOT, check=True, capture_output=True, text=True)


def synthetic_bundle(path: Path, obs_hash: str) -> None:
    """A PWNET001 actor (hidden 64, seeded random weights) for ffa.v1 with the standard policy.bas."""
    rng = random.Random(7)
    inputs, hidden, outputs = 810, 64, sum(ACTION_SIZES)
    n = inputs * hidden + 3 * hidden * hidden + outputs * hidden
    model = bytearray(b"PWNET001")
    model += struct.pack("<6I", 1, inputs, hidden, outputs, len(ACTION_SIZES), n)
    model += obs_hash.encode() + ACTION_CONTRACT_V2.encode()
    model += struct.pack(f"<{len(ACTION_SIZES)}I", *ACTION_SIZES)
    weights = []
    for i in range(n):
        scale = 0.08 if i < inputs * hidden else (0.15 if i < inputs * hidden + 3 * hidden * hidden else 0.6)
        weights.append((rng.random() * 2 - 1) * scale)
    model += struct.pack(f"<{n}f", *weights)
    policy = (b"paintbot_observe(neuralObservation())\n"
              b"run_neural_net(neuralModel(), neuralObservation(), neuralLogits(), neuralState())\n"
              b"paintbot_act(neuralLogits())\n")
    manifest = {"schema": "paintbot-neural-basic/1", "observation_contract": obs_hash,
                "action_contract": ACTION_CONTRACT_V2, "sha256": {}}
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("manifest.json", json.dumps(manifest))
        z.writestr("policy.bas", policy)
        z.writestr("model.bin", bytes(model))


class KinEvalTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix="kin-eval-test-")
        cls.dir = Path(cls.tmp.name)
        suffix = ".dylib" if sys.platform == "darwin" else ".so"
        cls.lib = cls.dir / f"libpaintbot_pw{suffix}"
        cls.tool = cls.dir / "kin-replay-counters"
        nim("--app:lib", f"-o:{cls.lib}", "examples/paintbot/native_env.nim")
        nim(f"-o:{cls.tool}", "tools/kin_replay_counters.nim")

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_blind_is_ffa_with_kin_blinded(self):
        self.assertEqual(subprocess.run([sys.executable, "tools/make_ffa_blind.py", "--check"], cwd=ROOT).returncode, 0,
                         "ffa_blind.bas is stale: run python tools/make_ffa_blind.py")
        ffa = (PLAYERS / "ffa.bas").read_text()
        blind = (PLAYERS / "ffa_blind.bas").read_text()
        self.assertTrue(blind.startswith(make_ffa_blind.HEADER))
        body = blind[len(make_ffa_blind.HEADER):]
        self.assertIsNone(re.search(r"(?<![A-Za-z0-9_])kin\(", body), "a kin( call survived the blinding")
        self.assertEqual(body.count("blindKin(selfId) = 100\n"), 1)
        # Undo exactly the blinding and nothing else: the rest of the program is ffa.bas byte for byte.
        body = body.replace("dim blindKin(16)\n", "", 1).replace("  blindKin(selfId) = 100\n", "", 1)
        self.assertEqual(body.replace("blindKin(", "kin("), ffa)

    def run_eval(self, *argv):
        out = self.dir / ("out-" + "-".join(a.strip("-").replace("/", "_") for a in argv)[:60])
        results = kin_eval.main([*argv, "--episodes", "2", "--ticks", TICKS, "--workers", "2", "--bootstrap", "100",
                                 "--lib", str(self.lib), "--out", str(out)])
        page = (out / "report.html").read_text()
        self.assertNotIn("<script", page)
        self.assertNotIn("<link", page)
        self.assertNotIn("http://", page.replace("http://www.w3.org", ""))
        self.assertEqual(json.loads((out / "results.json").read_text())["meta"]["episodes"], 2)
        return results, page

    def test_every_suite_runs(self):
        results, page = self.run_eval("--suite", "all", "--policy", str(PLAYERS / "ffa.bas"),
                                      "--policy2", str(PLAYERS / "base.bas"))
        self.assertEqual(list(results), kin_eval.SUITES)
        for suite, res in results.items():
            self.assertNotIn("seat_failures", res, suite)
        inc = results["incentive"]
        self.assertEqual(set(inc["mixed"]), {"fours", "pairs"})
        self.assertEqual(set(inc["welfare"]), {"clones", "fours", "pairs", "strangers"})
        self.assertIn(inc["gate"]["pass"], (True, False))
        ham = results["hamilton"]
        for m in kin_eval.HEADLINE:
            self.assertIn("slope", ham["curve"][m])  # within-layout (headline)
            self.assertIn("slope_pooled", ham["curve"][m])
            self.assertIn("slope", ham["per_layout"]["cousins"][m])
        for b in ham["curve"]["yield"]["by"].values():
            if b["value"] is not None:
                self.assertTrue(0 <= b["value"] <= 1)
        self.assertIn("welfare_clone_minus_stranger", inc)
        self.assertIn("dropped", results["rsweep"]["dose_slope"]["harm"])
        self.assertIn("kin recognition pays", page)
        self.assertEqual(ham["episodes"], 12)
        self.assertIn("control_strangers", ham)
        self.assertIn("control_clones", ham)
        self.assertIn("confounded", page)
        self.assertEqual(results["rsweep"]["levels"], [0, 8, 16, 32])
        self.assertIn("skipped", results["genes_only"])  # BASIC policy: neural only
        self.assertFalse(results["selfish"]["no_control"])
        self.assertEqual(set(results["health"]["per_layout"]), set(kin_eval.ALL_LAYOUTS))
        self.assertIn("collusion_alarm", results["health"]["per_layout"]["fours"])
        self.assertIn("hazard", results["gini"])
        self.assertIn("same", json.dumps(results["crossplay"]["main"]))
        self.assertIn("defend_weak_minus_full", results["gap"])
        self.assertEqual(results["heldout"]["layouts"], ["cousins"])

    def test_selfish_without_control(self):
        results, page = self.run_eval("--suite", "selfish")
        self.assertTrue(results["selfish"]["no_control"])
        self.assertIn("No control", page)

    def test_neural_genes_only(self):
        buf = kin_eval.ctypes.create_string_buffer(65)
        kin_eval.load_lib(self.lib).pw_observation_contract_hash(kin_eval.OBS_FFA, buf, 65)
        bundle = self.dir / "synthetic.zip"
        synthetic_bundle(bundle, buf.value.decode())
        results, _ = self.run_eval("--suite", "genes_only,hamilton", "--policy", str(bundle), "--layouts", "fours")
        for suite in ("genes_only", "hamilton"):
            self.assertEqual(results[suite]["episodes"], 2, suite)
            self.assertNotIn("seat_failures", results[suite])
            self.assertIn("curve", results[suite])

    def test_replay_counters_equal_live_counters(self):
        replay = self.dir / "match.replay"
        subprocess.run([str(self.tool), "--record", str(replay), "--bot", str(PLAYERS / "ffa.bas"),
                        "--bot", str(PLAYERS / "base.bas"), "--ticks", TICKS, "--layout", "0", "--seed", "77"],
                       check=True, capture_output=True)
        row = json.loads(subprocess.run([str(self.tool), str(replay)], check=True, capture_output=True,
                                        text=True).stdout)
        self.assertNotIn("error", row)
        kin_eval._worker_init(str(self.lib))
        policies = {"a": kin_eval.policy_spec(PLAYERS / "ffa.bas"), "b": kin_eval.policy_spec(PLAYERS / "base.bas")}
        live = kin_eval.run_episode(dict(suite="x", cond={}, seed=77, ticks=int(TICKS), policies=policies,
                                         layout="fours", assign=["a"] * 8 + ["b"] * 8))
        pairs = array.array("i")
        pairs.frombytes(live["pairs"])
        self.assertGreater(sum(pairs), 0)
        self.assertEqual(list(pairs), row["pairs"])
        self.assertEqual([round(x, 2) for x in live["R"]], [round(x, 2) for x in row["scores"]])
        out = self.dir / "league"
        res = kin_replay_stats.main([str(replay), "--tool", str(self.tool), "--out", str(out), "--bootstrap", "100"])
        self.assertEqual(res["episodes"], 1)
        self.assertEqual(set(res["per_policy"]), {"ffa.bas", "base.bas"})
        self.assertIn("curve", res["hamilton"])
        self.assertTrue((out / "report.html").exists())


if __name__ == "__main__":
    unittest.main()
