## Rules 38: the navigator measures time, not distance. A cog in the lake moves at a quarter of its
## speed, and before rules 38 a cog on dry land walked straight across it whenever no wall was in
## the way. Replaying 60 games against the league leader, 73% of the shipped build's deaths came
## in that water. These tests walk one cog across the lake and check where it goes.
import std/[unittest]
import ../examples/paintbot/[sim, topography]

proc wet(p: Point): bool =
  riverBlend(p.x.int, p.z.int) > 0 and terrainHeight(p.x.int, p.z.int) < RiverWaterHeight

proc lakeCrossing(w: World): (Point, Point) =
  ## Two dry, open points on either side of the lake, the straight line between them wet.
  var minx, minz = high(int)
  var maxx, maxz = low(int)
  var z = minZ() + 100
  while z < maxZ() - 100:
    var x = minX() + 100
    while x < maxX() - 100:
      if wet(point(x, z)):
        minx = min(minx, x); maxx = max(maxx, x); minz = min(minz, z); maxz = max(maxz, z)
      x += 100
    z += 100
  doAssert minx <= maxx, "no lake on this map"
  let midz = (minz + maxz) div 2
  var a = point(minx - 600, midz)
  var b = point(maxx + 600, midz)
  doAssert not wet(a) and not wet(b) and not w.blocked(a) and not w.blocked(b)
  (a, b)

proc walk(version: int, a, b: Point, maxTicks = 2400): tuple[wetTicks, ticks: int, arrived: bool] =
  configureRules(version)
  var w = newWorld(4)
  for i in 0..<Seats:
    w.cogs[i].hp = 0; w.cogs[i].respawn = 100000
  w.cogs[0].hp = 3; w.cogs[0].pos = a; w.cogs[0].goal = a
  var commands: array[Seats, Command]
  commands[0].walk = true; commands[0].goal = b
  while result.ticks < maxTicks:
    w.step(commands, version)
    inc result.ticks
    if wet(w.cogs[0].pos): inc result.wetTicks
    if distance2(w.cogs[0].pos, b) <= 200'i64 * 200:
      result.arrived = true; break

suite "Rules 38 dry navigation":
  test "rules 37 walks straight through the lake; rules 38 goes around and still arrives":
    configureRules(38)
    let (a, b) = lakeCrossing(newWorld(4))
    let before = walk(37, a, b)
    let after = walk(38, a, b)
    check before.arrived
    check after.arrived
    check before.wetTicks > 0
    # A dry way round exists, so the rules 38 route should not wade at all, and should be quicker
    # than wading - the point of measuring time instead of distance.
    check after.wetTicks == 0
    check after.ticks < before.ticks

  test "a cog already in the lake is never stranded":
    configureRules(38)
    let (a, b) = lakeCrossing(newWorld(4))
    var inside = point((a.x + b.x) div 2, a.z)
    check wet(inside)
    let r = walk(38, inside, b)
    check r.arrived

  test "the same route twice gives the same path":
    configureRules(38)
    let (a, b) = lakeCrossing(newWorld(4))
    check walk(38, a, b) == walk(38, a, b)
