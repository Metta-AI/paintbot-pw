import
  polyworld/[bodies, fixed, pathing],
  ../examples/call_to_adventure/[content, sim]

proc flatFloor(width, depth: int): QuadLayer =
  ## Builds connected tiles for an isolated navigation scenario.
  result = QuadLayer(
    width: width,
    depth: depth,
    tiles: newSeq[Tile](width * depth)
  )
  for tile in result.tiles.mitems:
    tile = Tile(
      flags: TileExists or TileConnectedEast or TileConnectedSouth
    )

proc walker(world: World, tile: TileRef, speed: int32): int32 =
  ## Places a living walker with the requested navigation speed.
  world.addActor(Actor(home: tile, speed: speed, hp: 1, maxHp: 1))

proc finishPath(world: World, slot: int32, goal: TileRef, budget: int) =
  ## Requires a real path to complete on walkable tiles within a deadline.
  let actor = world.actors[slot]
  doAssert world.stepToward(slot, goal)
  for tick in 0 ..< budget:
    # Repeated bot commands must not restart turning or add movement.
    let before = actor.body
    doAssert world.stepToward(slot, goal)
    doAssert actor.body == before
    discard world.advancePath(slot)
    doAssert actor.home.walkable, "navigation left the walkable floor"
    if actor.home == goal and actor.path.len == 0:
      let arrived = actor.body
      for idle in 0 ..< 20:
        doAssert not world.advancePath(slot)
        doAssert actor.body == arrived
      return
  doAssert false, "CTA navigation missed its arrival deadline: goal=" &
    $goal & " position=" & $actor.body.pos & " pathIndex=" & $actor.pathIndex

echo "Testing CTA repathing from off-center cannot orbit the start waypoint"
block:
  layers = @[flatFloor(16, 16)]
  computeWalkable()
  let
    world = newWorld(Setup(seed: 1988))
    slot = world.addActor(Actor(
      home: TileRef(level: 0, x: 5, z: 5),
      speed: ClassSpeeds[RogueClass],
      hp: 1,
      maxHp: 1
    ))
    actor = world.actors[slot]
    goal = TileRef(level: 0, x: 10, z: 5)
  actor.body.pos = fixedVec2(5.5'fx - 0.36'fx, 5.5'fx)
  actor.body.facing = FixedPi * 7 / 8
  doAssert world.setPath(slot, goal)
  for tick in 0 ..< 600:
    discard world.advancePath(slot)
  doAssert actor.home == goal and actor.path.len == 0,
    "CTA never left its starting waypoint: " & $actor.body.pos

echo "Testing CTA off-center starts across hero speeds and headings"
block:
  layers = @[flatFloor(16, 16)]
  computeWalkable()
  for class in HeroClass:
    for scale in [50'i32, 100'i32, 150'i32]:
      for heading in 0 ..< 32:
        let
          world = newWorld(Setup(seed: 1988))
          slot = world.walker(
            TileRef(level: 0, x: 5, z: 5),
            ClassSpeeds[class] * scale div 100
          )
        world.actors[slot].body.pos = fixedVec2(5.14'fx, 5.5'fx)
        world.actors[slot].body.facing =
          wrapAngle(FixedPi * int32(heading) / 16)
        world.finishPath(slot, TileRef(level: 0, x: 10, z: 10), 400)

echo "Testing CTA navigation rounds narrow corners in both directions"
block:
  let floor = flatFloor(12, 12)
  for z in 0 ..< floor.depth:
    for x in 0 ..< floor.width:
      let corridor =
        (x == 2 and z in 2 .. 8) or
        (z == 8 and x in 2 .. 8) or
        (x == 8 and z in 2 .. 8)
      if not corridor:
        floor.tiles[z * floor.width + x].flags = 0
  layers = @[floor]
  computeWalkable()
  for class in HeroClass:
    let
      world = newWorld(Setup(seed: 1988))
      start = TileRef(level: 0, x: 2, z: 2)
      goal = TileRef(level: 0, x: 8, z: 2)
      slot = world.walker(start, ClassSpeeds[class])
    world.actors[slot].body.facing = -FixedHalfPi
    world.finishPath(slot, goal, 600)
    world.finishPath(slot, start, 600)

echo "Testing CTA navigation turns on connected ramp landings"
block:
  let
    lower = flatFloor(10, 10)
    upper = flatFloor(10, 10)
  for z in 0 ..< 10:
    for x in 0 ..< 10:
      if z == 5 and x in 2 .. 4:
        if x == 4:
          lower.tiles[z * 10 + x].tops = [0'i16, 8, 0, 8]
      else:
        lower.tiles[z * 10 + x].flags = 0
      if (z == 5 and x in 5 .. 7) or (x == 7 and z in 2 .. 5):
        upper.tiles[z * 10 + x].tops = [8'i16, 8, 8, 8]
      else:
        upper.tiles[z * 10 + x].flags = 0
  layers = @[lower, upper]
  computeWalkable()
  let
    world = newWorld(Setup(seed: 1988))
    start = TileRef(level: 0, x: 2, z: 5)
    goal = TileRef(level: 1, x: 7, z: 2)
    slot = world.walker(start, ClassSpeeds[RogueClass])
  world.actors[slot].body.facing = FixedPi
  world.finishPath(slot, goal, 300)
  world.finishPath(slot, start, 300)

echo "Testing CTA navigation recovers after a moving target reverses"
block:
  layers = @[flatFloor(16, 16)]
  computeWalkable()
  let
    world = newWorld(Setup(seed: 1988))
    slot = world.walker(
      TileRef(level: 0, x: 8, z: 8),
      ClassSpeeds[RogueClass]
    )
  for goal in [
    TileRef(level: 0, x: 13, z: 13),
    TileRef(level: 0, x: 3, z: 3),
    TileRef(level: 0, x: 13, z: 3)
  ]:
    doAssert world.stepToward(slot, goal)
    for tick in 0 ..< 7:
      discard world.advancePath(slot)
  world.finishPath(slot, TileRef(level: 0, x: 3, z: 13), 300)

echo "Testing CTA blocked routes stop turning and recover when reopened"
block:
  let floor = flatFloor(8, 1)
  layers = @[floor]
  computeWalkable()
  let
    world = newWorld(Setup(seed: 1988))
    slot = world.walker(
      TileRef(level: 0, x: 1, z: 0),
      ClassSpeeds[RogueClass]
    )
    actor = world.actors[slot]
    goal = TileRef(level: 0, x: 6, z: 0)
  doAssert world.setPath(slot, goal)
  floor.tiles[3].flags = 0
  computeWalkable()
  for tick in 0 ..< 300:
    discard world.advancePath(slot)
    doAssert actor.home.x < 3
  doAssert actor.path.len == 0
  let stopped = actor.body
  for tick in 0 ..< 100:
    discard world.advancePath(slot)
    doAssert actor.body == stopped
  floor.tiles[3].flags = TileExists or TileConnectedEast or TileConnectedSouth
  computeWalkable()
  world.finishPath(slot, goal, 150)

echo "CTA navigation tests passed"
