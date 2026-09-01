## Light vs Dark simulation invariants: determinism, the one-unit-per-tile
## promise, the blocked-movement escalation, the harvest round trip, and the
## economy's accounting.

import
  std/strformat,
  polyworld/[bodies, tapes],
  ../examples/light_vs_dark/bots,
  ../examples/light_vs_dark/content,
  ../examples/light_vs_dark/maps,
  ../examples/light_vs_dark/replays,
  ../examples/light_vs_dark/sim

let map = generateMap(DefaultSeed)
map.validateMap()

const MatchTicks = DefaultSeconds * TickRate

proc stateHash(w: World): uint64 =
  ## Wraps a world in a session so tests can use the public hasher.
  var game = Game()
  game.world = w
  result = game.stateHash()
  wasMoved(game.world)

proc noDecisions(w: World) = discard

proc run(w: World, ticks: int32) =
  for _ in 0 ..< ticks:
    w.tickWorld(noDecisions)

proc checkOccupancy(w: World, label: string) =
  ## Every living unit's tile matches its body and stands on open terrain.
  for unit in w.units:
    if unit.state == UnitDying or unit.state == UnitInMine:
      continue
    let (x, z) = cell(unit.body.pos)
    doAssert unit.tile == tile2(x, z),
      &"{label}: unit {unit.id} tile ({unit.tile.x},{unit.tile.y}) " &
      &"does not match body cell ({x},{z}) at tick {w.tick}"
    doAssert w.tileOpen(unit.tile),
      &"{label}: unit {unit.id} stands on a blocked tile at tick {w.tick}"

echo "Testing the opening position"
block openingIsSane:
  var w = newWorld(map, MatchTicks)
  doAssert w.units.len == int(StartingPeons) * PlayerCount
  doAssert w.buildings.len == map.mines.len + PlayerCount
  for player in 0'i32 ..< PlayerCount:
    doAssert w.players[player].gold == StartingGold
    doAssert w.players[player].wood == StartingWood
    doAssert w.players[player].foodUsed == StartingPeons
    doAssert w.players[player].foodCap ==
      BuildingTable[TownHallBuilding].foodProvided
    doAssert w.buildingCount(player) == 1
    doAssert w.peonCount(player) == StartingPeons
  w.checkOccupancy("opening")
  ## Neither side can see the other at the start, or scouting would be free.
  let darkHall = map.hallOrigin[DarkPlayer]
  doAssert not w.visible(LightPlayer, darkHall)
  doAssert w.visible(LightPlayer, map.hallOrigin[LightPlayer])
  doAssert w.exploredCount[LightPlayer] > 0
  doAssert w.exploredCount[LightPlayer] == w.exploredCount[DarkPlayer],
    "the two openings reveal different amounts of ground"

echo "Testing determinism across identical runs"
block twoRunsAgree:
  var first = newWorld(map, MatchTicks)
  var second = newWorld(map, MatchTicks)
  doAssert first.stateHash() == second.stateHash(), "openings differ"
  for tick in 1 .. TickRate * 20:
    first.tickWorld(noDecisions)
    second.tickWorld(noDecisions)
    doAssert first.stateHash() == second.stateHash(),
      &"two identical runs diverged at tick {tick}"

echo "Testing that the hash actually responds to state"
block hashNoticesChange:
  var w = newWorld(map, MatchTicks)
  let before = w.stateHash()
  w.players[LightPlayer].gold += 1
  doAssert w.stateHash() != before, "the hash ignores a resource change"
  w.players[LightPlayer].gold -= 1
  doAssert w.stateHash() == before, "the hash is not a pure function"
  w.units[0].hp -= 1
  doAssert w.stateHash() != before, "the hash ignores unit health"

block hashIgnoresDerivedState:
  var w = newWorld(map, MatchTicks)
  let before = w.stateHash()
  ## Vision is a pure function of positions, so rebuilding it must not move
  ## the hash even though `explored` accumulates.
  w.rebuildVision()
  doAssert w.stateHash() == before, "the hash depends on derived vision"

