## Heartleaf decorations: the props that dress the village. Purely visual
## and derived from nothing but the generated map and its seed, so a live
## game and its replay dress identically. Nothing here reaches the sim.
##
## The plaza gets a well, stalls, a cart, and seating between the road
## entrances, with signposts outside. Each house gets a mailbox, flower
## pots, a back fence, flower beds, and a bush. Garden plots get a fence
## piece. Road verges get lamp posts, tufts, bushes, and small rocks. The
## outskirts get boulders.

import
  std/[math, sets],
  polyworld/[pathing, rngs],
  content,
  maps

type
  DecorKit* = enum
    MeadowProps, MeadowVegetation, MeadowBuildings, MeadowRocks, ValleyProps

  DecorArea* = enum
    PlazaArea, HouseArea, GardenArea, RoadArea, OutskirtsArea

  Decoration* = object
    kit*: DecorKit
    node*: string
    area*: DecorArea
    x*, y*: float32
      ## Tile space; a tile centre is its index plus one half.
    lift*: float32
      ## Tiles above the ground, for pieces that sit on other pieces.
    yaw*: float32
    height*: float32
      ## Tiles tall. The prop loader normalises models to unit height, so
      ## this is the placement scale.

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
  FenceHeight = 1.0'f32
  GardenFenceHeight = 0.9'f32
  FenceSpacing = 1.3'f32
    ## One meadow fence piece is about this many tiles long at FenceHeight.
  FlowerHeight = 0.4'f32
  BushHeight = 1.35'f32
  TuftHeight = 0.35'f32
  VergeBushHeight = 1.2'f32
    ## Nobody trims anything; the villagers are busy with the vegetables.
  SmallRockHeight = 0.45'f32
  MediumRockHeight = 1.2'f32
  LargeRockHeight = 2.5'f32
  HouseFlowerBeds = 3
  HouseDecorReach = 3'i32
  HouseDecorAttempts = 12
  GardenFlowerOneIn = 3'i32
  RoadDecorOneIn = 3'i32
  NaturalVariance = 0.3'f32
    ## Things that grew or were left lying vary this much in size either
    ## way. Things gnomes made, signs, lamps, fences, do not.
  MediumRockOneIn = 12'i32
  LargeRockOneIn = 40'i32

  KitFiles: array[DecorKit, string] = [
    "terrain/toon_enchanted_meadow/props.glb",
    "terrain/toon_enchanted_meadow/vegetation.glb",
    "terrain/toon_enchanted_meadow/buildings.glb",
    "terrain/toon_enchanted_meadow/rocks.glb",
    "terrain/toon_golden_valley/props.glb",
  ]
  DecorNodes: array[DecorKit, seq[string]] = [
    @["market_stand_01a", "canopy_01a", "canopy_02a", "canopy_03a",
      "canopy_04a", "apple_crate_01a", "pepper_crate_01a", "lamp_post_01a",
      "wood_cart_01a", "wood_barrel_01a", "sack_pile_01a", "wood_crate_01a",
      "mailbox_01a", "flower_pot_01a", "wood_fence_01a", "wood_fence_02a",
      "wood_fence_pole_01a"],
    @["flowers_patch_01a", "flowers_patch_02a", "flowers_patch_03a",
      "flower_bush_01a", "bush_01a", "grass_patch_01a", "grass_patch_02a",
      "grass_patch_03a", "grass_patch_04a", "grass_patch_05a"],
    @["wood_bench_01a", "wood_table_01a"],
    @["rock_small_01a", "rock_small_02a", "rock_small_03a", "rock_small_04a",
      "rock_medium_01a", "rock_medium_02a", "rock_medium_03a",
      "rock_large_01a"],
    @["well_01a", "wood_sign_01a"],
  ]
  Canopies = ["canopy_01a", "canopy_02a", "canopy_03a", "canopy_04a"]
  Tufts = ["grass_patch_01a", "grass_patch_02a", "grass_patch_03a",
    "grass_patch_04a", "grass_patch_05a"]
  SmallRocks = ["rock_small_01a", "rock_small_02a", "rock_small_03a",
    "rock_small_04a"]
  MediumRocks = ["rock_medium_01a", "rock_medium_02a", "rock_medium_03a"]
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

