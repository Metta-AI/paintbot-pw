"""Host-boundary checks independent of the engine executable: seat staging, the bridge, the oracle."""

import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent / "runtime"))
from seats import verified_policy


class RuntimeTests(unittest.TestCase):
    def test_hash_mismatch_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "policy"
            p.write_text("idle = 1")
            with self.assertRaises(ValueError):
                verified_policy(
                    dict(
                        file_uri=p.as_uri(),
                        size_bytes=p.stat().st_size,
                        content_hash="sha256:wrong",
                        slot=0,
                    )
                )

ORACLE_REQUEST = b'{"state":"ping","questions":{"q":{"type":"noul","instructions":"Is this a ping?"}}}'
class OracleTests(unittest.TestCase):
    """The advisor oracle: sandboxed seats ask, the host calls out, answers land on a later tick."""

    def _server(self, delay=0.0, body=b'{"answers":{"q":{"type":"noul","noul":0.9}}}', status=200):
        import http.server
        import threading
        import time

        seen = []
        requests = self.requests = []  # (path, headers) per POST, for the tests that care

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                seen.append(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
                requests.append((self.path, {k.lower(): v for k, v in self.headers.items()}))
                time.sleep(delay)
                self.send_response(status)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return f"http://127.0.0.1:{server.server_address[1]}/", seen

    def _settle(self, oracle, seconds=3.0):
        import time

        deadline = time.time() + seconds
        while time.time() < deadline and any(s.inflight is not None for s in oracle._seats.values()):
            time.sleep(0.02)

    def test_answer_arrives_on_a_later_tick_and_asks_are_rate_limited(self):
        from oracle import Oracle

        url, seen = self._server()
        oracle = Oracle(url, "secret", "test-model", min_interval=24, deadline=2.0)
        self.addCleanup(oracle.close)
        self.assertEqual(oracle.ask(3, 0, ORACLE_REQUEST), 1)  # asked
        self.assertEqual(oracle.poll(3, 1, 4096)[0], 0)  # nothing yet on the asking tick
        self._settle(oracle)
        status, answer = oracle.poll(3, 1, 4096)  # answered on a later tick
        self.assertEqual(status, len(answer))
        self.assertTrue(answer.startswith(b'{"q":{"type":"noul","noul":0.9}}'))
        self.assertEqual(seen[0]["model"], "test-model")
        self.assertEqual(seen[0]["questions"]["q"]["type"], "noul")
        self.assertEqual(seen[0]["state"], "ping")
        # Too soon: the ask is refused, the answer already collected is gone, and nothing was sent.
        self.assertEqual(oracle.ask(3, 2, ORACLE_REQUEST), 0)
        self.assertEqual(oracle.poll(3, 1, 4096)[0], -1)
        self.assertEqual(len(seen), 1)
        self.assertEqual(oracle.ask(3, 24, ORACLE_REQUEST), 2)
        self._settle(oracle)
        self.assertEqual(len(seen), 2)

    def test_slow_endpoint_is_reported_as_failure_without_blocking(self):
        import time

        from oracle import Oracle

        url, _ = self._server(delay=1.5)
        oracle = Oracle(url, deadline=0.3)
        self.addCleanup(oracle.close)
        started = time.time()
        self.assertEqual(oracle.ask(3, 0, ORACLE_REQUEST), 1)
        self.assertEqual(oracle.poll(3, 1, 4096)[0], 0)
        self.assertLess(time.time() - started, 0.2, "an ask or poll must never wait on the network")
        self._settle(oracle)
        self.assertEqual(oracle.poll(3, 1, 4096)[0], -1)  # failed, and the seat is free to ask again
        self.assertEqual(oracle.ask(3, 24, ORACLE_REQUEST), 2)

    def test_hosted_pods_reach_the_oracle_through_the_llm_sidecar(self):
        from oracle import Oracle

        # Hosted game pods hold no provider key: the platform's sidecar does, at this reserved variable.
        oracle = Oracle.from_env({"AWS_ENDPOINT_URL_BEDROCK_RUNTIME": "http://127.0.0.1:9100/"})
        self.addCleanup(oracle.close)
        self.assertEqual(oracle.url, "http://127.0.0.1:9100/v1/systemone")
        self.assertIsNone(oracle.key)
        self.assertEqual(oracle.model, "typesafe/jev-1.13")
        # The sidecar's System One bucket is 120 a minute per player slot; one ask a second is half of it.
        self.assertEqual(oracle.min_interval, 24)
        self.assertTrue(oracle.sidecar)

        explicit = Oracle.from_env(
            {"AWS_ENDPOINT_URL_BEDROCK_RUNTIME": "http://127.0.0.1:9100", "COGAME_ORACLE_URL": "https://example.test/o"}
        )
        self.addCleanup(explicit.close)
        self.assertEqual((explicit.url, explicit.model, explicit.min_interval), ("https://example.test/o", "jev-latest", 24))
        self.assertFalse(explicit.sidecar)

        tuned = Oracle.from_env(
            {
                "AWS_ENDPOINT_URL_BEDROCK_RUNTIME": "http://127.0.0.1:9100",
                "COGAME_ORACLE_MODEL": "typesafe/jev-2",
                "COGAME_ORACLE_INTERVAL": "96",
            }
        )
        self.addCleanup(tuned.close)
        self.assertEqual((tuned.model, tuned.min_interval), ("typesafe/jev-2", 96))

        self.assertIsNone(Oracle.from_env({"AWS_ENDPOINT_URL_BEDROCK_RUNTIME": "http://127.0.0.1:9100", "COGAME_ORACLE": "off"}))
        self.assertIsNone(Oracle.from_env({"AWS_ENDPOINT_URL_BEDROCK_RUNTIME": "ftp://127.0.0.1"}))
        self.assertIsNone(Oracle.from_env({"COGAME_ORACLE_URL": "http://plain.test/o"}))
        self.assertIsNone(Oracle.from_env({}))

    def test_sidecar_asks_name_the_seat_and_carry_no_credential(self):
        from oracle import Oracle

        url, seen = self._server()
        oracle = Oracle.from_env({"AWS_ENDPOINT_URL_BEDROCK_RUNTIME": url})
        self.addCleanup(oracle.close)
        self.assertEqual(oracle.ask(5, 0, ORACLE_REQUEST), 1)
        self._settle(oracle)
        path, headers = self.requests[0]
        self.assertEqual(path, "/v1/systemone")
        # The platform charges spend and the request-rate bucket to the seat the game names.
        self.assertEqual(headers["x-coworld-player-slot"], "5")
        self.assertNotIn("authorization", headers)
        self.assertEqual(seen[0]["model"], "typesafe/jev-1.13")
        self.assertEqual(oracle.poll(5, 1, 4096)[1], b'{"q":{"type":"noul","noul":0.9}}')

        direct_url, _ = self._server()
        direct = Oracle(direct_url, "secret")
        self.addCleanup(direct.close)
        direct.ask(5, 0, ORACLE_REQUEST)
        self._settle(direct)
        _, headers = self.requests[0]
        self.assertEqual(headers["authorization"], "Bearer secret")
        self.assertNotIn("x-coworld-player-slot", headers)  # seat numbers stay inside the platform

    def test_sidecar_without_the_route_is_asked_once(self):
        from oracle import Oracle

        # A sidecar that predates /v1/systemone answers 404. Asks already in flight finish; every later ask is refused.
        url, seen = self._server(status=404, body=b'{"message":"not found"}')
        oracle = Oracle.from_env({"AWS_ENDPOINT_URL_BEDROCK_RUNTIME": url})
        self.addCleanup(oracle.close)
        self.assertEqual(oracle.ask(2, 0, ORACLE_REQUEST), 1)
        self._settle(oracle)
        self.assertEqual(oracle.poll(2, 1, 4096)[0], -1)
        self.assertEqual(oracle.ask(2, 100, ORACLE_REQUEST), 0)
        self.assertEqual(oracle.ask(9, 100, ORACLE_REQUEST), 0)
        self.assertEqual(len(seen), 1)

    def test_sidecar_rate_or_spend_limit_fails_the_ask_and_nothing_else(self):
        from oracle import Oracle

        url, seen = self._server(status=429, body=b'{"error":{"message":"spend limit","code":429}}')
        oracle = Oracle.from_env({"AWS_ENDPOINT_URL_BEDROCK_RUNTIME": url})
        self.addCleanup(oracle.close)
        self.assertEqual(oracle.ask(2, 0, ORACLE_REQUEST), 1)
        self._settle(oracle)
        self.assertEqual(oracle.poll(2, 1, 4096)[0], -1)
        self.assertEqual(oracle.ask(2, 100, ORACLE_REQUEST), 2)  # limits clear; the seat may try again
        self._settle(oracle)
        self.assertEqual(len(seen), 2)

    def test_no_reply_however_broken_leaves_a_seat_pending(self):
        import http.server
        import threading

        from oracle import Oracle

        replies = {
            "/cut/v1/systemone": (404, b'{"message":"not', 4096),  # error body shorter than it claims
            "/list/v1/systemone": (200, b"[1]", 3),  # valid JSON, not an object
            "/text/v1/systemone": (200, b'{"answers":"no"}', 16),  # answers is not an object
        }

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                self.rfile.read(int(self.headers["Content-Length"]))
                status, body, claimed = replies[self.path]
                self.send_response(status)
                self.send_header("Content-Length", str(claimed))
                self.end_headers()
                self.wfile.write(body)
                self.wfile.flush()
                self.connection.close()

            def log_message(self, *args):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        for prefix in ("cut", "list", "text"):
            with self.subTest(prefix):
                base = f"http://127.0.0.1:{server.server_address[1]}/{prefix}"
                oracle = Oracle.from_env({"AWS_ENDPOINT_URL_BEDROCK_RUNTIME": base, "COGAME_ORACLE_DEADLINE": "1"})
                self.addCleanup(oracle.close)
                self.assertEqual(oracle.ask(4, 0, ORACLE_REQUEST), 1)
                self._settle(oracle)
                # Whatever went wrong, the seat is told it failed and may ask again; it is never left waiting.
                self.assertEqual(oracle.poll(4, 1, 4096)[0], -1)
                self.assertEqual(oracle.failures, 1)
                self.assertEqual(oracle._reported, 1)

    def test_a_malformed_deadline_only_matters_when_there_is_an_oracle(self):
        from oracle import Oracle

        self.assertIsNone(Oracle.from_env({"COGAME_ORACLE_DEADLINE": "soon"}))

    _NOUL_ASK = {"state": {"t": 0}, "questions": {"g": {"type": "noul", "instructions": "?"}}}

    def _basic_round_trip(self, reply_body):
        """One BASIC ask through the bridge against an endpoint that answers `reply_body`."""
        import host
        from oracle import Oracle

        url, _ = self._server(body=reply_body)
        oracle = Oracle(url, min_interval=24, deadline=2.0)
        self.addCleanup(oracle.close)
        pending = {}
        host.basic_oracle_round(oracle, {"tick": 0, "oracle": [{"slot": 2, "id": 1, "body": self._NOUL_ASK}]}, pending)
        self._settle(oracle)
        return oracle, pending, host.basic_oracle_round(oracle, {"tick": 1, "oracle": []}, pending)

    def test_flatten_drops_what_it_cannot_scale_and_never_raises(self):
        from oracle import flatten

        questions = {
            "g": {"type": "noul"},
            "s": {"type": "score"},
            "c": {"type": "choice", "criteria": {"a": "", "b": ""}},
            "ok": {"type": "noul"},
        }
        answers = {
            "g": {"noul": float("inf")},  # json.loads("1e999")
            "s": {"score": float("-inf")},
            "c": {"choice": "a", "probabilities": [0.5, 0.5], "confidence": float("inf")},
            "ok": {"noul": 0.25, "confidence": float("nan")},
        }
        self.assertEqual(
            flatten(answers, questions),
            {
                "c": {"value": 0, "confidence": -1, "probabilities": {}},
                "ok": {"value": 250, "confidence": -1, "probabilities": {}},
            },
        )
        for junk in ({"g": {"noul": [1]}}, {"g": {"noul": {"x": 1}}}, {"c": {"choice": ["a"], "probabilities": "no"}}):
            self.assertEqual(flatten(junk, questions), {})

    def test_an_unscalable_answer_fails_the_ask_instead_of_ending_the_episode(self):
        # 1e999 parses as infinity. This once raised out of the host loop and took all sixteen seats with it.
        oracle, pending, replies = self._basic_round_trip(b'{"answers":{"g":{"type":"noul","noul":1e999}}}')
        self.assertEqual(replies, [{"slot": 2, "id": 1, "status": -1, "answers": {}}])
        self.assertEqual(pending, {})
        self.assertEqual(oracle.failures, 1)

    def test_a_reply_with_no_usable_answer_is_failed_not_pending(self):
        # Status 0 means "still pending" to the engine: a seat that waits on it never asks again.
        for body in (b'{"answers":{}}', b'{"answers":{"g":{"type":"noul","noul":null}}}', b'{"answers":{"other":{"noul":0.5}}}'):
            with self.subTest(body):
                oracle, pending, replies = self._basic_round_trip(body)
                self.assertEqual(replies, [{"slot": 2, "id": 1, "status": -1, "answers": {}}])
                self.assertEqual(pending, {})
                self.assertEqual(oracle.failures, 1)

    def test_a_bug_while_flattening_fails_that_ask_only(self):
        import host

        with patch.object(host, "flatten", side_effect=RuntimeError("boom")):
            oracle, pending, replies = self._basic_round_trip(b'{"answers":{"g":{"type":"noul","noul":0.5}}}')
        self.assertEqual(replies, [{"slot": 2, "id": 1, "status": -1, "answers": {}}])
        self.assertEqual(pending, {})
        self.assertEqual(oracle.failures, 1)

    def test_only_a_missing_route_stops_the_asking(self):
        from oracle import Oracle

        # A refusal, a provider fault or a legacy-lane pod may be this seat's or this moment's
        # problem. None of them may turn the advisor off for every seat for the rest of the episode.
        for status in (400, 403, 500, 502, 503):
            with self.subTest(status):
                url, seen = self._server(status=status, body=b'{"error":{"message":"no","code":0}}')
                oracle = Oracle.from_env({"AWS_ENDPOINT_URL_BEDROCK_RUNTIME": url})
                self.addCleanup(oracle.close)
                self.assertEqual(oracle.ask(2, 0, ORACLE_REQUEST), 1)
                self._settle(oracle)
                self.assertEqual(oracle.poll(2, 1, 4096)[0], -1)
                self.assertEqual(oracle.ask(9, 100, ORACLE_REQUEST), 1)
                self._settle(oracle)
                self.assertEqual(len(seen), 2)
        for status in (404, 405, 501):
            with self.subTest(status):
                url, seen = self._server(status=status, body=b"{}")
                oracle = Oracle.from_env({"AWS_ENDPOINT_URL_BEDROCK_RUNTIME": url})
                self.addCleanup(oracle.close)
                oracle.ask(2, 0, ORACLE_REQUEST)
                self._settle(oracle)
                self.assertEqual(oracle.ask(9, 100, ORACLE_REQUEST), 0)
        # A direct endpoint has no route to go missing: its 404 is one failed ask.
        url, seen = self._server(status=404, body=b"{}")
        direct = Oracle(url)
        self.addCleanup(direct.close)
        direct.ask(2, 0, ORACLE_REQUEST)
        self._settle(direct)
        self.assertEqual(direct.ask(9, 100, ORACLE_REQUEST), 1)

    def test_failure_log_is_bounded_and_says_when_it_stops(self):
        import contextlib
        import io

        from oracle import Oracle

        url, _ = self._server(status=500, body=b"down")
        oracle = Oracle(url, min_interval=0)
        self.addCleanup(oracle.close)
        captured = io.StringIO()
        with contextlib.redirect_stderr(captured):
            for i in range(12):
                self.assertEqual(oracle.ask(i, 0, ORACLE_REQUEST), 1)
            self._settle(oracle)
        lines = [line for line in captured.getvalue().splitlines() if line.startswith("oracle:")]
        self.assertEqual(sum("failed: HTTP 500 down" in line for line in lines), 8)
        self.assertEqual(sum("not logged" in line for line in lines), 1)
        self.assertEqual(len(lines), 9)
        self.assertEqual(oracle.failures, 12)

    def test_a_sidecar_never_sees_a_credential(self):
        from oracle import Oracle

        url, _ = self._server()
        oracle = Oracle(url + "v1/systemone", "secret", sidecar=True)
        self.addCleanup(oracle.close)
        oracle.ask(1, 0, ORACLE_REQUEST)
        self._settle(oracle)
        self.assertNotIn("authorization", self.requests[0][1])  # the sidecar is reached over plain http

    def test_a_refused_endpoint_says_why_there_is_no_oracle(self):
        import contextlib
        import io

        from oracle import Oracle

        captured = io.StringIO()
        with contextlib.redirect_stderr(captured):
            self.assertIsNone(
                Oracle.from_env({"COGAME_ORACLE_URL": "http://plain.test/o", "AWS_ENDPOINT_URL_BEDROCK_RUNTIME": "http://127.0.0.1:1"})
            )
        self.assertIn("COGAME_ORACLE_URL must be https", captured.getvalue())

    def test_a_dripping_reply_is_failed_at_the_deadline_and_dropped_when_it_lands(self):
        import http.server
        import threading
        import time

        from oracle import Oracle

        body = b'{"answers":{"q":{"type":"noul","noul":0.9}}}'

        class Drip(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                self.rfile.read(int(self.headers["Content-Length"]))
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                for i in range(len(body)):  # a byte every 50 ms: no single socket read ever times out
                    self.wfile.write(body[i : i + 1])
                    self.wfile.flush()
                    time.sleep(0.05)

            def log_message(self, *args):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Drip)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        oracle = Oracle(f"http://127.0.0.1:{server.server_address[1]}/", deadline=0.3, min_interval=0)
        self.addCleanup(oracle.close)
        self.assertEqual(oracle.ask(3, 0, ORACLE_REQUEST), 1)
        self.assertEqual(oracle.poll(3, 1, 4096)[0], 0)
        time.sleep(0.8)  # past deadline x grace (0.6 s); the reply needs ~2.2 s
        self.assertEqual(oracle.poll(3, 1, 4096)[0], -1)
        self.assertEqual(oracle.failures, 1)
        self.assertEqual(oracle.ask(3, 1, ORACLE_REQUEST), 2)  # the seat is free to ask again
        time.sleep(2.0)  # the first reply lands now, complete and well-formed
        self.assertEqual(oracle.poll(3, 1, 4096)[0], -1)  # and is not resurrected
        self.assertEqual(oracle.failures, 1)

    def test_without_an_oracle_every_ask_is_refused(self):
        """No oracle configured: the engine is not told to ask (no PW_ORACLE), and every bridge
        reply is the empty {"oracle": []} object, never the legacy bare list."""
        import host

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            engine = _stand_in_engine(root, ticks=3, ask_on_tick=(0, 1, 2))
            with patch.dict(
                os.environ,
                COGAME_PLAYER_SEATS_URI=_seat_document(root, {}).as_uri(),
                COGAME_PLAYER_FAILURE_URI=(root / "failure.json").as_uri(),
                COGAME_ORACLE="off",
            ):
                self.assertEqual(host.run(str(engine)), 0)
            out = json.loads((root / "out.json").read_text())
            self.assertEqual(out["env"], [None, None])
            self.assertEqual(out["replies"], [{"oracle": []}] * 3)
            self.assertFalse((root / "failure.json").exists())

    def test_flatten_gives_basic_seats_thousandths_and_choice_indices(self):
        from oracle import flatten

        questions = {
            "press": {"type": "noul", "criteria": {"true": "yes", "false": "no"}},
            "caution": {"type": "score", "criteria": ["bold", "careful"]},
            "formation": {"type": "choice", "criteria": {"spread": "alone", "pairs": "in twos"}},
            "junk": {"type": "score"},
        }
        answers = {
            "press": {"noul": 0.9, "confidence": 0.4},
            "caution": {"score": 1.5},
            "formation": {"choice": "pairs", "probabilities": {"spread": 0.25, "pairs": 0.75, "x": 1}},
            "junk": {"score": "not a number"},
            "unknown": {"noul": 1},
        }
        self.assertEqual(
            flatten(answers, questions),
            {
                "press": {"value": 900, "confidence": 400, "probabilities": {}},
                "caution": {"value": 1500, "confidence": -1, "probabilities": {}},
                "formation": {
                    "value": 1,
                    "confidence": -1,
                    "probabilities": {"spread": 250, "pairs": 750},
                },
            },
        )

    def test_basic_asks_cross_the_bridge_and_answers_return_flattened(self):
        """The engine ships a BASIC seat's ask in its world line; the host answers on a later tick."""
        import host
        from oracle import Oracle

        url, seen = self._server(
            body=b'{"answers":{"guard":{"noul":0.8},"caution":{"score":2,"confidence":0.5}}}'
        )
        oracle = Oracle(url, min_interval=24, deadline=2.0)
        self.addCleanup(oracle.close)
        body = {
            "state": {"tick": 0, "hp": 3},
            "questions": {
                "guard": {"type": "noul", "instructions": "?", "criteria": {"true": "t", "false": "f"}},
                "caution": {"type": "score", "instructions": "?", "criteria": ["a", "b", "c"]},
            },
        }
        pending = {}
        replies = host.basic_oracle_round(oracle, {"tick": 0, "oracle": [{"slot": 2, "id": 1, "body": body}]}, pending)
        self.assertEqual(replies, [])
        self.assertEqual(set(pending), {2})
        self._settle(oracle)
        self.assertEqual(seen[0]["state"], body["state"])
        self.assertEqual(seen[0]["questions"], body["questions"])
        replies = host.basic_oracle_round(oracle, {"tick": 1, "oracle": []}, pending)
        self.assertEqual(
            replies,
            [
                {
                    "slot": 2,
                    "id": 1,
                    "status": 2,
                    "answers": {
                        "guard": {"value": 800, "confidence": -1, "probabilities": {}},
                        "caution": {"value": 2000, "confidence": 500, "probabilities": {}},
                    },
                }
            ],
        )
        self.assertEqual(pending, {})
        # A second ask inside the interval is refused at once (the engine gates this too; the
        # host's refusal is a backstop); after the interval it goes through.
        replies = host.basic_oracle_round(
            oracle, {"tick": 2, "oracle": [{"slot": 2, "id": 2, "body": body}]}, pending
        )
        self.assertEqual(replies, [{"slot": 2, "id": 2, "status": -1, "answers": {}}])
        replies = host.basic_oracle_round(
            oracle, {"tick": 30, "oracle": [{"slot": 2, "id": 3, "body": body}]}, pending
        )
        self.assertEqual(replies, [])
        self._settle(oracle)
        self.assertEqual(len(seen), 2)
        replies = host.basic_oracle_round(oracle, {"tick": 31, "oracle": []}, pending)
        self.assertEqual([(r["id"], r["status"]) for r in replies], [(3, 2)])
        self.assertEqual(pending, {})

    def test_basic_bridge_reply_carries_oracle_replies_and_the_engine_env(self):
        """With an oracle configured the host replies {commands, oracle} and enables BASIC asks."""
        import host
        from oracle import Oracle

        url, _ = self._server(body=b'{"answers":{"q":{"noul":0.25}}}')
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            good = root / "good"
            good_data = b"idle = 1\n"
            good.write_bytes(good_data)
            seats = [
                dict(
                    slot=i,
                    file_uri=good.as_uri(),
                    size_bytes=len(good_data),
                    content_hash="sha256:" + hashlib.sha256(good_data).hexdigest(),
                    log_uri=(root / f"{i}.log").as_uri(),
                )
                for i in range(16)
            ]
            doc = root / "seats.json"
            doc.write_text(
                json.dumps(
                    dict(schema="coworld-player-seats/1", seats=seats, player_status_uri=(root / "status").as_uri())
                )
            )
            # A stand-in engine: asks once on tick 0, then reads replies until the answer lands.
            engine = root / "engine"
            engine.write_text(
                "#!/usr/bin/env python3\n"
                "import json, os, socket, sys, time\n"
                "s = socket.socket(fileno=int(os.environ['PW_POLICY_FD']))\n"
                "f = s.makefile('rw')\n"
                "out = {'env': [os.environ.get('PW_ORACLE'), os.environ.get('PW_ORACLE_INTERVAL')], 'replies': []}\n"
                "body = {'state': 's', 'questions': {'q': {'type': 'noul', 'instructions': '?', 'criteria': {'true': 't', 'false': 'f'}}}}\n"
                "for tick in range(200):\n"
                "    asks = [{'slot': 5, 'id': 1, 'body': body}] if tick == 0 else []\n"
                "    f.write(json.dumps({'rulesVersion': 36, 'tick': tick, 'oracle': asks}) + '\\n'); f.flush()\n"
                "    r = json.loads(f.readline())\n"
                "    assert isinstance(r, dict) and set(r) == {'oracle'}, r\n"
                "    if r['oracle']: out['replies'] = r['oracle']; break\n"
                "    time.sleep(0.02)\n"
                f"open({str(root / 'out.json')!r}, 'w').write(json.dumps(out))\n"
            )
            engine.chmod(0o755)
            with patch.dict(
                os.environ,
                COGAME_PLAYER_SEATS_URI=doc.as_uri(),
                COGAME_PLAYER_FAILURE_URI=(root / "failure.json").as_uri(),
            ), patch.object(Oracle, "from_env", classmethod(lambda cls, env=None: Oracle(url, min_interval=7))):
                self.assertEqual(host.run(str(engine)), 0)
            out = json.loads((root / "out.json").read_text())
            self.assertEqual(out["env"], ["1", "7"])
            self.assertEqual(
                out["replies"],
                [{"slot": 5, "id": 1, "status": 1, "answers": {"q": {"value": 250, "confidence": -1, "probabilities": {}}}}],
            )

    def test_tick_pacing_holds_the_bridge_to_real_time(self):
        """COGAME_TICK_SECONDS makes each bridge tick take at least that long (local evaluation aid)."""
        import time

        import host

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            good = root / "good"
            good_data = b"idle = 1\n"
            good.write_bytes(good_data)
            seats = [
                dict(
                    slot=i,
                    file_uri=good.as_uri(),
                    size_bytes=len(good_data),
                    content_hash="sha256:" + hashlib.sha256(good_data).hexdigest(),
                    log_uri=(root / f"{i}.log").as_uri(),
                )
                for i in range(16)
            ]
            doc = root / "seats.json"
            doc.write_text(
                json.dumps(
                    dict(schema="coworld-player-seats/1", seats=seats, player_status_uri=(root / "status").as_uri())
                )
            )
            engine = root / "engine"
            engine.write_text(
                "#!/usr/bin/env python3\n"
                "import json, os, socket\n"
                "s = socket.socket(fileno=int(os.environ['PW_POLICY_FD']))\n"
                "f = s.makefile('rw')\n"
                "for tick in range(8):\n"
                "    f.write(json.dumps({'rulesVersion': 36, 'tick': tick, 'oracle': []}) + '\\n'); f.flush()\n"
                "    assert isinstance(json.loads(f.readline()), dict)\n"
            )
            engine.chmod(0o755)
            with patch.dict(
                os.environ,
                COGAME_PLAYER_SEATS_URI=doc.as_uri(),
                COGAME_PLAYER_FAILURE_URI=(root / "failure.json").as_uri(),
                COGAME_TICK_SECONDS="0.05",
            ):
                started = time.monotonic()
                self.assertEqual(host.run(str(engine)), 0)
                self.assertGreaterEqual(time.monotonic() - started, 0.35)

    def test_oracle_log_journals_requests_and_answers(self):
        from oracle import Oracle

        url, _ = self._server()
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "oracle.jsonl"
            oracle = Oracle(url, log_path=str(path))
            self.addCleanup(oracle.close)
            body = json.dumps({"state": "ping", "questions": {"q": {"type": "noul", "instructions": "?"}}}).encode()
            self.assertEqual(oracle.ask(4, 7, body), 1)
            self._settle(oracle)
            row = json.loads(path.read_text().splitlines()[0])
            self.assertEqual((row["slot"], row["id"], row["tick"]), (4, 1, 7))
            self.assertEqual(row["model"], "jev-latest")
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(row["request"]["state"], "ping")
            self.assertEqual(row["answers"], {"q": {"type": "noul", "noul": 0.9}})
            self.assertGreaterEqual(row["latency_ms"], 0)

    def test_oracle_log_repairs_existing_permissions(self):
        from oracle import Oracle

        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "oracle.jsonl"
            path.write_text("")
            path.chmod(0o644)
            oracle = Oracle("https://example.invalid/", log_path=str(path))
            oracle.close()
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_guest_cannot_pick_the_endpoint_or_send_junk(self):
        from oracle import Oracle

        oracle = Oracle("https://example.invalid/")
        self.addCleanup(oracle.close)
        self.assertEqual(oracle.ask(0, 0, b"not json"), 0)
        self.assertEqual(oracle.ask(0, 0, b'{"url":"https://evil","questions":{}}'), 0)
        self.assertEqual(oracle.ask(0, 0, b'{"state":1,"questions":[]}'), 0)
        self.assertEqual(oracle.ask(0, 0, b"x" * (40 * 1024)), 0)
        self.assertIsNone(Oracle.from_env({}))
        self.assertIsNone(Oracle.from_env({"COGAME_ORACLE_URL": "http://plain"}))
        configured = Oracle.from_env({"COGAME_ORACLE_URL": "https://api.example/", "COGAME_ORACLE_INTERVAL": "48"})
        self.assertEqual(configured.min_interval, 48)
        configured.close()


GOOD_SOURCE = b"idle = 1\n"
IDLE_STUB = b"idle = 1\n"  # what the host stages for a forfeited seat


def _seat_document(root, files):
    """A sixteen-seat document; `files` maps a slot to the bytes it submits (others submit GOOD_SOURCE)."""
    seats = []
    for slot in range(16):
        data = files.get(slot, GOOD_SOURCE)
        path = root / f"seat-{slot}"
        path.write_bytes(data)
        seats.append(
            dict(
                slot=slot,
                file_uri=path.as_uri(),
                size_bytes=len(data),
                content_hash="sha256:" + hashlib.sha256(data).hexdigest(),
                log_uri=(root / f"{slot}.log").as_uri(),
            )
        )
    doc = root / "seats.json"
    doc.write_text(
        json.dumps(dict(schema="coworld-player-seats/1", seats=seats, player_status_uri=(root / "status").as_uri()))
    )
    return doc


def _stand_in_engine(root, ticks=1, ask_on_tick=()):
    """An engine that records what the host staged for it and every bridge reply, then exits 0.

    It writes {staged, contents (slot -> sha256 of the staged file), replies, env} to root/out.json.
    """
    engine = root / "engine"
    engine.write_text(
        "#!/usr/bin/env python3\n"
        "import hashlib, json, os, socket\n"
        "from urllib.parse import unquote, urlsplit\n"
        "path = lambda uri: unquote(urlsplit(uri).path)\n"
        "doc = json.load(open(path(os.environ['COGAME_PLAYER_SEATS_URI'])))\n"
        "contents = {str(s['slot']): hashlib.sha256(open(path(s['file_uri']), 'rb').read()).hexdigest() for s in doc['seats']}\n"
        "s = socket.socket(fileno=int(os.environ['PW_POLICY_FD']))\n"
        "f = s.makefile('rw')\n"
        "body = {'state': 's', 'questions': {'q': {'type': 'noul', 'instructions': '?'}}}\n"
        "replies = []\n"
        f"for tick in range({ticks}):\n"
        f"    asks = [{{'slot': 1, 'id': tick + 1, 'body': body}}] if tick in {tuple(ask_on_tick)!r} else []\n"
        "    f.write(json.dumps({'rulesVersion': 36, 'tick': tick, 'oracle': asks}) + '\\n'); f.flush()\n"
        "    replies.append(json.loads(f.readline()))\n"
        "out = {'staged': doc, 'contents': contents, 'replies': replies,\n"
        "       'env': [os.environ.get('PW_ORACLE'), os.environ.get('PW_ORACLE_INTERVAL')]}\n"
        f"open({str(root / 'out.json')!r}, 'w').write(json.dumps(out))\n"
    )
    engine.chmod(0o755)
    return engine


class SeatStagingTests(unittest.TestCase):
    """Every seat is a BASIC source file; anything else forfeits that seat alone and the episode still runs."""

    def _run(self, files):
        import host

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            engine = _stand_in_engine(root)
            failure = root / "failure.json"
            with patch.dict(
                os.environ,
                COGAME_PLAYER_SEATS_URI=_seat_document(root, files).as_uri(),
                COGAME_PLAYER_FAILURE_URI=failure.as_uri(),
                COGAME_ORACLE="off",
            ):
                rc = host.run(str(engine))
            out = json.loads((root / "out.json").read_text())
            out["rc"] = rc
            out["failure"] = json.loads(failure.read_text()) if failure.exists() else None
            return out

    def _assert_forfeited(self, out, slot, message):
        self.assertEqual(out["rc"], 0)
        self.assertEqual(out["failure"], {"message": message, "failed_policy_index": slot})
        staged = {seat["slot"]: seat for seat in out["staged"]["seats"]}
        self.assertEqual(len(staged), 16)
        idle = staged[slot]
        self.assertTrue(idle["file_uri"].endswith("/idle.bas"), idle["file_uri"])
        self.assertEqual(idle["size_bytes"], len(IDLE_STUB))
        self.assertEqual(idle["content_hash"], "sha256:" + hashlib.sha256(IDLE_STUB).hexdigest())
        self.assertEqual(out["contents"][str(slot)], hashlib.sha256(IDLE_STUB).hexdigest())
        for other in range(16):
            if other == slot:
                continue
            seat = staged[other]
            self.assertTrue(seat["file_uri"].endswith(f"/player-{other}.bas"), seat["file_uri"])
            self.assertEqual(seat["size_bytes"], len(GOOD_SOURCE))
            self.assertEqual(seat["content_hash"], "sha256:" + hashlib.sha256(GOOD_SOURCE).hexdigest())
            self.assertEqual(out["contents"][str(other)], hashlib.sha256(GOOD_SOURCE).hexdigest())
        # No oracle configured: the reply is the empty object, never a bare list.
        self.assertEqual(out["replies"], [{"oracle": []}])
        self.assertIsInstance(out["replies"][0], dict)

    def test_a_wasm_module_is_forfeited_and_the_other_seats_keep_their_source(self):
        out = self._run({7: b"\x00asm\x01\x00\x00\x00" + b"\x00" * 40})
        self._assert_forfeited(
            out, 7, "Policy initialization failed: WASM modules are no longer accepted; submit a BASIC source file"
        )

    def test_a_non_utf8_or_oversize_source_is_forfeited(self):
        with self.subTest("not UTF-8"):
            out = self._run({3: b"\xff\xfe idle = 1\n"})
            self._assert_forfeited(out, 3, "Policy initialization failed: BASIC source is not UTF-8")
        # The limit is 128 KiB, matching maxSourceBytes in bots.nim; the boundary is exact.
        with self.subTest("over 128 KiB"):
            out = self._run({12: b"x" * (128 * 1024 + 1)})
            self._assert_forfeited(out, 12, "Policy initialization failed: BASIC source exceeds 128 KiB")
        with self.subTest("exactly 128 KiB is accepted"):
            out = self._run({12: b"x" * (128 * 1024)})
            self.assertEqual((out["rc"], out["failure"]), (0, None))
            self.assertEqual(out["contents"]["12"], hashlib.sha256(b"x" * (128 * 1024)).hexdigest())

    def test_a_hash_mismatch_still_forfeits_by_exception_name(self):
        import host

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            doc = _seat_document(root, {})
            seats = json.loads(doc.read_text())
            seats["seats"][2]["content_hash"] = "sha256:wrong"
            doc.write_text(json.dumps(seats))
            failure = root / "failure.json"
            with patch.dict(
                os.environ,
                COGAME_PLAYER_SEATS_URI=doc.as_uri(),
                COGAME_PLAYER_FAILURE_URI=failure.as_uri(),
                COGAME_ORACLE="off",
            ):
                self.assertEqual(host.run(str(_stand_in_engine(root))), 0)
            self.assertEqual(
                json.loads(failure.read_text()), {"message": "Policy initialization failed: ValueError", "failed_policy_index": 2}
            )


if __name__ == "__main__":
    unittest.main()
