## Heartland lake hearts (rules 44, FFA only). Heartwick's two lake hearts (3200,1250) and
## (3200,2750) sit in the water, and so do the medkits 83 units off them. Under the rules-38 wet
## routing a cog on dry land took anchors and pulled strings only over dry cells, so with a wet
## goal it walked to the shore cell nearest the goal and stood there, about 300 units short and
## out of the 140-unit capture ring, for as long as it kept that goal (eight hosted Heartland
## replays at 1041: 71 stalls of 5 s or more beside a lake heart, one 136 s long). Rules 44 let
## an FFA cog on dry land route into the lake when the goal's own cell is wet; the time-weighted
## field still keeps it dry for as long as that is faster. The teams game and FFA rules 40-43
## are unchanged, so recorded matches replay as they were played.
import std/[unittest, math]
import ../examples/paintbot/[sim, kinship, topography]

const
  NorthLake = point(3200, 1250)
  SouthLake = point(3200, 2750)
  # Where hosted ffa.bas cogs stood still (dry, about 300-320 units from the heart).
  NorthShore = point(3143, 933)
  SouthShore = point(3141, 3059)
  SouthMedkit = point(3200, 2667)

proc emptyFfa(rules: int): World =
  visionRulesVersion = rules
  configureRules(rules)
  gameMode = gmFfaKin
  kinshipOverride = some(kinshipFor(klStrangers, 5))
  result = newWorld(2026, 0)
  for i in 0..<Seats:
    result.cogs[i].hp = 0
    result.equipment[i].lives = 0

proc place(w: var World, slot: int, p: Point) =
  w.cogs[slot].hp = 3
  w.cogs[slot].shield = 0
  w.cogs[slot].pos = p
  w.cogs[slot].goal = p
  w.equipment[slot].lives = 1

proc heartAt(w: World, p: Point): int =
  result = -1
  for i, h in w.controlHearts:
    if h.pos == p: return i

proc walkFor(w: var World, slot: int, goal: Point, ticks: int): int =
  ## Walks `slot` toward goal for up to `ticks`; the tick the heart at goal (if any) became
  ## the seat's, or -1. Stops early once owned.
  let heart = w.heartAt(goal)
  result = -1
  for t in 0..<ticks:
    var commands: array[Seats, Command]
    commands[slot].walk = true
    commands[slot].goal = goal
    w.step(commands)
    if heart >= 0 and w.controlHearts[heart].owner == slot.int32: return t+1

proc run(rules, slot: int, start, goal: Point, ticks: int): (int, int) =
  ## (capture tick or -1, final distance to goal)
  var w = emptyFfa(rules)
  w.place(slot, start)
  w.place((slot+1) mod Seats, w.greatHearts[0].pos) # a second cog far away keeps the match on
  let captured = w.walkFor(slot, goal, ticks)
  (captured, int(sqrt(float(distance2(w.cogs[slot].pos, goal)))))

suite "FFA lake hearts":
  teardown:
    gameMode = gmTeams
    kinshipOverride = none(Kinship)
    visionRulesVersion = 44
    configureRules(44)

  test "the lake hearts and their medkits are in the water; the stall points are dry":
    var w = emptyFfa(44)
    check w.heartAt(NorthLake) >= 0 and w.heartAt(SouthLake) >= 0
    for p in [NorthLake, SouthLake, SouthMedkit]:
      check riverBlend(p.x.int, p.z.int) > 0 and terrainHeight(p.x.int, p.z.int) < RiverWaterHeight
    for p in [NorthShore, SouthShore]:
      check terrainHeight(p.x.int, p.z.int) >= RiverWaterHeight
      check not w.blocked(p)

  test "rules 44: a lone cog on the shore wades in and captures a lake heart":
    for slot in [0, 1]: # both mirror classes of the route search
      for (start, heart) in [(NorthShore, NorthLake), (SouthShore, SouthLake)]:
        let (captured, _) = run(44, slot, start, heart, 20*TickRate)
        check captured > HeartCaptureTicks
        check captured <= 12*TickRate

  test "rules 44: a cog on the shore reaches the lake medkit":
    for slot in [0, 1]:
      let (_, d) = run(44, slot, SouthShore, SouthMedkit, 10*TickRate)
      check d <= 2*Radius

  test "rules 40-43 FFA keep the shore stall (recorded matches replay unchanged)":
    for rules in [40, 41, 42, 43]:
      for (start, heart) in [(NorthShore, NorthLake), (SouthShore, SouthLake)]:
        let (captured, d) = run(rules, 0, start, heart, 20*TickRate)
        check captured == -1
        check d > ControlHeartRadius

  test "rules 44 teams routing is rules 43's (the fix is FFA only)":
    var answers: array[2, seq[Point]]
    for k, rules in [43, 44]:
      visionRulesVersion = rules
      configureRules(rules)
      gameMode = gmTeams
      var w = newWorld(2026, 0)
      for (start, heart) in [(NorthShore, NorthLake), (SouthShore, SouthLake)]:
        for slot in [0, 1]:
          # The rules-38 shore anchor: a dry cell centre, far outside the capture ring.
          let wp = w.waypointFor(slot, start, heart)
          check terrainHeight(wp.x.int, wp.z.int) >= RiverWaterHeight
          check distance2(wp, heart) > ControlHeartRadius*ControlHeartRadius
          answers[k].add wp
    check answers[0] == answers[1]

  test "rules 44 FFA: a dry cog far from a wet goal still walks round the lake, not through it":
    # From the far shore the straight line to the north lake heart is all water; the dry
    # shortcut rule still refuses it, so the first waypoint is not the goal itself.
    var w = emptyFfa(44)
    let far = point(3200, 3300)
    check terrainHeight(far.x.int, far.z.int) >= RiverWaterHeight
    check w.waypointFor(0, far, NorthLake) != NorthLake
