## Light vs Dark map generation.
##
## The map is generated entirely with integers, from an explicit seed, and is
## symmetric by construction under a 180 degree rotation about the centre of
## the grid: every height and tile kind is decided once for the canonical half
## and copied to its mirror, so neither player can be handed better ground.
##
## Each town sits on a rough corner plateau that runs to the two map edges,
## so only the inward sides have cliffs. A diagonal ramp is the way down.
## Grass and sand mix on top, with a few trees, and two natural expansions
## sit in clearings just outside the east and south walls.
##
## This module writes the shared `pathing.layers` terrain model once at
## startup and then returns a `MapData` value. The simulation reads only the
## returned value, never the layers, so the renderer's decoration can never
## change how a match plays out. Graphics may sample `surfaceHeight` and must
## not write simulation state.

import
  std/strformat,
  polyworld/[fixed, hashes, noises, pathing, profiles, rngs],
  content

static:
  doAssert GridSide.int == GridTiles,
    "content and pathing disagree about the size of the map"

## Terrain shape
##
## Heights are in packed 1/8-tile steps, the same unit `pathing.pack` uses.
## Blend amounts are fixed-point ratios over `MapBlendScale`.

const
  TerrainAmplitudeSteps = 11'i32
  WaterLevelSteps = -9'i32
  RiverBedSteps = -16'i32
  FordBedSteps = -3'i32

  RiverHalfWidth2 = 23
    ## River half width in doubled tile units, so tile centres stay integral.
  CornerSide = GridSide + 1
    ## Corners run 0 .. GridSide inclusive.

  BaseCenterTile = 22'i32
    ## Light's town hall centre. Dark's is its mirror.
  BasePlateauRaise = 16'i32
    ## How much higher the town sits than the natural ground, in
    ## 1/8-tile steps. One tile of drop at this height is a wall.
  PadWall = 36'i32
    ## How far the two inward cliffs sit from the map corner.
  PadRound = 48'i32
    ## Euclidean cap that rounds the plateau's inward corner.
  PadRoughness = 4'i32
    ## How much the cliff line wanders, in tiles.
  RampLength = 7'i32
  RampHalfWidth = 2'i32
    ## Diagonal corridor toward the map centre; the only way off the pad.
  ClearingRadius = 5'i32
  LightEastClearing = (48, 22)
  LightSouthClearing = (22, 48)
    ## Natural expansions just outside the two inward walls.
  PadNoiseStream = 0x9E3779B97F4A7C15'u64
  SandNoiseStream = 0xC2B2AE3D27D4EB4F'u64
  BumpNoiseStream = 0xA5A5A5A5A5A5A5A5'u64
  ForestNoiseStream = 0xD1B54A32D192ED03'u64
  ForestDetailStream = 0x8CB92BA72F3D8DD7'u64
  ForestRollStream = 0x2545F4914F6CDD1D'u64
  ForestDensityPercent = 90'i64
    ## Chance that a candidate at the forest map's peak passes the gate.
  PlateauTrees = 20

  FordCorners = [(96, 32), (64, 64), (32, 96)]
    ## Corner coordinates, so the middle ford sits exactly on the axis of
    ## symmetry and the outer two are each other's mirror.
  FordRadius = [13, 17, 13]
  MinimumFordWidth = 3

  HallFootprint = 3'i32
  MineFootprint = 2'i32
  LightHallOrigin = (21'i32, 21'i32)
  LightMainMine = (25'i32, 18'i32)
  LightEastMine = (47'i32, 21'i32)
  LightSouthMine = (21'i32, 47'i32)
    ## Two natural expansions, one on each inward side of the keep.

  GroveInnerRing = 16'i32
  GroveOuterRing = 30'i32
  GroveTiles = 150
  ScatterTiles = 420
  MinimumGroveTiles = 100
  MinimumSpawnTiles = 8

