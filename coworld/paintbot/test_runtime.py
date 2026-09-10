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
from sprite import SpriteView
from wasm_policy import decode_replies, verified_policy


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
                dict(pos=dict(x=500 if i % 2 == 0 else 6000, z=2000), hp=3, cooldown=0)
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


if __name__ == "__main__":
    unittest.main()
