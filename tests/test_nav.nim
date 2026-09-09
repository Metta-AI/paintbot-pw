import
  polyworld/[bodies, fixed]

proc openGround(pos: FixedVec2): bool =
  ## Accepts every planar point.
  true

proc wall(pos: FixedVec2): bool =
  ## Blocks the positive x half-plane while allowing wall sliding.
  pos.x < FixedZero

proc closedGround(pos: FixedVec2): bool =
  ## Rejects every attempted step.
  false

proc reach(goal: FixedVec2, facing, speed, turnRate: Fixed) =
  ## Requires bounded arrival, decreasing distance, and no complete spin.
  let budget = toInt(ceil(length(goal) / speed)) +
    toInt(ceil(FixedPi / turnRate)) + 8
  var
    body = Body(facing: facing)
    rotation = FixedZero
  for tick in 0 ..< budget:
    let
      before = body
      remaining = distanceSquared(body.pos, goal)
    steer(body, goal - body.pos, speed, turnRate, openGround)
    let turned = abs(shortestTurn(before.facing, body.facing))
    rotation += turned
    doAssert turned <= turnRate + Fixed(2)
    doAssert distance(body.pos, before.pos) <= speed + Fixed(4)
    doAssert distanceSquared(body.pos, goal) <= remaining,
      "navigation moved away from a stationary goal"
    doAssert rotation <= FixedPi + 0.02'fx,
      "navigation kept rotating around a stationary goal"
    if body.pos == goal:
      let arrived = body
      steer(body, goal - body.pos, speed, turnRate, openGround)
      doAssert body == arrived, "arrival must leave position and facing stable"
      return
  doAssert false, "navigation missed its arrival deadline: goal=" & $goal &
    " position=" & $body.pos & " facing=" & $facing & " speed=" & $speed &
    " turnRate=" & $turnRate

echo "Testing a nearby waypoint cannot trap a turning body in an orbit"
block:
  let goal = fixedVec2(0.36'fx, FixedZero)
  var
    body = Body(facing: FixedPi * 7 / 8)
    rotation = FixedZero
  for tick in 0 ..< 600:
    if distance(body.pos, goal) <= 0.35'fx:
      break
    let before = body.facing
    steer(
      body,
      goal - body.pos,
      fixed(340) / fixed(2400),
      0.35'fx,
      openGround
    )
    rotation += abs(shortestTurn(before, body.facing))
  doAssert distance(body.pos, goal) <= 0.35'fx,
    "body orbited a fixed waypoint for 600 ticks; rotation=" & $rotation

echo "Testing navigation arrival across headings, ranges, and turning speeds"
block:
  const
    Distances = [Fixed(1), 0.1'fx, 0.35'fx, 0.36'fx, 0.5'fx, 4'fx]
    Speeds = [0.05833'fx, 0.1'fx, 0.14167'fx, 0.2125'fx, 1'fx]
    TurnRates = [0.1'fx, 0.35'fx, FixedPi]
  for bearing in 0 ..< 16:
    for heading in 0 ..< 32:
      for dist in Distances:
        for speed in Speeds:
          for turnRate in TurnRates:
            reach(
              direction(FixedPi * int32(bearing) / 8) * dist,
              wrapAngle(FixedPi * int32(heading) / 16),
              speed,
              turnRate
            )

echo "Testing navigation across the signed angle boundary"
block:
  for bearing in [FixedPi - Fixed(1), -FixedPi + Fixed(1)]:
    for heading in [FixedPi - Fixed(1), -FixedPi + Fixed(1)]:
      reach(direction(bearing), heading, 0.1'fx, 0.35'fx)

echo "Testing wall sliding and blocked goals settle without spinning"
block:
  for walkable in [Walkable(wall), Walkable(closedGround)]:
    let goal = fixedVec2(1'fx, 1'fx)
    var
      body = Body(pos: fixedVec2(-1'fx, -1'fx), facing: FixedPi)
      rotation = FixedZero
    for tick in 0 ..< 200:
      let before = body
      steer(body, goal - body.pos, 0.1'fx, 0.35'fx, walkable)
      rotation += abs(shortestTurn(before.facing, body.facing))
      doAssert body.pos.x < FixedZero
      doAssert distanceSquared(body.pos, goal) <=
        distanceSquared(before.pos, goal)
    doAssert rotation < FixedPi + FixedHalfPi
    let stopped = body
    for tick in 0 ..< 100:
      steer(body, goal - body.pos, 0.1'fx, 0.35'fx, walkable)
      doAssert body == stopped, "blocked navigation must settle"

echo "Testing stopped bodies turn once without moving or spinning"
block:
  var body = Body(facing: FixedPi)
  for tick in 0 ..< 100:
    steer(body, fixedVec2(1'fx, FixedZero), FixedZero, 0.35'fx, openGround)
    doAssert body.pos == FixedVec2Zero
  doAssert body.facing == FixedZero

echo "Navigation tests passed"
