## Heartleaf houses: recipes that turn a seed into a list of kit pieces.
## Neither toon kit ships a whole cottage, only the parts the store
## cottages were assembled from, so every house is built here. Pure CPU,
## in metres, so headless tests can check every piece; the viewer scales
## and rotates the result.
##
## The golden valley roofs are steep A-frames, close to seven metres tall
## for a seven metre span, made to stand on the ground as chalets, and
## that is the shape every house here takes: a ring of stone foundation a
## metre high, the A-frame on top with its ridge running front to back,
## a plank gable closing each end, the door in the front gable, windows by
## coin flip, a chimney by coin flip. A cottage is two or three roof
## segments deep under slate, shingle, or reed. A longhouse is three or
## four under straw thatch tinted to turf with grass along the ridge, the
## viking sod house.

import
  std/math,
  vmath,
  polyworld/rngs,
  decor

type
  HouseKind* = enum
    Cottage, Longhouse

  HousePiece* = object
    kit*: DecorKit
    node*: string
    offset*: Vec3
      ## Metres from the house centre on the ground; +z is the front, where
      ## the door is, +y is up.
    yaw*: float32
    tint*: Vec3

  RoofStyle = object
    node: string
    along: float32
      ## Metres one segment covers along the ridge.
    span: float32
      ## Metres the A-frame covers across, which is the house width.
    height: float32

const
  HouseSalt = 0x40053'u64
  KindSalt = 0x1D'u64
  HouseExtent* = vec3(4.0, 9.0, 6.5)
    ## Every piece's centre stays within this box around the house centre.
  FoundationHeight = 1.0'f32
  GableWidth = 6.27'f32
    ## The gable end wall piece; a shade narrower than the roofs.
  GableLift = FoundationHeight
  GableProud = 0.35'f32
    ## Doors and windows stand this far outside the gable they sit in.
  DoorReach = 1.4'f32
    ## The door slides this far either side of the gable centre.
  WindowLift = 0.9'f32
  WindowReach = 0.9'f32
    ## Windows stay this close to the gable centre so they sit under the
    ## slope at their height.
  ChimneySink = 0.45'f32
    ## How far a chimney sinks into the ridge; the rest stands proud.
  StairsStandOff = 1.0'f32
  SodTint* = vec3(0.34, 0.72, 0.28)
    ## Thatch multiplied hard toward green so it reads as turf, not straw.
  SodTuftsPerSlope = 2
    ## Grass tufts down each slope per roof segment, besides the ridge one.
  SodGrassTint = vec3(0.95, 1.05, 0.85)
  SodGrassRidgeDrop = 0.35'f32
  SodGrassSlopeAt = 1.8'f32
    ## Metres from the ridge, across, where the slope tufts sit.
  SegmentOverlap = 0.3'f32
    ## Roof segments overlap this much so the rolled edge of one hides the
    ## groove against the next.
  SegmentStagger = 0.04'f32
    ## Every other segment sits this much lower, so the overlapping faces
    ## have a clear winner instead of flickering.
  PaintShade = 0.12'f32
  PaintWarmth = 0.06'f32
  Turn = PI / 2
    ## Roofs and gables are authored with the ridge along x; the house
    ## runs its ridge along z, so those pieces turn a quarter.

  Cubes = ["foundation_block_01a", "foundation_block_02a"]
  Chimneys = ["chimney_01a", "chimney_02a"]
  CottageRoofs = [
    RoofStyle(node: "roof_02a", along: 2.0, span: 7.12, height: 6.84),
    RoofStyle(node: "roof_03a", along: 2.25, span: 6.91, height: 6.63),
    RoofStyle(node: "roof_04a", along: 2.0, span: 6.45, height: 6.46),
  ]
  ThatchRoof = RoofStyle(node: "roof_01a", along: 2.5, span: 7.12, height: 6.82)
  SodGrass = ["grass_patch_01a", "grass_patch_02a", "grass_patch_03a"]

  HouseNodes: array[DecorKit, seq[string]] = [
    @[],
    @["grass_patch_01a", "grass_patch_02a", "grass_patch_03a"],
    @["foundation_block_01a", "foundation_block_02a", "stairs_03a"],
    @[],
    @[],
    @[],
    @["door_01a", "window_01a", "roof_01a", "roof_02a", "roof_03a",
      "roof_04a", "roof_structure_01a", "chimney_01a", "chimney_02a",
      "chimney_03a"],
  ]
    ## What the house packs load from each kit; empty kits are not loaded
    ## for houses at all.

