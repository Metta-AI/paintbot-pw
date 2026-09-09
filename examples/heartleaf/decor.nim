## Heartleaf decorations: the props that dress the village. Purely visual
## and derived from nothing but the generated map and its seed, so a live
## game and its replay dress identically. Nothing here reaches the sim.

import
  std/[math, sets],
  vmath,
  polyworld/[pathing, rngs],
  content,
  maps

type
  DecorKit* = enum
    MeadowProps, MeadowVegetation, MeadowBuildings, MeadowRocks, ValleyProps,
    ValleyVegetation, ValleyBuildings

  DecorArea* = enum
    PlazaArea, HouseArea, GardenArea, RoadArea, MeadowArea, OutskirtsArea

  Decoration* = object
    kit*: DecorKit
    node*: string
    area*: DecorArea
    x*, y*: float32
      ## Tile space; a tile centre is its index plus one half.
    tile*: Tile2
      ## The tile this decoration claimed, which a shifted prop may lean
      ## out of. Plaza props claim nothing and leave it at the centre.
    lift*: float32
      ## Tiles above the ground, for pieces that sit on other pieces.
    yaw*: float32
    height*: float32
      ## Tiles tall. The prop loader normalises models to unit height, so
      ## this is the placement scale.
    tint*: Vec3
      ## Multiplies the paint of textured props; one for as authored.

  Placer = object
    map: MapData
    rng: Rng
    used: HashSet[int32]
    placed: seq[Decoration]

const
  DecorSalt = 0xDEC0'u64
  PlazaDressRadius = 5.5'f32
  PlazaSignRadius = 10.5'f32
  PlazaLimit* = 7.5'f32
    ## Everything placed on the plaza sits within this many tiles of its
    ## centre; the curb starts at eight.
  WellHeight = 2.6'f32
  StallHeight = 1.6'f32
  CanopyLift = 1.45'f32
  CanopyHeight = 0.6'f32
  CrateHeight = 0.35'f32
  BenchHeight = 0.6'f32
  TableHeight = 0.6'f32
  LampHeight = 2.8'f32
  CartHeight = 1.3'f32
  BarrelHeight = 0.8'f32
  SackHeight = 0.7'f32
  BoxHeight = 0.5'f32
  SignPoleHeight = 1.7'f32
  SignBoardHeight = 0.2'f32
    ## The valley sign is only the board; it hangs on a meadow fence pole.
  SignBoardLift = 1.25'f32
  LampOneIn = 30'i32
  LampSpacing = 7'i32
    ## Lamp posts stand on road verges this many tiles apart at least.
  MailboxHeight = 1.1'f32
  PotHeight = 0.4'f32
  GardenPotHeight* = 0.5'f32
  GardenCropLift* = GardenPotHeight * 0.8'f32
  GardenPots* = ["flower_pot_01a", "flower_pot_03a", "flower_pot_04a"]
  FlowerHeight = 0.6'f32
  BushHeight = 1.8'f32
  TuftHeight = 0.55'f32
  SmallRockHeight = 0.85'f32
  RoadRockLimit = 4
  ForestRockLimit = 8
  ForestRockHeight = 1.1'f32
  HouseFlowerBeds = 5
  HouseBushes = 2
  HouseDecorReach = 4'i32
  HouseHalf = 2'i32
    ## Half the five-tile house footprint; the door sits one past it.
  HouseBushClearance* = 2'i32
    ## Bushes stay this many tiles beyond every doorstep.
  HouseDecorAttempts = 20
  GardenFlowerOneIn = 1'i32
  RoadDecorOneIn = 2'i32
  NaturalVariance = 0.45'f32
    ## Things that grew or were left lying vary this much in size either
    ## way. Things gnomes made, signs, lamps, fences, do not.
  PlantShade = 0.15'f32
  PlantWarmth = 0.12'f32
    ## Plants drift in brightness and between cool and warm green, so a
    ## row of bushes is not one bush.
  RockShade = 0.15'f32
  RockDrift = 0.08'f32
    ## Each rock's channels wander this much on top of the cobble match,
    ## the way the cobbles themselves vary stone to stone.
  CobbleTint = vec3(1.15, 1.03, 1.13)
    ## What the rock paint is multiplied by to land on the cobble sheet's
    ## average colour; the rock atlas is a neutral grey a shade darker.
  VergeRockSetback = 0.45'f32
    ## Tiles a verge rock is pushed away from the road.

  MeadowClusters = 95
  MeadowAttempts = 4000
  MeadowSpacing = 5'i32
  VillagePlantRadius = 32'i32
  MeadowTreeHeight = 3.2'f32
  MeadowTreeEvery = 4
  MeadowBushHeight = 0.8'f32
  ForestTransitionStart = 36'i32
  ForestTransitionOneIn = 4'i32
  MeadowUnderplanting = 14
  MeadowPlantReach = 3'i32
  SmallTrees = ["tree_05a", "tree_06a"]

  KitFiles: array[DecorKit, string] = [
    "terrain/toon_enchanted_meadow/props.glb",
    "terrain/toon_enchanted_meadow/vegetation.glb",
    "terrain/toon_enchanted_meadow/buildings.glb",
    "terrain/toon_enchanted_meadow/rocks.glb",
    "terrain/toon_golden_valley/props.glb",
    "terrain/toon_golden_valley/vegetation.glb",
    "terrain/toon_golden_valley/buildings.glb",
  ]
  DecorNodes: array[DecorKit, seq[string]] = [
    @["market_stand_01a", "canopy_01a", "canopy_02a", "canopy_03a",
      "canopy_04a", "apple_crate_01a", "pepper_crate_01a", "lamp_post_01a",
      "wood_cart_01a", "wood_barrel_01a", "sack_pile_01a", "wood_crate_01a",
      "mailbox_01a", "flower_pot_01a", "flower_pot_03a", "flower_pot_04a",
      "wood_fence_pole_01a"],
    @["flowers_patch_01a", "flowers_patch_02a", "flowers_patch_03a",
      "flower_bush_01a", "bush_01a", "grass_patch_01a", "grass_patch_02a",
      "grass_patch_03a", "grass_patch_04a", "grass_patch_05a",
      "plant_04a", "plant_05a", "plant_06a",
      "tree_05a", "tree_06a"],
    @["wood_bench_01a", "wood_table_01a"],
    @["rock_small_01a", "rock_small_02a", "rock_small_03a", "rock_small_04a",
      "rock_medium_01a", "rock_medium_02a", "rock_medium_03a"],
    @["well_01a", "wood_sign_01a"],
    @["plant_01a", "plant_02a", "plant_03a", "plant_04a", "plant_05a",
      "plant_06a", "plant_07a", "wheat_patch_01a"],
    @[],
  ]
  Canopies = ["canopy_01a", "canopy_02a", "canopy_03a", "canopy_04a"]
  Tufts = ["grass_patch_01a", "grass_patch_02a", "grass_patch_03a",
    "grass_patch_04a", "grass_patch_05a"]
  SmallRocks = ["rock_small_01a", "rock_small_02a", "rock_small_03a",
    "rock_small_04a"]
  FlowerBeds = ["flowers_patch_01a", "flowers_patch_02a", "flowers_patch_03a"]
  Sides = [(1'i32, 0'i32), (0'i32, 1'i32), (-1'i32, 0'i32), (0'i32, -1'i32)]

