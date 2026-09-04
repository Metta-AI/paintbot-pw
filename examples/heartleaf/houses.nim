## Heartleaf houses: recipes that turn a seed into a list of kit pieces,
## built the way golden valley's own prefab houses are built. Pure CPU,
## in metres, so headless tests can check every piece; the viewer scales
## and rotates the result.
##
## The prefabs, measured: a box of the kit's three metre wall panels
## standing on the ground, corner posts at its corners, the door and the
## windows being panels of that box; a plinth outside the box at ground
## level, a course of small bricks or a timber sill; the steep A-frame
## roof standing with its eave tips at shoulder height so the top of the
## walls hides inside it, its ridge running the long way; the plank gable
## piece closing each end above the wall, its rafters running on past the
## eaves. A chimney or a timber crest rides the ridge. A cottage is four
## or five segments of reed, slate, or shingle over plaster walls. A
## longhouse is four segments of straw thatch tinted to turf with grass
## along the ridge, over walls of stone cubes three high, the viking sod
## house.

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
  RoofLift = 2.1'f32
    ## Where the eave tips stand, as in the prefabs: well below the top of
    ## the walls, which hides inside the roof.
  WallHeight = 3.0'f32
  WallHalfSpan = 2.75'f32
    ## The outer face of the eave walls, across; the roof overhangs it.
  WallEndInset = 0.8'f32
    ## The gable walls stand this far inside the roof's ends.
  PanelThickness = 0.52'f32
  PostSize = 0.76'f32
  CourseSink = 0.25'f32
    ## The brick course sits this far into the ground, so more wall shows.
  BrickLength = 1.11'f32
  BrickThickness = 0.63'f32
  CornerSize = 0.87'f32
  CubeLength = 1.0'f32
  CubeRows = 3
    ## Stone longhouse walls are this many cubes high.
  DoorGapBricks = 2
    ## Bricks left out of the course in front of the door.
  DoorProud = 0.3'f32
    ## The door leaf stands this far outside the panel it is set in.
  PlinthBeamLength = 6.0'f32
  PlinthBeamThickness = 0.62'f32
  MaxDepth = 10.0'f32
    ## The prefab length, and exactly the five-tile house pad.
  ChimneySink = 0.45'f32
  CrestLegs = 1.87'f32
    ## Half the crest's leg spread across the ridge; the legs rest on the
    ## slopes there.
  GableWidth = 6.27'f32
  GablePlankHeight = 4.82'f32
    ## The gable wall piece's planks, above its rafters, as authored.
  GableRafterDrop = 0.89'f32
    ## Its rafters run this far below the planks, on down the slope.
  GableProud = 0.02'f32
    ## The gable piece stands this far outside the wall face below it.
  WindowChance = 0.4'f32
  WidePanelChance = 0.7'f32
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
    ## Roofs and the crest are authored with the ridge along x, and the
    ## wall pieces with their run along z; the house runs its ridge along
    ## z, so roofs and gable walls turn a quarter.

  Bricks = ["wall_base_01a", "wall_base_01b"]
  Corner = "wall_base_02a"
  Cubes = ["foundation_block_01a", "foundation_block_02a"]
  Post = "wall_03a"
  PlainWide = "wall_02a"
  PlainNarrow = "wall_01a"
  WindowWide = "wall_04a"
  WindowNarrow = "wall_05a"
  DoorPanel* = "wall_02a"
    ## The door leaf stands on a plain wide panel, as in the prefabs.
  PlinthBeam = "beam_02a"
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
    @["wall_base_01a", "wall_base_01b", "wall_base_02a", "wall_01a",
      "wall_02a", "wall_03a", "wall_04a", "wall_05a", "beam_02a",
      "door_01a", "roof_01a", "roof_02a", "roof_03a", "roof_04a",
      "roof_structure_01a", "roof_structure_02a", "chimney_01a",
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

type Panel = object
  node: string
  length: float32
  door: bool

proc panelRun(b: var Builder, nominal: int, withDoor: bool): seq[Panel] =
  ## Panels filling `nominal` metres of wall: wide and narrow, plain and
  ## windowed, and the door panel somewhere along it when asked.
  var left = nominal - (if withDoor: 2 else: 0)
  while left > 0:
    if left >= 2 and b.rng.unit() < WidePanelChance:
      let windowed = b.rng.unit() < WindowChance
      result.add Panel(
        node: if windowed: WindowWide else: PlainWide, length: 2.0)
      left -= 2
    else:
      let windowed = b.rng.unit() < WindowChance
      result.add Panel(
        node: if windowed: WindowNarrow else: PlainNarrow, length: 1.0)
      dec left
  if withDoor:
    result.insert(Panel(node: DoorPanel, length: 2.0, door: true),
      int(b.rng.below(int32(result.len + 1))))

proc wallRun(b: var Builder, run: float32, withDoor: bool,
    at: proc(along: float32): Vec3, yaw: float32): float32 =
  ## Panels end to end along one wall between its posts, stretched a
  ## little to fill the run exactly. `at` maps a distance along the run
  ## from its middle to the piece's spot. Returns where the door panel's
  ## centre landed along the run.
  let
    nominal = max(int(round(run)), if withDoor: 2 else: 1)
    stretch = run / float32(nominal)
  var cursor = -run * 0.5'f32
  for panel in b.panelRun(nominal, withDoor):
    let
      length = panel.length * stretch
      middle = cursor + length * 0.5'f32
      spot = at(middle)
    b.add(ValleyBuildings, panel.node, spot.x, spot.y, spot.z, yaw, 1.0,
      vec3(1, 1, stretch))
    if panel.door:
      result = middle
    cursor += length

proc plasterWalls(b: var Builder, halfDepth: float32): float32 =
  ## The cottage wall box: posts at the corners, panel runs between them,
  ## the door panel in the front run. Returns the door's x.
  let
    wz = halfDepth - WallEndInset
    faceX = WallHalfSpan - PanelThickness * 0.5'f32
    faceZ = wz - PanelThickness * 0.5'f32
    postX = WallHalfSpan - PostSize * 0.5'f32
    postZ = wz - PostSize * 0.5'f32
    eaveRun = 2.0'f32 * (wz - PostSize)
    gableRun = 2.0'f32 * (WallHalfSpan - PostSize)
  for x in [-postX, postX]:
    for z in [-postZ, postZ]:
      b.add(ValleyBuildings, Post, x, 0, z)
  for side in [1.0'f32, -1.0'f32]:
    discard b.wallRun(eaveRun, false,
      proc(along: float32): Vec3 = vec3(faceX * side, 0, along), 0)
  result = b.wallRun(gableRun, true,
    proc(along: float32): Vec3 = vec3(along, 0, faceZ), Turn)
  b.add(ValleyBuildings, "door_01a", result, 0, wz + DoorProud, Turn)
  discard b.wallRun(gableRun, false,
    proc(along: float32): Vec3 = vec3(along, 0, -faceZ), Turn)

proc brickCourse(b: var Builder, halfDepth, doorX: float32) =
  ## A course of small bricks around the outside of the wall box at ground
  ## level, a corner block at each corner, a gap in front of the door.
  let
    wz = halfDepth - WallEndInset
    outerX = WallHalfSpan + BrickThickness
    outerZ = wz + BrickThickness
    inset = outerX - BrickThickness * 0.5'f32
    endInset = outerZ - BrickThickness * 0.5'f32
    cornerX = outerX - CornerSize * 0.5'f32
    cornerZ = outerZ - CornerSize * 0.5'f32
    eaveRun = 2.0'f32 * (outerZ - CornerSize)
    eaveCount = max(int(round(eaveRun / BrickLength)), 1)
    eaveStep = eaveRun / float32(eaveCount)
    gableRun = 2.0'f32 * (outerX - CornerSize)
    gableCount = max(int(round(gableRun / BrickLength)), 1)
    gableStep = gableRun / float32(gableCount)
    doorSlot = clamp(
      int(round((doorX + gableRun * 0.5'f32) / gableStep - 0.5'f32)),
      0, gableCount - 1)
    gapFrom = clamp(doorSlot - DoorGapBricks div 2, 0, gableCount - 1)
    gapTo = min(gapFrom + DoorGapBricks - 1, gableCount - 1)
  for side in [1.0'f32, -1.0'f32]:
    for i in 0 ..< eaveCount:
      b.add(ValleyBuildings, b.rng.pick(Bricks), inset * side, -CourseSink,
        -eaveRun * 0.5'f32 + eaveStep * (float32(i) + 0.5'f32))
    for i in 0 ..< gableCount:
      if side > 0 and i >= gapFrom and i <= gapTo:
        continue
      b.add(ValleyBuildings, b.rng.pick(Bricks),
        -gableRun * 0.5'f32 + gableStep * (float32(i) + 0.5'f32), -CourseSink,
        endInset * side, Turn)
  for x in [-cornerX, cornerX]:
    for z in [-cornerZ, cornerZ]:
      b.add(ValleyBuildings, Corner, x, -CourseSink, z)

