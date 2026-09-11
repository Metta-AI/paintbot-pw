import village, topography
export topography
## Integer-only Paintbot simulation; Polyworld RNG and portable state hashes.
import polyworld/[rngs, hashes]
import std/[tables, math]

const
  Seats* = 16
  TickRate* = 24
  MatchTicks* = 5*60*TickRate
  Width* = 6400
  Height* = 4000
  Radius* = 55
  MoveSpeed* = 28
  FireCooldownTicks* = TickRate
  ShotSpeed* = 100
  ShotRange* = 1800
  VisionRange* = 2000
  RespawnTicks* = 72
  CaptureTarget* = 3
  HeartCaptureTicks* = 3 * TickRate
  BigHeartInterval* = 30 * TickRate
  BigHeartPoints* = 5
  SpawnTemperature* = 1000
  HeartSpawnRadius* = 350
  # Compile-time exponential table keeps native/WASM sampling integer-only.
  # Scores are quantized to 10 world units (1% of the temperature).
  SpawnWeights = block:
    var weights: array[1601, int32]
    for i in 0..1600:
      weights[i] = int32(exp(-float(i) / 100.0) * 1000000.0)
    weights

type
  Point* = object
    x*, z*: int32
  Cover* = object
    x*, z*, w*, h*: int32
  Cog* = object
    pos*, goal*: Point
    hp*, respawn*, cooldown*, shield*: int32
    carrying*: bool
    aim*: Point
    firing*: bool
    tags*, captures*: int32
  Paintball* = object
    pos*, velocity*: Point
    owner*, life*: int32
  Heart* = object
    pos*: Point
    carrier*: int32 # -1 on ground
    returnAt*: int32
  PickupKind* = enum
    grenadePickup, sprayPickup, medkitPickup, armorPickup
  Pickup* = object
    pos*: Point
    kind*: PickupKind
    readyAt*: int32
  Equipment* = object
    grenade*, sprayCan*: bool
    charge*, armor*, lives*, burst*, sprayCooldown*, windup*: int32
    sprayAim*, gunAim*: Point
    sprayHits*: uint32
  Lob* = object
    start*, target*: Point
    owner*, releasedAt*, landsAt*: int32
  Blast* = object
    pos*: Point
    tick*, owner*, trench*: int32
  ControlHeart* = object
    pos*: Point
    owner*: int32 # -1 neutral, 0 Ember, 1 Azure
  HeartCapture* = object
    team*: int32 # -1 when idle
    ticks*: int32
    contested*: bool
  World* = object
    seed*, tick*: int32
    rng*: Rng
    cogs*: array[Seats, Cog]
    hearts*: array[2, Heart]
    captures*: array[2, int32]
    cover*: seq[Cover]
    balls*: seq[Paintball]
    winner*: int32 # -1 before a capture victory
    equipment*: array[Seats, Equipment]
    trenches*: seq[Cover]
    pickups*: seq[Pickup]
    grenades*: seq[Lob]
    blasts*: seq[Blast]
    controlHearts*: seq[ControlHeart]
    scoreTicks*: array[2, int32] # One point = TickRate units, no floating-point drift.
    endTick*: int32
    heartCaptures*: seq[HeartCapture]
    bigHeart*: int32 # -1 until 30 seconds, or after all hearts have been used
    bigHeartRound*: int32
    usedBigHearts*: seq[bool]
  TerritoryWorld = object
    seed*, tick*: int32
    rng*: Rng
    cogs*: array[Seats, Cog]
    hearts*: array[2, Heart]
    captures*: array[2, int32]
    cover*: seq[Cover]
    balls*: seq[Paintball]
    winner*: int32 # -1 before a capture victory
    equipment*: array[Seats, Equipment]
    trenches*: seq[Cover]
    pickups*: seq[Pickup]
    grenades*: seq[Lob]
    blasts*: seq[Blast]
    controlHearts*: seq[ControlHeart]
  CombatWorld = object
    seed*, tick*: int32
    rng*: Rng
    cogs*: array[Seats, Cog]
    hearts*: array[2, Heart]
    captures*: array[2, int32]
    cover*: seq[Cover]
    balls*: seq[Paintball]
    winner*: int32 # -1 before a capture victory
    equipment*: array[Seats, Equipment]
    trenches*: seq[Cover]
    pickups*: seq[Pickup]
    grenades*: seq[Lob]
    blasts*: seq[Blast]
  Command* = object
    walk*, shoot*, direct*: bool
    goal*, aim*: Point
    chargeGrenade*: bool

