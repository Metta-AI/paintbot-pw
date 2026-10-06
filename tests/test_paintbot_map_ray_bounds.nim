## Generated-map sight rays. The training build's lineClearRay settles most samples on a
## generated map from the sample's grid-cell bounds (maps.cellMaxHeight / cellMinMargin)
## instead of interpolating, and scans trenches only when the ground is above the eye line.
## Both must be invisible: the bounds hold for every point of every cell (edges included), and
## rays on every map, many of them past trenches and across ridges, equal the full scan as it
## read before any geometry cache existed. Runs in the hosted build and in the training build:
## `nim r tests/test_paintbot_map_ray_bounds.nim` and
## `nim r --mm:arc --threads:on -d:pwTraining tests/test_paintbot_map_ray_bounds.nim`.
import std/[unittest, random]
import ../examples/paintbot/sim

proc directBlocked(w: World, p: Point): bool =
  ## blocked(p, 0) as a full scan (radius 0: a sight-line sample).
  if p.x < minX() or p.z < minZ() or p.x > maxX() or p.z > maxZ(): return true
  if islandTerrain and islandMarginDirect(p.x.int, p.z.int) < 40: return true
  for c in w.cover:
    if c.h == 0:
      let r = c.w div 2
      if distance2(p, point(c.x.int+r.int, c.z.int+r.int)) < r.int64*r: return true
    elif p.x > c.x and p.x < c.x+c.w and p.z > c.z and p.z < c.z+c.h: return true

proc directElevation(w: World, p: Point): int =
  ## sim.elevation from the direct terrain function: the ground, 60 lower in a trench.
  result = terrainHeightDirect(p.x.int, p.z.int)
  for t in w.trenches:
    if p.x >= t.x and p.x < t.x+t.w and p.z >= t.z and p.z < t.z+t.h:
      result -= 60
      break

proc directLineClear(w: World, a, b: Point): bool =
  ## lineClear sample by sample, every predicate evaluated in full.
  let startHeight = w.directElevation(a)
  let endHeight = w.directElevation(b)
  let steps = max(abs(b.x-a.x), abs(b.z-a.z)) div 25 + 1
  for i in 1..steps:
    let p = Point(x: a.x+(b.x-a.x)*i div steps, z: a.z+(b.z-a.z)*i div steps)
    if w.directBlocked(p): return false
    let eye = startHeight+120+(endHeight-startHeight)*i.int div steps.int
    if w.directElevation(p) > eye: return false
  true

suite "Generated-map sight rays":
  test "cell bounds hold everywhere in every cell of every map":
    var rng = initRand(4242)
    for name in MapNames:
      configureMap(name)
      for _ in 0..<40000:
        # Anywhere in the grid, on its last row and column, and on cell corners and edges.
        var x = rng.rand(minX()..maxX())
        var z = rng.rand(minZ()..maxZ())
        case rng.rand(3)
        of 0: x = maxX()
        of 1: z = maxZ()
        of 2:
          x = minX() + (x-minX()) div 50 * 50
          z = minZ() + (z-minZ()) div 50 * 50
        else: discard
        let cell = mapCell(x, z)
        check cell >= 0
        check mapHeight(x, z) <= mapCellMaxHeight(cell)
        check mapMargin(x, z) >= mapCellMinMargin(cell)
      check mapCell(minX()-1, minZ()) == -1 and mapCell(minX(), maxZ()+1) == -1
    configureMap("")

  test "rays on every generated map equal the full scan":
    var rng = initRand(77)
    configureRules(48)
    for name in MapNames:
      configureMap(name)
      let w = newWorld(2026, 240)
      var spots: seq[Point]
      for t in w.trenches:
        spots.add point(t.x.int, t.z.int)
        spots.add point(t.x.int+t.w.int div 2, t.z.int+t.h.int div 2)
        spots.add point(t.x.int+t.w.int-1, t.z.int+t.h.int-1)
      for c in w.cover: spots.add point(c.x.int+c.w.int div 2, c.z.int+c.w.int+Radius)
      for cog in w.cogs: spots.add cog.pos
      for h in w.controlHearts: spots.add h.pos
      for p in w.pickups: spots.add p.pos
      var clear = 0
      for _ in 0..<3000:
        let a = if rng.rand(1) == 0: spots[rng.rand(spots.high)] else: point(rng.rand(minX()..maxX()), rng.rand(minZ()..maxZ()))
        let reach = [200, 900, 4000][rng.rand(2)]
        let b = if rng.rand(1) == 0: spots[rng.rand(spots.high)]
                else: point(clamp(a.x.int+rng.rand(-reach..reach), minX(), maxX()), clamp(a.z.int+rng.rand(-reach..reach), minZ(), maxZ()))
        let got = w.lineClear(a, b)
        check got == w.directLineClear(a, b)
        if got: inc clear
      # Both outcomes are exercised on every map.
      check clear > 0 and clear < 3000
    configureMap("")
