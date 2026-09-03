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
    scale*: float32
      ## Uniform scale on top of the viewer's metres-to-tiles; one for as
      ## authored. The gable walls stretch to the roof span with it.

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
  HouseExtent* = vec3(4.0, 12.0, 6.5)
    ## Every piece's centre stays within this box around the house centre.
  FoundationHeight = 1.0'f32
  WallHeight = 3.0'f32
    ## One row of kit wall panels, which cottages stand on top of the
    ## foundation and under the roof.
  WallThickness = 0.5'f32
  DoorPanelWidth = 2.0'f32
  GableWidth = 6.27'f32
    ## The gable end wall piece; a shade narrower than the roofs.
  GableBeamDrop = 0.89'f32
    ## The gable wall's side beams hang this far below its planks, and the
    ## loader stands a piece on its lowest point, so the wall is set down
    ## by this much to put the planks on the foundation.
  GableProud = 0.35'f32
  WindowProud = 0.3'f32
    ## A window stands this far outside the wall it sits in.
    ## Doors and windows stand this far outside the gable they sit in.
  DoorReach = 1.4'f32
  DoorScale = 1.12'f32
    ## The door leaf is 0.9m wide; scaled to fill the one metre cube gap.
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
    RoofStyle(node: "roof_02a", along: 2.0, span: 7.12, height: 6.84,
      overlap: 0.5),
    RoofStyle(node: "roof_03a", along: 2.25, span: 6.91, height: 6.63,
      overlap: 0.35),
    RoofStyle(node: "roof_04a", along: 2.0, span: 6.45, height: 6.46,
      overlap: 0.35),
  ]
  ThatchRoof = RoofStyle(node: "roof_01a", along: 2.5, span: 7.12,
    height: 6.82, overlap: 0.55)
  WallPanels = ["wall_02a", "wall_06a"]
    ## Two metre panels, three metres tall, planks and plaster. The kit's
    ## other panel has a door moulded into it and reads as a second door.
  WallFiller = "wall_01a"
    ## The one metre panel that finishes a run.
  DoorPanels = ["entrance_02a", "entrance_03a"]
    ## Meadow wall panels with a door in them, the size of a wall panel.
  SodGrass = ["grass_patch_01a", "grass_patch_02a", "grass_patch_03a"]

  HouseNodes: array[DecorKit, seq[string]] = [
    @[],
    @["grass_patch_01a", "grass_patch_02a", "grass_patch_03a"],
    @["foundation_block_01a", "foundation_block_02a", "stairs_03a",
      "entrance_02a", "entrance_03a", "wood_pillar_corner_01a"],
    @[],
    @[],
    @[],
    @["door_01a", "window_01a", "roof_01a", "roof_02a", "roof_03a",
      "roof_04a", "roof_structure_01a", "chimney_01a", "chimney_02a",
      "chimney_03a", "wall_01a", "wall_02a", "wall_06a"],
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
    yaw = 0.0'f32, scale = 1.0'f32) =
  ## Records one piece in the house's paint.
  b.pieces.add HousePiece(
    kit: kit, node: node, offset: vec3(x, y, z), yaw: yaw, tint: b.tint,
    scale: scale)

proc addTinted(b: var Builder, kit: DecorKit, node: string,
    x, y, z: float32, yaw: float32, tint: Vec3) =
  ## Records one piece in its own colour.
  b.pieces.add HousePiece(
    kit: kit, node: node, offset: vec3(x, y, z), yaw: yaw, tint: tint,
    scale: 1.0)

