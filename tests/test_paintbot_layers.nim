import std/[unittest, deques, sets]
import ../examples/paintbot/sim
suite "Layered village":
  setup: visionRulesVersion = 9
  test "terraces, ramps and lower lane have symmetric elevations":
    check terrainHeight(1550, 720) == 250
    check terrainHeight(800, 900) == 125
    check terrainHeight(2550, 2000) == -150
    check terrainHeight(3200, 2000) == 0
    for x in countup(0, 6400, 100):
      for z in countup(0, 4000, 100):
        check terrainHeight(x, z) == terrainHeight(6400-x, 4000-z)
  test "cliffs block travel but ramps connect the terrace":
    let w = newWorld(2026)
    check not w.traversable(point(1700, 195), point(1700, 215))
    check w.traversable(point(600, 900), point(1000, 900))
    check w.traversable(point(2200, 900), point(2800, 900))
  test "terrain occludes sight through the raised bank":
    var w = newWorld(2026)
    w.cover = @[]
    check not w.lineClear(point(1700, 100), point(1700, 1350))
    check w.lineClear(point(2800, 1500), point(2800, 2300))
  test "all pickups and homes remain reachable via ramps":
    let w = newWorld(2026)
    var visited: HashSet[(int, int)]
    var q: Deque[(int, int)]
    q.addLast((19, 40)); visited.incl((19, 40))
    while q.len > 0:
      let p = q.popFirst()
      for d in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
        let n = (p[0]+d[0], p[1]+d[1])
        if n in visited or w.blocked(point(n[0]*50, n[1]*50)): continue
        if not w.traversable(point(p[0]*50, p[1]*50), point(n[0]*50, n[
            1]*50)): continue
        visited.incl(n); q.addLast(n)
    for p in w.pickups: check (p.pos.x.int div 50, p.pos.z.int div 50) in visited
    check (home(1).x.int div 50, home(1).z.int div 50) in visited

  test "height advantage narrows spread and uphill widens it":
    visionRulesVersion = 10
    var w = newWorld(2026)
    w.trenches = @[]
    check w.gunSpreadPercent(point(1550,720), point(500,720)) == 50
    check w.gunSpreadPercent(point(500,720), point(1550,720)) == 150
    check w.gunSpreadPercent(point(800,900), point(500,900)) == 69
    check w.gunSpreadPercent(point(500,720), point(500,900)) == 100
    visionRulesVersion = 9
    check w.gunSpreadPercent(point(1550,720), point(500,720)) == 100