proc beamPlinth(b: var Builder, halfDepth: float32) =
  ## A ring of heavy timber sills around the outside of the wall box at
  ## ground level, each stretched to its side.
  let
    wz = halfDepth - WallEndInset
    outerX = WallHalfSpan + PlinthBeamThickness
    outerZ = wz + PlinthBeamThickness
    atX = outerX - PlinthBeamThickness * 0.5'f32
    atZ = outerZ - PlinthBeamThickness * 0.5'f32
  for side in [1.0'f32, -1.0'f32]:
    b.add(ValleyBuildings, PlinthBeam, atX * side, 0, 0, 0, 1.0,
      vec3(1, 1, 2.0'f32 * outerZ / PlinthBeamLength))
    b.add(ValleyBuildings, PlinthBeam, 0, 0, atZ * side, Turn, 1.0,
      vec3(1, 1, 2.0'f32 * (outerX - PlinthBeamThickness) / PlinthBeamLength))

proc stoneWalls(b: var Builder, halfDepth: float32): float32 =
  ## The longhouse wall box: meadow stone cubes three high, a cube-wide
  ## gap two high in the front for the door. Returns the door's x.
  let
    wz = halfDepth - WallEndInset
    atX = WallHalfSpan - CubeLength * 0.5'f32
    atZ = wz - CubeLength * 0.5'f32
    eaveRun = 2.0'f32 * wz
    eaveCount = max(int(round(eaveRun / CubeLength)), 1)
    eaveStep = eaveRun / float32(eaveCount)
    gableRun = 2.0'f32 * (WallHalfSpan - CubeLength)
    gableCount = max(int(round(gableRun / CubeLength)), 1)
    gableStep = gableRun / float32(gableCount)
    doorSlot = int(b.rng.below(int32(gableCount)))
  result = -gableRun * 0.5'f32 + gableStep * (float32(doorSlot) + 0.5'f32)
  for row in 0 ..< CubeRows:
    let y = float32(row) * CubeLength - (if row == CubeRows - 1: 0.05'f32
      else: 0.0'f32)
    for side in [1.0'f32, -1.0'f32]:
      for i in 0 ..< eaveCount:
        b.add(MeadowBuildings, b.rng.pick(Cubes), atX * side, y,
          -eaveRun * 0.5'f32 + eaveStep * (float32(i) + 0.5'f32))
      for i in 0 ..< gableCount:
        if side > 0 and i == doorSlot and row < CubeRows - 1:
          continue
        b.add(MeadowBuildings, b.rng.pick(Cubes),
          -gableRun * 0.5'f32 + gableStep * (float32(i) + 0.5'f32), y,
          atZ * side)

proc roofAndGables(b: var Builder, roof: RoofStyle, modules: int,
    halfDepth: float32, roofTint: Vec3) =
  ## Roof segments along the ridge, each joint overlapping and every
  ## other segment a little lower; the plank gable piece above each end
  ## wall, stretched up so its rafters run parallel to the roof's slope,
  ## its planks starting at the eave line and their edge tucked under the
  ## roof.
  let pitch = roof.along - roof.overlap
  for i in 0 ..< modules:
    let
      segZ = -halfDepth + roof.along * 0.5'f32 + pitch * float32(i)
      drop = if i mod 2 == 1: SegmentStagger else: 0.0'f32
    b.addTinted(ValleyBuildings, roof.node, 0, RoofLift - drop, segZ, Turn,
      roofTint)
  let
    roofSlope = roof.height / (roof.span * 0.5'f32)
    gableSlope = GablePlankHeight / (GableWidth * 0.5'f32)
    gableStretch = vec3(1.0, roofSlope / gableSlope, 1.0)
    gableLift = RoofLift - GableRafterDrop * gableStretch.y
    gableZ = halfDepth - WallEndInset + GableProud + PanelThickness * 0.5'f32
  for side in [1.0'f32, -1.0'f32]:
    b.add(ValleyBuildings, "roof_structure_01a", 0, gableLift,
      gableZ * side, Turn, 1.0, gableStretch)

proc houseDepth(roof: RoofStyle, modules: int): float32 =
  ## How long a roof of that many segments runs, capped at the pad.
  min(float32(modules) * roof.along - float32(modules - 1) * roof.overlap,
    MaxDepth)

proc buildCottage(b: var Builder) =
  ## Plaster walls under four or five segments of reed, slate, or shingle,
  ## on a brick course or a timber plinth, a chimney by coin flip, a
  ## timber crest by coin flip.
  let
    roof = b.rng.pick(CottageRoofs)
    modules = 4 + int(b.rng.below(2))
    depth = houseDepth(roof, modules)
    halfDepth = depth * 0.5'f32
    doorX = b.plasterWalls(halfDepth)
  if b.rng.coin():
    b.brickCourse(halfDepth, doorX)
  else:
    b.beamPlinth(halfDepth)
  b.roofAndGables(roof, modules, halfDepth, b.tint)
  if b.rng.coin():
    b.add(ValleyBuildings, b.rng.pick(Chimneys), 0,
      RoofLift + roof.height - ChimneySink,
      (b.rng.unit() - 0.5'f32) * depth * 0.6'f32)
  if b.rng.coin():
    let legsAt = RoofLift +
      roof.height * (1.0'f32 - CrestLegs / (roof.span * 0.5'f32))
    b.add(ValleyBuildings, Crest, 0, legsAt,
      (b.rng.unit() - 0.5'f32) * depth * 0.4'f32, Turn)

proc buildLonghouse(b: var Builder) =
  ## Stone cube walls under four segments of straw thatch tinted hard to
  ## turf, a door in a gap in the stone, grass along the ridge and in rows
  ## down both slopes, a squat chimney by coin flip.
  let
    roof = ThatchRoof
    modules = 4
    depth = houseDepth(roof, modules)
    halfDepth = depth * 0.5'f32
    doorX = b.stoneWalls(halfDepth)
  b.add(ValleyBuildings, "door_01a", doorX, 0, halfDepth - WallEndInset,
    Turn)
  b.roofAndGables(roof, modules, halfDepth, SodTint * b.tint)
  let
    peak = RoofLift + roof.height
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
      (b.rng.unit() - 0.5'f32) * depth * 0.6'f32)

proc buildHouse*(seed: int32, kind: HouseKind): seq[HousePiece] =
  ## Every piece of one house, in a fixed order from one seeded stream.
  var b = Builder(rng: initRng(seed, HouseSalt))
  b.tint = b.rng.paint()
  case kind
  of Cottage: b.buildCottage()
  of Longhouse: b.buildLonghouse()
  b.pieces
