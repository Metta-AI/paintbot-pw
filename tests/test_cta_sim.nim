## Call to Adventure simulation: hashing, claims, movement, and restore.

import
  polyworld/[fixed, pathing, rngs, tapes],
  ../examples/call_to_adventure/[content, sim, replays]

proc testSetup(): Setup =
  result = Setup(
    seed: 2026,
    mapVersion: 1,
    tickRate: uint16(TickRate),
    gridTiles: uint16(GridTiles),
    levels: uint8(LevelCount),
    decisionTicks: uint16(DecisionTicks),
    hashIntervalTicks: uint16(HashIntervalTicks),
    maximumTicks: uint32(DefaultMaximumTicks),
    mapHash: 0x1234_5678_9ABC_DEF0'u64
  )
  for slot in 0 ..< PartySize:
    result.party[slot] = PartyMember(
      id: int32(100 + slot),
      class: HeroClass(slot)
    )

proc populate(world: World) =
  ## Gives the world enough shape that every hashed field is non-trivial.
  world.actors.setLen(PartySize)
  for slot in 0 ..< PartySize:
    let class = HeroClass(slot)
    world.actors[slot] = Actor(
      id: int32(100 + slot),
      kind: HeroActor,
      class: uint8(class),
      home: TileRef(level: 0, x: uint8(10 + slot), z: 10),
      next: TileRef(level: 0, x: uint8(10 + slot), z: 10),
      baseSpeed: ClassSpeeds[class],
      speed: ClassSpeeds[class],
      hp: ClassHp[class],
      maxHp: ClassHp[class],
      mana: ClassMana[class],
      maxMana: ClassMana[class]
    )
  discard world.addActor(Actor(
    id: 0,
    kind: MonsterActor,
    class: uint8(OrcSpecies),
    home: TileRef(level: 2, x: 40, z: 40),
    baseSpeed: SpeciesSpeeds[OrcSpecies],
    speed: SpeciesSpeeds[OrcSpecies],
    hp: SpeciesHp[OrcSpecies],
    maxHp: SpeciesHp[OrcSpecies]
  ))
  world.items.add Item(
    id: 1,
    kind: HealingPotionLoot,
    tile: TileRef(level: 4, x: 60, z: 61),
    value: LootValues[HealingPotionLoot],
    weight: LootWeights[HealingPotionLoot]
  )
  world.doors.add Door(id: 1, tile: TileRef(level: 2, x: 33, z: 44))
  world.markExplored(TileRef(level: 2, x: 33, z: 44))
  world.markVisible(0, TileRef(level: 0, x: 11, z: 10))
  world.say(100, 2, 7)
  world.rebuildClaims()