proc houseNodesFor*(kit: DecorKit): seq[string] =
  ## The nodes houses use from one kit.
  HouseNodes[kit]

proc houseKindFor*(seed: int32, slot: int): HouseKind =
  ## Which recipe one house slot gets: two thirds cottages.
  var rng = initRng(seed xor int32(slot) * 7919, KindSalt)
  if rng.below(3) == 0: Longhouse else: Cottage

proc unit(rng: var Rng): float32 =
  ## One draw in 0 .. 1.
  float32(rng.below(10001)) / 10000.0'f32

proc coin(rng: var Rng): bool =
  ## One draw in two.
  rng.below(2) == 0

proc pick[T](rng: var Rng, items: openArray[T]): T =
  ## One uniformly chosen item.
  items[rng.below(int32(items.len))]

proc paint(rng: var Rng): Vec3 =
  ## A per-house drift of brightness and warmth over the kit paint.
  let
    shade = 1.0'f32 + (rng.unit() - 0.5'f32) * 2.0'f32 * PaintShade
    warmth = (rng.unit() - 0.5'f32) * 2.0'f32 * PaintWarmth
  vec3(shade * (1.0'f32 + warmth), shade, shade * (1.0'f32 - warmth))

type Builder = object
  rng: Rng
  tint: Vec3
  pieces: seq[HousePiece]

proc add(b: var Builder, kit: DecorKit, node: string, x, y, z: float32,
    yaw = 0.0'f32) =
  ## Records one piece in the house's paint.
  b.pieces.add HousePiece(
    kit: kit, node: node, offset: vec3(x, y, z), yaw: yaw, tint: b.tint)

proc addTinted(b: var Builder, kit: DecorKit, node: string,
    x, y, z: float32, yaw: float32, tint: Vec3) =
  ## Records one piece in its own colour.
  b.pieces.add HousePiece(
    kit: kit, node: node, offset: vec3(x, y, z), yaw: yaw, tint: tint)

proc buildChalet(
    b: var Builder, roof: RoofStyle, modules: int, roofTint: Vec3,
    raisedDoor: bool
): tuple[depth, doorX: float32] =
  ## The shape both kinds share: foundation ring, roof segments along z,
  ## gable walls, a door in the front gable. A raised door sits on the
  ## foundation with stairs; otherwise the foundation opens for it.
  let
    depth = float32(modules) * roof.along
    halfDepth = depth * 0.5'f32
    halfSpan = roof.span * 0.5'f32
    doorX = round((b.rng.unit() - 0.5'f32) * 2.0'f32 * DoorReach)
      ## Snapped to the foundation cube grid so a ground door takes exactly
      ## one cube out.
    doorZ = halfDepth
  ## Foundation: cubes under the eaves and along both gables.
  var z = -halfDepth + 0.5'f32
  while z < halfDepth:
    for x in [-halfSpan + 0.5'f32, halfSpan - 0.5'f32]:
      b.add(MeadowBuildings, b.rng.pick(Cubes), x, 0, z)
    z += 1.0'f32
  ## Gable rows: enough cubes to meet the eave cubes, overlapping a little
  ## rather than leaving a corner open, and one cube out for a ground door.
  let gableCubes = int(ceil(roof.span - 2.0'f32))
  for i in 0 ..< gableCubes:
    let x = (float32(i) - float32(gableCubes - 1) * 0.5'f32)
    for side in [1.0'f32, -1.0'f32]:
      let gap = side > 0 and not raisedDoor and abs(x - doorX) < 0.5'f32
      if not gap:
        b.add(MeadowBuildings, b.rng.pick(Cubes), x, 0, halfDepth * side)
  ## Roof, ridge along z, segments overlapping and staggered.
  let pitch = (depth - SegmentOverlap) / float32(modules)
  for i in 0 ..< modules:
    let
      segZ = -halfDepth + SegmentOverlap * 0.5'f32 +
        pitch * (float32(i) + 0.5'f32)
      drop = if i mod 2 == 1: SegmentStagger else: 0.0'f32
    b.addTinted(ValleyBuildings, roof.node, 0, FoundationHeight - drop, segZ,
      Turn, roofTint)
  ## Gable walls closing each end, the door and windows set into them.
  for side in [1.0'f32, -1.0'f32]:
    b.add(ValleyBuildings, "roof_structure_01a", 0, GableLift,
      halfDepth * side, Turn)
  let doorLift = if raisedDoor: FoundationHeight else: 0.0'f32
  b.add(ValleyBuildings, "door_01a", doorX, doorLift, doorZ + GableProud, Turn)
  if raisedDoor:
    b.add(MeadowBuildings, "stairs_03a", doorX, 0, doorZ + StairsStandOff)
  if b.rng.coin():
    let windowX = if doorX < 0: WindowReach else: -WindowReach
    b.add(ValleyBuildings, "window_01a", windowX, GableLift + WindowLift,
      doorZ + GableProud, Turn)
  if b.rng.coin():
    b.add(ValleyBuildings, "window_01a",
      (b.rng.unit() - 0.5'f32) * 2.0'f32 * WindowReach, GableLift + WindowLift,
      -doorZ - GableProud, Turn)
  (depth: depth, doorX: doorX)

proc buildCottage(b: var Builder) =
  ## Two or three segments under slate, shingle, or reed, a chimney by
  ## coin flip.
  let
    roof = b.rng.pick(CottageRoofs)
    modules = 2 + int(b.rng.below(2))
    raisedDoor = b.rng.coin()
    house = b.buildChalet(roof, modules, b.tint, raisedDoor)
  if b.rng.coin():
    b.add(ValleyBuildings, b.rng.pick(Chimneys), 0,
      FoundationHeight + roof.height - ChimneySink,
      (b.rng.unit() - 0.5'f32) * house.depth * 0.6'f32)

proc buildLonghouse(b: var Builder) =
  ## Three segments of straw thatch tinted hard to turf, grass along the
  ## ridge and in rows down both slopes, a squat chimney by coin flip.
  ## Three segments keep the gables inside the house footprint.
  let
    roof = ThatchRoof
    modules = 3
    house = b.buildChalet(roof, modules, SodTint * b.tint, false)
    peak = FoundationHeight + roof.height
    halfDepth = house.depth * 0.5'f32
    slopeLift = FoundationHeight +
      roof.height * (1.0'f32 - SodGrassSlopeAt / (roof.span * 0.5'f32))
  for i in 0 ..< modules:
    let z = -halfDepth + roof.along * (float32(i) + 0.5'f32)
    b.addTinted(MeadowVegetation, b.rng.pick(SodGrass), 0,
      peak - SodGrassRidgeDrop, z, b.rng.unit() * 2 * PI, SodGrassTint)
    for side in [1.0'f32, -1.0'f32]:
      for k in 0 ..< SodTuftsPerSlope:
        let along = z + (float32(k) + 0.5'f32) / float32(SodTuftsPerSlope) *
          roof.along - roof.along * 0.5'f32
        b.addTinted(MeadowVegetation, b.rng.pick(SodGrass),
          SodGrassSlopeAt * side + (b.rng.unit() - 0.5'f32) * 0.6'f32,
          slopeLift, along, b.rng.unit() * 2 * PI, SodGrassTint)
  if b.rng.coin():
    b.add(ValleyBuildings, "chimney_03a", 0, peak - 0.4'f32,
      (b.rng.unit() - 0.5'f32) * house.depth * 0.6'f32)

proc buildHouse*(seed: int32, kind: HouseKind): seq[HousePiece] =
  ## Every piece of one house, in a fixed order from one seeded stream.
  var b = Builder(rng: initRng(seed, HouseSalt))
  b.tint = b.rng.paint()
  case kind
  of Cottage: b.buildCottage()
  of Longhouse: b.buildLonghouse()
  b.pieces
