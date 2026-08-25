## Light vs Dark static game content: units, buildings, tech, and economy.
##
## Every value here is an integer constant folded into `contentHash`, so a
## balance change makes older replays fail at load with a named error instead
## of diverging silently at some later tick.

import
  polyworld/[cli, common, hashes]

## Match shape

const
  GridSide* = 128'i32
    ## Tiles along one edge of the map, matching `pathing.GridTiles`.
  GridCells* = GridSide * GridSide
  TickRate* = SharedTickRate
    ## Simulation ticks per second.
  DecisionTicks* = 1'i32
    ## Ticks between overlord decisions. One decision per simulation tick.
  VisionTicks* = 1'i32
    ## Ticks between vision rebuilds. Must divide `DecisionTicks` so that a
    ## decision never observes stale vision.
  DefaultSeconds* = 1_200'i32
    ## Twenty minutes, the default match length.
  DefaultSeed* = 2026'i32
  PlayerCount* = 2
  LightPlayer* = 0'i32
  DarkPlayer* = 1'i32

static:
  doAssert DecisionTicks mod VisionTicks == 0,
    "vision must be rebuilt on every decision tick"

## Tiles
##
## A tile coordinate is the authoritative spatial unit: units stand on tiles,
## structures cover square blocks of them, and nothing in the simulation ever
## holds a position finer than this.

type
  Tile2* = object
    x*, y*: int16

proc tile2*(x, y: int32): Tile2 =
  ## Builds one tile coordinate from wider integers.
  Tile2(x: int16(x), y: int16(y))

proc inGrid*(x, y: int32): bool =
  ## Returns whether a coordinate pair names a tile on the map.
  x >= 0 and x < GridSide and y >= 0 and y < GridSide

proc inGrid*(tile: Tile2): bool =
  ## Returns whether a tile coordinate names a tile on the map.
  inGrid(int32(tile.x), int32(tile.y))

proc tileIndex*(x, y: int32): int32 =
  ## Returns the flat row-major index of an on-map tile.
  y * GridSide + x

proc tileIndex*(tile: Tile2): int32 =
  ## Returns the flat row-major index of an on-map tile.
  tileIndex(int32(tile.x), int32(tile.y))

proc mirrorTile*(x, y: int32): (int32, int32) =
  ## Rotates a tile 180 degrees about the centre of the map. The two starting
  ## positions map onto each other under this, which is what makes the
  ## generated map fair by construction.
  (GridSide - 1 - x, GridSide - 1 - y)

proc chebyshev*(first, second: Tile2): int32 =
  ## Returns the king-move distance between two tiles.
  max(abs(int32(first.x) - int32(second.x)),
      abs(int32(first.y) - int32(second.y)))

## Entity identifiers
##
## The kind of an entity is derivable from its identifier range, so every
## command validator can reject a malformed identifier with one comparison
## before it touches an array. Identifiers are never reused within a match.

const
  NoEntity* = 0'i32
  FirstMineId* = 10'i32
  LastMineId* = 99'i32
  FirstBuildingId* = 1_000'i32
  LastBuildingId* = 999_999'i32
  FirstUnitId* = 1_000_000'i32
  LastUnitId* = int32.high - 1

proc isMineId*(id: int32): bool =
  ## Returns whether an identifier names a neutral gold mine.
  id >= FirstMineId and id <= LastMineId

proc isPlayerBuildingId*(id: int32): bool =
  ## Returns whether an identifier names a structure a player built or owns.
  id >= FirstBuildingId and id <= LastBuildingId

proc isBuildingId*(id: int32): bool =
  ## Returns whether an identifier names any structure, mines included.
  id.isMineId or id.isPlayerBuildingId

proc isUnitId*(id: int32): bool =
  ## Returns whether an identifier names a mobile unit.
  id >= FirstUnitId and id <= LastUnitId

## Kinds