type
  MineSpot* = object
    id*: int32
    origin*: Tile2
      ## North-west corner of the two-by-two footprint.
    gold*: int32

  MapData* = object
    seed*: int32
    passable*: seq[uint8]
      ## Terrain walkability only: slope, map edge, and water. Trees and
      ## structures are simulation state and live in the world's blocker grid.
    kinds*: seq[uint8]
      ## Tile kind per cell, kept for the minimap and for debugging.
    heights*: seq[int16]
      ## Mean packed terrain height per tile for integer line of sight.
    treeWood*: seq[int16]
      ## Harvestable wood remaining on each tile, zero where there is no tree.
    mines*: seq[MineSpot]
    hallOrigin*: array[PlayerCount, Tile2]
    hash*: uint64

proc triangleWave(value, period: int): int32 =
  ## Returns a deterministic signed triangle wave in fixed integer units.
  ## Odd about zero, which is what keeps the wiggled river symmetric.
  let
    phase = ((value mod period) + period) mod period
    quarter = period div 4
  if phase < quarter:
    int32(phase * MapBlendScale div quarter)
  elif phase < quarter * 2:
    int32((quarter * 2 - phase) * MapBlendScale div quarter)
  elif phase < quarter * 3:
    -int32((phase - quarter * 2) * MapBlendScale div quarter)
  else:
    -int32((period - phase) * MapBlendScale div quarter)

## Symmetry

proc mirrorCorner(cx, cz: int): (int, int) =
  ## Rotates a corner 180 degrees about the centre of the grid.
  (GridSide.int - cx, GridSide.int - cz)

proc canonicalCorner(cx, cz: int): (int, int) =
  ## Folds a corner onto the canonical half of the map. Terrain is generated
  ## for the canonical representative only, so both halves are identical by
  ## construction and no averaging step can leave a seam.
  let (mx, mz) = mirrorCorner(cx, cz)
  if cz * CornerSide + cx <= mz * CornerSide + mx: (cx, cz) else: (mx, mz)

## Generation

