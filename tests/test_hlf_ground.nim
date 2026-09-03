## Heartleaf ground art: the cobble sheet tiles and carries per-stone
## heights, and the ground mask puts stone on the plaza, dirt on the roads,
## and nothing on gardens.

import
  std/strformat,
  polyworld/pathing,
  ../examples/heartleaf/[content, maps, ground]

const Seed = 1988'i32

echo "Testing the cobble sheet"
block sheetShape:
  let sheet = buildCobbleSheet(Seed)
  doAssert sheet.color.width == SheetSize and sheet.color.height == SheetSize
  doAssert sheet.height.width == SheetSize and sheet.height.height == SheetSize
  doAssert sheet.cells.len == SheetSize * SheetSize

block sheetHasStonesAndMortar:
  let sheet = buildCobbleSheet(Seed)
  var
    mortar = 0
    lowStone = 0
  for i, cell in sheet.cells:
    if cell < 0:
      mortar += 1
      doAssert sheet.height.data[i].r == 0, "mortar must have zero height"
    else:
      doAssert sheet.height.data[i].r >= 80,
        &"stone texel {i} is too low to outlast mortar"
      if sheet.height.data[i].r < 120:
        lowStone += 1
  let fraction = mortar.float / sheet.cells.len.float
  doAssert fraction > 0.10 and fraction < 0.35,
    &"mortar covers {fraction * 100:.0f}% of the sheet"
  doAssert lowStone > 0, "no stone landed near the height floor"

block sheetWraps:
  let sheet = buildCobbleSheet(Seed)
  var same = 0
  for y in 0 ..< SheetSize:
    if sheet.cells[y * SheetSize] == sheet.cells[y * SheetSize + SheetSize - 1]:
      same += 1
  for x in 0 ..< SheetSize:
    if sheet.cells[x] == sheet.cells[(SheetSize - 1) * SheetSize + x]:
      same += 1
  let fraction = same.float / (2 * SheetSize).float
  doAssert fraction > 0.7,
    &"only {fraction * 100:.0f}% of the seam texels share a stone"

block curbSheet:
  let sheet = buildCurbSheet(Seed)
  var
    mortar = 0
    highest = -1'i32
  for i, cell in sheet.cells:
    if cell < 0:
      mortar += 1
    else:
      highest = max(highest, cell)
      doAssert sheet.height.data[i].r >= 110,
        &"curb stone texel {i} sits below the curb height floor"
  doAssert highest == CurbStyle.cells * CurbStyle.cells - 1,
    &"curb sheet has {highest + 1} stones"
  let fraction = mortar.float / sheet.cells.len.float
  doAssert fraction > 0.05 and fraction < 0.35,
    &"curb mortar covers {fraction * 100:.0f}% of the sheet"
  doAssert CurbStones mod CurbStyle.cells == 0,
    "the curb stone count must be a multiple of the sheet's cells"

echo "Testing the ground mask"
block maskCoverage:
  let
    map = generateMap(Seed)
    mask = buildGroundMask(map, Seed)
    middle = GridSide div 2
  doAssert mask.len == MaskSize * MaskSize * MaskChannels

  proc texelAt(x, y: int): (uint8, uint8) =
    let index = (y * MaskSize + x) * MaskChannels
    (mask[index], mask[index + 1])

  proc tileTexel(tile: Tile2): (uint8, uint8) =
    texelAt(
      int(tile.x) * MaskTexelsPerTile + MaskTexelsPerTile div 2,
      int(tile.y) * MaskTexelsPerTile + MaskTexelsPerTile div 2)

  let (plazaStone, plazaDirt) = tileTexel(tile2(int32(middle), int32(middle)))
  doAssert plazaStone == 255, &"plaza centre stone coverage is {plazaStone}"
  doAssert plazaDirt == 255, "dirt must underlie the plaza"

  let (farStone, farDirt) = tileTexel(tile2(int32(middle + 40), int32(middle)))
  doAssert farStone == 0 and farDirt == 0,
    &"open meadow carries coverage {farStone}/{farDirt}"

  var roadFound = false
  for y in 0 ..< GridSide:
    for x in 0 ..< GridSide:
      let tile = tile2(int32(x), int32(y))
      if map.kinds[tileIndex(tile)] == uint8(RoadTile) and
          chebyshev(tile, tile2(int32(middle), int32(middle))) > 12:
        let (stone, dirt) = tileTexel(tile)
        doAssert dirt == 255, &"road tile {x},{y} has dirt coverage {dirt}"
        doAssert stone > 0, &"road tile {x},{y} has no cobbles"
        roadFound = true
  doAssert roadFound, "no road tile away from the plaza"

  for garden in map.gardenTiles:
    let (stone, dirt) = tileTexel(garden)
    doAssert stone == 0 and dirt == 0,
      &"garden {garden.x},{garden.y} carries coverage {stone}/{dirt}"

echo "test_hlf_ground: all checks passed"
