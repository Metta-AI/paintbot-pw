## Training-build geometry caches must be invisible: every tabled terrain value and
## every indexed obstacle test equals the direct computation, for every rules version
## that changes the terrain flags, at the arena edges and outside the tabled span.
## Build with --mm:arc --threads:on -d:pwTraining.
import std/[unittest, random]
import ../examples/paintbot/[sim, neural_contract]

when not defined(pwTraining): {.error: "this test exercises the -d:pwTraining caches".}

proc directBlocked(w: World, p: Point, radius: int): bool =
  ## The full scan the index replaces, as it read before the index existed.
  if p.x < minX()+radius or p.z < minZ()+radius or p.x > maxX()-radius or p.z > maxZ()-radius: return true
  if islandTerrain and islandMarginDirect(p.x.int, p.z.int) < radius div 3+40: return true
  for c in w.cover:
    if c.h == 0:
      let r = c.w div 2
      if distance2(p, point(c.x.int+r.int, c.z.int+r.int)) < (r+radius).int64*(r+radius): return true
    elif p.x > c.x-radius and p.x < c.x+c.w+radius and p.z > c.z-radius and p.z < c.z+c.h+radius: return true

proc directLineClear(w: World, a, b: Point): bool =
  ## lineClear as it read before the index and memo existed (game commit 1f89877).
  var rayWorld = w
  rayWorld.cover = @[]
  for c in w.cover:
    let depth = if c.h == 0: c.w else: c.h
    if c.x <= max(a.x,b.x) and c.x+c.w >= min(a.x,b.x) and
        c.z <= max(a.z,b.z) and c.z+depth >= min(a.z,b.z):
      rayWorld.cover.add c
  let startHeight = if visionRulesVersion >= 9: w.elevation(a) else: 0
  let endHeight = if visionRulesVersion >= 9: w.elevation(b) else: 0
  let steps = max(abs(b.x-a.x), abs(b.z-a.z)) div 25 + 1
  for i in 1..steps:
    let p = Point(x: a.x+(b.x-a.x)*i div steps, z: a.z+(b.z-a.z)*i div steps)
    if rayWorld.directBlocked(p, 0): return false
    if visionRulesVersion >= 9:
      let eye = startHeight+120+(endHeight-startHeight)*i.int div steps.int
      if w.elevation(p) > eye: return false
  true
proc directWalkClear(w: World, a,b: Point):bool =
  ## walkClear as it read before the index existed (game commit 1f89877).
  if w.directBlocked(b, Radius) or not w.traversable(a,b):return false
  let dx=(b.x-a.x).float64;let dz=(b.z-a.z).float64
  let length=dx*dx+dz*dz
  for c in w.cover:
    if c.h==0:
      let r=c.w.float64/2
      let cx=c.x.float64+r;let cz=c.z.float64+r
      let t=if length==0:0.0 else:clamp(((cx-a.x.float64)*dx+(cz-a.z.float64)*dz)/length,0.0,1.0)
      let ex=a.x.float64+t*dx-cx;let ez=a.z.float64+t*dz-cz
      if ex*ex+ez*ez<(r+Radius.float64)*(r+Radius.float64):return false
    else:
      let steps=max(abs(b.x-a.x),abs(b.z-a.z)).int div 15+1
      for i in 1..steps:
        let x=a.x.int+(b.x-a.x).int*i div steps
        let z=a.z.int+(b.z-a.z).int*i div steps
        if x>c.x-Radius and x<c.x+c.w+Radius and z>c.z-Radius and z<c.z+c.h+Radius:return false
  let steps=max(abs(b.x-a.x),abs(b.z-a.z)).int div 50+1
  for i in 1..steps:
    let x=a.x.int+(b.x-a.x).int*i div steps
    let z=a.z.int+(b.z-a.z).int*i div steps
    if islandTerrain and islandMarginDirect(x,z)<Radius div 3+40:return false
  true

