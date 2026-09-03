## Every simulation type for Call to Adventure, and the constants that tune
## them. The whole simulation is integer: tile coordinates, phase units, tick
## counts, hit points. Floating point appears only in the renderer.
##
## `World` holds value fields plus `seq[Actor]`. Actors are refs so a path
## seq is not copied by `let actor = world.actors[i]`. Clone and restore
## deep-copy each actor. The state hash walks actor contents, not addresses.
## Actors refer to each other by `int32` id, never by pointer.

import
  polyworld/[bodies, cli, common, pathing, rngs]

## Shape of the world

const
  LevelCount* = 6      ## surface, pyramid, rooms, caves, lava hall, vault
  PartySize* = 4
  InventorySlots* = 2
  ChatLines* = 16      ## ring buffer of recent party chatter
  TilesPerLevel* = GridTiles * GridTiles
  WorldTiles* = LevelCount * TilesPerLevel

  SurfaceLevel* = 0'i8
  VaultLevel* = int8(LevelCount - 1)

## Tick budget

const
  TickRate* = SharedTickRate
  DecisionTicks* = 1'i32
    ## Ticks between hero VM decisions. One decision per simulation tick.
  HashIntervalTicks* = 24'i32     ## one replay checkpoint per second
  DefaultMaximumTicks* = 28_800'i32  ## 20 minutes at 24 ticks per second

## Movement

const
  PhaseUnits* = TickRate * 100
    ## Phase units in one flat tile step. An actor's `speed` is added to its
    ## phase each tick, so `tilesPerSecond = speed * TickRate / PhaseUnits`,
    ## so speed remains exactly centi-tiles per second at any tick rate.
  MinimumStepUnits* = PhaseUnits * 3 div 4
  MaximumStepUnits* = PhaseUnits * 2
  ClimbCostPerStep* = PhaseUnits div 8    ## per 1/8 tile of rise
  DescendCostPerStep* = PhaseUnits div 24 ## per 1/8 tile of drop
  MaximumPathTiles* = 256
  RepathAfterStuckTicks* = 12'i16
  SidestepAfterStuckTicks* = 36'i16

type
  TileRef* = object
    ## One tile anywhere in the world. Levels are separate `QuadLayer`s, so
    ## `level` doubles as the pathing layer index.
    level*: int8
    x*, z*: uint8

  Facing* = enum
    ## Numbered to match `edgeLink`'s direction argument exactly, so a facing
    ## can be passed straight through with no translation table.
    East, South, West, North

  PathStep* = object
    tile*: TileRef
    direction*: Facing

## Actors

type
  ActorKind* = enum
    HeroActor, MonsterActor

  HeroClass* = enum
    FighterClass, WizardClass, RogueClass, ClericClass

  Species* = enum
    OrcSpecies, SkeletonSpecies, LichSpecies, GolemSpecies

  MonsterState* = enum
    ## Native monster AI has no scripting; these are its whole vocabulary.
    GuardingState, PatrollingState, ChasingState, FightingState,
    KitingState, FleeingState

  Ability* = enum
    NoAbility,
    FirebrandSword, MoltenFist, LionGuard,
    MeteorStrike, FrostLance, VoidPortal,
    VenomDagger, VerdantArrow, ShadowCloak,
    HealingBloom, AngelicEmblem, SunOrb,
    HealingPotion, ChainAxe, CrystalCrown, ArcaneGateway, BattleHorn,
    SolarHammer,
    IronFlail, InfernoAegis, WingedBoot, BlazingBlade,
    IceWall, LightningStorm, ManaCrystal, ArcaneMeteor,
    VoidBlade, ShadowComet, GaleSlash, ThornRing,
    FirePhoenix, NatureTalisman, CosmicFlare

