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
            return view.command(w, policy.step(view.frame(w)))

        def integrate(ticks):
            # Walk toward the ordered goal in open space at the engine's pace; the policy
            # gives direct orders (walkTo), so the goal is a destination, not a direction.
            for _ in range(ticks):
                command = step()
                self.assertFalse(command["direct"], "orders must use the engine's pathing")
                p = w["cogs"][slot]["pos"]
                dx = command["goal"]["x"] - p["x"]
                dz = command["goal"]["z"] - p["z"]
                length = (dx * dx + dz * dz) ** 0.5
                if length > 18:
                    dx, dz = dx * 18 / length, dz * 18 / length
                p["x"] += int(dx)
                p["z"] += int(dz)

        def inside(heart, point=None):
            p = point or w["cogs"][slot]["pos"]
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
                # Stay in the ring longer than the full three-second capture and
                # stuck-recovery timers: every order keeps the cog inside it.
                for _ in range(90):
                    command = step()
                    self.assertTrue(inside(hearts[first]))
                    goal = dict(x=command["goal"]["x"], z=command["goal"]["z"])
                    self.assertTrue(inside(hearts[first], goal), f"walked off: {goal}")
                    integrate(1)
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
