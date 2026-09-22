"""Policy-boundary checks independent of the renderer and engine executable."""

import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent / "runtime"))
from sprite import SpriteView, visible
from wasm_policy import decode_replies, verified_policy


class RuntimeTests(unittest.TestCase):
    def test_uniform_spoofs_wasm_color_and_seat_but_preserves_self(self):
        view = SpriteView(2)
        view.initial = False
        w = dict(
            rulesVersion=27, tick=0, cover=[],
            uniforms=[True] + [False] * 15,
            cogs=[dict(pos=dict(x=500,z=2000),aim=dict(x=1000,z=2000),hp=3,cooldown=0)
                  for _ in range(16)],
            hearts=[dict(pos=dict(x=x,z=2000),carrier=-1) for x in (960,5440)],
        )
        with patch("sprite.visible", side_effect=lambda w, observer, other: other in (0,2)):
            frame = view.frame(w)
        self.assertIn(b"player blue left", frame)
        self.assertIn(b"seat 1", frame)
        self.assertNotIn(b"player red right", frame)
        self.assertNotIn(b"seat 0", frame)
        self.assertNotIn(b"uniform worn", frame)
        view.slot = 0
        with patch("sprite.visible", side_effect=lambda w, observer, other: other == 0):
            frame = view.frame(w)
        self.assertIn(b"self red right", frame)
        self.assertIn(b"seat 0", frame)
        self.assertIn(b"uniform worn", frame)

    def test_forward_cone_hides_allies_and_enemies_behind(self):
        w = {
            "cover": [],
            "cogs": [
                {"hp": 3, "pos": {"x": 3000, "z": 2000}, "aim": {"x": 4000, "z": 2000}}
                for _ in range(3)
            ],
        }
        for other in (1, 2):
            for x, z, expected in [
                (3500, 2000, True),
                (2500, 2000, False),
                (3000, 2500, False),
                (3500, 2800, True),
                (3500, 2900, False),
                (5100, 2000, True),
            ]:
                w["cogs"][other]["pos"] = {"x": x, "z": z}
                self.assertEqual(visible(w, 0, other), expected)

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

    def test_foreign_seat_packet_is_rejected(self):
        with self.assertRaises(ValueError):
            decode_replies(b"\x01\0\0\0\x01\0\0\0\x82")

    def test_direct_order_gives_a_wasm_seat_the_basic_actuators(self):
        import struct

        def order(flags, gx, gz, ax, az):
            packet = struct.pack("<BBiiii", 0x85, flags, gx, gz, ax, az)
            return decode_replies(struct.pack("<II", 1, len(packet)) + packet)

        with self.assertRaises(ValueError):
            decode_replies(b"\x01\0\0\0\x03\0\0\0\x85\0\0")  # wrong size
        view = SpriteView(0)
        w = dict(rulesVersion=34, cogs=[dict(pos=dict(x=1000, z=2000), aim=dict(x=0, z=0))])
        # walkTo + shootAt: engine pathing, an exact aim point, one shot.
        command = view.command(w, order(1 | 2 | 16, 3000, 2500, 4000, -1000))
        self.assertEqual(
            command,
            dict(walk=True, direct=False, shoot=True, chargeGrenade=False, sneak=False,
                 goal=dict(x=3000, z=2500), aim=dict(x=4000, z=-1000)),
        )
        # The gamepad turret and its `own aim` marker follow the real aim (north-east = 32).
        self.assertEqual(view.angle, 32)
        # A tick without an order keeps the goal and orders nothing new: no repeated shot.
        command = view.command(w, [])
        self.assertEqual(
            command,
            dict(walk=False, direct=False, shoot=False, chargeGrenade=False, sneak=False,
                 goal=dict(x=3000, z=2500), aim=dict(x=0, z=0)),
        )
        # walkTo alone aims along the walk, as it does for BASIC (aim left unset).
        command = view.command(w, order(1, 1500, 1500, 0, 0))
        self.assertEqual(command["aim"], dict(x=0, z=0))
        self.assertTrue(command["walk"])
        # chargeGrenade and sneak.
        command = view.command(w, order(4 | 8, 0, 0, 0, 0))
        self.assertTrue(command["chargeGrenade"] and command["sneak"])
        self.assertFalse(command["walk"])
        # A button mask returns the seat to the gamepad protocol.
        command = view.command(w, [b"\x84\x08"])
        self.assertTrue(command["direct"])
        self.assertEqual(command["goal"], dict(x=1100, z=2000))

    def test_bad_wasm_forfeits_its_seat_and_the_episode_still_runs(self):
        import host

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bad = root / "bad"
            bad_data = b"\0asmBAD"
            bad.write_bytes(bad_data)
            good = root / "good"
            good_data = b"idle = 1\n"
            good.write_bytes(good_data)
            seats = []
            for i in range(16):
                path, data = (bad, bad_data) if i == 0 else (good, good_data)
                seats.append(
                    dict(
                        slot=i,
                        file_uri=path.as_uri(),
                        size_bytes=len(data),
                        content_hash="sha256:" + hashlib.sha256(data).hexdigest(),
                        log_uri=(root / f"{i}.log").as_uri(),
                    )
                )
            doc = root / "seats.json"
            doc.write_text(
                json.dumps(
                    dict(
                        schema="coworld-player-seats/1",
                        seats=seats,
                        player_status_uri=(root / "status").as_uri(),
                    )
                )
            )
            failure = root / "failure.json"
            # A stand-in engine: with the bad seat forfeited (not fatal), `run` reaches
            # this subprocess and returns its real exit code instead of raising.
            engine = root / "engine"
            engine.write_text("#!/usr/bin/env python3\nimport sys\nsys.exit(0)\n")
            engine.chmod(0o755)
            with patch.dict(
                os.environ,
                COGAME_PLAYER_SEATS_URI=doc.as_uri(),
                COGAME_PLAYER_FAILURE_URI=failure.as_uri(),
            ):
                self.assertEqual(host.run(str(engine)), 0)
            self.assertEqual(json.loads(failure.read_text())["failed_policy_index"], 0)

    def test_trapping_policy_forfeits_only_its_own_seat(self):
        import host

        class TrappingPolicy:
            def step(self, frame, tick):
                raise RuntimeError("boom")

            def close(self):
                self.closed = True

        with tempfile.TemporaryDirectory() as tmp:
            failure = Path(tmp) / "failure.json"
            policy = TrappingPolicy()
            policies = {3: policy}
            views = {3: SpriteView(3)}
            with patch.dict(os.environ, COGAME_PLAYER_FAILURE_URI=failure.as_uri()):
                host.forfeit_seat(3, "WASM policy failed: RuntimeError", policies, views)
            self.assertNotIn(3, policies)
            self.assertNotIn(3, views)
            self.assertTrue(policy.closed)
            self.assertEqual(json.loads(failure.read_text())["failed_policy_index"], 3)

    def test_wasm_receives_gun_readiness(self):
        view = SpriteView(0)
        view.initial = False
        w = dict(
            cogs=[
                dict(
                    pos=dict(x=500 if i % 2 == 0 else 6000, z=2000),
                    aim=dict(x=0, z=0),
                    hp=3,
                    cooldown=0,
                )
                for i in range(16)
            ],
            cover=[],
            hearts=[dict(pos=dict(x=x, z=2000), carrier=-1) for x in (960, 5440)],
        )
        frame = view.frame(w)
        self.assertIn(b"fire icon", frame)
        self.assertNotIn(b"fire icon cooldown", frame)
        self.assertIn(b"game teams 2 map 1280x800", frame)
        w["cogs"][0]["cooldown"] = 8
        self.assertIn(b"fire icon cooldown", view.frame(w))

    def test_wasm_receives_public_capture_progress_without_changing_owner_label(self):
        view = SpriteView(0)
        view.initial = False
        w = dict(
            cogs=[dict(pos=dict(x=500, z=2000), aim=dict(x=0,z=0), hp=3, cooldown=0)
                  for _ in range(16)],
            cover=[],
            hearts=[dict(pos=dict(x=x,z=2000), carrier=-1) for x in (960,5440)],
            controlHearts=[dict(pos=dict(x=3200,z=2000), owner=-1)],
            heartCaptures=[dict(team=1, ticks=36, contested=True)],
        )
        frame = view.frame(w)
        self.assertIn(b"control heart 0 owner -1", frame)
        self.assertIn(b"control capture 0 team 1 ticks 36 contested 1", frame)
        w["rulesVersion"] = 25
        w["bigHeart"] = 0
        self.assertIn(b"control value 0 points 5", view.frame(w))
        w["bigHeart"] = -1
        self.assertIn(b"control value 0 points 1", view.frame(w))
        del w["heartCaptures"]
        self.assertNotIn(b"control capture", view.frame(w))
        w["controlHearts"].append(dict(pos=dict(x=3400, z=2000), owner=-1))
        w["glory"] = [587, 300]
        self.assertNotIn(b"glory team", view.frame(w))
        w["rulesVersion"] = 36
        frame = view.frame(w)
        self.assertIn(b"glory team 0 value 587", frame)
        self.assertIn(b"glory team 1 value 300", frame)

    def test_sound_sprites_are_listener_relative_and_quiet_chord_is_opt_in(self):
        view = SpriteView(0)
        view.initial = False
        w = dict(tick=20, rulesVersion=26, cover=[],
                 cogs=[dict(pos=dict(x=500,z=2000),aim=dict(x=0,z=0),hp=3,cooldown=0) for _ in range(16)],
                 hearts=[dict(pos=dict(x=x,z=2000),carrier=-1) for x in (960,5440)],
                 sounds=[dict(listener=0,kind=1,direction=7,distance=2,tick=12),
                         dict(listener=1,kind=2,direction=4,distance=0,tick=12),
                         dict(listener=0,kind=3,direction=1,distance=0,tick=-20)])
        frame = view.frame(w)
        self.assertIn(b"sound kind 1 direction 7 distance 2 age 8", frame)
        self.assertNotIn(b"sound kind 2", frame)
        self.assertNotIn(b"sound kind 3", frame)
        w["cogs"][0]["hp"] = 0
        self.assertNotIn(b"sound kind", view.frame(w))
        w["cogs"][0]["hp"] = 3
        # B+Select is the quiet chord; existing single-button aim turns stay unchanged.
        self.assertTrue(view.command(w, [(0x84,80)])["sneak"])
        self.assertFalse(view.command(w, [(0x84,64)])["sneak"])
        w["rulesVersion"] = 25
        self.assertFalse(view.command(w, [(0x84,80)])["sneak"])




