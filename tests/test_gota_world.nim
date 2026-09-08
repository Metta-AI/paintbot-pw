## Gods of the Arena map: dense woods must leave all three lanes open.

import
  polyworld/pathing,
  ../examples/gods_of_the_arena/maps

const
  MidLane = [
    (GroundLayer, 23, 21), (GroundLayer, 29, 21),
    (GroundLayer, 48, 54), (GroundLayer, 65, 61),
    (GroundLayer, 82, 68), (GroundLayer, 98, 106),
    (GroundLayer, 104, 106)
  ]
  TopLane = [
    (GroundLayer, 23, 20), (GroundLayer, 29, 20),
    (GroundLayer, 107, 21), (GroundLayer, 107, 32),
    (GroundLayer, 107, 98), (GroundLayer, 107, 104)
  ]
  BottomLane = [
    (GroundLayer, 20, 23), (GroundLayer, 20, 29),
    (GroundLayer, 21, 107), (GroundLayer, 32, 107),
    (GroundLayer, 98, 107), (GroundLayer, 104, 107)
  ]

proc checkLane(stops: openArray[(int, int, int)]) =
  ## Checks each stop on a battle lane remains reachable through the woods.
  for i in 0 ..< stops.len - 1:
    let
      a = stops[i]
      b = stops[i + 1]
      route = findTilePath(a[0], a[1], a[2], b[0], b[1], b[2])
    doAssert route.len > 0,
      "a lane is blocked between " & $a & " and " & $b

proc checkForest(seed: int32) =
  ## Checks repeatable forest chunks and open roads across map seeds.
  let
    first = generateMap(seed)
    second = generateMap(seed)
    ground = layers[GroundLayer]
  doAssert first.hash == second.hash, "the same seed changed its forest"
  doAssert layers.len == 4, "the arena needs ground, two forts, and water"
  for layerIndex, layer in layers:
    doAssert layer.water == (layerIndex == WaterLayer)
  var
    trees = 0
    grouped = 0
    marsh = 0
    waterTiles = 0
  for z in 0 ..< GridTiles:
    for x in 0 ..< GridTiles:
      let tile = ground.tiles[z * GridTiles + x]
      doAssert tile.exists, "the arena should have continuous ground"
      let water = layers[WaterLayer].tiles[z * GridTiles + x]
      if water.exists:
        inc waterTiles
        doAssert isWalkable(GroundLayer, x, z) and not tile.impassable,
          "the submerged riverbed must remain walkable"
        doAssert not isWalkable(WaterLayer, x, z),
          "units must wade on the bed instead of standing on the water"
        doAssert tile.kind == MarshTile,
          "water should stay in the marsh channel"
        var submerged = false
        for corner, height in tile.tops:
          let depth = water.tops[corner].int32 - height.int32
          doAssert depth <= WaterDepthSteps, "the water is deeper than knees"
          if depth > 0:
            submerged = true
        doAssert submerged, "water should only cover a submerged tile"
      if tile.kind == MarshTile:
        inc marsh
        doAssert not tile.impassable and isWalkable(GroundLayer, x, z),
          "the marsh channel should be walkable"
      if tile.kind != TreeTile:
        continue
      inc trees
      doAssert tile.impassable and not isWalkable(GroundLayer, x, z),
        "a tree must block its tile"
      for fort in [RedFortTile, BlueFortTile]:
        doAssert max(abs(x - fort), abs(z - fort)) > 19,
          "a forest entered a fort clearing"
      var neighbours = 0
      for dz in -2 .. 2:
        for dx in -2 .. 2:
          let
            tx = x + dx
            tz = z + dz
          if tx < 0 or tz < 0 or tx >= GridTiles or tz >= GridTiles:
            continue
          let nearby = ground.tiles[tz * GridTiles + tx].kind
          doAssert nearby != RoadTile, "a forest crowds a battle lane"
          if abs(dx) + abs(dz) == 1 and nearby == TreeTile:
            inc neighbours
      if neighbours >= 2:
        inc grouped
  doAssert trees > 0, "the forest is missing"
  doAssert marsh > GridTiles, "the former river should have marsh terrain"
  doAssert waterTiles > GridTiles, "the shallow river should span the map"
  doAssert grouped * 100 >= trees * 80,
    "seed " & $seed & ": only " & $grouped & "/" & $trees &
      " trees form dense patches"
  checkLane(TopLane)
  checkLane(MidLane)
  checkLane(BottomLane)

echo "Testing dense forests and clear lanes across seeds"
for seed in 1'i32 .. 50'i32:
  checkForest(seed)
checkForest(1988)
checkForest(2026)

echo "Testing the middle lane crosses the depressed marsh channel"
block:
  discard generateMap(2026)
  var tiles: seq[PathTile]
  for i in 0 ..< MidLane.len - 1:
    let
      a = MidLane[i]
      b = MidLane[i + 1]
      segment = findTilePath(a[0], a[1], a[2], b[0], b[1], b[2])
    doAssert segment.len > 0, "each mid-lane stop must be reachable"
    for tileIndex, tile in segment:
      if tiles.len > 0 and tileIndex == 0:
        continue
      tiles.add tile
  for tile in tiles:
    doAssert tile.layer == GroundLayer,
      "the middle lane should stay on the ground"
  doAssert isWalkable(GroundLayer, 65, 61),
    "the former bridge centre should be walkable ground"
  let centre = layers[GroundLayer].tiles[61 * GridTiles + 65]
  doAssert layers[WaterLayer].tiles[61 * GridTiles + 65].exists,
    "the middle lane should wade through the shallow river"
  doAssert centre.kind == MarshTile,
    "the lane crossing should retain the river's marsh color"
  for height in centre.tops:
    doAssert height < -11, "the riverbed should remain below nearby terrain"
  let pulled = smoothPathTiles(tiles)
  doAssert pulled.len >= 2, "the middle lane needs a complete route"
  for tile in pulled:
    doAssert tile.layer == GroundLayer,
      "creeps should follow the middle lane entirely on the ground"

echo "Testing distinct fort materials and flat wall tops"
block:
  discard generateMap(1988)
  for (layerIndex, kind) in [(RedFortLayer, RedFortKind),
      (BlueFortLayer, BlueFortKind)]:
    let
      fort = layers[layerIndex]
      center = FortOuterRadius
      wallHeight = fort.tiles[fort.width + center].tops[0]
    var walls = 0
    for z in 0 ..< fort.depth:
      for x in 0 ..< fort.width:
        let
          tile = fort.tiles[z * fort.width + x]
          ring = max(abs(x - center), abs(z - center))
        if ring == FortOuterRadius:
          doAssert not tile.exists, "a crenellation remains outside the wall"
        if not tile.exists:
          continue
        doAssert tile.kind == kind, "the fort should use its own stone"
        for height in tile.tops:
          doAssert height <= wallHeight, "nothing should rise above the wall"
        if ring == FortWallRadius:
          inc walls
          doAssert isWalkable(layerIndex, x, z), "the wall should be walkable"
          for height in tile.tops:
            doAssert height == wallHeight, "wall tops should be level"
    doAssert walls == FortWallRadius * 8, "the wall ring should remain complete"

echo "GOTA world tests passed"