echo "Testing movement, occupancy, and arrival"
block unitsWalkAndNeverOverlap:
  var w = newWorld(map, MatchTicks)
  ## March every Light peon at a distant tile on its own side of the river.
  var ordered = 0
  for index in 0 ..< w.units.len:
    if w.units[index].owner != LightPlayer:
      continue
    if w.applyMove(LightPlayer, w.units[index].id, 40, 40):
      inc ordered
  doAssert ordered == StartingPeons, &"only {ordered} peons accepted a move"
  for tick in 1 .. TickRate * 50:
    w.tickWorld(noDecisions)
    if tick mod TickRate == 0:
      w.checkOccupancy("march")
  var arrived = 0
  for unit in w.units:
    if unit.owner == LightPlayer and
        tileDistance(unit.tile, tile2(40, 40)) <= 3:
      inc arrived
  doAssert arrived >= StartingPeons - 1,
    &"only {arrived} of {StartingPeons} peons reached the rally tile"

echo "Testing paths go around other units"
block pathsGoAroundOtherUnits:
  var w = newWorld(map, MatchTicks)
  let
    walkerId = w.units[0].id
    blockerId = w.units[1].id
  doAssert w.units[0].owner == LightPlayer
  doAssert w.units[1].owner == LightPlayer
  var start, mid, goal = NoTile
  block found:
    for y in 0'i32 ..< GridSide:
      for x in 0'i32 ..< GridSide - 4:
        var open = true
        for ox in 0'i32 .. 4:
          if not w.tileFree(x + ox, y) or
              not w.tileOpen(x + ox, y - 1) or
              not w.tileOpen(x + ox, y + 1):
            open = false
            break
        if open:
          start = tile2(x, y)
          mid = tile2(x + 2, y)
          goal = tile2(x + 4, y)
          break found
  doAssert inGrid(start), "no open five-tile corridor on the map"
  for (id, tile) in [(walkerId, start), (blockerId, mid)]:
    let index = w.unitIndex(id)
    w.place(w.units[index], tile)
  doAssert w.applyMove(
    LightPlayer, walkerId, int32(goal.x), int32(goal.y)
  )
  for _ in 1 .. TickRate * 8:
    w.tickWorld(noDecisions)
    let walker = w.units[w.unitIndex(walkerId)]
    doAssert walker.tile != mid,
      "the walker stepped onto a standing peon instead of going around"
  let walker = w.units[w.unitIndex(walkerId)]
  doAssert tileDistance(walker.tile, goal) <= 1,
    &"the walker stopped at ({walker.tile.x},{walker.tile.y}) short of the goal"

echo "Testing mine approach tiles spread across peons"
block harvestSpotsSpread:
  var w = newWorld(map, MatchTicks)
  var mineId = NoEntity
  var best = int32.high
  for mine in map.mines:
    let distance = tileDistance(map.hallOrigin[LightPlayer], mine.origin)
    if distance < best:
      best = distance
      mineId = mine.id
  doAssert mineId != NoEntity
  let
    first = w.units[0].id
    second = w.units[1].id
  doAssert w.applyHarvest(LightPlayer, first, mineId, 0)
  doAssert w.applyHarvest(LightPlayer, second, mineId, 0)
  let
    firstGoal = w.units[w.unitIndex(first)].goal
    secondGoal = w.units[w.unitIndex(second)].goal
  doAssert firstGoal != secondGoal,
    "two peons queued on the same mine ring tile"

block movesToBlockedGroundAreRejected:
  var w = newWorld(map, MatchTicks)
  let peon = w.units[0].id
  ## The middle of the river is not standable terrain.
  var wet = tile2(-1, -1)
  for index in 0 ..< GridCells:
    if map.passable[index] == 0:
      wet = tile2(int32(index) mod GridSide, int32(index) div GridSide)
      break
  doAssert inGrid(wet)
  doAssert not w.applyMove(LightPlayer, peon, int32(wet.x), int32(wet.y)),
    "a move onto impassable terrain was accepted"

block ownershipIsEnforced:
  var w = newWorld(map, MatchTicks)
  var darkPeon = NoEntity
  for unit in w.units:
    if unit.owner == DarkPlayer:
      darkPeon = unit.id
      break
  doAssert darkPeon != NoEntity
  doAssert not w.applyMove(LightPlayer, darkPeon, 40, 40),
    "Light commanded a Dark unit"
  doAssert not w.applyCancel(LightPlayer, darkPeon),
    "Light cancelled a Dark unit's order"
  doAssert w.applyMove(DarkPlayer, darkPeon, 100, 100),
    "Dark could not command its own unit"

