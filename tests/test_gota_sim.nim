## Gods of the Arena simulation: hashing, towers, and a live bot tick.
##
## game.nim parses the command line and builds the world at import time, so
## this test must be run with a bot roster:
##   nim r tests/test_gota_sim.nim -- \
##     --bot:examples/gods_of_the_arena/players/base.bas:10

import
  polyworld/tapes,
  ../examples/gods_of_the_arena/[content, maps, game, sim, replays]

template hashNow(): uint64 =
  run.stateHash()

doAssert run.world.heroes.len == 10,
  "run this test with " &
    "--bot:examples/gods_of_the_arena/players/base.bas:10"

echo "Testing the decision rotation reaches the state hash"
block:
  let base = hashNow()

  let savedStart = run.world.heroTurnStart
  run.world.heroTurnStart =
    (run.world.heroTurnStart + 1) mod run.world.heroes.len
  doAssert hashNow() != base,
    "heroTurnStart is authoritative but does not reach stateHash"
  run.world.heroTurnStart = savedStart
  doAssert hashNow() == base

  let savedTicks = run.world.heroTurnTicks
  run.world.heroTurnTicks = run.world.heroTurnTicks + 1
  doAssert hashNow() != base,
    "heroTurnTicks is authoritative but does not reach stateHash"
  run.world.heroTurnTicks = savedTicks
  doAssert hashNow() == base

echo "Testing hero class identity reaches the state hash"
block:
  let
    base = hashNow()
    savedClass = run.world.heroes[0].class
  run.world.heroes[0].class =
    if savedClass == VanguardKnight: Ranger else: VanguardKnight
  doAssert hashNow() != base,
    "hero class is authoritative but does not reach stateHash"
  run.world.heroes[0].class = savedClass
  doAssert hashNow() == base

echo "Testing attack-move flag reaches the state hash"
block:
  let
    base = hashNow()
    saved = run.world.heroes[0].attackMoving
  run.world.heroes[0].attackMoving = not saved
  doAssert hashNow() != base,
    "attackMoving is authoritative but does not reach stateHash"
  run.world.heroes[0].attackMoving = saved
  doAssert hashNow() == base

echo "Testing ability cooldown reaches the state hash"
block:
  let
    base = hashNow()
    saved = run.world.heroes[0].cooldowns[PrimaryAbility]
  run.world.heroes[0].cooldowns[PrimaryAbility] = saved + 12
  doAssert hashNow() != base,
    "ability cooldown is authoritative but does not reach stateHash"
  run.world.heroes[0].cooldowns[PrimaryAbility] = saved
  doAssert hashNow() == base

echo "Testing the map fingerprint is independent of the simulation"
block:
  # run.map.hash is written once when the map is generated, before any
  # simulation runs, and terrain is immutable afterwards. This pins that: a
  # game that starts mutating terrain mid-run has to revisit how the map is
  # fingerprinted.
  let mapBefore = run.map.hash
  for _ in 0 ..< TickRate * 10:
    advanceGame()
  doAssert run.map.hash == mapBefore, "terrain changed during simulation"

echo "Testing the simulation advances the state hash"
block:
  let before = hashNow()
  advanceGame()
  doAssert hashNow() != before, "a tick that changes nothing is suspicious"

echo "Testing towers expose outer, inner, then gate"
block:
  var lane: array[TowerTier, int]
  for i, tower in run.world.towers:
    if tower.team == RedTeam and tower.lane == 0:
      lane[tower.tier] = i
      run.world.towers[i].hp = run.world.towers[i].maxHp
  doAssert towerExposed(run.world, run.world.towers[lane[OuterTower]])
  doAssert not towerExposed(run.world, run.world.towers[lane[InnerTower]])
  doAssert not towerExposed(run.world, run.world.towers[lane[GateTower]])
  run.world.towers[lane[OuterTower]].hp = 0
  doAssert towerExposed(run.world, run.world.towers[lane[InnerTower]])
  doAssert not towerExposed(run.world, run.world.towers[lane[GateTower]])
  run.world.towers[lane[InnerTower]].hp = 0
  doAssert towerExposed(run.world, run.world.towers[lane[GateTower]])
  run.world.towers[lane[GateTower]].hp = 0
  doAssert fortExposed(run.world, RedTeam)

