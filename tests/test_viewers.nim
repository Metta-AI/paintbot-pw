import
  std/math,
  polyworld/[player, viewers]

echo "Testing damping"
doAssert damping(0, 1) == 0
doAssert damping(1000, 1) > 0.99'f32
doAssert damping(5, 0) == 0

echo "Testing shortestTurn"
doAssert abs(shortestTurn(0, 0.1) - 0.1) < 1e-5
doAssert abs(shortestTurn(0.1, 0) + 0.1) < 1e-5
doAssert abs(shortestTurn(PI.float32, -PI.float32)) < 1e-4
doAssert shortestTurn(3.0, -3.0) > 0
doAssert shortestTurn(-3.0, 3.0) < 0

echo "Testing simulationActive"
block:
  var transport = initPlayer(live = true, durationTicks = 100, playing = false)
  doAssert not simulationActive(transport)
  transport.playing = true
  doAssert simulationActive(transport)
  transport.playing = false
  transport.targetTick = 10
  doAssert simulationActive(transport)

echo "Testing live tick cap"
doAssert atLiveTickCap(100, 100, true)
doAssert not atLiveTickCap(99, 100, true)
doAssert not atLiveTickCap(100, 100, false)

echo "Viewer tests passed"