echo "Testing live history seek does not skip recorded actions"
block liveHistorySeek:
  ## The graphical scrubber restores a live checkpoint whose stored cursor
  ## is still 0, then catches up through recorded overlord commands.
  const Ticks = TickRate * 8
  let setup = Setup(
    mapSeed: DefaultSeed,
    tickRate: uint16(TickRate),
    gridTiles: uint16(GridSide),
    decisionTicks: uint16(DecisionTicks),
    maximumTicks: uint32(Ticks),
    mapHash: map.hash,
    contentHash: contentHash(),
    players: [
      ReplayPlayerSetup(
        id: 0,
        startX: uint8(map.hallOrigin[LightPlayer].x),
        startY: uint8(map.hallOrigin[LightPlayer].y)
      ),
      ReplayPlayerSetup(
        id: 1,
        startX: uint8(map.hallOrigin[DarkPlayer].x),
        startY: uint8(map.hallOrigin[DarkPlayer].y)
      )
    ]
  )
  let recorder = initReplayRecorder(setup)
  var liveGame = newGame(map, Ticks)
  liveGame.recorder = recorder
  let player = ReplayPlayer(data: recorder.data)

  proc liveOrders(w: World) =
    ## Issues one accepted move per decision so the live tape is not empty.
    let playerId = (w.tick div DecisionTicks) mod PlayerCount
    for index in 0 ..< w.units.len:
      if w.units[index].owner != playerId or
          w.units[index].state != UnitIdle:
        continue
      discard liveGame.applyMove(
        playerId,
        w.units[index].id,
        40 + playerId * 40,
        40
      )
      break

  const SnapAfter = Ticks div 2
  var snapshot: World
  for i in 1 .. Ticks:
    liveGame.world.tickWorld(liveOrders)
    if i == SnapAfter:
      snapshot = liveGame.world.clone()
  doAssert recorder.data.actions.len > 0,
    "overlords issued no commands during the live window"
  doAssert player.actionIndex == 0,
    "live recording must not advance the playback cursor"
  let
    frontierTick = liveGame.world.tick
    frontierHash = liveGame.stateHash()
  liveGame.world.restore(snapshot)
  player.data = recorder.data
  player.syncCursor(uint32(liveGame.world.tick))

  proc drain(w: World) =
    ## Replays every recorded command for this tick.
    var action: ReplayAction
    while player.takeActionAt(uint32(w.tick), action):
      w.applyReplayAction(action)

  while liveGame.world.tick < frontierTick:
    liveGame.world.tickWorld(drain)
  doAssert liveGame.world.tick == frontierTick
  doAssert liveGame.stateHash() == frontierHash,
    "catching up from a live seek diverged from the recorded frontier"

echo "Testing the gold round trip"
block goldFlows:
  var w = newWorld(map, MatchTicks)
  var mineId = NoEntity
  var best = int32.high
  for mine in map.mines:
    let distance = tileDistance(map.hallOrigin[LightPlayer], mine.origin)
    if distance < best:
      best = distance
      mineId = mine.id
  doAssert mineId != NoEntity
  var sent = 0
  for index in 0 ..< w.units.len:
    if w.units[index].owner != LightPlayer:
      continue
    if w.applyHarvest(LightPlayer, w.units[index].id, mineId, 0):
      inc sent
  doAssert sent == StartingPeons, &"only {sent} peons accepted a mine order"

  let startingGold = w.players[LightPlayer].gold
  w.run(TickRate * 60)
  w.checkOccupancy("mining")
  let gained = w.players[LightPlayer].gold - startingGold
  doAssert gained > 0, "sixty seconds of mining produced no gold"
  doAssert gained mod GoldPerTrip == 0,
    &"gold arrived in a partial load: {gained}"
  doAssert w.players[LightPlayer].goldGathered == int64(gained),
    "the gathered total disagrees with the stockpile"
  ## Gold is conserved: what the mine lost is either banked or still being
  ## carried. Nothing may appear from nowhere or evaporate in transit.
  let mine = w.buildingIndex(mineId)
  var inFlight = 0'i32
  for unit in w.units:
    inFlight += unit.carryGold
  doAssert w.buildings[mine].goldLeft + gained + inFlight == MainMineGold,
    &"gold is not conserved: mine has {w.buildings[mine].goldLeft}, " &
    &"player banked {gained}, peons carry {inFlight}"
  doAssert w.buildings[mine].minersInside <= MinersPerMine,
    "more peons fit inside the mine than the rules allow"
  ## Five peons on an eight-tile trip should be worth roughly 12 gold each
  ## per second; allow a wide band, this is a sanity check not a balance one.
  doAssert gained >= 1500, &"income was implausibly low: {gained} in 60s"
  echo &"  five peons gathered {gained} gold in 60 seconds"

