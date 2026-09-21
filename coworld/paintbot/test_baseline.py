"""Exercise the shipped WASM actuator output against territory sprite frames.

The contract: a cog that sees no opponent walks to a heart its team does not own, stands
still inside the capture ring for longer than the capture and progress timers, and once
that heart is its team's moves on to the other. Which of the two hearts it takes first is
the squad rule's business (see players/base.bas), not this test's.
"""

import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

import wasmtime

sys.path.insert(0, str(Path(__file__).parent / "runtime"))
from sprite import SpriteView, compress_walkability
from wasm_policy import Policy

RING = 140


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
        # dimensions and origin.
        cls.map = compress_walkability(b"\xff" * (3200 * 1920 * 4))

    @classmethod
    def tearDownClass(cls):
        cls.module.close()
        cls.engine.close()

    def exercise(self, slot):
        team = slot % 2
        mirror = 1 if team else -1
        start = dict(x=3200 - 5600 * mirror, z=2000)
        hearts = [dict(x=start["x"], z=3500), dict(x=start["x"], z=500)]
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
                dict(pos=hearts[0], owner=-1),
                dict(pos=hearts[1], owner=1 - team),
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

        def integrate(ticks):
            # Only the d-pad moves the cog, in open space, at the engine's pace.
            for _ in range(ticks):
                _, (dx, dz) = step()
                p = w["cogs"][slot]["pos"]
                p["x"] += (dx > 0) * 18 - (dx < 0) * 18
                p["z"] += (dz > 0) * 18 - (dz < 0) * 18

        def inside(heart):
            p = w["cogs"][slot]["pos"]
            return (p["x"] - heart["x"]) ** 2 + (p["z"] - heart["z"]) ** 2 < RING**2

        try:
            with (
                patch("sprite.walkability", return_value=self.map),
                patch(
                    "sprite.visible",
                    side_effect=lambda world, observer, other: observer == other,
                ),
            ):
                integrate(120)
                taken = [i for i, h in enumerate(hearts) if inside(h)]
                self.assertEqual(len(taken), 1, f"must reach a heart: {w['cogs'][slot]['pos']}")
                first = taken[0]
                # Remain still longer than the full three-second capture and
                # stuck-recovery timers. Turret/fire outputs remain unrestricted.
                for _ in range(90):
                    self.assertEqual(step()[1], (0, 0))
                w["controlHearts"][first]["owner"] = team
                integrate(600)
                self.assertTrue(
                    inside(hearts[1 - first]),
                    f"must reach the other heart: {w['cogs'][slot]['pos']}",
                )
        finally:
            policy.close()

    def test_blue_reaches_a_heart_holds_capture_and_retargets(self):
        self.exercise(1)

    def test_red_uses_the_same_territory_contract(self):
        self.exercise(0)


if __name__ == "__main__":
    unittest.main()
