"""Every catalogue map builds, validates, and serialises; the JSON round-trips."""
import base64
import unittest

import numpy as np

import mapgen as g


class MapgenTest(unittest.TestCase):
    def test_catalogue(self):
        for i, (name, title, fn, blurb) in enumerate(g.CATALOGUE):
            with self.subTest(name):
                m = g.build(name, title, fn, blurb, 1000 + i)
                self.assertEqual(g.validate(m), [])
                doc = g.to_json(m)
                h = np.frombuffer(base64.b64decode(doc["grid"]["height"]), "<i2").reshape(g.NZ, g.NX)
                self.assertTrue(np.array_equal(h, m.height))
                self.assertEqual(len(doc["controlHearts"]), 10)
                self.assertEqual(doc["stats"]["reachablePct"] > 80, True)

    def test_train_arenas(self):
        """--layout-scale keeps the standard bounds and shrinks only the land; the committed arenas rebuild
        byte for byte."""
        from pathlib import Path
        engine = Path(__file__).resolve().parents[4] / "examples/paintbot/maps/train"
        i = [n for n, *_ in g.CATALOGUE].index("twin-mesas")
        name, title, fn, blurb = g.CATALOGUE[i]
        try:
            for tag, scale in (("4", 0.5), ("9", 0.3333333333)):
                with self.subTest(tag):
                    g.LAYOUT, g.EXTRA_WEAPONS = scale, 2
                    m = g.build(f"train-arena-{tag}", title, fn, blurb, 8 * 1000 + i)
                    self.assertEqual(g.validate(m), [])
                    doc = g.to_json(m)
                    self.assertEqual(doc["bounds"], [-4800, -2800, 11200, 6800])
                    self.assertEqual(len(doc["pickups"]), 28)
                    self.assertEqual(len(doc["controlHearts"]), 10)
                    self.assertLess(doc["stats"]["landM2"], 7332 * scale * scale * 1.5)
                    self.assertEqual(g.to_binary(m), (engine / f"train-arena-{tag}.pbmap").read_bytes())
        finally:
            g.LAYOUT, g.EXTRA_WEAPONS = 1.0, 0


if __name__ == "__main__":
    unittest.main()
