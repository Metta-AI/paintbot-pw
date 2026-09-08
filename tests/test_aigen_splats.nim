import
  std/math,
  vmath,
  ../experiments/terrain/[aigen_splats, aigen_surfaces]

template expectAigenError(body: untyped) =
  ## Requires malformed map inputs to fail before placing any brushes.
  block:
    var raised = false
    try:
      body
    except AigenError:
      raised = true
    doAssert raised

echo "Testing variable-length terrain splat spans"
block:
  let surface = SplatTile(exists: true, material: 3)
  for count in [0, 1, 8, 32]:
    let map = generateSplats([surface], 1, 1, vec2(0), 42, count)
    doAssert map.placements == count
    doAssert map.spans[0].first == 0 and map.spans[0].count == count
    doAssert map.splats.len == count
    doAssert map == generateSplats([surface], 1, 1, vec2(0), 42, count)
    for splat in map.splats:
      doAssert splat.material in 3 .. 5
      doAssert splat.position.x >= 0 and splat.position.x <= 1
      doAssert splat.position.y >= 0 and splat.position.y <= 1
      doAssert splat.size >= 0.65 and splat.size <= 1.5
      doAssert splat.amount >= 0 and splat.amount <= 1
  expectAigenError:
    discard generateSplats([surface], 0, 1, vec2(0), 0, 1)
  expectAigenError:
    discard generateSplats([surface], 2, 1, vec2(0), 0, 1)
  expectAigenError:
    discard generateSplats([surface], 1, 1, vec2(0), 0, -1)
  expectAigenError:
    discard generateSplats([surface], 1, 1, vec2(0), 0, 1_000_001)
  expectAigenError:
    discard generateSplats(
      [SplatTile(exists: true, material: 18)], 1, 1, vec2(0), 0, 1
    )
  expectAigenError:
    discard generateSplats([surface], 1, 1, vec2(0), 0, 1, -0.1)
  expectAigenError:
    discard generateSplats([surface], 1, 1, vec2(0), 0, 1, 1, 0)

echo "Testing sparse placement and a shared texture scale"
block:
  var tiles = newSeq[SplatTile](100)
  for tile in tiles.mitems:
    tile = SplatTile(exists: true)
  let
    empty = generateSplats(tiles, 10, 10, vec2(0), 5, 1, 0, 2.5)
    sparse = generateSplats(tiles, 10, 10, vec2(0), 5, 1, 0.04, 2.5)
    dense = generateSplats(tiles, 10, 10, vec2(0), 5, 1, 1, 2.5)
  doAssert empty.placements == 0 and empty.splats.len == 0
  doAssert sparse.placements > 0 and sparse.placements < 20
  doAssert dense.placements == 100
  var untouched = 0
  for span in sparse.spans:
    if span.count == 0:
      inc untouched
  doAssert untouched > 0
  for splat in sparse.splats:
    doAssert splat.size == 2.5 and splat.amount == 1
    doAssert splat in dense.splats
  let scaled = generateSplats(tiles, 10, 10, vec2(0), 5, 1, 0.04, 4)
  doAssert scaled.placements == sparse.placements
  for splat in scaled.splats:
    doAssert splat.size == 4

echo "Testing large brushes reach connected tiles beyond immediate neighbors"
block:
  let tiles = [
    SplatTile(exists: true, material: 0),
    SplatTile(exists: true, material: 3),
    SplatTile(exists: true, material: 6),
    SplatTile(exists: true, material: 9),
    SplatTile(exists: true, material: 12)
  ]
  let map = generateSplats(tiles, 5, 1, vec2(0), 9, 1, 1, 12)
  for span in map.spans:
    doAssert span.count == 5

