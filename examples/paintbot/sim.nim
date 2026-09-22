import village, topography
export topography
## Integer-only Paintbot simulation; Polyworld RNG and portable state hashes.
import polyworld/[rngs, hashes]
import std/[tables, math]

const
  Seats* = 16
  TickRate* = 24
  MatchTicks* = 5*60*TickRate # Historical replay duration.
  HeartMeterMatchTicks* = 10*60*TickRate
  HeartMeterFillTicks* = 3*60*TickRate
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
  # Glory (rules 37) is the winner's score: it starts at the match length in seconds, loses
  # one per second, and grows on the events below. The loser's glory is zeroed at the end.
  # Glory is a self-imposed handicap: nothing that makes a team more likely to win pays it.
  GloryQuietSupplies* = 10
  GloryQuietSupplyTicks* = 30*TickRate
  GloryFriendlyFire* = 30
  GloryFriendlyFireTicks* = 30*TickRate
  GloryEventLifetime* = 4*TickRate
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
    grenadePickup, sprayPickup, medkitPickup, armorPickup, uniformPickup
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
  SoundCue* = object
    listener*, kind*, direction*, distance*, tick*: int32
  GloryKind* = enum
    gloryQuietSupplies, gloryFriendlyFire
  GloryEvent* = object
    tick*, team*, amount*: int32
    kind*: GloryKind
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
    sounds*: seq[SoundCue] # Listener-relative sectors; never exact source coordinates.
    uniforms*: array[Seats, bool]
    glory*: array[2, int32] # Rules 37: the winner's score, in seconds; see GloryQuietSupplies and friends.
    lastSupplyTick*: array[2, int32] # The last tick each team collected a supply.
    gloryEvents*: seq[GloryEvent] # Recent awards, kept GloryEventLifetime ticks for the viewer.
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
    sneak*: bool

proc point*(x, z: int): Point = Point(x: int32(x), z: int32(z))
proc team*(slot: int): int = slot mod 2
# Rules 36 never existed as behaviour: version 0.3.32 stamped recordings 36 while this default
# still said 35, so a 36 header means rules 35 play. Glory and everything after start at 37.
when defined(pwTraining):
  var visionRulesVersion* {.threadvar.}: int
else:
  var visionRulesVersion* = 37
proc apparentTeam*(w: World, slot: int): int =
  ## Uniforms change appearance only; ownership always uses team(slot).
  if visionRulesVersion >= 27 and w.uniforms[slot]: 1-team(slot) else: team(slot)
proc observedTeam*(w: World, observer, slot: int): int =
  if observer == slot: team(slot) else: w.apparentTeam(slot)
proc observedSeat*(w: World, observer, slot: int): int =
  if observer != slot and visionRulesVersion >= 27 and w.uniforms[slot]:
    result = slot xor 1
    # A disguise must never overwrite the observer's own body.
    if result == observer: result = (result+2) mod Seats
  else: result = slot
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
proc coverBlocks(c: Cover, p: Point, radius: int): bool {.inline.} =
  if c.h == 0:
    let r = c.w div 2
    return distance2(p, point(c.x.int+r.int, c.z.int+r.int)) < (r+radius).int64*(r+radius)
  p.x > c.x-radius and p.x < c.x+c.w+radius and p.z > c.z-radius and p.z < c.z+c.h+radius
proc boundsBlocked(p: Point, radius: int, bounds: array[4,int]): bool {.inline.} =
  if p.x < bounds[0]+radius or p.z < bounds[1]+radius or p.x > bounds[2]-radius or p.z >
      bounds[3]-radius: return true
  islandTerrain and islandMargin(p.x.int,p.z.int)<radius div 3+40
proc boundsBlocked(p: Point, radius: int): bool {.inline.} =
  boundsBlocked(p, radius, [minX(),minZ(),maxX(),maxZ()])
