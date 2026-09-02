import
  vmath,
  polyworld/rtscameras

echo "Testing screen-edge pan directions"
block:
  let size = vec2(800, 600)
  doAssert rtsEdgePanDir(vec2(400, 300), size) == vec2(0, 0)
  doAssert rtsEdgePanDir(vec2(0, 300), size) == vec2(-1, 0)
  doAssert rtsEdgePanDir(vec2(799, 300), size) == vec2(1, 0)
  doAssert rtsEdgePanDir(vec2(400, 0), size) == vec2(0, -1)
  doAssert rtsEdgePanDir(vec2(400, 599), size) == vec2(0, 1)
  doAssert rtsEdgePanDir(vec2(0, 0), size) == vec2(-1, -1)
  doAssert rtsEdgePanDir(vec2(-1, 300), size) == vec2(0, 0)
  doAssert rtsEdgePanDir(vec2(0, 300), size, inside = false) == vec2(0, 0)
  doAssert rtsEdgePanDir(vec2(400, 300), size, 4) == vec2(0, 0)

echo "Testing edge pan stays off unless fullscreen"
block:
  doAssert not rtsEdgePanAllowed(false, true, false)
  doAssert not rtsEdgePanAllowed(true, false, false)
  doAssert not rtsEdgePanAllowed(true, true, true)
  doAssert rtsEdgePanAllowed(true, true, false)

echo "Testing combined pan does not double a held direction"
block:
  let doubled = rtsPanDir(vec2(0, -1), vec2(0, -1))
  doAssert abs(doubled.y + 1) < 0.001
  let diagonal = rtsPanDir(vec2(1, 0), vec2(0, -1))
  doAssert abs(diagonal.length - 1) < 0.001

echo "Testing pan scales with zoom"
block:
  doAssert rtsPanSpeed(80) > rtsPanSpeed(20) * 3
  var nearTarget = vec3(0, 0, 0)
  var farTarget = vec3(0, 0, 0)
  doAssert applyRtsPan(nearTarget, vec2(1, 0), 1.0'f32, 20, 64)
  doAssert applyRtsPan(farTarget, vec2(1, 0), 1.0'f32, 80, 64)
  doAssert farTarget.x > nearTarget.x * 3

echo "Testing pan stays on the map"
block:
  var target = vec3(60, 0, 0)
  doAssert applyRtsPan(target, vec2(1, 0), 1.0'f32, 100, 64)
  doAssert target.x == 64
  doAssert applyRtsPan(target, vec2(0, -1), 0.5'f32, 100, 64)
  doAssert target.z < 0
  doAssert not applyRtsPan(target, vec2(0, 0), 1.0'f32, 100, 64)

echo "Testing follow frame lifts the subject"
block:
  let
    subject = vec3(0, 1, 0)
    framed = rtsFollowFrame(subject, 80)
    farther = rtsFollowFrame(subject, 160)
  doAssert framed.x == 0
  doAssert framed.y == 1
  doAssert framed.z > 0
  doAssert farther.z > framed.z
  let lower = rtsFollowFrame(subject, 80, RtsGotaFollowLift)
  doAssert lower.z > 0
  doAssert lower.z < framed.z

echo "Testing ground tile picking"
block:
  let tile = groundTile(vec3(-63.2, 0, 4.1), 64, 128)
  doAssert tile[0] == 0
  doAssert tile[1] == 68

echo "RTS camera tests passed"
