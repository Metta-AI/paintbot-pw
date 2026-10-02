## Rules 49 items and actions: the windex-mister, the sniper rifle, the radar and self-destruct, plus
## the teams game's 10 HP and single life. Each test builds a rules-49 world with no cover, trenches
## or pickups, stands the cogs it needs on open dry ground near the island's centre-west, and steps
## the real engine.
import std/[unittest, os, math]
import polyworld/[rngs, tapes]
import ../examples/paintbot/[sim, game]

const Site = Point(x: 2060, z: 2940) # dry, open ground (the rules-49 mister spot)

proc at(dx, dz: int): Point = point(Site.x.int+dx, Site.z.int+dz)

proc arena(rules = 49): World =
  visionRulesVersion = rules
  replayRulesVersion = rules
  result = newWorld(2026)
  result.cover = @[]
  result.trenches = @[]
  result.pickups = @[]
  for i in 0..<Seats:
    result.cogs[i].shield = 0
    result.equipment[i].armor = 0

proc place(w: var World, seat: int, p: Point, hp = -1) =
  doAssert not w.blocked(p), "blocked test spot"
  w.cogs[seat].pos = p; w.cogs[seat].goal = p
  if hp >= 0: w.cogs[seat].hp = hp.int32

proc idle(w: var World, ticks: int) =
  var c: array[LegacySeats, Command]
  for t in 0..<ticks: w.step(c)

proc give(w: var World, seat: int, kind: PickupKind) =
  ## Drops a pickup under the seat and steps once so it is collected.
  w.pickups = @[Pickup(pos: w.cogs[seat].pos, kind: kind)]
  w.idle(1)
  w.pickups = @[]

proc lane(w: World, distance: int): (Point, Point) =
  ## An origin and a target `distance` east of it on the same height, with nothing between.
  for z in countup(minZ()+600, maxZ()-600, 100):
    for x in countup(minX()+600, maxX()-600-distance, 100):
      let a = point(x, z)
      let b = point(x+distance, z)
      if w.elevation(a) != w.elevation(b) or w.blocked(a) or w.blocked(b): continue
      if not w.lineClear(a, b): continue
      var open = true
      for n in 1..(distance+200) div 20:
        if w.blocked(point(x+n*20, z), 0):
          open = false
          break
      if open: return (a, b)
  doAssert false, "no open lane " & $distance & " long"

suite "Rules 49: teams cogs carry 10 HP and one life":
  teardown:
    visionRulesVersion = LiveRules; replayRulesVersion = LiveRules; gameMode = gmTeams
  test "rules 49 teams: 10 HP, 1 life; rules 48: 3 HP, 4 lives":
    let w49 = arena(49)
    check maxHp() == 10 and w49.cogs[0].hp == 10 and w49.equipment[0].lives == 1
    let w48 = arena(48)
    check maxHp() == 3 and w48.cogs[0].hp == 3 and w48.equipment[0].lives == 4
  test "a cog killed at rules 49 never respawns":
    var w = arena()
    w.place(0, at(0, 0), hp = 1)
    w.damage(0, 1, 1)
    w.idle(10*TickRate)
    check w.cogs[0].hp == 0 and w.equipment[0].lives == 0

suite "Rules 49: items are placed on the island":
  teardown:
    visionRulesVersion = LiveRules; replayRulesVersion = LiveRules; gameMode = gmTeams
  test "one mirrored pair each of mister, sniper and radar, on dry open ground, in both modes":
    for mode in [gmTeams, gmFfaKin]:
      gameMode = mode
      visionRulesVersion = 49
      let w = newWorld(7)
      for kind in [misterPickup, sniperPickup, radarPickup]:
        var spots: seq[Point]
        for p in w.pickups:
          if p.kind == kind: spots.add p.pos
        check spots.len == 2
        if spots.len == 2: check point(Width-spots[0].x.int, Height-spots[0].z.int) == spots[1]
        for s in spots:
          check not w.blocked(s)
          check riverBlend(s.x.int, s.z.int) == 0
          for o in w.pickups:
            if o.pos != s: check distance2(o.pos, s) >= 300*300
          for h in w.controlHearts: check distance2(h.pos, s) >= 300*300
  test "generated maps carry them from rules 49 only":
    for rules in [48, 49]:
      visionRulesVersion = rules
      configureMap("crater")
      let w = newWorld(7)
      var n = 0
      for p in w.pickups:
        if p.kind in {misterPickup, sniperPickup, radarPickup}: inc n
      check n == (if rules >= 49: 6 else: 0)
    configureMap("")
  test "rules 48 islands carry none of them":
    visionRulesVersion = 48
    let w = newWorld(7)
    for p in w.pickups: check p.kind notin {misterPickup, sniperPickup, radarPickup}

