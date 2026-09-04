## Heartleaf houses: recipes are deterministic, stay inside their box, have
## one door, differ from seed to seed, and only name nodes that exist.

import
  std/[json, os, sets, strformat, strutils],
  vmath,
  ../examples/heartleaf/[decor, houses]

const DataRoot = "../polyworld_data"

proc isDoor(piece: HousePiece): bool =
  ## Whether one piece is the door leaf.
  piece.node == "door_01a"

proc isCourse(piece: HousePiece): bool =
  ## Whether one piece belongs to the brick course or the stone walls.
  piece.node.startsWith("wall_base_01") or
    piece.node.startsWith("foundation_block")

proc isPanel(piece: HousePiece): bool =
  ## Whether one piece is a three metre wall panel.
  piece.node in ["wall_01a", "wall_02a", "wall_04a", "wall_05a"]

echo "Testing house determinism"
block sameSeedSameHouse:
  for kind in HouseKind:
    doAssert buildHouse(1988, kind) == buildHouse(1988, kind),
      &"{kind} built differently from the same seed"

echo "Testing house shape"
block piecesStayHome:
  for seed in 1'i32 .. 40:
    for kind in HouseKind:
      let pieces = buildHouse(seed, kind)
      doAssert pieces.len > 8, &"{kind} seed {seed} has {pieces.len} pieces"
      var doors = 0
      var thatch = 0
      var frontCourse = 0
      var backCourse = 0
      var panels = 0
      var cubes = 0
      for piece in pieces:
        if piece.isCourse and piece.yaw != 0:
          ## Gable runs are the turned course pieces; eave runs lie along z.
          if piece.offset.z > 0: inc frontCourse else: inc backCourse
        if piece.isPanel:
          inc panels
          doAssert piece.stretch.z >= 0.85 and piece.stretch.z <= 1.15,
            &"{kind} seed {seed}: {piece.node} stretched {piece.stretch.z}"
        if piece.node.startsWith("foundation_block"): inc cubes
        doAssert abs(piece.offset.x) <= HouseExtent.x and
          abs(piece.offset.z) <= HouseExtent.z and
          piece.offset.y >= -1.0 and piece.offset.y <= HouseExtent.y,
          &"{kind} seed {seed}: {piece.node} at {piece.offset} is outside"
        doAssert houseNodesFor(piece.kit).contains(piece.node),
          &"{piece.node} is not in the house node list for {piece.kit}"
        if piece.isDoor: inc doors
        if piece.node == "roof_01a": inc thatch
      doAssert doors == 1, &"{kind} seed {seed} has {doors} doors"
      ## A brick course or stone wall leaves a gap in front of the door.
      doAssert backCourse == 0 or frontCourse < backCourse,
        &"{kind} seed {seed}: gable course {frontCourse} front, {backCourse} back"
      if kind == Longhouse:
        doAssert thatch >= 3, "a longhouse needs its thatch"
        doAssert cubes >= 40, &"a longhouse of {cubes} stones"
      else:
        doAssert thatch == 0, "a cottage should not be thatched"
        doAssert panels >= 8, &"a cottage of {panels} wall panels"

block seedsVary:
  var seen: HashSet[seq[HousePiece]]
  for seed in 1'i32 .. 20:
    seen.incl buildHouse(seed, Cottage)
  doAssert seen.len >= 8, &"only {seen.len} distinct cottages in twenty seeds"

block kindsMix:
  var longhouses = 0
  for slot in 0 ..< 9:
    if houseKindFor(1988, slot) == Longhouse:
      inc longhouses
  doAssert longhouses >= 1 and longhouses <= 6,
    &"{longhouses} longhouses out of nine"

echo "Testing that every house node exists in its kit"
block nodesExist:
  for kit in DecorKit:
    if houseNodesFor(kit).len == 0:
      continue
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
    for node in houseNodesFor(kit):
      doAssert node in known, &"{node} is not in {glb}"

echo "test_hlf_houses: all checks passed"