const
  AbilityCount* = int(Ability.high) + 1
  AbilityIconFiles*: array[Ability, string] = [
    "",
    "firebrand_sword",
    "molten_fist",
    "lion_guard",
    "meteor_strike",
    "frost_lance",
    "void_portal",
    "venom_dagger",
    "verdant_arrow",
    "shadow_cloak",
    "healing_bloom",
    "angelic_emblem",
    "sun_orb",
    "healing_potion",
    "chain_axe",
    "crystal_crown",
    "arcane_gateway",
    "battle_horn",
    "solar_hammer",
    "iron_flail",
    "inferno_aegis",
    "winged_boot",
    "blazing_blade",
    "ice_wall",
    "lightning_storm",
    "mana_crystal",
    "arcane_meteor",
    "void_blade",
    "shadow_comet",
    "gale_slash",
    "thorn_ring",
    "fire_phoenix",
    "nature_talisman",
    "cosmic_flare"
  ]

type
  AbilitySpec* = object
    ## Timing is chosen in round tick counts for feel. The client warps its
    ## animation clip so the clip's impact frame lands on `windupTicks`; the
    ## simulation never reads a clip length.
    windupTicks*: int16
    recoverTicks*: int16
    cooldownTicks*: int16
    manaCost*: int16
    rangeTiles*: int16
    damage*: int16
    spread*: int16

const Abilities*: array[Ability, AbilitySpec] = [
  AbilitySpec(),
  AbilitySpec(windupTicks: 9, recoverTicks: 10, rangeTiles: 1,
    damage: 14, spread: 6),
  AbilitySpec(windupTicks: 14, recoverTicks: 15, cooldownTicks: 120,
    rangeTiles: 1, damage: 34, spread: 10),
  AbilitySpec(windupTicks: 3, cooldownTicks: 48),
  AbilitySpec(windupTicks: 12, recoverTicks: 12, cooldownTicks: 36,
    manaCost: 12, rangeTiles: 7, damage: 22, spread: 8),
  AbilitySpec(windupTicks: 10, recoverTicks: 10, cooldownTicks: 96,
    manaCost: 16, rangeTiles: 5, damage: 10, spread: 4),
  AbilitySpec(windupTicks: 7, recoverTicks: 5, cooldownTicks: 240,
    manaCost: 20, rangeTiles: 4),
  AbilitySpec(windupTicks: 5, recoverTicks: 5, cooldownTicks: 96,
    rangeTiles: 1, damage: 12, spread: 4),
  AbilitySpec(windupTicks: 8, recoverTicks: 6, cooldownTicks: 24,
    rangeTiles: 6, damage: 9, spread: 5),
  AbilitySpec(windupTicks: 8, recoverTicks: 4, cooldownTicks: 360),
  AbilitySpec(windupTicks: 10, recoverTicks: 10, cooldownTicks: 72,
    manaCost: 18, rangeTiles: 4, damage: -70),
  AbilitySpec(windupTicks: 12, recoverTicks: 8, cooldownTicks: 360,
    manaCost: 24, rangeTiles: 4),
  AbilitySpec(windupTicks: 14, recoverTicks: 10, cooldownTicks: 240,
    manaCost: 20, rangeTiles: 5, damage: 26, spread: 10),
  AbilitySpec(windupTicks: 14, recoverTicks: 10, cooldownTicks: 12),
  AbilitySpec(windupTicks: 10, recoverTicks: 5),
  AbilitySpec(windupTicks: 4, recoverTicks: 3),
  AbilitySpec(windupTicks: 12, recoverTicks: 4, rangeTiles: 1),
  AbilitySpec(cooldownTicks: 12),
  AbilitySpec(windupTicks: 9, recoverTicks: 10, rangeTiles: 1,
    damage: 14, spread: 6),
  AbilitySpec(windupTicks: 8, recoverTicks: 8, cooldownTicks: 72,
    rangeTiles: 2, damage: 18, spread: 8),
  AbilitySpec(windupTicks: 3, cooldownTicks: 64),
  AbilitySpec(windupTicks: 6, recoverTicks: 5, cooldownTicks: 180,
    rangeTiles: 3),
  AbilitySpec(windupTicks: 12, recoverTicks: 12, cooldownTicks: 96,
    rangeTiles: 1, damage: 28, spread: 8),
  AbilitySpec(windupTicks: 4, cooldownTicks: 80),
  AbilitySpec(windupTicks: 14, recoverTicks: 14, cooldownTicks: 48,
    manaCost: 18, rangeTiles: 6, damage: 30, spread: 10),
  AbilitySpec(windupTicks: 8, recoverTicks: 6, cooldownTicks: 120,
    manaCost: 14, rangeTiles: 3),
  AbilitySpec(windupTicks: 16, recoverTicks: 14, cooldownTicks: 72,
    manaCost: 22, rangeTiles: 8, damage: 36, spread: 12),
  AbilitySpec(windupTicks: 5, recoverTicks: 5, cooldownTicks: 80,
    rangeTiles: 1, damage: 16, spread: 5),
  AbilitySpec(windupTicks: 9, recoverTicks: 7, cooldownTicks: 36,
    rangeTiles: 7, damage: 14, spread: 6),
  AbilitySpec(windupTicks: 6, recoverTicks: 6, cooldownTicks: 48,
    rangeTiles: 1, damage: 20, spread: 6),
  AbilitySpec(windupTicks: 4, cooldownTicks: 90),
  AbilitySpec(windupTicks: 12, recoverTicks: 10, cooldownTicks: 300,
    manaCost: 22, rangeTiles: 4, damage: -90),
  AbilitySpec(windupTicks: 10, recoverTicks: 8, cooldownTicks: 240,
    manaCost: 16, rangeTiles: 4),
  AbilitySpec(windupTicks: 12, recoverTicks: 10, cooldownTicks: 180,
    manaCost: 20, rangeTiles: 6, damage: 24, spread: 8)
]

