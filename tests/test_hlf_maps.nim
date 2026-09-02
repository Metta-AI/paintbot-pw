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
    doAssert chebyshev(house.center, house.door) == 2,
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