proc point*(x, z: int): Point = Point(x: int32(x), z: int32(z))
proc team*(slot: int): int = slot mod 2
proc home*(side: int): Point = point(if side ==
    0: Width*15 div 100 else: Width*85 div 100, Height div 2)
proc distance2*(a, b: Point): int64 =
  let x = int64(a.x)-b.x; let z = int64(a.z)-b.z
  x*x+z*z
proc isqrt(n: int64): int64 =
  var x = n; var y = (x+1) div 2
  while y < x: x = y; y = (x+n div x) div 2
  x
proc direction*(a, b: Point, speed: int): Point =
  let d = isqrt(distance2(a, b))
  if d == 0: return
  result.x = int32((int64(b.x)-a.x)*speed.int64 div d)
  result.z = int32((int64(b.z)-a.z)*speed.int64 div d)
var visionRulesVersion* = 25
proc minX*():int = (if visionRulesVersion>=22: -4800 elif visionRulesVersion>=14: -2800 elif visionRulesVersion>=12: -800 else: 0)
proc minZ*():int = (if visionRulesVersion>=22: -2800 elif visionRulesVersion>=14: -1200 elif visionRulesVersion>=12: -400 else: 0)
proc maxX*():int = Width-minX()
proc maxZ*():int = Height-minZ()
proc elevation*(w: World, p: Point): int =
  if visionRulesVersion < 9: return 0
  result = terrainHeight(p.x.int, p.z.int)
  for t in w.trenches:
    if p.x >= t.x and p.x < t.x+t.w and p.z >= t.z and p.z < t.z+t.h:
      result -= 60
      break
proc traversable*(w: World, a, b: Point): bool =
  if visionRulesVersion < 9: return true
  let steps = max(abs(b.x-a.x), abs(b.z-a.z)).int div 20+1
  var last = terrainHeight(a.x.int, a.z.int)
  for i in 1..steps:
    let x = a.x.int+(b.x-a.x).int*i div steps
    let z = a.z.int+(b.z-a.z).int*i div steps
    let h = terrainHeight(x, z)
    if abs(h-last) > 25: return false
    last = h
  true
proc blocked*(w: World, p: Point, radius = Radius): bool =
  if p.x < minX()+radius or p.z < minZ()+radius or p.x > maxX()-radius or p.z >
      maxZ()-radius: return true
  if islandTerrain and islandMargin(p.x.int,p.z.int)<radius div 3+40: return true
  for c in w.cover:
    if c.h == 0:
      let r = c.w div 2
      if distance2(p, point(c.x.int+r.int, c.z.int+r.int)) < (r+radius).int64*(
          r+radius): return true
      continue
    if p.x > c.x-radius and p.x < c.x+c.w+radius and p.z > c.z-radius and p.z <
        c.z+c.h+radius: return true
proc lineClear*(w: World, a, b: Point): bool =
  # Only obstacles overlapping the ray bounds can block its sampled points.
  # Keep the exact sample positions and collision predicates for replay parity.
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
    if rayWorld.blocked(p, 0): return false
    if visionRulesVersion >= 9:
      let eye = startHeight+120+(endHeight-startHeight)*i.int div steps.int
      if w.elevation(p) > eye: return false
  true
