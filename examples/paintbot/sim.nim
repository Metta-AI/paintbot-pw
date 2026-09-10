import village, topography
export topography
## Integer-only Paintbot simulation; Polyworld RNG and portable state hashes.
import polyworld/[rngs, hashes]

const
  Seats* = 16
  TickRate* = 24
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
var visionRulesVersion* = 13
proc minX*():int = (if visionRulesVersion>=12: -800 else: 0)
proc minZ*():int = (if visionRulesVersion>=12: -400 else: 0)
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
  for c in w.cover:
    if c.h == 0:
      let r = c.w div 2
      if distance2(p, point(c.x.int+r.int, c.z.int+r.int)) < (r+radius).int64*(
          r+radius): return true
      continue
    if p.x > c.x-radius and p.x < c.x+c.w+radius and p.z > c.z-radius and p.z <
        c.z+c.h+radius: return true
proc lineClear*(w: World, a, b: Point): bool =
  let steps = max(abs(b.x-a.x), abs(b.z-a.z)) div 25 + 1
  for i in 1..steps:
    let p = Point(x: a.x+(b.x-a.x)*i div steps, z: a.z+(b.z-a.z)*i div steps)
    if w.blocked(p, 0): return false
    if visionRulesVersion >= 9:
      let eye = w.elevation(a)+120+(w.elevation(b)-w.elevation(
          a))*i.int div steps.int
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
proc newWorld*(seed: int32): World =
  wideRamps = visionRulesVersion >= 11
  wilderness = visionRulesVersion >= 12
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
  for i in 0..<Seats: result.spawn(i)
  if wilderness:
    for p in [point(-620,300),point(-620,1700),point(-620,3500),point(1200,-320),point(3100,-320),point(5400,-320)]:
      for q in [p,point(6400-p.x.int,4000-p.z.int)]:
        result.cover.add Cover(x:q.x-65,z:q.z-65,w:130,h:0)
  if visionRulesVersion >= 6: result.initializeEquipment()
proc scores*(w: World): seq[int] =
  for i in 0..<Seats:
    result.add (if visionRulesVersion>=13:w.captures[team(i)].int else:int(w.winner == team(i).int32))
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
  if visionRulesVersion >= 13: return hashy(w)
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
proc waypoint*(w: World, start, goal: Point): Point =
  ## Bounded breadth-first navigation over a 32x20 arena grid.
  if w.lineClear(start, goal) and w.traversable(start, goal): return goal
  let nx = (maxX()-minX()) div 200; let nz = (maxZ()-minZ()) div 200
  var prev: array[960, int]
  for x in prev.mitems: x = -2
  let a = clamp((start.z.int-minZ()) div 200, 0, nz-1)*nx+clamp((start.x.int-minX()) div 200, 0, nx-1)
  let b = clamp((goal.z.int-minZ()) div 200, 0, nz-1)*nx+clamp((goal.x.int-minX()) div 200, 0, nx-1)
  var q: array[960, int]; var head = 0; var tail = 1
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
