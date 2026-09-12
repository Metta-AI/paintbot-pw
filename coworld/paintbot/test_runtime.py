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

    def test_bad_wasm_is_attributed_before_engine_starts(self):
        import host

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            p = root / "bad"
            data = b"\0asmBAD"
            p.write_bytes(data)
            seats = [
                dict(
                    slot=i,
                    file_uri=p.as_uri(),
                    size_bytes=len(data),
                    content_hash="sha256:" + hashlib.sha256(data).hexdigest(),
                    log_uri=(root / f"{i}.log").as_uri(),
                )
                for i in range(16)
            ]
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
            with patch.dict(
                os.environ,
                COGAME_PLAYER_SEATS_URI=doc.as_uri(),
                COGAME_PLAYER_FAILURE_URI=failure.as_uri(),
            ):
                with self.assertRaises(Exception):
                    host.run("/must-not-start")
            self.assertEqual(json.loads(failure.read_text())["failed_policy_index"], 0)

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


if __name__ == "__main__":
    unittest.main()