# Training builds index cover on a coarse grid so point and segment tests visit only
# nearby obstacles instead of all of them (224 under rules 37). The index belongs to the
# thread and is keyed by the cover it was built from: a world whose cover payload address
# or length differs is compared by content and the index rebuilt if it differs. Every
# candidate set is a superset of the obstacles that can satisfy the predicate, so the
# answers are identical to the full scans below. Other builds keep the full scans.
when defined(pwTraining):
  const
    CoverCell = 200
    CoverReach = 90 # Largest radius any caller passes to blocked; larger falls back.
  const RayMemoBits = 16
  type
    RayKey = object
      a, b: Point
    CoverIndex = object
      payload: pointer
      length: int
      bounds: array[4, int]
      cover: seq[Cover]
      originX, originZ, nx, nz: int
      cellStart, items: seq[int32]
      seen: seq[int32]
      stamp: int32
      # lineClear is a function of its endpoints and the static geometry (cover,
      # trenches, terrain, rules), so rays repeat exactly while cogs stand still.
      rayTrenches: seq[Cover]
      rayRules: int
      rayKeys: seq[RayKey]
      rayState: seq[uint8] # 0 empty, 1 blocked, 2 clear
  var coverIndex {.threadvar.}: CoverIndex
  proc coverSpan(c: Cover): tuple[x0, x1, z0, z1: int] =
    let depth = if c.h == 0: c.w else: c.h
    (c.x.int-CoverReach-1, c.x.int+c.w.int+CoverReach+1, c.z.int-CoverReach-1, c.z.int+depth.int+CoverReach+1)
  proc buildCoverIndex(w: World) =
    let g = addr coverIndex
    g.cover = w.cover
    g.bounds = [minX(), minZ(), maxX(), maxZ()]
    g.originX = minX()-2*CoverCell
    g.originZ = minZ()-2*CoverCell
    g.nx = (maxX()-minX()) div CoverCell+5
    g.nz = (maxZ()-minZ()) div CoverCell+5
    g.cellStart = newSeq[int32](g.nx*g.nz+1)
    g.seen = newSeq[int32](w.cover.len)
    g.stamp = 0
    g.rayKeys = newSeq[RayKey](1 shl RayMemoBits)
    g.rayState = newSeq[uint8](1 shl RayMemoBits)
    g.rayRules = -1
    template cells(c: Cover, body: untyped) =
      let span = coverSpan(c)
      let cx0 = clamp((span.x0-g.originX) div CoverCell, 0, g.nx-1)
      let cx1 = clamp((span.x1-g.originX) div CoverCell, 0, g.nx-1)
      let cz0 = clamp((span.z0-g.originZ) div CoverCell, 0, g.nz-1)
      let cz1 = clamp((span.z1-g.originZ) div CoverCell, 0, g.nz-1)
      if span.x1 >= g.originX and span.z1 >= g.originZ:
        for cz in cz0..cz1:
          for cx in cx0..cx1:
            let cell {.inject.} = cz*g.nx+cx
            body
    for c in w.cover:
      cells(c): inc g.cellStart[cell+1]
    for i in 1..g.nx*g.nz: g.cellStart[i] += g.cellStart[i-1]
    g.items = newSeq[int32](g.cellStart[^1])
    var fill = g.cellStart
    for index, c in w.cover:
      cells(c):
        g.items[fill[cell]] = index.int32
        inc fill[cell]
  proc coverIndexFor(w: World): ptr CoverIndex =
    result = addr coverIndex
    let payload = if w.cover.len > 0: cast[pointer](unsafeAddr w.cover[0]) else: nil
    if result.payload == payload and result.length == w.cover.len and
        result.bounds == [minX(), minZ(), maxX(), maxZ()]: return
    if result.length != w.cover.len or result.bounds != [minX(), minZ(), maxX(), maxZ()] or
        result.cover != w.cover:
      buildCoverIndex(w)
    result.payload = payload
    result.length = w.cover.len
  proc raySlot(a, b: Point): int {.inline.} =
    var h = uint64(uint32(a.x))*0x9E3779B97F4A7C15'u64
    h = (h xor uint64(uint32(a.z)))*0xC2B2AE3D27D4EB4F'u64
    h = (h xor uint64(uint32(b.x)))*0x165667B19E3779F9'u64
    h = (h xor uint64(uint32(b.z)))*0x9E3779B97F4A7C15'u64
    int((h shr 40) and uint64((1 shl RayMemoBits)-1))
  template cellAt(g: ptr CoverIndex, x, z: int): int =
    ## -1 when the point lies outside the indexed span.
    let cx = x-g.originX
    let cz = z-g.originZ
    if cx < 0 or cz < 0 or cx >= g.nx*CoverCell or cz >= g.nz*CoverCell: -1
    else: (cz div CoverCell)*g.nx+cx div CoverCell
  proc coverBlockedIndexed(g: ptr CoverIndex, w: World, p: Point, radius: int): bool =
    if radius > CoverReach:
      for c in w.cover:
        if c.coverBlocks(p, radius): return true
      return false
    let cell = cellAt(g, p.x.int, p.z.int)
    if cell < 0:
      for c in w.cover:
        if c.coverBlocks(p, radius): return true
      return false
    for k in g.cellStart[cell]..<g.cellStart[cell+1]:
      if w.cover[g.items[k]].coverBlocks(p, radius): return true
    false
  iterator segmentCover(w: World, a, b: Point): int =
    ## Indices of cover that may lie within CoverReach of segment ab, each once, or every
    ## index when the segment leaves the indexed span. Rebuilding is impossible mid-loop.
    let g = coverIndexFor(w)
    let c0 = cellAt(g, min(a.x, b.x).int, min(a.z, b.z).int)
    let c1 = cellAt(g, max(a.x, b.x).int, max(a.z, b.z).int)
    if c0 < 0 or c1 < 0:
      for index in 0..<w.cover.len: yield index
    else:
      inc g.stamp
      if g.stamp == high(int32):
        for s in g.seen.mitems: s = 0
        g.stamp = 1
      let stamp = g.stamp
      for cz in c0 div g.nx..c1 div g.nx:
        for cx in c0 mod g.nx..c1 mod g.nx:
          let cell = cz*g.nx+cx
          for k in g.cellStart[cell]..<g.cellStart[cell+1]:
            let index = g.items[k]
            if g.seen[index] == stamp: continue
            g.seen[index] = stamp
            yield index.int
