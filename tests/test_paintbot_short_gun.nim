## Rules 49 short guns: rays stop at ShortGunRange (21 m, about half the bases' distance), aim error is
## wider, and past a third of the reach a ball that reaches a cog may land as a dud. Hit rates are
## measured through the engine: a still cog on level, open ground, aimed at dead centre, each shot
## from a fresh copy of one world with its own RNG seed.
import std/[unittest, strutils]
import polyworld/rngs
import ../examples/paintbot/[sim, game]

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

proc hitRate(rules, distance, shots: int): float =
  visionRulesVersion = rules
  var base = newWorld(2026)
  base.cover = @[]
  base.trenches = @[]
  base.pickups = @[]
  let (origin, target) = base.lane(distance)
  for i in 0..<Seats:
    base.cogs[i].shield = 0
    base.equipment[i].armor = 0
    if i > 1:
      base.cogs[i].hp = 0
      base.cogs[i].respawn = 100000
  base.cogs[0].pos = origin; base.cogs[0].goal = origin; base.cogs[0].cooldown = 0
  base.cogs[1].pos = target; base.cogs[1].goal = target
  var hits = 0
  for shot in 0..<shots:
    var w = base
    w.rng = initRng(int32(shot+1))
    let hp = w.cogs[1].hp
    var c: array[LegacySeats, Command]
    c[0] = Command(shoot: true, aim: target)
    w.step(c)
    c[0] = Command(aim: target)
    for tick in 0..<GunWindupTicks: w.step(c)
    doAssert w.winner == -1 and w.cogs[0].pos == origin and w.cogs[1].pos == target
    if w.cogs[1].hp < hp: inc hits
  hits / shots

suite "Short guns (rules 49)":
  teardown:
    visionRulesVersion = LiveRules
    replayRulesVersion = LiveRules
    gameMode = gmTeams
  test "live rules are 49":
    check LiveRules == 49 and ShortGunRules == 49
    check replayRulesVersion == 49
  test "the gun reaches 21 m from rules 49; FFA-kin keeps 20 m":
    visionRulesVersion = 48
    check gunReach() == GunRange
    visionRulesVersion = 49
    check gunReach() == 2133
    gameMode = gmFfaKin
    check gunReach() == FfaGunRange
  test "dud chance: none within a third of the reach, rising to half at full reach":
    visionRulesVersion = 48
    check gunDudPercent(2133) == 0
    visionRulesVersion = 49
    check gunDudPercent(0) == 0
    check gunDudPercent(711) == 0
    check gunDudPercent(1422) == 25
    check gunDudPercent(2133) == 50
    check gunDudPercent(4000) == 50
  test "about 80% of shots at full reach fail to land":
    let rate = hitRate(49, 2120, 4000)
    checkpoint "hit rate at 2120: " & formatFloat(rate, ffDecimal, 3)
    check rate in 0.17..0.23
  test "hit rate falls off smoothly with range":
    let near = hitRate(49, 500, 600)
    let mid = hitRate(49, 1000, 1500)
    let far = hitRate(49, 1500, 1500)
    checkpoint "500: " & $near & "  1000: " & $mid & "  1500: " & $far
    check near >= 0.95
    check mid in 0.58..0.74
    check far in 0.32..0.46
  test "nothing is hit beyond the reach":
    check hitRate(49, 2250, 300) == 0.0
  test "rules 48 guns are unchanged: long, accurate, no duds":
    check hitRate(48, 2500, 300) >= 0.95