echo "Testing the wood round trip and tree depletion"
block woodFlowsAndTreesFall:
  var w = newWorld(map, MatchTicks)
  var treeIndex = -1'i32
  var best = int32.high
  for index in 0 ..< GridCells:
    if w.treeWood[index] <= 0:
      continue
    let tile = tile2(int32(index) mod GridSide, int32(index) div GridSide)
    let distance = tileDistance(map.hallOrigin[LightPlayer], tile)
    if distance < best:
      best = distance
      treeIndex = int32(index)
  doAssert treeIndex >= 0
  let peon = w.units[0].id
  doAssert w.units[0].owner == LightPlayer
  doAssert w.applyHarvest(LightPlayer, peon, treeIndex, 1),
    "a peon would not chop a tree"

  let edits = w.terrainEdits.len
  w.run(TickRate * 100)
  doAssert w.players[LightPlayer].wood > StartingWood,
    "one hundred seconds of chopping produced no wood"
  let gained = w.players[LightPlayer].wood - StartingWood
  doAssert gained mod WoodPerTrip == 0, "wood arrived in a partial load"
  doAssert w.treeWood[treeIndex] == 0,
    "a tree survived four full trips"
  doAssert w.terrainEdits.len == edits + 1,
    "felling a tree did not log a terrain edit"
  doAssert w.terrainEdits[^1].index == treeIndex
  doAssert w.tileOpen(tile2(treeIndex mod GridSide, treeIndex div GridSide)),
    "the felled tree still blocks its tile"
  doAssert gained == int32(WoodPerTree),
    &"a tree yielded {gained} wood instead of {WoodPerTree}"
  ## With the tile exhausted the peon reports failure rather than guessing.
  let index = w.unitIndex(peon)
  doAssert w.units[index].orderFailed,
    "an exhausted tree did not report an order failure"

echo "Testing construction, training, food, and cancellation"
block basesGrow:
  var w = newWorld(map, MatchTicks)
  let
    peon = w.units[0].id
    hall = map.hallOrigin[LightPlayer]
  doAssert w.units[0].owner == LightPlayer
  ## Find a legal farm site near home.
  var site = NoTile
  for radius in 4'i32 .. 10'i32:
    for dy in -radius .. radius:
      for dx in -radius .. radius:
        let
          x = int32(hall.x) + dx
          y = int32(hall.y) + dy
        if inGrid(x, y) and w.canPlace(FarmBuilding, x, y):
          site = tile2(x, y)
          break
      if inGrid(site): break
    if inGrid(site): break
  doAssert inGrid(site), "nowhere to put a farm near the opening base"

  let
    goldBefore = w.players[LightPlayer].gold
    stats = BuildingTable[FarmBuilding]
  doAssert w.applyBuild(LightPlayer, peon, int32(FarmBuilding.ord),
    int32(site.x), int32(site.y)), "a farm order was rejected"
  doAssert w.players[LightPlayer].gold == goldBefore - stats.gold,
    "the farm was not paid for when the order was accepted"
  doAssert not w.canPlace(FarmBuilding, int32(site.x), int32(site.y)),
    "the site is still advertised as free after being claimed"

  let capBefore = w.players[LightPlayer].foodCap
  w.run(TickRate * 40)
  w.checkOccupancy("building")
  var farmId = NoEntity
  for structure in w.buildings:
    if structure.owner == LightPlayer and structure.kind == FarmBuilding:
      farmId = structure.id
  doAssert farmId != NoEntity, "the farm vanished"
  let farm = w.buildingIndex(farmId)
  doAssert w.buildings[farm].state == BuildingComplete,
    "forty seconds was not enough to raise a farm"
  doAssert w.buildings[farm].hp == stats.hp
  doAssert w.players[LightPlayer].foodCap == capBefore + stats.foodProvided,
    "the finished farm did not raise the food cap"
  ## The builder is released, not consumed.
  doAssert w.hasUnit(peon), "the builder was eaten by its own farm"
  doAssert w.units[w.unitIndex(peon)].state == UnitIdle,
    "the builder was not released when its farm finished"

