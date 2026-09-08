## Light vs Dark map generation: determinism, exact symmetry, connectivity,
## and a playable opening on every seed the generator claims to support.

import
  std/[sets, strformat, strutils],
  polyworld/pathing,
  ../examples/light_vs_dark/content,
  ../examples/light_vs_dark/maps

const
  SeedsUnderTest = 50
  BattleClearings = [(64, 64, 22), (96, 32, 16), (32, 96, 16)]

proc checkForest(map: MapData) =
  ## Checks that woods form adjoining patches outside the battle areas.
  var
    trees = 0
    surrounded = 0
  for y in 0 ..< GridSide:
    for x in 0 ..< GridSide:
      if map.treeWood[tileIndex(x, y)] == 0:
        continue
      inc trees
      for (cx, cy, radius) in BattleClearings:
        let
          dx = x * 2 + 1 - int32(cx * 2)
          dy = y * 2 + 1 - int32(cy * 2)
        doAssert dx * dx + dy * dy > int32(radius * radius * 4),
          &"seed {map.seed}: a tree crowds the battle at ({x},{y})"
      if min(x, y) >= 22 and max(x, y) < GridSide - 22:
        doAssert abs(x - y) > 6,
          &"seed {map.seed}: a tree blocks the approach at ({x},{y})"
      var neighbours = 0
      for (dx, dy) in [(1'i32, 0'i32), (-1'i32, 0'i32),
        (0'i32, 1'i32), (0'i32, -1'i32)]:
          let
            tx = x + dx
            ty = y + dy
          if inGrid(tx, ty) and map.treeWood[tileIndex(tx, ty)] > 0:
            inc neighbours
      if neighbours >= 2:
        inc surrounded
  doAssert surrounded * 100 >= trees * 80,
    &"seed {map.seed}: only {surrounded}/{trees} trees form dense patches"

echo "Testing map determinism"
block sameSeedSameMap:
  let
    first = generateMap(DefaultSeed)
    second = generateMap(DefaultSeed)
  doAssert first.hash == second.hash, "the same seed produced two maps"
  doAssert first.passable == second.passable
  doAssert first.treeWood == second.treeWood
  doAssert first.kinds == second.kinds
  doAssert first.mines == second.mines
  doAssert first.hallOrigin == second.hallOrigin
  doAssert first.hash != 0, "the map fingerprint is empty"

block differentSeedsDifferentMaps:
  var seen: HashSet[uint64]
  for seed in 1'i32 .. 20'i32:
    let map = generateMap(seed)
    doAssert map.hash notin seen, &"seed {seed} collided with another map"
    seen.incl map.hash

echo "Testing symmetry, connectivity, and opening playability"
block everySeedValidates:
  for seed in 1'i32 .. SeedsUnderTest:
    let map = generateMap(seed)
    map.validateMap()
    map.checkForest()

echo "Testing map invariants"
block gridsAreWellFormed:
  let map = generateMap(DefaultSeed)
  map.checkForest()
  doAssert map.passable.len == GridCells
  doAssert map.kinds.len == GridCells
  doAssert map.treeWood.len == GridCells
  var
    walkable = 0
    wooded = 0
  for index in 0 ..< GridCells:
    if map.passable[index] == 1:
      inc walkable
    if map.treeWood[index] > 0:
      inc wooded
      doAssert map.treeWood[index] == WoodPerTree,
        "a tree started partly harvested"
      doAssert map.passable[index] == 1,
        "a tree grew on terrain nothing can stand on"
  doAssert walkable > GridCells div 2,
    &"only {walkable} of {GridCells} tiles are walkable"
  doAssert wooded >= 400, &"only {wooded} tree tiles were planted"
  doAssert wooded mod 2 == 0, "trees were not planted in mirror pairs"

block minesAreDistinctAndMirrored:
  let map = generateMap(DefaultSeed)
  doAssert map.mines.len == 6
  for index, mine in map.mines:
    doAssert mine.id == FirstMineId + int32(index),
      "mine identifiers are not assigned in order"
    for other in map.mines[0 ..< index]:
      doAssert chebyshev(mine.origin, other.origin) > 2,
        "two gold mines overlap"
  ## Mines come in mirror pairs, so their gold totals must match pairwise.
  doAssert map.mines[0].gold == map.mines[1].gold
  doAssert map.mines[2].gold == map.mines[3].gold
  doAssert map.mines[4].gold == map.mines[5].gold
  doAssert map.mines[0].gold == MainMineGold
  doAssert map.mines[2].gold == ExpansionMineGold
  doAssert map.mines[4].gold == ExpansionMineGold