proc blocked*(w: World, p: Point, radius = Radius): bool =
  if boundsBlocked(p, radius): return true
  when defined(pwTraining):
    coverBlockedIndexed(coverIndexFor(w), w, p, radius)
  else:
    for c in w.cover:
      if c.coverBlocks(p, radius): return true
const RayCoverLimit = 512
proc lineClearRay(w: World, a, b: Point): bool =
  # Only obstacles overlapping the ray bounds can block its sampled points, so the
  # sampled predicate is evaluated against that subset (from the cover index in training
  # builds, otherwise indexed on the stack; too many for the stack means the full set,
  # which gives the same answer). Keep the exact sample positions and collision
  # predicates for replay parity. No world copy, no allocation.
  when not defined(pwTraining):
    var rayCover: array[RayCoverLimit, int32]
    var rayCount = 0
    for index, c in w.cover:
      let depth = if c.h == 0: c.w else: c.h
      if c.x <= max(a.x,b.x) and c.x+c.w >= min(a.x,b.x) and
          c.z <= max(a.z,b.z) and c.z+depth >= min(a.z,b.z):
        if rayCount < RayCoverLimit: rayCover[rayCount] = index.int32
        inc rayCount
    let filtered = rayCount <= RayCoverLimit
  else:
    let g = coverIndexFor(w)
  let bounds = [minX(),minZ(),maxX(),maxZ()]
  let elevated = visionRulesVersion >= 9
  let startHeight = if elevated: w.elevation(a) else: 0
  let endHeight = if elevated: w.elevation(b) else: 0
  let steps = max(abs(b.x-a.x), abs(b.z-a.z)) div 25 + 1
  for i in 1..steps:
    let p = Point(x: a.x+(b.x-a.x)*i div steps, z: a.z+(b.z-a.z)*i div steps)
    if boundsBlocked(p, 0, bounds): return false
    when defined(pwTraining):
      if coverBlockedIndexed(g, w, p, 0): return false
    else:
      if filtered:
        for k in 0..<rayCount:
          if w.cover[rayCover[k]].coverBlocks(p, 0): return false
      else:
        for c in w.cover:
          if c.coverBlocks(p, 0): return false
    if elevated:
      let eye = startHeight+120+(endHeight-startHeight)*i.int div steps.int
      if w.elevation(p) > eye: return false
  true