echo "Testing towers prefer footmen and attack once per period"
block:
  run.world.towers[0].hp = run.world.towers[0].maxHp
  run.world.towers[0].targetId = 0
  run.world.towers[0].attackTicks = 0
  var targetHero = -1
  for i in 0 ..< run.world.heroes.len:
    run.world.heroes[i].state = Dying
    if targetHero < 0 and run.world.heroes[i].team != run.world.towers[0].team:
      targetHero = i
  run.world.heroes[targetHero].state = Marching
  run.world.heroes[targetHero].place(run.world.towers[0].position)
  run.world.heroes[targetHero].hp = run.world.heroes[targetHero].maxHp
  run.world.footmen = @[
    Footman(
      id: 50_000,
      team: run.world.heroes[targetHero].team,
      lane: run.world.towers[0].lane,
      position: run.world.towers[0].position,
      hp: FootmanHp,
      state: Marching
    )
  ]
  updateTower(run.world, run.world.towers[0])
  doAssert run.world.towers[0].targetId == run.world.footmen[0].id,
    "a tower should protect heroes by targeting a footman first"
  for _ in 1 ..< TowerAttackTicks:
    updateTower(run.world, run.world.towers[0])
  doAssert run.world.footmen[0].hp ==
    FootmanHp - TowerDamages[run.world.towers[0].tier]
  run.world.footmen[0].hp = 0
  for _ in 0 ..< TowerAttackTicks:
    updateTower(run.world, run.world.towers[0])
  doAssert run.world.towers[0].targetId == run.world.heroes[targetHero].id
  doAssert run.world.heroes[targetHero].hp ==
    run.world.heroes[targetHero].maxHp -
      TowerDamages[run.world.towers[0].tier]

echo "Testing tower combat state reaches the simulation hash"
block:
  let
    base = hashNow()
    savedTarget = run.world.towers[0].targetId
    savedTicks = run.world.towers[0].attackTicks
  run.world.towers[0].targetId = run.world.towers[0].targetId + 1
  doAssert hashNow() != base, "tower target is missing from stateHash"
  run.world.towers[0].targetId = savedTarget
  run.world.towers[0].attackTicks = run.world.towers[0].attackTicks + 1
  doAssert hashNow() != base, "tower attack phase is missing from stateHash"
  run.world.towers[0].attackTicks = savedTicks
  doAssert hashNow() == base

echo "Testing the base bot attacks an exposed tower through attackTarget"
block:
  var attacker = -1
  for i in 0 ..< run.world.heroes.len:
    run.world.heroes[i].state = Dying
    if attacker < 0 and run.world.heroes[i].team != run.world.towers[0].team:
      attacker = i
  run.world.heroes[attacker].state = Marching
  run.world.heroes[attacker].hp = run.world.heroes[attacker].maxHp
  run.world.heroes[attacker].place(run.world.towers[0].position)
  run.world.heroes[attacker].attackObjectId = 0
  run.world.heroes[attacker].hasMoveTarget = false
  run.heroVms[attacker].failed = false
  run.world.towers[0].hp = run.world.towers[0].maxHp
  run.world.towers[0].targetId = 0
  run.world.towers[0].attackTicks = 0
  run.world.footmen.setLen(0)
  run.world.spawnTimerTicks = 1_000
  run.world.heroTurnTicks = 1
  for _ in 0 ..< 40:
    advanceGame()
  doAssert run.world.towers[0].hp < run.world.towers[0].maxHp,
    "the existing attackTarget API did not let the bot damage a tower"

