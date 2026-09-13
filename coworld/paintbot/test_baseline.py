"""Exercise the shipped WASM actuator output against territory sprite frames."""

import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

import wasmtime

sys.path.insert(0, str(Path(__file__).parent / "runtime"))
from sprite import SpriteView, compress_walkability
from wasm_policy import Policy


class TerritoryBaselineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        config = wasmtime.Config()
        config.consume_fuel = True
        config.epoch_interruption = True
        cls.engine = wasmtime.Engine(config)
        path = os.environ.get(
            "PAINTBOT_BASELINE_WASM",
            str(Path(__file__).parent / "players/baseline.wasm"),
        )
        cls.module = wasmtime.Module.from_file(cls.engine, path)
        # Isolate objective selection from terrain: retain the real expanded-map
        # dimensions and origin that put the obsolete CTF goal at (-2400,2000).
        cls.map = compress_walkability(b"\xff" * (3200 * 1920 * 4))

    @classmethod
    def tearDownClass(cls):
        cls.module.close()
        cls.engine.close()

    def exercise(self, slot):
        team = slot % 2
        mirror = 1 if team else -1
        start = dict(x=3200 - 5600 * mirror, z=2000)
        target = dict(x=start["x"], z=3500)
        second = dict(x=start["x"], z=500)
        w = dict(
            rulesVersion=28,
            tick=0,
            cover=[],
            cogs=[
                dict(pos=dict(start), aim=dict(x=3200, z=2000), hp=0, cooldown=0)
                for _ in range(16)
            ],
            hearts=[dict(pos=dict(x=x, z=2000), carrier=-1) for x in (960, 5440)],
            controlHearts=[
                dict(pos=target, owner=-1),
                dict(pos=second, owner=1 - team),
            ],
        )
        w["cogs"][slot]["hp"] = 3
        view = SpriteView(slot)
        policy = Policy(self.engine, self.module, slot)

        def step():
            w["tick"] += 1
            command = view.command(w, policy.step(view.frame(w)))
            p = w["cogs"][slot]["pos"]
            return command, (
                command["goal"]["x"] - p["x"],
                command["goal"]["z"] - p["z"],
            )

        try:
            with (
                patch("sprite.walkability", return_value=self.map),
                patch(
                    "sprite.visible",
                    side_effect=lambda world, observer, other: observer == other,
                ),
            ):
                # Start on the obsolete goal, then integrate only the d-pad in
                # open space. The old binary circles here instead of departing.
                for _ in range(120):
                    command, (dx, dz) = step()
                    p = w["cogs"][slot]["pos"]
                    p["x"] += (dx > 0) * 18 - (dx < 0) * 18
                    p["z"] += (dz > 0) * 18 - (dz < 0) * 18
                p = w["cogs"][slot]["pos"]
                self.assertLess(
                    (p["x"] - target["x"]) ** 2 + (p["z"] - target["z"]) ** 2, 140**2
                )
                # Remain still longer than the full three-second capture and
                # stuck-recovery timers. Turret/fire outputs remain unrestricted.
                for _ in range(90):
                    self.assertEqual(step()[1], (0, 0))
                w["controlHearts"][0]["owner"] = team
                for _ in range(600):
                    command, (dx, dz) = step()
                    p["x"] += (dx > 0) * 18 - (dx < 0) * 18
                    p["z"] += (dz > 0) * 18 - (dz < 0) * 18
                self.assertLess(
                    (p["x"] - second["x"]) ** 2 + (p["z"] - second["z"]) ** 2,
                    140**2,
                    f"must reach the next uncaptured heart: {p}",
                )
        finally:
            policy.close()

    def test_blue_leaves_obsolete_goal_holds_capture_and_retargets(self):
        self.exercise(1)

    def test_red_uses_the_same_territory_contract(self):
        self.exercise(0)


if __name__ == "__main__":
    unittest.main()
