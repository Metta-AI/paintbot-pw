## Gods of the Arena simulation: objects, vision, combat, and the tick.
##
## Planar unit motion uses Q16.16 tile-space bodies. Height, combat ranges,
## and replay integers stay on `WorldPoint`. This module must not import
## anything that returns a float. Graphics may sample `surfaceHeight` and
## must not write simulation state.
##
## BASIC decisions arrive through `onHeroTurn`. This module owns the
## VM type on `Game` but never runs a program.

import
  std/[strformat],
  polyworld/[basic, bodies, fixed, hashes, noises, pathing, profiles, rngs,
    tapes, visions],
  content,
  maps,
  replays

## Deterministic animation slots shared by every backend.

const
  runClip* = 0
  idleClip* = 1
  deathClip* = 2
  victoryClip* = 3
  attackClips* = [4, 5]
  heroRunClip* = 0
  heroIdleClip* = 1
  heroDeathClip* = 2
  heroAttackClips* = [3, 4]

## Lane waypoints

type LaneStop = tuple[layer, x, z: int]

const LaneRoutes: array[3, seq[LaneStop]] = [
  @[(GroundLayer, 23, 20), (GroundLayer, 29, 20),
    (GroundLayer, 107, 21), (GroundLayer, 107, 32),
    (GroundLayer, 107, 98), (GroundLayer, 107, 104)],
  @[(GroundLayer, 23, 21), (GroundLayer, 29, 21),
    (GroundLayer, 48, 54), (BridgeLayer, 11, 3),
    (GroundLayer, 82, 68), (GroundLayer, 98, 106),
    (GroundLayer, 104, 106)],
  @[(GroundLayer, 20, 23), (GroundLayer, 20, 29),
    (GroundLayer, 21, 107), (GroundLayer, 32, 107),
    (GroundLayer, 98, 107), (GroundLayer, 104, 107)],
]

var
  lanePathPoints*: array[3, seq[PathPoint]]
  lanePathTiles: array[3, seq[PathTile]]
  laneWorldLayers: array[3, seq[int32]]
  visionBlockers: seq[int16]
  visionSources: seq[VisionSource]
  visionSkipWorld: pointer
  visionSkipKeys: seq[int32]
  visionSkipNow: seq[int32]
  heroPathPoints: seq[PathPoint]
  heroPathTiles: seq[PathTile]
  gotaWalkLayer: int
  gotaWalkDestLayer: int

## Simulation

type
  Team* = enum RedTeam, BlueTeam
  FootmanState* = enum Marching, Fighting, Dying
  TowerTier* = enum OuterTower, InnerTower, GateTower
  WorldPoint* = object
    x*, y*, z*: int32
  Heading* = object
    x*, z*: int32
  HeroVm* = ref object
    runtime*: Runtime
    limits*: Limits
    ready*: bool
    failed*: bool
    lastError*: string
    decisions*: int
    lastWork*, lastInstructions*: int64

  Footman* = object
    id*: int32
    team*: Team
    lane*: int
    position*: WorldPoint
    facing*: Heading
    body*: Body
    hp*: int32
    state*: FootmanState
    waypointIndex*: int
    targetId*: int32
    targetHeroId*: int32
    targetTowerId*: int32
    attackingFort*: bool
    swingClip*: int
    swingTicks*: int32
    damageLanded*: bool
    animClip*: int
    animTicks*: int32
    deathTicks*: int32
    surfaceHint*: int32
    navLayer*: int32

  Hero* = ref object
    id*: int32
    team*: Team
    slot*: int
    lane*: int
    class*: HeroClass
    position*: WorldPoint
    spawnPosition*: WorldPoint
    facing*: Heading
    body*: Body
    hp*: int32
    maxHp*: int32
    mana*: int32
    maxMana*: int32
    level*: int
    xp*: int
    totalXp*: int
    gold*: int
    state*: FootmanState
    waypointIndex*: int
    targetFootmanId*: int32
    targetHeroId*: int32
    targetTowerId*: int32
    attackingFort*: bool
    swingClip*: int
    swingTicks*: int32
    damageLanded*: bool
    animClip*: int
    animTicks*: int32
    deathTicks*: int32
    surfaceHint*: int32
    navLayer*: int32
    attackObjectId*: int32
    movePath*: seq[WorldPoint]
    movePathLayers*: seq[int32]
    movePathIndex*: int
    moveTileX*: int
    moveTileY*: int
    hasMoveTarget*: bool
    inventory*: array[InventorySlots, Item]
    itemCounts*: array[InventorySlots, int32]
    cooldowns*: array[HeroAbilitySlot, int32]

  Fort* = object
    id*: int32
    team*: Team
    center*: WorldPoint
    hp*: int32

  Tower* = object
    id*: int32
    team*: Team
    lane*: int
    tier*: TowerTier
    position*: WorldPoint
    facing*: Heading
    hp*: int32
    maxHp*: int32
    targetId*: int32
    attackTicks*: int32

  WorldObject* = object
    id*: int32
    kind*: int32
    class*: int32
    team*: Team
    position*: WorldPoint
    hp*: int32
    maxHp*: int32
    alive*: bool

  NavTile* = object
    layer*: int
    x*: int
    z*: int

  World* = ref object
    ## One match. A ref so `a = b` aliases and a second world is `clone()`.
    footmen*: seq[Footman]
    heroes*: seq[Hero]
    forts*: array[2, Fort]
    towers*: seq[Tower]
    barracksSpawns*: array[2, array[3, WorldPoint]]
    spawnIntervalTicks*: int32
    spawnTimerTicks*: int32
    gameOver*: bool
    winner*: Team
    rng*: Rng
    nextFootmanId*: int32
    tick*: int32
    heroTurnTicks*: int32
    heroTurnStart*: int
    teamHeroKills*: array[2, int]
    teamHeroDeaths*: array[2, int]
    teamVisible*: array[2, seq[uint8]]
    teamExplored*: array[2, seq[uint8]]
    scriptObjects: seq[WorldObject]
    scriptObjectCount: int
    scriptObjectsHeroId: int32
    scriptObjectsTick: int32
  Game* = ref object
    ## One match session. World is the hashable sim; everything else is
    ## tape, map, and agents.
    world*: World
    map*: MapData
    recorder*: ReplayRecorder
    replayData*: ReplayData
    replayPlayer*: ReplayPlayer
    hashCheck*: ReplayHashCheck
    historyPlayback*: bool
    replayMode*: bool
    recordingError*: string
    heroVms*: seq[HeroVm]