echo "Testing clone is an independent copy"
block:
  let
    snapshot = run.world.clone()
    before = hashNow()
    savedHp = run.world.towers[0].hp
    alias = run.world
  run.world.towers[0].hp = run.world.towers[0].hp - 1
  doAssert hashNow() != before, "live world should diverge after a write"
  doAssert snapshot.towers[0].hp == savedHp,
    "clone shared its towers seq with the original"
  run.world.restore(snapshot)
  doAssert hashNow() == before, "restore did not reproduce the snapshot"
  doAssert run.world == alias, "restore rebound the ref instead of assigning"
  doAssert run.world != snapshot

echo "Testing live history seek does not skip recorded actions"
block:
  ## The graphical scrubber restores a live checkpoint whose stored cursor
  ## is still 0, then catches up through recorded bot commands.
  startReplayRecording(uint32(run.world.tick) + 400)
  for i in 0 ..< run.world.heroes.len:
    if run.heroVms[i] != nil:
      run.heroVms[i].failed = false
    run.world.heroes[i].state = Marching
    run.world.heroes[i].hp = run.world.heroes[i].maxHp
  run.world.gameOver = false
  const
    SnapAfter = 20
    LiveTicks = 40
  var snapshot: World
  for i in 1 .. LiveTicks:
    advanceGame()
    if i == SnapAfter:
      snapshot = run.world.clone()
  doAssert run.recorder.data.actions.len > 0,
    "bots issued no commands during the live window"
  doAssert run.replayPlayer.actionIndex == 0,
    "live recording must not advance the playback cursor"
  let
    frontierTick = run.world.tick
    frontierHash = hashNow()
  run.world.restore(snapshot)
  run.replayPlayer.data = run.recorder.data
  run.replayPlayer.syncCursor(uint32(run.world.tick))
  run.historyPlayback = true
  while run.world.tick < frontierTick:
    advanceGame()
  doAssert run.world.tick == frontierTick
  doAssert hashNow() == frontierHash,
    "catching up from a live seek diverged from the recorded frontier"
  run.historyPlayback = false

echo "Testing shop purchases reach inventory and the state hash"
block:
  let
    heroId = run.world.heroes[0].id
    base = hashNow()
    savedGold = run.world.heroes[0].gold
    savedHp = run.world.heroes[0].hp
    savedInv = run.world.heroes[0].inventory
    savedCounts = run.world.heroes[0].itemCounts
    savedMaxHp = run.world.heroes[0].maxHp
  run.world.heroes[0].gold = 500
  doAssert applyBuyItem(run.world, heroId, int32(KnightArmor.ord)),
    "a funded hero should buy knight armor"
  var hasArmor = false
  for slot in 0 ..< InventorySlots:
    if run.world.heroes[0].inventory[slot] == KnightArmor:
      hasArmor = true
  doAssert hasArmor, "armor should occupy an inventory slot"
  doAssert run.world.heroes[0].maxHp > savedMaxHp,
    "armor should raise maximum health"
  doAssert hashNow() != base, "inventory is missing from stateHash"
  run.world.heroes[0].hp = run.world.heroes[0].maxHp div 2
  doAssert applyBuyItem(run.world, heroId, int32(IronrootRation.ord))
  var rationSlot = -1
  for slot in 0 ..< InventorySlots:
    if run.world.heroes[0].inventory[slot] == IronrootRation:
      rationSlot = slot
  doAssert rationSlot >= 0
  let hpBefore = run.world.heroes[0].hp
  doAssert applyUseItem(run.world, heroId, int32(rationSlot))
  doAssert run.world.heroes[0].hp > hpBefore, "a ration should heal"
  run.world.heroes[0].gold = savedGold
  run.world.heroes[0].inventory = savedInv
  run.world.heroes[0].itemCounts = savedCounts
  run.world.heroes[0].refreshHeroStats()
  run.world.heroes[0].hp = savedHp

