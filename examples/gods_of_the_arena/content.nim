## Deterministic Gods of the Arena hero classes and their integer tuning.
## Graphics attach models and portraits to these identities separately.

import polyworld/cli

const
  InventorySlots* = 6
  TickRate* = SharedTickRate
    ## Simulation ticks per second.

type
  HeroClass* = enum
    VanguardKnight,
    Ranger,
    Arcanist,
    DruidWarden,
    DemonHunter,
    DeathKnight,
    Crossbowman,
    Lich,
    Warlock,
    Berserker
  HeroAttackStyle* = enum
    MeleeAttack,
    RangedAttack,
    MagicAttack
  HeroAbilitySlot* = enum
    PassiveAbility,
    PrimaryAbility,
    SecondaryAbility,
    UltimateAbility
  Ability* = enum
    LionGuard, FirebrandSword, InfernoAegis, BlazingBlade,
    DragonSight, VerdantArrow, RicochetDisc, StormEagle,
    ManaCrystal, FrostLance, MeteorStrike, ArcaneMeteor,
    NatureTalisman, HealingBloom, KindredWisps, GolemSeed,
    ShadowCloak, VoidBlade, GaleSlash, ShadowComet,
    SanguineChalice, AfterlightSickle, WitheringIdol, DarkEclipse,
    FinalMeasure, SiegeScarab, LodestoneSurge, ClockworkCharge,
    FrostSigil, IceSpear, BoneMarionette, BoundVoid,
    AetherSiphon, MothHex, DreadTotem, VoidPortal,
    RageCrucible, MoltenFist, WingedBoot, VolcanicEruption
  AbilityKind* = enum
    Strike, Heal, Restore
  HeroSpec* = object
    name*: string
    role*: string
    attackStyle*: HeroAttackStyle
    baseHitPoints*: int32
    hitPointsPerLevel*: int32
    baseMana*: int32
    manaPerLevel*: int32
    baseDamage*: int32
    damagePerLevel*: int32
    baseMovePerTick*: int32
    movePerLevel*: int32
    attackRange*: int32
    attackTicks*: int32
    abilities*: array[HeroAbilitySlot, Ability]
  AbilitySpec* = object
    name*: string
    icon*: string
    kind*: AbilityKind
    cooldownTicks*: int32
    manaCost*: int32
    range*: int32
    damage*: int32
    heal*: int32
    restore*: int32
  Item* = enum
    NoItem,
    IronrootRation,
    VitalityElixir,
    ManaPotion,
    PoisonPotion,
    SteelHelmet,
    SteelBuckler,
    LeatherGauntlets,
    RangerBoots,
    RubyAmulet,
    SapphireRing,
    CrimsonDagger,
    AmethystWand,
    SunsteelLongsword,
    RangerBow,
    IronbarkPauldrons,
    KnightArmor,
    ThornwoodStaff,
    BattleAxe,
    RuneCrossbow,
    ArcaneSpellbook
  ItemKind* = enum
    Consumable, Equipment
  ItemSpec* = object
    name*: string
    icon*: string
    kind*: ItemKind
    cost*: int32
    maxHp*: int32
    maxMana*: int32
    damage*: int32
    movePerTick*: int32
    heal*: int32
    restore*: int32
    strike*: int32