type
  UnitKind* = enum
    PeonUnit, SoldierUnit, ArcherUnit, MageUnit,
    KnightUnit, CatapultUnit, ClericUnit, SummonUnit
      ## Ordinals 0-3 stay peon/soldier/archer/mage so existing BASIC
      ## scripts keep reading the same `obsSub` values.

  BuildingKind* = enum
    TownHallBuilding, FarmBuilding, BarracksBuilding,
    LumberMillBuilding, TowerBuilding,
    StablesBuilding, ChurchBuilding, BlacksmithBuilding,
    GoldMineBuilding
      ## Neutral and never buildable. Listed last so the buildable kinds
      ## form the prefix `TownHallBuilding .. BlacksmithBuilding`.

const
  BuildableHigh* = BlacksmithBuilding
    ## Highest kind an overlord may pass to `build`.

type
  UnitStats* = object
    gold*, wood*: int32
    trainTicks*: int32
    hp*: int32
    armor*: int32
    piercing*: int32
      ## Always applied; ignores armor.
    basic*: int32
      ## Reduced by the target's armor, never below zero.
    splash*: int32
      ## Extra piercing to king-move neighbours. Catapult only.
    missPercent*: int32
      ## Chance the swing does nothing. Zero on catapults.
    cooldownTicks*: int32
    rangeTiles*: int32
    sightTiles*: int32
    stepTicks*: int32
      ## Ticks to cross one orthogonal tile. Diagonals cost 181/128 of this.
    food*: int32
    trainedAt*: BuildingKind
    requires*: set[BuildingKind]

  BuildingStats* = object
    gold*, wood*: int32
    buildTicks*: int32
    hp*: int32
    sightTiles*: int32
    footprint*: int32
      ## Square side in tiles.
    foodProvided*: int32
    damage*, cooldownTicks*, rangeTiles*: int32
      ## Zero for everything that is not a tower.
    dropOffGold*, dropOffWood*: bool
    requires*: set[BuildingKind]

## Unit table
##
## Stats are written for a 24 Hz tick. A listed cooldown or build time of
## F frames on a 40 Hz sheet is `F * 24 / 40` ticks here. Light and Dark
## share costs and train times; combat numbers follow each side's column
## where they differ.

const
  AttackMissPercent* = 20'i32
  SpeedStepTicks* = 10'i32
    ## Infantry walk: one tile every ten ticks.
  SlowStepTicks* = 16'i32
    ## Catapult crawl: one tile every sixteen ticks.

const LightUnits: array[UnitKind, UnitStats] = [
  PeonUnit: UnitStats(
    gold: 400, wood: 0, trainTicks: 450,
    hp: 40, armor: 0, piercing: 0, basic: 1, splash: 0,
    missPercent: AttackMissPercent, cooldownTicks: 24,
    rangeTiles: 1, sightTiles: 5, stepTicks: SpeedStepTicks, food: 1,
    trainedAt: TownHallBuilding, requires: {}
  ),
  SoldierUnit: UnitStats(
    gold: 400, wood: 0, trainTicks: 360,
    hp: 60, armor: 2, piercing: 1, basic: 9, splash: 0,
    missPercent: AttackMissPercent, cooldownTicks: 24,
    rangeTiles: 1, sightTiles: 5, stepTicks: SpeedStepTicks, food: 1,
    trainedAt: BarracksBuilding, requires: {}
  ),
  ArcherUnit: UnitStats(
    gold: 450, wood: 50, trainTicks: 420,
    hp: 60, armor: 1, piercing: 4, basic: 0, splash: 0,
    missPercent: AttackMissPercent, cooldownTicks: 37,
    rangeTiles: 5, sightTiles: 7, stepTicks: SpeedStepTicks, food: 1,
    trainedAt: BarracksBuilding, requires: {LumberMillBuilding}
  ),
  MageUnit: UnitStats(
    gold: 900, wood: 0, trainTicks: 540,
    hp: 40, armor: 0, piercing: 6, basic: 0, splash: 0,
    missPercent: AttackMissPercent, cooldownTicks: 36,
    rangeTiles: 3, sightTiles: 7, stepTicks: SpeedStepTicks, food: 1,
    trainedAt: TowerBuilding, requires: {}
  ),
  KnightUnit: UnitStats(
    gold: 850, wood: 0, trainTicks: 480,
    hp: 90, armor: 5, piercing: 1, basic: 13, splash: 0,
    missPercent: AttackMissPercent, cooldownTicks: 24,
    rangeTiles: 1, sightTiles: 6, stepTicks: SpeedStepTicks, food: 1,
    trainedAt: BarracksBuilding,
    requires: {StablesBuilding, BlacksmithBuilding}
  ),
  CatapultUnit: UnitStats(
    gold: 900, wood: 200, trainTicks: 600,
    hp: 120, armor: 0, piercing: 255, basic: 0, splash: 63,
    missPercent: 0, cooldownTicks: 192,
    rangeTiles: 8, sightTiles: 8, stepTicks: SlowStepTicks, food: 1,
    trainedAt: BarracksBuilding,
    requires: {BlacksmithBuilding, LumberMillBuilding}
  ),
  ClericUnit: UnitStats(
    gold: 700, wood: 0, trainTicks: 480,
    hp: 40, armor: 0, piercing: 6, basic: 0, splash: 0,
    missPercent: AttackMissPercent, cooldownTicks: 48,
    rangeTiles: 1, sightTiles: 7, stepTicks: SpeedStepTicks, food: 1,
    trainedAt: ChurchBuilding, requires: {}
  ),
  SummonUnit: UnitStats(
    gold: 1200, wood: 0, trainTicks: 720,
    hp: 250, armor: 0, piercing: 40, basic: 0, splash: 0,
    missPercent: AttackMissPercent, cooldownTicks: 24,
    rangeTiles: 3, sightTiles: 6, stepTicks: SpeedStepTicks, food: 1,
    trainedAt: TowerBuilding, requires: {}
  )
]