echo "Testing the base bot spends starting gold on an item"
block:
  var bought = false
  for hero in run.world.heroes:
    for slot in 0 ..< InventorySlots:
      if hero.inventory[slot] != NoItem:
        bought = true
  if not bought:
    run.world.heroTurnTicks = 1
    for _ in 0 ..< 20:
      advanceGame()
    for hero in run.world.heroes:
      for slot in 0 ..< InventorySlots:
        if hero.inventory[slot] != NoItem:
          bought = true
  doAssert bought, "the base bot did not buy a shop item"

echo "Testing heroes spend a combat ability"
block:
  var
    blue = -1
    red = -1
  for i, hero in run.world.heroes:
    if hero.state == Dying or hero.hp <= 0:
      continue
    if hero.team == BlueTeam and blue < 0:
      blue = i
    elif hero.team == RedTeam and red < 0:
      red = i
  doAssert blue >= 0 and red >= 0, "need one living hero on each team"
  var beside = run.world.heroes[blue].position
  beside.x += 40_000
  run.world.heroes[red].place(beside)
  run.world.heroes[blue].attackObjectId = run.world.heroes[red].id
  run.world.heroes[blue].hp = run.world.heroes[blue].maxHp div 2
  run.world.heroes[blue].mana = run.world.heroes[blue].maxMana
  for slot in HeroAbilitySlot:
    run.world.heroes[blue].cooldowns[slot] = 0
  advanceGame()
  var used = false
  for slot in HeroAbilitySlot:
    if run.world.heroes[blue].cooldowns[slot] > 0:
      used = true
  doAssert used, "the selected hero did not spend an ability"

echo "Testing footmen walk out of the red base"
block:
  ## Later tests leave the spawn timer high and the roster empty. Reset
  ## those so a fresh wave can march out of the fort.
  run.world.gameOver = false
  run.world.footmen.setLen(0)
  run.world.spawnTimerTicks = 1
  var spawned = false
  for _ in 0 ..< TickRate:
    advanceGame()
    if run.world.footmen.len > 0:
      spawned = true
      break
  doAssert spawned, "the first footman wave never spawned"
  var
    startX: int32
    startZ: int32
    startId = 0'i32
  for footman in run.world.footmen:
    if footman.team != RedTeam or footman.state == Dying:
      continue
    startX = footman.position.x
    startZ = footman.position.z
    startId = footman.id
    break
  doAssert startId != 0, "no living red footman after the first wave"
  for _ in 0 ..< TickRate * 10:
    advanceGame()
  var
    found = false
    moved = false
    outside = false
  for footman in run.world.footmen:
    if footman.id != startId:
      continue
    found = true
    let
      dx = int64(footman.position.x) - int64(startX)
      dz = int64(footman.position.z) - int64(startZ)
      tileX = int(mapCoordinate(footman.position.x))
      tileZ = int(mapCoordinate(footman.position.z))
      ring = max(abs(tileX - RedFortTile), abs(tileZ - RedFortTile))
    moved = dx * dx + dz * dz >= int64(2 * WorldScale) * int64(2 * WorldScale)
    outside = ring > FortWallRadius
    break
  doAssert found, "the tracked footman disappeared"
  doAssert moved, "the tracked footman did not leave its spawn tile"
  doAssert outside, "the tracked footman never left the red fort walls"

echo "test_gota_sim: all checks passed"

echo "Testing team victories and timeout standings"
block:
  let world = run.world.clone()
  world.gameOver = false
  doAssert world.scores() == @[0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  world.gameOver = true
  world.winner = RedTeam
  doAssert world.scores() == @[1, 1, 1, 1, 1, 0, 0, 0, 0, 0]
  world.winner = BlueTeam
  doAssert world.scores() == @[0, 0, 0, 0, 0, 1, 1, 1, 1, 1]