proc canSeePoint*(w: World, slot: int, p: Point): bool =
  if slot notin 0..<Seats or w.cogs[slot].hp <= 0: return false
  let c = w.cogs[slot]
  let distance = distance2(c.pos, p)
  if visionRulesVersion < 5 and distance >
      VisionRange.int64*VisionRange: return false
  if visionRulesVersion >= 4 and distance > 0:
    let facing = if c.aim == Point(): home(1-team(slot)) else: c.aim
    let fx = int64(facing.x)-c.pos.x
    let fz = int64(facing.z)-c.pos.z
    let dx = int64(p.x)-c.pos.x
    let dz = int64(p.z)-c.pos.z
    let dot = fx*dx+fz*dz
    if dot <= 0 or 4*dot*dot < (fx*fx+fz*fz)*distance: return false
  w.lineClear(c.pos, p)
proc visible*(w: World, slot, other: int): bool =
  if slot notin 0..<Seats or other notin 0..<Seats or w.cogs[other].hp <= 0:
    return false
  if slot == other: return true
  if visionRulesVersion < 4 and team(slot) == team(other): return true
  w.canSeePoint(slot, w.cogs[other].pos)
proc occupied(w: World, p: Point, slot: int): bool =
  for other in 0..<Seats:
    if other != slot and w.cogs[other].hp > 0 and
        distance2(p, w.cogs[other].pos) < (2*Radius).int64*(2*Radius):
      return true
proc movementBlocked(w: World, p: Point, slot: int, solid: bool): bool =
  w.blocked(p) or (solid and w.occupied(p, slot)) or
    (distance2(w.cogs[slot].pos, p) < 10000 and not w.traversable(w.cogs[
        slot].pos, p))
