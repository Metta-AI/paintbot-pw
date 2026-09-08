## Gods of the Arena map generation.
##
## Builds the packed terrain and its walkability from an explicit seed using
## only integers. Writes `pathing.layers` once and returns a `MapData`. The
## simulation never writes terrain. Graphics may sample `surfaceHeight` and
## must not write simulation state.

import
  polyworld/[fixed, hashes, noises, pathing, profiles, rngs]

const
  FordCenters = [(107, 21), (21, 107)]
  RedFortTile* = 20
  BlueFortTile* = GridTiles - 1 - RedFortTile
  FortPlateauRadius = 15
  FortOuterRadius* = 12
  FortWallRadius* = 11
  GroundLayer* = 0
  RedFortLayer* = 1
  BlueFortLayer* = 2
  RedFortKind* = 6'u32
  BlueFortKind* = 7'u32
  TerrainAmplitudeSteps = 11'i32
  RiverBedSteps = -16'i32
  FordBedSteps = -4'i32
  FortWallHeightSteps = 36'i32
  FortGateClearanceSteps = 24'i32
  FortKeepHeightSteps = 11'i32
  ForestNoiseStream = 0xD1B54A32D192ED03'u64
  ForestDetailStream = 0x8CB92BA72F3D8DD7'u64
  ForestRollStream = 0x2545F4914F6CDD1D'u64
  ForestDensityPercent = 70'i64
    ## Chance of a candidate at the forest map's peak.
  ForestPatchRadius = 4'i32
    ## Fills neighbouring tiles into compact, solid patches of woods.

type MapData* = object
  seed*: int32
  hash*: uint64

proc triangleWave(value, period: int): int32 =
  ## Returns a deterministic signed triangle wave in fixed integer units.
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

proc mapFingerprint(): uint64 =
  ## Hashes the packed map and its derived walkability in stable sequence order.
  var hash = HashySeed
  hash.addHashy(layers.len)
  for layerIndex, layer in layers:
    hash.addHashy(layer.originX)
    hash.addHashy(layer.originZ)
    hash.addHashy(layer.width)
    hash.addHashy(layer.depth)
    hash.addHashy(layer.slab)
    hash.addHashy(layer.water)
    for tileIndex, tile in layer.tiles:
      hash.addHashy(uint32(tile.flags))
      hash.addHashy(uint32(tile.kind))
      for value in tile.tops:
        hash.addHashy(value)
      for value in tile.bottoms:
        hash.addHashy(value)
      hash.addHashy(layerWalkable[layerIndex][tileIndex])
  uint64(hash)

var battleMapHash*: uint64