suite "Rules 49: windex-mister":
  teardown:
    visionRulesVersion = LiveRules; replayRulesVersion = LiveRules; gameMode = gmTeams
  test "heals 1 HP every 15 s for a minute to every cog within 5 m, any team, itself too":
    var w = arena()
    w.place(0, at(0, 0), hp = 5)      # the mister
    w.place(1, at(300, 0), hp = 5)    # enemy inside
    w.place(2, at(0, 450), hp = 5)    # ally inside
    w.place(3, at(-620, 0), hp = 5)   # enemy outside (beyond 500)
    w.place(4, at(0, -480), hp = 9)   # ally inside, one short of max
    w.give(0, misterPickup)
    check w.misting(0)
    let start = w.tick-1                 # the tick it was picked up
    w.idle(int(start+MisterHealTicks-w.tick))   # through tick start + 15 s - 1
    check w.cogs[0].hp == 5 and w.cogs[1].hp == 5
    w.idle(1)                            # tick start + 15 s
    check w.cogs[0].hp == 6 and w.cogs[1].hp == 6 and w.cogs[2].hp == 6
    check w.cogs[3].hp == 5 and w.cogs[4].hp == 10
    w.idle(3*MisterHealTicks)            # through the last heal at start + 60 s
    check w.cogs[0].hp == 9 and w.cogs[1].hp == 9 and w.cogs[2].hp == 9
    check w.cogs[3].hp == 5 and w.cogs[4].hp == 10
    check not w.misting(0)
    w.idle(MisterHealTicks)
    check w.cogs[0].hp == 9
  test "a misting cog cannot shoot, spray, throw or self-destruct for exactly a minute":
    var w = arena()
    w.place(0, at(0, 0))
    w.place(1, at(400, 0))
    w.give(0, misterPickup)
    let until = w.misterUntil[0]
    var c: array[LegacySeats, Command]
    c[0] = Command(shoot: true, aim: w.cogs[1].pos, chargeGrenade: true, selfDestruct: true)
    w.equipment[0].grenade = true
    while w.tick < until:
      w.step(c)
      check w.equipment[0].windup == 0 and w.equipment[0].charge == 0
      check w.cogs[0].hp > 0
    # Picked up at the end of tick until - MisterTicks, so ticks until-MisterTicks+1 .. until are
    # locked: exactly a minute. The last one heals and ends the mister.
    w.step(c)
    check w.cogs[0].hp > 0 and w.equipment[0].windup == 0
    check not w.misting(0)
    c[0].selfDestruct = false
    w.step(c)                            # the next tick the gun winds up again
    check w.equipment[0].windup == GunWindupTicks
  test "death ends the mister":
    var w = arena()
    w.place(0, at(0, 0), hp = 1)
    w.give(0, misterPickup)
    w.damage(0, 1, 1)
    check not w.misting(0)

suite "Rules 49: sniper rifle":
  teardown:
    visionRulesVersion = LiveRules; replayRulesVersion = LiveRules; gameMode = gmTeams
  test "hits a still cog at 47 m almost every time, and fires once every 4 s":
    var base = arena()
    let (origin, target) = base.lane(4700)
    for i in 2..<Seats: base.cogs[i].pos = at(0, (i-2)*130) # out of the lane
    base.place(0, origin); base.place(1, target)
    base.sniper[0] = true
    var hits = 0
    for shot in 0..<200:
      var w = base
      w.rng = initRng(int32(shot+1))
      let hp = w.cogs[1].hp
      var c: array[LegacySeats, Command]
      c[0] = Command(shoot: true, aim: target)
      w.step(c)
      check w.cogs[0].cooldown == SniperCooldownTicks
      c[0] = Command(aim: target)
      for t in 0..<GunWindupTicks: w.step(c)
      if w.cogs[1].hp < hp: inc hits
      check hp-w.cogs[1].hp in 0..1  # sniper damage is 1
    check hits >= 190
  test "the plain gun cannot reach that far":
    var w = arena()
    let (origin, target) = w.lane(4700)
    w.place(0, origin); w.place(1, target)
    var c: array[LegacySeats, Command]
    c[0] = Command(shoot: true, aim: target)
    w.step(c)
    check w.cogs[0].cooldown == FireCooldownTicks
    c[0] = Command(aim: target)
    for t in 0..<GunWindupTicks: w.step(c)
    check w.cogs[1].hp == 10
  test "sniper and spray can share one slot; death drops the sniper":
    var w = arena()
    w.place(0, at(0, 0))
    w.give(0, sniperPickup)
    check w.hasSniper(0)
    w.give(0, sprayPickup)
    check not w.equipment[0].sprayCan
    w.place(2, at(0, 300))
    w.give(2, sprayPickup)
    w.give(2, sniperPickup)
    check w.equipment[2].sprayCan and not w.hasSniper(2)
    w.damage(0, 1, 10)
    check not w.hasSniper(0)
  test "a hit does not shorten a sniper's cooldown below its cadence":
    var w = arena()
    w.place(0, at(0, 0))
    w.sniper[0] = true
    w.cogs[0].cooldown = 80
    w.damage(0, 1, 1)
    check w.cogs[0].cooldown == 80

