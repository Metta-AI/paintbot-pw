## Heartleaf houses: recipes that turn a seed into a list of kit pieces,
## built the way golden valley's own prefab houses are built. Pure CPU,
## in metres, so headless tests can check every piece; the viewer scales
## and rotates the result.
##
## The prefabs, measured: a base course of small bricks about a metre
## tall with a timber sill on top, the steep A-frame roof standing on
## that at a metre and a half with its ridge running the long way, the
## plank gable piece stretched to the roof's triangle closing each end,
## and the door and windows standing in that end face from the ground up.
## A chimney or a timber crest rides the ridge. A cottage is three or four segments
## of reed, slate, or shingle on a brick course. A longhouse is four
## segments of straw thatch tinted to turf with grass along the ridge, on
## a stone course, the viking sod house.

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
    scale*: float32
      ## Uniform scale on top of the viewer's metres-to-tiles; one for as
      ## authored.
    stretch*: Vec3
      ## Per-axis scale in the piece's own frame, before its turn; one for
      ## as authored. The gable wall is stretched to the roof's triangle.

  RoofStyle = object
    node: string
    along: float32
      ## Metres one segment covers along the ridge.
    span: float32
      ## Metres the A-frame covers across, which is the house width.
    height: float32
    overlap: float32
      ## Metres neighbouring segments overlap so their rolled edges nest;
      ## thatch needs more than slate.

const
  HouseSalt = 0x40053'u64
  KindSalt = 0x1D'u64
  HouseExtent* = vec3(4.0, 12.0, 5.6)
    ## Every piece's centre stays within this box around the house centre.
  RoofLift = 1.5'f32
    ## Where the eave tips stand, as in the prefabs: on the sill over the
    ## base course.
  CourseHeight = 0.98'f32
  BrickLength = 1.11'f32
  BrickThickness = 0.63'f32
  CornerSize = 0.87'f32
  CubeLength = 1.0'f32
  SillLength = 5.0'f32
  MaxDepth = 10.0'f32
    ## The prefab length, and exactly the five-tile house pad.
  DoorProud = 0.35'f32
    ## Doors and windows stand this far outside the end face they sit in.
  DoorScale = 1.12'f32
    ## The door leaf is 0.9m wide; scaled to fill a brick-sized gap.
  DoorReach = 1.5'f32
    ## The door slides this far either side of the gable centre.
  WindowLift = 1.2'f32
  WindowBeside = 1.7'f32
    ## A front window stands this far to the side of the door.
  WindowReach = 1.6'f32
  ChimneySink = 0.45'f32
  CrestLegs = 1.87'f32
    ## Half the crest's leg spread across the ridge; the legs rest on the
    ## slopes there.
  GableWidth = 6.27'f32
  GablePlankHeight = 4.82'f32
    ## The gable wall piece's planks, above its beams, as authored.
  GableBeamDrop = 0.89'f32
    ## Its side beams hang this far below the planks; they end up under the
    ## ground once the planks start on the course.
  GableInset = 0.15'f32
    ## The gable wall stands this far inside the roof's end.
  SodTint* = vec3(0.34, 0.72, 0.28)
    ## Thatch multiplied hard toward green so it reads as turf, not straw.
  SodGrassTint = vec3(0.95, 1.05, 0.85)
  SodGrassRidgeDrop = 0.35'f32
  SodGrassSlopeAt = 1.8'f32
    ## Metres from the ridge, across, where the slope tufts sit.
  SodTuftsPerSlope = 2
  SegmentStagger = 0.04'f32
    ## Every other segment sits this much lower, so the overlapping faces
    ## have a clear winner instead of flickering.
  PaintShade = 0.12'f32
  PaintWarmth = 0.06'f32
  Turn = PI / 2
    ## Roofs and the crest are authored with the ridge along x; the house
    ## runs its ridge along z, so those pieces turn a quarter.

  Bricks = ["wall_base_01a", "wall_base_01b"]
  Corner = "wall_base_02a"
  Cubes = ["foundation_block_01a", "foundation_block_02a"]
  Sill = "beam_01a"
  Chimneys = ["chimney_01a", "chimney_02a"]
  Crest = "roof_structure_02a"
  CottageRoofs = [
    RoofStyle(node: "roof_02a", along: 2.0, span: 7.12, height: 6.84,
      overlap: 0.5),
    RoofStyle(node: "roof_03a", along: 2.25, span: 6.91, height: 6.63,
      overlap: 0.35),
    RoofStyle(node: "roof_04a", along: 2.0, span: 6.45, height: 6.46,
      overlap: 0.35),
  ]
  ThatchRoof = RoofStyle(node: "roof_01a", along: 2.5, span: 7.12,
    height: 6.82, overlap: 0.55)
  SodGrass = ["grass_patch_01a", "grass_patch_02a", "grass_patch_03a"]

  HouseNodes: array[DecorKit, seq[string]] = [
    @[],
    @["grass_patch_01a", "grass_patch_02a", "grass_patch_03a"],
    @["foundation_block_01a", "foundation_block_02a"],
    @[],
    @[],
    @[],
    @["wall_base_01a", "wall_base_01b", "wall_base_02a", "beam_01a",
      "door_01a", "window_01a", "roof_01a", "roof_02a", "roof_03a",
      "roof_04a", "roof_structure_01a", "roof_structure_02a", "chimney_01a",
      "chimney_02a", "chimney_03a"],
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
    yaw = 0.0'f32, scale = 1.0'f32, stretch = vec3(1, 1, 1)) =
  ## Records one piece in the house's paint.
  b.pieces.add HousePiece(
    kit: kit, node: node, offset: vec3(x, y, z), yaw: yaw, tint: b.tint,
    scale: scale, stretch: stretch)