type
  Actor* = ref object
    ## Heroes occupy slots 0 ..< PartySize; monsters follow. A slot with
    ## `id == 0` is a tombstone and is reused deterministically.
    id*: int32
    kind*: ActorKind
    class*: uint8              ## HeroClass for heroes, Species for monsters
    home*: TileRef             ## the tile this actor occupies and claims
    next*: TileRef             ## step destination; equals home when still
    phase*: int32              ## 0 ..< stepUnits
    stepUnits*: int32          ## cost of the step in progress
    speed*: int32              ## phase units per tick, after encumbrance
    baseSpeed*: int32
    facing*: Facing
    body*: Body
    hp*, maxHp*: int16
    mana*, maxMana*: int16
    action*: Ability
    actionTicks*: int16
    target*: int32             ## actor or item id, depending on the action
    cooldowns*: array[AbilityCount, int16]
    inventory*: array[InventorySlots, int32]  ## item ids, 0 empty
    carriedWeight*: int32
    carriedValue*: int32
    sinceHitTicks*: int16      ## saturates; drives a client-only flinch
    slowTicks*: int16
    guardTicks*: int16
    deathTicks*: int16
    state*: MonsterState
    stateTicks*: int16
    path*: seq[PathStep]
    pathIndex*: int32
    stuckTicks*: int16
    hasteTicks*: int16

## Items, doors, chat

type
  LootKind* = enum
    ## Floor drops. Treasure kinds only add gold. Gear kinds also fill Q or E.
    GoldPile,
    Gemstone,
    Chalice,
    Idol,
    Crown,
    HealingPotionLoot,
    ManaPotionLoot,
    BattleHornLoot,
    WingedBootLoot,
    IronFlailLoot,
    InfernoAegisLoot,
    BlazingBladeLoot,
    IceWallLoot,
    LightningStormLoot,
    ArcaneMeteorLoot,
    VoidBladeLoot,
    ShadowCometLoot,
    GaleSlashLoot,
    ThornRingLoot,
    FirePhoenixLoot,
    NatureTalismanLoot,
    CosmicFlareLoot

  Item* = object
    id*: int32
    kind*: LootKind
    tile*: TileRef
    carrier*: int32            ## actor id, 0 when lying on the floor
    value*: int32
    weight*: int32

  Door* = object
    id*: int32
    tile*: TileRef
    open*: bool

  ChatLine* = object
    ## Chat is simulation state: heroes read each other's lines, so it is
    ## recorded, checkpointed and hashed. Phrases are ids, never strings,
    ## because the script VM has no runtime strings.
    speaker*: int32
    phrase*: int32
    value*: int32
    tick*: int32

