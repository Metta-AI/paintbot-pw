## FFA-kin rules (mode "ffa_kin" on the live rules, 41): sixteen separate players, one life, neutral
## control hearts captured by a lone cog, great hearts that need three cogs, and kin-weighted
## scores. The engine reads only the family grouping (spawn) and r (territory boost), never
## genes; the kin invariance test proves it.
import std/unittest
import ../examples/paintbot/[sim, kinship]
import polyworld/rngs

proc ffaWorld(seed = 2026'i32, endTick = 0'i32): World =
  gameMode = gmFfaKin
  newWorld(seed, endTick)

proc emptyFfa(): World =
  ## An FFA world with every cog out of the match; tests place the cogs they need.
  result = ffaWorld()
  for i in 0..<Seats:
    result.cogs[i].hp = 0
    result.equipment[i].lives = 0

proc place(w: var World, slot: int, p: Point) =
  w.cogs[slot].hp = 3
  w.cogs[slot].shield = 0
  w.cogs[slot].pos = p
  w.cogs[slot].goal = p
  w.equipment[slot].lives = 1

proc near(p: Point, dx: int): Point = point(p.x.int+dx, p.z.int)

proc idle(): array[Seats, Command] = default(array[Seats, Command])

proc scriptedCommands(w: World): array[Seats, Command] =
  ## The golden test's scripted driver for FFA: walk to a heart, shoot the nearest living cog.
  for slot in 0..<Seats:
    let cog = w.cogs[slot]
    if cog.hp <= 0: continue
    result[slot].walk = true
    result[slot].goal = w.controlHearts[slot mod w.controlHearts.len].pos
    var best = -1
    var bestD = int64.high
    for other in 0..<Seats:
      if other == slot or w.cogs[other].hp <= 0: continue
      let d = distance2(cog.pos, w.cogs[other].pos)
      if d < bestD: best = other; bestD = d
    if best >= 0 and bestD <= ShotRange.int64 * ShotRange:
      result[slot].aim = w.cogs[best].pos
      result[slot].shoot = true
      result[slot].chargeGrenade = w.equipment[slot].grenade and w.tick mod 96 < 48

proc hashes(k: Kinship, seed: int32, ticks: int): seq[uint32] =
  kinshipOverride = some(k)
  var w = ffaWorld(seed)
  doAssert activeKinship == k
  while w.tick < ticks and w.winner == -1:
    w.step(w.scriptedCommands())
    result.add w.stateHash()
  kinshipOverride = none(Kinship)