suite "Rules 49: self-destruct":
  teardown:
    visionRulesVersion = LiveRules; replayRulesVersion = LiveRules; gameMode = gmTeams
  test "the bomber dies and deals its HP to every cog in the grenade blast, allies included":
    var w = arena()
    w.place(0, at(0, 0), hp = 7)
    w.place(2, at(200, 0))              # ally inside
    w.place(1, at(0, 400))              # enemy inside (blast 360 + body 55)
    w.place(3, at(-480, 0))             # enemy outside
    w.place(5, at(0, -300))             # enemy inside, armored
    w.equipment[5].armor = 3
    w.equipment[0].armor = 3; w.cogs[0].shield = 20 # neither saves the bomber
    var c: array[LegacySeats, Command]
    c[0] = Command(selfDestruct: true)
    w.step(c)
    check w.cogs[0].hp == 0 and w.equipment[0].lives == 0
    check w.cogs[2].hp == 3 and w.cogs[1].hp == 3
    check w.cogs[3].hp == 10
    check w.cogs[5].hp == 6 and w.equipment[5].armor == 0
    check w.blasts.len == 1 and w.blasts[0].owner == 0
  test "rules 48 ignores the order":
    var w = arena(48)
    w.place(0, at(0, 0))
    var c: array[LegacySeats, Command]
    c[0] = Command(selfDestruct: true)
    w.step(c)
    check w.cogs[0].hp == 3
  test "a rules-49 recording keeps the order, and a rules-48 recording still round-trips":
    for rules in [48, 49]:
      visionRulesVersion = rules; replayRulesVersion = rules
      var r = Recording(seed: 5, endTick: 2000, seats: Seats.int32)
      for t in 0..<3:
        var f = Frame(hash: uint32(t), commands: newSeq[Command](Seats))
        f.commands[1] = Command(walk: true, goal: point(100, 200), sneak: true, chargeGrenade: true)
        f.commands[2] = Command(selfDestruct: rules >= 49)
        r.frames.add f
      let path = getTempDir() / ("paintbot-rules49-destruct-" & $rules & "-" & $getCurrentProcessId() & ".replay")
      defer: removeFile(path)
      saveRecording(path, r)
      check loadReplayFileHeader(path).gameVersion.int == rules
      let back = loadRecording(path)
      check back.frames == r.frames

suite "Rules 49: radar":
  teardown:
    visionRulesVersion = LiveRules; replayRulesVersion = LiveRules; gameMode = gmTeams
  test "every cog within 8 m of the carrier deals double damage, whatever its side":
    var w = arena()
    w.place(0, at(0, 0))                # carrier
    w.place(1, at(700, 0))              # enemy of the carrier, inside
    w.place(2, at(0, 600))              # ally, inside
    w.place(3, at(-900, 0))             # enemy, outside
    w.place(5, at(0, -700))             # victim
    w.give(0, radarPickup)
    check w.hasRadar(0)
    check w.radarBoosted(1) and w.radarBoosted(2) and not w.radarBoosted(3)
    w.damage(5, 1, 1); check w.cogs[5].hp == 8
    w.damage(5, 2, 1); check w.cogs[5].hp == 6
    w.damage(5, 3, 1); check w.cogs[5].hp == 5
  test "the carrier cannot attack and moves at 60% speed":
    var w = arena()
    w.place(0, at(0, 0)); w.place(2, at(0, 1200))
    w.give(0, radarPickup)
    var c: array[LegacySeats, Command]
    c[0] = Command(walk: true, goal: at(800, 0), direct: true, shoot: true, aim: at(800, 0))
    c[2] = Command(walk: true, goal: at(800, 1200), direct: true)
    w.step(c)
    check w.equipment[0].windup == 0
    let a = w.cogs[0].pos; let b = w.cogs[2].pos
    for t in 0..<10: w.step(c)
    let slow = sqrt(distance2(a, w.cogs[0].pos).float)
    let normal = sqrt(distance2(b, w.cogs[2].pos).float)
    check abs(slow/normal - 0.6) < 0.05
  test "gunRange() follows the rules and the sniper":
    var w = arena(48)
    check gunReach() == 5250
    w = arena(49)
    check gunReach() == 2133
    w.sniper[0] = true
    check (if w.hasSniper(0): SniperRange else: gunReach()) == 4800
  test "it lasts a minute, or until the carrier picks up anything else":
    var w = arena()
    w.place(0, at(0, 0))
    w.give(0, radarPickup)
    w.idle(RadarTicks-2)
    check w.hasRadar(0)
    w.idle(2)
    check not w.hasRadar(0)
    w.give(0, radarPickup)
    check w.hasRadar(0)
    w.give(0, grenadePickup)
    check not w.hasRadar(0) and w.equipment[0].grenade