const DarkUnits: array[UnitKind, UnitStats] = [
  PeonUnit: LightUnits[PeonUnit],
  SoldierUnit: LightUnits[SoldierUnit],
  ArcherUnit: UnitStats(
    gold: 450, wood: 50, trainTicks: 420,
    hp: 60, armor: 1, piercing: 5, basic: 0, splash: 0,
    missPercent: AttackMissPercent, cooldownTicks: 37,
    rangeTiles: 4, sightTiles: 7, stepTicks: SpeedStepTicks, food: 1,
    trainedAt: BarracksBuilding, requires: {LumberMillBuilding}
  ),
  MageUnit: UnitStats(
    gold: 900, wood: 0, trainTicks: 540,
    hp: 40, armor: 0, piercing: 6, basic: 0, splash: 0,
    missPercent: AttackMissPercent, cooldownTicks: 36,
    rangeTiles: 2, sightTiles: 7, stepTicks: SpeedStepTicks, food: 1,
    trainedAt: TowerBuilding, requires: {}
  ),
  KnightUnit: LightUnits[KnightUnit],
  CatapultUnit: LightUnits[CatapultUnit],
  ClericUnit: UnitStats(
    gold: 700, wood: 0, trainTicks: 480,
    hp: 40, armor: 0, piercing: 6, basic: 0, splash: 0,
    missPercent: AttackMissPercent, cooldownTicks: 48,
    rangeTiles: 2, sightTiles: 7, stepTicks: SpeedStepTicks, food: 1,
    trainedAt: ChurchBuilding, requires: {}
  ),
  SummonUnit: UnitStats(
    gold: 1200, wood: 0, trainTicks: 720,
    hp: 300, armor: 0, piercing: 0, basic: 65, splash: 0,
    missPercent: AttackMissPercent, cooldownTicks: 24,
    rangeTiles: 1, sightTiles: 6, stepTicks: SpeedStepTicks, food: 1,
    trainedAt: TowerBuilding, requires: {}
  )
]

const UnitTable*: array[PlayerCount, array[UnitKind, UnitStats]] = [
  LightUnits,
  DarkUnits
]

proc unitOf*(player: int32, kind: UnitKind): UnitStats =
  ## Returns one side's stats for a unit kind.
  UnitTable[player][kind]

