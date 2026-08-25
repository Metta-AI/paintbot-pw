## Body motion across quad-terrain layers.
##
## Uses only `bodies` and `pathing`: a planar body steers toward tile
## centres, and `preferLayer` decides when a ramp or bridge may change
## floors. Overlapping geometry on some other layer is not a hole.

import
  polyworld/[bodies, fixed, pathing]

const
  BodySpeed = 0.2'fx
  TurnRate = FixedPi
  Arrive = 0.35'fx

var
  walkLayer: int
  walkDest: int

proc openTile(height: int16): Tile =
  ## One flat tile at a packed height, connected east and south.
  Tile(
    tops: [height, height, height, height],
    flags: TileExists or TileConnectedEast or TileConnectedSouth
  )

proc flatLayer(
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
    tile = openTile(height)

proc walkable(pos: FixedVec2): bool {.nimcall.} =
  ## Current layer, plus dest while a route is crossing.
  let (x, z) = cell(pos)
  layersOpen(walkLayer, walkDest, int(x), int(z))

proc center(tile: PathTile): FixedVec2 =
  ## Tile-space centre of one path cell.
  fixedVec2(fixed(tile.x) + 0.5'fx, fixed(tile.z) + 0.5'fx)

proc walkTiles(body: var Body, tiles: seq[PathTile], startLayer: int) =
  ## Steers one body along a pulled tile path, updating its layer.
  walkLayer = startLayer
  var index = 0
  var guard = 0
  while index < tiles.len:
    inc guard
    doAssert guard < 4_000, "a body stalled on a layered path"
    let dest = tiles[index]
    walkDest = int(dest.layer)
    let offset = center(dest) - body.pos
    if length(offset) <= Arrive:
      walkLayer = preferLayer(
        walkLayer, walkDest, int(dest.x), int(dest.z)
      )
      inc index
      continue
    steer(body, offset, BodySpeed, TurnRate, walkable)
    let (x, z) = cell(body.pos)
    walkLayer = preferLayer(walkLayer, walkDest, int(x), int(z))

proc installRamp() =
  ## Lower floor, 45 degree ramp, upper floor. Same recipe as the tile path
  ## tests so the edge links are bit-identical.
  const
    Low = 0'i16
    High = 64'i16
    Rise = 8'i16
    RampTiles = int(High - Low) div int(Rise)
  let lower = flatLayer(0, 0, 4, 3, Low)
  var ramp = QuadLayer(
    originX: 4,
    originZ: 1,
    width: RampTiles,
    depth: 1,
    tiles: newSeq[Tile](RampTiles)
  )
  for i in 0 ..< RampTiles:
    let
      near = Low + Rise * int16(i)
      far = Low + Rise * int16(i + 1)
    ramp.tiles[i] = Tile(
      tops: [near, far, near, far],
      flags: TileExists or TileConnectedEast or TileConnectedSouth
    )
  let upper = flatLayer(12, 0, 4, 3, High)
  layers = @[lower, ramp, upper]
  computeWalkable()

echo "Testing preferLayer stays on a deck over ground"
block:
  let ground = flatLayer(0, 0, 12, 1, 0)
  var deck = flatLayer(0, 0, 12, 1, 32)
  for x in 0 .. 11:
    if x < 4 or x > 7:
      deck.tiles[x].flags = 0
  layers = @[ground, deck]
  computeWalkable()
  doAssert isWalkable(0, 5, 0) and isWalkable(1, 5, 0),
    "the two layers must overlap in xz"
  doAssert preferLayer(1, 0, 5, 0) == 1,
    "a body on the deck must not fall through to the ground"
  doAssert preferLayer(0, 0, 5, 0) == 0,
    "a body already on the ground stays on the ground"
  doAssert layersOpen(1, 0, 5, 0)
  doAssert not layersOpen(1, 1, 2, 0),
    "the deck must not walk onto a bank tile that is only on the ground"

echo "Testing a body climbs a ramp without leaving walkable tiles"
block:
  installRamp()
  let tiles = findTilePath(0, 0, 1, 2, 3, 1)
  doAssert tiles.len > 0
  var body = Body(
    pos: center(tiles[0]),
    facing: FixedZero,
    radius: 0.22'fx
  )
  walkTiles(body, tiles, 0)
  let (x, z) = cell(body.pos)
  doAssert walkLayer == 2, "the climb must finish on the upper floor"
  doAssert isWalkable(walkLayer, int(x), int(z)),
    "the body must stand on a real upper tile, not inside a wall"
  doAssert x == 3 and z == 1

echo "Testing a body descends a ramp without falling into a wall"
block:
  installRamp()
  let tiles = findTilePath(2, 3, 1, 0, 0, 1)
  doAssert tiles.len > 0
  var body = Body(
    pos: center(tiles[0]),
    facing: FixedPi,
    radius: 0.22'fx
  )
  walkTiles(body, tiles, 2)
  let (x, z) = cell(body.pos)
  doAssert walkLayer == 0, "the descent must finish on the lower floor"
  doAssert isWalkable(walkLayer, int(x), int(z)),
    "the body must not finish inside a wall"
  doAssert x == 0 and z == 1
  for tile in tiles:
    doAssert layersOpen(int(tile.layer), int(tile.layer), int(tile.x), int(tile.z))

echo "Testing a body walks a deck without dropping to the riverbed"
block:
  var ground = flatLayer(0, 0, 12, 1, 0)
  for x in 4 .. 7:
    ground.tiles[x].flags = 0
  var deck = flatLayer(0, 0, 12, 1, 0)
  for x in 0 .. 11:
    if x < 4 or x > 7:
      deck.tiles[x].flags = 0
  layers = @[ground, deck]
  computeWalkable()
  doAssert not isWalkable(0, 5, 0), "the riverbed under the deck is closed"
  doAssert isWalkable(1, 5, 0)
  doAssert preferLayer(1, 0, 5, 0) == 1
  var body = Body(
    pos: fixedVec2(4.5'fx, 0.5'fx),
    facing: FixedZero,
    radius: 0.22'fx
  )
  walkLayer = 1
  walkDest = 1
  for _ in 0 ..< 40:
    steer(
      body,
      fixedVec2(7.5'fx, 0.5'fx) - body.pos,
      BodySpeed,
      TurnRate,
      walkable
    )
    let (x, z) = cell(body.pos)
    walkLayer = preferLayer(walkLayer, walkDest, int(x), int(z))
    doAssert walkLayer == 1, "walking the deck must not change layer"
    doAssert isWalkable(1, int(x), int(z)),
      "the body left the deck"
  doAssert cell(body.pos).x >= 6

echo "Testing string-pull keeps the deck over a river gap"
block:
  var ground = flatLayer(0, 0, 12, 1, 0)
  for x in 4 .. 7:
    ground.tiles[x].flags = 0
  var deck = flatLayer(0, 0, 12, 1, 0)
  for x in 0 .. 11:
    if x < 4 or x > 7:
      deck.tiles[x].flags = 0
  layers = @[ground, deck]
  computeWalkable()
  let
    raw = findTilePath(0, 0, 0, 0, 11, 0)
    pulled = smoothPathTiles(raw)
  var layersSeen: set[uint8]
  for tile in pulled:
    layersSeen.incl uint8(tile.layer)
  doAssert 1'u8 in layersSeen,
    "pulling across a river must keep the deck waypoint"
  var body = Body(
    pos: center(pulled[0]),
    facing: FixedZero,
    radius: 0.22'fx
  )
  walkTiles(body, pulled, 0)
  let (x, z) = cell(body.pos)
  doAssert x == 11 and z == 0
  doAssert walkLayer == 0, "the far bank is ground again"

echo "Body layer tests passed"