const
  LootValues*: array[LootKind, int32] = [
    12, 60, 140, 300, 900,
    40, 45, 80, 100,
    70, 75, 90,
    70, 110, 120,
    80, 85, 90, 70,
    100, 85, 95
  ]
  LootWeights*: array[LootKind, int32] = [
    0, 0, 0, 0, 0,
    1, 1, 2, 2,
    2, 2, 2,
    2, 2, 2,
    2, 2, 2, 1,
    2, 1, 2
  ]
  LootAbilities*: array[LootKind, Ability] = [
    NoAbility, NoAbility, NoAbility, NoAbility, NoAbility,
    HealingPotion, ManaCrystal, BattleHorn, WingedBoot,
    IronFlail, InfernoAegis, BlazingBlade,
    IceWall, LightningStorm, ArcaneMeteor,
    VoidBlade, ShadowComet, GaleSlash, ThornRing,
    FirePhoenix, NatureTalisman, CosmicFlare
  ]
  LootConsumable*: array[LootKind, bool] = [
    false, false, false, false, false,
    true, true, false, false,
    false, false, false,
    false, false, false,
    false, false, false, false,
    false, false, false
  ]
  HeroAbilities*: array[HeroClass, array[4, Ability]] = [
    [FirebrandSword, MoltenFist, LionGuard, BlazingBlade],
    [MeteorStrike, FrostLance, VoidPortal, LightningStorm],
    [VenomDagger, VerdantArrow, ShadowCloak, GaleSlash],
    [SolarHammer, HealingBloom, AngelicEmblem, SunOrb]
  ]
  UsableLoot*: array[17, LootKind] = [
    HealingPotionLoot, ManaPotionLoot, BattleHornLoot, WingedBootLoot,
    IronFlailLoot, InfernoAegisLoot, BlazingBladeLoot,
    IceWallLoot, LightningStormLoot, ArcaneMeteorLoot,
    VoidBladeLoot, ShadowCometLoot, GaleSlashLoot, ThornRingLoot,
    FirePhoenixLoot, NatureTalismanLoot, CosmicFlareLoot
  ]

## Class tuning

const
  # Heroes are outfits of the modular character pack: one shared glb, one
  # manifest preset per class (knight with shield, wizard, hooded archer,
  # templar with the cross helm).
  HeroModelPath* = DataRoot & "/characters/modular_chars/character.glb"
  HeroManifestPath* = DataRoot & "/characters/modular_chars/manifest.json"
  ClassPresets*: array[HeroClass, string] = [
    "Preset 5", "Preset 18", "Preset 11", "Preset 9"
  ]
  ClassSpeeds*: array[HeroClass, int32] = [250, 260, 340, 270]
  ClassHp*: array[HeroClass, int16] = [340, 200, 250, 270]
  ClassMana*: array[HeroClass, int16] = [0, 160, 40, 180]
  ClassDamage*: array[HeroClass, int32] = [150, 125, 135, 100]
    ## Percentage of base ability damage, so one table tunes how hard the
    ## party hits without touching the ability timings the client animates to.
  ClassCarryWeight*: array[HeroClass, int32] = [120, 45, 70, 80]
  ClassLightRadius*: array[HeroClass, int32] = [6, 8, 5, 6]

  SpeciesModels*: array[Species, string] = [
    DataRoot & "/characters/orc.glb",
    DataRoot & "/characters/footman.glb",
    DataRoot & "/characters/lich.glb",
    DataRoot & "/characters/rock_golem.glb"
  ]
  SpeciesSpeeds*: array[Species, int32] = [300, 220, 200, 140]
  SpeciesHp*: array[Species, int16] = [90, 60, 130, 260]
  SpeciesSight*: array[Species, int32] = [9, 6, 10, 5]
  SpeciesDamage*: array[Species, int32] = [70, 55, 80, 110]
    ## Percentage of the base ability damage. Monsters hit for less than a
    ## hero would with the same swing: four heroes against a floor's worth of
    ## monsters lose a straight damage race, and the party is meant to be
    ## able to reach the vault and come back.

  RegenerationIdleTicks* = 72'i16    ## calm needed before wounds close
  RegenerationPeriodTicks* = 12'i32  ## how often a point of healing lands
  RegenerationPercent* = 4'i32       ## of maximum, per period

  EncumbranceScale*: array[4, int32] = [100, 85, 70, 50]
    ## Speed multiplier per encumbrance step, recomputed only when the
    ## inventory changes rather than divided out every tick.