block trainingSpendsAndRespectsFood:
  var w = newWorld(map, MatchTicks)
  var hallId = NoEntity
  for structure in w.buildings:
    if structure.owner == LightPlayer and structure.kind == TownHallBuilding:
      hallId = structure.id
  doAssert hallId != NoEntity

  ## The opening cap is five food and five peons already use it all.
  doAssert not w.canTrain(hallId, PeonUnit),
    "a full food cap still allowed training"
  doAssert not w.applyTrain(LightPlayer, hallId, int32(PeonUnit.ord))

  ## Free a slot and it should work.
  w.players[LightPlayer].foodCap += 4
  let
    goldBefore = w.players[LightPlayer].gold
    foodBefore = w.players[LightPlayer].foodUsed
    stats = UnitTable[LightPlayer][PeonUnit]
  doAssert w.applyTrain(LightPlayer, hallId, int32(PeonUnit.ord)),
    "training was rejected with food to spare"
  doAssert w.players[LightPlayer].gold == goldBefore - stats.gold
  doAssert w.players[LightPlayer].foodUsed == foodBefore + stats.food,
    "queued training did not reserve its food"

  ## A soldier cannot come out of a town hall.
  doAssert not w.applyTrain(LightPlayer, hallId, int32(SoldierUnit.ord)),
    "a town hall trained a soldier"

  let unitsBefore = w.units.len
  w.run(stats.trainTicks + TickRate)
  doAssert w.units.len == unitsBefore + 1, "the peon never appeared"
  doAssert w.players[LightPlayer].unitsTrained == 1
  doAssert w.players[LightPlayer].foodUsed == foodBefore + stats.food,
    "food was charged twice for one unit"

block cancellingRefunds:
  var w = newWorld(map, MatchTicks)
  var hallId = NoEntity
  for structure in w.buildings:
    if structure.owner == LightPlayer and structure.kind == TownHallBuilding:
      hallId = structure.id
  w.players[LightPlayer].foodCap += 4
  let
    goldBefore = w.players[LightPlayer].gold
    foodBefore = w.players[LightPlayer].foodUsed
  doAssert w.applyTrain(LightPlayer, hallId, int32(PeonUnit.ord))
  doAssert w.applyCancel(LightPlayer, hallId)
  doAssert w.players[LightPlayer].gold == goldBefore,
    "cancelling a queued unit did not refund its gold"
  doAssert w.players[LightPlayer].foodUsed == foodBefore,
    "cancelling a queued unit did not release its food"

echo "Testing the reference overlord starts building"
block openingBuild:
  ## The BASIC script harvests every idle peon and then issues a build to
  ## one of them. That second order must replace the queued harvest path,
  ## or the builder stands on spawn forever and the farm never rises.
  let source = readFile("examples/light_vs_dark/players/base.bas")
  var game = newGame(map, TickRate * 45)
  loadBots(game, [source, source])
  proc decide(w: World) =
    runBotDecisions(game)
  for _ in 1 .. TickRate * 30:
    game.world.tickWorld(decide)
  for player in 0'i32 ..< PlayerCount:
    doAssert game.brains[player] != nil and game.brains[player].ready,
      "player " & $player & " did not load the reference overlord"
    doAssert not game.brains[player].failed,
      "player " & $player & " BASIC error: " & game.brains[player].lastError
  var raised = 0
  for structure in game.world.buildings:
    if structure.kind == FarmBuilding and
        structure.state == BuildingComplete:
      inc raised
  doAssert raised >= 1,
    "the opening overlords never finished a farm in 30s"
  echo "  " & $raised & " farm(s) finished in the opening 30s"