const
  MaxItemStack* = 8
  HeroClassCount* = HeroClass.high.ord + 1
  HeroClassesPerTeam* = 5
  RedHeroClasses*: array[HeroClassesPerTeam, HeroClass] = [
    DeathKnight,
    Crossbowman,
    Lich,
    Warlock,
    Berserker
  ]
  BlueHeroClasses*: array[HeroClassesPerTeam, HeroClass] = [
    VanguardKnight,
    Ranger,
    Arcanist,
    DruidWarden,
    DemonHunter
  ]
  HeroSpecs*: array[HeroClass, HeroSpec] = [
    HeroSpec(
      name: "Vanguard Knight",
      role: "Frontline protector",
      attackStyle: MeleeAttack,
      baseHitPoints: 330,
      hitPointsPerLevel: 60,
      baseMana: 110,
      manaPerLevel: 8,
      baseDamage: 25,
      damagePerLevel: 5,
      baseMovePerTick: 5_800,
      movePerLevel: 60,
      attackRange: 70_000,
      attackTicks: 26,
      abilities: [
        LionGuard, FirebrandSword, InfernoAegis, BlazingBlade
      ]
    ),
    HeroSpec(
      name: "Ranger",
      role: "Mobile ranged carry",
      attackStyle: RangedAttack,
      baseHitPoints: 210,
      hitPointsPerLevel: 38,
      baseMana: 110,
      manaPerLevel: 8,
      baseDamage: 25,
      damagePerLevel: 6,
      baseMovePerTick: 6_900,
      movePerLevel: 90,
      attackRange: 330_000,
      attackTicks: 18,
      abilities: [
        DragonSight, VerdantArrow, RicochetDisc, StormEagle
      ]
    ),
    HeroSpec(
      name: "Arcanist",
      role: "Burst mage",
      attackStyle: MagicAttack,
      baseHitPoints: 190,
      hitPointsPerLevel: 30,
      baseMana: 180,
      manaPerLevel: 15,
      baseDamage: 38,
      damagePerLevel: 8,
      baseMovePerTick: 6_200,
      movePerLevel: 70,
      attackRange: 300_000,
      attackTicks: 30,
      abilities: [
        ManaCrystal, FrostLance, MeteorStrike, ArcaneMeteor
      ]
    ),
    HeroSpec(
      name: "Druid Warden",
      role: "Durable support",
      attackStyle: MagicAttack,
      baseHitPoints: 250,
      hitPointsPerLevel: 48,
      baseMana: 170,
      manaPerLevel: 14,
      baseDamage: 22,
      damagePerLevel: 4,
      baseMovePerTick: 6_400,
      movePerLevel: 70,
      attackRange: 240_000,
      attackTicks: 26,
      abilities: [
        NatureTalisman, HealingBloom, KindredWisps, GolemSeed
      ]
    ),
    HeroSpec(
      name: "Demon Hunter",
      role: "Melee assassin",
      attackStyle: MeleeAttack,
      baseHitPoints: 220,
      hitPointsPerLevel: 36,
      baseMana: 90,
      manaPerLevel: 7,
      baseDamage: 32,
      damagePerLevel: 7,
      baseMovePerTick: 7_600,
      movePerLevel: 120,
      attackRange: 75_000,
      attackTicks: 16,
      abilities: [
        ShadowCloak, VoidBlade, GaleSlash, ShadowComet
      ]
    ),
    HeroSpec(
      name: "Death Knight",
      role: "Sustaining bruiser",
      attackStyle: MeleeAttack,
      baseHitPoints: 350,
      hitPointsPerLevel: 62,
      baseMana: 90,
      manaPerLevel: 8,
      baseDamage: 30,
      damagePerLevel: 6,
      baseMovePerTick: 5_700,
      movePerLevel: 60,
      attackRange: 76_000,
      attackTicks: 28,
      abilities: [
        SanguineChalice, AfterlightSickle, WitheringIdol, DarkEclipse
      ]
    ),
    HeroSpec(
      name: "Crossbowman",
      role: "Heavy ranged carry",
      attackStyle: RangedAttack,
      baseHitPoints: 230,
      hitPointsPerLevel: 42,
      baseMana: 80,
      manaPerLevel: 6,
      baseDamage: 43,
      damagePerLevel: 8,
      baseMovePerTick: 6_000,
      movePerLevel: 60,
      attackRange: 390_000,
      attackTicks: 36,
      abilities: [
        FinalMeasure, SiegeScarab, LodestoneSurge, ClockworkCharge
      ]
    ),
    HeroSpec(
      name: "Lich",
      role: "Control mage",
      attackStyle: MagicAttack,
      baseHitPoints: 185,
      hitPointsPerLevel: 28,
      baseMana: 210,
      manaPerLevel: 17,
      baseDamage: 36,
      damagePerLevel: 8,
      baseMovePerTick: 6_000,
      movePerLevel: 60,
      attackRange: 330_000,
      attackTicks: 32,
      abilities: [
        FrostSigil, IceSpear, BoneMarionette, BoundVoid
      ]
    ),
    HeroSpec(
      name: "Warlock",
      role: "Utility summoner",
      attackStyle: MagicAttack,
      baseHitPoints: 240,
      hitPointsPerLevel: 46,
      baseMana: 190,
      manaPerLevel: 16,
      baseDamage: 26,
      damagePerLevel: 5,
      baseMovePerTick: 6_200,
      movePerLevel: 70,
      attackRange: 270_000,
      attackTicks: 28,
      abilities: [
        AetherSiphon, MothHex, DreadTotem, VoidPortal
      ]
    ),
    HeroSpec(
      name: "Berserker",
      role: "Aggressive melee carry",
      attackStyle: MeleeAttack,
      baseHitPoints: 300,
      hitPointsPerLevel: 55,
      baseMana: 40,
      manaPerLevel: 4,
      baseDamage: 35,
      damagePerLevel: 7,
      baseMovePerTick: 6_800,
      movePerLevel: 90,
      attackRange: 80_000,
      attackTicks: 20,
      abilities: [
        RageCrucible, MoltenFist, WingedBoot, VolcanicEruption
      ]
    )
  ]
  AbilitySpecs*: array[Ability, AbilitySpec] = [
    AbilitySpec(
      name: "Lion Guard", icon: "lion_guard",
      kind: Heal, cooldownTicks: 192, heal: 28
    ),
    AbilitySpec(
      name: "Firebrand Sword", icon: "firebrand_sword",
      kind: Strike, cooldownTicks: 96, manaCost: 20,
      range: 90_000, damage: 40
    ),
    AbilitySpec(
      name: "Inferno Aegis", icon: "inferno_aegis",
      kind: Heal, cooldownTicks: 240, manaCost: 35, heal: 50
    ),
    AbilitySpec(
      name: "Blazing Blade", icon: "blazing_blade",
      kind: Strike, cooldownTicks: 480, manaCost: 70,
      range: 110_000, damage: 90
    ),
    AbilitySpec(
      name: "Dragon Sight", icon: "dragon_sight",
      kind: Strike, cooldownTicks: 216,
      range: 420_000, damage: 16
    ),
    AbilitySpec(
      name: "Verdant Arrow", icon: "verdant_arrow",
      kind: Strike, cooldownTicks: 72, manaCost: 18,
      range: 360_000, damage: 32
    ),
    AbilitySpec(
      name: "Ricochet Disc", icon: "ricochet_disc",
      kind: Strike, cooldownTicks: 192, manaCost: 32,
      range: 390_000, damage: 48
    ),
    AbilitySpec(
      name: "Storm Eagle", icon: "storm_eagle",
      kind: Strike, cooldownTicks: 576, manaCost: 80,
      range: 480_000, damage: 95
    ),
    AbilitySpec(
      name: "Mana Crystal", icon: "mana_crystal",
      kind: Restore, cooldownTicks: 144, restore: 28
    ),
    AbilitySpec(
      name: "Frost Lance", icon: "frost_lance",
      kind: Strike, cooldownTicks: 96, manaCost: 28,
      range: 330_000, damage: 42
    ),
    AbilitySpec(
      name: "Meteor Strike", icon: "meteor_strike",
      kind: Strike, cooldownTicks: 216, manaCost: 50,
      range: 360_000, damage: 70
    ),
    AbilitySpec(
      name: "Arcane Meteor", icon: "arcane_meteor",
      kind: Strike, cooldownTicks: 600, manaCost: 100,
      range: 420_000, damage: 120
    ),
    AbilitySpec(
      name: "Nature Talisman", icon: "nature_talisman",
      kind: Heal, cooldownTicks: 192, heal: 22
    ),
    AbilitySpec(
      name: "Healing Bloom", icon: "healing_bloom",
      kind: Heal, cooldownTicks: 168, manaCost: 30, heal: 55
    ),
    AbilitySpec(
      name: "Kindred Wisps", icon: "kindred_wisps",
      kind: Heal, cooldownTicks: 288, manaCost: 45, heal: 80
    ),
    AbilitySpec(
      name: "Golem Seed", icon: "golem_seed",
      kind: Strike, cooldownTicks: 528, manaCost: 75,
      range: 200_000, damage: 85
    ),
    AbilitySpec(
      name: "Shadow Cloak", icon: "shadow_cloak",
      kind: Heal, cooldownTicks: 240, heal: 18
    ),
    AbilitySpec(
      name: "Void Blade", icon: "void_blade",
      kind: Strike, cooldownTicks: 80, manaCost: 16,
      range: 90_000, damage: 38
    ),
    AbilitySpec(
      name: "Gale Slash", icon: "gale_slash",
      kind: Strike, cooldownTicks: 168, manaCost: 28,
      range: 120_000, damage: 52
    ),
    AbilitySpec(
      name: "Shadow Comet", icon: "shadow_comet",
      kind: Strike, cooldownTicks: 504, manaCost: 65,
      range: 300_000, damage: 100
    ),
    AbilitySpec(
      name: "Sanguine Chalice", icon: "sanguine_chalice",
      kind: Heal, cooldownTicks: 192, heal: 26
    ),
    AbilitySpec(
      name: "Afterlight Sickle", icon: "afterlight_sickle",
      kind: Strike, cooldownTicks: 108, manaCost: 18,
      range: 90_000, damage: 42
    ),
    AbilitySpec(
      name: "Withering Idol", icon: "withering_idol",
      kind: Strike, cooldownTicks: 216, manaCost: 36,
      range: 160_000, damage: 60
    ),
    AbilitySpec(
      name: "Dark Eclipse", icon: "dark_eclipse",
      kind: Strike, cooldownTicks: 624, manaCost: 80,
      range: 140_000, damage: 110
    ),
    AbilitySpec(
      name: "Final Measure", icon: "final_measure",
      kind: Strike, cooldownTicks: 216,
      range: 420_000, damage: 20
    ),
    AbilitySpec(
      name: "Siege Scarab", icon: "siege_scarab",
      kind: Strike, cooldownTicks: 120, manaCost: 22,
      range: 400_000, damage: 50
    ),
    AbilitySpec(
      name: "Lodestone Surge", icon: "lodestone_surge",
      kind: Strike, cooldownTicks: 240, manaCost: 40,
      range: 360_000, damage: 68
    ),
    AbilitySpec(
      name: "Clockwork Charge", icon: "clockwork_charge",
      kind: Strike, cooldownTicks: 552, manaCost: 70,
      range: 450_000, damage: 115
    ),
    AbilitySpec(
      name: "Frost Sigil", icon: "frost_sigil",
      kind: Strike, cooldownTicks: 192,
      range: 360_000, damage: 14
    ),
    AbilitySpec(
      name: "Ice Spear", icon: "ice_spear",
      kind: Strike, cooldownTicks: 96, manaCost: 30,
      range: 360_000, damage: 44
    ),
    AbilitySpec(
      name: "Bone Marionette", icon: "bone_marionette",
      kind: Strike, cooldownTicks: 216, manaCost: 48,
      range: 300_000, damage: 66
    ),
    AbilitySpec(
      name: "Bound Void", icon: "bound_void",
      kind: Strike, cooldownTicks: 648, manaCost: 110,
      range: 390_000, damage: 125
    ),
    AbilitySpec(
      name: "Aether Siphon", icon: "aether_siphon",
      kind: Restore, cooldownTicks: 168, restore: 22
    ),
    AbilitySpec(
      name: "Moth Hex", icon: "moth_hex",
      kind: Strike, cooldownTicks: 96, manaCost: 24,
      range: 280_000, damage: 36
    ),
    AbilitySpec(
      name: "Dread Totem", icon: "dread_totem",
      kind: Strike, cooldownTicks: 216, manaCost: 42,
      range: 240_000, damage: 58
    ),
    AbilitySpec(
      name: "Void Portal", icon: "void_portal",
      kind: Strike, cooldownTicks: 576, manaCost: 90,
      range: 300_000, damage: 105
    ),
    AbilitySpec(
      name: "Rage Crucible", icon: "rage_crucible",
      kind: Heal, cooldownTicks: 192, heal: 20
    ),
    AbilitySpec(
      name: "Molten Fist", icon: "molten_fist",
      kind: Strike, cooldownTicks: 84, manaCost: 8,
      range: 90_000, damage: 45
    ),
    AbilitySpec(
      name: "Winged Boot", icon: "winged_boot",
      kind: Strike, cooldownTicks: 192, manaCost: 12,
      range: 150_000, damage: 40
    ),
    AbilitySpec(
      name: "Volcanic Eruption", icon: "volcanic_eruption",
      kind: Strike, cooldownTicks: 480, manaCost: 24,
      range: 130_000, damage: 100
    )
  ]
  ItemSpecs*: array[Item, ItemSpec] = [
    ItemSpec(),
    ItemSpec(
      name: "Ironroot Ration", icon: "ironroot_ration",
      kind: Consumable, cost: 30, heal: 40
    ),
    ItemSpec(
      name: "Vitality Elixir", icon: "vitality_elixir",
      kind: Consumable, cost: 50, heal: 90
    ),
    ItemSpec(
      name: "Mana Potion", icon: "mana_potion",
      kind: Consumable, cost: 45, restore: 60
    ),
    ItemSpec(
      name: "Poison Potion", icon: "poison_potion",
      kind: Consumable, cost: 40, strike: 35
    ),
    ItemSpec(
      name: "Steel Helmet", icon: "steel_helmet",
      kind: Equipment, cost: 80, maxHp: 50
    ),
    ItemSpec(
      name: "Steel Buckler", icon: "steel_buckler",
      kind: Equipment, cost: 90, maxHp: 60
    ),
    ItemSpec(
      name: "Leather Gauntlets", icon: "leather_gauntlets",
      kind: Equipment, cost: 70, damage: 4
    ),
    ItemSpec(
      name: "Ranger Boots", icon: "ranger_boots",
      kind: Equipment, cost: 100, movePerTick: 800
    ),
    ItemSpec(
      name: "Ruby Amulet", icon: "ruby_amulet",
      kind: Equipment, cost: 120, maxHp: 70
    ),
    ItemSpec(
      name: "Sapphire Ring", icon: "sapphire_ring",
      kind: Equipment, cost: 120, maxMana: 40
    ),
    ItemSpec(
      name: "Crimson Dagger", icon: "crimson_dagger",
      kind: Equipment, cost: 110, damage: 8
    ),
    ItemSpec(
      name: "Amethyst Wand", icon: "amethyst_wand",
      kind: Equipment, cost: 140, damage: 9
    ),
    ItemSpec(
      name: "Sunsteel Longsword", icon: "sunsteel_longsword",
      kind: Equipment, cost: 150, damage: 10
    ),
    ItemSpec(
      name: "Ranger Bow", icon: "ranger_bow",
      kind: Equipment, cost: 150, damage: 10
    ),
    ItemSpec(
      name: "Ironbark Pauldrons", icon: "ironbark_pauldrons",
      kind: Equipment, cost: 140, maxHp: 80
    ),
    ItemSpec(
      name: "Knight Armor", icon: "knight_armor",
      kind: Equipment, cost: 160, maxHp: 120
    ),
    ItemSpec(
      name: "Thornwood Staff", icon: "thornwood_staff",
      kind: Equipment, cost: 170, maxHp: 40, damage: 6
    ),
    ItemSpec(
      name: "Battle Axe", icon: "battle_axe",
      kind: Equipment, cost: 180, damage: 14
    ),
    ItemSpec(
      name: "Rune Crossbow", icon: "rune_crossbow",
      kind: Equipment, cost: 180, damage: 14
    ),
    ItemSpec(
      name: "Arcane Spellbook", icon: "arcane_spellbook",
      kind: Equipment, cost: 190, maxMana: 30, damage: 12
    )
  ]

