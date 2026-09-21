## Heartwick is a two-team map that is meant to be fair under a half turn: every static
## feature a policy can exploit (ground, water, cover, trenches, supplies, hearts) must have
## an exact mirror. Rules 35 make that true; this suite states it.
import std/[unittest, sets, algorithm, sequtils]
import ../examples/paintbot/sim

proc mirror(x, z: int): (int, int) = (6400-x, 4000-z)

proc mismatches(points: seq[(int, int)]): int =
  let all = points.toHashSet
  for p in points:
    if mirror(p[0], p[1]) notin all: inc result

suite "Heartwick half-turn symmetry":
  setup:
    visionRulesVersion = 35

  test "terrain height, water and coast mirror exactly":
    discard newWorld(2026)
    var bad = 0
    for x in countup(-4800, 11200, 40):
      for z in countup(-2800, 6800, 40):
        let m = mirror(x, z)
        if terrainHeight(x, z) != terrainHeight(m[0], m[1]): inc bad
        elif riverBlend(x, z) != riverBlend(m[0], m[1]): inc bad
        elif islandMargin(x, z) != islandMargin(m[0], m[1]): inc bad
    check bad == 0

  test "cover, trenches, supplies and hearts mirror exactly":
    let w = newWorld(2026)
    var circles, rects, trenches, pickups, hearts: seq[(int, int)]
    for c in w.cover:
      if c.h == 0: circles.add((c.x.int*2+c.w.int, c.z.int*2+c.w.int))   # doubled centre
      else: rects.add((c.x.int*2+c.w.int, c.z.int*2+c.h.int))
    for t in w.trenches: trenches.add((t.x.int*2+t.w.int, t.z.int*2+t.h.int))
    for p in w.pickups: pickups.add((p.pos.x.int*2, p.pos.z.int*2))
    for h in w.controlHearts: hearts.add((h.pos.x.int*2, h.pos.z.int*2))
    proc mirror2(points: seq[(int, int)]): int =
      let all = points.toHashSet
      for p in points:
        if (12800-p[0], 8000-p[1]) notin all: inc result
    check mirror2(circles) == 0
    check mirror2(rects) == 0
    check mirror2(trenches) == 0
    check mirror2(pickups) == 0
    check mirror2(hearts) == 0
    # Same kinds of supply at mirrored spots.
    var kinds: seq[(int, int, int)]
    for p in w.pickups: kinds.add((p.pos.x.int, p.pos.z.int, p.kind.ord))
    let kindSet = kinds.toHashSet
    var kindBad = 0
    for k in kinds:
      if (6400-k[0], 4000-k[1], k[2]) notin kindSet: inc kindBad
    check kindBad == 0

  test "rules 34 keeps its old, asymmetric terrain":
    visionRulesVersion = 34
    discard newWorld(2026)
    check terrainHeight(1950, 650) != terrainHeight(4450, 3350)
    check mismatches(@[(0, 0)]) == 1  # sanity: the helper reports a lone point
