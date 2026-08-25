## Covers the two tile-oriented additions to pathing: `findTilePath`, which a
## tile-stepping simulation follows one step at a time, and `tileTop`, which
## prices a ramp step without leaving integers.
##
## The case that matters most is a ramp: `edgeLink` joins two layers only when
## their shared corner heights match exactly, so a path that climbs from one
## layer to another is the real test of both the search and the recipe for
## authoring ramps.

import polyworld/pathing

proc flatTile(height: int16): Tile =
  ## One flat tile at a packed height, connected east and south.
  Tile(
    tops: [height, height, height, height],
    flags: TileExists or TileConnectedEast or TileConnectedSouth
  )

proc flatLayer(originX, originZ, width, depth: int, height: int16): QuadLayer =
  result = QuadLayer(
    originX: originX,
    originZ: originZ,
    width: width,
    depth: depth,
    tiles: newSeq[Tile](width * depth)
  )
  for tile in result.tiles.mitems:
    tile = flatTile(height)

proc blockedColumn(layer, x, z: int): bool {.nimcall.} =
  isWalkable(layer, x, z) and x != 2

proc taxCentre(layer, x, z: int): int32 {.nimcall.} =
  if x == 2 and z == 1: 10_000'i32 else: 0'i32

echo "Testing findTilePath walks adjacent tiles from start to finish"
block:
  layers = @[flatLayer(0, 0, 5, 5, 0)]
  computeWalkable()

  let path = findTilePath(0, 0, 0, 0, 4, 4)
  doAssert path.len > 0, "a flat open grid must be traversable"
  doAssert path[0] == PathTile(layer: 0, x: 0, z: 0),
    "a path starts on the tile you are already standing on"
  doAssert path[^1] == PathTile(layer: 0, x: 4, z: 4)
  doAssert path.len == 9, "Manhattan distance on a flat grid is 8 steps"

  for i in 1 ..< path.len:
    let
      previous = path[i - 1]
      step = path[i]
      dx = abs(step.x - previous.x)
      dz = abs(step.z - previous.z)
    doAssert dx + dz == 1,
      "consecutive path tiles must be edge neighbors, got " &
      $previous & " -> " & $step

echo "Testing findTilePath agrees with findPathPoints"
block:
  layers = @[flatLayer(0, 0, 5, 5, 0)]
  computeWalkable()
  let
    tiles = findTilePath(0, 0, 0, 0, 4, 3)
    points = findPathPoints(0, 0, 0, 0, 4, 3)
  doAssert tiles.len == points.len,
    "both projections must come from the same search"
  for i in 0 ..< tiles.len:
    doAssert points[i] ==
      pathPoint(tiles[i].layer.int, tiles[i].x.int, tiles[i].z.int),
      "tile path and point path disagree at step " & $i

echo "Testing findTilePath is empty when no route exists"
block:
  layers = @[flatLayer(0, 0, 5, 5, 0)]
  # Wall off the far column by breaking every edge into it.
  for z in 0 ..< 5:
    layers[0].tiles[z * 5 + 3].connectedEast = false
  computeWalkable()
  doAssert findTilePath(0, 0, 0, 0, 4, 0).len == 0,
    "a severed column must be unreachable"

