import
  polyworld/[bodies, fixed]

proc openGround(pos: FixedVec2): bool =
  ## Accepts every planar point.
  discard pos
  true

proc blockedPastX(pos: FixedVec2): bool =
  ## Blocks anything at or past two tiles on x.
  pos.x < 2'fx

echo "Testing world-integer tile conversion"
block:
  doAssert worldToTiles(60_000, 60_000) == FixedOne
  doAssert worldToTiles(0, 60_000) == FixedZero
  doAssert worldToTiles(-60_000, 60_000) == -FixedOne
  doAssert tilesToWorld(FixedOne, 60_000) == 60_000
  doAssert tilesToWorld(-FixedOne, 60_000) == -60_000
  doAssert tilesToWorld(FixedZero, 60_000) == 0
  let step = worldToTiles(5_500, 60_000)
  doAssert step > FixedZero
  doAssert tilesToWorld(step, 60_000) >= 5_499
  doAssert tilesToWorld(step, 60_000) <= 5_500

echo "Testing angle wrapping and shortest turns"
block:
  doAssert wrapAngle(FixedZero) == FixedZero
  doAssert wrapAngle(FixedPi + FixedPi) == FixedZero
  doAssert wrapAngle(-(FixedPi + FixedPi)) == FixedZero
  doAssert wrapAngle(FixedPi) == FixedPi
  doAssert wrapAngle(-FixedPi) == FixedPi
  doAssert shortestTurn(FixedZero, FixedPi) == FixedPi
  doAssert shortestTurn(FixedZero, -FixedHalfPi) == -FixedHalfPi
  doAssert abs(shortestTurn(FixedPi, -FixedPi)) <= Fixed(2)
  let
    westLeft = FixedPi - Fixed(200)
    westRight = -FixedPi + Fixed(200)
  doAssert abs(shortestTurn(westLeft, westRight)) <= Fixed(400)
  doAssert shortestTurn(westLeft, westRight) > FixedZero

echo "Testing turn toward a heading"
block:
  var facing = FixedZero
  turnToward(facing, FixedPi, 0.1'fx)
  doAssert facing == 0.1'fx
  turnToward(facing, FixedPi, FixedPi)
  doAssert facing == FixedPi
  facing = FixedZero
  turnToward(facing, -FixedHalfPi, 0.2'fx)
  doAssert facing == -0.2'fx
  facing = FixedPi - Fixed(200)
  let before = facing
  turnToward(facing, -FixedPi + Fixed(200), 0.1'fx)
  doAssert abs(shortestTurn(before, facing)) <= 0.1'fx + Fixed(2)
  doAssert abs(shortestTurn(facing, -FixedPi + Fixed(200))) <= Fixed(2)

echo "Testing cell floors and desired steps"
block:
  doAssert cell(fixedVec2(1.9'fx, -0.1'fx)) == (1'i32, -1'i32)
  doAssert cell(fixedVec2(FixedZero, FixedZero)) == (0'i32, 0'i32)
  let arrived = desiredStep(
    FixedVec2Zero,
    fixedVec2(0.2'fx, FixedZero),
    0.5'fx,
    0.35'fx
  )
  doAssert arrived == FixedVec2Zero
  let step = desiredStep(
    FixedVec2Zero,
    fixedVec2(fixed(10'i32), FixedZero),
    0.5'fx,
    0.35'fx
  )
  doAssert abs(length(step) - 0.5'fx) <= Fixed(2)
  doAssert step.x > FixedZero
  doAssert step.y == FixedZero

echo "Testing wall-slide along a blocked axis"
block:
  var pos = fixedVec2(1.5'fx, FixedZero)
  slide(pos, fixedVec2(1'fx, 0.5'fx), blockedPastX)
  doAssert pos.x == 1.5'fx
  doAssert pos.y == 0.5'fx
  slide(pos, fixedVec2(0.1'fx, 0.1'fx), openGround)
  doAssert pos == fixedVec2(1.6'fx, 0.6'fx)

echo "Testing circle-circle separation"
block:
  var
    a = Body(
      pos: FixedVec2Zero,
      facing: FixedZero,
      radius: 0.22'fx
    )
    b = Body(
      pos: fixedVec2(0.1'fx, FixedZero),
      facing: FixedZero,
      radius: 0.22'fx
    )
  separatePair(a, b, openGround)
  doAssert a.pos.x < FixedZero
  doAssert b.pos.x > 0.1'fx
  doAssert abs(distance(a.pos, b.pos) - 0.44'fx) <= Fixed(8)
  var
    stackedA = Body(pos: FixedVec2Zero, radius: 0.22'fx)
    stackedB = Body(pos: FixedVec2Zero, radius: 0.22'fx)
  separatePair(stackedA, stackedB, openGround)
  doAssert stackedA.pos == stackedB.pos

echo "Testing steer turns before walking backward"
block:
  var body = Body(
    pos: FixedVec2Zero,
    facing: FixedPi,
    radius: 0.22'fx
  )
  steer(
    body,
    fixedVec2(FixedOne, FixedZero),
    0.1'fx,
    0.35'fx,
    openGround
  )
  doAssert body.pos == FixedVec2Zero
  doAssert body.facing != FixedPi
  steer(
    body,
    fixedVec2(FixedOne, FixedZero),
    0.1'fx,
    FixedPi,
    openGround
  )
  doAssert body.pos.x > FixedZero
