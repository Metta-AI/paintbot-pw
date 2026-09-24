"""Exercise the JSONL bridge against the real native Paintbot simulator."""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class TrainingBridgeTest(unittest.TestCase):
    def test_complete_native_episode_and_factorized_actions(self):
        with tempfile.TemporaryDirectory(prefix="paintbot-training-test-") as directory:
            suffix = ".dylib" if sys.platform == "darwin" else ".so"
            library = Path(directory) / f"paintbot{suffix}"
            subprocess.run(
                [
                    "nim", "c", "--app:lib", "--mm:arc", "--threads:on", "-d:pwTraining", "-d:headless",
                    f"-o:{library}", "examples/paintbot/native_env.nim",
                ],
                cwd=ROOT, check=True, capture_output=True, text=True,
            )
            action = {name: 0 for name in ("move", "aim", "fire", "grenade", "sneak")}
            commands = [
                {"kind": "reset", "seed": "bridge-smoke", "players": 16},
                {"kind": "encode"},
                {"kind": "step", "decision_id": 1, "response": json.dumps({**action, "move": 51})},
                *(
                    {"kind": "step", "decision_id": tick, "response": json.dumps(action)}
                    for tick in range(1, 65)
                ),
            ]
            result = subprocess.run(
                [sys.executable, str(ROOT / "coworld/paintbot/tools/training_bridge.py"),
                 "--library", str(library), "--ticks", "64"],
                input="\n".join(json.dumps(command) for command in commands) + "\n",
                cwd=ROOT, check=True, capture_output=True, text=True,
            )
            responses = [json.loads(line) for line in result.stdout.splitlines()]
            self.assertEqual(len(responses), len(commands))
            self.assertEqual(responses[0]["kind"], "decision")
            self.assertEqual(len(responses[0]["semantic_view"]["values"]), 506)
            self.assertEqual([len(head["choices"]) for head in responses[1]["action_heads"]], [51, 25, 2, 2, 2])
            self.assertEqual(responses[2]["kind"], "rejected")
            self.assertEqual(responses[3]["observation"]["decision_id"], 2)
            self.assertEqual(responses[-1]["observation"]["kind"], "terminal")
            self.assertEqual(set(responses[-1]["observation"]["scores"]), {str(slot) for slot in range(16)})


if __name__ == "__main__":
    unittest.main()
