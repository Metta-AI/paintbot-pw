import polyworld/pathing

proc openTile(): Tile =
  ## Returns one flat tile with all cardinal edges connected.
  Tile(
    tops: [0'i16, 0'i16, 0'i16, 0'i16],
    flags: TileExists or TileConnectedEast or TileConnectedSouth
  )

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

echo "Pathing tests passed"
