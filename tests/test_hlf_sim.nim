## Heartleaf simulation: determinism, dinner scoring to the exact point,
## command validation, the 17:59 door crush, and a whole bot-driven week.

import
  std/strformat,
  ../examples/heartleaf/content,
  ../examples/heartleaf/maps,
  ../examples/heartleaf/sim,
  ../examples/heartleaf/bots

let gameMap = generateMap(DefaultSeed)
gameMap.validateMap()

proc gatherAndParty(w: World) =
  ## A deterministic scripted decision: gather the nearest stocked garden,
  ## and from 16:30 walk into Ivan's house.
  for slot in 0'i32 ..< int32(VillagerCount):
    let v = w.villagers[slot]
    if w.minuteOfDay >= 16 * 60 + 30 and not w.dinnerDone:
      if v.inHouse < 0 and v.order != EnterOrder:
        discard w.applyEnterHouse(slot, 0)
      continue
    if v.order != NoOrder or v.inHouse >= 0:
      continue
    var
      best = -1'i32
      bestDist = int32.high
    for garden in 0'i32 ..< int32(GardenCount):
      if w.gardens[garden] < 0:
        continue
      let dist = chebyshev(v.tile, w.map.gardenTiles[garden])
      if dist < bestDist:
        bestDist = dist
        best = garden
    if best >= 0:
      discard w.applyGather(slot, best)

echo "Testing determinism: two identical games, one hash stream"
block twinWorlds:
  let
    first = newGame(gameMap, 2)
    second = newGame(gameMap, 2)
  while not first.world.over:
    first.world.tickWorld(gatherAndParty)
    second.world.tickWorld(gatherAndParty)
    if first.world.tick mod 100 == 0:
      doAssert first.stateHash() == second.stateHash(),
        &"twin worlds diverged at tick {first.world.tick}"
  doAssert second.world.over
  doAssert first.stateHash() == second.stateHash()

echo "Testing the dinner tally to the exact point"
block exactScoring:
  var w = newWorld(gameMap, 7)
  ## Hand-build the 18:00 moment: Ivan hosts Anton and Yura with four
  ## carrots and one tomato on the table. Everyone else stays outside.
  w.villagers[0].inventory[0] = 4  # carrots
  w.villagers[0].inventory[1] = 1  # a tomato
  w.villagers[0].inHouse = 0
  w.villagers[1].inHouse = 0
  w.villagers[2].inHouse = 0
  ## Yura has already tasted carrot this week.
  w.villagers[2].eaten[0] = true
  w.runDinnerTally()

  ## Host multiplier: five items times two visitors.
  doAssert w.lastTally[0].valid
  doAssert w.lastTally[0].visitors == 2
  doAssert w.lastTally[0].pantry == 5
  doAssert w.lastTally[0].hostPoints == 10

  ## Bites: three rounds, three diners, five items, so the pantry runs dry
  ## after five bites. The draw prefers an untasted best-stocked kind, so
  ## every first carrot is +3 except Yura's (+1), and whoever draws the
  ## tomato gets +3. Total eating points: 3 + 3 + 1 + 3 + 1 = 11, however
  ## the seating shuffle lands.
  var eatingPoints = 0'i32
  for slot in 0 ..< VillagerCount:
    eatingPoints += w.villagers[slot].score
  eatingPoints -= w.lastTally[0].hostPoints
  doAssert eatingPoints == 11,
    &"expected 11 eating points, got {eatingPoints}"

  ## Hosting empties the pantry.
  doAssert w.villagers[0].carriedTotal() == 0
  ## Nobody outside a valid party scored.
  for slot in 3 ..< VillagerCount:
    doAssert w.villagers[slot].score == 0

block aloneScoresNothing:
  var w = newWorld(gameMap, 7)
  w.villagers[0].inventory[0] = 9
  w.villagers[0].inHouse = 0
  w.runDinnerTally()
  doAssert not w.lastTally[0].valid
  doAssert w.villagers[0].score == 0
  doAssert w.villagers[0].carriedTotal() == 9,
    "an invalid party should not clear the pantry"

