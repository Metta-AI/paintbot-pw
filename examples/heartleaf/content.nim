## Heartleaf static game content: the village calendar, the vegetable list,
## and the dinner-party scoring table.
##
## Every value here is an integer constant folded into `contentHash`, so a
## tuning change makes older replays fail at load with a named error instead
## of diverging silently at some later tick.

import
  polyworld/[cli, hashes]

## Match shape
##
## A game is a week in a small village. Each day runs 9:00 to 21:00 on an
## accelerated clock, everyone gathers vegetables from the morning gardens,
## and at 18:00 sharp every house holds its dinner tally.

const
  GridSide* = 128'i32
    ## Tiles along one edge of the map, matching `pathing.GridTiles`.
  GridCells* = GridSide * GridSide
  TickRate* = SharedTickRate
    ## Simulation ticks per second.
  DecisionTicks* = 8'i32
    ## Ticks between villager decisions: one decision per game minute.
  TicksPerGameMinute* = 8'i32
    ## One real second is three game minutes.
  DayStartMinute* = 9 * 60
  DinnerMinute* = 18 * 60
    ## The tally fires the moment the clock reaches six in the evening.
  DayEndMinute* = 21 * 60
  DayTicks* = (DayEndMinute - DayStartMinute) * TicksPerGameMinute
    ## 5760 ticks: four real minutes per village day.
  ScoreScreenTicks* = 10 * TickRate
    ## Ten real seconds of standings between days.
  DefaultDayCount* = 7'i32
  MaxDayCount* = 28'i32
  DefaultSeed* = 2026'i32
  VillagerCount* = 9
  VeggieKinds* = 24
  GardensPerHouse* = 3
  GardenCount* = VillagerCount * GardensPerHouse
    ## Every garden grows exactly one vegetable each morning, so 27 items
    ## enter the world per day: three per villager, if nobody hoards.

static:
  doAssert DayTicks mod DecisionTicks == 0,
    "a day must end on a decision boundary"
  doAssert TicksPerGameMinute mod DecisionTicks == 0 or
    DecisionTicks mod TicksPerGameMinute == 0,
    "decisions and game minutes must nest"

## Dinner scoring
##
## A party is valid when the owner is inside their own house at 18:00 with at
## least one visitor. The host banks pantry-times-visitors, the pantry feeds
## everyone in three bite rounds, and a first taste of a vegetable is worth
## three times a repeat. Hosting empties the pantry; guests eat for free.

const
  BiteRounds* = 3'i32
  NewVeggiePoints* = 3'i32
  RepeatVeggiePoints* = 1'i32

## Movement and interaction
##
## Distances are king-move tiles. Doors are generous so a villager shoved off
## the doorstep in the 17:59 crush still gets inside before the bell.

const
  StepTicks* = 10'i32
    ## Ticks to cross one orthogonal tile: a walk, not a march.
  OrthogonalCost* = 128'i32
  DiagonalCost* = 181'i32
  GatherRadius* = 1'i32
  DoorRadius* = 1'i32
  InviteRadius* = 3'i32
  GardenEnterCost* = 64'i32
    ## Paths skirt garden plots instead of trampling through them.
  RepathAfterTicks* = 36'i32
  AbandonAfterTicks* = 240'i32
  RepathCooldownTicks* = 24'i32
  ShortPathCooldownTicks* = 6'i32
  MaxPathExpansions* = 3000
  PathBudgetPerTick* = 6
  MaxPathRequests* = 32

## Tiles

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

proc chebyshev*(first, second: Tile2): int32 =
  ## Returns the king-move distance between two tiles.
  max(abs(int32(first.x) - int32(second.x)),
      abs(int32(first.y) - int32(second.y)))

## Tile kinds
##
## The shared kinds cover grass, road, and trees; the village adds two of its
## own. Kinds only steer rendering and pathing costs; walkability comes from
## the impassable flag written at generation.

const
  GardenTileKind* = 6'u32
    ## A tilled plot. Walkable, but paths prefer to go around.
  HouseTileKind* = 7'u32
    ## A house footprint tile. Impassable; the prop stands on it.

## Names
##
## Cosmetic, but fixed: bots refer to villagers and vegetables by index, the
## UI by these names.

const
  VillagerNames*: array[VillagerCount, string] = [
    "Ivan", "Anton", "Yura", "Sasha", "Maxim",
    "Nikita", "Vova", "Dima", "Egor"
  ]
    ## The nine villagers of the original Heartleaf, house for house.
  VeggieNames*: array[VeggieKinds, string] = [
    "Carrot", "Tomato", "Lettuce", "Potato", "Pumpkin", "Radish",
    "Beet", "Corn", "Pea", "Onion", "Garlic", "Cabbage",
    "Squash", "Turnip", "Leek", "Spinach", "Broccoli", "Pepper",
    "Cucumber", "Zucchini", "Celery", "Eggplant", "Parsnip", "Kale"
  ]

## Day phases

type
  DayPhase* = enum
    DaytimePhase
      ## 9:00 until the 18:00 tally.
    EveningPhase
      ## After the tally until 21:00.
    ScorePhase
      ## The standings screen between days.
    GameOverPhase

  AnimationSlot* = enum
    IdleAnimation, WalkAnimation, GatherAnimation, WaveAnimation

## Clock helpers

proc minuteOfDayAt*(dayTick: int32): int32 =
  ## Returns the wall-clock minute for a tick offset into one day.
  DayStartMinute + dayTick div TicksPerGameMinute

proc gameLengthTicks*(dayCount: int32): int32 =
  ## Total ticks for a whole game, score screens included.
  dayCount * (DayTicks + ScoreScreenTicks)

## Content fingerprint

proc contentHash*(): uint64 =
  ## Hashes every tuning value that can change how a game plays out.
  var hash = HashySeed
  for value in [
    GridSide, TickRate, DecisionTicks, TicksPerGameMinute,
    int32(DayStartMinute), int32(DinnerMinute), int32(DayEndMinute),
    DayTicks, ScoreScreenTicks, int32(VillagerCount), int32(VeggieKinds),
    int32(GardensPerHouse), int32(GardenCount), BiteRounds, NewVeggiePoints,
    RepeatVeggiePoints, StepTicks, OrthogonalCost, DiagonalCost,
    GatherRadius, DoorRadius, InviteRadius, GardenEnterCost,
    RepathAfterTicks, AbandonAfterTicks, RepathCooldownTicks,
    ShortPathCooldownTicks
  ]:
    hash.addHashy(value)
  uint64(hash)