suite "Training geometry caches":
  test "tabled terrain equals the direct functions everywhere":
    var rng = initRand(2026)
    for version in [9, 12, 14, 16, 22, 29, 33, 35, 37]:
      configureRules(version)
      var checked = 0
      for _ in 0..<20000:
        # Inside the arena, on its edges, and well outside the tabled span.
        let x = case rng.rand(3)
          of 0: rng.rand(minX()..maxX())
          of 1: [minX(), maxX(), -5120, -5121, -5120+264*64-1, -5120+264*64][rng.rand(5)]
          else: rng.rand(-9000..15000)
        let z = case rng.rand(3)
          of 0: rng.rand(minZ()..maxZ())
          of 1: [minZ(), maxZ(), -3072, -3073, -3072+160*64-1, -3072+160*64][rng.rand(5)]
          else: rng.rand(-7000..11000)
        check terrainHeight(x, z) == terrainHeightDirect(x, z)
        check islandMargin(x, z) == islandMarginDirect(x, z)
        let cell = terrainSample(x, z)
        check cell.height.int == terrainHeightDirect(x, z) and cell.margin.int == islandMarginDirect(x, z)
        inc checked
      check checked == 20000
    check terrainCacheResidentBlocks() > 0
  test "indexed obstacle tests equal full scans for every rules version":
    var rng = initRand(37)
    for version in [8, 12, 14, 22, 35, 37]:
      configureRules(version)
      let w = newWorld(int32(version), 240)
      for _ in 0..<4000:
        let p = point(rng.rand(minX()-300..maxX()+300), rng.rand(minZ()-300..maxZ()+300))
        for radius in [0, Radius, 90]:
          check w.blocked(p, radius) == directBlocked(w, p, radius)
      # Rays and walks between random points, cog positions and obstacle rims.
      var spots: seq[Point]
      for c in w.cover: spots.add point(c.x.int+c.w.int div 2, c.z.int+c.w.int div 2+c.w.int div 2+Radius)
      for cog in w.cogs: spots.add cog.pos
      for h in w.controlHearts: spots.add h.pos
      for _ in 0..<3000:
        let a = if rng.rand(1) == 0: spots[rng.rand(spots.high)] else: point(rng.rand(minX()..maxX()), rng.rand(minZ()..maxZ()))
        let b = if rng.rand(1) == 0: spots[rng.rand(spots.high)] else: point(a.x.int+rng.rand(-700..700), a.z.int+rng.rand(-700..700))
        check w.lineClear(a, b) == w.directLineClear(a, b)
        check w.lineClear(a, b) == w.directLineClear(a, b) # memo hit
        check w.walkClear(a, b) == w.directWalkClear(a, b)
  test "navigation memo agrees with a fresh grid and full scans":
    configureRules(37)
    var rng = initRand(11)
    let w = newWorld(5, 240)
    var goals: seq[Point]
    for h in w.controlHearts: goals.add h.pos
    for pk in w.pickups: goals.add pk.pos
    for _ in 0..<200: goals.add point(rng.rand(minX()+100..maxX()-100), rng.rand(minZ()+100..maxZ()-100))
    var first: seq[Point]
    for i in 0..<600:
      let start = w.cogs[i mod Seats].pos
      first.add w.waypoint(start, goals[i mod goals.len])
    # The same queries again (memo and LRU hits) and after a different world (rebuild).
    for i in 0..<600:
      check w.waypoint(w.cogs[i mod Seats].pos, goals[i mod goals.len]) == first[i]
    configureRules(35)
    discard newWorld(9, 240).waypoint(point(100, 100), point(3000, 2000))
    configureRules(37)
    for i in 0..<600:
      check w.waypoint(w.cogs[i mod Seats].pos, goals[i mod goals.len]) == first[i]
  test "host body cache matches per-call resolution":
    configureRules(37)
    let w = newWorld(77, 240)
    for slot in 0..<Seats:
      let bodies = w.observedBodies(slot)
      var actions = [int32(1), int32(1+slot), 1'i32, 0'i32, 0'i32]
      check w.decodeActions(slot, actions) == w.decodeActions(slot, actions, bodies)
      var direct: array[ObservationSize, float32]
      var shared: array[ObservationSize, float32]
      w.encodeObservation(slot, direct)
      w.encodeObservation(slot, shared, bodies)
      check direct == shared
      var a, b: array[ActionSizes.len, int32]
      w.trainingBotActions(slot, 2, a)
      w.trainingBotActions(slot, 2, b, bodies)
      check a == b