proc attackDamage*(stats: UnitStats, armor: int32): int32 =
  ## Piercing always lands; basic is reduced by armor and never below zero.
  stats.piercing + max(0'i32, stats.basic - armor)

## Building table

const BuildingTable*: array[BuildingKind, BuildingStats] = [
  TownHallBuilding: BuildingStats(
    gold: 1200, wood: 800, buildTicks: 720,
    hp: 1200, sightTiles: 6, footprint: 3, foodProvided: 5,
    dropOffGold: true, dropOffWood: true, requires: {}
  ),
  FarmBuilding: BuildingStats(
    gold: 400, wood: 200, buildTicks: 240,
    hp: 400, sightTiles: 3, footprint: 2, foodProvided: 4,
    requires: {}
  ),
  BarracksBuilding: BuildingStats(
    gold: 600, wood: 400, buildTicks: 480,
    hp: 800, sightTiles: 4, footprint: 3, foodProvided: 0,
    requires: {}
  ),
  LumberMillBuilding: BuildingStats(
    gold: 500, wood: 300, buildTicks: 360,
    hp: 600, sightTiles: 4, footprint: 3, foodProvided: 0,
    dropOffWood: true, requires: {}
  ),
  TowerBuilding: BuildingStats(
    gold: 500, wood: 300, buildTicks: 360,
    hp: 700, sightTiles: 9, footprint: 2, foodProvided: 0,
    damage: 12, cooldownTicks: 24, rangeTiles: 6,
    requires: {LumberMillBuilding}
  ),
  StablesBuilding: BuildingStats(
    gold: 600, wood: 400, buildTicks: 480,
    hp: 700, sightTiles: 4, footprint: 3, foodProvided: 0,
    requires: {BarracksBuilding}
  ),
  ChurchBuilding: BuildingStats(
    gold: 700, wood: 400, buildTicks: 480,
    hp: 700, sightTiles: 4, footprint: 3, foodProvided: 0,
    requires: {BarracksBuilding}
  ),
  BlacksmithBuilding: BuildingStats(
    gold: 600, wood: 400, buildTicks: 360,
    hp: 700, sightTiles: 4, footprint: 3, foodProvided: 0,
    requires: {BarracksBuilding}
  ),
  GoldMineBuilding: BuildingStats(
    gold: 0, wood: 0, buildTicks: 0,
    hp: 2000, sightTiles: 0, footprint: 2, foodProvided: 0,
    requires: {}
  )
]

## Economy

const
  StartingGold* = 800'i32
  StartingWood* = 400'i32
  StartingPeons* = 5'i32
  GoldPerTrip* = 100'i32
  MineTicks* = 60'i32
    ## Ticks a peon spends hidden inside a gold mine.
  MinersPerMine* = 4'i32
  WoodPerTrip* = 100'i32
  ChopTicks* = 80'i32
  WoodPerTree* = 400'i16
    ## Four trips, after which the tile is removed from the map.
  DepositTicks* = 5'i32
  MainMineGold* = 25_000'i32
  ExpansionMineGold* = 15_000'i32
  FoodCapMax* = 100'i32
  UnitsPerPlayer* = 100'i32
  DeathTicks* = 36'i32
    ## Ticks a corpse lingers before the unit is removed.
  RubbleTicks* = 48'i32

## Movement and pathing

const
  OrthogonalCost* = 128'i32
  DiagonalCost* = 181'i32
    ## 181/128 is 1.4141, within 0.0001 of the square root of two.
  ShoveAfterTicks* = 5'i32
  SwapAfterTicks* = 10'i32
  RepathAfterTicks* = 36'i32
  AbandonAfterTicks* = 120'i32
  RepathCooldownTicks* = 60'i32
  ShortPathCooldownTicks* = 6'i32
  AcquireStagger* = 3'i32
    ## Ticks between target sweeps for one idle unit. Sweeping every unit
    ## every tick is quadratic and dominates the simulation; an eighth of a
    ## second of reaction delay is invisible next to any attack cooldown.
  TowerStagger* = 2'i32
  MaxPathExpansions* = 3000
  PathBudgetPerTick* = 15
  MaxPathRequests* = 256
  FieldsPerPlayer* = 8
  OccupiedTilePenalty* = 256'i32

proc diagonalStepTicks*(stepTicks: int32): int32 =
  ## Returns the tick cost of one diagonal step for a unit speed.
  int32((int64(stepTicks) * DiagonalCost + OrthogonalCost div 2) div
    OrthogonalCost)

## Presentation identifiers
##
## Names only. The simulation never reads an asset, so a missing model changes
## how the game looks and never how it plays.

type
  AnimationSlot* = enum
    RunAnimation, IdleAnimation, DeathAnimation,
    AttackAnimation, AttackAlternateAnimation, VictoryAnimation

const
  UnitModels*: array[PlayerCount, array[UnitKind, string]] = [
    [
      PeonUnit: DataRoot & "/characters/mini_legion/human/worker.glb",
      SoldierUnit: DataRoot & "/characters/mini_legion/human/footman.glb",
      ArcherUnit: DataRoot & "/characters/mini_legion/human/archer.glb",
      MageUnit: DataRoot & "/characters/mini_legion/human/mage.glb",
      KnightUnit: DataRoot & "/characters/mini_legion/human/horseman.glb",
      CatapultUnit: DataRoot & "/characters/mini_legion/human/siege_engine.glb",
      ClericUnit: DataRoot & "/characters/mini_legion/sentinel/druid.glb",
      SummonUnit: DataRoot & "/characters/mini_legion/sentinel/rock_golem.glb"
    ],
    [
      PeonUnit: DataRoot & "/characters/mini_legion/warband/minion.glb",
      SoldierUnit: DataRoot & "/characters/mini_legion/warband/grunt.glb",
      ArcherUnit: DataRoot & "/characters/mini_legion/warband/head_hunter.glb",
      MageUnit: DataRoot & "/characters/mini_legion/warband/warlock.glb",
      KnightUnit: DataRoot & "/characters/mini_legion/warband/hog_rider.glb",
      CatapultUnit: DataRoot & "/characters/mini_legion/undead/siege_engine.glb",
      ClericUnit: DataRoot & "/characters/mini_legion/undead/lich.glb",
      SummonUnit: DataRoot & "/characters/rpg_monsters/demon_king.glb"
    ]
  ]

  UnitHeights*: array[UnitKind, float32] = [
    PeonUnit: 1.05'f32,
    SoldierUnit: 1.15'f32,
    ArcherUnit: 1.20'f32,
    MageUnit: 1.25'f32,
    KnightUnit: 1.55'f32,
    CatapultUnit: 1.40'f32,
    ClericUnit: 1.22'f32,
    SummonUnit: 1.90'f32
  ]

## Clip name candidates per slot, most preferred first.
##
## Mini Legion uses Idle/Run/Attack01/Death. Workers have WorkRoutine and
## no attack. Archers and head hunters use Attack01Start. Siege engines
## move with Move. The rock golem walks. Demon king uses IdleBattle and
## RunForward. The last name in each list is one every current model has.

const MiniLegionClips: array[AnimationSlot, seq[string]] = [
  RunAnimation: @["Run", "Move", "Walk", "RunForward", "WalkForward"],
  IdleAnimation: @["Idle", "IdleBattle", "IdleNormal"],
  DeathAnimation: @["Death", "Die", "Die01"],
  AttackAnimation: @[
    "Attack01", "Attack01Start", "WorkRoutine", "WorkStart", "Idle"
  ],
  AttackAlternateAnimation: @[
    "Attack02", "Attack02Start", "Attack01", "Attack01Start",
    "WorkRoutine", "Idle"
  ],
  VictoryAnimation: @["Victory", "Idle", "IdleBattle", "Taunting"]
]

const AnimationNames*: array[UnitKind, array[AnimationSlot, seq[string]]] = [
  PeonUnit: MiniLegionClips,
  SoldierUnit: MiniLegionClips,
  ArcherUnit: MiniLegionClips,
  MageUnit: MiniLegionClips,
  KnightUnit: MiniLegionClips,
  CatapultUnit: MiniLegionClips,
  ClericUnit: MiniLegionClips,
  SummonUnit: MiniLegionClips
]

const
  LightPropPack* = DataRoot & "/terrain/low_poly_village.glb"
  DarkPropPack* = DataRoot & "/terrain/tower_defense_kit.glb"

  BuildingProps*: array[PlayerCount, array[BuildingKind, string]] = [
    [
      TownHallBuilding: "house_lvl7",
      FarmBuilding: "farm_lvl4",
      BarracksBuilding: "farm_house_lvl5",
      LumberMillBuilding: "farm_house_lvl3",
      TowerBuilding: "tower_lvl5",
      StablesBuilding: "farm_house_lvl6",
      ChurchBuilding: "house_lvl4",
      BlacksmithBuilding: "farm_house_lvl2",
      GoldMineBuilding: ""
    ],
    [
      TownHallBuilding: "building1",
      FarmBuilding: "farm_lvl2",
      BarracksBuilding: "building3",
      LumberMillBuilding: "building2",
      TowerBuilding: "tower_square_tall1",
      StablesBuilding: "tower_tall1",
      ChurchBuilding: "tower_square_tall2",
      BlacksmithBuilding: "tower_square_small1",
      GoldMineBuilding: ""
    ]
  ]

  BuildingPropHeights*: array[BuildingKind, float32] = [
    TownHallBuilding: 3.0'f32,
    FarmBuilding: 1.6'f32,
    BarracksBuilding: 2.6'f32,
    LumberMillBuilding: 2.4'f32,
    TowerBuilding: 3.2'f32,
    StablesBuilding: 2.5'f32,
    ChurchBuilding: 2.8'f32,
    BlacksmithBuilding: 2.2'f32,
    GoldMineBuilding: 1.8'f32
  ]

  ## Farm props live in the village pack for both sides, since the tower kit
  ## has no farm. Every other Dark building comes from the tower kit.
  DarkFarmFromVillage* = true

  MineProps* = ["mineral1", "mineral3", "rock2"]
    ## Neutral gold mine decoration, from the tower kit.
  ConstructionProps* = ["box1", "barel1", "wall1"]
  RubbleProps* = ["rock1", "stump1"]

## Content fingerprint

proc contentHash*(): uint64 =
  ## Hashes every tuning value that can change how a match plays out.
  var hash = HashySeed
  hash.addHashy(GridSide)
  hash.addHashy(TickRate)
  hash.addHashy(DecisionTicks)
  hash.addHashy(VisionTicks)
  for player in 0 ..< PlayerCount:
    for kind in UnitKind:
      let stats = UnitTable[player][kind]
      hash.addHashy(int32(player))
      hash.addHashy(int32(kind.ord))
      hash.addHashy(stats.gold)
      hash.addHashy(stats.wood)
      hash.addHashy(stats.trainTicks)
      hash.addHashy(stats.hp)
      hash.addHashy(stats.armor)
      hash.addHashy(stats.piercing)
      hash.addHashy(stats.basic)
      hash.addHashy(stats.splash)
      hash.addHashy(stats.missPercent)
      hash.addHashy(stats.cooldownTicks)
      hash.addHashy(stats.rangeTiles)
      hash.addHashy(stats.sightTiles)
      hash.addHashy(stats.stepTicks)
      hash.addHashy(stats.food)
      hash.addHashy(int32(stats.trainedAt.ord))
      for required in BuildingKind:
        hash.addHashy(required in stats.requires)
  for kind in BuildingKind:
    let stats = BuildingTable[kind]
    hash.addHashy(int32(kind.ord))
    hash.addHashy(stats.gold)
    hash.addHashy(stats.wood)
    hash.addHashy(stats.buildTicks)
    hash.addHashy(stats.hp)
    hash.addHashy(stats.sightTiles)
    hash.addHashy(stats.footprint)
    hash.addHashy(stats.foodProvided)
    hash.addHashy(stats.damage)
    hash.addHashy(stats.cooldownTicks)
    hash.addHashy(stats.rangeTiles)
    hash.addHashy(stats.dropOffGold)
    hash.addHashy(stats.dropOffWood)
    for required in BuildingKind:
      hash.addHashy(required in stats.requires)
  for value in [
    StartingGold, StartingWood, StartingPeons, GoldPerTrip, MineTicks,
    MinersPerMine, WoodPerTrip, ChopTicks, int32(WoodPerTree), DepositTicks,
    MainMineGold, ExpansionMineGold, FoodCapMax, UnitsPerPlayer, DeathTicks,
    RubbleTicks, OrthogonalCost, DiagonalCost, ShoveAfterTicks,
    SwapAfterTicks, RepathAfterTicks, AbandonAfterTicks,
    RepathCooldownTicks, ShortPathCooldownTicks, OccupiedTilePenalty,
    AttackMissPercent
  ]:
    hash.addHashy(value)
  uint64(hash)
