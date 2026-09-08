import
  vmath,
  polyworld/pathing

proc openTile(): Tile =
  ## Returns one flat tile with all cardinal edges connected.
  Tile(
    tops: [0'i16, 0'i16, 0'i16, 0'i16],
    flags: TileExists or TileConnectedEast or TileConnectedSouth
  )

echo "Testing immutable layer context reuse"
block:
  proc flatLayer(width: int; height: int16): QuadLayer =
    result = QuadLayer(
      originX: 0,
      originZ: 0,
      width: width,
      depth: 1,
      tiles: newSeq[Tile](width)
    )
    for tile in result.tiles.mitems:
      tile = openTile()
      tile.tops = [height, height, height, height]

  let
    first = flatLayer(1, 0)
    second = flatLayer(2, 8)
  installImmutableLayers(@[first])
  let firstWalkable = cast[pointer](unsafeAddr layerWalkable[0][0])
  installImmutableLayers(@[second])
  let secondWalkable = cast[pointer](unsafeAddr layerWalkable[0][0])
  doAssert firstWalkable != secondWalkable
  installImmutableLayers(@[first])
  doAssert cast[pointer](unsafeAddr layerWalkable[0][0]) == firstWalkable
  installImmutableLayers(@[second])
  doAssert cast[pointer](unsafeAddr layerWalkable[0][0]) == secondWalkable
  doAssert findPathPoints(0, 0, 0, 0, 1, 0).len == 2

echo "Testing deterministic integer A* tie breaking"
let layer = QuadLayer(
  originX: 0,
  originZ: 0,
  width: 3,
  depth: 3,
  tiles: newSeq[Tile](9)
)
for tile in layer.tiles.mitems:
  tile = openTile()
layers = @[layer]
computeWalkable()

let expected = @[
  PathPoint(x: -2032, y: 0, z: -2032),
  PathPoint(x: -2000, y: 0, z: -2032),
  PathPoint(x: -1968, y: 0, z: -2032),
  PathPoint(x: -1968, y: 0, z: -2000),
  PathPoint(x: -1968, y: 0, z: -1968)
]
for i in 0 ..< 100:
  let path = findPathPoints(0, 0, 0, 0, 2, 2)
  doAssert path == expected, "equal-cost path changed on run " & $i

echo "Testing exact packed path height"
layer.tiles[4].tops = [8'i16, 8'i16, 8'i16, 8'i16]
computeWalkable()
doAssert pathPoint(0, 1, 1).y == 32

echo "Testing integer slope walkability"
layer.tiles[0].tops = [0'i16, 0'i16, 0'i16, 64'i16]
computeWalkable()
doAssert not isWalkable(0, 0, 0)

echo "Testing string-pull drops open diagonals and keeps blocked kinks"
block:
  let open = QuadLayer(
    originX: 0,
    originZ: 0,
    width: 5,
    depth: 5,
    tiles: newSeq[Tile](25)
  )
  for tile in open.tiles.mitems:
    tile = openTile()
  layers = @[open]
  computeWalkable()
  let raw = findTilePath(0, 0, 0, 0, 4, 4)
  doAssert raw.len > 2
  let pulled = smoothPathTiles(raw)
  doAssert pulled.len == 2, "an open field should pull to start and finish"
  doAssert pulled[0] == raw[0]
  doAssert pulled[^1] == raw[^1]
  # Block the diagonal so the straight line from start to finish is closed.
  open.tiles[1 * 5 + 1].flags = TileExists
  computeWalkable()
  let bent = smoothPathTiles(findTilePath(0, 0, 0, 0, 4, 4))
  doAssert bent.len > 2, "a blocked corner must keep a kink"

echo "Testing string-pull does not skip a layer change"
block:
  proc flatTile(height: int16): Tile =
    ## One flat connected tile at a packed height.
    Tile(
      tops: [height, height, height, height],
      flags: TileExists or TileConnectedEast or TileConnectedSouth
    )
  proc makeLayer(
      originX, originZ, width, depth: int,
      height: int16
  ): QuadLayer =
    result = QuadLayer(
      originX: originX,
      originZ: originZ,
      width: width,
      depth: depth,
      tiles: newSeq[Tile](width * depth)
    )
    for tile in result.tiles.mitems:
      tile = flatTile(height)
  var ground = makeLayer(0, 0, 12, 1, 0)
  for x in 4 .. 7:
    ground.tiles[x].flags = 0
  var deck = makeLayer(0, 0, 12, 1, 0)
  for x in 0 .. 11:
    if x < 4 or x > 7:
      deck.tiles[x].flags = 0
  layers = @[ground, deck]
  computeWalkable()
  let pulled = smoothPathTiles(findTilePath(0, 0, 0, 0, 11, 0))
  var layersSeen: set[uint8]
  for tile in pulled:
    layersSeen.incl uint8(tile.layer)
  doAssert 1'u8 in layersSeen,
    "a river crossing must keep at least one deck tile"

