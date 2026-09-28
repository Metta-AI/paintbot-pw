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


if __name__ == "__main__":
    unittest.main()