proc add(
    p: var Placer, kit: DecorKit, node: string, area: DecorArea,
    x, y, yaw, height: float32, lift = 0.0'f32
) =
  ## Records one decoration.
  p.placed.add Decoration(
    kit: kit, node: node, area: area, x: x, y: y, lift: lift, yaw: yaw,
    height: height)

proc claim(
    p: var Placer, kit: DecorKit, node: string, area: DecorArea,
    tileX, tileY: int32, yaw, height: float32, jitter = 0.0'f32,
    variance = 0.0'f32
): bool =
  ## Places one decoration on a free grass tile and marks the tile used.
  ## Jitter moves it off the tile centre by up to that many tiles;
  ## variance scales its height by up to that fraction either way.
  if not p.tileFree(tileX, tileY):
    return false
  p.used.incl tileIndex(tileX, tileY)
  let
    offsetX = (p.rng.unit() - 0.5'f32) * 2.0'f32 * jitter
    offsetY = (p.rng.unit() - 0.5'f32) * 2.0'f32 * jitter
    grown = height * (1.0'f32 + (p.rng.unit() - 0.5'f32) * 2.0'f32 * variance)
  p.add(kit, node, area,
    float32(tileX) + 0.5'f32 + offsetX, float32(tileY) + 0.5'f32 + offsetY,
    yaw, grown)
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
      tangentX = -sin(mid)
      tangentY = cos(mid)
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
        x - tangentX * 0.9'f32, y - tangentY * 0.9'f32, facing, BenchHeight)
    of 2:
      p.add(MeadowBuildings, "wood_bench_01a", PlazaArea, x, y, facing,
        BenchHeight)
      for side in [-1.0'f32, 1.0'f32]:
        p.add(MeadowProps, "flower_pot_01a", PlazaArea,
          x + tangentX * side, y + tangentY * side, facing, PotHeight)
    of 3:
      p.add(MeadowProps, "wood_cart_01a", PlazaArea, x, y, facing + PI / 2,
        CartHeight)
      p.add(MeadowProps, "wood_barrel_01a", PlazaArea,
        x + tangentX * 1.1'f32, y + tangentY * 1.1'f32, 0.0, BarrelHeight)
      p.add(MeadowProps, "wood_barrel_01a", PlazaArea,
        x + tangentX * 1.1'f32 + 0.5'f32, y + tangentY * 1.1'f32 - 0.4'f32,
        0.7, BarrelHeight)
    else:
      p.add(MeadowProps, "sack_pile_01a", PlazaArea, x, y, facing, SackHeight)
      p.add(MeadowProps, "wood_crate_01a", PlazaArea,
        x + tangentX * 0.8'f32, y + tangentY * 0.8'f32, facing, BoxHeight)
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
      along = yawAlong(float32(px), float32(py))
    discard p.claim(MeadowProps, "mailbox_01a", HouseArea,
      cx + fx * 2 + px, cy + fy * 2 + py, facing, MailboxHeight)
    for side in [-1.2'f32, 1.2'f32]:
      p.add(MeadowProps, "flower_pot_01a", HouseArea,
        float32(cx) + 0.5'f32 + float32(fx) * 1.7'f32 + float32(px) * side,
        float32(cy) + 0.5'f32 + float32(fy) * 1.7'f32 + float32(py) * side,
        facing, PotHeight)
    for k in -1'i32 .. 1'i32:
      let
        tileX = cx - fx * 3 + px * k
        tileY = cy - fy * 3 + py * k
      if p.tileFree(tileX, tileY):
        p.used.incl tileIndex(tileX, tileY)
        p.add(MeadowProps, "wood_fence_01a", HouseArea,
          float32(cx) + 0.5'f32 - float32(fx) * 3 +
            float32(px) * float32(k) * FenceSpacing,
          float32(cy) + 0.5'f32 - float32(fy) * 3 +
            float32(py) * float32(k) * FenceSpacing,
          along, FenceHeight)
    var beds = 0
    for attempt in 0 ..< HouseDecorAttempts:
      if beds >= HouseFlowerBeds:
        break
      let
        x = cx + p.rng.below(HouseDecorReach * 2 + 1) - HouseDecorReach
        y = cy + p.rng.below(HouseDecorReach * 2 + 1) - HouseDecorReach
      if max(abs(x - cx), abs(y - cy)) < 2:
        continue
      if p.claim(MeadowVegetation, p.rng.pick(FlowerBeds), HouseArea, x, y,
          p.rng.unit() * 2 * PI, FlowerHeight, 0.25, NaturalVariance):
        inc beds
    for attempt in 0 ..< HouseDecorAttempts:
      let
        x = cx + p.rng.below(HouseDecorReach * 2 + 1) - HouseDecorReach
        y = cy + p.rng.below(HouseDecorReach * 2 + 1) - HouseDecorReach
      if max(abs(x - cx), abs(y - cy)) < 2:
        continue
      let bush = if p.rng.below(2) == 0: "flower_bush_01a" else: "bush_01a"
      if p.claim(MeadowVegetation, bush, HouseArea, x, y,
          p.rng.unit() * 2 * PI, BushHeight, 0.2, NaturalVariance):
        break

proc dressGardens(p: var Placer) =
  ## A fence piece beside every plot, flowers beside some.
  for garden in p.map.gardenTiles:
    var order = [0'i32, 1, 2, 3]
    for i in countdown(3, 1):
      let j = p.rng.below(int32(i + 1))
      swap(order[i], order[j])
    var fenced = false
    for choice in order:
      let
        (sx, sy) = Sides[choice]
        x = int32(garden.x) + sx
        y = int32(garden.y) + sy
      if not fenced:
        if p.claim(MeadowProps, "wood_fence_02a", GardenArea, x, y,
            yawAlong(float32(-sy), float32(sx)), GardenFenceHeight):
          fenced = true
      elif p.rng.below(GardenFlowerOneIn) == 0:
        discard p.claim(MeadowVegetation, p.rng.pick(FlowerBeds), GardenArea,
          x, y, p.rng.unit() * 2 * PI, FlowerHeight, 0.25, NaturalVariance)
        break

proc dressVerges(p: var Placer) =
  ## Lamp posts, tufts, bushes, small rocks, and flowers along the road
  ## edges.
  var lamps: seq[Tile2]
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
          yaw, TuftHeight, 0.3, NaturalVariance)
      of 1:
        discard p.claim(MeadowVegetation, "bush_01a", RoadArea, x, y, yaw,
          VergeBushHeight, 0.2, NaturalVariance)
      of 2:
        discard p.claim(MeadowRocks, p.rng.pick(SmallRocks), RoadArea, x, y,
          yaw, SmallRockHeight, 0.3, NaturalVariance)
      else:
        discard p.claim(MeadowVegetation, p.rng.pick(FlowerBeds), RoadArea,
          x, y, yaw, FlowerHeight, 0.3, NaturalVariance)

proc dressOutskirts(p: var Placer) =
  ## Boulders in the meadow between the village and the forest wall.
  let middle = tile2(GridSide div 2, GridSide div 2)
  for y in 0'i32 ..< GridSide:
    for x in 0'i32 ..< GridSide:
      let ring = chebyshev(tile2(x, y), middle)
      if ring < ForestEdgeRadius or ring >= ForestWallRadius:
        continue
      if not p.tileFree(x, y):
        continue
      let yaw = p.rng.unit() * 2 * PI
      if p.rng.below(LargeRockOneIn) == 0:
        discard p.claim(MeadowRocks, "rock_large_01a", OutskirtsArea, x, y,
          yaw, LargeRockHeight, 0.0, NaturalVariance)
      elif p.rng.below(MediumRockOneIn) == 0:
        discard p.claim(MeadowRocks, p.rng.pick(MediumRocks), OutskirtsArea,
          x, y, yaw, MediumRockHeight, 0.3, NaturalVariance)

proc placeDecor*(map: MapData, seed: int32): seq[Decoration] =
  ## Every decoration for one map, in a fixed order from one seeded stream.
  var p = Placer(map: map, rng: initRng(seed, DecorSalt))
  p.dressPlaza()
  p.dressHouses()
  p.dressGardens()
  p.dressVerges()
  p.dressOutskirts()
  p.placed
