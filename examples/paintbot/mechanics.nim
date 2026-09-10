## Paintbot equipment and combat. Integer coordinates are five units per CTF pixel.
const
  GrenadeChargeTicks* = 24
  GrenadeFlightTicks* = 10
  GrenadeBlastRadius* = 260
  SprayReach* = 850
  SprayDamage* = 3
  SprayTicks* = 5
  SprayRecoveryTicks* = 20
  GunWindupTicks* = 5
  GunRange* = 5250
  StartingLives* = 3

proc gunSpreadPercent*(w: World, origin, target: Point): int =
  ## 25% less spread per metre downhill, capped at 50% less or 50% more spread.
  if visionRulesVersion < 10: return 100
  clamp(100 - (w.elevation(origin)-w.elevation(target)) div 4, 50, 150)

proc trenchAt*(w: World, p: Point): int =
  for i, t in w.trenches:
    if p.x >= t.x and p.x < t.x+t.w and p.z >= t.z and p.z < t.z+t.h:
      return i
  -1

proc freePickup(w: World, p: Point): Point =
  if not w.blocked(p): return p
  for r in 1..20:
    for dz in -r..r:
      for dx in -r..r:
        if abs(dx) != r and abs(dz) != r: continue
        let candidate = point(p.x.int+dx*60, p.z.int+dz*60)
        if not w.blocked(candidate): return candidate
  p