proc wallRun(
    b: var Builder, length: float32, panel: proc(b: var Builder, along: float32,
    width: float32)
) =
  ## Fills a run of `length` metres centred on zero with two metre panels
  ## and a one metre filler at each end when the run is odd, calling
  ## `panel` with the centre of each along the run.
  let
    twos = int(length / 2.0'f32)
    rest = length - float32(twos) * 2.0'f32
  var along = -length * 0.5'f32
  if rest > 0.5'f32:
    b.panel(along + rest * 0.25'f32, 1.0)
    along += rest * 0.5'f32
  for i in 0 ..< twos:
    b.panel(along + 1.0'f32, 2.0)
    along += 2.0'f32
  if rest > 0.5'f32:
    b.panel(along + rest * 0.25'f32, 1.0)

proc buildChalet(
    b: var Builder, roof: RoofStyle, modules: int, roofTint: Vec3,
    walled: bool
): tuple[depth, doorX: float32] =
  ## The shape both kinds share: a foundation ring, roof segments along z,
  ## gable walls, a door in the front gable. A walled house adds a row of
  ## wall panels between foundation and roof and puts the door in that
  ## row, on the foundation with stairs; a low one opens the foundation
  ## for the door.
  let
    depth = float32(modules) * roof.along -
      float32(modules - 1) * roof.overlap
    halfDepth = depth * 0.5'f32
    halfSpan = roof.span * 0.5'f32
    gableCubes = int(ceil(roof.span - 2.0'f32))
    cubeShift = float32(gableCubes - 1) * 0.5'f32
    doorX =
      if walled: round(b.rng.unit() - 0.5'f32) * DoorPanelWidth
      else:
        round((b.rng.unit() - 0.5'f32) * 2.0'f32 * DoorReach + cubeShift) -
          cubeShift
      ## Snapped onto the wall panel grid or the foundation cube grid.
    doorZ = halfDepth
    wallTop = if walled: FoundationHeight + WallHeight else: FoundationHeight
  ## Foundation: cubes under the eaves and along both gables.
  var z = -halfDepth + 0.5'f32
  while z < halfDepth:
    for x in [-halfSpan + 0.5'f32, halfSpan - 0.5'f32]:
      b.add(MeadowBuildings, b.rng.pick(Cubes), x, 0, z)
    z += 1.0'f32
  for i in 0 ..< gableCubes:
    let x = float32(i) - cubeShift
    for side in [1.0'f32, -1.0'f32]:
      let gap = side > 0 and not walled and abs(x - doorX) < 0.5'f32
      if not gap:
        b.add(MeadowBuildings, b.rng.pick(Cubes), x, 0, halfDepth * side)
  if walled:
    ## Wall row: panels along both eaves and across both gables, the door
    ## panel in the front gable's run, corner pillars over the seams.
    let inset = halfSpan - WallThickness * 0.5'f32
    for side in [1.0'f32, -1.0'f32]:
      b.wallRun(depth, proc(b: var Builder, along, width: float32) =
        b.add(ValleyBuildings,
          if width > 1.5: b.rng.pick(WallPanels) else: WallFiller,
          inset * side, FoundationHeight, along))
      b.wallRun(roof.span, proc(b: var Builder, along, width: float32) =
        let isDoor = side > 0 and width > 1.5 and abs(along - doorX) < 0.5
        if isDoor:
          b.add(MeadowBuildings, b.rng.pick(DoorPanels), along,
            FoundationHeight, (halfDepth - WallThickness * 0.5'f32) * side,
            Turn)
        else:
          b.add(ValleyBuildings,
            if width > 1.5: b.rng.pick(WallPanels) else: WallFiller,
            along, FoundationHeight, (halfDepth - WallThickness * 0.5'f32) * side,
            Turn)
          if width > 1.5 and b.rng.below(3) == 0:
            b.add(ValleyBuildings, "window_01a", along,
              FoundationHeight + WindowLift,
              (halfDepth + WindowProud) * side, Turn))
    for x in [-halfSpan, halfSpan]:
      for zc in [-halfDepth, halfDepth]:
        b.add(MeadowBuildings, "wood_pillar_corner_01a", x, FoundationHeight,
          zc)
    b.add(MeadowBuildings, "stairs_03a", doorX, 0, doorZ + StairsStandOff)
  ## Roof, ridge along z, each joint overlapping and every other segment
  ## a little lower.
  let pitch = roof.along - roof.overlap
  for i in 0 ..< modules:
    let
      segZ = -halfDepth + roof.along * 0.5'f32 + pitch * float32(i)
      drop = if i mod 2 == 1: SegmentStagger else: 0.0'f32
    b.addTinted(ValleyBuildings, roof.node, 0, wallTop - drop, segZ, Turn,
      roofTint)
  ## Gable walls closing each end under the roof, stretched to the roof's
  ## span so the bottom corners meet the eaves.
  let
    gableScale = roof.span / GableWidth
    gableLift = wallTop - GableBeamDrop * gableScale
  for side in [1.0'f32, -1.0'f32]:
    b.add(ValleyBuildings, "roof_structure_01a", 0, gableLift,
      halfDepth * side, Turn, gableScale)
  if not walled:
    ## A low house's door stands in the foundation gap, and a window may
    ## sit in the gable above.
    b.add(ValleyBuildings, "door_01a", doorX, 0,
      doorZ + 0.5'f32 + GableProud * 0.5'f32, Turn, DoorScale)
    if b.rng.coin():
      let windowX = if doorX < 0: WindowReach else: -WindowReach
      b.add(ValleyBuildings, "window_01a", windowX,
        FoundationHeight + WindowLift, doorZ + GableProud, Turn)
  if b.rng.coin():
    b.add(ValleyBuildings, "window_01a",
      (b.rng.unit() - 0.5'f32) * 2.0'f32 * WindowReach,
      wallTop + WindowLift, -doorZ - GableProud, Turn)
  (depth: depth, doorX: doorX)

proc buildCottage(b: var Builder) =
  ## A walled house: foundation, a row of plank walls with the door and
  ## windows, and two or three roof segments of slate, shingle, or reed
  ## on top, with a chimney by coin flip.
  let
    roof = b.rng.pick(CottageRoofs)
    modules = 2 + int(b.rng.below(2))
    house = b.buildChalet(roof, modules, b.tint, true)
  if b.rng.coin():
    b.add(ValleyBuildings, b.rng.pick(Chimneys), 0,
      FoundationHeight + WallHeight + roof.height - ChimneySink,
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