proc generateMap*(seed: int32): MapData {.measure.} =
  ## Builds a marsh channel, rolling ground, forests, and two fort layers.
  proc ground(cx, cz: int): int32 =
    let value =
      valueNoise(seed, 0xA0761D6478BD642F'u64, cx, cz, 24) * 4 +
      valueNoise(seed, 0xE7037ED1A0B428DB'u64, cx, cz, 12) * 2 +
      valueNoise(seed, 0x8EBC6AF09C88C6E3'u64, cx, cz, 6)
    int32(roundDivision(
      int64(value) * TerrainAmplitudeSteps,
      int64(MapBlendScale) * 7
    ))

  let
    redPlateau = ground(RedFortTile, RedFortTile)
    bluePlateau = ground(BlueFortTile, BlueFortTile)

  proc riverBlend(cx2, cz2: int): int32 =
    ## Blends from the river banks to the bed using doubled coordinates.
    let
      wiggle2 = int(triangleWave(cx2 - cz2, 168)) * 8 div MapBlendScale
      axisDistance2 = abs(cx2 + cz2 - GridTiles * 2 - wiggle2)
      ratio = clamp(
        int32(axisDistance2 * MapBlendScale div 23),
        0'i32,
        MapBlendScale
      )
      cubic = int32(roundDivision(
        int64(ratio) * int64(ratio) * int64(ratio),
        int64(MapBlendScale) * int64(MapBlendScale)
      ))
    MapBlendScale - cubic

  proc makeCorner(cx, cz: int): int32 =
    ## Corner height as a pure function of the corner coordinate: tiles that
    ## share a corner always agree, so the surface has no accidental walls.
    result = ground(cx, cz)
    result = blendHeight(result, RiverBedSteps, riverBlend(cx * 2, cz * 2))
    for (fordX, fordZ) in FordCenters:
      let
        deltaX = int64(cx - fordX)
        deltaZ = int64(cz - fordZ)
        distance = integerSqrt(
          (deltaX * deltaX + deltaZ * deltaZ) *
          int64(MapBlendScale) * int64(MapBlendScale)
        )
        amount = smoothstep(MapBlendScale - int32(distance div 14))
      result = blendHeight(result, FordBedSteps, amount)
    for (fortTile, plateau) in [
      (RedFortTile, redPlateau), (BlueFortTile, bluePlateau)
    ]:
      let ring = max(abs(cx - fortTile), abs(cz - fortTile))
      if ring <= FortPlateauRadius + 4:
        let amount = smoothstep(
          int32(FortPlateauRadius + 4 - ring) * MapBlendScale div 4
        )
        result = blendHeight(result, plateau, amount)

  var cornerHeights: array[(GridTiles + 1) * (GridTiles + 1), int16]
  for z in 0 .. GridTiles:
    for x in 0 .. GridTiles:
      cornerHeights[z * (GridTiles + 1) + x] = int16(makeCorner(x, z))
  template corner(cx, cz: int): int32 =
    int32(cornerHeights[(cz) * (GridTiles + 1) + (cx)])

  var groundLayer = QuadLayer(
    originX: 0, originZ: 0,
    width: GridTiles, depth: GridTiles,
    slab: false,
    tiles: newSeq[Tile](GridTiles * GridTiles)
  )
  template gtile(x, z: int): var Tile = groundLayer.tiles[(z) * GridTiles + (x)]

  for z in 0 ..< GridTiles:
    for x in 0 ..< GridTiles:
      let
        tops = [corner(x, z), corner(x + 1, z),
                corner(x, z + 1), corner(x + 1, z + 1)]
        heightSum = tops[0] + tops[1] + tops[2] + tops[3]
        nearRiver = riverBlend(x * 2 + 1, z * 2 + 1) > 102
        kind =
          if nearRiver and heightSum < 10:
            MarshTile
          elif heightSum > TerrainAmplitudeSteps * 2:
            RockTile
          else:
            GrassTile
      gtile(x, z) = Tile(
        flags: TileExists or TileConnectedEast or TileConnectedSouth,
        kind: kind,
        tops: packedHeights(tops)
      )

  for (fortTile, plateau) in [
    (RedFortTile, redPlateau),
    (BlueFortTile, bluePlateau)
  ]:
    for z in 0 ..< GridTiles:
      for x in 0 ..< GridTiles:
        let ring = max(abs(x - fortTile), abs(z - fortTile))
        if ring <= FortPlateauRadius:
          gtile(x, z).kind = RoadTile

  # Lanes: cosmetic road tiles along the three lane polylines, and a
  # dilated "near lane" mask that keeps the forests off the roads.
  const LanePolylines = [
    @[(23, 20), (29, 20), (96, 20), (104, 22),
      (107, 32), (107, 98), (107, 104)],
    @[(23, 21), (29, 21), (48, 54), (65, 61),
      (82, 68), (98, 106), (104, 106)],
    @[(20, 23), (20, 29), (20, 96), (22, 104),
      (32, 107), (98, 107), (104, 107)],
  ]
  var laneMask: array[GridTiles * GridTiles, bool]
  for polyline in LanePolylines:
    for i in 0 ..< polyline.len - 1:
      let
        (ax, az) = polyline[i]
        (bx, bz) = polyline[i + 1]
        steps = max(abs(bx - ax), abs(bz - az)) * 4
      for step in 0 .. steps:
        let
          divisor = max(steps, 1)
          x = ax + int(roundDivision(int64(bx - ax) * step, divisor))
          z = az + int(roundDivision(int64(bz - az) * step, divisor))
        for dx in -1 .. 0:
          for dz in -1 .. 0:
            let (tx, tz) = (x + dx, z + dz)
            if tx >= 0 and tx < GridTiles and tz >= 0 and tz < GridTiles:
              laneMask[tz * GridTiles + tx] = true
  var nearLane: array[GridTiles * GridTiles, bool]
  for z in 0 ..< GridTiles:
    for x in 0 ..< GridTiles:
      block dilate:
        for dz in -2 .. 2:
          for dx in -2 .. 2:
            let (tx, tz) = (x + dx, z + dz)
            if tx >= 0 and tx < GridTiles and tz >= 0 and tz < GridTiles and
                laneMask[tz * GridTiles + tx]:
              nearLane[z * GridTiles + x] = true
              break dilate
  for z in 0 ..< GridTiles:
    for x in 0 ..< GridTiles:
      let fortRing = min(
        max(abs(x - RedFortTile), abs(z - RedFortTile)),
        max(abs(x - BlueFortTile), abs(z - BlueFortTile)))
      if laneMask[z * GridTiles + x] and fortRing > 1 and
        gtile(x, z).kind != StoneTile and gtile(x, z).kind != MarshTile and
        not gtile(x, z).impassable:
          gtile(x, z).kind = RoadTile

  proc isGate(fortTile, x, z: int, redSide: bool): bool =
    ## Returns whether a wall tile is one of a fort's inward-facing arches.
    if redSide:
      (x == fortTile + FortWallRadius and abs(z - fortTile) <= 1) or
        (z == fortTile + FortWallRadius and abs(x - fortTile) <= 1)
    else:
      (x == fortTile - FortWallRadius and abs(z - fortTile) <= 1) or
        (z == fortTile - FortWallRadius and abs(x - fortTile) <= 1)

  proc buildFort(
      fortTile: int,
      plateau: int32,
      redSide: bool
  ): QuadLayer =
    ## Builds a fort slab with a walkable rampart, arches, ramps, and dais.
    const FortSize = FortOuterRadius * 2 + 1
    result = QuadLayer(
      originX: fortTile - FortOuterRadius,
      originZ: fortTile - FortOuterRadius,
      width: FortSize,
      depth: FortSize,
      slab: true,
      tiles: newSeq[Tile](FortSize * FortSize)
    )
    template ftile(x, z: int): var Tile =
      result.tiles[
        (z - result.originZ) * result.width + (x - result.originX)
      ]
    let
      wallTop = plateau + FortWallHeightSteps
      keepTop = plateau + FortKeepHeightSteps
      kind =
        if redSide:
          RedFortKind
        else:
          BlueFortKind
      stoneFlags =
        TileExists or TileConnectedEast or TileConnectedSouth

    for z in result.originZ ..< result.originZ + result.depth:
      for x in result.originX ..< result.originX + result.width:
        let ring = max(abs(x - fortTile), abs(z - fortTile))
        if ring == FortWallRadius:
          let bottom =
            if isGate(fortTile, x, z, redSide):
              plateau + FortGateClearanceSteps
            else:
              plateau - 1
          ftile(x, z) = Tile(
            flags: stoneFlags,
            kind: kind,
            tops: packedHeights([wallTop, wallTop, wallTop, wallTop]),
            bottoms: packedHeights([bottom, bottom, bottom, bottom])
          )
          if not isGate(fortTile, x, z, redSide):
            gtile(x, z).impassable = true
        elif ring <= 1:
          ftile(x, z) = Tile(
            flags: stoneFlags,
            kind: kind,
            tops: packedHeights([keepTop, keepTop, keepTop, keepTop]),
            bottoms: packedHeights([plateau, plateau, plateau, plateau])
          )
          gtile(x, z).impassable = true

    if redSide:
      let rampZ = fortTile - 4
      for x in fortTile + 2 .. fortTile + FortWallRadius - 1:
        proc rampHeight(cx: int): int32 =
          plateau + int32(roundDivision(
            int64(FortWallHeightSteps) * (cx - fortTile - 2),
            FortWallRadius - 2
          ))
        ftile(x, rampZ) = Tile(
          flags: stoneFlags,
          kind: kind,
          tops: packedHeights([
            rampHeight(x),
            rampHeight(x + 1),
            rampHeight(x),
            rampHeight(x + 1)
          ]),
          bottoms: packedHeights([
            plateau - 1,
            plateau - 1,
            plateau - 1,
            plateau - 1
          ])
        )
        gtile(x, rampZ).impassable = true
      ftile(fortTile + 2, fortTile) = Tile(
        flags: stoneFlags,
        kind: kind,
        tops: packedHeights([keepTop, plateau, keepTop, plateau]),
        bottoms: packedHeights([plateau, plateau, plateau, plateau])
      )
      gtile(fortTile + 2, fortTile).impassable = true
    else:
      let rampZ = fortTile + 4
      for x in fortTile - FortWallRadius + 1 .. fortTile - 2:
        proc rampHeight(cx: int): int32 =
          plateau + int32(roundDivision(
            int64(FortWallHeightSteps) * (fortTile - 1 - cx),
            FortWallRadius - 2
          ))
        ftile(x, rampZ) = Tile(
          flags: stoneFlags,
          kind: kind,
          tops: packedHeights([
            rampHeight(x),
            rampHeight(x + 1),
            rampHeight(x),
            rampHeight(x + 1)
          ]),
          bottoms: packedHeights([
            plateau - 1,
            plateau - 1,
            plateau - 1,
            plateau - 1
          ])
        )
        gtile(x, rampZ).impassable = true
      ftile(fortTile - 2, fortTile) = Tile(
        flags: stoneFlags,
        kind: kind,
        tops: packedHeights([plateau, keepTop, plateau, keepTop]),
        bottoms: packedHeights([plateau, plateau, plateau, plateau])
      )
      gtile(fortTile - 2, fortTile).impassable = true

  let
    redFort = buildFort(RedFortTile, redPlateau, true)
    blueFort = buildFort(BlueFortTile, bluePlateau, false)

  proc openForTree(x, z: int): bool =
    ## Keeps each tree clear of lanes, forts, and blocked terrain.
    if x < 0 or z < 0 or x >= GridTiles or z >= GridTiles:
      return false
    let fortRing = min(
      max(abs(x - RedFortTile), abs(z - RedFortTile)),
      max(abs(x - BlueFortTile), abs(z - BlueFortTile))
    )
    if gtile(x, z).kind != GrassTile or gtile(x, z).impassable or
      nearLane[z * GridTiles + x] or fortRing <= FortPlateauRadius + 4:
        return false
    true

  # Noise chooses patch centres and the total tree count for each seed.
  # Each patch fills solidly instead of rolling separately for its trees.
  var
    forestRng = initRng(seed, ForestRollStream)
    forestTiles: seq[tuple[x, z: int]]
  for z in 0 ..< GridTiles:
    for x in 0 ..< GridTiles:
      if not openForTree(x, z):
        continue
      let
        forest = int64(
          valueNoise(seed, ForestNoiseStream, x, z, 20) * 2 +
          valueNoise(seed, ForestDetailStream, x, z, 10))
        roll = int64(forestRng.below(int32(MapBlendScale)))
      if forest <= 0 or roll * 300 >= forest * ForestDensityPercent:
        continue
      forestTiles.add((x, z))

  for i in countdown(forestTiles.high, 1):
    let j = int(forestRng.below(int32(i + 1)))
    swap(forestTiles[i], forestTiles[j])

  var planted = 0
  proc plantPatch(x, z: int) =
    ## Fills outwards from one forest centre until the tree budget is met.
    let radius = int(2 + forestRng.below(ForestPatchRadius - 1))
    for ring in 0 .. radius:
      for dz in -ring .. ring:
        for dx in -ring .. ring:
          if max(abs(dx), abs(dz)) != ring or
            dx * dx + dz * dz > radius * radius:
              continue
          if planted >= forestTiles.len:
            return
          let
            tx = x + dx
            tz = z + dz
          if openForTree(tx, tz):
            gtile(tx, tz).kind = TreeTile
            gtile(tx, tz).impassable = true
            inc planted

  for (x, z) in forestTiles:
    if planted >= forestTiles.len:
      break
    plantPatch(x, z)

  layers = @[groundLayer, redFort, blueFort]
  computeWalkable()
  result.seed = seed
  result.hash = mapFingerprint()
  battleMapHash = result.hash