proc lineClear*(w: World, a, b: Point): bool =
  when defined(pwTraining):
    # Remembered per thread for the geometry the cover index was built from; the
    # trenches and rules are checked on every call and any change empties the memo.
    let g = coverIndexFor(w)
    if g.rayRules != visionRulesVersion or g.rayTrenches != w.trenches:
      g.rayRules = visionRulesVersion
      g.rayTrenches = w.trenches
      for state in g.rayState.mitems: state = 0
    let slot = raySlot(a, b)
    if g.rayState[slot] != 0 and g.rayKeys[slot].a == a and g.rayKeys[slot].b == b:
      return g.rayState[slot] == 2
    result = lineClearRay(w, a, b)
    g.rayKeys[slot] = RayKey(a: a, b: b)
    g.rayState[slot] = if result: 2 else: 1
  else:
    lineClearRay(w, a, b)
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
proc configureRules*(version: int) =
  ## Native rollout workers call this on their own thread before accessing a world.
  visionRulesVersion = version
  wideRamps = visionRulesVersion >= 11
  wilderness = visionRulesVersion >= 12
  deepWilderness = visionRulesVersion >= 14
  organicTerrain = visionRulesVersion >= 15
  islandTerrain = visionRulesVersion >= 16
  expandedIsland = visionRulesVersion >= 22
  riverTerrain = visionRulesVersion >= 29
  curvedRiver = visionRulesVersion >= 31
  fractalRiver = visionRulesVersion >= 32
  lakeTerrain = visionRulesVersion >= 33
  symmetricTerrain = visionRulesVersion >= 35
  refreshTerrainTable()

proc newWorld*(seed: int32, endTick: int32 = 0): World =
  configureRules(visionRulesVersion)
  result.endTick = if visionRulesVersion >= 28:
    (if endTick <= 0: HeartMeterMatchTicks.int32 else: min(endTick, HeartMeterMatchTicks.int32))
  else: (if endTick <= 0: MatchTicks.int32 else: endTick)
  result.seed = seed; result.rng = initRng(seed); result.winner = -1
  if visionRulesVersion >= 37:
    let seconds = result.endTick div TickRate
    result.glory = [seconds, seconds]
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
  if visionRulesVersion in 25..27 and w.bigHeart == index.int32: BigHeartPoints else: 1

proc heartMeterTarget*(w: World): int32 =
  ## Half the hearts held for three minutes, measured in integer tick-points.
  w.controlHearts.len.int32 * HeartMeterFillTicks div 2

proc earnGlory*(w: var World, side: int, kind: GloryKind, amount: int32) =
  ## Rules 37: credit a team and remember why, so the viewer can say so.
  if visionRulesVersion < 37: return
  w.glory[side] += amount
  w.gloryEvents.add GloryEvent(tick: w.tick, team: side.int32, amount: amount, kind: kind)

