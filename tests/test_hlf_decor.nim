## Heartleaf decorations: deterministic, off the tiles the simulation
## cares about, and every node really exists in its kit.

import
  std/[json, os, sets, strformat],
  polyworld/pathing,
  ../examples/heartleaf/[content, maps, decor]

const
  Seed = 1988'i32
  DataRoot = "../polyworld_data"

echo "Testing decoration determinism"
block sameSeedSamePlacements:
  let
    map = generateMap(Seed)
    first = placeDecor(map, Seed)
    second = placeDecor(map, Seed)
  doAssert first.len > 40, &"only {first.len} decorations placed"
  doAssert first == second, "the same seed dressed the village differently"

echo "Testing where decorations land"
block placementRules:
  let
    map = generateMap(Seed)
    placed = placeDecor(map, Seed)
    centre = float32(GridSide div 2) + 0.5'f32
  var
    claimed: HashSet[int32]
    wellFound = false
  for d in placed:
    if d.node == "well_01a":
      doAssert d.x == centre and d.y == centre, "the well is off centre"
      wellFound = true
    if d.area == PlazaArea:
      let
        dx = d.x - centre
        dy = d.y - centre
      doAssert dx * dx + dy * dy <= PlazaLimit * PlazaLimit,
        &"{d.node} strayed off the plaza"
    elif d.area == GardenArea and d.node in GardenPots:
      doAssert map.kinds[tileIndex(d.tile)] == uint8(GardenTileKind)
      doAssert d.x == float32(d.tile.x) + 0.5'f32
      doAssert d.y == float32(d.tile.y) + 0.5'f32
    elif d.node != "flower_pot_01a" and d.lift == 0:
      let
        x = d.tile.x
        y = d.tile.y
        index = tileIndex(x, y)
      doAssert abs(d.x - float32(x) - 0.5'f32) <= 1.0'f32 and
        abs(d.y - float32(y) - 0.5'f32) <= 1.0'f32,
        &"{d.node} strayed more than a tile from its claim at {x},{y}"
      doAssert map.kinds[index] == uint8(GrassTile),
        &"{d.node} sits on tile kind {map.kinds[index]} at {x},{y}"
      doAssert map.passable[index] != 0, &"{d.node} sits on a blocked tile"
      doAssert index notin claimed, &"two decorations share tile {x},{y}"
      claimed.incl index
  doAssert wellFound, "no well"

block everyGardenHasOnePot:
  for seed in 1'i32 .. 40:
    let map = generateMap(seed)
    var pots: HashSet[int32]
    for decoration in placeDecor(map, seed):
      if decoration.area == GardenArea and decoration.node in GardenPots:
        let index = tileIndex(decoration.tile)
        doAssert index notin pots
        pots.incl index
    doAssert pots.len == GardenCount
    for tile in map.gardenTiles:
      doAssert tileIndex(tile) in pots

block bushesClearHouseDoors:
  for seed in 1'i32 .. 40:
    let map = generateMap(seed)
    for decoration in placeDecor(map, seed):
      if decoration.node notin ["bush_01a", "flower_bush_01a"]:
        continue
      for house in map.houses:
        doAssert chebyshev(decoration.tile, house.door) > HouseBushClearance,
          &"seed {seed}: {decoration.node} blocks door {house.door}"

block meadowAdditionStaysSmall:
  for seed in 1'i32 .. 20:
    let map = generateMap(seed)
    var
      foliage = 0
      rocks = 0
      mediumTrees = 0
      trees: seq[Tile2]
    for decoration in placeDecor(map, seed):
      if decoration.area != MeadowArea:
        continue
      if decoration.node in ["tree_05a", "tree_06a"]:
        doAssert decoration.height in [2.4'f32, 4.2'f32]
        if decoration.height == 4.2'f32:
          inc mediumTrees
        for tree in trees:
          doAssert chebyshev(decoration.tile, tree) >= 12
        trees.add decoration.tile
        for oy in -2'i32 .. 2'i32:
          for ox in -2'i32 .. 2'i32:
            doAssert map.kinds[tileIndex(int32(decoration.tile.x) + ox,
              int32(decoration.tile.y) + oy)] != uint8(RoadTile)
      elif decoration.kit == MeadowRocks:
        inc rocks
        doAssert decoration.height <= 1.0'f32
      else:
        inc foliage
        doAssert decoration.kit == MeadowVegetation
        doAssert decoration.height <= 0.8'f32
      for garden in map.gardenTiles:
        doAssert chebyshev(decoration.tile, garden) > 1
      for house in map.houses:
        doAssert chebyshev(decoration.tile, house.door) > HouseBushClearance
    doAssert foliage > 0 and foliage <= 243
    doAssert trees.len >= 4 and trees.len <= 6
    doAssert mediumTrees > 0 and mediumTrees <= 3
    doAssert rocks > 0 and rocks <= 5

block townGrassHasNearbyPlanting:
  let middle = int32(GridSide div 2)
  for seed in [1988'i32, 2026]:
    let map = generateMap(seed)
    var plants: seq[Tile2]
    for d in placeDecor(map, seed):
      if d.area == MeadowArea and d.kit == MeadowVegetation and d.height <= 0.8'f32:
        plants.add d.tile
    for y in middle - 26 .. middle + 26:
      for x in middle - 26 .. middle + 26:
        if map.kinds[tileIndex(x, y)] != uint8(GrassTile) or
            map.passable[tileIndex(x, y)] == 0:
          continue
        var nearest = GridSide
        for plant in plants:
          nearest = min(nearest, chebyshev(tile2(x, y), plant))
        doAssert nearest <= 8,
          &"seed {seed}: town grass at {x},{y} is {nearest} tiles from meadow planting"

block foliageReachesForest:
  let middle = tile2(GridSide div 2, GridSide div 2)
  for sample in 0'i32 .. 20:
    let
      seed = if sample == 0: 2026'i32 else: sample
      map = generateMap(seed)
    var
      count = 0
      coverage: array[2, array[4, bool]]
      besideTree = false
    for d in placeDecor(map, seed):
      if d.area != ForestFloorArea:
        continue
      inc count
      doAssert d.kit == MeadowVegetation
      doAssert d.height <= 0.8'f32
      let
        ring = chebyshev(d.tile, middle)
        dx = int32(d.tile.x) - int32(middle.x)
        dy = int32(d.tile.y) - int32(middle.y)
        side = if abs(dx) >= abs(dy): (if dx > 0: 0 else: 2)
               else: (if dy > 0: 1 else: 3)
      doAssert ring >= 36 and ring < ForestWallRadius
      coverage[ord(ring >= ForestEdgeRadius)][side] = true
      for garden in map.gardenTiles:
        doAssert chebyshev(d.tile, garden) > 1
      for oy in -1'i32 .. 1'i32:
        for ox in -1'i32 .. 1'i32:
          if map.kinds[tileIndex(int32(d.tile.x) + ox,
              int32(d.tile.y) + oy)] == uint8(TreeTile):
            besideTree = true
    doAssert count > 0 and count <= 96
    doAssert besideTree, &"seed {seed}: foliage never reaches the trees"
    for band in coverage:
      for covered in band:
        doAssert covered, &"seed {seed}: a side has an empty foliage band"

echo "Testing that every node exists in its kit"
block nodesExist:
  for kit in DecorKit:
    let manifest = DataRoot / kitFile(kit).parentDir / "manifest.json"
    doAssert fileExists(manifest),
      &"{manifest} is missing; clone polyworld_data next to this repo"
    let
      glb = kitFile(kit).extractFilename
      json = parseJson(readFile(manifest))
    var known: HashSet[string]
    for category in json["categories"]:
      if category["path"].getStr.extractFilename == glb:
        for node in category["nodes"]:
          known.incl node["node"].getStr
    doAssert known.len > 0, &"{glb} has no nodes in {manifest}"
    for node in nodesFor(kit):
      doAssert node in known, &"{node} is not in {glb}"

echo "test_hlf_decor: all checks passed"