echo "Testing findTilePath crosses layers up a ramp"
block:
  # Lower floor at 0, upper floor at 64 steps (8 tiles), joined by a ramp
  # that rises 8 steps per tile. Corner heights are written directly as
  # int16 so the ramp mouth matches its landing pad exactly; interpolating
  # in float and rounding is what silently breaks these links.
  const
    Low = 0'i16
    High = 64'i16
    Rise = 8'i16
    RampTiles = int(High - Low) div int(Rise)   # 8

  let lower = flatLayer(0, 0, 4, 3, Low)
  # The ramp occupies its own strip of the lower layer, x = 4 .. 11 at z = 1.
  let ramp = QuadLayer(
    originX: 4, originZ: 1, width: RampTiles, depth: 1,
    tiles: newSeq[Tile](RampTiles)
  )
  for i in 0 ..< RampTiles:
    let
      near = Low + Rise * int16(i)          # west corners
      far = Low + Rise * int16(i + 1)       # east corners
    ramp.tiles[i] = Tile(
      tops: [near, far, near, far],
      flags: TileExists or TileConnectedEast or TileConnectedSouth
    )
  let upper = flatLayer(12, 0, 4, 3, High)

  layers = @[lower, ramp, upper]
  computeWalkable()

  doAssert isWalkable(1, 0, 0), "a 45 degree ramp must stay walkable"

  # The mouths link because the shared corners are bit-identical.
  let intoRamp = edgeLink(0, 3, 1, 0)
  doAssert intoRamp.open and intoRamp.layer == 1,
    "the lower floor must link into the ramp, got " & $intoRamp
  let ontoUpper = edgeLink(1, RampTiles - 1, 0, 0)
  doAssert ontoUpper.open and ontoUpper.layer == 2,
    "the ramp must link onto the upper floor, got " & $ontoUpper

  let path = findTilePath(0, 0, 1, 2, 3, 1)
  doAssert path.len > 0, "the upper floor must be reachable up the ramp"
  doAssert path[0].layer == 0 and path[^1].layer == 2
  var layersSeen: set[uint8]
  for step in path:
    layersSeen.incl uint8(step.layer)
  doAssert layersSeen == {0'u8, 1, 2},
    "the route must pass through all three layers"

  let back = findTilePath(2, 3, 1, 0, 0, 1)
  doAssert back.len == path.len, "ramps must be walkable in both directions"

echo "Testing a ramp one step off does not link"
block:
  # The same geometry with the top of the ramp one height step short. This is
  # exactly the failure that float interpolation plus rounding produces, and
  # it is silent: the tile is still walkable, it just never connects.
  const
    Low = 0'i16
    High = 64'i16
    Rise = 8'i16
    RampTiles = 8

  let lower = flatLayer(0, 0, 4, 3, Low)
  let ramp = QuadLayer(
    originX: 4, originZ: 1, width: RampTiles, depth: 1,
    tiles: newSeq[Tile](RampTiles)
  )
  for i in 0 ..< RampTiles:
    var
      near = Low + Rise * int16(i)
      far = Low + Rise * int16(i + 1)
    if i == RampTiles - 1:
      far = far - 1                          # one eighth of a tile short
    ramp.tiles[i] = Tile(
      tops: [near, far, near, far],
      flags: TileExists or TileConnectedEast or TileConnectedSouth
    )
  let upper = flatLayer(12, 0, 4, 3, High)

  layers = @[lower, ramp, upper]
  computeWalkable()

  doAssert isWalkable(1, RampTiles - 1, 0),
    "the mistake leaves the tile walkable, which is why it is easy to miss"
  doAssert not edgeLink(1, RampTiles - 1, 0, 0).open,
    "a mouth one step off must not link"
  doAssert findTilePath(0, 0, 1, 2, 3, 1).len == 0,
    "the upper floor must be unreachable when the ramp mouth is off by one"

echo "Testing tileTop reads packed corner heights"
block:
  layers = @[flatLayer(0, 0, 3, 3, 0)]
  computeWalkable()
  doAssert tileTop(0, 1, 1) == 0

  layers[0].tiles[4].tops = [8'i16, 8'i16, 8'i16, 8'i16]
  doAssert tileTop(0, 1, 1) == 8, "a flat tile reports its own height"

  layers[0].tiles[4].tops = [0'i16, 8'i16, 0'i16, 8'i16]
  doAssert tileTop(0, 1, 1) == 4, "a slope reports its mean"

echo "Testing tileTop floors toward negative infinity"
block:
  # Dungeon levels sit far below zero, so a division that truncates toward
  # zero would make step costs asymmetric above and below the surface.
  layers = @[flatLayer(0, 0, 3, 3, 0)]
  layers[0].tiles[4].tops = [-1'i16, -1'i16, -1'i16, 0'i16]
  doAssert tileTop(0, 1, 1) == -1, "mean of -3/4 must floor to -1, not 0"
  layers[0].tiles[4].tops = [-8'i16, -8'i16, -8'i16, -8'i16]
  doAssert tileTop(0, 1, 1) == -8
  layers[0].tiles[4].tops = [1'i16, 1'i16, 1'i16, 0'i16]
  doAssert tileTop(0, 1, 1) == 0, "mean of 3/4 truncates to 0"

echo "Testing tileTop matches a ramp's rise per tile"
block:
  const Rise = 8'i16
  let ramp = QuadLayer(
    originX: 0, originZ: 0, width: 4, depth: 1, tiles: newSeq[Tile](4))
  for i in 0 ..< 4:
    let
      near = Rise * int16(i)
      far = Rise * int16(i + 1)
    ramp.tiles[i] = Tile(
      tops: [near, far, near, far],
      flags: TileExists or TileConnectedEast or TileConnectedSouth)
  layers = @[ramp]
  computeWalkable()
  for i in 1 ..< 4:
    doAssert tileTop(0, i, 0) - tileTop(0, i - 1, 0) == int32(Rise),
      "each ramp tile must climb exactly one rise"

echo "Testing eight-neighbour paths take diagonals"
block:
  layers = @[flatLayer(0, 0, 5, 5, 0)]
  computeWalkable()
  let found = findTilePath(PathQuery(
    startLayer: 0, startX: 0, startZ: 0,
    finishLayer: 0, finishX: 4, finishZ: 4,
    neighbors: EightNeighbors
  ))
  doAssert found.complete
  doAssert found.tiles.len == 5,
    "a diagonal across a 5x5 grid is 4 steps, got " & $found.tiles.len
  doAssert found.tiles[0] == PathTile(layer: 0, x: 0, z: 0)
  doAssert found.tiles[^1] == PathTile(layer: 0, x: 4, z: 4)
  for i in 1 ..< found.tiles.len:
    let
      dx = abs(found.tiles[i].x - found.tiles[i - 1].x)
      dz = abs(found.tiles[i].z - found.tiles[i - 1].z)
    doAssert dx <= 1 and dz <= 1 and dx + dz > 0,
      "eight-neighbour steps must be king-moves"

echo "Testing eight-neighbour paths refuse a diagonal squeeze"
block:
  layers = @[flatLayer(0, 0, 2, 2, 0)]
  layers[0].tiles[1].impassable = true
  layers[0].tiles[2].impassable = true
  computeWalkable()
  let found = findTilePath(PathQuery(
    startLayer: 0, startX: 0, startZ: 0,
    finishLayer: 0, finishX: 1, finishZ: 1,
    neighbors: EightNeighbors
  ))
  doAssert not found.complete
  doAssert found.tiles.len == 0,
    "a corner between two blocked tiles must not be a path"

echo "Testing a walkable callback sees blockers the terrain cache cannot"
block:
  layers = @[flatLayer(0, 0, 5, 1, 0)]
  computeWalkable()
  let found = findTilePath(PathQuery(
    startLayer: 0, startX: 0, startZ: 0,
    finishLayer: 0, finishX: 4, finishZ: 0,
    neighbors: EdgeNeighbors,
    walkable: blockedColumn
  ))
  doAssert not found.complete
  doAssert found.tiles.len == 0,
    "a callback-blocked column must cut the default edge path"

echo "Testing a budgeted search returns a partial path"
block:
  layers = @[flatLayer(0, 0, 5, 5, 0)]
  computeWalkable()
  let found = findTilePath(PathQuery(
    startLayer: 0, startX: 0, startZ: 0,
    finishLayer: 0, finishX: 4, finishZ: 4,
    neighbors: EightNeighbors,
    maxExpansions: 1,
    partial: true
  ))
  doAssert not found.complete
  doAssert found.tiles.len >= 1, "partial paths still include the start"
  doAssert found.tiles[0] == PathTile(layer: 0, x: 0, z: 0)
  doAssert found.tiles[^1] != PathTile(layer: 0, x: 4, z: 4),
    "one expansion cannot reach the far corner"
  let empty = findTilePath(PathQuery(
    startLayer: 0, startX: 0, startZ: 0,
    finishLayer: 0, finishX: 4, finishZ: 4,
    neighbors: EightNeighbors,
    maxExpansions: 1
  ))
  doAssert not empty.complete
  doAssert empty.tiles.len == 0,
    "without partial, a budget miss must be empty"

echo "Testing enterCost steers a search around a taxed tile"
block:
  layers = @[flatLayer(0, 0, 5, 3, 0)]
  computeWalkable()
  let found = findTilePath(PathQuery(
    startLayer: 0, startX: 0, startZ: 1,
    finishLayer: 0, finishX: 4, finishZ: 1,
    neighbors: EightNeighbors,
    enterCost: taxCentre
  ))
  doAssert found.complete
  for tile in found.tiles:
    doAssert not (tile.x == 2 and tile.z == 1),
      "a cheap detour must beat a taxed centre tile"

echo "Tile path tests passed"
