"""Real hosted engine + Python staging wrapper: private annotations at completion."""
import hashlib
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]


class AnnotationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix="paintbot-annotations-build-")
        cls.addClassCleanup(cls.build.cleanup)
        cls.engine = Path(cls.build.name) / "paintbot"
        subprocess.run([
            "nim", "c", "-d:coworld", f"--nimcache:{cls.build.name}/cache",
            f"-o:{cls.engine}", "examples/paintbot/paintbot.nim",
        ], cwd=ROOT, check=True)

    def test_private_files_and_nonfatal_limits_through_host(self):
        # Seats 0/1 annotate; seat 2 has a destination but never annotates;
        # seat 3 calls ANNOTATE without an optional destination.
        with tempfile.TemporaryDirectory(prefix="paintbot-annotations-") as temp:
            root = Path(temp)
            scripts = []
            for slot in range(2):
                scripts.append(f'''
bad = ANNOTATE(worldTick, -1, -1, -1)
i = 0
while i < 50
code = ANNOTATE(worldTick, strNew("intent"), strNew("move"), strNew("{{""seat"":{slot}}}"))
i = i + 1
wend
PRINT "CONTINUED", code
''')
            scripts += ['idle = 1', 'code = ANNOTATE(worldTick, 0, 0, 0)\nPRINT "DISABLED", code']
            seats = []
            for slot, source in enumerate(scripts):
                path = root / f"{slot}.bas"
                path.write_text(source)
                seat = dict(slot=slot, file_uri=path.as_uri(), size_bytes=len(source.encode()),
                            content_hash="sha256:" + hashlib.sha256(source.encode()).hexdigest(),
                            log_uri=(root / f"{slot}.log").as_uri())
                if slot < 3:
                    seat["annotations_uri"] = (root / f"{slot}.jsonl").as_uri()
                seats.append(seat)
            config = dict(tokens=[str(i) for i in range(4)], players=[dict(name=str(i)) for i in range(4)],
                          seed=2026, max_ticks=240)
            inputs = {"CONFIG": config, "PLAYER_SEATS": dict(schema="coworld-player-seats/1", seats=seats,
                      player_status_uri=(root / "status.json").as_uri())}
            env = dict(os.environ, COGAME_HOST="127.0.0.1", COGAME_TICK_SECONDS="0")
            env.pop("COWORLD_LLM_ENDPOINT", None)
            with socket.socket() as listener:
                listener.bind(("127.0.0.1", 0))
                env["COGAME_PORT"] = str(listener.getsockname()[1])
            for key, value in inputs.items():
                path = root / f"{key}.json"
                path.write_text(json.dumps(value))
                env[f"COGAME_{key}_URI"] = path.as_uri()
            for key in ["RESULTS", "SAVE_REPLAY", "PLAYER_FAILURE"]:
                env[f"COGAME_{key}_URI"] = (root / key).as_uri()
            with (root / "host.log").open("w") as log:
                process = subprocess.Popen([sys.executable, str(ROOT / "coworld/paintbot/runtime/host.py"),
                                            "--engine", str(self.engine)], env=env, cwd=ROOT,
                                           stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                try:
                    deadline = time.monotonic() + 60
                    while not (root / "RESULTS").exists():
                        self.assertFalse((root / "PLAYER_FAILURE").exists(),
                                         (root / "0.log").read_text() if (root / "0.log").exists() else "player failure")
                        self.assertIsNone(process.poll(), (root / "host.log").read_text())
                        self.assertLess(time.monotonic(), deadline, (root / "host.log").read_text())
                        time.sleep(.02)
                    for slot in range(2):
                        records = [json.loads(line) for line in (root / f"{slot}.jsonl").read_text().splitlines()]
                        self.assertEqual(len(records), 1000)
                        self.assertTrue(all(record["args"] == {"seat": slot} for record in records))
                        self.assertEqual([r["time"] for r in records], sorted(r["time"] for r in records))
                        self.assertIn("CONTINUED", (root / f"{slot}.log").read_text())
                    self.assertFalse((root / "2.jsonl").exists())
                    self.assertIn("DISABLED", (root / "3.log").read_text())
                    status = json.loads((root / "status.json").read_text())
                    self.assertTrue(all(p["exit_code"] == 0 for p in status["players"]))
                    self.assertGreater((root / "SAVE_REPLAY").stat().st_size, 0)
                    self.assertNotIn('"function":"move"', (root / "host.log").read_text())
                finally:
                    os.killpg(process.pid, signal.SIGTERM)
                    process.wait(timeout=10)


if __name__ == "__main__":
    unittest.main()