proc flatTile(): Tile =
  ## Creates one flat tile connected to its east and south neighbors.
  Tile(
    tops: [0'i16, 0, 0, 0],
    flags: TileExists or TileConnectedEast or TileConnectedSouth
  )

proc flatLayer(width: int): QuadLayer =
  ## Creates one row of flat tiles for a straight movement test.
  result = QuadLayer(
    width: width,
    depth: 1,
    tiles: newSeq[Tile](width)
  )
  for tile in result.tiles.mitems:
    tile = flatTile()

proc eastwardPos(actor: Actor): Fixed =
  ## Tile-space x from the centre of the start tile.
  actor.body.pos.x - 0.5'fx

echo "Testing clone is an independent deep copy"
block:
  let world = newWorld(testSetup())
  world.populate()
  let snapshot = world.clone()
  doAssert hashWorld(world) == hashWorld(snapshot)

  world.actors[0].hp = 3
  world.items[0].value = 1
  world.claims[500] = 9
  world.explored[7] = 0xFF
  world.chat[0].value = 99
  doAssert hashWorld(world) != hashWorld(snapshot),
    "mutating the original must not be invisible to the hash"
  doAssert snapshot.actors[0].hp != 3,
    "clone shared its actors seq with the original"
  doAssert snapshot.items[0].value != 1
  doAssert snapshot.claims[500] != 9
  doAssert snapshot.explored[7] != 0xFF
  doAssert snapshot.chat[0].value != 99

echo "Testing restore returns a world to a snapshot exactly"
block:
  let world = newWorld(testSetup())
  world.populate()
  let snapshot = world.clone()
  let before = hashWorld(world)

  for _ in 0 ..< 100:
    discard world.rng.next()
  world.tick = 4137
  world.actors[1].hp = 1
  world.banked = 5000
  world.outcome = WipedOutcome
  doAssert hashWorld(world) != before

  world.restore(snapshot)
  doAssert hashWorld(world) == before, "restore did not reproduce the snapshot"
  doAssert world.tick == 0
  doAssert world.rng.state ==
    snapshot.rng.state

echo "Testing restore keeps the caller's ref identity"
block:
  let world = newWorld(testSetup())
  world.populate()
  let alias = world              # stands in for a captured host closure
  let snapshot = world.clone()
  world.tick = 900
  world.restore(snapshot)
  doAssert alias.tick == 0, "restore rebound the ref instead of assigning"

echo "Testing every scalar field of World reaches the hash"
block:
  # The tripwire. Add a field to World and this fails on the day the field
  # is added rather than during a divergence hunt weeks later.
  let world = newWorld(testSetup())
  world.populate()
  var checked = 0
  for name, value in world[].fieldPairs:
    when value is SomeInteger:
      let base = hashWorld(world)
      let saved = value
      value = value + 1
      doAssert hashWorld(world) != base, "unhashed field: " & name
      value = saved
      doAssert hashWorld(world) == base
      inc checked
    elif value is enum:
      let base = hashWorld(world)
      let saved = value
      value = if saved == low(typeof(value)): succ(saved) else: pred(saved)
      doAssert hashWorld(world) != base, "unhashed field: " & name
      value = saved
      doAssert hashWorld(world) == base
      inc checked
  doAssert checked >= 6, "the tripwire checked suspiciously few fields"

echo "Testing the compound fields of World reach the hash"
block:
  # fieldPairs only reaches top-level scalars, so the seqs, arrays and
  # nested objects are poked by hand. Each of these is a field that a naive
  # hash of packed memory would plausibly miss.
  let world = newWorld(testSetup())
  world.populate()

  template mutates(label: string, body: untyped) =
    let base = hashWorld(world)
    let snapshot = world.clone()
    body
    doAssert hashWorld(world) != base, "unhashed: " & label
    world.restore(snapshot)
    doAssert hashWorld(world) == base

  mutates "actors": world.actors[0].facing = North
  mutates "actor cooldowns": world.actors[0].cooldowns[int(FirebrandSword)] = 12
  mutates "actor inventory": world.actors[0].inventory[1] = 77
  mutates "actor haste": world.actors[0].hasteTicks = 12
  mutates "actor path":
    world.actors[0].path.add PathStep(
      tile: TileRef(level: 0, x: 12, z: 10), direction: East)
  mutates "actor tombstones": world.actors.add Actor()
  mutates "items": world.items[0].tile.x = 61
  mutates "doors": world.doors[0].open = true
  mutates "claims": world.claims[1234] = 3
  mutates "explored": world.markExplored(TileRef(level: 5, x: 1, z: 1))
  mutates "visible": world.markVisible(3, TileRef(level: 5, x: 1, z: 1))
  mutates "chat": world.chat[2].phrase = 4
  mutates "personal gold": world.bankedGold[1] = 100
  mutates "returned heroes": world.returned[2] = true
  mutates "rng": discard world.rng.next()

echo "Testing tile claims are exclusive"
block:
  let world = newWorld(testSetup())
  world.populate()
  let tile = TileRef(level: 3, x: 20, z: 20)
  doAssert not world.claimed(tile)
  let slot = world.addActor(Actor(
    kind: MonsterActor,
    class: uint8(OrcSpecies),
    home: tile,
    hp: 10,
    maxHp: 10
  ))
  doAssert slot >= 0
  doAssert world.claimed(tile)
  doAssert world.claimant(tile) == slot

  let rejected = world.addActor(Actor(
    kind: MonsterActor,
    class: uint8(LichSpecies),
    home: tile,
    hp: 10,
    maxHp: 10
  ))
  doAssert rejected == -1, "two actors must never share a tile"

  world.removeActor(slot)
  doAssert not world.claimed(tile)
  doAssert world.actors[slot].id == 0

echo "Testing removed slots are reused before the seq grows"
block:
  let world = newWorld(testSetup())
  world.populate()
  let first = world.addActor(Actor(
    kind: MonsterActor, home: TileRef(level: 1, x: 5, z: 5),
    hp: 1, maxHp: 1))
  let
    length = world.actors.len
    firstId = world.actors[first].id
  world.removeActor(first)
  let second = world.addActor(Actor(
    kind: MonsterActor, home: TileRef(level: 1, x: 6, z: 5),
    hp: 1, maxHp: 1))
  doAssert second == first, "a free slot should be reused"
  doAssert world.actors.len == length
  doAssert world.actors[second].id > firstId,
    "ids must keep increasing even when a slot is reused"

echo "Testing rebuildClaims matches the incremental claims"
block:
  let world = newWorld(testSetup())
  world.populate()
  let before = hashWorld(world)
  world.rebuildClaims()
  doAssert hashWorld(world) == before,
    "claims drifted from what actor homes imply"

echo "Testing tileKnown reports party memory and private sight"
block:
  let world = newWorld(testSetup())
  world.populate()
  let tile = TileRef(level: 2, x: 70, z: 70)
  doAssert world.tileKnown(0, tile) == 0
  world.markExplored(tile)
  doAssert world.tileKnown(0, tile) == 1
  doAssert world.tileKnown(1, tile) == 1, "memory is shared by the party"
  world.markVisible(0, tile)
  doAssert world.tileKnown(0, tile) == 2
  doAssert world.tileKnown(1, tile) == 1, "sight is not shared by the party"

echo "Testing tile indexing covers the world without collision"
block:
  var seen = newSeq[bool](WorldTiles)
  for level in 0 ..< LevelCount:
    for z in 0 ..< GridTiles:
      for x in 0 ..< GridTiles:
        let index = TileRef(
          level: int8(level), x: uint8(x), z: uint8(z)).tileIndex
        doAssert index >= 0 and index < WorldTiles
        doAssert not seen[index], "tile index collision"
        seen[index] = true

echo "Testing the same seed builds the same world"
block:
  let first = newWorld(testSetup())
  let second = newWorld(testSetup())
  doAssert hashWorld(first) == hashWorld(second)
  var other = testSetup()
  other.seed = 2027
  let third = newWorld(other)
  doAssert hashWorld(third) != hashWorld(first),
    "a different seed must produce a different world"

echo "Testing encumbrance scales speed in steps"
block:
  var actor = Actor(kind: HeroActor, class: uint8(FighterClass))
  let capacity = actor.carryCapacity
  doAssert capacity == ClassCarryWeight[FighterClass]
  doAssert actor.encumbrance(capacity) == 0
  actor.carriedWeight = capacity div 2
  doAssert actor.encumbrance(capacity) == 2
  actor.carriedWeight = capacity
  doAssert actor.encumbrance(capacity) == 3
  actor.carriedWeight = capacity * 10
  doAssert actor.encumbrance(capacity) == 3, "encumbrance must saturate"

echo "Testing CTA movement stays linear across tile boundaries"
block:
  layers = @[flatLayer(6)]
  computeWalkable()

  let
    world = newWorld(Setup(seed: 1988))
    slot = world.addActor(Actor(
      home: TileRef(level: 0, x: 0, z: 0),
      speed: ClassSpeeds[RogueClass],
      hp: 1,
      maxHp: 1
    ))
  doAssert slot == 0

  for x in 1'u8 .. 5'u8:
    world.actors[slot].path.add PathStep(
      tile: TileRef(level: 0, x: x, z: 0),
      direction: East
    )

  for tick in 1'i32 .. 20'i32:
    discard world.advancePath(slot)
    doAssert world.actors[slot].moving,
      "the test path must continue through every sampled tick"
    let
      expected = fixed(tick) * fixed(ClassSpeeds[RogueClass]) / fixed(PhaseUnits)
      travelled = world.actors[slot].eastwardPos
    doAssert abs(travelled - expected) <= Fixed(512),
      "movement drifted at tile boundary on tick " & $tick
    doAssert abs(world.actors[slot].body.pos.y - 0.5'fx) <= Fixed(8)

echo "Testing stepToward only sets the path"
block:
  layers = @[flatLayer(6)]
  computeWalkable()
  let
    world = newWorld(Setup(seed: 1988))
    slot = world.addActor(Actor(
      home: TileRef(level: 0, x: 0, z: 0),
      speed: ClassSpeeds[RogueClass],
      hp: 1,
      maxHp: 1
    ))
    goal = TileRef(level: 0, x: 5, z: 0)
    before = world.actors[slot].body.pos
  doAssert world.stepToward(slot, goal)
  doAssert world.actors[slot].body.pos == before,
    "a walk command must not also steer that tick"
  doAssert world.pathGoal(slot) == goal
  discard world.advancePath(slot)
  doAssert world.actors[slot].body.pos != before,
    "movement must happen in the path phase"

echo "Testing paths route around occupied tiles"
block:
  var floor = QuadLayer(
    width: 3,
    depth: 5,
    tiles: newSeq[Tile](15)
  )
  for tile in floor.tiles.mitems:
    tile = flatTile()
  layers = @[floor]
  computeWalkable()
  let
    world = newWorld(Setup(seed: 1988))
    walker = world.addActor(Actor(
      home: TileRef(level: 0, x: 1, z: 0),
      speed: ClassSpeeds[RogueClass],
      hp: 1,
      maxHp: 1
    ))
    blocker = world.addActor(Actor(
      home: TileRef(level: 0, x: 1, z: 2),
      speed: ClassSpeeds[FighterClass],
      hp: 1,
      maxHp: 1
    ))
    goal = TileRef(level: 0, x: 1, z: 4)
  doAssert walker >= 0 and blocker >= 0
  doAssert world.setPath(walker, goal),
    "an occupied corridor must still have a way around"
  doAssert world.pathGoal(walker) == goal
  for step in world.actors[walker].path:
    doAssert not (step.tile == world.actors[blocker].home),
      "the route walked through the standing hero"

echo "Testing live history seek does not skip recorded actions"
block:
  ## The graphical scrubber restores a live checkpoint whose stored cursor
  ## is still 0, then catches up through recorded hero commands.
  let
    game = newGame(2026, 200)
    recorder = initReplayRecorder(game.world.setup)
    player = ReplayPlayer(data: recorder.data)
  game.recorder = recorder

  proc walkTile(tile: TileRef): TileRef =
    ## Returns a neighboring walkable tile, or the original tile.
    result = tile
    for facing in Facing:
      let next = tile.neighbor(facing)
      if next.walkable:
        return next

  proc liveDecide(game: Game, slot: int32) =
    ## Records one walk so the live tape is not empty.
    let actor = game.world.actors[slot]
    if actor.kind != HeroActor or not actor.alive or actor.busy:
      return
    let
      dest = walkTile(actor.home)
      action = ReplayAction(
        tick: uint32(game.world.tick),
        heroId: actor.id,
        kind: ActionWalkTo,
        first: int32(dest.level),
        second: int32(dest.x),
        third: int32(dest.z)
      )
    recorder.recordAction(
      action.tick,
      action.heroId,
      action.kind,
      action.first,
      action.second,
      action.third
    )
    discard game.applyHeroAction(slot, action)

  proc replayDecide(game: Game, slot: int32) =
    ## Replays every recorded command for this hero on this tick.
    let actor = game.world.actors[slot]
    if actor.kind != HeroActor:
      return
    var action: ReplayAction
    while player.takeActionAt(uint32(game.world.tick), actor.id, action):
      discard game.applyHeroAction(slot, action)

  const
    SnapAfter = 20
    LiveTicks = 40
  var snapshot: World
  for i in 1 .. LiveTicks:
    game.tickWorld(liveDecide)
    recorder.recordHash(game.stateHash())
    if i == SnapAfter:
      snapshot = game.world.clone()
  doAssert recorder.data.actions.len > 0,
    "heroes issued no commands during the live window"
  doAssert player.actionIndex == 0,
    "live recording must not advance the playback cursor"
  let
    frontierTick = game.world.tick
    frontierHash = game.stateHash()
  game.world.restore(snapshot)
  player.data = recorder.data
  player.syncCursor(uint32(game.world.tick))
  while game.world.tick < frontierTick:
    game.tickWorld(replayDecide)
  doAssert game.world.tick == frontierTick
  doAssert game.stateHash() == frontierHash,
    "catching up from a live seek diverged from the recorded frontier"

echo "Testing viewLevel follows the uppermost selected hero"
block:
  var game = Game(world: newWorld(testSetup()))
  game.world.populate()
  game.world.actors[0].home.level = 3
  game.world.actors[1].home.level = 1
  game.world.actors[2].home.level = 4
  game.world.actors[3].home.level = 2
  var selected: array[PartySize, bool]
  selected[0] = true
  selected[1] = true
  selected[2] = true
  doAssert game.viewLevel(selected) == 1,
    "the cutaway must follow the selected hero closest to the surface"
  selected[1] = false
  doAssert game.viewLevel(selected) == 3
  selected[0] = false
  selected[2] = false
  selected[3] = true
  doAssert game.viewLevel(selected) == 2
  var none: array[PartySize, bool]
  doAssert game.viewLevel(none) == 1,
    "with no selection the cutaway still follows the highest living hero"

echo "Testing a hero walks a ramp without falling into a wall"
block:
  const
    Low = 0'i16
    High = 64'i16
    Rise = 8'i16
    RampTiles = int(High - Low) div int(Rise)
  proc flatAt(originX, originZ, width, depth: int, height: int16): QuadLayer =
    result = QuadLayer(
      originX: originX,
      originZ: originZ,
      width: width,
      depth: depth,
      tiles: newSeq[Tile](width * depth)
    )
    for tile in result.tiles.mitems:
      tile = Tile(
        tops: [height, height, height, height],
        flags: TileExists or TileConnectedEast or TileConnectedSouth
      )
  let lower = flatAt(0, 0, 4, 3, Low)
  var ramp = QuadLayer(
    originX: 4, originZ: 1, width: RampTiles, depth: 1,
    tiles: newSeq[Tile](RampTiles)
  )
  for i in 0 ..< RampTiles:
    let
      near = Low + Rise * int16(i)
      far = Low + Rise * int16(i + 1)
    ramp.tiles[i] = Tile(
      tops: [near, far, near, far],
      flags: TileExists or TileConnectedEast or TileConnectedSouth
    )
  layers = @[lower, ramp, flatAt(12, 0, 4, 3, High)]
  computeWalkable()
  let world = newWorld(Setup(seed: 1988))
  let slot = world.addActor(Actor(
    home: TileRef(level: 0, x: 0, z: 1),
    speed: ClassSpeeds[RogueClass],
    hp: 1,
    maxHp: 1
  ))
  doAssert world.setPath(slot, TileRef(level: 2, x: 3, z: 1))
  for _ in 1 .. 400:
    discard world.advancePath(slot)
    let home = world.actors[slot].home
    doAssert isWalkable(int(home.level), int(home.x), int(home.z)),
      "the hero left walkable tiles at " & $home
  doAssert world.actors[slot].home.level == 2,
    "the hero never reached the upper floor"
  doAssert not world.actors[slot].moving

echo "Testing a hero faces the direction of travel"
block:
  proc flatAt(originX, originZ, width, depth: int, height: int16): QuadLayer =
    result = QuadLayer(
      originX: originX,
      originZ: originZ,
      width: width,
      depth: depth,
      tiles: newSeq[Tile](width * depth)
    )
    for tile in result.tiles.mitems:
      tile = Tile(
        tops: [height, height, height, height],
        flags: TileExists or TileConnectedEast or TileConnectedSouth
      )
  layers = @[flatAt(0, 0, 16, 16, 0)]
  computeWalkable()
  let world = newWorld(Setup(seed: 7))
  let slot = world.addActor(Actor(
    home: TileRef(level: 0, x: 2, z: 2),
    facing: East,
    speed: ClassSpeeds[RogueClass],
    hp: 1,
    maxHp: 1
  ))
  doAssert world.setPath(slot, TileRef(level: 0, x: 10, z: 10))
  for _ in 1 .. 30:
    discard world.advancePath(slot)
  let dir = direction(world.actors[slot].body.facing)
  doAssert abs(dir.x) > 0.25'fx and abs(dir.y) > 0.25'fx,
    "the hero snapped to a cardinal instead of facing the diagonal"

echo "Testing a hero can drop a carried item"
block:
  let
    game = newGame(2026, 240)
    slot = 0'i32
    hero = game.world.actors[slot]
    itemId = game.world.nextItemId
  game.world.items.add Item(
    id: itemId,
    kind: HealingPotionLoot,
    tile: hero.home,
    carrier: hero.id,
    weight: LootWeights[HealingPotionLoot]
  )
  inc game.world.nextItemId
  game.world.actors[slot].inventory[0] = itemId
  doAssert game.applyHeroAction(slot, ReplayAction(
    heroId: 100,
    kind: ActionDropItem,
    first: 0
  ))
  doAssert game.world.actors[slot].inventory[0] == 0
  let index = game.world.itemIndex(itemId)
  doAssert index >= 0
  doAssert game.world.items[index].carrier == 0
  doAssert game.world.items[index].tile == hero.home

echo "test_cta_sim: all checks passed"

echo "Testing standings require a living returned hero"
block:
  let world = newWorld(testSetup())
  world.populate()
  world.bankedGold = [10'i32, 20, 30, 999]
  doAssert world.scores() == @[0, 0, 0, 0]
  world.returned[0] = true
  doAssert world.scores() == @[1, 0, 0, 0]
  world.returned[1] = true
  doAssert world.scores() == @[0, 1, 0, 0]
  world.bankedGold[0] = 20
  doAssert world.scores() == @[1, 1, 0, 0]
  world.returned[3] = true
  world.actors[3].hp = 0
  doAssert world.scores() == @[1, 1, 0, 0]
  world.actors[0].hp = 0
  world.actors[1].hp = 0
  doAssert world.scores() == @[0, 0, 0, 0]

echo "Testing personal gold is banked before carried gold is cleared"
block:
  let game = newGame(2026, 240)
  game.world.phase = ReturningPhase
  for slot in 0 ..< PartySize:
    game.world.actors[slot].carriedValue = int32(slot + 1) * 100
  proc noDecision(game: Game, slot: int32) =
    ## Leaves the heroes at the surface for the banking test.
    discard
  game.tickWorld(noDecision)
  doAssert game.world.returned == [true, true, true, true]
  doAssert game.world.bankedGold == [100'i32, 200, 300, 400]
  doAssert game.world.banked == 1000
  for slot in 0 ..< PartySize:
    doAssert game.world.actors[slot].carriedValue == 0
  doAssert game.world.scores() == @[0, 0, 0, 1]
  let snapshot = game.world.clone()
  game.world.bankedGold[3] = 0
  game.world.returned[3] = false
  game.world.restore(snapshot)
  doAssert game.world.scores() == @[0, 0, 0, 1]
