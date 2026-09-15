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
    visionRulesVersion = 33
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

  test "water quarters movement from rules 30 and dry land restores speed":
    for rules in [29, 30]:
      for direct in [false, true]:
        for sneak in [false, true]:
          visionRulesVersion = rules
          var w = newWorld(2026)
          w.cover = @[]
          w.trenches = @[]
          w.pickups = @[]
          for i in 0..<Seats:
            w.cogs[i].pos = point(-2000+i*150, -2000)
            w.cogs[i].goal = w.cogs[i].pos
          for x in [riverCenter(0), riverCenter(0)+RiverBankWidth]:
            let start = point(x, 0)
            w.cogs[0].pos = start
            check (terrainHeight(x, 0) < RiverWaterHeight) == (x == riverCenter(0))
            var commands: array[Seats, Command]
            commands[0] = Command(walk:true, direct:direct, sneak:sneak, goal:point(x, 1000))
            w.step(commands)
            var expected = if sneak: MoveSpeed div 2 else: MoveSpeed
            if rules >= 30 and x == riverCenter(0): expected = expected div 4
            check w.cogs[0].pos == point(x, expected)

  test "curved river ends inland with a dry northern route":
    visionRulesVersion = 31
    let w = newWorld(2026)
    check riverCenter(-1700) == 1900
    check riverCenter(1700) == 4500
    check riverBlend(riverCenter(2600),2600) == 1000
    for x in countup(0,6400,100):
      check riverBlend(x,3500) == 0
    for z in [-1500, 0, 1700, 2600]:
      check terrainHeight(riverCenter(z),z) == RiverBedHeight
    # The rounded headwater shallows gradually and remains traversable.
    let x = riverCenter(2600)
    for z in countup(2600,3500,20):
      check w.traversable(point(x,z),point(x,z+20))

  test "fractal river has narrow separated coastal channels":
    visionRulesVersion = 32
    discard newWorld(2026)
    for z in [3500, 4500, 5500]:
      for x in countup(0,6400,100): check riverBlend(x,z) == 0
    var channels = 0
    var wet = false
    for x in countup(0,6400,10):
      let nextWet = riverBlend(x,-2100)>0 and terrainHeight(x,-2100)<RiverWaterHeight
      if nextWet and not wet: inc channels
      wet = nextWet
    check channels == 3
    # The primary estuary is narrower than the channel through the village.
    check riverBlend(riverCenter(-2100)+500,-2100) == 0
    check riverBlend(riverCenter(0)+500,0) > 0

  test "lake is enclosed inland and retains quarter-speed water":
    visionRulesVersion = 33
    var w = newWorld(2026)
    check lakeTerrain
    check terrainHeight(3200,2000) == RiverBedHeight
    # A dry ring separates the lake from every coast; no river mouth remains.
    for x in countup(1000,5500,50):
      check riverBlend(x,400) == 0
      check riverBlend(x,3600) == 0
    for z in countup(400,3600,50):
      check riverBlend(1000,z) == 0
      check riverBlend(5500,z) == 0
    w.cover = @[]
    w.trenches = @[]
    w.pickups = @[]
    w.cogs[0].pos = point(3200,2000)
    var commands: array[Seats,Command]
    commands[0] = Command(walk:true,direct:true,goal:point(3200,2500))
    w.step(commands)
    check w.cogs[0].pos == point(3200,2007)
    visionRulesVersion = 32
    discard newWorld(2026)
    check not lakeTerrain