echo "Testing ray-triangle hits"
block:
  doAssert rayTriangle(
    vec3(0, 0, -1),
    vec3(0, 0, 1),
    vec3(-1, -1, 0),
    vec3(1, -1, 0),
    vec3(0, 1, 0)
  ) > 0
  doAssert rayTriangle(
    vec3(0, 0, -1),
    vec3(0, 0, 1),
    vec3(2, 2, 0),
    vec3(3, 2, 0),
    vec3(2, 3, 0)
  ) < 0

echo "Testing walk pick hits ramps and skips holes"
block:
  proc flatTile(height: int16, flags = TileExists or
      TileConnectedEast or TileConnectedSouth): Tile =
    ## One flat tile at a packed height.
    Tile(
      tops: [height, height, height, height],
      flags: flags
    )
  proc makeLayer(height: int16): QuadLayer =
    result = QuadLayer(
      originX: 0,
      originZ: 0,
      width: 3,
      depth: 3,
      tiles: newSeq[Tile](9)
    )
    for tile in result.tiles.mitems:
      tile = flatTile(height)
  let
    upper = makeLayer(8)
    lower = makeLayer(0)
  # Shaft hole on the upper floor; the slope lives on the floor below.
  upper.tiles[1 * 3 + 1] = Tile()
  lower.tiles[1 * 3 + 1] = Tile(
    tops: [0'i16, 8'i16, 0'i16, 8'i16],
    flags: TileExists or TileConnectedEast or TileConnectedSouth
  )
  # A wall blocks the ray; the floor under it must not be picked.
  upper.tiles[2 * 3 + 2] = flatTile(8, TileExists or TileImpassable)
  layers = @[upper, lower]
  computeWalkable()
  proc tileRay(x, z: int, height: float32): (Vec3, Vec3) =
    ## A downward ray through the centre of one world tile.
    let
      x0 = x.float32 - HalfGrid + 0.5
      z0 = z.float32 - HalfGrid + 0.5
    (vec3(x0, height, z0), vec3(0, -1, 0))
  block:
    let (origin, dir) = tileRay(1, 1, 4)
    let hit = pickWalkableTile(origin, dir)
    doAssert hit.hit, "a shaft hole must pick the ramp below"
    doAssert hit.layer == 1 and hit.x == 1 and hit.z == 1
  block:
    let (origin, dir) = tileRay(0, 0, 4)
    let hit = pickWalkableTile(origin, dir)
    doAssert hit.hit and hit.layer == 0 and hit.x == 0 and hit.z == 0
  block:
    let (origin, dir) = tileRay(2, 2, 4)
    let hit = pickWalkableTile(origin, dir)
    doAssert not hit.hit, "an impassable tile must not be a walk target"

echo "Testing tile borders include changing tree and building blockers"
block:
  let ground = QuadLayer(width: 5, depth: 5, tiles: newSeq[Tile](25))
  for tile in ground.tiles.mitems:
    tile = openTile()
  ground.tiles[0].impassable = true
  layers = @[ground]
  computeWalkable()
  var blockers = @[newSeq[int32](25)]
  doAssert edgeMask(0, 2, 2, blockers) == 15
  blockers[0][12] = -1
  doAssert edgeMask(0, 2, 2, blockers) == 0,
    "a tree tile must have four red borders"
  for (x, z, direction) in [(1, 2, 0), (2, 1, 1), (3, 2, 2), (2, 3, 3)]:
    doAssert (edgeMask(0, x, z, blockers) and uint8(1 shl direction)) == 0,
      "an open tile must show a red edge facing the tree"
  doAssert isWalkable(0, 2, 2)
  doAssert edgeLink(0, 1, 2, 0).open,
    "the overlay must not change cached terrain connections"
  blockers[0][12] = 0
  doAssert edgeMask(0, 2, 2, blockers) == 15,
    "felling a tree must reopen the displayed edges"
  for z in 1 .. 2:
    for x in 1 .. 2:
      blockers[0][z * 5 + x] = 1000
      doAssert edgeMask(0, x, z, blockers) == 0,
        "every tile of a building footprint must be red"
  doAssert edgeMask(0, 0, 0, blockers) == 0,
    "terrain blocks must remain red"
  for blocker in blockers[0].mitems:
    blocker = 0
  doAssert edgeMask(0, 2, 2, blockers) == 15,
    "removing a building must reopen the displayed edges"

echo "Testing tile borders include blockers across layer connections"
block:
  let
    first = QuadLayer(width: 1, depth: 1, tiles: @[openTile()])
    second = QuadLayer(originX: 1, width: 1, depth: 1, tiles: @[openTile()])
  layers = @[first, second]
  computeWalkable()
  var blockers = @[@[0'i32], @[-1'i32]]
  doAssert edgeMask(0, 0, 0) == 1
  doAssert edgeMask(0, 0, 0, blockers) == 0
  blockers[1][0] = 0
  doAssert edgeMask(0, 0, 0, blockers) == 1
  doAssert edgeMask(1, 0, 0, blockers) == 4

echo "Pathing tests passed"
