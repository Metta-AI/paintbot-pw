"""Real hosted-engine proof with a local deterministic System One endpoint (no provider calls).

Build tmp/paintbot-coworld first. Run with the benchmark's Pydantic/Wasmtime dependencies.
"""

import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from benchmark import Episode

ROOT = Path(__file__).resolve().parents[2]


class Advisor(BaseHTTPRequestHandler):
    def do_POST(self):
        assert self.path == "/v1/systemone"
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        assert body["model"] == "local-proof"
        assert set(body["questions"]) == {"guard", "caution"}
        answer = json.dumps(
            {"answers": {"guard": {"noul": 0.9}, "caution": {"score": 2}}}
        ).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(answer)))
        self.end_headers()
        self.wfile.write(answer)

    def log_message(self, format, *args):
        pass


class BenchmarkTests(unittest.TestCase):
    def test_complete_paired_games(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), Advisor)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as tmp:
                # Set BENCHMARK_EVIDENCE to retain full manifests, journals and replays.
                output = Path(
                    os.environ.get("BENCHMARK_EVIDENCE", str(Path(tmp) / "proof"))
                )
                env = dict(
                    os.environ,
                    AWS_ENDPOINT_URL_BEDROCK_RUNTIME=f"http://127.0.0.1:{server.server_port}",
                )
                env.pop("COGAME_ORACLE_URL", None)
                command = [
                    sys.executable,
                    str(ROOT / "coworld/paintbot/benchmark.py"),
                    "--candidate",
                    str(ROOT / "examples/paintbot/players/advised.bas"),
                    "--opponent",
                    str(ROOT / "examples/paintbot/players/base.bas"),
                    "--engine",
                    str(ROOT / "tmp/paintbot-coworld"),
                    "--seeds",
                    "2026",
                    "--tick-seconds",
                    "0",
                    "--model",
                    "local-proof",
                    "--cost-per-request-usd",
                    "0",
                    "--output",
                    str(output),
                    "--port",
                    "18088",
                ]
                subprocess.run(command, env=env, check=True)
                manifest = json.loads((output / "manifest.json").read_text())
                self.assertEqual(manifest["status"], "complete")
                self.assertEqual(len(manifest["pairs"]), 2)
                episodes = [Episode.model_validate(row) for row in manifest["episodes"]]
                self.assertEqual(len(episodes), 4)
                for episode in episodes:
                    self.assertFalse(episode.policy_failure)
                    self.assertNotEqual(episode.outcome, "time_limit")
                    self.assertEqual(episode.failed_requests, 0)
                    self.assertEqual(episode.estimated_completed_request_cost_usd, 0)
                    self.assertIn("replay.bin", episode.artifacts)
                    if episode.advisor == "on":
                        self.assertGreater(episode.completed_requests, 0)
                    else:
                        self.assertEqual(episode.completed_requests, 0)
                    seats = json.loads(
                        (output / episode.directory / "seats.json").read_text()
                    )["seats"]
                    for seat in seats:
                        role = (
                            "candidate"
                            if seat["slot"] % 2 == episode.candidate_team
                            else "opponent"
                        )
                        self.assertEqual(
                            seat["content_hash"],
                            "sha256:" + manifest["policies"][role]["sha256"],
                        )
                for role in ("candidate", "opponent"):
                    with self.subTest(invalid_role=role):
                        invalid = list(command)
                        source = (
                            ROOT
                            / "examples/paintbot/players"
                            / ("base.bas" if role == "candidate" else "advised.bas")
                        )
                        invalid[invalid.index("--" + role) + 1] = str(source)
                        invalid_output = Path(tmp) / ("invalid-" + role)
                        invalid[invalid.index("--output") + 1] = str(invalid_output)
                        invalid.extend(["--ticks", "60"])
                        failed = subprocess.run(
                            invalid,
                            env=env,
                            capture_output=True,
                            text=True,
                            check=False,
                        )
                        self.assertNotEqual(failed.returncode, 0)
                        self.assertIn(
                            "no requests"
                            if role == "candidate"
                            else "Opponent requested advice",
                            failed.stderr,
                        )
                        self.assertEqual(
                            json.loads((invalid_output / "manifest.json").read_text())[
                                "status"
                            ],
                            "running",
                        )
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == "__main__":
    unittest.main()