proc kitFile*(kit: DecorKit): string =
  ## Path of one kit's glb under the art repo.
  KitFiles[kit]

proc nodesFor*(kit: DecorKit): seq[string] =
  ## Every node the decorations use from one kit, so the loader can skip
  ## the rest.
  DecorNodes[kit]

proc unit(rng: var Rng): float32 =
  ## One draw in 0 .. 1.
  float32(rng.below(10001)) / 10000.0'f32

proc pick[T](rng: var Rng, items: openArray[T]): T =
  ## One uniformly chosen item.
  items[rng.below(int32(items.len))]

proc plantTint(rng: var Rng): Vec3 =
  ## A slightly brighter or darker, cooler or warmer green.
  let
    shade = 1.0'f32 + (rng.unit() - 0.5'f32) * 2.0'f32 * PlantShade
    warmth = (rng.unit() - 0.5'f32) * 2.0'f32 * PlantWarmth
  vec3(
    shade * (1.0'f32 + warmth),
    shade,
    shade * (1.0'f32 - warmth))

proc rockTint(rng: var Rng): Vec3 =
  ## The cobble match, shaded a little and drifted a little per channel,
  ## so rocks scatter around the paving's colour rather than all landing
  ## on one shade of it.
  let shade = 1.0'f32 + (rng.unit() - 0.5'f32) * 2.0'f32 * RockShade
  vec3(
    CobbleTint.x + (rng.unit() - 0.5'f32) * 2.0'f32 * RockDrift,
    CobbleTint.y + (rng.unit() - 0.5'f32) * 2.0'f32 * RockDrift,
    CobbleTint.z + (rng.unit() - 0.5'f32) * 2.0'f32 * RockDrift) * shade

proc yawAlong(x, y: float32): float32 =
  ## The yaw that points a prop's forward axis along a tile-space direction,
  ## matching how the houses face their doors.
  arctan2(x, y)

proc tileFree(p: Placer, x, y: int32): bool =
  ## Plain walkable grass nobody has decorated yet.
  if not inGrid(x, y):
    return false
  let index = tileIndex(x, y)
  p.map.kinds[index] == uint8(GrassTile) and p.map.passable[index] != 0 and
    index notin p.used

proc nearRoad(p: Placer, x, y: int32): bool =
  ## A road tile within one step.
  for dy in -1'i32 .. 1'i32:
    for dx in -1'i32 .. 1'i32:
      if inGrid(x + dx, y + dy) and
          p.map.kinds[tileIndex(x + dx, y + dy)] == uint8(RoadTile):
        return true
  false

proc nearHouseDoor(p: Placer, x, y: int32): bool =
  ## Returns whether a tile is inside a house's clear front approach.
  for house in p.map.houses:
    if chebyshev(tile2(x, y), house.door) <= HouseBushClearance:
      return true
  false

proc nearTree(p: Placer, x, y: int32): bool =
  ## A forest tree tile within one step.
  for dy in -1'i32 .. 1'i32:
    for dx in -1'i32 .. 1'i32:
      if inGrid(x + dx, y + dy) and
          p.map.kinds[tileIndex(x + dx, y + dy)] == uint8(TreeTile):
        return true
  false

proc awayFromRoad(p: Placer, x, y: int32): Vec2 =
  ## Unit direction pointing away from the road tiles around one tile.
  var pull = vec2(0, 0)
  for dy in -1'i32 .. 1'i32:
    for dx in -1'i32 .. 1'i32:
      if inGrid(x + dx, y + dy) and
          p.map.kinds[tileIndex(x + dx, y + dy)] == uint8(RoadTile):
        pull -= vec2(float32(dx), float32(dy))
  if pull.length < 0.001'f32:
    return vec2(0, 0)
  pull.normalize

proc add(
    p: var Placer, kit: DecorKit, node: string, area: DecorArea,
    x, y, yaw, height: float32, lift = 0.0'f32, tint = vec3(1, 1, 1)
) =
  ## Records one decoration.
  p.placed.add Decoration(
    kit: kit, node: node, area: area, x: x, y: y,
    tile: tile2(int32(x), int32(y)), lift: lift, yaw: yaw, height: height,
    tint: tint)

proc claim(
    p: var Placer, kit: DecorKit, node: string, area: DecorArea,
    tileX, tileY: int32, yaw, height: float32, jitter = 0.0'f32,
    variance = 0.0'f32, tint = vec3(1, 1, 1), shift = vec2(0, 0)
): bool =
  ## Places one decoration on a free grass tile and marks the tile used.
  ## Jitter moves it off the tile centre by up to that many tiles, shift
  ## moves it by exactly that much, and variance scales its height by up
  ## to that fraction either way.
  if not p.tileFree(tileX, tileY):
    return false
  p.used.incl tileIndex(tileX, tileY)
  let
    offsetX = (p.rng.unit() - 0.5'f32) * 2.0'f32 * jitter + shift.x
    offsetY = (p.rng.unit() - 0.5'f32) * 2.0'f32 * jitter + shift.y
    grown = height * (1.0'f32 + (p.rng.unit() - 0.5'f32) * 2.0'f32 * variance)
  p.add(kit, node, area,
    float32(tileX) + 0.5'f32 + offsetX, float32(tileY) + 0.5'f32 + offsetY,
    yaw, grown, 0.0, tint)
  p.placed[^1].tile = tile2(tileX, tileY)
  true

proc dressPlaza(p: var Placer) =
  ## The well, and one dressing in each sector between road entrances.
  let centre = float32(GridSide div 2) + 0.5'f32
  p.add(ValleyProps, "well_01a", PlazaArea, centre, centre, 0.0, WellHeight)
  var angles: seq[float32]
  for house in p.map.houses:
    angles.add arctan2(
      float32(house.center.y) + 0.5'f32 - centre,
      float32(house.center.x) + 0.5'f32 - centre)
  for i in 1 ..< angles.len:
    for j in countdown(i, 1):
      if angles[j] < angles[j - 1]:
        swap(angles[j], angles[j - 1])
  for i, entrance in angles:
    let
      next = if i + 1 < angles.len: angles[i + 1] else: angles[0] + 2 * PI
      mid = (entrance + next) * 0.5'f32
      x = centre + cos(mid) * PlazaDressRadius
      y = centre + sin(mid) * PlazaDressRadius
      facing = yawAlong(centre - x, centre - y)
      sideways = facing + PI / 2
        ## Long props lie across the sector rather than pointing inward.
      tangentX = -sin(mid)
      tangentY = cos(mid)
      outwardX = cos(mid)
      outwardY = sin(mid)
    case i mod 5
    of 0:
      p.add(MeadowProps, "market_stand_01a", PlazaArea, x, y, facing,
        StallHeight)
      p.add(MeadowProps, p.rng.pick(Canopies), PlazaArea, x, y, facing,
        CanopyHeight, CanopyLift)
      p.add(MeadowProps, "apple_crate_01a", PlazaArea,
        x + tangentX * 0.9'f32, y + tangentY * 0.9'f32, facing, CrateHeight)
      p.add(MeadowProps, "pepper_crate_01a", PlazaArea,
        x - tangentX * 0.9'f32, y - tangentY * 0.9'f32, facing, CrateHeight)
    of 1:
      p.add(MeadowBuildings, "wood_table_01a", PlazaArea, x, y, facing,
        TableHeight)
      p.add(MeadowBuildings, "wood_bench_01a", PlazaArea,
        x + outwardX * 1.0'f32, y + outwardY * 1.0'f32, sideways,
        BenchHeight)
    of 2:
      p.add(MeadowBuildings, "wood_bench_01a", PlazaArea, x, y, sideways,
        BenchHeight)
      for side in [-1.8'f32, 1.8'f32]:
        p.add(MeadowProps, "flower_pot_01a", PlazaArea,
          x + tangentX * side, y + tangentY * side, facing, PotHeight)
    of 3:
      p.add(MeadowProps, "wood_cart_01a", PlazaArea, x, y, sideways,
        CartHeight)
      p.add(MeadowProps, "wood_barrel_01a", PlazaArea,
        x + outwardX * 1.3'f32, y + outwardY * 1.3'f32, 0.0, BarrelHeight)
      p.add(MeadowProps, "wood_barrel_01a", PlazaArea,
        x + outwardX * 1.3'f32 + tangentX * 0.7'f32,
        y + outwardY * 1.3'f32 + tangentY * 0.7'f32, 0.7, BarrelHeight)
    else:
      p.add(MeadowProps, "sack_pile_01a", PlazaArea, x, y, facing, SackHeight)
      p.add(MeadowProps, "wood_crate_01a", PlazaArea,
        x + tangentX * 1.1'f32, y + tangentY * 1.1'f32, facing, BoxHeight)
    ## A signpost on the grass beside every third entrance: a fence pole
    ## with the sign board hung on it, turned to face the road.
    if i mod 3 == 1:
      let
        beside = entrance + 0.22'f32
        signX = int32(centre + cos(beside) * PlazaSignRadius)
        signY = int32(centre + sin(beside) * PlazaSignRadius)
        toward = yawAlong(-cos(entrance), -sin(entrance))
      if p.claim(MeadowProps, "wood_fence_pole_01a", RoadArea, signX, signY,
          toward, SignPoleHeight):
        p.add(ValleyProps, "wood_sign_01a", RoadArea,
          float32(signX) + 0.5'f32, float32(signY) + 0.5'f32, toward,
          SignBoardHeight, SignBoardLift)

proc dressHouses(p: var Placer) =
  ## Mailbox, door pots, back fence, flower beds, and a bush per house.
  for house in p.map.houses:
    let
      cx = int32(house.center.x)
      cy = int32(house.center.y)
      fx = int32(house.facingX)
      fy = int32(house.facingY)
      px = -fy
      py = fx
      facing = yawAlong(float32(fx), float32(fy))
    discard p.claim(MeadowProps, "mailbox_01a", HouseArea,
      cx + fx * (HouseHalf + 1) + px, cy + fy * (HouseHalf + 1) + py,
      facing, MailboxHeight)
    for side in [-1.2'f32, 1.2'f32]:
      p.add(MeadowProps, "flower_pot_01a", HouseArea,
        float32(cx) + 0.5'f32 + float32(fx) * (float32(HouseHalf) + 1.3'f32) +
          float32(px) * side,
        float32(cy) + 0.5'f32 + float32(fy) * (float32(HouseHalf) + 1.3'f32) +
          float32(py) * side,
        facing, PotHeight)
    var beds = 0
    for attempt in 0 ..< HouseDecorAttempts:
      if beds >= HouseFlowerBeds:
        break
      let
        x = cx + p.rng.below(HouseDecorReach * 2 + 1) - HouseDecorReach
        y = cy + p.rng.below(HouseDecorReach * 2 + 1) - HouseDecorReach
      if max(abs(x - cx), abs(y - cy)) <= HouseHalf:
        continue
      if p.claim(MeadowVegetation, p.rng.pick(FlowerBeds), HouseArea, x, y,
          p.rng.unit() * 2 * PI, FlowerHeight, 0.25, NaturalVariance,
          p.rng.plantTint()):
        inc beds
    var bushes = 0
    for attempt in 0 ..< HouseDecorAttempts:
      if bushes >= HouseBushes:
        break
      let
        x = cx + p.rng.below(HouseDecorReach * 2 + 1) - HouseDecorReach
        y = cy + p.rng.below(HouseDecorReach * 2 + 1) - HouseDecorReach
      if max(abs(x - cx), abs(y - cy)) <= HouseHalf:
        continue
      if p.nearHouseDoor(x, y):
        continue
      let bush = if p.rng.below(2) == 0: "flower_bush_01a" else: "bush_01a"
      if p.claim(MeadowVegetation, bush, HouseArea, x, y,
          p.rng.unit() * 2 * PI, BushHeight, 0.2, NaturalVariance,
          p.rng.plantTint()):
        inc bushes

proc dressGardens(p: var Placer) =
  ## Pots mark every crop plot, with flowers beside some plots.
  for index, garden in p.map.gardenTiles:
    p.add(MeadowProps, GardenPots[index mod GardenPots.len], GardenArea,
      float32(garden.x) + 0.5'f32, float32(garden.y) + 0.5'f32,
      float32(index) * 0.7'f32, GardenPotHeight)
    if p.rng.below(GardenFlowerOneIn) != 0:
      continue
    let
      (sx, sy) = Sides[p.rng.below(4)]
      x = int32(garden.x) + sx
      y = int32(garden.y) + sy
    discard p.claim(MeadowVegetation, p.rng.pick(FlowerBeds), GardenArea,
      x, y, p.rng.unit() * 2 * PI, FlowerHeight, 0.25, NaturalVariance,
      p.rng.plantTint())

proc dressVerges(p: var Placer) =
  ## Lamp posts, tufts, bushes, small rocks, and flowers along the road
  ## edges.
  var
    lamps: seq[Tile2]
    rocks = 0
  for y in 0'i32 ..< GridSide:
    for x in 0'i32 ..< GridSide:
      if not p.tileFree(x, y) or not p.nearRoad(x, y):
        continue
      if p.rng.below(LampOneIn) == 0:
        var crowded = false
        for lamp in lamps:
          if chebyshev(lamp, tile2(x, y)) < LampSpacing:
            crowded = true
            break
        if not crowded and p.claim(MeadowProps, "lamp_post_01a", RoadArea,
            x, y, p.rng.unit() * 2 * PI, LampHeight):
          lamps.add tile2(x, y)
          continue
      if p.rng.below(RoadDecorOneIn) != 0:
        continue
      let yaw = p.rng.unit() * 2 * PI
      case p.rng.below(4)
      of 0:
        discard p.claim(MeadowVegetation, p.rng.pick(Tufts), RoadArea, x, y,
          yaw, TuftHeight, 0.3, NaturalVariance, p.rng.plantTint())
      of 1:
        if rocks < RoadRockLimit and p.rng.below(8) == 0:
          if p.claim(MeadowRocks, p.rng.pick(SmallRocks), RoadArea, x, y,
              yaw, SmallRockHeight, 0.2, 0.1, p.rng.rockTint(),
              p.awayFromRoad(x, y) * VergeRockSetback):
            inc rocks
      of 2:
        if not p.nearHouseDoor(x, y):
          discard p.claim(MeadowVegetation, "bush_01a", RoadArea, x, y,
            yaw, MeadowBushHeight, 0.15, 0.15, p.rng.plantTint())
      else:
        discard p.claim(MeadowVegetation, p.rng.pick(FlowerBeds), RoadArea,
          x, y, yaw, FlowerHeight, 0.3, NaturalVariance, p.rng.plantTint())

proc meadowFree(p: Placer, x, y: int32): bool =
  ## Keeps substantial vegetation off paths and away from doors and crops.
  if not p.tileFree(x, y) or p.nearHouseDoor(x, y) or p.nearRoad(x, y):
    return false
  for garden in p.map.gardenTiles:
    if chebyshev(tile2(x, y), garden) <= 1:
      return false
  true

proc dressMeadow(p: var Placer) =
  ## Broad planted patches fill the meadow between the village paths.
  var centres: seq[Tile2]
  for attempt in 0 ..< MeadowAttempts:
    if centres.len >= MeadowClusters:
      break
    let
      reach = if attempt < MeadowAttempts div 2: VillagePlantRadius else: ForestEdgeRadius
      x = GridSide div 2 + p.rng.below(reach * 2) - reach
      y = GridSide div 2 + p.rng.below(reach * 2) - reach
      tile = tile2(x, y)
    if chebyshev(tile, tile2(GridSide div 2, GridSide div 2)) < 12:
      continue
    var clear = true
    for centre in centres:
      if chebyshev(tile, centre) < MeadowSpacing:
        clear = false
    if not clear:
      continue
    for dy in -2'i32 .. 2'i32:
      for dx in -2'i32 .. 2'i32:
        if not p.meadowFree(x + dx, y + dy):
          clear = false
    if not clear:
      continue
    centres.add tile
    let yaw = p.rng.unit() * 2 * PI
    if centres.len mod MeadowTreeEvery == 0:
      discard p.claim(MeadowVegetation, p.rng.pick(SmallTrees), MeadowArea,
        x, y, yaw, MeadowTreeHeight, variance = 0.15, tint = p.rng.plantTint())
    for plant in 0 ..< MeadowUnderplanting:
      let
        px = x + p.rng.below(MeadowPlantReach * 2 + 1) - MeadowPlantReach
        py = y + p.rng.below(MeadowPlantReach * 2 + 1) - MeadowPlantReach
        angle = p.rng.unit() * 2 * PI
      if not p.meadowFree(px, py):
        continue
      case plant mod 4
      of 0, 1:
        let node = if plant mod 2 == 0: "bush_01a" else: "flower_bush_01a"
        discard p.claim(MeadowVegetation, node, MeadowArea,
          px, py, angle, MeadowBushHeight, variance = 0.2,
          tint = p.rng.plantTint())
      of 2:
        discard p.claim(MeadowVegetation, p.rng.pick(FlowerBeds), MeadowArea,
          px, py, angle, FlowerHeight * 1.5, variance = 0.2,
          tint = p.rng.plantTint())
      else:
        discard

proc dressOutskirts(p: var Placer) =
  ## Low planting bridges the open meadow and forest edge.
  let middle = tile2(GridSide div 2, GridSide div 2)
  var rocks = 0
  for y in 0'i32 ..< GridSide:
    for x in 0'i32 ..< GridSide:
      let ring = chebyshev(tile2(x, y), middle)
      if ring < ForestTransitionStart or ring >= ForestWallRadius:
        continue
      if not p.meadowFree(x, y):
        continue
      let chance = if p.nearTree(x, y): 2'i32 else: ForestTransitionOneIn
      if p.rng.below(chance) != 0:
        continue
      let yaw = p.rng.unit() * 2 * PI
      case p.rng.below(4)
      of 0:
        discard p.claim(MeadowVegetation, "bush_01a", OutskirtsArea,
          x, y, yaw, MeadowBushHeight, 0.2, 0.2, p.rng.plantTint())
      of 1:
        discard p.claim(MeadowVegetation, p.rng.pick(Tufts), OutskirtsArea,
          x, y, yaw, TuftHeight, 0.2, NaturalVariance, p.rng.plantTint())
      of 2:
        discard p.claim(MeadowVegetation, p.rng.pick(FlowerBeds), OutskirtsArea,
          x, y, yaw, FlowerHeight, 0.2, NaturalVariance, p.rng.plantTint())
      else:
        if rocks < ForestRockLimit and p.nearTree(x, y) and p.rng.below(10) == 0:
          if p.claim(MeadowRocks, "rock_medium_01a", OutskirtsArea,
              x, y, yaw, ForestRockHeight, tint = p.rng.rockTint()):
            inc rocks

proc placeDecor*(map: MapData, seed: int32): seq[Decoration] =
  ## Every decoration for one map, in a fixed order from one seeded stream.
  var p = Placer(map: map, rng: initRng(seed, DecorSalt))
  p.dressPlaza()
  p.dressHouses()
  p.dressGardens()
  p.dressMeadow()
  p.dressVerges()
  p.dressOutskirts()
  p.placed