proc initializeEquipment(w: var World) =
  for i in 0..<Seats:
    w.equipment[i].lives = (if visionRulesVersion >= 19: 4 else: StartingLives)
    w.cogs[i].aim = home(1-team(i))
  # Mirrors use the same symmetry as this arena's terrain (180-degree rotation).
  for p in [point(300, 300), point(300, Height-300)]:
    w.pickups.add Pickup(pos: w.freePickup(p), kind: grenadePickup)
    w.pickups.add Pickup(pos: w.freePickup(point(Width-p.x.int,
        Height-p.z.int)), kind: grenadePickup)
  for spec in [(sprayPickup, point(600, 1000)), (armorPickup, point(600, 3000))]:
    w.pickups.add Pickup(pos: w.freePickup(spec[1]), kind: spec[0])
    w.pickups.add Pickup(pos: w.freePickup(point(Width-spec[1].x.int,
        Height-spec[1].z.int)), kind: spec[0])
  for z in [Height div 3, Height*2 div 3]:
    w.pickups.add Pickup(pos: w.freePickup(point(Width div 2, z)),
        kind: medkitPickup)
  let pits = if visionRulesVersion >= 9:
      [point(1950, 650), point(2600, 2050), point(900, 2850)]
    else: [point(1100, 1100), point(2100, 2350), point(3000, 700)]
  for p in pits:
    let q = w.freePickup(p)
    w.trenches.add Cover(x: q.x-140, z: q.z-140, w: 280, h: 280)
    w.trenches.add Cover(x: Width.int32-q.x-140, z: Height.int32-q.z-140,
        w: 280, h: 280)

  if visionRulesVersion>=13:
    for i,p in [home(0),home(1),point(2050,950),point(4350,3050),
        point(1800,-200),point(4600,4200),point(-400,3000),point(6800,1000),
        point(3200,1250),point(3200,2750)]:
      w.controlHearts.add ControlHeart(pos:w.freePickup(p),owner:(if i<2:i.int32 else: -1'i32))
    if deepWilderness:
      for i,p in [point(-1700,700),point(8100,3300),point(1200,-650),point(5200,4650),
          point(-1700,3300),point(8100,700)]:
        w.controlHearts[i+2].pos=w.freePickup(p)
      for p in [point(-1700,2000),point(8100,2000),point(3200,-650),point(3200,4650)]:
        w.pickups.add Pickup(pos:w.freePickup(p),kind:medkitPickup)
    w.captures=[1'i32,1'i32]

proc updateTerritory*(w:var World) =
  for heart in w.controlHearts.mitems:
    var touching:array[2,bool]
    for i,c in w.cogs:
      if c.hp>0 and distance2(c.pos,heart.pos)<=140*140 and w.traversable(c.pos,heart.pos):
        touching[team(i)]=true
    if touching[0] != touching[1]:
      let owner=(if touching[0]:0'i32 else:1'i32)
      if heart.owner!=owner:
        for i,c in w.cogs:
          if team(i)==owner.int and c.hp>0 and distance2(c.pos,heart.pos)<=140*140 and w.traversable(c.pos,heart.pos):
            inc w.cogs[i].captures
            break
        heart.owner=owner
  w.captures=[0'i32,0'i32]
  for heart in w.controlHearts:
    if heart.owner>=0:inc w.captures[heart.owner]
  for side in 0..1:
    if w.captures[side]==10:w.winner=side.int32

proc damage*(w: var World, victim, attacker, amount: int) =
  if w.cogs[victim].hp <= 0 or w.cogs[victim].shield > 0: return
  if observeHit != nil: observeHit(w.tick, victim, attacker, w.cogs[victim].pos)
  let absorbed = min(w.equipment[victim].armor, amount.int32)
  w.equipment[victim].armor-=absorbed
  w.cogs[victim].hp = max(0'i32, w.cogs[victim].hp-(amount.int32-absorbed))
  if w.equipment[victim].armor == 0 and not w.cogs[victim].carrying and
      w.trenchAt(w.cogs[victim].pos) < 0:
    w.cogs[victim].cooldown = min(w.cogs[victim].cooldown,
        FireCooldownTicks.int32)
  if w.cogs[victim].hp > 0: return
  if w.cogs[victim].carrying:
    w.resetHeart(1-team(victim)); w.cogs[victim].carrying = false
  let lives = if visionRulesVersion in 13..18:StartingLives.int32 else:max(0'i32, w.equipment[victim].lives-1)
  w.equipment[victim] = Equipment(lives: lives)
  w.cogs[victim].respawn = RespawnTicks
  w.cogs[victim].cooldown = 0
  if attacker >= 0 and attacker != victim:
    inc w.cogs[attacker].tags
    if observeTag != nil: observeTag(w.tick, victim, attacker, w.cogs[victim].pos)

proc grenadeTarget*(w: World, slot: int): Point =
  let c = w.cogs[slot]
  let charge = clamp(w.equipment[slot].charge, 1, GrenadeChargeTicks)
  let reach = 150+(Width div 5-150)*charge.int div GrenadeChargeTicks
  let aim = if c.aim == Point(): home(1-team(slot)) else: c.aim
  let v = direction(c.pos, aim, reach)
  Point(x: clamp(c.pos.x+v.x,minX().int32,maxX().int32), z: clamp(c.pos.z+v.z,minZ().int32,maxZ().int32))

proc explode*(w: var World, p: Point, owner: int) =
  let trench = w.trenchAt(p)
  w.blasts.add Blast(pos: p, tick: w.tick, owner: owner.int32,
      trench: trench.int32)
  for i in 0..<Seats:
    if w.cogs[i].hp <= 0 or distance2(w.cogs[i].pos, p) > (
        GrenadeBlastRadius+Radius).int64*(GrenadeBlastRadius+Radius): continue
    let victimTrench = w.trenchAt(w.cogs[i].pos)
    let amount = if victimTrench >= 0: (if victimTrench ==
        trench: 6 else: 1) else: 2
    w.damage(i, owner, amount)

proc sprayTouches*(w: World, slot, victim: int): bool =
  if victim == slot or w.cogs[victim].hp <= 0: return false
  let c = w.cogs[slot]; let v = w.equipment[slot].sprayAim
  let dx = int64(w.cogs[victim].pos.x)-c.pos.x
  let dz = int64(w.cogs[victim].pos.z)-c.pos.z
  let length = max(1'i64, isqrt(int64(v.x)*v.x+int64(v.z)*v.z))
  let along = (dx*v.x+dz*v.z) div length
  let across = abs(dx*v.z-dz*v.x) div length
  let halfWidth = if visionRulesVersion >= 17: along*3 div 5 else: along div 4
  along > 0 and along <= SprayReach+Radius and across <= halfWidth+Radius and
    w.lineClear(c.pos, w.cogs[victim].pos)

proc pickupEquipment(w: var World) =
  for k in 0..<w.pickups.len:
    if w.pickups[k].readyAt > w.tick: continue
    for i in 0..<Seats:
      if w.cogs[i].hp <= 0 or distance2(w.cogs[i].pos, w.pickups[k].pos) >
          120*120: continue
      var taken = false
      case w.pickups[k].kind
      of grenadePickup:
        if not w.equipment[i].grenade: w.equipment[i].grenade = true; taken = true
      of sprayPickup:
        if not w.equipment[i].sprayCan: w.equipment[i].sprayCan = true; taken = true
      of medkitPickup:
        if w.cogs[i].hp < 3: w.cogs[i].hp = 3; taken = true
      of armorPickup:
        if w.equipment[i].armor < 3: w.equipment[i].armor = 3; taken = true
      if taken:
        w.pickups[k].readyAt = w.tick+(if w.pickups[k].kind ==
            grenadePickup: 120 else: 720)
        break

proc stepEquipment(w: var World, commands: array[Seats, Command]) =
  if w.winner != -1: return
  var gunTargets: seq[tuple[attacker, victim: int]]
  var visual: seq[Paintball]
  for b in w.balls:
    if b.life > 1:
      var next = b; dec next.life; visual.add next
  w.balls = visual
  var flashes: seq[Blast]
  for b in w.blasts:
    if w.tick-b.tick < 24: flashes.add b
  w.blasts = flashes
  for i in 0..<Seats:
    if w.cogs[i].hp <= 0:
      if w.equipment[i].lives > 0:
        dec w.cogs[i].respawn
        if w.cogs[i].respawn <= 0:
          # Random endzone positions prevent spawn camping; solid fallback handles crowds.
          var placed = false
          for attempt in 0..<64:
            let x = w.rng.between(150, 800)
            let p = point(if team(i) == 0: x else: Width-x, w.rng.between(150, Height-150))
            if not w.movementBlocked(p, i, true):
              w.cogs[i].pos = p; w.cogs[i].goal = p; w.cogs[i].hp = 3
              w.cogs[i].shield = 36; placed = true; break
          if not placed: w.spawn(i)
      continue
    if w.cogs[i].shield > 0: dec w.cogs[i].shield
    if w.cogs[i].cooldown > 0: dec w.cogs[i].cooldown
    if w.equipment[i].sprayCooldown > 0: dec w.equipment[i].sprayCooldown
    let cmd = commands[i]
    if cmd.walk: w.cogs[i].goal = Point(x: clamp(cmd.goal.x, (minX()+100).int32, (maxX()-100).int32),
        z: clamp(cmd.goal.z, (minZ()+100).int32, (maxZ()-100).int32))
    if cmd.aim != Point(): w.cogs[i].aim = cmd.aim
    elif cmd.walk and cmd.goal != w.cogs[i].pos: w.cogs[i].aim = cmd.goal
    w.cogs[i].firing = cmd.shoot
    let dest = if cmd.direct: w.cogs[i].goal else: w.waypoint(w.cogs[i].pos,
        w.cogs[i].goal)
    let speed = if w.cogs[i].carrying: MoveSpeed*7 div 10 else: MoveSpeed
    if distance2(w.cogs[i].pos, dest) > speed.int64*speed:
      var v = direction(w.cogs[i].pos, dest, speed)
      let trench = w.trenchAt(w.cogs[i].pos)
      if trench >= 0:
        let t = w.trenches[trench]
        if abs(w.cogs[i].pos.x+v.x-(t.x+t.w div 2)) > abs(w.cogs[i].pos.x-(
            t.x+t.w div 2)): v.x = v.x div 5
        if abs(w.cogs[i].pos.z+v.z-(t.z+t.h div 2)) > abs(w.cogs[i].pos.z-(
            t.z+t.h div 2)): v.z = v.z div 5
      var p = w.cogs[i].pos; p.x+=v.x
      if not w.movementBlocked(p, i, true): w.cogs[i].pos = p
      p = w.cogs[i].pos; p.z+=v.z
      if not w.movementBlocked(p, i, true): w.cogs[i].pos = p
  for i in 0..<Seats:
    if w.cogs[i].hp <= 0: continue
    let cmd = commands[i]
    if w.equipment[i].grenade:
      if cmd.chargeGrenade: w.equipment[i].charge = min(
          GrenadeChargeTicks.int32, w.equipment[i].charge+1)
      elif w.equipment[i].charge > 0:
        w.grenades.add Lob(start: w.cogs[i].pos, target: w.grenadeTarget(i),
            owner: i.int32, releasedAt: w.tick,
            landsAt: w.tick+GrenadeFlightTicks)
        w.equipment[i].grenade = false; w.equipment[i].charge = 0
    if w.equipment[i].sprayCan:
      if cmd.shoot and w.equipment[i].sprayCooldown == 0:
        w.equipment[i].burst = SprayTicks
        w.equipment[i].sprayCooldown = SprayTicks+SprayRecoveryTicks
        w.equipment[i].sprayHits = 0
        w.equipment[i].sprayAim = direction(w.cogs[i].pos, w.cogs[i].aim, SprayReach)
    else:
      if w.equipment[i].windup > 0:
        dec w.equipment[i].windup
        if w.equipment[i].windup == 0:
          # Integer samples follow a hitscan corridor; each victim is tested only once.
          let origin = w.cogs[i].pos
          var aim = w.equipment[i].gunAim
          # Bounded triangular jitter approximates the original small angular spread.
          var jitter = w.rng.between(-32, 32)+w.rng.between(-32, 32)
          if visionRulesVersion >= 10:
            let target = Point(x: origin.x+aim.x, z: origin.z+aim.z)
            jitter = jitter*w.gunSpreadPercent(origin, target).int32 div 100
            aim = direction(Point(), aim, GunRange)
          aim = Point(x: aim.x-int32(int64(aim.z)*jitter div GunRange),
              z: aim.z+int32(int64(aim.x)*jitter div GunRange))
          let ray = direction(Point(), aim, GunRange)
          var checked: uint32 = 0
          var endPoint = origin
          block trace:
            for n in 1..(GunRange div 20):
              let p = Point(x: origin.x+ray.x*n.int32 div (GunRange div 20),
                  z: origin.z+ray.z*n.int32 div (GunRange div 20))
              if w.blocked(p, 0): break
              endPoint = p
              for j in 0..<Seats:
                if j == i or w.cogs[j].hp <= 0 or (checked and (1'u32 shl j)) != 0: continue
                if distance2(p, w.cogs[j].pos) > Radius.int64*Radius: continue
                if visionRulesVersion >= 9 and not w.lineClear(origin, w.cogs[
                    j].pos): continue
                checked = checked or (1'u32 shl j)
                let trench = w.trenchAt(w.cogs[j].pos)
                if trench >= 0 and trench != w.trenchAt(origin) and
                    w.rng.between(0, 99) < 70: continue
                gunTargets.add (i, j)
                break trace
          w.balls.add Paintball(pos: endPoint, velocity: Point(
              x: endPoint.x-origin.x, z: endPoint.z-origin.z), owner: i.int32, life: (if visionRulesVersion >= 9: 6 else: 2))
      elif cmd.shoot and w.cogs[i].cooldown == 0:
        w.equipment[i].windup = GunWindupTicks
        w.equipment[i].gunAim = if visionRulesVersion >= 10:
          Point(x: w.cogs[i].aim.x-w.cogs[i].pos.x,
              z: w.cogs[i].aim.z-w.cogs[i].pos.z)
        else: direction(w.cogs[i].pos, w.cogs[i].aim, GunRange)
        let slow = w.equipment[i].armor > 0 or w.cogs[i].carrying or w.trenchAt(
            w.cogs[i].pos) >= 0
        w.cogs[i].cooldown = int32(FireCooldownTicks*(if slow: 3 else: 1))
  # Targets were selected before damage, allowing simultaneous mutual kills.
  for hit in gunTargets: w.damage(hit.victim, hit.attacker, 1)
  for i in 0..<Seats:
    if w.equipment[i].burst > 0 and w.cogs[i].hp > 0:
      for j in 0..<Seats:
        let bit = 1'u32 shl j
        if visionRulesVersion >= 18 and w.cogs[j].shield > 0: continue
        if (w.equipment[i].sprayHits and bit) == 0 and w.sprayTouches(i, j):
          w.equipment[i].sprayHits = w.equipment[i].sprayHits or bit
          w.damage(j, i, SprayDamage)
      dec w.equipment[i].burst
  var airborne: seq[Lob]
  for g in w.grenades:
    if w.tick >= g.landsAt: w.explode(g.target, g.owner.int)
    else: airborne.add g
  w.grenades = airborne
  w.pickupEquipment()
  if visionRulesVersion>=13:
    w.updateTerritory()
    inc w.tick
    return
  for i in 0..<Seats:
    if w.cogs[i].hp <= 0: continue
    let side = team(i); let enemy = 1-side
    if not w.cogs[i].carrying and w.hearts[enemy].carrier < 0 and distance2(
        w.cogs[i].pos, w.hearts[enemy].pos) < 140*140:
      w.cogs[i].carrying = true; w.hearts[enemy].carrier = i.int32
    if w.cogs[i].carrying:
      w.hearts[enemy].pos = w.cogs[i].pos
      if (side == 0 and w.cogs[i].pos.x <= home(0).x) or (side == 1 and w.cogs[
          i].pos.x >= home(1).x):
        inc w.captures[side]; inc w.cogs[i].captures
        w.winner = side.int32
  var surviving: array[2, bool]
  for i in 0..<Seats:
    if w.cogs[i].hp > 0 or w.equipment[i].lives > 0: surviving[team(i)] = true
  if surviving[0] and not surviving[1]: w.winner = 0
  elif surviving[1] and not surviving[0]: w.winner = 1
  elif not surviving[0] and not surviving[1]: w.winner = -2
  inc w.tick