echo "Testing shared splats, stable ordering, and disconnected surfaces"
block:
  var tiles = [
    SplatTile(exists: true, material: 0, tops: [0'i16, 1, 0, 1]),
    SplatTile(exists: true, material: 6, tops: [1'i16, 2, 1, 2])
  ]
  let
    origin = vec2(-32, -32)
    map = generateSplats(tiles, 2, 1, origin, 43, 16)
    left = map.splats[0 ..< map.spans[0].count]
    right = map.splats[map.spans[1].first .. ^1]
  doAssert map.placements == 32
  doAssert map.spans[0].count > 16 and map.spans[1].count > 16
  var
    shared = 0
    previous = -1
  for splat in left:
    for j, candidate in right:
      if splat == candidate:
        doAssert j > previous
        previous = j
        inc shared
  doAssert shared > 0
  tiles[1].tops = [9'i16, 10, 9, 10]
  let disconnected = generateSplats(tiles, 2, 1, origin, 43, 16)
  doAssert disconnected.spans[0].count == 16
  doAssert disconnected.spans[1].count == 16
  tiles[1].exists = false
  let absent = generateSplats(tiles, 2, 1, origin, 43, 16)
  doAssert absent.placements == 16 and absent.spans[1].count == 0

echo "Testing packed splat transforms and material variation"
block:
  let
    splat = Splat(
      position: vec2(3, 7),
      size: 2,
      angle: PI.float32 / 2,
      amount: 0.7,
      material: 17
    )
    packed = packedSplats([splat])
  doAssert packed.len == 8
  doAssert packed[0] == 3 and packed[1] == 7
  doAssert abs(packed[2]) < 0.00001 and abs(packed[3] - 0.5) < 0.00001
  doAssert packed[4] == 17 and packed[5] == 0.7'f
  doAssert packedSplats(newSeq[Splat]()).len == 8
  for material in 0 ..< MaterialNames.len:
    var seen: array[3, bool]
    for x in -10 .. 10:
      for z in -10 .. 10:
        let selected = variant(x, z, material)
        doAssert selected div 3 == material div 3
        seen[selected mod 3] = true
    doAssert seen == [true, true, true]

echo "Testing material families and stamps that keep their assigned grass"
block:
  for material in 0 ..< SurfaceNames.len:
    let assigned = generateSplats(
      [SplatTile(exists: true, material: material, variants: 1)],
      1, 1, vec2(0), 12, 16, 1, 2.5, SurfaceNames.len
    )
    for splat in assigned.splats:
      doAssert splat.material == material
  let tiles = [
    SplatTile(exists: true, material: GrassSurface, variants: 4),
    SplatTile(exists: true, material: MarshSurface, variants: 1)
  ]
  let map = generateSplats(tiles, 2, 1, vec2(0), 12, 16, 1, 2.5, 9)
  var sampled: array[9, bool]
  for splat in map.splats:
    doAssert splat.material in 0 .. 3 or splat.material == MarshSurface
    sampled[splat.material] = true
  for material in [0, 1, 2, 3, 8]:
    doAssert sampled[material]
  expectAigenError:
    discard generateSplats(
      [SplatTile(exists: true, material: 8, variants: 2)],
      1, 1, vec2(0), 12, 1, 1, 2.5, 9
    )

echo "Testing coherent grass regions, stable seeds, and terrain influences"
block:
  const Width = 96
  let
    regions = initGrassRegions(1988, 24)
    repeated = initGrassRegions(1988, 24)
    changed = initGrassRegions(4321, 24)
    broad = initGrassRegions(1988, 48)
  var
    counts: array[4, int]
    same, broadSame, neighbors, differences: int
    lowMoss, highMoss, lowOlive, highOlive, flatSparse, steepSparse: int
  for z in 0 ..< Width:
    for x in 0 ..< Width:
      let
        px = x.float32 - 48.0'f
        pz = z.float32 - 48.0'f
        material = grassMaterial(regions, px, pz, 0, 0)
        broadMaterial = grassMaterial(broad, px, pz, 0, 0)
        low = grassMaterial(regions, px, pz, -0.8, 0)
        high = grassMaterial(regions, px, pz, 0.8, 0)
      doAssert material in GrassSurface .. SparseSurface
      inc counts[material]
      doAssert material == grassMaterial(repeated, px, pz, 0, 0)
      if material != grassMaterial(changed, px, pz, 0, 0):
        inc differences
      for (dx, dz) in [(1.0'f, 0.0'f), (0.0'f, 1.0'f)]:
        inc neighbors
        if material == grassMaterial(regions, px + dx, pz + dz, 0, 0):
          inc same
        if broadMaterial == grassMaterial(broad, px + dx, pz + dz, 0, 0):
          inc broadSame
      if low == MossSurface:
        inc lowMoss
      if high == MossSurface:
        inc highMoss
      if low == OliveSurface:
        inc lowOlive
      if high == OliveSurface:
        inc highOlive
      if material == SparseSurface:
        inc flatSparse
      if grassMaterial(regions, px, pz, 0, 1) == SparseSurface:
        inc steepSparse
  echo "Grass cells by material: ", counts
  echo "Matching grass neighbors: ", same, "/", neighbors
  for count in counts:
    doAssert count > Width, "Every grass painting must occupy a region."
  doAssert same.float32 / neighbors.float32 > 0.85,
    "Grass should form clumps, not independent tile choices."
  doAssert broadSame > same, "Larger patches must reduce material boundaries."
  doAssert differences > Width * Width div 3
  doAssert lowMoss > highMoss and highOlive > lowOlive
  doAssert steepSparse > flatSparse

echo "Testing a continuous winding road through the fort gate"
block:
  var
    left = 0.5'f
    right = 0.5'f
  for i in 0 .. 320:
    let z = i.float32 * 0.1'f
    let center = roadCenter(z)
    left = min(left, center)
    right = max(right, center)
    if z <= 10:
      doAssert center == 0.5'f
    doAssert roadDistance(center, z) < 0.0001
    doAssert roadHalfWidth(z) >= 1.29 and roadHalfWidth(z) <= 1.51
    for x in -8 .. 8:
      doAssert abs(roadDistance(x.float32 - 0.0001, z) -
        roadDistance(x.float32 + 0.0001, z)) < 0.001
  doAssert right - left > 6
  doAssert abs(roadCenter(10.01) - roadCenter(10)) < 0.001

echo "AI terrain splat tests passed"