proc generateMap*(seed: int32): MapData {.measure.} =
  ## Builds the terrain layers for one seed and returns the derived map data.
  ## Writes the shared `pathing.layers` and refreshes walkability once.

  proc ground(cx, cz: int): int32 =
    ## Layered value noise, evaluated at the canonical corner.
    let (nx, nz) = canonicalCorner(cx, cz)
    let value =
      valueNoise(seed, 0xA0761D6478BD642F'u64, nx, nz, 24) * 4 +
      valueNoise(seed, 0xE7037ED1A0B428DB'u64, nx, nz, 12) * 2 +
      valueNoise(seed, 0x8EBC6AF09C88C6E3'u64, nx, nz, 6)
    int32(roundDivision(
      int64(value) * TerrainAmplitudeSteps,
      int64(MapBlendScale) * 7
    ))

  proc riverBlend(cx2, cz2: int): int32 =
    ## How deep inside the river band a doubled coordinate lies, from zero at
    ## the banks to `MapBlendScale` at the bed. The wiggle is an odd function
    ## of `cx2 - cz2`, which keeps the whole band symmetric.
    let
      wiggle2 = int(triangleWave(cx2 - cz2, 168)) * 8 div MapBlendScale
      axisDistance2 = abs(cx2 + cz2 - GridSide.int * 2 - wiggle2)
      ratio = clamp(
        int32(axisDistance2 * MapBlendScale div RiverHalfWidth2),
        0'i32,
        MapBlendScale
      )
      cubic = int32(roundDivision(
        int64(ratio) * int64(ratio) * int64(ratio),
        int64(MapBlendScale) * int64(MapBlendScale)
      ))
    MapBlendScale - cubic

  let plateauHeight =
    ground(BaseCenterTile.int, BaseCenterTile.int) +
    BasePlateauRaise

  proc padWobble(nx, nz: int): int =
    ## Low-frequency wander of the cliff line, in tiles.
    let n = valueNoise(seed, PadNoiseStream, nx, nz, 10)
    int(roundDivision(int64(n) * PadRoughness, MapBlendScale))

  proc onPadCorner(cx, cz: int): bool =
    ## Whether a corner sits on the rough corner plateau.
    let (nx, nz) = canonicalCorner(cx, cz)
    if nx < 0 or nz < 0:
      return false
    let
      wobble = padWobble(nx, nz)
      wall = PadWall.int + wobble
      radius = PadRound.int + wobble
    nx <= wall and nz <= wall and
      nx * nx + nz * nz <= radius * radius

  proc inRampCorridor(cx, cz: int): bool =
    ## Whether a point lies on either diagonal exit toward the map centre.
    let (nx, nz) = canonicalCorner(cx, cz)
    nx >= 0 and nz >= 0 and
      abs(nx - nz) <= RampHalfWidth.int and
      max(nx, nz) >= BaseCenterTile.int

  proc inClearingTile(x, y: int): bool =
    ## Whether a tile sits in one of the four expansion clearings.
    for (cx, cy) in [LightEastClearing, LightSouthClearing]:
      if max(abs(x - cx), abs(y - cy)) <= ClearingRadius.int:
        return true
      let (mx, my) = mirrorTile(int32(cx), int32(cy))
      if max(abs(x - mx.int), abs(y - my.int)) <= ClearingRadius.int:
        return true
    false

  proc tileOnPad(x, z: int): bool =
    ## Whether every corner of a tile sits on a raised pad.
    onPadCorner(x, z) and
      onPadCorner(x + 1, z) and
      onPadCorner(x, z + 1) and
      onPadCorner(x + 1, z + 1)

  proc tileOnRamp(x, z: int): bool =
    ## Whether a tile is part of the sloped exit off the pad.
    if tileOnPad(x, z):
      return false
    for (cx, cz) in [(x, z), (x + 1, z), (x, z + 1), (x + 1, z + 1)]:
      if not inRampCorridor(cx, cz):
        continue
      let
        (nx, nz) = canonicalCorner(cx, cz)
        bx = max(nx - RampLength.int, 0)
        bz = max(nz - RampLength.int, 0)
      if onPadCorner(bx, bz):
        return true
    false

  proc tileIsCliff(x, z: int): bool =
    ## Whether a tile straddles the pad edge and is not the ramp.
    if tileOnPad(x, z) or tileOnRamp(x, z):
      return false
    var
      anyPad = false
      anyOff = false
    for (cx, cz) in [(x, z), (x + 1, z), (x, z + 1), (x + 1, z + 1)]:
      if onPadCorner(cx, cz):
        anyPad = true
      else:
        anyOff = true
    anyPad and anyOff

  proc canonicalTile(x, z: int): (int, int) =
    ## Folds a tile onto the canonical half of the map.
    let (mx, mz) = mirrorTile(int32(x), int32(z))
    if z * GridSide.int + x <= mz.int * GridSide.int + mx.int:
      (x, z)
    else:
      (mx.int, mz.int)

  proc padSand(x, z: int): bool =
    ## Whether a plateau tile reads as sand instead of grass.
    let (nx, nz) = canonicalTile(x, z)
    valueNoise(seed, SandNoiseStream, nx, nz, 5) > 180

  proc makeCorner(cx, cz: int): int32 =
    ## Corner height as a pure function of the corner coordinate, so tiles
    ## that share a corner always agree and the surface grows no walls.
    result = ground(cx, cz)
    result = blendHeight(result, RiverBedSteps, riverBlend(cx * 2, cz * 2))
    for index, (fordX, fordZ) in FordCorners:
      let
        deltaX = int64(cx - fordX)
        deltaZ = int64(cz - fordZ)
        distance = integerSqrt(
          (deltaX * deltaX + deltaZ * deltaZ) *
          int64(MapBlendScale) * int64(MapBlendScale)
        )
        amount = smoothstep(
          MapBlendScale - int32(distance div FordRadius[index])
        )
      result = blendHeight(result, FordBedSteps, amount)
    let (nx, nz) = canonicalCorner(cx, cz)
    for (ccx, ccz) in [LightEastClearing, LightSouthClearing]:
      let cr = max(abs(nx - ccx), abs(nz - ccz))
      if cr <= ClearingRadius.int + 2:
        let amount = smoothstep(
          int32(ClearingRadius.int + 2 - cr) *
          MapBlendScale div 2
        )
        result = blendHeight(result, ground(ccx, ccz), amount)
    if onPadCorner(cx, cz):
      let
        n = valueNoise(seed, BumpNoiseStream, nx, nz, 8)
        bump = int32(roundDivision(int64(n) * 2, MapBlendScale))
      result = plateauHeight + bump
    elif inRampCorridor(cx, cz):
      var
        px = nx
        pz = nz
        steps = 0
      while steps <= RampLength.int and not onPadCorner(px, pz):
        if px > 0:
          dec px
        if pz > 0:
          dec pz
        inc steps
      if steps > 0 and steps <= RampLength.int and
          onPadCorner(px, pz):
        let amount = int32(RampLength.int - steps) *
          MapBlendScale div RampLength
        result = blendHeight(
          result,
          plateauHeight,
          smoothstep(amount)
        )

  var cornerHeights = newSeq[int16](CornerSide * CornerSide)
  for cz in 0 .. GridSide.int:
    for cx in 0 .. GridSide.int:
      cornerHeights[cz * CornerSide + cx] = int16(makeCorner(cx, cz))
  template corner(cx, cz: int): int32 =
    int32(cornerHeights[(cz) * CornerSide + (cx)])

  var groundLayer = QuadLayer(
    originX: 0, originZ: 0,
    width: GridSide, depth: GridSide,
    slab: false,
    tiles: newSeq[Tile](GridCells)
  )
  template groundTile(x, z: int): var Tile =
    groundLayer.tiles[(z) * GridSide + (x)]

  for z in 0 ..< GridSide.int:
    for x in 0 ..< GridSide.int:
      let
        tops = [corner(x, z), corner(x + 1, z),
                corner(x, z + 1), corner(x + 1, z + 1)]
        heightSum = tops[0] + tops[1] + tops[2] + tops[3]
        nearRiver = riverBlend(x * 2 + 1, z * 2 + 1) > 102
        kind =
          if nearRiver and heightSum < 10: MarshTile
          elif heightSum > TerrainAmplitudeSteps * 2: RockTile
          else: GrassTile
      groundTile(x, z) = Tile(
        flags: TileExists or TileConnectedEast or TileConnectedSouth,
        kind: kind,
        tops: packedHeights(tops)
      )
      if heightSum < WaterLevelSteps * 4:
        groundTile(x, z).impassable = true

  ## The plateau mixes grass and sand. The ramp is worn sand. The cliff
  ## is rock and is forced closed so a lucky slope cannot open a second exit.
  for z in 0 ..< GridSide.int:
    for x in 0 ..< GridSide.int:
      if tileOnPad(x, z):
        groundTile(x, z).kind =
          if padSand(x, z): RoadTile else: GrassTile
      elif tileOnRamp(x, z):
        groundTile(x, z).kind = RoadTile
      elif tileIsCliff(x, z):
        groundTile(x, z).kind = RockTile
        groundTile(x, z).impassable = true
      elif inClearingTile(x, z):
        groundTile(x, z).kind = GrassTile

  ## Water: one flat sheet over every tile carved below the water level.
  var water = QuadLayer(
    originX: 0, originZ: 0,
    width: GridSide, depth: GridSide,
    slab: true,
    water: true,
    tiles: newSeq[Tile](GridCells)
  )
  for z in 0 ..< GridSide.int:
    for x in 0 ..< GridSide.int:
      let tops = groundTile(x, z).tops
      if int32(tops[0]) + int32(tops[1]) + int32(tops[2]) +
          int32(tops[3]) < WaterLevelSteps * 4:
        water.tiles[z * GridSide + x] = Tile(
          flags: TileExists,
          tops: packedHeights([WaterLevelSteps, WaterLevelSteps,
                               WaterLevelSteps, WaterLevelSteps]),
          bottoms: packedHeights([WaterLevelSteps - 3, WaterLevelSteps - 3,
                                  WaterLevelSteps - 3, WaterLevelSteps - 3])
        )

  layers = @[groundLayer, water]
  computeWalkable()

  ## Derived grids. Trees are deliberately absent from `passable`: a felled
  ## tree must open its tile without anything recomputing terrain walkability.
  var map = MapData(
    seed: seed,
    passable: newSeq[uint8](GridCells),
    kinds: newSeq[uint8](GridCells),
    heights: newSeq[int16](GridCells),
    treeWood: newSeq[int16](GridCells)
  )
  for z in 0 ..< GridSide.int:
    for x in 0 ..< GridSide.int:
      let index = z * GridSide.int + x
      map.passable[index] = uint8(isWalkable(0, x, z))
      map.kinds[index] = uint8(groundLayer.tiles[index].kind)
      let tops = groundLayer.tiles[index].tops
      map.heights[index] = int16(
        (int32(tops[0]) + int32(tops[1]) +
          int32(tops[2]) + int32(tops[3])) div 4
      )

  ## Structures. Both halls and all six mines are placed as mirror pairs.
  ## A footprint of side `f` at origin `a` covers `a ..< a + f`, so its mirror
  ## covers `GridSide - f - a ..< GridSide - a`.
  proc mirrorOrigin(x, y, footprint: int32): (int32, int32) =
    (GridSide - footprint - x, GridSide - footprint - y)

  let
    (lightHallX, lightHallY) = LightHallOrigin
    (darkHallX, darkHallY) = mirrorOrigin(lightHallX, lightHallY, HallFootprint)
  map.hallOrigin[LightPlayer] = tile2(lightHallX, lightHallY)
  map.hallOrigin[DarkPlayer] = tile2(darkHallX, darkHallY)

  var mineId = FirstMineId
  for (spot, gold) in [
    (LightMainMine, MainMineGold),
    (LightEastMine, ExpansionMineGold),
    (LightSouthMine, ExpansionMineGold)
  ]:
    let
      (mineX, mineY) = spot
      (mirrorX, mirrorY) = mirrorOrigin(mineX, mineY, MineFootprint)
    map.mines.add MineSpot(
      id: mineId, origin: tile2(mineX, mineY), gold: gold)
    map.mines.add MineSpot(
      id: mineId + 1, origin: tile2(mirrorX, mirrorY), gold: gold)
    mineId += 2

  ## Forests. Every planted tile writes its mirror too, so the two players get
  ## identical wood no matter which half the sampler happened to land on.
  proc covers(origin: Tile2, footprint, margin, x, y: int32): bool =
    x >= int32(origin.x) - margin and
      x < int32(origin.x) + footprint + margin and
      y >= int32(origin.y) - margin and
      y < int32(origin.y) + footprint + margin

  proc openForTree(x, y: int32): bool =
    ## Shared tree rules: open grass, not a ramp, clearing, hall, or mine.
    if not inGrid(x, y):
      return false
    let index = int(tileIndex(x, y))
    if map.passable[index] == 0 or map.treeWood[index] > 0:
      return false
    if map.kinds[index] != uint8(GrassTile):
      return false
    if tileOnRamp(x.int, y.int) or inClearingTile(x.int, y.int):
      return false
    for player in 0 ..< PlayerCount:
      if covers(map.hallOrigin[player], HallFootprint, 3, x, y):
        return false
    for mine in map.mines:
      if covers(mine.origin, MineFootprint, 3, x, y):
        return false
    true

  proc plantOn(x, y: int32, wantPad: bool): bool =
    ## Plants one tree and its mirror, or neither.
    let (mirrorX, mirrorY) = mirrorTile(x, y)
    if tileOnPad(x.int, y.int) != wantPad or
        tileOnPad(mirrorX.int, mirrorY.int) != wantPad:
      return false
    if not openForTree(x, y) or not openForTree(mirrorX, mirrorY):
      return false
    for (tileX, tileY) in [(x, y), (mirrorX, mirrorY)]:
      let index = int(tileIndex(tileX, tileY))
      map.treeWood[index] = WoodPerTree
      map.kinds[index] = uint8(TreeTile)
      layers[0].tiles[index].kind = TreeTile
    true

  proc plant(x, y: int32): bool =
    ## Plants one grove or scatter tree and its mirror, or neither.
    plantOn(x, y, false)

  ## Trees grow in woods, not at random: a low-frequency forest map (its own
  ## noise stream) gives each candidate a density. Nothing grows where it is
  ## negative, and above zero the chance rises with the noise, so the wood
  ## thickens toward its heart and thins to a ragged forest line at the
  ## zero crossing. The mirror is planted with its twin, so the woods stay
  ## symmetric even though the map is sampled from one side.
  var forestRng = initRng(seed, ForestRollStream)
  proc inForest(x, y: int32): bool =
    let
      forest = int64(
        valueNoise(seed, ForestNoiseStream, x.int, y.int, 20) * 2 +
        valueNoise(seed, ForestDetailStream, x.int, y.int, 10))
      roll = int64(forestRng.below(int32(MapBlendScale)))
    # forest ranges over ±3 * MapBlendScale and roll over MapBlendScale.
    # The chance is the squared normalized noise times the density: the
    # passes plant a fixed count, so the gate has to be steep for the woods
    # to gather at their hearts instead of spreading over every positive
    # patch. A tile at the peak passes ForestDensityPercent of the time.
    forest > 0 and
      roll * 300 * 3 * int64(MapBlendScale) <
        forest * forest * ForestDensityPercent

  ## The grove is each player's guaranteed starting wood, so it fills in two
  ## passes: forest-gated first, so it clumps like the rest of the woods,
  ## then ungated to reach the count on seeds whose forest map leaves the
  ## grove ring thin.
  let lightCentre = tile2(BaseCenterTile, BaseCenterTile)
  var
    mapRng = initRng(seed)
    planted = 0
  for gated in [true, false]:
    for attempt in 0 ..< GroveTiles * 60:
      if planted >= GroveTiles:
        break
      let
        x = mapRng.below(GridSide)
        y = mapRng.below(GridSide)
        ring = chebyshev(tile2(x, y), lightCentre)
      if ring < GroveInnerRing or ring > GroveOuterRing:
        continue
      if gated and not inForest(x, y):
        continue
      if plant(x, y):
        inc planted

  var
    scattered = 0
  for attempt in 0 ..< ScatterTiles * 60:
    if scattered >= ScatterTiles:
      break
    let
      x = mapRng.below(GridSide)
      y = mapRng.below(GridSide)
    ## Keep the fords clear so the chokepoints stay chokepoints.
    var nearFord = false
    for (fordX, fordZ) in FordCorners:
      if chebyshev(tile2(x, y), tile2(int32(fordX), int32(fordZ))) <= 7:
        nearFord = true
    if nearFord:
      continue
    if not inForest(x, y):
      continue
    if plant(x, y):
      inc scattered

  var plateauPlanted = 0
  for attempt in 0 ..< PlateauTrees * 40:
    if plateauPlanted >= PlateauTrees:
      break
    let
      x = mapRng.below(PadWall + 6)
      y = mapRng.below(PadWall + 6)
    if plantOn(x, y, true):
      inc plateauPlanted

  ## Fingerprint. Covers the packed terrain, the derived walkability, the
  ## trees, and every structure placement, so a generator change is caught at
  ## replay load rather than as a mysterious divergence later.
  var hash = HashySeed
  hash.addHashy(seed)
  hash.addHashy(layers.len)
  for layerIndex, layer in layers:
    hash.addHashy(layer.originX)
    hash.addHashy(layer.originZ)
    hash.addHashy(layer.width)
    hash.addHashy(layer.depth)
    hash.addHashy(layer.slab)
    hash.addHashy(layer.water)
    for index, tile in layer.tiles:
      hash.addHashy(uint32(tile.flags))
      hash.addHashy(uint32(tile.kind))
      for value in tile.tops:
        hash.addHashy(value)
      for value in tile.bottoms:
        hash.addHashy(value)
      hash.addHashy(layerWalkable[layerIndex][index])
  for index in 0 ..< GridCells:
    hash.addHashy(map.passable[index])
    hash.addHashy(map.heights[index])
    hash.addHashy(map.treeWood[index])
  for player in 0 ..< PlayerCount:
    hash.addHashy(map.hallOrigin[player].x)
    hash.addHashy(map.hallOrigin[player].y)
  for mine in map.mines:
    hash.addHashy(mine.id)
    hash.addHashy(mine.origin.x)
    hash.addHashy(mine.origin.y)
    hash.addHashy(mine.gold)
  map.hash = uint64(hash)
  map

## Checks
##
## Every one names the seed, so a bad seed is instantly reproducible.

proc blockedForSetup(map: MapData, x, y: int32): bool =
  ## Returns whether a tile is closed at the start of a match, counting
  ## terrain, trees, halls, and mines.
  if not inGrid(x, y):
    return true
  let index = tileIndex(x, y)
  if map.passable[index] == 0 or map.treeWood[index] > 0:
    return true
  for player in 0 ..< PlayerCount:
    let hall = map.hallOrigin[player]
    if x >= int32(hall.x) and x < int32(hall.x) + HallFootprint and
        y >= int32(hall.y) and y < int32(hall.y) + HallFootprint:
      return true
  for mine in map.mines:
    if x >= int32(mine.origin.x) and
        x < int32(mine.origin.x) + MineFootprint and
        y >= int32(mine.origin.y) and
        y < int32(mine.origin.y) + MineFootprint:
      return true
  false

const StepOffsets* = [
  (0'i32, -1'i32), (1'i32, -1'i32), (1'i32, 0'i32), (1'i32, 1'i32),
  (0'i32, 1'i32), (-1'i32, 1'i32), (-1'i32, 0'i32), (-1'i32, -1'i32)
]
  ## Neighbour scan order, clockwise from north. Fixed everywhere so that
  ## tie-breaking in movement, pathing, and flood fill is reproducible.

proc floodFrom(map: MapData, start: Tile2): seq[uint8] =
  ## Eight-neighbour integer flood fill over open setup tiles.
  result = newSeq[uint8](GridCells)
  if map.blockedForSetup(int32(start.x), int32(start.y)):
    return
  var frontier = @[start]
  result[tileIndex(start)] = 1
  while frontier.len > 0:
    let tile = frontier.pop()
    for (dx, dy) in StepOffsets:
      let
        nextX = int32(tile.x) + dx
        nextY = int32(tile.y) + dy
      if map.blockedForSetup(nextX, nextY):
        continue
      let index = tileIndex(nextX, nextY)
      if result[index] == 1:
        continue
      result[index] = 1
      frontier.add tile2(nextX, nextY)

proc freeTilesAround(map: MapData, origin: Tile2, footprint, ring: int32): int =
  ## Counts open tiles in the band around a square footprint.
  for y in int32(origin.y) - ring ..< int32(origin.y) + footprint + ring:
    for x in int32(origin.x) - ring ..< int32(origin.x) + footprint + ring:
      if not map.blockedForSetup(x, y):
        inc result

proc anyOpenNeighbour(map: MapData, origin: Tile2, footprint: int32): Tile2 =
  ## Returns one open tile touching a footprint, or an off-map tile when the
  ## footprint is completely walled in.
  for y in int32(origin.y) - 1 ..< int32(origin.y) + footprint + 1:
    for x in int32(origin.x) - 1 ..< int32(origin.x) + footprint + 1:
      if not map.blockedForSetup(x, y):
        return tile2(x, y)
  tile2(-1, -1)

proc fordWidth(map: MapData, cornerX, cornerZ: int): int =
  ## Counts open tiles along the line crossing the river at one ford.
  for offset in -10 .. 10:
    let
      x = int32(cornerX + offset)
      y = int32(cornerZ - offset)
    if not map.blockedForSetup(x, y):
      inc result

proc validateMap*(map: MapData) =
  ## Asserts that a generated map is symmetric, connected, and playable.
  let seed = map.seed

  for y in 0 ..< GridSide:
    for x in 0 ..< GridSide:
      let
        (mirrorX, mirrorY) = mirrorTile(x, y)
        index = tileIndex(x, y)
        mirrorIndex = tileIndex(mirrorX, mirrorY)
      doAssert map.passable[index] == map.passable[mirrorIndex],
        &"seed {seed}: walkability is asymmetric at ({x},{y})"
      doAssert map.kinds[index] == map.kinds[mirrorIndex],
        &"seed {seed}: tile kind is asymmetric at ({x},{y})"
      doAssert map.heights[index] == map.heights[mirrorIndex],
        &"seed {seed}: mean height is asymmetric at ({x},{y})"
      doAssert map.treeWood[index] == map.treeWood[mirrorIndex],
        &"seed {seed}: wood is asymmetric at ({x},{y})"
      ## A 180 degree rotation swaps corner 0 with 3 and 1 with 2.
      let
        tops = layers[0].tiles[index].tops
        mirrorTops = layers[0].tiles[mirrorIndex].tops
      for i in 0 .. 3:
        doAssert tops[i] == mirrorTops[3 - i],
          &"seed {seed}: terrain height is asymmetric at ({x},{y})"

  doAssert map.mines.len == PlayerCount * 3,
    &"seed {seed}: expected three mines per player"

  var seenIds: seq[int32]
  for mine in map.mines:
    doAssert mine.id.isMineId, &"seed {seed}: mine {mine.id} is out of range"
    doAssert mine.id notin seenIds, &"seed {seed}: duplicate mine {mine.id}"
    seenIds.add mine.id
    doAssert mine.gold > 0, &"seed {seed}: mine {mine.id} holds no gold"

  for player in 0 ..< PlayerCount:
    let
      hall = map.hallOrigin[player]
      spawnTiles = map.freeTilesAround(hall, HallFootprint, 2)
    doAssert spawnTiles >= MinimumSpawnTiles,
      &"seed {seed}: player {player} has only {spawnTiles} tiles to spawn " &
      &"peons around its hall"

  let
    lightStart = map.anyOpenNeighbour(map.hallOrigin[LightPlayer],
      HallFootprint)
    darkStart = map.anyOpenNeighbour(map.hallOrigin[DarkPlayer], HallFootprint)
  doAssert inGrid(lightStart) and inGrid(darkStart),
    &"seed {seed}: a town hall is completely walled in"

  let reached = map.floodFrom(lightStart)
  doAssert reached[tileIndex(darkStart)] == 1,
    &"seed {seed}: the two bases cannot reach each other"
  for mine in map.mines:
    let approach = map.anyOpenNeighbour(mine.origin, MineFootprint)
    doAssert inGrid(approach),
      &"seed {seed}: mine {mine.id} is completely walled in"
    doAssert reached[tileIndex(approach)] == 1,
      &"seed {seed}: mine {mine.id} is unreachable"

  for player in 0 ..< PlayerCount:
    var grove = 0
    let centre = map.hallOrigin[player]
    for y in 0 ..< GridSide:
      for x in 0 ..< GridSide:
        if map.treeWood[tileIndex(x, y)] > 0 and
            chebyshev(tile2(x, y), centre) <= GroveOuterRing + 4:
          inc grove
    doAssert grove >= MinimumGroveTiles,
      &"seed {seed}: player {player} has only {grove} nearby tree tiles"

  for index, (fordX, fordZ) in FordCorners:
    let width = map.fordWidth(fordX, fordZ)
    doAssert width >= MinimumFordWidth,
      &"seed {seed}: ford {index} at ({fordX},{fordZ}) closed up to {width}"
