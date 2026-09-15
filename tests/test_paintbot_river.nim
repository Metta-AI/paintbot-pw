import std/[unittest, sets, deques]
import ../examples/paintbot/sim

suite "Heartwick river":
  setup:
    visionRulesVersion = 29

  test "shallow river winds across the island with traversable banks":
    let w = newWorld(2026)
    check riverCenter(800) != riverCenter(3200)
    for z in countup(-1800, 5800, 100):
      let x = riverCenter(z)
      check terrainHeight(x,z) == RiverBedHeight
      check RiverWaterHeight-terrainHeight(x,z) == 38
    # Full crossings away from the village's existing terrace cliffs.
    for z in [-1800, -1000, 0, 2000, 4500, 5800]:
      let x = riverCenter(z)
      for dx in countup(-RiverBankWidth, RiverBankWidth-20, 20):
        check w.traversable(point(x+dx,z),point(x+dx+20,z))
    for tree in forestLots():
      check riverBlend(tree.x,tree.z) == 0

  test "every objective remains reachable across the river":
    for seed in [1'i32, 2026, 930220186]:
      let w = newWorld(seed)
      var seen: HashSet[(int,int)]
      var queue: Deque[(int,int)]
      let start = (w.cogs[0].pos.x.int div 50,w.cogs[0].pos.z.int div 50)
      seen.incl(start)
      queue.addLast(start)
      while queue.len>0:
        let p=queue.popFirst()
        for d in [(1,0),(-1,0),(0,1),(0,-1)]:
          let n=(p[0]+d[0],p[1]+d[1])
          if n in seen or w.blocked(point(n[0]*50,n[1]*50)):continue
          if not w.traversable(point(p[0]*50,p[1]*50),point(n[0]*50,n[1]*50)):continue
          seen.incl(n)
          queue.addLast(n)
      for h in w.controlHearts:
        check (h.pos.x.int div 50,h.pos.z.int div 50) in seen
      for p in w.pickups:
        check (p.pos.x.int div 50,p.pos.z.int div 50) in seen

  test "loading old rules removes the river and restores the old terrain":
    discard newWorld(2026)
    check terrainHeight(3200,2000) == RiverBedHeight
    visionRulesVersion=28
    discard newWorld(2026)
    check not riverTerrain
    check terrainHeight(3200,2000) != RiverBedHeight