echo "Testing combat and defeat"
block unitsFightAndDie:
  var w = newWorld(map, MatchTicks)
  let
    attacker = w.units[0].id
    defender = w.units[int(StartingPeons)].id
  doAssert w.units[0].owner == LightPlayer
  doAssert w.unitOwner(defender) == DarkPlayer
  ## Stand them next to each other in open ground and let them brawl.
  let arena = tile2(60, 20)
  doAssert w.tileFree(int32(arena.x), int32(arena.y))
  doAssert w.tileFree(int32(arena.x) + 1, int32(arena.y))
  for (id, tile) in [(attacker, arena), (defender, tile2(61, 20))]:
    let index = w.unitIndex(id)
    w.place(w.units[index], tile)
  w.rebuildVision()
  doAssert w.applyAttack(LightPlayer, attacker, defender)
  doAssert not w.applyAttack(LightPlayer, attacker, w.units[1].id),
    "a unit was ordered to attack its own side"

  let hpBefore = w.units[w.unitIndex(defender)].hp
  w.run(TickRate * 10 div 3)
  doAssert not w.hasUnit(defender) or
    w.units[w.unitIndex(defender)].hp < hpBefore,
    "two hundred ticks of combat did no damage"
  w.run(TickRate * 80)
  doAssert not w.hasUnit(defender), "the defender never died"
  doAssert w.players[DarkPlayer].unitsLost == 1
  w.checkOccupancy("after combat")

block losingEverythingLosesTheMatch:
  var w = newWorld(map, MatchTicks)
  ## Raze everything Dark owns and kill every Dark peon.
  for index in 0 ..< w.buildings.len:
    if w.buildings[index].owner == DarkPlayer:
      w.damageEntity(w.buildings[index].id, w.buildings[index].hp)
  for index in 0 ..< w.units.len:
    if w.units[index].owner == DarkPlayer:
      w.damageEntity(w.units[index].id, w.units[index].hp)
  w.run(1)
  doAssert w.over, "a player with nothing left did not lose"
  doAssert w.winner == LightPlayer, &"the wrong player won: {w.winner}"

block reachingTheCapDecidesOnScore:
  var w = newWorld(map, TickRate * 4)
  w.players[LightPlayer].goldGathered = 50_000
  w.run(TickRate * 4)
  doAssert w.over, "the match did not end at its tick limit"
  doAssert w.winner == LightPlayer,
    "the richer player did not win on score"

echo "Testing attack-move engages enemies that a move walks past"
block attackMoveFightsOnTheWay:
  var w = newWorld(map, MatchTicks)
  let
    walker = w.spawnUnit(LightPlayer, SoldierUnit, tile2(60, 20))
    foe = w.spawnUnit(DarkPlayer, SoldierUnit, tile2(63, 20))
  w.rebuildVision()
  doAssert w.applyAttackMove(LightPlayer, walker, 70, 20)
  let hpBefore = w.units[w.unitIndex(foe)].hp
  w.run(TickRate * 8)
  doAssert not w.hasUnit(foe) or
    w.units[w.unitIndex(foe)].hp < hpBefore,
    "an attack-move walked past a visible enemy without fighting"

block plainMoveIgnoresEnemies:
  var w = newWorld(map, MatchTicks)
  let
    walker = w.spawnUnit(LightPlayer, SoldierUnit, tile2(60, 20))
    foe = w.spawnUnit(DarkPlayer, SoldierUnit, tile2(63, 20))
  w.rebuildVision()
  doAssert w.applyMove(LightPlayer, walker, 70, 20)
  let hpBefore = w.units[w.unitIndex(foe)].hp
  w.run(TickRate * 2)
  doAssert w.hasUnit(foe)
  doAssert w.units[w.unitIndex(foe)].hp == hpBefore,
    "a plain move stopped to fight instead of walking through"
  doAssert w.units[w.unitIndex(walker)].state == UnitMoving,
    "the walker finished or abandoned the plain move too soon"

block attackMoveStopsAtRange:
  var w = newWorld(map, MatchTicks)
  let
    archer = w.spawnUnit(LightPlayer, ArcherUnit, tile2(60, 20))
    foe = w.spawnUnit(DarkPlayer, PeonUnit, tile2(66, 20))
  w.rebuildVision()
  doAssert w.applyAttackMove(LightPlayer, archer, 70, 20)
  let hpBefore = w.units[w.unitIndex(foe)].hp
  w.run(TickRate * 8)
  doAssert w.hasUnit(foe)
  doAssert w.units[w.unitIndex(foe)].hp < hpBefore,
    "the archer never shot during the attack-move"
  doAssert tileDistance(
    w.units[w.unitIndex(archer)].tile,
    w.units[w.unitIndex(foe)].tile
  ) >= 2,
    "the archer closed to melee instead of shooting at range"

