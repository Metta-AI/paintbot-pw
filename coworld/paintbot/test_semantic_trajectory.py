"""The Jev journal join keeps private choices and policy overrides distinct."""

import json
import os
from pathlib import Path
import tempfile
import unittest

from tools.export_semantic_trajectory import export


class SemanticTrajectoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.questions = {"objective": {"type": "choice", "criteria": {
            "C0": {"text": "Capture heart zero"}, "C1": {"text": "Capture heart one"},
            "current": {"text": "Keep current objective"},
        }}}
        self.roster = []
        for slot in range(16):
            path = self.root / f"player-{slot}.log"
            path.write_text("")
            self.roster.append({"slot": slot, "log_uri": path.as_uri(), "content_hash": "sha256:" + "a" * 64})
        (self.root / "seats.json").write_text(json.dumps({"seats": self.roster}))
        (self.root / "results.json").write_text(json.dumps({"scores": [0] * 16, "ticks": 100, "outcome": "draw"}))

    def journal(self, slot, *, raw=0, answer=True, effect=True, applied=1, explored=0, ansobj=None, failure=False):
        if ansobj is None:
            ansobj = raw
        lines = [
            "oracle-q h=abc " + json.dumps(self.questions),
            'oracle-ask id=1 t=10 q=abc {"me.current_objective_heart":-1}',
            f"ask t=10 id=1 squad=1 self=0 cand=2 ret=0 seat={slot}",
        ]
        if answer:
            lines.append('oracle-ans id=1 t=12 status=1 ' + json.dumps({"objective": {"v": raw, "c": 700, "p": {"C0": 500, "C1": 200, "current": 300}}}))
        if effect:
            lines.append(f"ans t=12 id=1 obj=0 guard=-1 ansobj={ansobj} rawobj={raw} n=3 ret=-1 plose=-1 dial=1 fresh=1 greedy={raw} explored={explored} applied={applied} conf=-1")
        if failure:
            lines.append("fail t=12 id=1")
        self.root.joinpath(f"player-{slot}.log").write_text("\n".join(lines) + "\n")

    def exported(self):
        output = self.root / "episode.jsonl"
        result = export(self.root / "seats.json", self.root / "results.json", output, "episode-1", "a" * 40)
        self.assertEqual(os.stat(output).st_mode & 0o777, 0o600)
        self.assertEqual(json.loads(output.read_text()), result)
        return result

    def test_accepted_override_current_and_failed_request(self):
        self.journal(0)
        self.journal(1, raw=1, ansobj=0, applied=1, explored=1)
        self.journal(2, raw=2, applied=0)
        self.journal(3, answer=False, effect=False, failure=True)
        decisions = self.exported()["decisions"]
        self.assertEqual([row["action_status"] for row in decisions], ["accepted", "fallback", "accepted", "missing"])
        self.assertEqual(decisions[0]["attempts"][0]["parsed_action"], {"choice": "C0"})
        self.assertEqual(decisions[1]["attempts"][0]["parsed_action"], {"choice": "C1"})
        self.assertEqual(decisions[1]["executed_action"]["objective_choice"], "C0")
        self.assertEqual(decisions[2]["attempts"][0]["parsed_action"], {"choice": "current"})
        self.assertIsNone(decisions[3]["executed_action"])
        self.assertEqual(decisions[0]["observation"], {"me.current_objective_heart": -1})

    def test_rejects_answer_mismatch(self):
        self.journal(0)
        path = self.root / "player-0.log"
        path.write_text(path.read_text().replace("rawobj=0", "rawobj=1"))
        with self.assertRaisesRegex(ValueError, "differs"):
            self.exported()

    def test_score_arm_requires_its_own_action_join(self):
        self.journal(0)
        path = self.root / "player-0.log"
        path.write_text(path.read_text() + "score t=12 id=1 v0=1 v1=2 pick=1\n")
        with self.assertRaisesRegex(ValueError, "Score-arm"):
            self.exported()


if __name__ == "__main__":
    unittest.main()
