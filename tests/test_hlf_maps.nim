## Heartleaf map generation: determinism, connectivity, and a playable
## village on every seed the generator claims to support.

import
  std/[sets, strformat, strutils],
  polyworld/pathing,
  ../examples/heartleaf/content,
  ../examples/heartleaf/maps

const SeedsUnderTest = 30

echo "Testing map determinism"
block sameSeedSameMap:
  let
    first = generateMap(DefaultSeed)
    second = generateMap(DefaultSeed)
  doAssert first.hash == second.hash, "the same seed produced two maps"
  doAssert first.passable == second.passable
  doAssert first.kinds == second.kinds
  doAssert first.houses == second.houses
  doAssert first.gardenTiles == second.gardenTiles
  doAssert first.hash != 0, "the map fingerprint is empty"

block differentSeedsDifferentMaps:
  var seen: HashSet[uint64]
  for seed in 1'i32 .. 20'i32:
    let map = generateMap(seed)
    doAssert map.hash notin seen, &"seed {seed} collided with another map"
    seen.incl map.hash

echo "Testing connectivity and playability"
block everySeedValidates:
  for seed in 1'i32 .. SeedsUnderTest:
    let map = generateMap(seed)
    map.validateMap()

block doorsHaveContinuousRoads:
  for seed in 1'i32 .. SeedsUnderTest:
    let map = generateMap(seed)
    var reached = newSeq[bool](GridCells)
    var frontier = @[map.houses[0].door]
    reached[tileIndex(frontier[0])] = true
    while frontier.len > 0:
      let tile = frontier.pop()
      for (dx, dy) in [(0'i32, -1'i32), (1'i32, 0'i32),
          (0'i32, 1'i32), (-1'i32, 0'i32)]:
        let next = tile2(int32(tile.x) + dx, int32(tile.y) + dy)
        if not inGrid(next):
          continue
        let index = tileIndex(next)
        if not reached[index] and map.passable[index] != 0 and
            map.kinds[index] in [uint8(RoadTile), uint8(StoneTile)]:
          reached[index] = true
          frontier.add next
    for house in map.houses:
      doAssert reached[tileIndex(house.door)],
        &"seed {seed}: reaching a house requires leaving the road"

block southernPlazaRoadIsShared:
  let map = generateMap(DefaultSeed)
  for y in 75'i32 .. 81'i32:
    var strips = 0
    var pavedBefore = false
    for x in 62'i32 .. 70'i32:
      let paved = map.kinds[tileIndex(x, y)] == uint8(RoadTile)
      if paved and not pavedBefore:
        inc strips
      pavedBefore = paved
    doAssert strips == 1,
      &"default map has {strips} separate southern roads at row {y}"

block narrowParallelRoads:
  ## Count six-tile stretches of road separated by one to three unpaved
  ## tiles. Wide roads and ordinary intersections do not count.
  var runs = 0
  for seed in [1'i32, 7, 1988, DefaultSeed]:
    let map = generateMap(seed)
    for y in 1'i32 .. GridSide - 7:
      for x in 1'i32 .. GridSide - 7:
        for (dx, dy) in [(1'i32, 0'i32), (0'i32, 1'i32)]:
          for gap in 1'i32 .. 3'i32:
            var parallel = true
            for step in 0'i32 .. 5'i32:
              let
                px = x + dy * step
                py = y + dx * step
              if map.kinds[tileIndex(px, py)] != uint8(RoadTile) or
                  map.kinds[tileIndex(px + dx * (gap + 1),
                    py + dy * (gap + 1))] != uint8(RoadTile):
                parallel = false
                break
              for across in 1'i32 .. gap:
                if map.kinds[tileIndex(px + dx * across, py + dy * across)] in
                    [uint8(RoadTile), uint8(StoneTile)]:
                  parallel = false
            if parallel:
              inc runs
  doAssert runs == 0, &"{runs} narrow parallel road stretches remain"

echo "Testing village invariants"
block gridsAreWellFormed:
  let map = generateMap(DefaultSeed)
  doAssert map.passable.len == GridCells
  doAssert map.kinds.len == GridCells
  doAssert map.heights.len == GridCells
  var
    walkable = 0
    forest = 0
    gardens = 0
  for index in 0 ..< GridCells:
    if map.passable[index] == 1:
      inc walkable
    if map.kinds[index] == uint8(TreeTile):
      inc forest
      doAssert map.passable[index] == 0, "a forest tile is walkable"
    if map.kinds[index] == uint8(GardenTileKind):
      inc gardens
  doAssert walkable > GridCells div 4,
    &"only {walkable} of {GridCells} tiles are walkable"
  doAssert forest >= 1000, &"only {forest} forest tiles frame the map"
  doAssert gardens == GardenCount,
    &"the grid holds {gardens} garden tiles, wanted {GardenCount}"

block housesRingThePlaza:
  let map = generateMap(DefaultSeed)
  for slot, house in map.houses:
    let ring = chebyshev(house.center, tile2(GridSide div 2, GridSide div 2))
    doAssert ring >= 15 and ring <= 40,
      &"house {slot} sits {ring} tiles from the plaza"
    doAssert chebyshev(house.center, house.door) == HouseFootprint div 2 + 1,
      &"house {slot} has a detached door"
    for other in 0 ..< slot:
      doAssert chebyshev(house.center, map.houses[other].center) > 6,
        &"houses {other} and {slot} overlap"

block gardensBelongToHouses:
  ## Each block of three gardens sits within gathering reach of its house.
  let map = generateMap(DefaultSeed)
  for slot in 0 ..< VillagerCount:
    for i in 0 ..< GardensPerHouse:
      let garden = map.gardenTiles[slot * GardensPerHouse + i]
      doAssert chebyshev(garden, map.houses[slot].center) <= 8,
        &"garden {i} strayed from house {slot}"

echo "Testing that a broken map is actually caught"
block validationRejectsABlockedDoor:
  var map = generateMap(DefaultSeed)
  map.passable[tileIndex(map.houses[0].door)] = 0
  var caught = false
  try:
    map.validateMap()
  except AssertionDefect:
    caught = true
  doAssert caught, "a blocked door passed validation"

block validationRejectsAPavedGarden:
  var map = generateMap(DefaultSeed)
  map.kinds[tileIndex(map.gardenTiles[0])] = 1'u8  # RoadTile
  var caught = false
  try:
    map.validateMap()
  except AssertionDefect:
    caught = true
  doAssert caught, "a paved-over garden passed validation"

echo "test_hlf_maps: all checks passed"
let sample = generateMap(DefaultSeed)
echo "  seed ", DefaultSeed, " mapHash = ", toHex(sample.hash)