proc sampleSpawnHeart*(w: var World, slot: int): int =
  ## Softmax of summed distances to living teammates; larger sums are favored.
  var candidates: seq[int]
  var scores: seq[int64]
  var maximum = 0'i64
  for index, heart in w.controlHearts:
    if heart.owner != team(slot).int32: continue
    var score = 0'i64
    for other, cog in w.cogs:
      if other != slot and team(other) == team(slot) and cog.hp > 0:
        score += isqrt(distance2(cog.pos, heart.pos))
    candidates.add index
    scores.add score
    maximum = max(maximum, score)
  if candidates.len == 0: return -1
  var weights: seq[int32]
  var total = 0'i32
  for score in scores:
    let bucket = min(1600'i64, (maximum-score) * 100 div SpawnTemperature)
    let weight = SpawnWeights[bucket.int]
    weights.add weight
    total += weight
  var draw = w.rng.below(total)
  for i, weight in weights:
    if draw < weight: return candidates[i]
    draw -= weight
  candidates[^1]

proc spawnAtHeart(w: var World, slot: int): bool =
  let heart = w.sampleSpawnHeart(slot)
  if heart < 0: return false
  let origin = w.controlHearts[heart].pos
  # Search only near the selected heart. If crowded, retry next tick.
  for attempt in 0..<128:
    let p = point(origin.x.int+w.rng.between(-HeartSpawnRadius, HeartSpawnRadius).int,
        origin.z.int+w.rng.between(-HeartSpawnRadius, HeartSpawnRadius).int)
    if distance2(origin, p) > HeartSpawnRadius*HeartSpawnRadius: continue
    if w.blocked(p) or w.occupied(p, slot) or not w.traversable(origin, p): continue
    w.cogs[slot].pos = p; w.cogs[slot].goal = p
    w.cogs[slot].hp = 3; w.cogs[slot].shield = 36
    w.cogs[slot].firing = false; w.cogs[slot].carrying = false
    return true

proc spawn(w: var World, slot: int, solid = true) =
  var p = point(if team(slot) == 0: 350+(slot div 2 mod 2)*160 else: Width-350-(
      slot div 2 mod 2)*160,
    1100+(slot div 4)*550)
  if solid and w.movementBlocked(p, slot, true):
    let origin = p
    var found = false
    block search:
      for ring in 1..20:
        for dz in -ring..ring:
          for dx in -ring..ring:
            if abs(dx) != ring and abs(dz) != ring: continue
            let candidate = point(origin.x.int+dx*(2*Radius+2),
                origin.z.int+dz*(2*Radius+2))
            if not w.movementBlocked(candidate, slot, true):
              p = candidate
              found = true
              break search
    if not found: return # Retry next tick rather than overlap a living cog.
  w.cogs[slot].pos = p; w.cogs[slot].goal = p
  w.cogs[slot].hp = 3; w.cogs[slot].shield = 36
  w.cogs[slot].firing = false; w.cogs[slot].carrying = false
proc resetHeart*(w: var World, side: int) =
  w.hearts[side] = Heart(pos: home(side), carrier: -1)
proc initializeEquipment(w: var World)
proc newWorld*(seed: int32, endTick: int32 = MatchTicks): World =
  wideRamps = visionRulesVersion >= 11
  wilderness = visionRulesVersion >= 12
  deepWilderness = visionRulesVersion >= 14
  organicTerrain = visionRulesVersion >= 15
  islandTerrain = visionRulesVersion >= 16
  expandedIsland = visionRulesVersion >= 22
  result.endTick = endTick
  result.seed = seed; result.rng = initRng(seed); result.winner = -1
  if visionRulesVersion >= 8:
    for lot in roundVillage():
      result.cover.add Cover(x: (lot.x-lot.radius).int32,
          z: (lot.z-lot.radius).int32, w: (lot.radius*2).int32, h: 0)
  elif visionRulesVersion >= 7:
    for lot in VillageLots:
      result.cover.add Cover(x: lot.x.int32, z: lot.z.int32,
          w: lot.w.int32, h: lot.h.int32)
      result.cover.add Cover(x: (Width-lot.x-lot.w).int32,
          z: (Height-lot.z-lot.h).int32, w: lot.w.int32, h: lot.h.int32)
    result.cover.add Cover(x: 3090, z: 1890, w: 220, h: 220)
  else:
    # Symmetric lanes and bunkers leave all homes reachable.
    for x in [1500, 2600]:
      let shift = result.rng.between(-100, 100)
      for z in [650, 1650, 2850]:
        let c = Cover(x: x.int32, z: z.int32+shift, w: 260, h: 420)
        result.cover.add c
        result.cover.add Cover(x: Width.int32-c.x-c.w, z: Height.int32-c.z-c.h,
            w: c.w, h: c.h)
  for side in 0..1: result.resetHeart(side)
  if visionRulesVersion < 24:
    for i in 0..<Seats: result.spawn(i)
  if wilderness:
    for p in [point(-620,300),point(-620,1700),point(-620,3500),point(1200,-320),point(3100,-320),point(5400,-320)]:
      for q in [p,point(6400-p.x.int,4000-p.z.int)]:
        result.cover.add Cover(x:q.x-65,z:q.z-65,w:130,h:0)
  if deepWilderness:
    for lot in forestLots():
      result.cover.add Cover(x:(lot.x-lot.radius).int32,z:(lot.z-lot.radius).int32,w:(2*lot.radius).int32,h:0)
  if visionRulesVersion >= 6: result.initializeEquipment()
  if visionRulesVersion >= 24:
    for i in 0..<Seats:
      discard result.spawnAtHeart(i)
  result.bigHeart = -1
  if visionRulesVersion >= 25:
    result.usedBigHearts = newSeq[bool](result.controlHearts.len)

proc heartPoints*(w: World, index: int): int32 =
  if visionRulesVersion >= 25 and w.bigHeart == index.int32: BigHeartPoints else: 1

proc scores*(w: World): seq[float] =
  for i in 0..<Seats:
    result.add (if visionRulesVersion >= 23: w.scoreTicks[team(i)].float / TickRate.float else: float(if visionRulesVersion >= 20 and w.winner >= 0: (if w.winner == team(i).int32: 10 else: 0) elif visionRulesVersion>=13:w.captures[team(i)].int else:int(w.winner == team(i).int32)))
type LegacyWorld = object
  seed, tick: int32
  rng: Rng
  cogs: array[Seats, Cog]
  hearts: array[2, Heart]
  captures: array[2, int32]
  cover: seq[Cover]
  balls: seq[Paintball]
  winner: int32
proc stateHash*(w: World): uint32 =
  if visionRulesVersion >= 25: return hashy(w)
  if visionRulesVersion >= 13:
    result = hashy(TerritoryWorld(seed:w.seed,tick:w.tick,rng:w.rng,cogs:w.cogs,
      hearts:w.hearts,captures:w.captures,cover:w.cover,balls:w.balls,winner:w.winner,
      equipment:w.equipment,trenches:w.trenches,pickups:w.pickups,grenades:w.grenades,
      blasts:w.blasts,controlHearts:w.controlHearts))
    if visionRulesVersion >= 23:
      result.addHashy(w.scoreTicks)
      result.addHashy(w.endTick)
    if visionRulesVersion >= 24:
      result.addHashy(w.heartCaptures)
    return
  if visionRulesVersion >= 6:
    return hashy(CombatWorld(seed:w.seed,tick:w.tick,rng:w.rng,cogs:w.cogs,
      hearts:w.hearts,captures:w.captures,cover:w.cover,balls:w.balls,winner:w.winner,
      equipment:w.equipment,trenches:w.trenches,pickups:w.pickups,grenades:w.grenades,blasts:w.blasts))
  hashy(LegacyWorld(seed: w.seed, tick: w.tick, rng: w.rng, cogs: w.cogs,
      hearts: w.hearts, captures: w.captures, cover: w.cover, balls: w.balls,
      winner: w.winner))
proc dropHeart(w: var World, slot: int) =
  if not w.cogs[slot].carrying: return
  let enemy = 1-team(slot)
  w.hearts[enemy] = Heart(pos: w.cogs[slot].pos, carrier: -1,
      returnAt: w.tick+240)
  w.cogs[slot].carrying = false
# Optional spectator instrumentation lives outside World and its hash.
var observeHit*: proc(tick: int32, victim, attacker: int,
    pos: Point) {.closure.}
var observeTag*: proc(tick: int32, victim, attacker: int,
    pos: Point) {.closure.}
proc hit*(w: var World, victim, attacker: int) =
  if w.cogs[victim].hp <= 0 or w.cogs[victim].shield > 0: return
  if observeHit != nil: observeHit(w.tick, victim, attacker, w.cogs[victim].pos)
  dec w.cogs[victim].hp
  if w.cogs[victim].hp == 0:
    w.dropHeart(victim); w.cogs[victim].respawn = RespawnTicks
    inc w.cogs[attacker].tags
    if observeTag != nil: observeTag(w.tick, victim, attacker, w.cogs[victim].pos)
proc legacyWaypoint(w: World, start, goal: Point): Point =
  ## Bounded breadth-first navigation over a 32x20 arena grid.
  if w.lineClear(start, goal) and w.traversable(start, goal): return goal
  let nx = (maxX()-minX()) div 200; let nz = (maxZ()-minZ()) div 200
  var prev: array[1920, int]
  for x in prev.mitems: x = -2
  let a = clamp((start.z.int-minZ()) div 200, 0, nz-1)*nx+clamp((start.x.int-minX()) div 200, 0, nx-1)
  let b = clamp((goal.z.int-minZ()) div 200, 0, nz-1)*nx+clamp((goal.x.int-minX()) div 200, 0, nx-1)
  var q: array[1920, int]; var head = 0; var tail = 1
  q[0] = a; prev[a] = -1
  while head < tail and prev[b] == -2:
    let n = q[head]; inc head
    for delta in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
      let x = n mod nx+delta[0]; let z = n div nx+delta[1]
      if x < 0 or x >= nx or z < 0 or z >= nz: continue
      let j = z*nx+x
      if prev[j] != -2 or w.blocked(point(minX()+x*200+100, minZ()+z*200+100), 90): continue
      if not w.traversable(point(minX()+n mod nx*200+100, minZ()+n div nx*200+100), point(
          minX()+x*200+100, minZ()+z*200+100)): continue
      prev[j] = n; q[tail] = j; inc tail
  if prev[b] == -2: return start
  var n = b
  while prev[n] >= 0 and prev[n] != a: n = prev[n]
  point(minX()+n mod nx*200+100, minZ()+n div nx*200+100)
# Navigation uses body clearance, never the visibility ray. Cached flow fields
# share static terrain work across cogs headed for the same objective.
var navCover: seq[Cover]
var navBounds: array[4,int]
var navEdges: seq[seq[int]]
var navFields: Table[int,seq[int]]
const NavCell = 100
proc walkClear*(w: World, a,b: Point):bool =
  if w.blocked(b) or not w.traversable(a,b):return false
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
    if islandTerrain and islandMargin(x,z)<Radius div 3+40:return false
  true
proc navigationPoint(n,nx:int):Point =
  point(minX()+(n mod nx)*NavCell+NavCell div 2,
        minZ()+(n div nx)*NavCell+NavCell div 2)
proc waypoint*(w:World,start,goal:Point):Point =
  if visionRulesVersion<22:return w.legacyWaypoint(start,goal)
  if w.walkClear(start,goal):return goal
  let nx=(maxX()-minX()) div NavCell
  let nz=(maxZ()-minZ()) div NavCell
  let bounds=[minX(),minZ(),maxX(),maxZ()]
  if navEdges.len!=nx*nz or navCover!=w.cover or navBounds!=bounds:
    navCover=w.cover;navBounds=bounds;navFields.clear()
    navEdges=newSeq[seq[int]](nx*nz)
    for n in 0..<nx*nz:
      let a=navigationPoint(n,nx)
      if w.blocked(a):continue
      for delta in [(1,0),(0,1)]:
        let x=n mod nx+delta[0];let z=n div nx+delta[1]
        if x>=nx or z>=nz:continue
        let j=z*nx+x
        if w.walkClear(a,navigationPoint(j,nx)):
          navEdges[n].add j;navEdges[j].add n
  var target = -1
  var best=high(int64)
  for n in 0..<navEdges.len:
    if navEdges[n].len==0:continue
    let d=distance2(goal,navigationPoint(n,nx))
    if d<best:best=d;target=n
  if target<0:return start
  if target notin navFields:
    var distances=newSeq[int](nx*nz)
    for d in distances.mitems:d = -1
    var queue = @[target];distances[target]=0
    var head=0
    while head<queue.len:
      let n=queue[head];inc head
      for j in navEdges[n]:
        if distances[j]<0:
          distances[j]=distances[n]+1;queue.add j
    if navFields.len>=64:navFields.clear()
    navFields[target]=distances
  let distances=navFields[target]
  result=start
  best=high(int64)
  var anchor = -1
  let sx=(start.x.int-minX()) div NavCell
  let sz=(start.z.int-minZ()) div NavCell
  for z in max(0,sz-3)..min(nz-1,sz+3):
    for x in max(0,sx-3)..min(nx-1,sx+3):
      let n=z*nx+x
      if distances[n]<0:continue
      let p=navigationPoint(n,nx)
      let cost=distances[n].int64*10000000+distance2(start,p)
      if cost<best and w.walkClear(start,p):
        best=cost;anchor=n
  if anchor<0:return
  result=navigationPoint(anchor,nx)
  for step in 0..<8:
    var next = -1
    for j in navEdges[anchor]:
      if distances[j]>=0 and distances[j]<distances[anchor]:next=j;break
    if next<0:break
    let p=navigationPoint(next,nx)
    if not w.walkClear(start,p):break
    result=p;anchor=next
proc stepEquipment(w: var World, commands: array[Seats, Command])
proc step*(w: var World, commands: array[Seats, Command],
    rulesVersion = visionRulesVersion) =
  if rulesVersion >= 6:
    w.stepEquipment(commands)
    return
  let solid = rulesVersion >= 3
  if w.winner >= 0: return
  for i in 0..<Seats:
    if w.cogs[i].hp <= 0:
      dec w.cogs[i].respawn
      if w.cogs[i].respawn <= 0: w.spawn(i, solid)
      continue
    if w.cogs[i].shield > 0: dec w.cogs[i].shield
    if w.cogs[i].cooldown > 0: dec w.cogs[i].cooldown
    let cmd = commands[i]
    if cmd.walk: w.cogs[i].goal = Point(x: clamp(cmd.goal.x, (minX()+100).int32, (maxX()-100).int32),
        z: clamp(cmd.goal.z, (minZ()+100).int32, (maxZ()-100).int32))
    w.cogs[i].firing = cmd.shoot
    if cmd.shoot or (rulesVersion >= 4 and cmd.aim != Point()):
      w.cogs[i].aim = cmd.aim
    elif rulesVersion >= 4 and cmd.walk and cmd.goal != w.cogs[i].pos:
      w.cogs[i].aim = cmd.goal
    let dest = if cmd.direct: w.cogs[i].goal else: w.waypoint(w.cogs[i].pos,
        w.cogs[i].goal)
    let speed = if w.cogs[i].carrying: MoveSpeed*7 div 10 else: MoveSpeed
    if distance2(w.cogs[i].pos, dest) > speed.int64*speed:
      let v = direction(w.cogs[i].pos, dest, speed)
      var p = w.cogs[i].pos; p.x+=v.x
      if not w.movementBlocked(p, i, solid): w.cogs[i].pos = p
      p = w.cogs[i].pos; p.z+=v.z
      if not w.movementBlocked(p, i, solid): w.cogs[i].pos = p
    if cmd.shoot and w.cogs[i].cooldown == 0:
      let v = direction(w.cogs[i].pos, w.cogs[i].aim, ShotSpeed)
      if v.x != 0 or v.z != 0:
        w.balls.add Paintball(pos: w.cogs[i].pos, velocity: v, owner: i.int32,
            life: ShotRange div ShotSpeed)
        w.cogs[i].cooldown = (if solid: FireCooldownTicks else: 8)
  var live: seq[Paintball]
  for original in w.balls:
    var b = original
    let old = b.pos
    b.pos.x+=b.velocity.x; b.pos.z+=b.velocity.z; dec b.life
    if b.life < 0 or not w.lineClear(old, b.pos): continue
    var collided = false
    # Short swept samples prevent a fast ball crossing a cog between ticks.
    for sub in 1..4:
      let p = Point(x: old.x+b.velocity.x*sub.int32 div 4,
          z: old.z+b.velocity.z*sub.int32 div 4)
      for j in 0..<Seats:
        if team(j) != team(b.owner.int) and w.cogs[j].hp > 0 and distance2(p,
            w.cogs[j].pos) <= Radius.int64*Radius:
          w.hit(j, b.owner.int); collided = true; break
      if collided: break
    if not collided: live.add b
  w.balls = live
  for side in 0..1:
    if w.hearts[side].carrier >= 0:
      w.hearts[side].pos = w.cogs[w.hearts[side].carrier].pos
    elif w.hearts[side].returnAt > 0 and w.tick >= w.hearts[
        side].returnAt: w.resetHeart(side)
  for i in 0..<Seats:
    if w.cogs[i].hp <= 0: continue
    let side = team(i); let enemy = 1-side
    if w.hearts[side].carrier < 0 and distance2(w.cogs[i].pos, w.hearts[
        side].pos) < 140*140:
      w.resetHeart(side)
    if not w.cogs[i].carrying and w.hearts[enemy].carrier < 0 and distance2(
        w.cogs[i].pos, w.hearts[enemy].pos) < 140*140:
      w.cogs[i].carrying = true; w.hearts[enemy].carrier = i.int32
    if w.cogs[i].carrying and distance2(w.cogs[i].pos, home(side)) < 200*200 and
        w.hearts[side].carrier < 0 and w.hearts[side].pos == home(side):
      inc w.captures[side]; inc w.cogs[i].captures
      w.cogs[i].carrying = false; w.resetHeart(enemy)
      if w.captures[side] >= CaptureTarget: w.winner = side.int32
  inc w.tick

include mechanics
