import
  vmath,
  polyworld/[pathing, terrainmaps, terrainsurfaces]

const Kinds = [
  GrassSurface, DirtSurface, GravelSurface,
  MarshSurface, CobbleSurface, ForestSurface
]

proc flatLayer(width, depth: int): QuadLayer =
  ## Builds a small logical map without initializing any renderer state.
  result = QuadLayer(
    originX: 17,
    originZ: 23,
    width: width,
    depth: depth,
    tiles: newSeq[Tile](width * depth)
  )
  for tile in result.tiles.mitems:
    tile = Tile(flags: TileExists, kind: GrassTile)

template expectTerrainError(body: untyped) =
  ## Requires invalid visual settings to raise the module's error type.
  block:
    var raised = false
    try:
      body
    except TerrainMapError:
      raised = true
    doAssert raised

echo "Testing terrain sidecars preserve gameplay state and deterministic seeds"
block:
  let layer = flatLayer(4, 3)
  layer.tiles[1].kind = RoadTile
  layer.tiles[2].kind = TreeTile
  layer.tiles[3].kind = StoneTile
  layer.tiles[4].kind = MarshTile
  let
    before = layer.tiles
    map = buildTerrainMap([layer], Kinds, 123, chance = 1)
    repeated = buildTerrainMap([layer], Kinds, 123, chance = 1)
  doAssert layer.tiles == before
  doAssert map == repeated
  doAssert map != buildTerrainMap([layer], Kinds, 124, chance = 1)
  doAssert map.placements == 12
  doAssert map.layers[0].materials[1] == DirtSurface
  doAssert map.layers[0].materials[2] == ForestSurface
  doAssert map.layers[0].materials[3] == CobbleSurface
  doAssert map.layers[0].materials[4] == MarshSurface
  doAssert map.peak > 1
  doAssert map.blends.len == 12 * 4 * 4
  let empty = buildTerrainMap([layer], Kinds, 123, chance = 0)
  doAssert empty.placements == 0 and empty.peak == 0
  doAssert empty.blends == map.blends
  for value in empty.layers[0].ranges:
    doAssert value.y == 0
  let dense = buildTerrainMap([flatLayer(1, 1)], Kinds, 1, count = 32, chance = 1)
  doAssert dense.placements == 32 and dense.peak == 32
  doAssert dense.layers[0].ranges[0].y == 32

echo "Testing material neighborhoods and splats stop at disconnected heights"
block:
  let layer = flatLayer(2, 1)
  layer.tiles[0].kind = RoadTile
  layer.tiles[1].kind = StoneTile
  layer.tiles[1].tops = [8'i16, 8, 8, 8]
  let map = buildTerrainMap([layer], Kinds, 12, chance = 1)
  doAssert map.layers[0].ranges[0].y == 1
  doAssert map.layers[0].ranges[1].y == 1
  for value in map.blends[0 ..< 16]:
    doAssert value == -1 or value == DirtSurface.float32
  for value in map.blends[16 ..< 32]:
    doAssert value == -1 or value == CobbleSurface.float32
  layer.tiles[1].tops = [0'i16, 0, 0, 0]
  let connected = buildTerrainMap([layer], Kinds, 12, chance = 1)
  doAssert CobbleSurface.float32 in connected.blends[0 ..< 16]
  doAssert DirtSurface.float32 in connected.blends[16 ..< 32]

echo "Testing empty, water, multiple, and malformed layers"
block:
  let
    first = flatLayer(1, 1)
    water = flatLayer(1, 1)
    upper = flatLayer(1, 1)
  water.water = true
  upper.slab = true
  upper.tiles[0].tops = [16'i16, 16, 16, 16]
  let map = buildTerrainMap([first, water, upper], Kinds, 4, chance = 1)
  doAssert map.placements == 2
  doAssert map.layers[1].ranges.len == 0
  doAssert map.layers[2].ranges[0] == vec3(1, 1, 4)
  let empty = buildTerrainMap([], Kinds, 1)
  doAssert empty.placements == 0
  doAssert empty.blends.len == 4 and empty.brushes.len == 8
  expectTerrainError:
    discard buildTerrainMap([first], Kinds, 1, patchSize = NaN)
  expectTerrainError:
    discard buildTerrainMap([first], Kinds, 1, textureSize = 0)
  expectTerrainError:
    discard buildTerrainMap([first], [99], 1)
  expectTerrainError:
    discard buildTerrainMap([QuadLayer(nil)], Kinds, 1)
  first.tiles.setLen(0)
  expectTerrainError:
    discard buildTerrainMap([first], Kinds, 1)

echo "Terrain visual map tests passed"