proc heroClassForTeam*(team, slot: int): HeroClass =
  ## Assigns one of five stable class identities to a team's local slot.
  if team == 0:
    RedHeroClasses[slot mod HeroClassesPerTeam]
  else:
    BlueHeroClasses[slot mod HeroClassesPerTeam]

proc heroSpec*(class: HeroClass): HeroSpec =
  ## Returns the immutable integer tuning for one hero class.
  HeroSpecs[class]

proc abilitySpec*(ability: Ability): AbilitySpec =
  ## Returns the immutable integer tuning for one hero ability.
  AbilitySpecs[ability]

proc heroAbility*(class: HeroClass, slot: HeroAbilitySlot): Ability =
  ## Returns the ability bound to one class slot.
  class.heroSpec.abilities[slot]

proc abilityIconKey*(ability: Ability): string =
  ## Returns the atlas name packed from one ability art file.
  "ability_" & ability.abilitySpec.icon

proc itemSpec*(item: Item): ItemSpec =
  ## Returns the immutable shop tuning for one item.
  ItemSpecs[item]

proc itemFromId*(id: int32): Item =
  ## Maps a BASIC item id onto the shop catalog.
  if id <= 0 or id > int32(Item.high.ord):
    NoItem
  else:
    Item(id)

proc itemIconKey*(item: Item): string =
  ## Returns the atlas name packed from one item art file.
  if item == NoItem:
    return ""
  "item_" & item.itemSpec.icon

proc heroMaxHp*(class: HeroClass, level: int): int32 =
  ## Returns class hit points at one level.
  let spec = class.heroSpec
  spec.baseHitPoints + int32(level - 1) * spec.hitPointsPerLevel

proc heroMaxMana*(class: HeroClass, level: int): int32 =
  ## Returns class mana at one level.
  let spec = class.heroSpec
  spec.baseMana + int32(level - 1) * spec.manaPerLevel

proc heroDamage*(class: HeroClass, level: int): int32 =
  ## Returns class basic-attack damage at one level.
  let spec = class.heroSpec
  spec.baseDamage + int32(level - 1) * spec.damagePerLevel

proc heroMovePerTick*(class: HeroClass, level: int): int32 =
  ## Returns class movement distance for one authoritative tick.
  let spec = class.heroSpec
  spec.baseMovePerTick + int32(level - 1) * spec.movePerLevel

proc heroAttackRange*(class: HeroClass): int32 =
  ## Returns class basic-attack range in integer world units.
  class.heroSpec.attackRange

proc heroAttackTicks*(class: HeroClass): int32 =
  ## Returns the class basic-attack period in simulation ticks.
  class.heroSpec.attackTicks