const
  WorldScale* = 60_000'i32
  FirstTowerId = 10'i32
  TowerHitPoints*: array[TowerTier, int32] = [600'i32, 800, 1_000]
  TowerDamages*: array[TowerTier, int32] = [14'i32, 18, 22]
  TowerAttackRanges*: array[TowerTier, int32] = [
    300_000'i32,
    330_000,
    360_000
  ]
  TowerAttackTicks* = TickRate
  TowerSiegeRange* = 105_000'i32

proc worldPoint(point: PathPoint): WorldPoint =
  ## Converts one exact 1/32-tile path point into integer world units.
  const PathUnit = WorldScale div PathUnitsPerTile
  WorldPoint(
    x: point.x * PathUnit,
    y: point.y * PathUnit,
    z: point.z * PathUnit
  )

proc heading*(x, z: int32): Heading =
  ## Creates an integer heading from a non-normalized planar direction.
  Heading(x: x, z: z)

proc `-`(first, second: WorldPoint): WorldPoint =
  ## Subtracts two authoritative world positions.
  WorldPoint(
    x: first.x - second.x,
    y: first.y - second.y,
    z: first.z - second.z
  )

proc `+`(first, second: WorldPoint): WorldPoint =
  ## Adds two authoritative world offsets.
  WorldPoint(
    x: first.x + second.x,
    y: first.y + second.y,
    z: first.z + second.z
  )

proc distanceSquared(first, second: WorldPoint): int64 =
  ## Returns squared planar distance without floating-point arithmetic.
  let
    x = int64(first.x) - int64(second.x)
    z = int64(first.z) - int64(second.z)
  x * x + z * z

proc within(first, second: WorldPoint, distance: int32): bool =
  ## Tests a planar range using squared authoritative integer units.
  distanceSquared(first, second) <= int64(distance) * int64(distance)

proc scaledPlanar(direction: WorldPoint, distance: int32): WorldPoint =
  ## Scales an integer direction to an exact signed planar distance.
  let length = integerSqrt(
    int64(direction.x) * int64(direction.x) +
    int64(direction.z) * int64(direction.z)
  )
  if length == 0:
    return
  WorldPoint(
    x: int32(roundDivision(int64(direction.x) * distance, length)),
    z: int32(roundDivision(int64(direction.z) * distance, length))
  )

proc floorWorldTile(value: int32): int =
  ## Floors a signed fixed-point coordinate to its whole world tile.
  if value >= 0:
    int(value div WorldScale)
  else:
    -int(((-int64(value)) + int64(WorldScale) - 1) div
      int64(WorldScale))

proc fixedSurfaceHeight(position: WorldPoint): int32
proc fixedSurfaceHeightNear(
    position: WorldPoint,
    referenceY: int32
): int32

proc laneWorldPlacement(
    path: seq[PathPoint],
    ratioPermille: int32,
    offset: int32
): tuple[position: WorldPoint, facing: Heading] =
  ## Places one authoritative structure using integer path geometry.
  let
    index = clamp(
      int(roundDivision(
        int64(path.len - 1) * ratioPermille,
        1000
      )),
      0,
      path.len - 1
    )
    nextIndex = min(index + 1, path.len - 1)
    previousIndex = max(index - 1, 0)
    center = worldPoint(path[index])
    previous = worldPoint(path[previousIndex])
    next = worldPoint(path[nextIndex])
    direction = next - previous
    side = WorldPoint(x: -direction.z, z: direction.x)
  result.facing = heading(direction.x, direction.z)
  for amount in [offset, -offset, offset div 2, -offset div 2]:
    var position = center + scaledPlanar(side, amount)
    let
      tileX = floorWorldTile(position.x) + GridTiles div 2
      tileZ = floorWorldTile(position.z) + GridTiles div 2
    if isWalkable(GroundLayer, tileX, tileZ):
      position.y = fixedSurfaceHeight(position)
      result.position = position
      return
  result.position = center
  result.position.y = fixedSurfaceHeight(result.position)

proc initTowers(world: World) =
  ## Creates the lane tower records used by simulation UI and rendering.
  for lane in 0 .. 2:
    let path = lanePathPoints[lane]
    for definition in [
      (team: RedTeam, tier: OuterTower,
        ratio: 380'i32, offset: 180_000'i32),
      (team: RedTeam, tier: InnerTower,
        ratio: 220'i32, offset: 192_000'i32),
      (team: RedTeam, tier: GateTower,
        ratio: 55'i32, offset: 210_000'i32),
      (team: BlueTeam, tier: OuterTower,
        ratio: 620'i32, offset: -180_000'i32),
      (team: BlueTeam, tier: InnerTower,
        ratio: 780'i32, offset: -192_000'i32),
      (team: BlueTeam, tier: GateTower,
        ratio: 945'i32, offset: -210_000'i32)
    ]:
      let placement = laneWorldPlacement(
        path,
        definition.ratio,
        definition.offset
      )
      let hitPoints = TowerHitPoints[definition.tier]
      world.towers.add Tower(
        id: FirstTowerId + world.towers.len.int32,
        team: definition.team,
        lane: lane,
        tier: definition.tier,
        position: placement.position,
        facing: placement.facing,
        hp: hitPoints,
        maxHp: hitPoints
      )

const
  FootmanHp* = 60'i32
  FootmanDamage* = 12'i32
  FootmanMovePerTick* = 5_500'i32
  FootmanBodyRadius = 0.22'fx
  HeroBodyRadius = 0.28'fx
  BodyTurnRate = 0.35'fx
  FootmanSightRadius* = 5 * WorldScale
  FootmanTowerSightRadius = 7 * WorldScale
  FootmanMeleeRange* = 54_000'i32
  FortRange = 255_000'i32
  HeroLanes = [0, 0, 1, 2, 2]
  HeroRespawnTicks = 8 * TickRate
  HeroMaxLevel* = 20
  FootmanXpReward = 25
  FootmanGoldReward = 15
  HeroXpReward = 150
  HeroGoldReward = 100
  TowerXpReward = 100
  TowerGoldReward = 75
  DecisionTicks = 1'i32
    ## Ticks between hero VM decisions. One decision per simulation tick.
  FortObjectKind = 1'i32
  HeroObjectKind = 2'i32
  FootmanObjectKind = 3'i32
  TowerObjectKind = 4'i32
  RedFortId = 1'i32
  BlueFortId = 2'i32
  FirstHeroId* = 100'i32
  FirstFootmanId = 1000'i32
  UnitCap = 120
  CorpseLingerTicks = 60'i32
  FootmanDeathTicks = 24'i32
  HeroDeathTicks = 24'i32
  FortHp* = 400'i32

proc startingForts(): array[2, Fort] =
  ## Places the two forts on their canonical map tiles.
  [
    Fort(
      id: RedFortId,
      team: RedTeam,
      hp: FortHp,
      center: WorldPoint(
        x: (RedFortTile - GridTiles div 2) * WorldScale +
          WorldScale div 2,
        z: (RedFortTile - GridTiles div 2) * WorldScale +
          WorldScale div 2
      )
    ),
    Fort(
      id: BlueFortId,
      team: BlueTeam,
      hp: FortHp,
      center: WorldPoint(
        x: (BlueFortTile - GridTiles div 2) * WorldScale +
          WorldScale div 2,
        z: (BlueFortTile - GridTiles div 2) * WorldScale +
          WorldScale div 2
      )
    )
  ]

proc cloneHeroes(heroes: seq[Hero]): seq[Hero] =
  ## Copies each hero so two worlds never share a path seq.
  result.setLen(heroes.len)
  for i, hero in heroes:
    result[i] = Hero()
    result[i][] = hero[]

proc clone*(w: World): World =
  ## Deep copy. Heroes are refs and must be cloned one by one.
  result = World()
  result[] = w[]
  result.heroes = cloneHeroes(w.heroes)

proc restore*(w: World, snapshot: World) =
  ## Overwrites in place, keeping the caller's ref identity.
  w[] = snapshot[]
  w.heroes = cloneHeroes(snapshot.heroes)

proc buildSightTerrain(): tuple[
    terrainHeights,
    blockerHeights: seq[int16]
] =
  ## Builds one integer occlusion grid from terrain and forest tiles.
  let cellCount = GridTiles * GridTiles
  result.terrainHeights = newSeq[int16](cellCount)
  result.blockerHeights = newSeq[int16](cellCount)
  for value in result.terrainHeights.mitems:
    value = int16.low
  for layer in layers:
    if layer.water:
      continue
    for z in 0 ..< layer.depth:
      for x in 0 ..< layer.width:
        let
          tile = layer.tiles[z * layer.width + x]
          mapX = layer.originX + x
          mapZ = layer.originZ + z
        if not tile.exists or mapX < 0 or mapX >= GridTiles or
            mapZ < 0 or mapZ >= GridTiles:
          continue
        let
          index = mapZ * GridTiles + mapX
          mean = int16(
            (int32(tile.tops[0]) + int32(tile.tops[1]) +
              int32(tile.tops[2]) + int32(tile.tops[3])) div 4
          )
        result.terrainHeights[index] = max(
          result.terrainHeights[index],
          mean
        )
  let ground = layers[GroundLayer]
  for z in 0 ..< ground.depth:
    for x in 0 ..< ground.width:
      let index = z * ground.width + x
      if ground.tiles[index].kind == TreeTile:
        result.blockerHeights[
          (ground.originZ + z) * GridTiles + ground.originX + x
        ] = 24
  for value in result.terrainHeights.mitems:
    if value == int16.low:
      value = 0

var sightTerrain: tuple[terrainHeights, blockerHeights: seq[int16]]

proc sightTile(position: WorldPoint): tuple[x, z: int32] =
  ## Converts one integer world position to the shared visibility grid.
  result.x = int32(floorWorldTile(position.x) + GridTiles div 2)
  result.z = int32(floorWorldTile(position.z) + GridTiles div 2)

proc addVisionBlocker(position: WorldPoint, height: int16) =
  ## Raises one tile's occluder height for this tick's vision pass.
  let tile = sightTile(position)
  if tile.x >= 0 and tile.x < GridTiles and
      tile.z >= 0 and tile.z < GridTiles:
    let index = tile.z * GridTiles + tile.x
    visionBlockers[index] = max(visionBlockers[index], height)

proc fillVisionKeys(world: World, dest: var seq[int32]) =
  ## Records living observers and the towers or forts that occlude them.
  dest.setLen(0)
  dest.add int32(world.heroes.len)
  for i in 0 ..< world.heroes.len:
    let
      hero = world.heroes[i]
      tile = sightTile(hero.position)
    dest.add hero.id
    dest.add int32(hero.team.ord)
    dest.add int32(hero.state.ord)
    dest.add hero.hp
    dest.add tile.x
    dest.add tile.z
  dest.add int32(world.footmen.len)
  for footman in world.footmen:
    let tile = sightTile(footman.position)
    dest.add footman.id
    dest.add int32(footman.team.ord)
    dest.add int32(footman.state.ord)
    dest.add footman.hp
    dest.add tile.x
    dest.add tile.z
  dest.add int32(world.towers.len)
  for tower in world.towers:
    let tile = sightTile(tower.position)
    dest.add tower.id
    dest.add int32(tower.team.ord)
    dest.add tower.hp
    dest.add tile.x
    dest.add tile.z
  dest.add int32(world.forts.len)
  for fort in world.forts:
    let tile = sightTile(fort.center)
    dest.add fort.id
    dest.add int32(fort.team.ord)
    dest.add fort.hp
    dest.add tile.x
    dest.add tile.z

proc rebuildVision*(world: World) {.measure.} =
  ## Rebuilds both teams' limited, terrain-occluded visibility maps.
  world.fillVisionKeys(visionSkipNow)
  if visionSkipWorld == cast[pointer](world) and
      sameVisionKeys(visionSkipNow, visionSkipKeys):
    return
  visionBlockers.setLen(sightTerrain.blockerHeights.len)
  for i, value in sightTerrain.blockerHeights:
    visionBlockers[i] = value
  for tower in world.towers:
    if tower.hp > 0:
      addVisionBlocker(tower.position, 28)
  for fort in world.forts:
    if fort.hp > 0:
      addVisionBlocker(fort.center, 32)
  for team in Team:
    visionSources.setLen(0)
    for i in 0 ..< world.heroes.len:
      let hero = world.heroes[i]
      if hero.team == team and hero.state != Dying and hero.hp > 0:
        let tile = sightTile(hero.position)
        visionSources.add VisionSource(
          x: tile.x,
          z: tile.z,
          radius: 10,
          eyeHeight: 14
        )
    for footman in world.footmen:
      if footman.team == team and footman.state != Dying and footman.hp > 0:
        let tile = sightTile(footman.position)
        visionSources.add VisionSource(
          x: tile.x,
          z: tile.z,
          radius: FootmanSightRadius div WorldScale,
          eyeHeight: 12
        )
    for tower in world.towers:
      if tower.team == team and tower.hp > 0:
        let tile = sightTile(tower.position)
        visionSources.add VisionSource(
          x: tile.x,
          z: tile.z,
          radius: TowerAttackRanges[tower.tier] div WorldScale + 2,
          eyeHeight: 24
        )
    for fort in world.forts:
      if fort.team == team and fort.hp > 0:
        let tile = sightTile(fort.center)
        visionSources.add VisionSource(
          x: tile.x,
          z: tile.z,
          radius: FortOuterRadius + 2,
          eyeHeight: 28
        )
    revealVision(
      world.teamVisible[team.ord],
      GridTiles,
      GridTiles,
      sightTerrain.terrainHeights,
      visionBlockers,
      visionSources
    )
    for i, value in world.teamVisible[team.ord]:
      if value != 0:
        world.teamExplored[team.ord][i] = 255
  copyVisionKeys(visionSkipKeys, visionSkipNow)
  visionSkipWorld = cast[pointer](world)

proc visible*(world: World, team: Team, position: WorldPoint): bool =
  ## Returns whether a position is currently visible to one team.
  let tile = sightTile(position)
  tile.x >= 0 and tile.x < GridTiles and
    tile.z >= 0 and tile.z < GridTiles and
    world.teamVisible[team.ord].len == GridTiles * GridTiles and
    world.teamVisible[team.ord][tile.z * GridTiles + tile.x] != 0

proc enemyFort(team: Team): int =
  ## Returns the opposing fort index for a team.
  if team == RedTeam: 1 else: 0

proc footmanIndex(world: World, id: int32): int =
  ## Returns the footman slot for one id, or -1.
  if id == 0:
    return -1
  for i, footman in world.footmen:
    if footman.id == id:
      return i
  -1

proc heroIndex*(world: World, id: int32): int =
  ## Returns the hero slot for one id, or -1.
  if id == 0:
    return -1
  for i in 0 ..< world.heroes.len:
    if world.heroes[i].id == id:
      return i
  -1

proc towerIndex*(world: World, id: int32): int =
  ## Returns the tower slot for one id, or -1.
  if id == 0:
    return -1
  for i, tower in world.towers:
    if tower.id == id:
      return i
  -1

proc towerById*(world: World, id: int32): Tower =
  ## Reads one tower by its script-visible object ID.
  let index = towerIndex(world, id)
  if index >= 0:
    result = world.towers[index]

proc towerExposed*(world: World, tower: Tower): bool =
  ## Returns whether every earlier tower in this lane has been destroyed.
  if tower.id == 0 or tower.hp <= 0:
    return false
  for other in world.towers:
    if other.team == tower.team and other.lane == tower.lane and
        other.tier.ord < tower.tier.ord and other.hp > 0:
      return false
  true

proc nextEnemyTower(world: World, team: Team, lane: int): Tower =
  ## Returns the first standing tower in one enemy lane.
  let enemy = if team == RedTeam: BlueTeam else: RedTeam
  for tier in TowerTier:
    for tower in world.towers:
      if tower.team == enemy and tower.lane == lane and
          tower.tier == tier and tower.hp > 0:
        return tower

proc fortExposed*(world: World, team: Team): bool =
  ## Returns whether one complete lane into a team's fort has been cleared.
  for lane in 0 .. 2:
    var standing = false
    for tower in world.towers:
      if tower.team == team and tower.lane == lane and tower.hp > 0:
        standing = true
        break
    if not standing:
      return true
  false

proc xpForNextLevel*(level: int): int =
  ## Returns the XP needed to advance from the given hero level.
  100 + (level - 1) * 75

proc recordHeroKill(world: World, team: Team, victimTeam: Team) =
  ## Records one hero kill and the opposing hero's death.
  inc world.teamHeroKills[team.ord]
  inc world.teamHeroDeaths[victimTeam.ord]

proc heroItemBonus(hero: Hero): tuple[
    maxHp, maxMana, damage, movePerTick: int32
] =
  ## Sums passive bonuses from every item the hero is holding.
  for slot in 0 ..< InventorySlots:
    if hero.inventory[slot] == NoItem:
      continue
    let spec = hero.inventory[slot].itemSpec
    result.maxHp += spec.maxHp
    result.maxMana += spec.maxMana
    result.damage += spec.damage
    result.movePerTick += spec.movePerTick

proc refreshHeroStats*(hero: Hero) =
  ## Rebuilds current maximums from class, level, and held equipment.
  let
    previousMaxHp = hero.maxHp
    previousMaxMana = hero.maxMana
    bonus = hero.heroItemBonus()
  hero.maxHp = heroMaxHp(hero.class, hero.level) + bonus.maxHp
  hero.maxMana = heroMaxMana(hero.class, hero.level) + bonus.maxMana
  hero.hp += hero.maxHp - previousMaxHp
  hero.mana += hero.maxMana - previousMaxMana
  if hero.hp > hero.maxHp:
    hero.hp = hero.maxHp
  if hero.mana > hero.maxMana:
    hero.mana = hero.maxMana

proc heroAttackDamage*(hero: Hero): int32 =
  ## Returns basic-attack damage including held equipment.
  heroDamage(hero.class, hero.level) + hero.heroItemBonus().damage

proc heroMoveSpeed*(hero: Hero): int32 =
  ## Returns movement distance including held equipment.
  heroMovePerTick(hero.class, hero.level) +
    hero.heroItemBonus().movePerTick

proc gainRewards(hero: Hero, xp, gold: int) =
  ## Grants kill rewards and applies every level gained from the new XP.
  hero.xp += xp
  hero.totalXp += xp
  hero.gold += gold
  while hero.level < HeroMaxLevel and
      hero.xp >= xpForNextLevel(hero.level):
    hero.xp -= xpForNextLevel(hero.level)
    inc hero.level
    hero.refreshHeroStats()

proc layerFixedHeight(
    layerIndex: int,
    position: WorldPoint,
    height: var int32
): bool =
  ## Samples one packed tile surface using only fixed-point arithmetic.
  let
    layer = layers[layerIndex]
    worldTileX = floorWorldTile(position.x) + GridTiles div 2
    worldTileZ = floorWorldTile(position.z) + GridTiles div 2
    tileX = worldTileX - layer.originX
    tileZ = worldTileZ - layer.originZ
  if tileX < 0 or tileX >= layer.width or
      tileZ < 0 or tileZ >= layer.depth:
    return false
  let tile = layer.tiles[tileZ * layer.width + tileX]
  if not tile.exists:
    return false
  let
    floorX = int64(floorWorldTile(position.x)) * int64(WorldScale)
    floorZ = int64(floorWorldTile(position.z)) * int64(WorldScale)
    offsetX = int64(position.x) - floorX
    offsetZ = int64(position.z) - floorZ
    inverseX = int64(WorldScale) - offsetX
    inverseZ = int64(WorldScale) - offsetZ
    north = int64(tile.tops[0]) * inverseX +
      int64(tile.tops[1]) * offsetX
    south = int64(tile.tops[2]) * inverseX +
      int64(tile.tops[3]) * offsetX
    numerator = north * inverseZ + south * offsetZ
    denominator = int64(WorldScale) * 8
  height = int32(roundDivision(numerator, denominator))
  true

proc fixedSurfaceHeight(position: WorldPoint): int32 =
  ## Returns the highest packed solid surface at an integer world position.
  var found = false
  for layerIndex, layer in layers:
    if layer.water:
      continue
    var height: int32
    if layerFixedHeight(layerIndex, position, height) and
        (not found or height > result):
      result = height
      found = true

proc fixedSurfaceHeightNear(
    position: WorldPoint,
    referenceY: int32
): int32 =
  ## Returns the packed solid surface nearest an integer reference height.
  var
    found = false
    bestDistance = int64.high
  for layerIndex, layer in layers:
    if layer.water:
      continue
    var height: int32
    if layerFixedHeight(layerIndex, position, height):
      let distance = abs(int64(height) - int64(referenceY))
      if not found or distance < bestDistance or
          (distance == bestDistance and height > result):
        result = height
        bestDistance = distance
        found = true

proc onBridgeDeck(x, z: int32): bool =
  ## Returns whether an integer world position lies above a bridge tile.
  let
    tileX = floorWorldTile(x) + GridTiles div 2 -
      layers[BridgeLayer].originX
    tileZ = floorWorldTile(z) + GridTiles div 2 -
      layers[BridgeLayer].originZ
  tileX >= 0 and tileX < layers[BridgeLayer].width and
    tileZ >= 0 and tileZ < layers[BridgeLayer].depth and
    layers[BridgeLayer].tiles[tileZ * layers[BridgeLayer].width + tileX].exists

proc canStand(x, z: int32): bool =
  ## Keeps units out of deep water, forests, boulders, the fort
  ## footprints, and off the map edge. The bridge deck overrides the
  ## blocked riverbed below it.
  const
    Margin = 18_000'i32
    HalfGridUnits = GridTiles div 2 * WorldScale
  if x < -HalfGridUnits + Margin or x > HalfGridUnits - Margin or
      z < -HalfGridUnits + Margin or z > HalfGridUnits - Margin:
    return false
  if onBridgeDeck(x, z):
    return true
  let
    tileX = floorWorldTile(x) + GridTiles div 2 -
      layers[GroundLayer].originX
    tileZ = floorWorldTile(z) + GridTiles div 2 -
      layers[GroundLayer].originZ
  isWalkable(GroundLayer, tileX, tileZ)

proc navTileAt(position: WorldPoint, value: var NavTile): bool

proc walkWorldCell(pos: FixedVec2): tuple[x, z: int] =
  ## Converts a tile-space body into a world tile index.
  (
    int(floorWorldTile(tilesToWorld(pos.x, WorldScale))) + GridTiles div 2,
    int(floorWorldTile(tilesToWorld(pos.y, WorldScale))) + GridTiles div 2
  )

proc inWalkMargin(pos: FixedVec2): bool =
  ## Keeps units off the map rim.
  const
    Margin = 18_000'i32
    HalfGridUnits = GridTiles div 2 * WorldScale
  let
    x = tilesToWorld(pos.x, WorldScale)
    z = tilesToWorld(pos.y, WorldScale)
  x >= -HalfGridUnits + Margin and x <= HalfGridUnits - Margin and
    z >= -HalfGridUnits + Margin and z <= HalfGridUnits - Margin

proc tilesWalkable(pos: FixedVec2): bool =
  ## Current nav layer, plus the next waypoint layer while crossing a ramp.
  if not inWalkMargin(pos):
    return false
  let (x, z) = walkWorldCell(pos)
  worldLayersOpen(gotaWalkLayer, gotaWalkDestLayer, x, z)

proc bindNavLayer(position: WorldPoint): int32 =
  ## Picks the packed layer under a spawn or teleport.
  var tile: NavTile
  if navTileAt(position, tile):
    int32(tile.layer)
  else:
    int32(GroundLayer)

proc settleOnLayer(position: var WorldPoint, layer: int32) =
  ## Writes this layer's packed height onto a world point.
  var height: int32
  if layerFixedHeight(int(layer), position, height):
    position.y = height

proc finishMove(navLayer: var int32, pos: FixedVec2) =
  ## Keeps the unit on its layer until the current cell leaves it.
  let (x, z) = walkWorldCell(pos)
  navLayer = int32(worldPreferLayer(
    int(navLayer), gotaWalkDestLayer, x, z
  ))

proc toPlanar(point: WorldPoint): FixedVec2 =
  ## Reads the xz plane of a world point in tile-space.
  fixedVec2(
    worldToTiles(point.x, WorldScale),
    worldToTiles(point.z, WorldScale)
  )

proc bindBody(position: WorldPoint, facing: Heading, radius: Fixed): Body =
  ## Builds a body from an integer spawn pose.
  result.pos = toPlanar(position)
  result.radius = radius
  if facing.x != 0 or facing.z != 0:
    result.facing = angle(fixedVec2(
      worldToTiles(facing.x, WorldScale),
      worldToTiles(facing.z, WorldScale)
    ))

proc applyBody(position: var WorldPoint, facing: var Heading, body: Body) =
  ## Writes the body plane back onto the integer pose used by combat.
  position.x = tilesToWorld(body.pos.x, WorldScale)
  position.z = tilesToWorld(body.pos.y, WorldScale)
  let dir = direction(body.facing)
  facing = heading(
    tilesToWorld(dir.x, WorldScale),
    tilesToWorld(dir.y, WorldScale)
  )

proc applyBody(footman: var Footman) =
  ## Syncs one footman's integer pose from its body.
  applyBody(footman.position, footman.facing, footman.body)

proc applyBody(hero: Hero) =
  ## Syncs one hero's integer pose from its body.
  applyBody(hero.position, hero.facing, hero.body)

proc place*(footman: var Footman, at: WorldPoint) =
  ## Teleports a footman and keeps its body on the same plane.
  footman.position = at
  footman.body.pos = toPlanar(at)
  footman.navLayer = bindNavLayer(at)

proc place*(hero: Hero, at: WorldPoint) =
  ## Teleports a hero and keeps its body on the same plane.
  hero.position = at
  hero.body.pos = toPlanar(at)
  hero.navLayer = bindNavLayer(at)

proc snapFacing(body: var Body, facing: var Heading, offset: WorldPoint) =
  ## Turns toward a world-space offset the short way.
  if offset.x == 0 and offset.z == 0:
    return
  turnToward(
    body.facing,
    angle(toPlanar(offset)),
    FixedPi
  )
  let dir = direction(body.facing)
  facing = heading(
    tilesToWorld(dir.x, WorldScale),
    tilesToWorld(dir.y, WorldScale)
  )

proc tryMove(
    footman: var Footman,
    direction: WorldPoint,
    destLayer = -1'i32
) =
  ## Turns toward the offset, then walks along facing with wall-slide.
  gotaWalkLayer = int(footman.navLayer)
  gotaWalkDestLayer =
    if destLayer < 0: gotaWalkLayer else: int(destLayer)
  steer(
    footman.body,
    toPlanar(direction),
    worldToTiles(FootmanMovePerTick, WorldScale),
    BodyTurnRate,
    tilesWalkable
  )
  applyBody(footman)
  finishMove(footman.navLayer, footman.body.pos)
  settleOnLayer(footman.position, footman.navLayer)
  footman.surfaceHint = footman.position.y

proc tryMove(hero: Hero, direction: WorldPoint, destLayer = -1'i32) =
  ## Turns and walks a hero at its level-scaled tile-space speed.
  gotaWalkLayer = int(hero.navLayer)
  gotaWalkDestLayer =
    if destLayer < 0: gotaWalkLayer else: int(destLayer)
  steer(
    hero.body,
    toPlanar(direction),
    worldToTiles(hero.heroMoveSpeed, WorldScale),
    BodyTurnRate,
    tilesWalkable
  )
  applyBody(hero)
  finishMove(hero.navLayer, hero.body.pos)
  settleOnLayer(hero.position, hero.navLayer)
  hero.surfaceHint = hero.position.y

var laneWorldPaths: array[3, seq[WorldPoint]]

proc waypointAt(footman: Footman, index: int): WorldPoint =
  ## Reads one lane waypoint in the team's march order.
  if footman.team == RedTeam:
    laneWorldPaths[footman.lane][index]
  else:
    laneWorldPaths[footman.lane][
      laneWorldPaths[footman.lane].len - 1 - index
    ]

proc currentWaypoint(footman: Footman): WorldPoint =
  ## Red walks the lane forward, blue walks it backward.
  footman.waypointAt(footman.waypointIndex)

proc currentWaypointLayer(footman: Footman): int32 =
  ## Layer of the waypoint this footman is walking toward.
  let route = laneWorldLayers[footman.lane]
  if route.len == 0:
    return footman.navLayer
  let index =
    if footman.team == RedTeam:
      footman.waypointIndex
    else:
      route.len - 1 - footman.waypointIndex
  if index < 0 or index >= route.len:
    footman.navLayer
  else:
    route[index]

proc liveHeroSetup(total: int): seq[ReplayHero] =
  ## Assigns the ten live bot slots evenly across both teams.
  let redCount = (total + 1) div 2
  for i in 0 ..< total:
    let
      team =
        if i < redCount: RedTeam
        else: BlueTeam
      slot =
        if team == RedTeam: i
        else: i - redCount
      lane = HeroLanes[slot mod HeroLanes.len]
    result.add ReplayHero(
      id: FirstHeroId + int32(i),
      team: uint8(team.ord),
      slot: uint8(slot),
      lane: uint8(lane),
      class: uint8(heroClassForTeam(team.ord, slot).ord)
    )

proc spawnHeroes(world: World, setup: openArray[ReplayHero]) =
  ## Creates the persistent heroes described by a live or replay setup.
  const SlotOffsets = [
    -48_000'i32,
    48_000'i32,
    0'i32,
    -48_000'i32,
    48_000'i32
  ]
  for heroSetup in setup:
    let
      team = Team(heroSetup.team)
      slot = int(heroSetup.slot)
      lane = int(heroSetup.lane)
      class = HeroClass(heroSetup.class)
      path = lanePathPoints[lane]
      start = world.barracksSpawns[team.ord][lane]
      inner =
        if team == RedTeam:
          worldPoint(path[min(3, path.len - 1)])
        else:
          worldPoint(path[max(path.len - 4, 0)])
      direction = inner - start
      side = WorldPoint(x: -direction.z, z: direction.x)
      group = slot div HeroLanes.len
    var fixedPosition = start +
      scaledPlanar(side, SlotOffsets[slot mod SlotOffsets.len]) +
      scaledPlanar(direction, int32(group * 75_000))
    if not canStand(fixedPosition.x, fixedPosition.z):
      fixedPosition = start
    fixedPosition.y = fixedSurfaceHeight(fixedPosition)
    let
      maxHp = heroMaxHp(class, 1)
      maxMana = heroMaxMana(class, 1)
    world.heroes.add Hero(
      id: heroSetup.id,
      team: team,
      slot: slot,
      lane: lane,
      class: class,
      position: fixedPosition,
      spawnPosition: fixedPosition,
      facing: heading(direction.x, direction.z),
      body: bindBody(
        fixedPosition,
        heading(direction.x, direction.z),
        HeroBodyRadius
      ),
      hp: maxHp,
      maxHp: maxHp,
      mana: maxMana,
      maxMana: maxMana,
      level: 1,
      gold: 150,
      state: Marching,
      swingTicks: -1,
      animClip: heroRunClip,
      surfaceHint: fixedPosition.y,
      navLayer: bindNavLayer(fixedPosition)
    )

proc seededHeroTurnStart(world: World): int =
  ## Chooses the first VM from the order stream.
  int(world.rng.below(int32(world.heroes.len)))

proc currentSetup*(game: Game, maximumTicks: uint32): Setup =
  ## Captures the deterministic arena setup without any bot implementation.
  result = Setup(
    mapSeed: game.map.seed,
    mapHash: game.map.hash,
    tickRate: uint16(TickRate),
    gridTiles: uint16(GridTiles),
    spawnIntervalTicks: uint32(game.world.spawnIntervalTicks),
    maximumTicks: maximumTicks
  )
  for hero in game.world.heroes:
    result.heroes.add ReplayHero(
      id: hero.id,
      team: uint8(hero.team.ord),
      slot: uint8(hero.slot),
      lane: uint8(hero.lane),
      class: uint8(hero.class.ord)
    )

proc validateReplayWorld(game: Game) =
  ## Confirms that the replay setup matches this game simulation build.
  let
    actual = game.replayData.header.setup
    expected = currentSetup(game, actual.maximumTicks)
  if actual != expected:
    raise newException(
      ReplayError,
      "the replay setup does not match this Gods of the Arena build"
    )

proc spawnWave(world: World) {.measure.} =
  ## Spawns two footmen per lane for both teams when the cap permits it.
  const WaveSize = 12
  if world.footmen.len + WaveSize > UnitCap:
    return
  for team in [RedTeam, BlueTeam]:
    for lane in 0 .. 2:
      let start = world.barracksSpawns[team.ord][lane]
      for i in 0 .. 1:
        let
          id = world.nextFootmanId
          placed = start + WorldPoint(
            x: world.rng.below(72_001) - 36_000,
            z: world.rng.below(72_001) - 36_000
          )
        inc world.nextFootmanId
        world.footmen.add Footman(
          id: id,
          team: team,
          lane: lane,
          position: placed,
          body: bindBody(placed, Heading(), FootmanBodyRadius),
          hp: FootmanHp,
          state: Marching,
          animClip: runClip,
          animTicks: world.rng.below(TickRate),
          surfaceHint: start.y,
          navLayer: bindNavLayer(placed)
        )

proc mapCoordinate*(value: int32): int32 =
  ## Converts one world coordinate to a clamped script map coordinate.
  int32(clamp(
    floorWorldTile(value) + GridTiles div 2,
    0,
    GridTiles - 1
  ))

proc rawWorldObjectCount(world: World): int =
  ## Returns the total number of stable script-addressable objects.
  world.forts.len + world.towers.len + world.heroes.len + world.footmen.len

proc rawWorldObjectAt(world: World, index: int, value: var WorldObject): bool =
  ## Reads one object from the complete stable world enumeration.
  if index < 0:
    return false
  if index < world.forts.len:
    let fort = world.forts[index]
    value = WorldObject(
      id: fort.id,
      kind: FortObjectKind,
      class: -1,
      team: fort.team,
      position: fort.center,
      hp: fort.hp,
      maxHp: FortHp,
      alive: fort.hp > 0 and fortExposed(world, fort.team)
    )
    return true
  let towerIndex = index - world.forts.len
  if towerIndex < world.towers.len:
    let tower = world.towers[towerIndex]
    value = WorldObject(
      id: tower.id,
      kind: TowerObjectKind,
      class: -1,
      team: tower.team,
      position: tower.position,
      hp: tower.hp,
      maxHp: tower.maxHp,
      alive: towerExposed(world, tower)
    )
    return true
  let heroIndex = towerIndex - world.towers.len
  if heroIndex < world.heroes.len:
    let hero = world.heroes[heroIndex]
    value = WorldObject(
      id: hero.id,
      kind: HeroObjectKind,
      class: int32(hero.class.ord),
      team: hero.team,
      position: hero.position,
      hp: hero.hp,
      maxHp: hero.maxHp,
      alive: hero.state != Dying and hero.hp > 0
    )
    return true
  let footmanIndex = heroIndex - world.heroes.len
  if footmanIndex < world.footmen.len:
    let footman = world.footmen[footmanIndex]
    value = WorldObject(
      id: footman.id,
      kind: FootmanObjectKind,
      class: -1,
      team: footman.team,
      position: footman.position,
      hp: footman.hp,
      maxHp: FootmanHp,
      alive: footman.state != Dying and footman.hp > 0
    )
    return true
  false

proc objectVisibleTo(world: World, team: Team, value: WorldObject): bool =
  ## Returns whether one object is visible to a querying hero's team.
  value.team == team or visible(world, team, value.position)

proc ensureScriptObjects(world: World, heroId: int32) =
  ## Rebuilds the visible object list once per hero decision tick.
  if world.scriptObjectsHeroId == heroId and
      world.scriptObjectsTick == world.tick:
    return
  world.scriptObjectCount = 0
  let observer = heroIndex(world, heroId)
  if observer >= 0:
    let team = world.heroes[observer].team
    var value: WorldObject
    for i in 0 ..< rawWorldObjectCount(world):
      if not rawWorldObjectAt(world, i, value) or
          not objectVisibleTo(world, team, value):
        continue
      if world.scriptObjectCount == world.scriptObjects.len:
        world.scriptObjects.add value
      else:
        world.scriptObjects[world.scriptObjectCount] = value
      inc world.scriptObjectCount
  world.scriptObjectsHeroId = heroId
  world.scriptObjectsTick = world.tick

proc worldObjectCount*(world: World, heroId: int32): int =
  ## Returns the number of objects visible to one hero script.
  world.ensureScriptObjects(heroId)
  world.scriptObjectCount

proc worldObjectAt*(
    world: World,
    heroId: int32,
    index: int,
    value: var WorldObject
): bool =
  ## Reads one object from a hero's stable visibility-filtered enumeration.
  world.ensureScriptObjects(heroId)
  if index < 0 or index >= world.scriptObjectCount:
    return false
  value = world.scriptObjects[index]
  true

proc worldObjectById(
    world: World,
    heroId,
    id: int32,
    value: var WorldObject
): bool =
  ## Finds one object currently visible to a hero by stable object ID.
  world.ensureScriptObjects(heroId)
  for i in 0 ..< world.scriptObjectCount:
    if world.scriptObjects[i].id == id:
      value = world.scriptObjects[i]
      return true
  false

proc heroById*(world: World, id: int32): Hero =
  ## Reads one hero by its script-visible object ID.
  let index = heroIndex(world, id)
  if index >= 0:
    result = world.heroes[index]
  else:
    result = Hero()

proc footmanById*(world: World, id: int32): Footman =
  ## Reads one footman by its script-visible object ID.
  let index = footmanIndex(world, id)
  if index >= 0:
    result = world.footmen[index]

proc navTileAt(position: WorldPoint, value: var NavTile): bool =
  ## Finds the walkable layer tile closest to a world-space position.
  let
    worldX = floorWorldTile(position.x) + GridTiles div 2
    worldZ = floorWorldTile(position.z) + GridTiles div 2
  var bestHeight = int64.high
  for layerIndex, layer in layers:
    if layer.water:
      continue
    let
      x = worldX - layer.originX
      z = worldZ - layer.originZ
    if not isWalkable(layerIndex, x, z):
      continue
    let height = abs(
      int64(worldPoint(pathPoint(layerIndex, x, z)).y) -
      int64(position.y)
    )
    if not result or height < bestHeight:
      value = NavTile(layer: layerIndex, x: x, z: z)
      bestHeight = height
      result = true

proc nearestNavTile(
    mapX,
    mapY: int,
    referenceY: int32,
    value: var NavTile
): bool =
  ## Finds the closest walkable tile to a script map coordinate.
  var bestScore = int64.high
  for dz in -8 .. 8:
    for dx in -8 .. 8:
      let
        worldX = mapX + dx
        worldZ = mapY + dz
      if worldX < 0 or worldX >= GridTiles or
          worldZ < 0 or worldZ >= GridTiles:
        continue
      for layerIndex, layer in layers:
        if layer.water:
          continue
        let
          x = worldX - layer.originX
          z = worldZ - layer.originZ
        if not isWalkable(layerIndex, x, z):
          continue
        let
          centerY = worldPoint(pathPoint(layerIndex, x, z)).y
          planar = int64(dx * dx + dz * dz)
          score = planar * int64(WorldScale) * 100 +
            abs(int64(centerY) - int64(referenceY))
        if score < bestScore:
          value = NavTile(layer: layerIndex, x: x, z: z)
          bestScore = score
          result = true

proc setHeroDestination(
    hero: Hero,
    mapX,
    mapY: int,
    referenceY: int32
): bool =
  ## Computes and stores a server-side path for one hero destination.
  let
    targetX = clamp(mapX, 0, GridTiles - 1)
    targetY = clamp(mapY, 0, GridTiles - 1)
  if hero.hasMoveTarget and hero.moveTileX == targetX and
      hero.moveTileY == targetY and hero.movePathIndex < hero.movePath.len:
    return true
  var
    startTile: NavTile
    finishTile: NavTile
  if not navTileAt(hero.position, startTile) or
      not nearestNavTile(targetX, targetY, referenceY, finishTile):
    return false
  discard fillTilePath(PathQuery(
    startLayer: startTile.layer,
    startX: startTile.x,
    startZ: startTile.z,
    finishLayer: finishTile.layer,
    finishX: finishTile.x,
    finishZ: finishTile.z
  ), heroPathTiles)
  if heroPathTiles.len == 0:
    return false
  let pulled = smoothPathTiles(heroPathTiles)
  hero.movePath.setLen(pulled.len)
  hero.movePathLayers.setLen(pulled.len)
  for i, tile in pulled:
    hero.movePath[i] = worldPoint(pathPoint(
      int(tile.layer),
      int(tile.x),
      int(tile.z)
    ))
    hero.movePathLayers[i] = tile.layer
  hero.movePathIndex = 0
  hero.moveTileX = targetX
  hero.moveTileY = targetY
  hero.hasMoveTarget = true
  true

proc followHeroPath(hero: Hero): bool =
  ## Advances a hero along its current server-generated path.
  while hero.movePathIndex < hero.movePath.len:
    let waypoint = hero.movePath[hero.movePathIndex]
    let offset = WorldPoint(
      x: waypoint.x - hero.position.x,
      z: waypoint.z - hero.position.z
    )
    if not within(hero.position, waypoint, 21_000):
      let destLayer =
        if hero.movePathIndex < hero.movePathLayers.len:
          hero.movePathLayers[hero.movePathIndex]
        else:
          hero.navLayer
      hero.tryMove(offset, destLayer)
      return true
    inc hero.movePathIndex
  hero.hasMoveTarget = false
  false

proc applyWalkTo*(world: World, heroId, mapX, mapY: int32): bool =
  ## Applies one hero walk command using server-side pathfinding.
  let index = heroIndex(world, heroId)
  if index < 0 or world.heroes[index].state == Dying:
    return false
  world.heroes[index].attackObjectId = 0
  world.heroes[index].targetFootmanId = 0
  world.heroes[index].targetHeroId = 0
  world.heroes[index].targetTowerId = 0
  world.heroes[index].attackingFort = false
  setHeroDestination(
    world.heroes[index],
    int(mapX),
    int(mapY),
    world.heroes[index].position.y
  )

proc applyAttackTarget*(world: World, heroId, targetId: int32): bool =
  ## Applies one hero attack command after validating its target.
  let index = heroIndex(world, heroId)
  if index < 0 or world.heroes[index].state == Dying:
    return false
  if targetId == 0:
    world.heroes[index].attackObjectId = 0
    return true
  var value: WorldObject
  if not worldObjectById(world, heroId, targetId, value) or not value.alive or
      value.team == world.heroes[index].team:
    return false
  if world.heroes[index].attackObjectId != targetId:
    world.heroes[index].hasMoveTarget = false
  world.heroes[index].attackObjectId = targetId
  true

proc applyBuyItem*(world: World, heroId, itemId: int32): bool =
  ## Spends gold to put one shop item into a hero inventory.
  let index = heroIndex(world, heroId)
  if index < 0 or world.heroes[index].state == Dying:
    return false
  let item = itemFromId(itemId)
  if item == NoItem:
    return false
  let spec = item.itemSpec
  if world.heroes[index].gold < spec.cost:
    return false
  var
    stackSlot = -1
    emptySlot = -1
  for slot in 0 ..< InventorySlots:
    if world.heroes[index].inventory[slot] == item:
      stackSlot = slot
    elif world.heroes[index].inventory[slot] == NoItem and
        emptySlot < 0:
      emptySlot = slot
  if spec.kind == Consumable and stackSlot >= 0:
    if world.heroes[index].itemCounts[stackSlot] >= MaxItemStack:
      return false
    inc world.heroes[index].itemCounts[stackSlot]
  elif spec.kind == Equipment and stackSlot >= 0:
    return false
  elif emptySlot >= 0:
    world.heroes[index].inventory[emptySlot] = item
    world.heroes[index].itemCounts[emptySlot] = 1
  else:
    return false
  world.heroes[index].gold -= spec.cost
  world.heroes[index].refreshHeroStats()
  true

proc footmanAttackTicks(clip: int): int32 =
  ## Returns the deterministic footman attack duration in ticks.
  discard clip
  32

proc startSwing(world: World, footman: var Footman) =
  ## Begins a randomly selected melee animation and damage cycle.
  footman.swingClip = attackClips[world.rng.below(2)]
  footman.swingTicks = 0
  footman.damageLanded = false

proc startSwing(world: World, hero: Hero) =
  ## Begins a randomly selected hero melee animation and damage cycle.
  hero.swingClip = heroAttackClips[world.rng.below(2)]
  hero.swingTicks = 0
  hero.damageLanded = false

proc updateTower*(world: World, tower: var Tower) =
  ## Acquires one nearby enemy and applies a deterministic periodic attack.
  if tower.hp <= 0:
    tower.targetId = 0
    tower.attackTicks = 0
    return
  let attackRange = TowerAttackRanges[tower.tier]
  var
    targetFootman = footmanIndex(world, tower.targetId)
    targetHero = heroIndex(world, tower.targetId)
  if targetFootman >= 0:
    let footman = world.footmen[targetFootman]
    if footman.team == tower.team or
        footman.state == Dying or footman.hp <= 0 or
        not within(tower.position, footman.position, attackRange) or
        not visible(world, tower.team, footman.position):
      targetFootman = -1
  if targetHero >= 0:
    let hero = world.heroes[targetHero]
    if hero.team == tower.team or hero.state == Dying or
        hero.hp <= 0 or
        not within(tower.position, hero.position, attackRange) or
        not visible(world, tower.team, hero.position):
      targetHero = -1
  if targetFootman < 0 and targetHero < 0:
    var
      bestSquared = int64(attackRange) * attackRange
      bestId = int32.high
    for i, footman in world.footmen:
      if footman.team == tower.team or footman.state == Dying or
          footman.hp <= 0 or
          not visible(world, tower.team, footman.position):
        continue
      let distance = distanceSquared(tower.position, footman.position)
      if distance < bestSquared or
          (distance == bestSquared and footman.id < bestId):
        bestSquared = distance
        bestId = footman.id
        targetFootman = i
    if targetFootman < 0:
      bestSquared = int64(attackRange) * attackRange
      bestId = int32.high
      for i in 0 ..< world.heroes.len:
        let hero = world.heroes[i]
        if hero.team == tower.team or hero.state == Dying or hero.hp <= 0:
          continue
        if not visible(world, tower.team, hero.position):
          continue
        let distance = distanceSquared(tower.position, hero.position)
        if distance < bestSquared or
            (distance == bestSquared and hero.id < bestId):
          bestSquared = distance
          bestId = hero.id
          targetHero = i
  let targetId =
    if targetFootman >= 0: world.footmen[targetFootman].id
    elif targetHero >= 0: world.heroes[targetHero].id
    else: 0'i32
  if tower.targetId != targetId:
    tower.targetId = targetId
    tower.attackTicks = 0
  if targetId == 0:
    return
  inc tower.attackTicks
  if tower.attackTicks < TowerAttackTicks:
    return
  tower.attackTicks -= TowerAttackTicks
  let damage = TowerDamages[tower.tier]
  if targetFootman >= 0:
    world.footmen[targetFootman].hp -= damage
  else:
    let wasAlive = world.heroes[targetHero].hp > 0
    world.heroes[targetHero].hp -= damage
    if wasAlive and world.heroes[targetHero].hp <= 0:
      recordHeroKill(world, tower.team, world.heroes[targetHero].team)

proc updateFootman(world: World, footman: var Footman) =
  ## Advances one footman's movement, target selection, combat, and animation.
  if footman.state == Dying:
    inc footman.deathTicks
    footman.animClip = deathClip
    footman.animTicks = min(footman.deathTicks, FootmanDeathTicks)
    return

  if footman.hp <= 0:
    footman.state = Dying
    footman.deathTicks = 0
    return

  # Acquire: keep a live target while it stays in extended range, otherwise
  # take the nearest visible enemy; with none, batter the fort when close.
  var
    targetFootman = footmanIndex(world, footman.targetId)
    targetHero = heroIndex(world, footman.targetHeroId)
    targetTower = towerIndex(world, footman.targetTowerId)
  if targetFootman >= 0:
    let other = world.footmen[targetFootman]
    if other.state == Dying or other.hp <= 0 or
        not visible(world, footman.team, other.position) or
        not within(
          footman.position,
          other.position,
          FootmanSightRadius * 8 div 5
        ):
      targetFootman = -1
  if targetHero >= 0:
    let hero = world.heroes[targetHero]
    if hero.state == Dying or hero.hp <= 0 or
        not visible(world, footman.team, hero.position) or
        not within(
          footman.position,
          hero.position,
          FootmanSightRadius * 8 div 5
        ):
      targetHero = -1
  if targetTower >= 0:
    let tower = world.towers[targetTower]
    if not towerExposed(world, tower) or
        not visible(world, footman.team, tower.position) or
        not within(
          footman.position,
          tower.position,
          FootmanTowerSightRadius * 8 div 5
        ):
      targetTower = -1
  if targetFootman < 0 and targetHero < 0 and targetTower < 0:
    var bestSquared = int64(FootmanSightRadius) * FootmanSightRadius
    for i, other in world.footmen:
      if other.team == footman.team or other.state == Dying or other.hp <= 0:
        continue
      if not visible(world, footman.team, other.position):
        continue
      let distance = distanceSquared(footman.position, other.position)
      if distance < bestSquared:
        bestSquared = distance
        targetFootman = i
    for i in 0 ..< world.heroes.len:
      let hero = world.heroes[i]
      if hero.team == footman.team or hero.state == Dying or hero.hp <= 0:
        continue
      if not visible(world, footman.team, hero.position):
        continue
      let distance = distanceSquared(footman.position, hero.position)
      if distance < bestSquared:
        bestSquared = distance
        targetFootman = -1
        targetHero = i
  if targetFootman < 0 and targetHero < 0 and targetTower < 0:
    let tower = nextEnemyTower(world, footman.team, footman.lane)
    if tower.id != 0 and within(
        footman.position,
        tower.position,
        FootmanTowerSightRadius
    ) and visible(world, footman.team, tower.position):
      targetTower = towerIndex(world, tower.id)
  footman.targetId =
    if targetFootman >= 0: world.footmen[targetFootman].id else: 0
  footman.targetHeroId =
    if targetHero >= 0: world.heroes[targetHero].id else: 0
  footman.targetTowerId =
    if targetTower >= 0: world.towers[targetTower].id else: 0
  let fortIndex = enemyFort(footman.team)
  footman.attackingFort = targetFootman < 0 and targetHero < 0 and
    targetTower < 0 and
    fortExposed(world, world.forts[fortIndex].team) and
    visible(world, footman.team, world.forts[fortIndex].center) and
    within(footman.position, world.forts[fortIndex].center, FortRange)

  if targetFootman >= 0 or targetHero >= 0 or
      targetTower >= 0 or footman.attackingFort:
    footman.state = Fighting
    let targetPosition =
      if targetFootman >= 0: world.footmen[targetFootman].position
      elif targetHero >= 0: world.heroes[targetHero].position
      elif targetTower >= 0: world.towers[targetTower].position
      else: world.forts[fortIndex].center
    footman.surfaceHint = targetPosition.y
    let
      offset = targetPosition - footman.position
      # Fort walls sit well inside FortRange: close enough already counts
      # as being at arm's length of the enemy god's walls.
      inRange =
        if targetFootman >= 0 or targetHero >= 0:
          within(footman.position, targetPosition, FootmanMeleeRange)
        elif targetTower >= 0:
          within(footman.position, targetPosition, TowerSiegeRange)
        else: true
    if not inRange:
      footman.swingTicks = -1
      footman.animClip = runClip
      inc footman.animTicks
      footman.tryMove(offset)
    else:
      snapFacing(footman.body, footman.facing, offset)
      if footman.swingTicks < 0:
        startSwing(world, footman)
      let duration = footmanAttackTicks(footman.swingClip)
      inc footman.swingTicks
      if not footman.damageLanded and
          footman.swingTicks >= duration * 45 div 100:
        footman.damageLanded = true
        if targetFootman >= 0:
          world.footmen[targetFootman].hp -= FootmanDamage
        elif targetHero >= 0:
          let wasAlive = world.heroes[targetHero].hp > 0
          world.heroes[targetHero].hp -= FootmanDamage
          if wasAlive and world.heroes[targetHero].hp <= 0:
            recordHeroKill(world, footman.team, world.heroes[targetHero].team)
        elif targetTower >= 0:
          world.towers[targetTower].hp -= FootmanDamage
        else:
          world.forts[fortIndex].hp -= FootmanDamage
      if footman.swingTicks >= duration:
        startSwing(world, footman)
      footman.animClip = footman.swingClip
      footman.animTicks = max(footman.swingTicks, 0)
    return

  # March down the lane.
  footman.state = Marching
  footman.swingTicks = -1
  footman.animClip = runClip
  inc footman.animTicks
  if footman.waypointIndex < laneWorldPaths[footman.lane].len:
    let
      waypoint = footman.currentWaypoint
      offset = waypoint - footman.position
    if within(footman.position, waypoint, 21_000):
      inc footman.waypointIndex
    else:
      footman.tryMove(offset, footman.currentWaypointLayer)
  else:
    let fort = world.forts[enemyFort(footman.team)]
    footman.tryMove(fort.center - footman.position)

proc respawn(hero: Hero) =
  ## Restores a fallen hero at its original barracks spawn.
  hero.place(hero.spawnPosition)
  hero.hp = hero.maxHp
  hero.mana = hero.maxMana
  hero.state = Marching
  hero.waypointIndex = 0
  hero.targetFootmanId = 0
  hero.targetHeroId = 0
  hero.targetTowerId = 0
  hero.attackingFort = false
  hero.attackObjectId = 0
  hero.hasMoveTarget = false
  hero.movePath.setLen(0)
  hero.movePathIndex = 0
  hero.swingTicks = -1
  hero.animClip = heroRunClip
  hero.animTicks = 0
  hero.deathTicks = 0
  hero.surfaceHint = hero.spawnPosition.y
  hero.navLayer = bindNavLayer(hero.spawnPosition)
  for slot in HeroAbilitySlot:
    hero.cooldowns[slot] = 0

proc tickHeroCooldowns(hero: Hero) =
  ## Counts down every ability slot that is waiting to be used again.
  for slot in HeroAbilitySlot:
    if hero.cooldowns[slot] > 0:
      dec hero.cooldowns[slot]

proc regenHeroMana(hero: Hero, tick: int32) =
  ## Restores a small amount of mana on a stable cadence.
  if tick mod 6 == 0 and hero.mana < hero.maxMana:
    inc hero.mana

proc applyHeroHit(
    world: World,
    hero: Hero,
    damage: int32,
    targetFootman, targetHero, targetTower, fortIndex: int
) =
  ## Applies one hero hit to the current combat target.
  if damage <= 0:
    return
  if targetFootman >= 0:
    let wasAlive = world.footmen[targetFootman].hp > 0
    world.footmen[targetFootman].hp -= damage
    if wasAlive and world.footmen[targetFootman].hp <= 0:
      hero.gainRewards(FootmanXpReward, FootmanGoldReward)
  elif targetHero >= 0:
    let wasAlive = world.heroes[targetHero].hp > 0
    world.heroes[targetHero].hp -= damage
    if wasAlive and world.heroes[targetHero].hp <= 0:
      hero.gainRewards(HeroXpReward, HeroGoldReward)
      recordHeroKill(world, hero.team, world.heroes[targetHero].team)
  elif targetTower >= 0:
    let wasStanding = world.towers[targetTower].hp > 0
    world.towers[targetTower].hp -= damage
    if wasStanding and world.towers[targetTower].hp <= 0:
      hero.gainRewards(TowerXpReward, TowerGoldReward)
  elif fortIndex >= 0:
    world.forts[fortIndex].hp -= damage

proc consumeItem(hero: Hero, slot: int) =
  ## Removes one charge from an inventory slot and clears an empty stack.
  dec hero.itemCounts[slot]
  if hero.itemCounts[slot] <= 0:
    hero.inventory[slot] = NoItem
    hero.itemCounts[slot] = 0

proc applyUseItem*(world: World, heroId, slotId: int32): bool =
  ## Spends one consumable for a heal, mana restore, or poison strike.
  let
    index = heroIndex(world, heroId)
    slot = int(slotId)
  if index < 0 or world.heroes[index].state == Dying:
    return false
  if slot < 0 or slot >= InventorySlots:
    return false
  let item = world.heroes[index].inventory[slot]
  if item == NoItem:
    return false
  let spec = item.itemSpec
  if spec.kind != Consumable:
    return false
  if spec.heal > 0:
    if world.heroes[index].hp >= world.heroes[index].maxHp:
      return false
    world.heroes[index].hp = min(
      world.heroes[index].maxHp,
      world.heroes[index].hp + spec.heal
    )
  elif spec.restore > 0:
    if world.heroes[index].mana >= world.heroes[index].maxMana:
      return false
    world.heroes[index].mana = min(
      world.heroes[index].maxMana,
      world.heroes[index].mana + spec.restore
    )
  elif spec.strike > 0:
    let targetId = world.heroes[index].attackObjectId
    if targetId == 0:
      return false
    var
      targetFootman = footmanIndex(world, targetId)
      targetHero = heroIndex(world, targetId)
      targetTower = towerIndex(world, targetId)
      fortIndex = -1
    if targetFootman < 0 and targetHero < 0 and targetTower < 0:
      for i, fort in world.forts:
        if fort.id == targetId:
          fortIndex = i
          break
    if targetFootman < 0 and targetHero < 0 and
        targetTower < 0 and fortIndex < 0:
      return false
    applyHeroHit(
      world,
      world.heroes[index],
      spec.strike,
      targetFootman,
      targetHero,
      targetTower,
      fortIndex
    )
  else:
    return false
  world.heroes[index].consumeItem(slot)
  true

proc applyReplayAction(world: World, action: ReplayAction) =
  ## Applies one recorded bot command without requiring its private VM.
  case action.kind
  of ActionWalkTo:
    discard applyWalkTo(world, action.heroId, action.first, action.second)
  of ActionAttackTarget:
    discard applyAttackTarget(world, action.heroId, action.first)
  of ActionBuyItem:
    discard applyBuyItem(world, action.heroId, action.first)
  of ActionUseItem:
    discard applyUseItem(world, action.heroId, action.first)
  else:
    raise newException(ReplayError, "replay action kind is invalid")

proc tryCastAbility(
    world: World,
    hero: Hero,
    slot: HeroAbilitySlot,
    targetFootman, targetHero, targetTower, fortIndex: int
): bool =
  ## Spends one ready ability if its cost, range, and target match.
  let spec = heroAbility(hero.class, slot).abilitySpec
  if hero.cooldowns[slot] > 0:
    return false
  if hero.mana < spec.manaCost:
    return false
  let hasTarget =
    targetFootman >= 0 or targetHero >= 0 or
    targetTower >= 0 or fortIndex >= 0
  var targetPosition = hero.position
  if hasTarget:
    targetPosition =
      if targetFootman >= 0: world.footmen[targetFootman].position
      elif targetHero >= 0: world.heroes[targetHero].position
      elif targetTower >= 0: world.towers[targetTower].position
      else: world.forts[fortIndex].center
  case spec.kind
  of Strike:
    if not hasTarget:
      return false
    if not within(hero.position, targetPosition, spec.range):
      return false
  of Heal:
    if hero.hp >= hero.maxHp:
      return false
  of Restore:
    if hero.mana >= hero.maxMana:
      return false
  hero.mana -= spec.manaCost
  hero.cooldowns[slot] = spec.cooldownTicks
  case spec.kind
  of Strike:
    applyHeroHit(
      world,
      hero,
      spec.damage,
      targetFootman,
      targetHero,
      targetTower,
      fortIndex
    )
    if spec.heal > 0:
      hero.hp = min(hero.maxHp, hero.hp + spec.heal)
    if spec.restore > 0:
      hero.mana = min(hero.maxMana, hero.mana + spec.restore)
  of Heal:
    hero.hp = min(hero.maxHp, hero.hp + spec.heal)
  of Restore:
    hero.mana = min(hero.maxMana, hero.mana + spec.restore)
  true

proc tryCombatAbilities(
    world: World,
    hero: Hero,
    targetFootman, targetHero, targetTower, fortIndex: int
) =
  ## Fires the strongest ready combat ability, then the class passive.
  discard tryCastAbility(
    world,
    hero,
    PassiveAbility,
    targetFootman,
    targetHero,
    targetTower,
    fortIndex
  )
  if targetFootman < 0 and targetHero < 0 and
      targetTower < 0 and fortIndex < 0:
    return
  if tryCastAbility(
      world,
      hero,
      UltimateAbility,
      targetFootman,
      targetHero,
      targetTower,
      fortIndex
    ):
    return
  if tryCastAbility(
      world,
      hero,
      SecondaryAbility,
      targetFootman,
      targetHero,
      targetTower,
      fortIndex
    ):
    return
  discard tryCastAbility(
    world,
    hero,
    PrimaryAbility,
    targetFootman,
    targetHero,
    targetTower,
    fortIndex
  )

proc updateHero(world: World, hero: Hero) =
  ## Applies scripted navigation, combat, rewards, death, and respawn.
  if hero.state == Dying:
    inc hero.deathTicks
    hero.animClip = heroDeathClip
    hero.animTicks = min(hero.deathTicks, HeroDeathTicks)
    if hero.deathTicks >= HeroDeathTicks + HeroRespawnTicks:
      hero.respawn()
    return

  if hero.hp <= 0:
    hero.state = Dying
    hero.deathTicks = 0
    hero.targetFootmanId = 0
    hero.targetHeroId = 0
    hero.targetTowerId = 0
    hero.attackingFort = false
    hero.attackObjectId = 0
    hero.hasMoveTarget = false
    return

  hero.targetFootmanId = 0
  hero.targetHeroId = 0
  hero.targetTowerId = 0
  hero.attackingFort = false
  var
    targetFootman = -1
    targetHero = -1
    targetTower = -1
    fortIndex = -1
  if hero.attackObjectId != 0:
    targetFootman = footmanIndex(world, hero.attackObjectId)
    if targetFootman >= 0:
      let footman = world.footmen[targetFootman]
      if footman.team == hero.team or footman.state == Dying or
          footman.hp <= 0 or not visible(world, hero.team, footman.position):
        targetFootman = -1
    if targetFootman < 0:
      targetHero = heroIndex(world, hero.attackObjectId)
      if targetHero >= 0:
        let other = world.heroes[targetHero]
        if other.team == hero.team or other.state == Dying or
            other.hp <= 0 or not visible(world, hero.team, other.position):
          targetHero = -1
    if targetFootman < 0 and targetHero < 0:
      targetTower = towerIndex(world, hero.attackObjectId)
      if targetTower >= 0:
        let tower = world.towers[targetTower]
        if tower.team == hero.team or not towerExposed(world, tower) or
            not visible(world, hero.team, tower.position):
          targetTower = -1
    if targetFootman < 0 and targetHero < 0 and targetTower < 0:
      for i, fort in world.forts:
        if fort.id == hero.attackObjectId and fort.team != hero.team and
            fort.hp > 0 and fortExposed(world, fort.team):
          if not visible(world, hero.team, fort.center):
            continue
          fortIndex = i
          hero.attackingFort = true
          break
    if targetFootman < 0 and targetHero < 0 and targetTower < 0 and
        not hero.attackingFort:
      hero.attackObjectId = 0
  hero.targetFootmanId =
    if targetFootman >= 0: world.footmen[targetFootman].id else: 0
  hero.targetHeroId =
    if targetHero >= 0: world.heroes[targetHero].id else: 0
  hero.targetTowerId =
    if targetTower >= 0: world.towers[targetTower].id else: 0

  tickHeroCooldowns(hero)
  regenHeroMana(hero, world.tick)
  tryCombatAbilities(
    world,
    hero,
    targetFootman,
    targetHero,
    targetTower,
    fortIndex
  )

  if targetFootman >= 0 or targetHero >= 0 or
      targetTower >= 0 or hero.attackingFort:
    hero.state = Fighting
    let targetPosition =
      if targetFootman >= 0: world.footmen[targetFootman].position
      elif targetHero >= 0: world.heroes[targetHero].position
      elif targetTower >= 0: world.towers[targetTower].position
      else: world.forts[fortIndex].center
    hero.surfaceHint = targetPosition.y
    let
      offset = targetPosition - hero.position
      inRange =
        if targetFootman >= 0 or targetHero >= 0:
          within(
            hero.position,
            targetPosition,
            heroAttackRange(hero.class)
          )
        elif targetTower >= 0:
          within(
            hero.position,
            targetPosition,
            max(heroAttackRange(hero.class), TowerSiegeRange)
          )
        else:
          within(hero.position, targetPosition, FortRange)
    if not inRange:
      hero.swingTicks = -1
      hero.animClip = heroRunClip
      inc hero.animTicks
      let
        targetX = int(mapCoordinate(targetPosition.x))
        targetY = int(mapCoordinate(targetPosition.z))
      discard hero.setHeroDestination(
        targetX,
        targetY,
        targetPosition.y
      )
      if not hero.followHeroPath():
        hero.tryMove(offset)
    else:
      snapFacing(hero.body, hero.facing, offset)
      if hero.swingTicks < 0:
        startSwing(world, hero)
      let duration = heroAttackTicks(hero.class)
      inc hero.swingTicks
      if not hero.damageLanded and
          hero.swingTicks >= duration * 45 div 100:
        hero.damageLanded = true
        applyHeroHit(
          world,
          hero,
          hero.heroAttackDamage,
          targetFootman,
          targetHero,
          targetTower,
          fortIndex
        )
      if hero.swingTicks >= duration:
        startSwing(world, hero)
      hero.animClip = hero.swingClip
      hero.animTicks = max(hero.swingTicks, 0)
    return

  let moving = hero.followHeroPath()
  hero.state = Marching
  hero.swingTicks = -1
  hero.animClip = if moving: heroRunClip else: heroIdleClip
  inc hero.animTicks

proc separateBodies(first, second: var Body, layer: int32) =
  ## Pushes two living units apart while keeping both on this layer.
  gotaWalkLayer = int(layer)
  gotaWalkDestLayer = int(layer)
  separatePair(first, second, tilesWalkable)

proc addHashy(hash: var uint32, value: WorldPoint) =
  ## Mixes one authoritative integer world position.
  hash.addHashy(value.x)
  hash.addHashy(value.y)
  hash.addHashy(value.z)

proc addHashy(hash: var uint32, value: Heading) =
  ## Mixes one authoritative integer heading.
  hash.addHashy(value.x)
  hash.addHashy(value.z)

proc stateHash*(game: Game): uint64 =
  ## Hashes replay-authoritative state after actions for one tick are applied.
  let world = game.world
  var hash = HashySeed
  hash.addHashy(game.map.hash)
  hash.addHashy(world.tick)
  hash.addHashy(world.spawnTimerTicks)
  hash.addHashy(world.heroTurnTicks)
  hash.addHashy(world.heroTurnStart)
  hash.addHashy(world.rng)
  hash.addHashy(world.nextFootmanId)
  hash.addHashy(world.gameOver)
  hash.addHashy(world.winner.ord)
  for value in world.teamHeroKills:
    hash.addHashy(value)
  for value in world.teamHeroDeaths:
    hash.addHashy(value)
  hash.addHashy(world.forts.len)
  for fort in world.forts:
    hash.addHashy(fort.id)
    hash.addHashy(fort.team.ord)
    hash.addHashy(fort.center)
    hash.addHashy(fort.hp)
  hash.addHashy(world.towers.len)
  for tower in world.towers:
    hash.addHashy(tower.id)
    hash.addHashy(tower.team.ord)
    hash.addHashy(tower.lane)
    hash.addHashy(tower.tier.ord)
    hash.addHashy(tower.position)
    hash.addHashy(tower.facing)
    hash.addHashy(tower.hp)
    hash.addHashy(tower.maxHp)
    hash.addHashy(tower.targetId)
    hash.addHashy(tower.attackTicks)
  hash.addHashy(world.heroes.len)
  for i in 0 ..< world.heroes.len:
    let hero = world.heroes[i]
    hash.addHashy(hero.id)
    hash.addHashy(hero.team.ord)
    hash.addHashy(hero.slot)
    hash.addHashy(hero.lane)
    hash.addHashy(hero.class.ord)
    hash.addHashy(hero.position)
    hash.addHashy(hero.spawnPosition)
    hash.addHashy(hero.facing)
    hash.addHashy(hero.body)
    hash.addHashy(hero.hp)
    hash.addHashy(hero.maxHp)
    hash.addHashy(hero.mana)
    hash.addHashy(hero.maxMana)
    hash.addHashy(hero.level)
    hash.addHashy(hero.xp)
    hash.addHashy(hero.totalXp)
    hash.addHashy(hero.gold)
    hash.addHashy(hero.state.ord)
    hash.addHashy(hero.waypointIndex)
    hash.addHashy(hero.targetFootmanId)
    hash.addHashy(hero.targetHeroId)
    hash.addHashy(hero.targetTowerId)
    hash.addHashy(hero.attackingFort)
    hash.addHashy(hero.swingClip)
    hash.addHashy(hero.swingTicks)
    hash.addHashy(hero.damageLanded)
    hash.addHashy(hero.animClip)
    hash.addHashy(hero.animTicks)
    hash.addHashy(hero.deathTicks)
    hash.addHashy(hero.surfaceHint)
    hash.addHashy(hero.navLayer)
    hash.addHashy(hero.attackObjectId)
    hash.addHashy(hero.movePath.len)
    for waypoint in hero.movePath:
      hash.addHashy(waypoint)
    hash.addHashy(hero.movePathIndex)
    hash.addHashy(hero.moveTileX)
    hash.addHashy(hero.moveTileY)
    hash.addHashy(hero.hasMoveTarget)
    for slot in 0 ..< InventorySlots:
      hash.addHashy(hero.inventory[slot].ord)
      hash.addHashy(hero.itemCounts[slot])
    for slot in HeroAbilitySlot:
      hash.addHashy(hero.cooldowns[slot])
  hash.addHashy(world.footmen.len)
  for footman in world.footmen:
    hash.addHashy(footman.id)
    hash.addHashy(footman.team.ord)
    hash.addHashy(footman.lane)
    hash.addHashy(footman.position)
    hash.addHashy(footman.facing)
    hash.addHashy(footman.body)
    hash.addHashy(footman.hp)
    hash.addHashy(footman.state.ord)
    hash.addHashy(footman.waypointIndex)
    hash.addHashy(footman.targetId)
    hash.addHashy(footman.targetHeroId)
    hash.addHashy(footman.targetTowerId)
    hash.addHashy(footman.attackingFort)
    hash.addHashy(footman.swingClip)
    hash.addHashy(footman.swingTicks)
    hash.addHashy(footman.damageLanded)
    hash.addHashy(footman.animClip)
    hash.addHashy(footman.animTicks)
    hash.addHashy(footman.deathTicks)
    hash.addHashy(footman.surfaceHint)
    hash.addHashy(footman.navLayer)
  uint64(hash)

proc settleSurface(position: var WorldPoint, surfaceHint: int32) =
  ## Quantizes terrain geometry back into authoritative integer height.
  position.y = fixedSurfaceHeightNear(position, surfaceHint)

proc checkReplayHash(game: Game, hash: uint64) =
  ## Reports each divergent replay tick once while allowing playback to run.
  if not game.historyPlayback or game.world.tick <= 0:
    return
  let hashes =
    if game.recorder != nil: game.recorder.data.hashes
    else: game.replayPlayer.data.hashes
  hashes.checkReplayHash(uint32(game.world.tick), hash, game.hashCheck)

proc tickWorld*(game: Game, onHeroTurn: proc() {.closure.}) {.measure.} =
  ## Advances exactly one authoritative integer simulation tick.
  let world = game.world
  if world.gameOver:
    return
  if game.replayMode and
      uint32(world.tick) >= game.replayData.header.setup.maximumTicks:
    return

  dec world.spawnTimerTicks
  if world.spawnTimerTicks <= 0:
    world.spawnTimerTicks += world.spawnIntervalTicks
    profileBlock "spawnWave":
      spawnWave(world)

  world.tick = world.tick +% 1
  profileBlock "vision":
    rebuildVision(world)
  if game.historyPlayback:
    if game.recorder != nil:
      game.replayPlayer.data = game.recorder.data
    var action: ReplayAction
    while game.replayPlayer.takeActionAt(uint32(world.tick), action):
      applyReplayAction(world, action)
  dec world.heroTurnTicks
  if world.heroTurnTicks <= 0:
    world.heroTurnTicks += DecisionTicks
    if game.historyPlayback:
      world.heroTurnStart = (world.heroTurnStart + 1) mod world.heroes.len
    else:
      profileBlock "decisions":
        onHeroTurn()

  profileBlock "footmen":
    for footman in world.footmen.mitems:
      updateFootman(world, footman)
  profileBlock "towers":
    for tower in world.towers.mitems:
      updateTower(world, tower)
  profileBlock "heroes":
    for hero in world.heroes:
      updateHero(world, hero)

  var write = 0
  for read in 0 ..< world.footmen.len:
    if world.footmen[read].state != Dying or
        world.footmen[read].deathTicks < FootmanDeathTicks + CorpseLingerTicks:
      if write != read:
        world.footmen[write] = world.footmen[read]
      inc write
  world.footmen.setLen(write)

  profileBlock "separate":
    for i in 0 ..< world.footmen.len:
      if world.footmen[i].state == Dying:
        continue
      for j in i + 1 ..< world.footmen.len:
        if world.footmen[j].state == Dying:
          continue
        if world.footmen[i].navLayer != world.footmen[j].navLayer:
          continue
        separateBodies(
          world.footmen[i].body,
          world.footmen[j].body,
          world.footmen[i].navLayer
        )

    for i in 0 ..< world.heroes.len:
      if world.heroes[i].state == Dying:
        continue
      for j in i + 1 ..< world.heroes.len:
        if world.heroes[j].state == Dying:
          continue
        if world.heroes[i].navLayer != world.heroes[j].navLayer:
          continue
        separateBodies(
          world.heroes[i].body,
          world.heroes[j].body,
          world.heroes[i].navLayer
        )
      for j in 0 ..< world.footmen.len:
        if world.footmen[j].state == Dying:
          continue
        if world.heroes[i].navLayer != world.footmen[j].navLayer:
          continue
        separateBodies(
          world.heroes[i].body,
          world.footmen[j].body,
          world.heroes[i].navLayer
        )

  profileBlock "applyBody":
    for footman in world.footmen.mitems:
      applyBody(footman)
      settleOnLayer(footman.position, footman.navLayer)
    for hero in world.heroes:
      applyBody(hero)
      settleOnLayer(hero.position, hero.navLayer)

  for fort in world.forts.mitems:
    if fort.hp <= 0:
      world.gameOver = true
      world.winner = if fort.team == RedTeam: BlueTeam else: RedTeam
      for footman in world.footmen.mitems:
        if footman.state == Dying:
          continue
        footman.animClip =
          if footman.team == world.winner: victoryClip else: idleClip
        footman.animTicks = 0
      for hero in world.heroes:
        if hero.state == Dying:
          continue
        hero.animClip =
          if hero.team == world.winner: heroIdleClip else: heroDeathClip
        hero.animTicks = 0

  let hash = stateHash(game)
  if game.historyPlayback:
    checkReplayHash(game, hash)
  elif game.recorder != nil and game.recordingError.len == 0 and
      game.recorder.data.hashes.len < world.tick:
    try:
      game.recorder.recordHash(hash)
    except ReplayError as error:
      game.recordingError = error.msg

proc initLanePaths(seed: int32) =
  ## Builds shared lane polylines on the generated map.
  for lane in 0 .. 2:
    lanePathPoints[lane].setLen(0)
    lanePathTiles[lane].setLen(0)
    for i in 0 ..< LaneRoutes[lane].len - 1:
      let
        a = LaneRoutes[lane][i]
        b = LaneRoutes[lane][i + 1]
        segment = findTilePath(a.layer, a.x, a.z, b.layer, b.x, b.z)
      doAssert segment.len > 0,
        &"lane {lane} seed {seed}: no path {a} -> {b}; " &
        &"walkable {isWalkable(a.layer, a.x, a.z)} -> " &
        &"{isWalkable(b.layer, b.x, b.z)}"
      for tileIndex, tile in segment:
        if lanePathTiles[lane].len > 0 and tileIndex == 0:
          continue
        lanePathTiles[lane].add tile
        lanePathPoints[lane].add pathPoint(
          int(tile.layer),
          int(tile.x),
          int(tile.z)
        )
  let
    redTunnel = findPathPoints(
      GroundLayer,
      RedFortTile + FortOuterRadius + 1,
      RedFortTile,
      GroundLayer,
      RedFortTile + 3,
      RedFortTile
    )
    blueTunnel = findPathPoints(
      GroundLayer,
      BlueFortTile - FortOuterRadius - 1,
      BlueFortTile,
      GroundLayer,
      BlueFortTile - 3,
      BlueFortTile
    )
    redRampart = findPathPoints(
      GroundLayer,
      RedFortTile + 1,
      RedFortTile - 4,
      RedFortLayer,
      FortOuterRadius + FortWallRadius,
      FortOuterRadius - 4
    )
    blueRampart = findPathPoints(
      GroundLayer,
      BlueFortTile - 1,
      BlueFortTile + 4,
      BlueFortLayer,
      FortOuterRadius - FortWallRadius,
      FortOuterRadius + 4
    )
    redFountainPath = findPathPoints(
      GroundLayer,
      RedFortTile + FortOuterRadius + 1,
      RedFortTile,
      RedFortLayer,
      FortOuterRadius,
      FortOuterRadius
    )
    blueFountainPath = findPathPoints(
      GroundLayer,
      BlueFortTile - FortOuterRadius - 1,
      BlueFortTile,
      BlueFortLayer,
      FortOuterRadius,
      FortOuterRadius
    )
  doAssert redTunnel.len > 0, "red fort gate tunnel is unreachable"
  doAssert blueTunnel.len > 0, "blue fort gate tunnel is unreachable"
  doAssert redRampart.len > 0, "red fort rampart is unreachable"
  doAssert blueRampart.len > 0, "blue fort rampart is unreachable"
  doAssert redFountainPath.len > 0, "red fountain dais is unreachable"
  doAssert blueFountainPath.len > 0, "blue fountain dais is unreachable"

proc newGame*(
    map: MapData,
    spawnInterval: int32,
    botCount: int,
    replayMode: bool,
    replayData: ReplayData
): Game =
  ## Builds one match session: world, lane paths, towers, and heroes.
  result = Game(
    world: World(
      forts: startingForts(),
      nextFootmanId: FirstFootmanId,
      winner: RedTeam,
      scriptObjects: newSeqOfCap[WorldObject](256),
      scriptObjectsTick: -1
    ),
    map: map,
    replayMode: replayMode,
    replayData: replayData
  )
  let world = result.world
  world.spawnIntervalTicks = spawnInterval
  world.rng = initRng(map.seed)
  initLanePaths(map.seed)
  initTowers(world)
  for lane in 0 .. 2:
    world.barracksSpawns[RedTeam.ord][lane] = worldPoint(lanePathPoints[lane][0])
    world.barracksSpawns[BlueTeam.ord][lane] = worldPoint(lanePathPoints[lane][^1])
  sightTerrain = buildSightTerrain()
  let visionCells = GridTiles * GridTiles
  for team in Team:
    world.teamVisible[team.ord] = newSeq[uint8](visionCells)
    world.teamExplored[team.ord] = newSeq[uint8](visionCells)
  for lane in 0 .. 2:
    laneWorldPaths[lane].setLen(0)
    laneWorldLayers[lane].setLen(0)
    for tile in smoothPathTiles(lanePathTiles[lane]):
      laneWorldPaths[lane].add worldPoint(pathPoint(
        int(tile.layer),
        int(tile.x),
        int(tile.z)
      ))
      laneWorldLayers[lane].add tile.layer
  for fort in world.forts.mitems:
    fort.center.y = fixedSurfaceHeight(fort.center)
  let heroSetup =
    if replayMode:
      replayData.header.setup.heroes
    else:
      liveHeroSetup(botCount)
  spawnHeroes(world, heroSetup)
  doAssert world.heroes.len == heroSetup.len, "every configured hero must spawn"
  rebuildVision(world)
  world.heroTurnStart = seededHeroTurnStart(world)
  if replayMode:
    validateReplayWorld(result)