proc placeSquad(w: World, player: int32, anchor: Tile2,
    count: int): seq[int32] =
  ## Drops a block of soldiers around a tile and returns their identifiers.
  for _ in 0 ..< count:
    var spawn = NoTile
    block search:
      for radius in 0'i32 .. 10'i32:
        for dy in -radius .. radius:
          for dx in -radius .. radius:
            let tile = tile2(int32(anchor.x) + dx, int32(anchor.y) + dy)
            if inGrid(tile) and w.tileFree(int32(tile.x), int32(tile.y)):
              spawn = tile
              break search
    if not inGrid(spawn):
      return
    result.add w.spawnUnit(player, SoldierUnit, spawn)
    w.players[player].foodUsed += UnitTable[player][SoldierUnit].food

echo "Testing the chokepoint does not deadlock"
block fordsClear:
  ## Forty units of ONE side pushed both ways through the middle ford. Using
  ## a single player keeps combat out of it, so this measures only whether
  ## two-way traffic through a narrow gap resolves. Strict one-unit-per-tile
  ## is at its worst here, and the shove, swap, and abandon escalation exists
  ## precisely for this case.
  var w = newWorld(map, 200_000)
  let
    west = tile2(54, 53)
    east = tile2(74, 73)
    eastward = w.placeSquad(LightPlayer, west, 20)
    westward = w.placeSquad(LightPlayer, east, 20)
  doAssert eastward.len == 20 and westward.len == 20,
    &"could not place the squads: {eastward.len} and {westward.len}"

  for id in eastward:
    doAssert w.applyMove(LightPlayer, id, int32(east.x), int32(east.y))
  for id in westward:
    doAssert w.applyMove(LightPlayer, id, int32(west.x), int32(west.y))

  for tick in 1 .. TickRate * 150:
    w.tickWorld(noDecisions)
    if tick mod 50 == 0:
      w.checkOccupancy("ford")

  var
    crossed = 0
    jammed = 0
  for unit in w.units:
    if unit.kind != SoldierUnit:
      continue
    let goal = if unit.id in eastward: east else: west
    if tileDistance(unit.tile, goal) <= 10:
      inc crossed
    if unit.blockedTicks >= AbandonAfterTicks:
      inc jammed
  doAssert jammed == 0, &"{jammed} units are still grinding at the ford"
  doAssert crossed == 40, &"only {crossed} of 40 units crossed the ford"
  echo &"  all {crossed} units crossed the ford in both directions"

echo "Testing that an army can cross the whole map"
block armiesReachTheEnemy:
  ## Base to base is about 120 tiles through a ford. If A* cannot produce a
  ## complete route that far, units stall on the near bank and the game has
  ## no late phase at all, so this is a gameplay requirement and not just a
  ## pathing detail.
  var w = newWorld(map, 200_000)
  let
    target = map.hallOrigin[DarkPlayer]
    squad = w.placeSquad(LightPlayer, tile2(30, 30), 20)
  doAssert squad.len == 20
  for id in squad:
    doAssert w.applyMove(LightPlayer, id, int32(target.x), int32(target.y))

  for tick in 1 .. TickRate * 200:
    w.tickWorld(noDecisions)
    if tick mod 200 == 0:
      w.checkOccupancy("march")

  var
    arrived = 0
    crossedRiver = 0
    gaveUp = 0
  for unit in w.units:
    if unit.kind != SoldierUnit:
      continue
    if int32(unit.tile.x) + int32(unit.tile.y) > GridSide:
      inc crossedRiver
    if tileDistance(unit.tile, target) <= 12:
      inc arrived
    if unit.orderFailed:
      inc gaveUp
  echo "  " & $crossedRiver & "/20 crossed the river, " & $arrived &
    "/20 reached the enemy base, " & $gaveUp & " gave up"
  doAssert crossedRiver >= 18,
    "only " & $crossedRiver & " of 20 units got across the river"
  doAssert arrived >= 15,
    "only " & $arrived & " of 20 units reached the enemy base"

