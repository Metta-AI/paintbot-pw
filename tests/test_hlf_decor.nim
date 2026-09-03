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
