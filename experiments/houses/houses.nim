## House lab: a grid of heartleaf houses built from consecutive seeds on a
## flat meadow, for judging how the kit pieces seat against each other and
## how much the recipes vary, without launching the game.
##
##   R        reroll every house
##   K        cycle mixed, cottages only, longhouses only
##   drag     orbit, wheel zooms
##   Escape   quit
##
## Run from the repo root: nim r experiments/houses/houses.nim

import
  std/math,
  opengl, vmath, windy,
  polyworld/[noises, pathing, quadterrain, shadows, toon],
  ../../examples/heartleaf/[decor, houses, houseview]

const
  LabSide = 40'i32
  LabOrigin = GridTiles div 2 - LabSide div 2
    ## The flat layer sits centred on the world origin.
  GridCount = 3
  HouseSpacing = 12.0'f32
  LabHour = 11.0'f32

type KindFilter = enum
  Mixed, OnlyCottages, OnlyLonghouses

var
  window = newWindow("House lab", ivec2(1280, 800))
  rerolls = 0'i32
  filter = Mixed
  yaw = 0.7'f32
  pitch = 0.8'f32
  distance = 34.0'f32

proc flatMeadow() =
  ## One flat grass layer under the whole grid.
  var layer = QuadLayer(
    originX: LabOrigin, originZ: LabOrigin,
    width: LabSide, depth: LabSide,
    slab: false,
    tiles: newSeq[Tile](LabSide * LabSide))
  for tile in layer.tiles.mitems:
    tile = Tile(
      flags: TileExists or TileConnectedEast or TileConnectedSouth,
      kind: GrassTile,
      tops: packedHeights([0'i32, 0, 0, 0]))
  layers = @[layer]

proc kindFor(index: int): HouseKind =
  ## Which recipe one grid cell shows under the current filter.
  case filter
  of OnlyCottages: Cottage
  of OnlyLonghouses: Longhouse
  of Mixed: houseKindFor(rerolls, index)

proc rebuild(packs: HousePacks) =
  ## Places the grid and rebakes.
  clearProps()
  for row in 0 ..< GridCount:
    for col in 0 ..< GridCount:
      let
        index = row * GridCount + col
        seed = 1000 + rerolls * 100 + int32(index)
        x = (float32(col) - 1.0'f32) * HouseSpacing
        z = (float32(row) - 1.0'f32) * HouseSpacing
      packs.placeHouse(
        buildHouse(seed, kindFor(index)), vec3(x, 0, z), PI)
  bakeTerrain(rebuildWalkability = false)

proc main() =
  ## Runs the lab until the window closes.
  makeContextCurrent(window)
  loadExtensions()
  flatMeadow()
  computeWalkable()
  initTerrain()
  var visibility = newSeq[uint8](GridTiles * GridTiles)
  for value in visibility.mitems:
    value = 255
  uploadTerrainVisibility(visibility)
  var toonContext = newToonContext()
  toonContext.setPalette(paletteAtHour(LabHour))
  setEnvironmentPalette(toonContext)
  applySunHour(LabHour)
  let packs = loadHousePacks()
  rebuild(packs)
  echo "house lab: R rerolls, K cycles kinds, drag orbits, wheel zooms"

  window.onButtonPress = proc(button: Button) =
    case button
    of KeyR:
      inc rerolls
      rebuild(packs)
    of KeyK:
      filter = KindFilter((ord(filter) + 1) mod 3)
      rebuild(packs)
      echo "showing ", filter
    of KeyEscape:
      window.closeRequested = true
    else: discard

  while not window.closeRequested:
    pollEvents()
    if window.buttonDown[MouseLeft]:
      yaw += window.mouseDelta.x.float32 * 0.005'f32
      pitch = clamp(
        pitch + window.mouseDelta.y.float32 * 0.005'f32, 0.15'f32, 1.5'f32)
    if window.scrollDelta.y != 0:
      distance = clamp(
        distance * pow(0.9'f32, window.scrollDelta.y), 8.0'f32, 120.0'f32)
    let
      eye = vec3(
        cos(yaw) * cos(pitch) * distance,
        sin(pitch) * distance,
        sin(yaw) * cos(pitch) * distance)
      aspect = window.size.x.float32 / max(window.size.y.float32, 1.0'f32)
      viewProjection = perspective(45.0'f32, aspect, 0.1'f32, 500.0'f32) *
        lookAt(eye, vec3(0, 1.5, 0), vec3(0, 1, 0))
    glViewport(0, 0, window.size.x, window.size.y)
    applySunHour(LabHour)
    sunDepthPasses(window.size):
      drawTerrainSunDepth()
    glClearColor(0.55, 0.72, 0.9, 1.0)
    glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
    drawTerrain(viewProjection)
    window.swapBuffers()

main()