proc updateGlory*(w: var World) =
  ## Rules 37, once per tick after the tick counter advances: forget old awards, count
  ## down one glory per second, and pay a team that went thirty seconds without supplies.
  var recent: seq[GloryEvent]
  for event in w.gloryEvents:
    if w.tick-event.tick < GloryEventLifetime: recent.add event
  w.gloryEvents = recent
  if w.tick mod TickRate == 0:
    for side in 0..1: w.glory[side] = max(0'i32, w.glory[side]-1)
  for side in 0..1:
    if w.tick-w.lastSupplyTick[side] >= GloryQuietSupplyTicks:
      w.lastSupplyTick[side] = w.tick
      w.earnGlory(side, gloryQuietSupplies, GloryQuietSupplies)

proc settleGlory*(w: var World) =
  ## Only winners keep glory: the loser's drops to zero, and a draw pays nobody.
  if visionRulesVersion < 37 or w.winner == -1: return
  for side in 0..1:
    if w.winner != side.int32: w.glory[side] = 0

proc scores*(w: World): seq[float] =
  for i in 0..<Seats:
    result.add (if visionRulesVersion >= 37: w.glory[team(i)].float elif visionRulesVersion >= 23: w.scoreTicks[team(i)].float / TickRate.float else: float(if visionRulesVersion >= 20 and w.winner >= 0: (if w.winner == team(i).int32: 10 else: 0) elif visionRulesVersion>=13:w.captures[team(i)].int else:int(w.winner == team(i).int32)))
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
  if visionRulesVersion >= 26:
    result = HashySeed
    for name, value in fieldPairs(w):
      when name == "uniforms":
        if visionRulesVersion >= 27: result.addHashy(value)
      elif name == "glory" or name == "lastSupplyTick" or name == "gloryEvents":
        if visionRulesVersion >= 37: result.addHashy(value)
      else: result.addHashy(value)
    return
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
    if visionRulesVersion >= 25:
      result.addHashy(w.bigHeart)
      result.addHashy(w.bigHeartRound)
      result.addHashy(w.usedBigHearts)
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
var observeShot*: proc(tick: int32, slot: int) {.closure.}
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
type NavCache = object
  cover: seq[Cover]
  payload: pointer
  length: int
  bounds: array[4,int]
  edges: seq[seq[int]]
  fields: Table[int,seq[int32]] # target cell -> BFS distance per cell, -1 unreachable
  recent: seq[int]              # targets, least recently used first
  targets: Table[Point,int]     # goal -> nearest connected cell (or -1)
when defined(pwTraining):
  var nav {.threadvar.}: NavCache
else:
  var nav: NavCache
const
  NavCell = 100
  NavFieldLimit = 64
  NavTargetLimit = 4096
proc walkCoverBlocks(c: Cover, a,b: Point, dx,dz,length: float64): bool {.inline.} =
  if c.h==0:
    let r=c.w.float64/2
    let cx=c.x.float64+r;let cz=c.z.float64+r
    let t=if length==0:0.0 else:clamp(((cx-a.x.float64)*dx+(cz-a.z.float64)*dz)/length,0.0,1.0)
    let ex=a.x.float64+t*dx-cx;let ez=a.z.float64+t*dz-cz
    if ex*ex+ez*ez<(r+Radius.float64)*(r+Radius.float64):return true
  else:
    let steps=max(abs(b.x-a.x),abs(b.z-a.z)).int div 15+1
    for i in 1..steps:
      let x=a.x.int+(b.x-a.x).int*i div steps
      let z=a.z.int+(b.z-a.z).int*i div steps
      if x>c.x-Radius and x<c.x+c.w+Radius and z>c.z-Radius and z<c.z+c.h+Radius:return true
proc walkClear*(w: World, a,b: Point):bool =
  if w.blocked(b) or not w.traversable(a,b):return false
  let dx=(b.x-a.x).float64;let dz=(b.z-a.z).float64
  let length=dx*dx+dz*dz
  when defined(pwTraining):
    for index in segmentCover(w,a,b):
      if w.cover[index].walkCoverBlocks(a,b,dx,dz,length):return false
  else:
    for c in w.cover:
      if c.walkCoverBlocks(a,b,dx,dz,length):return false
  let steps=max(abs(b.x-a.x),abs(b.z-a.z)).int div 50+1
  for i in 1..steps:
    let x=a.x.int+(b.x-a.x).int*i div steps
    let z=a.z.int+(b.z-a.z).int*i div steps
    if islandTerrain and islandMargin(x,z)<Radius div 3+40:return false
  true
proc navigationPoint(n,nx:int):Point =
  point(minX()+(n mod nx)*NavCell+NavCell div 2,
        minZ()+(n div nx)*NavCell+NavCell div 2)
proc nearestConnectedCell(goal:Point,nx,nz:int):int =
  ## The connected cell whose centre is nearest the goal, lowest index on ties: the
  ## same answer as scanning every cell, found by rings of cells around the goal that
  ## stop once a ring cannot hold a centre as near as the best so far.
  result = -1
  var best=high(int64)
  let originX=minX(); let originZ=minZ()
  let gx=floorDiv(goal.x.int-originX,NavCell)
  let gz=floorDiv(goal.z.int-originZ,NavCell)
  for ring in 0..max(nx,nz)+max(abs(gx),abs(gz))+1:
    if ring>0:
      let nearest=int64((ring-1)*NavCell+NavCell div 2)
      if nearest*nearest>best:break
    for z in max(0,gz-ring)..min(nz-1,gz+ring):
      let edge=abs(z-gz)==ring
      var x=max(0,gx-ring)
      while x<=min(nx-1,gx+ring):
        if edge or abs(x-gx)==ring:
          let n=z*nx+x
          if nav.edges[n].len>0:
            let d=distance2(goal,point(originX+x*NavCell+NavCell div 2,originZ+z*NavCell+NavCell div 2))
            if d<best or (d==best and n<result):best=d;result=n
        if edge or x>=gx+ring:inc x
        else:x=gx+ring
proc waypoint*(w:World,start,goal:Point):Point =
  if visionRulesVersion<22:return w.legacyWaypoint(start,goal)
  if w.walkClear(start,goal):return goal
  let nx=(maxX()-minX()) div NavCell
  let nz=(maxZ()-minZ()) div NavCell
  let bounds=[minX(),minZ(),maxX(),maxZ()]
  let payload=if w.cover.len>0:cast[pointer](unsafeAddr w.cover[0]) else:nil
  # The grid depends only on cover and bounds. A world whose cover payload address or
  # length differs from the last is compared by content; the grid survives if it agrees.
  let same=nav.edges.len==nx*nz and nav.bounds==bounds and nav.length==w.cover.len and
    ((nav.payload==payload and defined(pwTraining)) or nav.cover==w.cover)
  if not same:
    nav.cover=w.cover;nav.bounds=bounds;nav.fields.clear();nav.recent.setLen(0);nav.targets.clear()
    nav.edges=newSeq[seq[int]](nx*nz)
    for n in 0..<nx*nz:
      let a=navigationPoint(n,nx)
      if w.blocked(a):continue
      for delta in [(1,0),(0,1)]:
        let x=n mod nx+delta[0];let z=n div nx+delta[1]
        if x>=nx or z>=nz:continue
        let j=z*nx+x
        if w.walkClear(a,navigationPoint(j,nx)):
          nav.edges[n].add j;nav.edges[j].add n
  nav.payload=payload;nav.length=w.cover.len
  var target = -1
  if goal in nav.targets:target=nav.targets[goal]
  else:
    target=nearestConnectedCell(goal,nx,nz)
    if nav.targets.len>=NavTargetLimit:nav.targets.clear()
    nav.targets[goal]=target
  if target<0:return start
  if target notin nav.fields:
    var distances=newSeq[int32](nx*nz)
    for d in distances.mitems:d = -1
    var queue = @[target];distances[target]=0
    var head=0
    while head<queue.len:
      let n=queue[head];inc head
      for j in nav.edges[n]:
        if distances[j]<0:
          distances[j]=distances[n]+1;queue.add j
    if nav.fields.len>=NavFieldLimit:
      # Bounded eviction of the least recently used field; results never depend on it.
      nav.fields.del(nav.recent[0]);nav.recent.delete(0)
    nav.fields[target]=distances
    nav.recent.add target
  elif nav.recent[^1]!=target:
    nav.recent.delete(nav.recent.find(target));nav.recent.add target
  let distances=addr nav.fields[target]
  result=start
  var best=high(int64)
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
    for j in nav.edges[anchor]:
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
        if observeShot != nil: observeShot(w.tick, i)
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