suite "FFA-kin rules":
  setup:
    visionRulesVersion = 41
    kinshipOverride = none(Kinship)
    gameMode = gmFfaKin
  teardown:
    gameMode = gmTeams
    kinshipOverride = none(Kinship)

  test "an FFA match starts neutral, one life each, no uniforms, two mirrored great hearts":
    let w = ffaWorld()
    check w.endTick == FfaMatchTicks
    check w.winner == -1
    check activeKinship == sampleKinship(2026)
    for heart in w.controlHearts: check heart.owner == -1
    for capture in w.heartCaptures: check capture == HeartCapture(team: -1)
    for i in 0..<Seats: check w.equipment[i].lives == 1
    for pickup in w.pickups: check pickup.kind != uniformPickup
    check w.glory == [0'i32, 0]
    check w.greatHearts[1].pos == point(Width-w.greatHearts[0].pos.x.int, Height-w.greatHearts[0].pos.z.int)
    for heart in w.greatHearts:
      check not w.blocked(heart.pos)
      check heart.progress == 0 and heart.dormantUntil == 0
    check ffaWorld(2026, 14400).endTick == FfaMatchTicks
    check ffaWorld(2026, 240).endTick == 240

  test "families spawn together around distinct anchors; clones and strangers spawn too":
    for layout in [klFours, klPairs, klTriosLoner, klCousins, klStrangers, klClones]:
      for seed in [1'i32, 7, 2026]:
        let k = kinshipFor(layout, seed)
        kinshipOverride = some(k)
        var w = ffaWorld(seed)
        # A crowded start retries next tick; a few idle ticks seat everyone.
        for tick in 0..<24:
          var spawned = true
          for c in w.cogs:
            if c.hp <= 0: spawned = false
          if spawned: break
          w.step(idle())
        for i in 0..<Seats:
          check w.cogs[i].hp > 0
          check distance2(w.cogs[i].pos, w.spawnAnchor[i]) <= HeartSpawnRadius.int64*HeartSpawnRadius + 2*MoveSpeed*MoveSpeed
          for j in 0..<Seats:
            let together = k.family[i] >= 0 and k.family[i] == k.family[j]
            if i == j or together: check w.spawnAnchor[i] == w.spawnAnchor[j]
            else: check w.spawnAnchor[i] != w.spawnAnchor[j]

  test "a lone cog captures a neutral heart after 72 ticks and earns 10 tenths a second":
    var w = emptyFfa()
    w.place(0, w.controlHearts[2].pos)
    w.place(1, w.greatHearts[0].pos.near(-800)) # standing elsewhere, so the match goes on
    for tick in 1..<HeartCaptureTicks:
      w.updateTerritory()
      check w.controlHearts[2].owner == -1
      check w.heartCaptures[2] == HeartCapture(team: 0, ticks: tick.int32)
    w.updateTerritory()
    check w.controlHearts[2].owner == 0
    check w.heartCaptures[2] == HeartCapture(team: -1)
    check w.cogs[0].captures == 1
    # Income through the real step: exactly FfaHeartIncome per whole second of ownership.
    while w.tick mod TickRate != 1: w.step(idle())
    let score = w.seatScore[0]
    let seconds = w.heartSeconds[0]
    for tick in 0..<5*TickRate: w.step(idle())
    check w.winner == -1
    check w.seatScore[0] - score == 5*FfaHeartIncome
    check w.heartSeconds[0] - seconds == 5
    check w.seatScore[1] == 0

  test "a second cog of any kin pauses the capture; leaving resumes it":
    for layout in [klStrangers, klClones]:
      kinshipOverride = some(kinshipFor(layout, 3))
      var w = emptyFfa()
      w.place(0, w.controlHearts[2].pos)
      for tick in 0..<30: w.updateTerritory()
      w.place(1, w.controlHearts[2].pos.near(60))
      for tick in 0..<100: w.updateTerritory()
      check w.heartCaptures[2] == HeartCapture(team: 0, ticks: 30, contested: true)
      check w.controlHearts[2].owner == -1
      w.cogs[1].hp = 0
      for tick in 0..<41: w.updateTerritory()
      check w.controlHearts[2].owner == -1
      w.updateTerritory()
      check w.controlHearts[2].owner == 0

  test "an empty heart resets the capture, and the owner alone does not recapture":
    var w = emptyFfa()
    w.place(3, w.controlHearts[4].pos)
    for tick in 0..<40: w.updateTerritory()
    w.cogs[3].pos = w.greatHearts[0].pos
    w.updateTerritory()
    check w.heartCaptures[4] == HeartCapture(team: -1)
    w.controlHearts[4].owner = 3
    w.cogs[3].pos = w.controlHearts[4].pos
    for tick in 0..<100: w.updateTerritory()
    check w.heartCaptures[4] == HeartCapture(team: -1)
    check w.controlHearts[4].owner == 3
    check w.cogs[3].captures == 0

  test "a dead owner's hearts go neutral the same tick":
    var w = emptyFfa()
    w.place(5, w.controlHearts[2].pos)
    w.place(6, w.controlHearts[9].pos)
    w.controlHearts[2].owner = 5
    w.controlHearts[4].owner = 5
    w.controlHearts[6].owner = 6
    w.heartCaptures[3] = HeartCapture(team: 5, ticks: 40)
    w.damage(5, 6, 99)
    check w.cogs[5].hp == 0
    check w.equipment[5].lives == 0
    check w.controlHearts[2].owner == -1
    check w.controlHearts[4].owner == -1
    check w.controlHearts[6].owner == 6
    check w.heartCaptures[3] == HeartCapture(team: -1)

  test "one life: a dead cog never respawns, and the match ends at 8640 with winner -3":
    var w = ffaWorld()
    for tick in 0..<24: w.step(idle())
    for i in 0..<Seats: check w.cogs[i].hp > 0
    w.cogs[3].shield = 0
    w.damage(3, 4, 99)
    check w.equipment[3].lives == 0
    var seenAlive = false
    while w.winner == -1:
      w.step(idle())
      if w.cogs[3].hp > 0: seenAlive = true
    check not seenAlive
    check w.tick == FfaMatchTicks
    check w.winner == -3
    let before = w.stateHash()
    w.step(idle())
    check w.tick == FfaMatchTicks
    check w.stateHash() == before

  test "the match ends on the tick the second-to-last cog dies":
    var w = emptyFfa()
    w.place(0, w.controlHearts[2].pos)
    w.place(1, w.controlHearts[3].pos)
    w.place(2, w.controlHearts[5].pos)
    w.grenades.add Lob(start: w.cogs[2].pos, target: w.cogs[2].pos, owner: 0,
        releasedAt: w.tick, landsAt: w.tick)
    w.step(idle())
    check w.cogs[2].hp == 0
    check w.winner == -1
    let tick = w.tick
    w.grenades.add Lob(start: w.cogs[1].pos, target: w.cogs[1].pos, owner: 0,
        releasedAt: w.tick, landsAt: w.tick)
    w.step(idle())
    check w.cogs[1].hp == 0
    check w.tick == tick+1
    check w.winner == -3

  test "a great heart needs three cogs, pays the bounty equally, then sleeps a minute":
    var w = emptyFfa()
    let spot = w.greatHearts[0].pos
    w.place(0, spot)
    w.place(1, spot.near(120))
    w.greatHearts[0].progress = 50
    for tick in 0..<10:
      w.updateGreatHearts(); inc w.tick
    check w.greatHearts[0].progress == 40
    check w.greatHearts[0].present == 2
    w.greatHearts[0].progress = 0
    w.place(2, spot.near(-120))
    for tick in 1..<GreatHeartCaptureTicks:
      w.updateGreatHearts(); inc w.tick
      check w.greatHearts[0].progress == tick.int32
    check w.seatScore == default(array[Seats, int32])
    w.updateGreatHearts()
    for i in 0..2:
      check w.seatScore[i] == 200
      check w.greatShare[i] == 200
    check w.greatHearts[0].progress == 0
    check w.greatHearts[0].present == 3
    check w.greatHearts[0].dormantUntil == w.tick+GreatHeartDormantTicks
    inc w.tick
    for tick in 1..<GreatHeartDormantTicks:
      w.updateGreatHearts(); inc w.tick
      check w.greatHearts[0].progress == 0
    check w.seatScore[0] == 200
    # Awake again: four cogs split 600 into 150 each.
    w.place(3, spot.near(60))
    for tick in 0..<GreatHeartCaptureTicks:
      w.updateGreatHearts(); inc w.tick
    for i in 0..3: check w.greatShare[i] == (if i < 3: 350 else: 150)
    check w.greatHearts[1].progress == 0 and w.greatHearts[1].present == 0

  test "dead cogs neither capture nor count toward a quorum":
    var w = emptyFfa()
    let spot = w.greatHearts[1].pos
    w.place(0, spot); w.place(1, spot.near(100)); w.place(2, spot.near(-100))
    w.cogs[2].hp = 0
    for tick in 0..<GreatHeartCaptureTicks+5:
      w.updateGreatHearts(); inc w.tick
    check w.greatHearts[1].progress == 0
    check w.seatScore == default(array[Seats, int32])
    w.cogs[0].pos = w.controlHearts[2].pos
    w.cogs[0].hp = 0
    for tick in 0..<HeartCaptureTicks+5: w.updateTerritory()
    check w.controlHearts[2].owner == -1

  test "FFA fields are hashed only in FFA":
    var w = ffaWorld()
    let base = w.stateHash()
    w.seatScore[4] = 7
    check w.stateHash() != base
    gameMode = gmTeams
    var t = newWorld(2026)
    let teams = t.stateHash()
    t.seatScore[4] = 7
    t.greatHearts[0].progress = 3
    t.spawnAnchor[2] = point(1, 1)
    check t.stateHash() == teams

  test "kin invariance: same families and r, different genes, identical hashes":
    # The engine reads the family grouping (spawns) and r (the territory boost), never genes.
    for seed in [1'i32, 2026]:
      for layout in [klFours, klCousins, klTriosLoner]:
        let a = kinshipFor(layout, seed)
        var b = a
        b.genes = kinshipFor(layout, seed+1).genes
        check a.family == b.family and a.ibd == b.ibd
        check a.genes != b.genes
        let ha = hashes(a, seed, 1440)
        check ha.len == 1440
        check ha == hashes(b, seed, 1440)
    # The test can fail: a different family grouping moves the spawns...
    let fours = kinshipFor(klFours, 1)
    check hashes(fours, 1, 24) != hashes(kinshipFor(klPairs, 1), 1, 24)
    # ...and a different r (clones instead of siblings, same grouping) changes the territory
    # boost on kin ground, so the match diverges.
    var clones = fours
    for i in 0..<KinSeats:
      for j in 0..<KinSeats:
        if i == j or (fours.family[i] >= 0 and fours.family[i] == fours.family[j]): clones.ibd[i][j] = Loci.int8
        else: clones.ibd[i][j] = 0
    check clones.family == fours.family and clones.ibd != fours.ibd
    check hashes(fours, 1, 1440) != hashes(clones, 1, 1440)

  test "FFA cogs spawn with 10 HP and a medkit restores 10; teams cogs keep 3":
    var w = ffaWorld()
    check maxHp() == FfaMaxHp
    for i in 0..<Seats:
      check w.cogs[i].hp == FfaMaxHp
    var kit = -1
    for k, pickup in w.pickups:
      if pickup.kind == medkitPickup: kit = k
    check kit >= 0
    w.place(0, w.pickups[kit].pos)
    w.cogs[0].hp = 4
    w.step(idle())
    check w.cogs[0].hp == FfaMaxHp
    gameMode = gmTeams
    check maxHp() == 3
    let teams = newWorld(2026)
    for i in 0..<Seats:
      check teams.cogs[i].hp == 3

  test "FFA gun rays stop at 20 m; the same shot at 24 m hits in the teams game":
    proc shot(mode: GameMode, gap: int): int32 =
      ## Seat 0 fires once at seat 1 standing `gap` units away on a clear, dry, level line;
      ## returns the damage seat 1 took. Every other cog is parked out of play.
      gameMode = mode
      var w = newWorld(2026)
      for i in 2..<Seats:
        w.cogs[i].hp = 0
        w.cogs[i].respawn = 100000
        w.equipment[i].lives = 1
      var a, b: Point
      var found = false
      for z in countup(minZ()+300, maxZ()-300, 50):
        for x in countup(minX()+300, maxX()-300-gap, 50):
          a = point(x, z)
          b = point(x+gap, z)
          if w.blocked(a) or w.blocked(b) or not w.lineClear(a, b) or
              w.trenchAt(a) >= 0 or w.trenchAt(b) >= 0 or
              terrainHeight(a.x.int, a.z.int) != terrainHeight(b.x.int, b.z.int):
            continue
          var clear = true
          for n in 1..(gap div 20):
            if w.blocked(point(x+n*20, z), 0) or w.trenchAt(point(x+n*20, z)) >= 0: clear = false
          if clear:
            found = true
            break
        if found: break
      doAssert found
      for i in 0..1:
        w.cogs[i].pos = (if i == 0: a else: b)
        w.cogs[i].goal = w.cogs[i].pos
        w.cogs[i].shield = 0
        w.equipment[i].armor = 0
      let before = w.cogs[1].hp
      var fire = idle()
      fire[0].shoot = true
      fire[0].aim = b
      w.step(fire)
      for tick in 0..<8: w.step(idle())
      before - w.cogs[1].hp
    check shot(gmFfaKin, 1900) == 1
    check shot(gmFfaKin, 2400) == 0
    check shot(gmTeams, 2400) == 1
    check shot(gmTeams, 1900) == 1

  test "scores are kin-weighted raw scores in points":
    kinshipOverride = some(kinshipFor(klCousins, 5))
    var w = ffaWorld(5)
    for j in 0..<Seats: w.seatScore[j] = int32(j*10+3)
    let s = w.scores()
    check s.len == Seats
    for i in 0..<Seats:
      var expected = 0.0
      for j in 0..<Seats: expected += activeKinship.ibd[i][j].float / 32.0 * float(j*10+3)
      check abs(s[i] - expected / 10.0) < 1e-9
    kinshipOverride = some(kinshipFor(klStrangers, 5))
    w = ffaWorld(5)
    w.seatScore[3] = 420
    check w.scores()[3] == 42.0
    check w.scores()[4] == 0.0

proc ownAll(w: var World, owner: int32) =
  ## Every control heart owned by `owner` (-1 neutral), so every point is that seat's territory.
  for h in w.controlHearts.mitems: h.owner = owner

proc openLane(w: World, length: int): Point =
  ## A start point with `length` units of walkable, dry-looking, trench-free ground to its east.
  for z in countup(minZ()+400, maxZ()-400, 100):
    for x in countup(minX()+400, maxX()-400-length, 100):
      var clear = true
      for d in countup(0, length, 10):
        let p = point(x+d, z)
        if w.blocked(p) or w.trenchAt(p) >= 0: clear = false; break
      if clear: return point(x, z)
  doAssert false, "no open lane"

suite "FFA-kin territory boost":
  setup:
    visionRulesVersion = 41
    gameMode = gmFfaKin
    kinshipOverride = some(kinshipFor(klCousins, 7))
  teardown:
    gameMode = gmTeams
    kinshipOverride = none(Kinship)

  test "boost is 30 x r(me, owner of the nearest heart): own 30, sibling 15, cousin 7, stranger and neutral 0":
    var w = emptyFfa()
    let k = activeKinship
    var sibling, cousin, stranger = -1
    for j in 1..<Seats:
      case k.rPercent(0, j)
      of 50: sibling = j
      of 25: cousin = j
      of 0: stranger = j
      else: discard
    check sibling >= 0 and cousin >= 0 and stranger >= 0
    let heart = w.controlHearts[3].pos
    w.place(0, heart)
    check w.territoryOwner(heart) == -1
    check w.territoryBoost(0) == 0 # neutral
    for (owner, boost) in [(0, 30), (sibling, 15), (cousin, 7), (stranger, 0)]:
      w.controlHearts[3].owner = owner.int32
      check w.territoryOwner(heart) == owner.int32
      check w.territoryBoost(0) == boost
    # The nearest heart decides, ties to the lower index; a far heart's owner does not count.
    w.controlHearts[3].owner = -1
    for i, h in w.controlHearts.mpairs:
      if i != 3: h.owner = 0
    check w.territoryBoost(0) == 0
    gameMode = gmTeams
    check w.territoryBoost(0) == 0

  test "own territory moves a cog 30% faster than neutral ground":
    const Ticks = 10
    proc run(owner: int32): int =
      var w = emptyFfa()
      let start = w.openLane(40*Ticks + 200)
      w.place(0, start)
      w.place(1, point(if start.x > Width div 2: minX()+300 else: maxX()-300, start.z.int))
      var cmds = idle()
      cmds[0] = Command(walk: true, direct: true, goal: point(start.x.int + 40*Ticks + 150, start.z.int))
      for t in 0..<Ticks:
        w.ownAll(owner)
        w.step(cmds)
      w.cogs[0].pos.x - start.x
    var sibling = -1
    for j in 1..<Seats:
      if activeKinship.rPercent(0, j) == 50: sibling = j
    check run(-1) == MoveSpeed*Ticks
    check run(0) == (MoveSpeed*130 div 100)*Ticks # 36 a tick
    check run(sibling.int32) == (MoveSpeed*115 div 100)*Ticks # 32 a tick

  test "own territory narrows gun spread by 30%":
    # The same world twice, differing only in who owns the hearts: the same RNG draws give the
    # same jitter, which the boost scales by 70/100. Measured on the ray's lateral offset.
    var total: array[2, float]
    var shots = 0
    for seed in 1..12:
      var ends: array[2, Point]
      for arm, owner in [-1'i32, 0]:
        var w = emptyFfa()
        let start = w.openLane(2200)
        w.place(0, start)
        w.place(1, point(start.x.int, if start.z > Height div 2: minZ()+300 else: maxZ()-300))
        w.rng = initRng(seed.int32)
        var cmds = idle()
        cmds[0] = Command(shoot: true, aim: point(start.x.int + 1500, start.z.int))
        var fired = false
        for t in 0..<30:
          w.ownAll(owner)
          w.step(cmds)
          cmds[0].shoot = false
          for b in w.balls:
            if b.owner == 0 and b.velocity.x > 0:
              ends[arm] = b.velocity; fired = true
          if fired: break
        check fired
      # Lateral angle (z offset per unit x); the lane is flat, so the elevation factor is 100.
      let neutral = ends[0].z.float / ends[0].x.float
      let boosted = ends[1].z.float / ends[1].x.float
      check abs(boosted) <= abs(neutral) + 0.002
      total[0] += abs(neutral); total[1] += abs(boosted)
      inc shots
    check shots == 12 and total[0] > 0
    check abs(total[1] / total[0] - 0.7) < 0.05

  test "the teams game has no territory boost":
    gameMode = gmTeams
    kinshipOverride = none(Kinship)
    var w = newWorld(2026)
    for h in w.controlHearts.mitems: h.owner = 0
    for i in 0..<Seats: check w.territoryBoost(i) == 0

suite "FFA-kin on generated maps (rules 41)":
  setup:
    visionRulesVersion = 41
    kinshipOverride = none(Kinship)
    gameMode = gmFfaKin
  teardown:
    configureMap("")
    gameMode = gmTeams
    kinshipOverride = none(Kinship)

  proc seated(w: var World) =
    ## A crowded start retries next tick; a few idle ticks seat everyone.
    for tick in 0..<24:
      var spawned = true
      for c in w.cogs:
        if c.hp <= 0: spawned = false
      if spawned: break
      w.step(idle())

  for name in MapNames:
    test name & ": FFA layout from the map's items, valid spawns and great hearts":
      configureMap(name)
      for seed in [1'i32, 2026]:
        var w = ffaWorld(seed)
        check w.controlHearts.len == currentMap().hearts.len
        for heart in w.controlHearts: check heart.owner == -1
        check w.captures == [0'i32, 0]
        for i in 0..<Seats: check w.equipment[i].lives == 1
        for pickup in w.pickups: check pickup.kind != uniformPickup
        check w.greatHearts[1].pos == point(Width-w.greatHearts[0].pos.x.int, Height-w.greatHearts[0].pos.z.int)
        for heart in w.greatHearts: check not w.blocked(heart.pos)
        w.seated()
        for i in 0..<Seats:
          check w.cogs[i].hp > 0
          check not w.blocked(w.cogs[i].pos)
          check not w.blocked(w.spawnAnchor[i])
          check distance2(w.cogs[i].pos, w.spawnAnchor[i]) <= HeartSpawnRadius.int64*HeartSpawnRadius + 2*MoveSpeed*MoveSpeed

  test "archipelago: a scripted FFA match runs 1440 ticks without a crash":
    configureMap("archipelago")
    var w = ffaWorld(7)
    var shots = 0
    while w.tick < 1440 and w.winner == -1:
      w.step(w.scriptedCommands())
      shots += w.balls.len
      for i in 0..<Seats:
        if w.cogs[i].hp > 0: check not w.blocked(w.cogs[i].pos)
    check w.tick == 1440 or w.winner == -3
    check shots > 0