proc addTinted(b: var Builder, kit: DecorKit, node: string,
    x, y, z: float32, yaw: float32, tint: Vec3) =
  ## Records one piece in its own colour.
  b.pieces.add HousePiece(
    kit: kit, node: node, offset: vec3(x, y, z), yaw: yaw, tint: tint,
    scale: 1.0, stretch: vec3(1, 1, 1))

proc coursePiece(b: var Builder, stone: bool): tuple[kit: DecorKit,
    node: string] =
  ## One base course piece: a golden valley brick, or a meadow stone cube.
  if stone: (MeadowBuildings, b.rng.pick(Cubes))
  else: (ValleyBuildings, b.rng.pick(Bricks))

proc buildBody(
    b: var Builder, roof: RoofStyle, modules: int, roofTint: Vec3,
    stone: bool
): tuple[depth, doorX: float32] =
  ## The shape both kinds share, built like the prefabs: a base course
  ## with a door gap in the front, sills along the eaves, roof segments
  ## on the sills, the door and windows in the front end face.
  let
    depth = min(
      float32(modules) * roof.along - float32(modules - 1) * roof.overlap,
      MaxDepth)
    halfDepth = depth * 0.5'f32
    halfSpan = roof.span * 0.5'f32
    unitLength = if stone: CubeLength else: BrickLength
    thickness = if stone: CubeLength else: BrickThickness
    cornerSize = if stone: CubeLength else: CornerSize
    inset = halfSpan - thickness * 0.5'f32
    endInset = halfDepth - thickness * 0.5'f32
    cornerX = halfSpan - cornerSize * 0.5'f32
    cornerZ = halfDepth - cornerSize * 0.5'f32
    eaveRun = depth - 2.0'f32 * cornerSize
    eaveCount = max(int(round(eaveRun / unitLength)), 1)
    eaveStep = eaveRun / float32(eaveCount)
    gableRun = roof.span - 2.0'f32 * cornerSize
    gableCount = max(int(round(gableRun / unitLength)), 1)
    gableStep = gableRun / float32(gableCount)
    doorSlot = clamp(int(round(
      (b.rng.unit() - 0.5'f32) * 2.0'f32 * DoorReach / gableStep +
      float32(gableCount - 1) * 0.5'f32)), 0, gableCount - 1)
    doorX = -gableRun * 0.5'f32 + gableStep * (float32(doorSlot) + 0.5'f32)
  ## Base course: along both eaves, along both gables with a gap for the
  ## door, a corner piece at each corner.
  for side in [1.0'f32, -1.0'f32]:
    for i in 0 ..< eaveCount:
      let piece = b.coursePiece(stone)
      b.add(piece.kit, piece.node, inset * side, 0,
        -eaveRun * 0.5'f32 + eaveStep * (float32(i) + 0.5'f32))
    for i in 0 ..< gableCount:
      if side > 0 and i == doorSlot:
        continue
      let piece = b.coursePiece(stone)
      b.add(piece.kit, piece.node,
        -gableRun * 0.5'f32 + gableStep * (float32(i) + 0.5'f32), 0,
        endInset * side, Turn)
  for x in [-cornerX, cornerX]:
    for z in [-cornerZ, cornerZ]:
      if stone:
        b.add(MeadowBuildings, b.rng.pick(Cubes), x, 0, z)
      else:
        b.add(ValleyBuildings, Corner, x, 0, z)
  ## Sills along the eaves on top of the course.
  let
    sillCount = max(int(ceil(depth / SillLength)), 1)
    sillStep = depth / float32(sillCount)
  for side in [1.0'f32, -1.0'f32]:
    for i in 0 ..< sillCount:
      b.add(ValleyBuildings, Sill, inset * side, CourseHeight,
        -halfDepth + sillStep * (float32(i) + 0.5'f32))
  ## Roof, ridge along z, each joint overlapping and every other segment
  ## a little lower.
  let pitch = roof.along - roof.overlap
  for i in 0 ..< modules:
    let
      segZ = -halfDepth + roof.along * 0.5'f32 + pitch * float32(i)
      drop = if i mod 2 == 1: SegmentStagger else: 0.0'f32
    b.addTinted(ValleyBuildings, roof.node, 0, RoofLift - drop, segZ, Turn,
      roofTint)
  ## Gable walls: the plank gable piece stretched to the roof's triangle,
  ## across to the span and up to the peak, standing just inside each end.
  ## Its wide axis is authored along z like the roofs, so it turns with
  ## them and the stretch is in its own frame.
  let
    gableStretch = vec3(
      1.0,
      (RoofLift + roof.height - CourseHeight) / GablePlankHeight,
      roof.span / GableWidth)
    gableLift = CourseHeight - GableBeamDrop * gableStretch.y
  for side in [1.0'f32, -1.0'f32]:
    b.add(ValleyBuildings, "roof_structure_01a", 0, gableLift,
      (halfDepth - GableInset) * side, Turn, 1.0, gableStretch)
  ## Door and windows in the front end face, a window on the back by
  ## coin flip.
  b.add(ValleyBuildings, "door_01a", doorX, 0, halfDepth + DoorProud, Turn,
    DoorScale)
  if b.rng.coin():
    let windowX = if doorX < 0: doorX + WindowBeside else: doorX - WindowBeside
    b.add(ValleyBuildings, "window_01a", windowX, WindowLift,
      halfDepth + DoorProud, Turn)
  if b.rng.coin():
    b.add(ValleyBuildings, "window_01a",
      (b.rng.unit() - 0.5'f32) * 2.0'f32 * WindowReach, WindowLift,
      -halfDepth - DoorProud, Turn)
  (depth: depth, doorX: doorX)

proc buildCottage(b: var Builder) =
  ## Three or four segments of reed, slate, or shingle on a brick course,
  ## a chimney by coin flip, a timber crest by coin flip.
  let
    roof = b.rng.pick(CottageRoofs)
    modules = 3 + int(b.rng.below(2))
    house = b.buildBody(roof, modules, b.tint, false)
  if b.rng.coin():
    b.add(ValleyBuildings, b.rng.pick(Chimneys), 0,
      RoofLift + roof.height - ChimneySink,
      (b.rng.unit() - 0.5'f32) * house.depth * 0.6'f32)
  if b.rng.coin():
    let legsAt = RoofLift +
      roof.height * (1.0'f32 - CrestLegs / (roof.span * 0.5'f32))
    b.add(ValleyBuildings, Crest, 0, legsAt,
      (b.rng.unit() - 0.5'f32) * house.depth * 0.4'f32, Turn)

proc buildLonghouse(b: var Builder) =
  ## Four segments of straw thatch tinted hard to turf on a stone course,
  ## grass along the ridge and in rows down both slopes, a squat chimney
  ## by coin flip.
  let
    roof = ThatchRoof
    modules = 4
    house = b.buildBody(roof, modules, SodTint * b.tint, true)
    peak = RoofLift + roof.height
    halfDepth = house.depth * 0.5'f32
    pitch = roof.along - roof.overlap
    slopeLift = RoofLift +
      roof.height * (1.0'f32 - SodGrassSlopeAt / (roof.span * 0.5'f32))
  for i in 0 ..< modules:
    let z = -halfDepth + roof.along * 0.5'f32 + pitch * float32(i)
    b.addTinted(MeadowVegetation, b.rng.pick(SodGrass), 0,
      peak - SodGrassRidgeDrop, z, b.rng.unit() * 2 * PI, SodGrassTint)
    for side in [1.0'f32, -1.0'f32]:
      for k in 0 ..< SodTuftsPerSlope:
        let along = z + (float32(k) + 0.5'f32) / float32(SodTuftsPerSlope) *
          pitch - pitch * 0.5'f32
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