## Run configuration and outcome

type
  Phase* = enum
    DescendingPhase, ReturningPhase, EscapedPhase, WipedPhase

  Outcome* = enum
    RunningOutcome, WipedOutcome, EscapedOutcome, TimedOutOutcome

  PartyMember* = object
    id*: int32
    class*: HeroClass

  Setup* = object
    ## Immutable for the whole run, and byte-identical to the replay's setup
    ## record, so `newWorld(setup)` is total and needs nothing else.
    seed*: int32
    mapVersion*: uint16
    tickRate*: uint16
    gridTiles*: uint16
    levels*: uint8
    decisionTicks*: uint16
    hashIntervalTicks*: uint16
    maximumTicks*: uint32
    party*: array[PartySize, PartyMember]
    mapHash*: uint64

## The world

type World* = ref object
  ## Everything the simulation may read or write. Adding a field here means
  ## `hashy(world[])` changes, and `tests/test_cta_sim.nim` fails until the
  ## new field is intentional. Actors are refs; see the module header.
  setup*: Setup
  tick*: int32
  rng*: Rng
  turnStart*: int32                        ## rotating bot decision order
  actors*: seq[Actor]
  items*: seq[Item]
  doors*: seq[Door]
  claims*: seq[uint16]                     ## tile -> actor slot + 1, 0 free
  explored*: seq[uint8]                    ## one bit per tile, party-shared
  visible*: array[PartySize, seq[uint8]]   ## one bit per tile, per hero
  chat*: array[ChatLines, ChatLine]
  chatHead*: int32
  banked*: int32
  phase*: Phase
  deepest*: int32
  respawnTicks*: int32
  killed*: int32
  collected*: int32
  outcome*: Outcome
  nextActorId*: int32
  nextItemId*: int32

## Small helpers on the types above

proc lootUsesSlot*(kind: LootKind): bool =
  ## True when this drop occupies a Q or E slot after pickup.
  LootAbilities[kind] != NoAbility

proc tileIndex*(tile: TileRef): int32 =
  ## Flat index into `claims`, `explored`, and the visibility bitmaps.
  int32(tile.level) * TilesPerLevel + int32(tile.z) * GridTiles + int32(tile.x)

proc `==`*(a, b: TileRef): bool =
  a.level == b.level and a.x == b.x and a.z == b.z

template moving*(actor: Actor): bool =
  ## True while a string-pulled path still has a waypoint to walk.
  actor.path.len > 0 and actor.pathIndex < int32(actor.path.len)

template alive*(actor: Actor): bool =
  ## True while this slot holds a living actor.
  actor.id != 0 and actor.hp > 0

template busy*(actor: Actor): bool =
  ## True while an ability is winding up or recovering.
  actor.action != NoAbility

template heroClass*(actor: Actor): HeroClass =
  ## Reads a hero's class without copying the actor.
  HeroClass(actor.class)

template species*(actor: Actor): Species =
  ## Reads a monster's species without copying the actor.
  Species(actor.class)

proc encumbrance*(actor: Actor, capacity: int32): int32 =
  ## Zero to three, used to index `EncumbranceScale`.
  if capacity <= 0:
    return 0
  min(actor.carriedWeight * 4 div capacity, 3)

template carryCapacity*(actor: Actor): int32 =
  ## Hero carry limit after class lookup, or zero for monsters.
  if actor.kind == HeroActor:
    ClassCarryWeight[actor.heroClass]
  else:
    0

proc opposite*(facing: Facing): Facing =
  Facing((facing.ord + 2) mod 4)