ORACLE_REQUEST = b'{"state":"ping","questions":{"q":{"type":"noul","instructions":"Is this a ping?"}}}'
# A minimal seat that asks the oracle once, then reports its state in the actuator byte:
# 0 idle, 1 asked, 2 answered (answer JSON at 8192), 3 failed. It re-asks once idle again.
ORACLE_GUEST = f"""
(module
  (import "paintbot" "oracle_ask" (func $ask (param i32 i32) (result i32)))
  (import "paintbot" "oracle_poll" (func $poll (param i32 i32 i32) (result i32)))
  (memory (export "memory") 1)
  (global $req (mut i32) (i32.const 0))
  (global $state (mut i32) (i32.const 0))
  (data (i32.const 2048) "{ORACLE_REQUEST.decode().replace(chr(34), chr(92) + chr(34))}")
  (func (export "paintbot_init") (param i32))
  (func (export "paintbot_buffer") (param i32) (result i32) (i32.const 16384))
  (func (export "paintbot_output_size") (result i32) (i32.const 10))
  (func (export "paintbot_step") (result i32)
    (local $n i32)
    (if (i32.eqz (global.get $req))
      (then
        (global.set $req (call $ask (i32.const 2048) (i32.const {len(ORACLE_REQUEST)})))
        (if (i32.ne (global.get $req) (i32.const 0)) (then (global.set $state (i32.const 1)))))
      (else
        (local.set $n (call $poll (global.get $req) (i32.const 8192) (i32.const 4096)))
        (if (i32.gt_s (local.get $n) (i32.const 0))
          (then (global.set $state (i32.const 2)) (global.set $req (i32.const 0))))
        (if (i32.lt_s (local.get $n) (i32.const 0))
          (then (global.set $state (i32.const 3)) (global.set $req (i32.const 0))))))
    (i32.store (i32.const 4096) (i32.const 1))
    (i32.store (i32.const 4100) (i32.const 2))
    (i32.store8 (i32.const 4104) (i32.const 132))
    (i32.store8 (i32.const 4105) (global.get $state))
    (i32.const 4096)))
"""


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

    def _policy(self, oracle):
        import wasmtime
        from wasm_policy import Policy

        config = wasmtime.Config()
        config.consume_fuel = True
        config.epoch_interruption = True
        engine = wasmtime.Engine(config)
        policy = Policy(engine, wasmtime.Module(engine, ORACLE_GUEST), 3, oracle)
        self.addCleanup(policy.close)
        return policy

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
        policy = self._policy(oracle)
        self.assertEqual(policy.step(b"frame", tick=0)[0][1], 1)  # asked
        self._settle(oracle)
        self.assertEqual(policy.step(b"frame", tick=1)[0][1], 2)  # answered
        answer = bytes(policy.memory.read(policy.store, 8192, 8192 + 64))
        self.assertTrue(answer.startswith(b'{"q":{"type":"noul","noul":0.9}}'))
        self.assertEqual(seen[0]["model"], "test-model")
        self.assertEqual(seen[0]["questions"]["q"]["type"], "noul")
        self.assertEqual(seen[0]["state"], "ping")
        # Too soon: the ask is refused, the guest stays where it was, and nothing was sent.
        self.assertEqual(policy.step(b"frame", tick=2)[0][1], 2)
        self.assertEqual(len(seen), 1)
        self.assertEqual(policy.step(b"frame", tick=24)[0][1], 1)
        self._settle(oracle)
        self.assertEqual(len(seen), 2)

    def test_slow_endpoint_is_reported_as_failure_without_blocking(self):
        import time

        from oracle import Oracle

        url, _ = self._server(delay=1.5)
        oracle = Oracle(url, deadline=0.3)
        self.addCleanup(oracle.close)
        policy = self._policy(oracle)
        started = time.time()
        self.assertEqual(policy.step(b"frame", tick=0)[0][1], 1)
        self.assertLess(time.time() - started, 0.2, "a step must never wait on the network")
        self._settle(oracle)
        self.assertEqual(policy.step(b"frame", tick=1)[0][1], 3)

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
        policy = self._policy(None)
        for tick in range(3):
            self.assertEqual(policy.step(b"frame", tick=tick)[0][1], 0)

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
                "    f.write(json.dumps({'tick': tick, 'oracle': asks, 'cogs': []}) + '\\n'); f.flush()\n"
                "    r = json.loads(f.readline())\n"
                "    if not isinstance(r, dict): out['replies'].append(r); break\n"
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
                "    f.write(json.dumps({'tick': tick, 'oracle': [], 'cogs': []}) + '\\n'); f.flush()\n"
                "    f.readline()\n"
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
            self.assertEqual(row["request"]["state"], "ping")
            self.assertEqual(row["answers"], {"q": {"type": "noul", "noul": 0.9}})
            self.assertGreaterEqual(row["latency_ms"], 0)

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


if __name__ == "__main__":
    unittest.main()