block hallsAreMirroredAndFarApart:
  let map = generateMap(DefaultSeed)
  let
    light = map.hallOrigin[LightPlayer]
    dark = map.hallOrigin[DarkPlayer]
    (mirrorX, mirrorY) = mirrorTile(int32(light.x) + 2, int32(light.y) + 2)
  doAssert int32(dark.x) == mirrorX and int32(dark.y) == mirrorY,
    "the two town halls are not mirror images"
  doAssert chebyshev(light, dark) > 60,
    "the two bases start too close together"

block cornerPlateauHasTwoWalls:
  ## The town sits on a corner plateau that meets the map edges. Only the
  ## inward sides have cliffs, and the two expansions stay open.
  let map = generateMap(DefaultSeed)
  doAssert map.passable[tileIndex(22, 22)] == 1,
    "the town pad should be walkable"
  doAssert map.passable[tileIndex(1, 20)] == 1,
    "the plateau should reach the west map edge"
  doAssert map.passable[tileIndex(20, 1)] == 1,
    "the plateau should reach the north map edge"
  doAssert map.passable[tileIndex(34, 34)] == 1,
    "the diagonal ramp should be open"
  var
    eastWall = false
    southWall = false
    padTrees = 0
    padGrass = 0
    padSand = 0
  for y in 0'i32 ..< 40'i32:
    for x in 0'i32 ..< 40'i32:
      let index = tileIndex(x, y)
      if map.treeWood[index] > 0:
        inc padTrees
      if x < 32 and y < 32 and map.passable[index] == 1:
        if map.kinds[index] == uint8(GrassTile) or
            map.kinds[index] == uint8(TreeTile):
          inc padGrass
        if map.kinds[index] == uint8(RoadTile):
          inc padSand
    if map.passable[tileIndex(y, 22)] == 0 and y >= 30:
      eastWall = true
    if map.passable[tileIndex(22, y)] == 0 and y >= 30:
      southWall = true
  doAssert eastWall, "the east cliff is missing"
  doAssert southWall, "the south cliff is missing"
  doAssert padTrees >= 8, &"only {padTrees} trees grew on the plateau"
  doAssert padGrass > 0, "the plateau has no grass"
  doAssert padSand > 0, "the plateau has no sand"
  for (x, y) in [(48'i32, 22'i32), (22'i32, 48'i32)]:
    doAssert map.treeWood[tileIndex(x, y)] == 0,
      &"a tree grew in the clearing at ({x},{y})"
    doAssert map.passable[tileIndex(x, y)] == 1,
      &"the clearing at ({x},{y}) is not walkable"

block eachPlayerHasACloseMine:
  ## Every player needs a mine near home, or the opening cannot function.
  let map = generateMap(DefaultSeed)
  for player in 0 ..< PlayerCount:
    var closest = GridSide
    for mine in map.mines:
      closest = min(closest, chebyshev(map.hallOrigin[player], mine.origin))
    doAssert closest <= 12,
      &"player {player} has no mine within reach; closest is {closest} tiles"

echo "Testing that a broken map is actually caught"
block validationRejectsAnAsymmetricMap:
  var map = generateMap(DefaultSeed)
  ## Open one tile without opening its mirror.
  var index = -1
  for candidate in 0 ..< GridCells:
    if map.passable[candidate] == 0:
      index = candidate
      break
  doAssert index >= 0, "the map has no blocked tile to corrupt"
  map.passable[index] = 1
  var caught = false
  try:
    map.validateMap()
  except AssertionDefect:
    caught = true
  doAssert caught, "an asymmetric map passed validation"

block validationRejectsAStolenForest:
  var map = generateMap(DefaultSeed)
  for index in 0 ..< GridCells:
    if map.treeWood[index] > 0:
      map.treeWood[index] = 0
      break
  var caught = false
  try:
    map.validateMap()
  except AssertionDefect:
    caught = true
  doAssert caught, "a lopsided forest passed validation"

echo "test_lvd_maps: all checks passed"
let sample = generateMap(DefaultSeed)
echo "  seed ", DefaultSeed, " mapHash = ", toHex(sample.hash)
echo "  halls ", sample.hallOrigin[LightPlayer], " and ",
  sample.hallOrigin[DarkPlayer]
for mine in sample.mines:
  echo "  mine ", mine.id, " at ", mine.origin, " holding ", mine.gold