echo "Testing that a recorded match replays tick for tick"
block replayReproducesTheMatch:
  ## The whole point of recording only accepted commands is that re-running
  ## them through the same validators rebuilds the match exactly. A command
  ## that mutates the world and then reports refusal would never be written
  ## down, and this is what catches it.
  const Ticks = TickRate * 200 div 3
  let setup = Setup(
    mapSeed: DefaultSeed,
    tickRate: uint16(TickRate),
    gridTiles: uint16(GridSide),
    decisionTicks: uint16(DecisionTicks),
    maximumTicks: uint32(Ticks),
    mapHash: map.hash,
    contentHash: contentHash(),
    players: [
      ReplayPlayerSetup(id: 0,
        startX: uint8(map.hallOrigin[LightPlayer].x),
        startY: uint8(map.hallOrigin[LightPlayer].y)),
      ReplayPlayerSetup(id: 1,
        startX: uint8(map.hallOrigin[DarkPlayer].x),
        startY: uint8(map.hallOrigin[DarkPlayer].y))
    ]
  )
  let recorder = initReplayRecorder(setup)
  var liveGame = newGame(map, Ticks)
  liveGame.recorder = recorder

  proc scripted(w: World) =
    ## A deterministic stand-in for an overlord, exercising every command
    ## kind including ones that will be refused or will fail to arrive.
    let player = (w.tick div DecisionTicks) mod PlayerCount
    var
      hall = NoEntity
      mine = NoEntity
    for structure in w.buildings:
      if structure.owner == player and structure.kind == TownHallBuilding:
        hall = structure.id
      if structure.owner < 0 and mine == NoEntity:
        mine = structure.id
    for index in 0 ..< w.units.len:
      if w.units[index].owner != player or w.units[index].state != UnitIdle:
        continue
      let id = w.units[index].id
      case int(id + w.tick) mod 4
      of 0: discard liveGame.applyHarvest(player, id, mine, 0)
      of 1:
        let tree = w.nearestTree(w.units[index].tile)
        if tree >= 0:
          discard liveGame.applyHarvest(player, id, tree, 1)
      of 2:
        discard liveGame.applyAttackMove(
          player, id, 40 + player * 40, 40
        )
      else:
        ## Deliberately hopeless: aimed into the river, and at a tile the
        ## unit may well never reach.
        discard liveGame.applyMove(player, id, 64, 63)
    if hall != NoEntity and w.tick mod (TickRate * 10) == 0:
      discard liveGame.applyTrain(player, hall, int32(PeonUnit.ord))
      discard liveGame.applySetRally(player, hall, 30 + player * 60, 30)
    if w.tick mod (TickRate * 20) == 0:
      for index in 0 ..< w.units.len:
        if w.units[index].owner == player and
            w.units[index].kind == PeonUnit:
          discard liveGame.applyBuild(player, w.units[index].id,
            int32(FarmBuilding.ord), 26 + player * 60, 26)
          discard liveGame.applyCancel(player, w.units[index].id)
          break

  var liveHashes: seq[uint64]
  for _ in 1 .. Ticks:
    liveGame.world.tickWorld(scripted)
    let hash = liveGame.stateHash()
    liveHashes.add hash
    liveGame.recorder.recordHash(hash)
  doAssert recorder.data.actions.len > 20,
    "the scripted overlord issued only " & $recorder.data.actions.len &
      " commands, so this proves little"

  ## Round trip through the real codec, not the in-memory object.
  let data = decodeReplay(recorder.data.encodeReplay())
  let cursor = initReplayPlayer(data)

  proc drain(w: World) =
    var action: ReplayAction
    while cursor.takeActionAt(uint32(w.tick), action):
      w.applyReplayAction(action)

  var replayed = newWorld(map, Ticks)
  for tick in 1 .. Ticks:
    replayed.tickWorld(drain)
    doAssert replayed.stateHash() == liveHashes[tick - 1],
      &"replay diverged from the recorded match at tick {tick}"
  doAssert cursor.finished, "the replay had commands left over"
  doAssert replayed.players == liveGame.world.players
  doAssert replayed.units.len == liveGame.world.units.len
  echo "  " & $data.actions.len & " commands replayed over " & $Ticks &
    " ticks with no divergence"

echo "test_lvd_sim: all checks passed"
