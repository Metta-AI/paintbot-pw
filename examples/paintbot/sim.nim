## Integer-only Paintbot simulation; Polyworld RNG and portable state hashes.
import polyworld/[rngs, hashes]

const
  Seats* = 16
  TickRate* = 24
  Width* = 6400
  Height* = 4000
  Radius* = 55
  MoveSpeed* = 28
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
  World* = object
    seed*, tick*: int32
    rng*: Rng
    cogs*: array[Seats, Cog]
    hearts*: array[2, Heart]
    captures*: array[2, int32]
    cover*: seq[Cover]
    balls*: seq[Paintball]
    winner*: int32 # -1 before a capture victory
  Command* = object
    walk*, shoot*, direct*: bool
    goal*, aim*: Point

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
proc blocked*(w: World, p: Point, radius = Radius): bool =
  if p.x < radius or p.z < radius or p.x > Width-radius or p.z >
      Height-radius: return true
  for c in w.cover:
    if p.x > c.x-radius and p.x < c.x+c.w+radius and p.z > c.z-radius and p.z <
        c.z+c.h+radius: return true
proc lineClear*(w: World, a, b: Point): bool =
  let steps = max(abs(b.x-a.x), abs(b.z-a.z)) div 25 + 1
  for i in 1..steps:
    let p = Point(x: a.x+(b.x-a.x)*i div steps, z: a.z+(b.z-a.z)*i div steps)
    if w.blocked(p, 0): return false
  true
proc visible*(w: World, slot, other: int): bool =
  other >= 0 and other < Seats and w.cogs[other].hp > 0 and
    (team(slot) == team(other) or
      (distance2(w.cogs[slot].pos, w.cogs[other].pos) <=
          VisionRange.int64*VisionRange and
       w.lineClear(w.cogs[slot].pos, w.cogs[other].pos)))
proc spawn(w: var World, slot: int) =
  let p = point(if team(slot) == 0: 350+(slot div 2 mod 2)*160 else: Width-350-(
      slot div 2 mod 2)*160,
    1100+(slot div 4)*550)
  w.cogs[slot].pos = p; w.cogs[slot].goal = p
  w.cogs[slot].hp = 3; w.cogs[slot].shield = 36
  w.cogs[slot].firing = false; w.cogs[slot].carrying = false
proc resetHeart*(w: var World, side: int) =
  w.hearts[side] = Heart(pos: home(side), carrier: -1)
proc newWorld*(seed: int32): World =
  result.seed = seed; result.rng = initRng(seed); result.winner = -1
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
proc scores*(w: World): seq[int] =
  for i in 0..<Seats: result.add int(w.winner == team(i).int32)
proc stateHash*(w: World): uint32 = hashy(w)
proc dropHeart(w: var World, slot: int) =
  if not w.cogs[slot].carrying: return
  let enemy = 1-team(slot)
  w.hearts[enemy] = Heart(pos: w.cogs[slot].pos, carrier: -1,
      returnAt: w.tick+240)
  w.cogs[slot].carrying = false
proc hit*(w: var World, victim, attacker: int) =
  if w.cogs[victim].hp <= 0 or w.cogs[victim].shield > 0: return
  dec w.cogs[victim].hp
  if w.cogs[victim].hp == 0:
    w.dropHeart(victim); w.cogs[victim].respawn = RespawnTicks
    inc w.cogs[attacker].tags
proc waypoint*(w: World, start, goal: Point): Point =
  ## Bounded breadth-first navigation over a 32x20 arena grid.
  if w.lineClear(start, goal): return goal
  const nx = Width div 200; const nz = Height div 200
  var prev: array[nx*nz, int]
  for x in prev.mitems: x = -2
  let a = clamp(start.z.int div 200, 0, nz-1)*nx+clamp(start.x.int div 200, 0, nx-1)
  let b = clamp(goal.z.int div 200, 0, nz-1)*nx+clamp(goal.x.int div 200, 0, nx-1)
  var q: array[nx*nz, int]; var head = 0; var tail = 1
  q[0] = a; prev[a] = -1
  while head < tail and prev[b] == -2:
    let n = q[head]; inc head
    for delta in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
      let x = n mod nx+delta[0]; let z = n div nx+delta[1]
      if x < 0 or x >= nx or z < 0 or z >= nz: continue
      let j = z*nx+x
      if prev[j] != -2 or w.blocked(point(x*200+100, z*200+100), 90): continue
      prev[j] = n; q[tail] = j; inc tail
  if prev[b] == -2: return start
  var n = b
  while prev[n] >= 0 and prev[n] != a: n = prev[n]
  point(n mod nx*200+100, n div nx*200+100)
proc step*(w: var World, commands: array[Seats, Command]) =
  if w.winner >= 0: return
  for i in 0..<Seats:
    if w.cogs[i].hp <= 0:
      dec w.cogs[i].respawn
      if w.cogs[i].respawn <= 0: w.spawn(i)
      continue
    if w.cogs[i].shield > 0: dec w.cogs[i].shield
    if w.cogs[i].cooldown > 0: dec w.cogs[i].cooldown
    let cmd = commands[i]
    if cmd.walk: w.cogs[i].goal = Point(x: clamp(cmd.goal.x, 100, Width-100),
        z: clamp(cmd.goal.z, 100, Height-100))
    w.cogs[i].firing = cmd.shoot
    if cmd.shoot: w.cogs[i].aim = cmd.aim
    let dest = if cmd.direct: w.cogs[i].goal else: w.waypoint(w.cogs[i].pos,
        w.cogs[i].goal)
    let speed = if w.cogs[i].carrying: MoveSpeed*7 div 10 else: MoveSpeed
    if distance2(w.cogs[i].pos, dest) > speed.int64*speed:
      let v = direction(w.cogs[i].pos, dest, speed)
      var p = w.cogs[i].pos; p.x+=v.x
      if not w.blocked(p): w.cogs[i].pos = p
      p = w.cogs[i].pos; p.z+=v.z
      if not w.blocked(p): w.cogs[i].pos = p
    if cmd.shoot and w.cogs[i].cooldown == 0:
      let v = direction(w.cogs[i].pos, w.cogs[i].aim, ShotSpeed)
      if v.x != 0 or v.z != 0:
        w.balls.add Paintball(pos: w.cogs[i].pos, velocity: v, owner: i.int32,
            life: ShotRange div ShotSpeed)
        w.cogs[i].cooldown = 8
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