block visitorsWithoutTheHostScoreNothing:
  var w = newWorld(gameMap, 7)
  w.villagers[1].inHouse = 0
  w.villagers[2].inHouse = 0
  w.runDinnerTally()
  doAssert not w.lastTally[0].valid
  doAssert w.villagers[1].score == 0 and w.villagers[2].score == 0

echo "Testing command validation"
block inviteRules:
  var w = newWorld(gameMap, 7)
  ## Villagers start on their own doorsteps, a ring apart.
  doAssert not w.applyInvite(0, 0), "self-invitation was accepted"
  doAssert not w.applyInvite(0, 1), "a cross-village shout was accepted"
  ## Walk them together: teleport via the door of one house.
  doAssert w.applyEnterHouse(0, 0)
  doAssert not w.applyInvite(0, 1), "an indoor host invited someone"
  doAssert w.applyExitHouse(0)
  ## Stand villager one next to villager zero by entering and leaving the
  ## same house, which parks both on the same doorstep.
  doAssert w.applyEnterHouse(1, 0) # walks; not there yet, so still refused
  doAssert not w.applyInvite(0, 1)
  ## Accepting an invitation that was never made is refused.
  doAssert not w.applyAccept(1, 0)
  ## And declining one too.
  doAssert not w.applyDecline(1, 0)

block gatherRace:
  var w = newWorld(gameMap, 7)
  ## Two villagers race for one plot. Whoever arrives first empties it and
  ## the loser's order fails.
  let garden = 0'i32
  doAssert w.applyGather(0, garden)
  doAssert w.applyGather(1, garden)
  var guard = 0
  while (w.villagers[0].order == GatherOrder or
      w.villagers[1].order == GatherOrder) and guard < DayTicks:
    w.tickWorld(nil)
    inc guard
  let taken = w.villagers[0].carriedTotal() + w.villagers[1].carriedTotal()
  doAssert taken == 1, &"one plot yielded {taken} items"
  doAssert w.villagers[0].orderFailed or w.villagers[1].orderFailed,
    "the losing gatherer was never told"
  doAssert w.gardens[garden] < 0, "the plot still holds food"

block houseRules:
  var w = newWorld(gameMap, 7)
  doAssert not w.applyExitHouse(0), "exited a house while outdoors"
  doAssert w.applyEnterHouse(0, 0), "the owner could not head home"
  doAssert w.villagers[0].inHouse == 0,
    "standing on the doorstep should enter immediately"
  doAssert not w.applyEnterHouse(0, 1), "entered a house from inside one"
  doAssert w.applyExitHouse(0)
  doAssert w.villagers[0].inHouse == -1

echo "Testing the door crush: nine villagers, one doorstep, one bell"
block doorCrush:
  var w = newWorld(gameMap, 7)
  ## Everyone converges on Ivan's house from their own doorstep with a
  ## quarter of the day to spare, arriving in a shoving crowd.
  for slot in 0'i32 ..< int32(VillagerCount):
    doAssert w.applyEnterHouse(slot, 0)
  while w.phase == DaytimePhase:
    w.tickWorld(nil)
  doAssert w.lastTally[0].valid, "the crowd never made it inside"
  doAssert w.lastTally[0].visitors == int32(VillagerCount) - 1,
    &"only {w.lastTally[0].visitors} of eight visitors got in"

echo "Testing a whole bot-driven week"
block botWeek:
  let game = newGame(gameMap, int32(DefaultDayCount))
  var sources: seq[string]
  let source = readFile("examples/heartleaf/players/base.bas")
  for slot in 0 ..< VillagerCount:
    sources.add source
  loadBots(game, sources)
  proc decide(w: World) =
    runBotDecisions(game)
  while not game.world.over:
    game.world.tickWorld(decide)
  for slot in 0 ..< VillagerCount:
    doAssert not game.brains[slot].failed,
      &"villager {slot} script failed: {game.brains[slot].lastError}"
    doAssert game.world.villagers[slot].score > 0,
      &"{VillagerNames[slot]} ended the week with nothing"
  ## Every night at least one party must have been valid; check the last.
  var anyParty = false
  for report in game.world.lastTally:
    if report.valid:
      anyParty = true
  doAssert anyParty, "the final night had no valid party at all"

echo "test_hlf_sim: all checks passed"
