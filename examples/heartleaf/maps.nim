## Heartleaf map generation.
##
## The village is generated entirely with integers from an explicit seed: a
## ring of nine houses around a central stone plaza, dirt roads from every
## door to the plaza and along the ring, three garden plots beside each
## house, and a forest closing in from every edge. A gentle meadow rolls
## under it all; the village interior is flattened so no doorstep sits on a
## cliff.
##
## This module writes the shared `pathing.layers` terrain model once at
## startup and then returns a `MapData` value. The simulation reads only the
## returned value, never the layers, so the renderer's decoration can never
## change how a game plays out.

import
  std/[heapqueue, strformat],
  polyworld/[hashes, noises, pathing, profiles, rngs],
  content

static:
  doAssert GridSide.int == GridTiles,
    "content and pathing disagree about the size of the map"

const
  MapCenter = GridSide div 2
  TerrainAmplitudeSteps = 6'i32
  VillageFlatRadius = 36'i32
    ## Inside this ring the meadow is pressed almost flat.
  VillageFadeRadius = 46'i32
    ## Between flat and fade the meadow rises back to full height.
  PlazaStoneRadius* = 8'i32
    ## The plaza is a disc of paving this many tiles across from the middle.
  RoadJoinMargin = 4'i32
  RoadSeparation = 2'i32
  ExistingRoadCost = 2'i32
  NewRoadCost = 6'i32
  ParallelRoadCost = 12'i32
  PlazaRoadRadius = 9'i32
    ## A one-tile road apron rings the paving.
  WellRadius* = 1'i32
    ## The well in the middle of the plaza blocks this far around the
    ## centre tile; nobody walks through it.
  HouseRingRadius = 26'i32
  HouseRingJitter = 6'i32
    ## Ring radius varies 26 .. 31 per house.
  HousePlaceJitter = 5'i32
    ## Centre offset varies -2 .. 2 per axis.
  HouseFootprint* = 5'i32
  HousePadRadius = 2'i32
    ## Corners this close to a house centre sit exactly on the pad.
  HousePadFade = 4'i32
  ForestEdgeRadius* = 44'i32
    ## Trees may appear outside this ring.
  ForestWallRadius* = 58'i32
    ## Beyond this the forest is a solid wall framing the map.
  GardenMinReach = 4'i32
  GardenMaxReach = 8'i32
  GardenAttempts = 400
  GenerationAttempts = 8
  GroundNoiseStream = 0xA0761D6478BD642F'u64
  GroundDetailStream = 0xE7037ED1A0B428DB'u64
  ForestNoiseStream = 0xD1B54A32D192ED03'u64
  CornerSide = GridSide + 1

  ## Unit circle at 40 degree steps, scaled by 1024. Integer by construction
  ## so house placement never touches a float.
  RingX: array[VillagerCount, int32] = [
    1024'i32, 784, 178, -512, -962, -962, -512, 178, 784]
  RingY: array[VillagerCount, int32] = [
    0'i32, 658, 1009, 887, 350, -350, -887, -1009, -658]

type
  House* = object
    center*: Tile2
      ## Middle tile of the HouseFootprint square.
    door*: Tile2
      ## The walkable doorstep tile just outside the five-tile footprint.
    facingX*, facingY*: int8
      ## Unit direction from the footprint toward the door.
    propKind*: uint8
      ## Which house model the renderer stands on the pad.

  MapData* = object
    seed*: int32
    passable*: seq[uint8]
      ## Walkability per tile: slope, houses, and forest included. Nothing
      ## changes walkability after generation.
    kinds*: seq[uint8]
      ## Tile kind per cell, for gardens, the minimap, and debugging.
    heights*: seq[int16]
      ## Mean packed terrain height per tile.
    houses*: array[VillagerCount, House]
    gardenTiles*: array[GardenCount, Tile2]
    hash*: uint64

const StepOffsets* = [
  (0'i32, -1'i32), (1'i32, -1'i32), (1'i32, 0'i32), (1'i32, 1'i32),
  (0'i32, 1'i32), (-1'i32, 1'i32), (-1'i32, 0'i32), (-1'i32, -1'i32)
]
  ## Neighbour scan order, clockwise from north. Fixed everywhere so that
  ## tie-breaking in pathing and flood fill is reproducible.

proc centerDistance(x, y: int32): int32 =
  ## King-move distance from the middle of the map.
  max(abs(x - MapCenter), abs(y - MapCenter))

proc centerDistanceSquared(x, y: int32): int32 =
  ## Squared straight-line distance from the middle of the map.
  (x - MapCenter) * (x - MapCenter) + (y - MapCenter) * (y - MapCenter)

## Generation

proc buildMap(seed: int32): MapData =
  ## Builds the terrain layers and village for one seed. May produce an
  ## unplayable layout on unlucky seeds; `generateMap` retries.
  var rng = initRng(seed)

  ## Houses first: their pads shape the heightfield.
  var houses: array[VillagerCount, House]
  for slot in 0 ..< VillagerCount:
    let
      radius = HouseRingRadius + rng.below(HouseRingJitter)
      jitterX = rng.below(HousePlaceJitter) - HousePlaceJitter div 2
      jitterY = rng.below(HousePlaceJitter) - HousePlaceJitter div 2
      centerX = MapCenter + RingX[slot] * radius div 1024 + jitterX
      centerY = MapCenter + RingY[slot] * radius div 1024 + jitterY
      towardX = MapCenter - centerX
      towardY = MapCenter - centerY
    var facingX, facingY = 0'i32
    if abs(towardX) >= abs(towardY):
      facingX = int32(cmp(towardX, 0'i32))
    else:
      facingY = int32(cmp(towardY, 0'i32))
    houses[slot] = House(
      center: tile2(centerX, centerY),
      door: tile2(
        centerX + facingX * (HouseFootprint div 2 + 1),
        centerY + facingY * (HouseFootprint div 2 + 1)),
      facingX: int8(facingX),
      facingY: int8(facingY),
      propKind: uint8(rng.below(7'i32))
    )

  ## Heights. Corner height is a pure function of the corner coordinate, so
  ## tiles that share a corner always agree and the surface grows no walls.
  proc ground(cx, cz: int): int32 =
    let value =
      valueNoise(seed, GroundNoiseStream, cx, cz, 24) * 3 +
      valueNoise(seed, GroundDetailStream, cx, cz, 9)
    int32(roundDivision(
      int64(value) * TerrainAmplitudeSteps,
      int64(MapBlendScale) * 4
    ))

  proc villageFlatten(cx, cz: int32): int32 =
    ## How strongly a corner is pressed toward the flat village floor.
    let ring = centerDistance(cx, cz)
    smoothstep(
      int32(VillageFadeRadius - ring) * MapBlendScale div
        (VillageFadeRadius - VillageFlatRadius)
    )

  proc meadowCorner(cx, cz: int32): int32 =
    ## Meadow height after the village press, before house pads.
    blendHeight(ground(int(cx), int(cz)), 0, villageFlatten(cx, cz))

  var padHeights: array[VillagerCount, int32]
  for slot in 0 ..< VillagerCount:
    padHeights[slot] = meadowCorner(
      int32(houses[slot].center.x), int32(houses[slot].center.y))

  proc makeCorner(cx, cz: int32): int32 =
    result = meadowCorner(cx, cz)
    for slot in 0 ..< VillagerCount:
      let reach = max(
        abs(cx - int32(houses[slot].center.x)),
        abs(cz - int32(houses[slot].center.y)))
      if reach <= HousePadFade:
        let amount = smoothstep(
          int32(HousePadFade - reach) * MapBlendScale div
            (HousePadFade - HousePadRadius)
        )
        result = blendHeight(result, padHeights[slot], amount)

  var cornerHeights = newSeq[int16](CornerSide * CornerSide)
  for cz in 0 .. GridSide.int:
    for cx in 0 .. GridSide.int:
      cornerHeights[cz * CornerSide + cx] =
        int16(makeCorner(int32(cx), int32(cz)))
  template corner(cx, cz: int32): int32 =
    int32(cornerHeights[int(cz) * CornerSide.int + int(cx)])

  var groundLayer = QuadLayer(
    originX: 0, originZ: 0,
    width: GridSide, depth: GridSide,
    slab: false,
    tiles: newSeq[Tile](GridCells)
  )
  template groundTile(x, y: int32): var Tile =
    groundLayer.tiles[int(y) * GridSide.int + int(x)]

  for y in 0'i32 ..< GridSide:
    for x in 0'i32 ..< GridSide:
      groundTile(x, y) = Tile(
        flags: TileExists or TileConnectedEast or TileConnectedSouth,
        kind: GrassTile,
        tops: packedHeights([
          corner(x, y), corner(x + 1, y),
          corner(x, y + 1), corner(x + 1, y + 1)])
      )

  ## Plaza: a round stone heart with a road apron.
  for y in MapCenter - PlazaRoadRadius .. MapCenter + PlazaRoadRadius:
    for x in MapCenter - PlazaRoadRadius .. MapCenter + PlazaRoadRadius:
      let distance = centerDistanceSquared(x, y)
      if distance <= PlazaStoneRadius * PlazaStoneRadius:
        groundTile(x, y).kind = StoneTile
      elif distance <= PlazaRoadRadius * PlazaRoadRadius:
        groundTile(x, y).kind = RoadTile
  ## The well stands on the centre and blocks its footprint.
  for y in MapCenter - WellRadius .. MapCenter + WellRadius:
    for x in MapCenter - WellRadius .. MapCenter + WellRadius:
      groundTile(x, y).impassable = true

  ## House footprints: impassable pads the houses stand on.
  for slot in 0 ..< VillagerCount:
    let
      center = houses[slot].center
      reach = HouseFootprint div 2
    for y in int32(center.y) - reach .. int32(center.y) + reach:
      for x in int32(center.x) - reach .. int32(center.x) + reach:
        groundTile(x, y).kind = HouseTileKind
        groundTile(x, y).impassable = true

  ## Roads. Wide plaza spokes and narrow neighborhood links that reuse
  ## nearby streets.
  proc stampRoad(x, y: int32) =
    if not inGrid(x, y):
      return
    if groundTile(x, y).impassable:
      return
    if groundTile(x, y).kind == StoneTile:
      return
    groundTile(x, y).kind = RoadTile

  proc carveLeg(fromX, fromY, toX, toY: int32, wide: bool) =
    ## One axis-aligned road segment. A wide leg stamps its neighbour on the
    ## crossing axis too.
    var
      x = fromX
      y = fromY
    let
      stepX = cmp(toX, fromX)
      stepY = cmp(toY, fromY)
    while true:
      stampRoad(x, y)
      if wide:
        if stepX != 0:
          stampRoad(x, y + 1)
        else:
          stampRoad(x + 1, y)
      if x == toX and y == toY:
        break
      x += int32(stepX)
      y += int32(stepY)

  proc carveDogleg(fromX, fromY, toX, toY: int32, wide, xFirst: bool) =
    if xFirst:
      carveLeg(fromX, fromY, toX, fromY, wide)
      carveLeg(toX, fromY, toX, toY, wide)
    else:
      carveLeg(fromX, fromY, fromX, toY, wide)
      carveLeg(fromX, toY, toX, toY, wide)

  for slot in 0 ..< VillagerCount:
    let door = houses[slot].door
    var xFirst = rng.below(2'i32) == 0
    # Doors near a plaza axis join its central street before the long leg.
    if abs(int32(door.x) - MapCenter) <= RoadJoinMargin:
      xFirst = true
    elif abs(int32(door.y) - MapCenter) <= RoadJoinMargin:
      xFirst = false
    carveDogleg(
      int32(door.x), int32(door.y), MapCenter, MapCenter,
      wide = true, xFirst = xFirst)
  proc connectNeighbors(start, goal: Tile2) =
    ## Keeps neighborhood links local while favoring existing streets over
    ## parallel strips of new paving.
    let
      minX = max(0'i32, min(int32(start.x), int32(goal.x)) - RoadJoinMargin)
      maxX = min(GridSide - 1, max(int32(start.x), int32(goal.x)) + RoadJoinMargin)
      minY = max(0'i32, min(int32(start.y), int32(goal.y)) - RoadJoinMargin)
      maxY = min(GridSide - 1, max(int32(start.y), int32(goal.y)) + RoadJoinMargin)
      startIndex = tileIndex(start)
      goalIndex = tileIndex(goal)
    var
      costs = newSeq[int32](GridCells)
      previous = newSeq[int32](GridCells)
      frontier = initHeapQueue[tuple[cost: int32, index: int32]]()
    for index in 0 ..< GridCells:
      costs[index] = int32.high
      previous[index] = -1
    costs[startIndex] = 0
    frontier.push((0'i32, startIndex))
    while frontier.len > 0:
      let current = frontier.pop()
      if current.cost != costs[current.index]:
        continue
      if current.index == goalIndex:
        break
      let
        x = int32(current.index mod GridSide)
        y = int32(current.index div GridSide)
      for (dx, dy) in [(0'i32, -1'i32), (1'i32, 0'i32),
          (0'i32, 1'i32), (-1'i32, 0'i32)]:
        let
          nx = x + dx
          ny = y + dy
        if nx < minX or nx > maxX or ny < minY or ny > maxY:
          continue
        if groundTile(nx, ny).impassable:
          continue
        let index = tileIndex(nx, ny)
        var stepCost = NewRoadCost
        if groundTile(nx, ny).kind in {RoadTile, StoneTile}:
          stepCost = ExistingRoadCost
        else:
          for oy in -RoadSeparation .. RoadSeparation:
            for ox in -RoadSeparation .. RoadSeparation:
              if inGrid(nx + ox, ny + oy) and
                  groundTile(nx + ox, ny + oy).kind == RoadTile:
                stepCost = ParallelRoadCost
        let cost = current.cost + stepCost
        if cost < costs[index]:
          costs[index] = cost
          previous[index] = current.index
          frontier.push((cost, index))
    if previous[goalIndex] < 0:
      raise newException(ValueError, &"seed {seed}: no neighborhood road route")
    var index = goalIndex
    while index != startIndex:
      stampRoad(int32(index mod GridSide), int32(index div GridSide))
      index = previous[index]

  for slot in 0 ..< VillagerCount:
    # Reserve the link's draw so garden randomness is independent of routing.
    discard rng.below(2'i32)
    connectNeighbors(houses[slot].door, houses[(slot + 1) mod VillagerCount].door)

  ## Forest. Purely noise-gated, thickening away from the village until it
  ## becomes the solid wall that frames the map. Roads keep a clear margin.
  proc nearRoad(x, y: int32): bool =
    for dy in -2'i32 .. 2'i32:
      for dx in -2'i32 .. 2'i32:
        let
          nx = x + dx
          ny = y + dy
        if not inGrid(nx, ny):
          continue
        if groundTile(nx, ny).kind == RoadTile or
            groundTile(nx, ny).kind == StoneTile:
          return true
    false

  for y in 0'i32 ..< GridSide:
    for x in 0'i32 ..< GridSide:
      let ring = centerDistance(x, y)
      if ring <= ForestEdgeRadius:
        continue
      if groundTile(x, y).kind != GrassTile:
        continue
      let
        forest = valueNoise(seed, ForestNoiseStream, int(x), int(y), 12)
        gate = MapBlendScale -
          (ring - ForestEdgeRadius) * MapBlendScale div
            (ForestWallRadius - ForestEdgeRadius)
      if forest > gate or ring >= ForestWallRadius:
        if nearRoad(x, y):
          continue
        groundTile(x, y).kind = TreeTile
        groundTile(x, y).impassable = true

  layers = @[groundLayer]
  computeWalkable()

  ## Derived grids.
  var map = MapData(
    seed: seed,
    passable: newSeq[uint8](GridCells),
    kinds: newSeq[uint8](GridCells),
    heights: newSeq[int16](GridCells),
    houses: houses
  )
  for y in 0'i32 ..< GridSide:
    for x in 0'i32 ..< GridSide:
      let index = tileIndex(x, y)
      map.passable[index] = uint8(isWalkable(0, int(x), int(y)))
      map.kinds[index] = uint8(groundLayer.tiles[index].kind)
      let tops = groundLayer.tiles[index].tops
      map.heights[index] = int16(
        (int32(tops[0]) + int32(tops[1]) +
          int32(tops[2]) + int32(tops[3])) div 4
      )

  ## Gardens: three tilled plots in the grass near each house. A plot must be
  ## walkable and keep a tile of spacing from its neighbours so gathering
  ## villagers do not stand in each other's beds.
  var placed = 0
  for slot in 0 ..< VillagerCount:
    let center = houses[slot].center
    var found = 0
    for attempt in 0 ..< GardenAttempts:
      if found >= GardensPerHouse:
        break
      let
        x = int32(center.x) +
          rng.below(GardenMaxReach * 2 + 1) - GardenMaxReach
        y = int32(center.y) +
          rng.below(GardenMaxReach * 2 + 1) - GardenMaxReach
        reach = max(abs(x - int32(center.x)), abs(y - int32(center.y)))
      if reach < GardenMinReach or reach > GardenMaxReach:
        continue
      if not inGrid(x, y):
        continue
      let index = tileIndex(x, y)
      if map.kinds[index] != uint8(GrassTile) or map.passable[index] == 0:
        continue
      var crowded = false
      for existing in 0 ..< placed:
        if chebyshev(map.gardenTiles[existing], tile2(x, y)) <= 1:
          crowded = true
          break
      if crowded:
        continue
      map.gardenTiles[placed] = tile2(x, y)
      map.kinds[index] = uint8(GardenTileKind)
      groundLayer.tiles[index].kind = GardenTileKind
      inc placed
      inc found

  ## Fingerprint. Covers the packed terrain, walkability, and every village
  ## placement, so a generator change is caught at replay load rather than
  ## as a mysterious divergence later.
  var hash = HashySeed
  hash.addHashy(seed)
  hash.addHashy(layers.len)
  for layerIndex, layer in layers:
    for index, tile in layer.tiles:
      hash.addHashy(uint32(tile.flags))
      hash.addHashy(uint32(tile.kind))
      for value in tile.tops:
        hash.addHashy(value)
      hash.addHashy(layerWalkable[layerIndex][index])
  for index in 0 ..< GridCells:
    hash.addHashy(map.passable[index])
    hash.addHashy(map.kinds[index])
    hash.addHashy(map.heights[index])
  for house in map.houses:
    hash.addHashy(house.center.x)
    hash.addHashy(house.center.y)
    hash.addHashy(house.door.x)
    hash.addHashy(house.door.y)
    hash.addHashy(house.facingX)
    hash.addHashy(house.facingY)
    hash.addHashy(house.propKind)
  hash.addHashy(placed)
  for garden in map.gardenTiles:
    hash.addHashy(garden.x)
    hash.addHashy(garden.y)
  map.hash = uint64(hash)
  map

## Checks
##
## Every one names the seed, so a bad seed is instantly reproducible.

proc floodFrom(map: MapData, start: Tile2): seq[uint8] =
  ## Eight-neighbour integer flood fill over passable tiles.
  result = newSeq[uint8](GridCells)
  if not inGrid(start) or map.passable[tileIndex(start)] == 0:
    return
  var frontier = @[start]
  result[tileIndex(start)] = 1
  while frontier.len > 0:
    let tile = frontier.pop()
    for (dx, dy) in StepOffsets:
      let
        nextX = int32(tile.x) + dx
        nextY = int32(tile.y) + dy
      if not inGrid(nextX, nextY):
        continue
      let index = tileIndex(nextX, nextY)
      if map.passable[index] == 0 or result[index] == 1:
        continue
      result[index] = 1
      frontier.add tile2(nextX, nextY)

const PlazaStart = tile2(MapCenter + WellRadius + 1, MapCenter)
  ## Where connectivity checks begin: the plaza paving just east of the
  ## well, since the well itself is blocked.

proc mapPlayable(map: MapData): bool =
  ## Quietly checks connectivity, for the retry loop.
  let reached = map.floodFrom(PlazaStart)
  for house in map.houses:
    if not inGrid(house.door) or reached[tileIndex(house.door)] == 0:
      return false
  for garden in map.gardenTiles:
    if not inGrid(garden) or reached[tileIndex(garden)] == 0:
      return false
    if map.kinds[tileIndex(garden)] != uint8(GardenTileKind):
      return false
  true

proc generateMap*(seed: int32): MapData {.measure.} =
  ## Builds the village for one seed, retrying deterministically on layouts
  ## the flood fill rejects. Writes the shared `pathing.layers` and
  ## refreshes walkability once per attempt.
  for attempt in 0 ..< GenerationAttempts:
    result = buildMap(seed + int32(attempt) * 7919)
    if result.mapPlayable():
      return
  raise newException(ValueError,
    &"seed {seed}: no playable village in {GenerationAttempts} attempts")

proc validateMap*(map: MapData) =
  ## Asserts that a generated map is connected and playable.
  let seed = map.seed
  let reached = map.floodFrom(PlazaStart)
  doAssert reached[tileIndex(PlazaStart)] == 1,
    &"seed {seed}: the plaza itself is blocked"
  for slot, house in map.houses:
    doAssert inGrid(house.door),
      &"seed {seed}: house {slot} has an off-map door"
    doAssert map.passable[tileIndex(house.door)] == 1,
      &"seed {seed}: house {slot} has a blocked door"
    doAssert reached[tileIndex(house.door)] == 1,
      &"seed {seed}: house {slot} is unreachable from the plaza"
    doAssert house.facingX == 0 or house.facingY == 0,
      &"seed {seed}: house {slot} faces diagonally"
    for y in int32(house.center.y) - 1 .. int32(house.center.y) + 1:
      for x in int32(house.center.x) - 1 .. int32(house.center.x) + 1:
        doAssert map.passable[tileIndex(x, y)] == 0,
          &"seed {seed}: house {slot} footprint is walkable at ({x},{y})"
  for index, garden in map.gardenTiles:
    doAssert inGrid(garden),
      &"seed {seed}: garden {index} is off the map"
    doAssert map.kinds[tileIndex(garden)] == uint8(GardenTileKind),
      &"seed {seed}: garden {index} lost its plot"
    doAssert map.passable[tileIndex(garden)] == 1,
      &"seed {seed}: garden {index} is not walkable"
    doAssert reached[tileIndex(garden)] == 1,
      &"seed {seed}: garden {index} is unreachable from the plaza"
    for other in 0 ..< index:
      doAssert chebyshev(map.gardenTiles[other], garden) > 1,
        &"seed {seed}: gardens {other} and {index} touch"
