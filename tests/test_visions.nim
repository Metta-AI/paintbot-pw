import polyworld/visions

const
  Width = 9'i32
  Height = 7'i32

var
  terrain = newSeq[int16](int(Width * Height))
  blockers = newSeq[int16](int(Width * Height))

echo "Testing integer line of sight range"
doAssert lineVisible(
  Width,
  Height,
  terrain,
  blockers,
  1,
  3,
  5,
  3,
  4
)
doAssert not lineVisible(
  Width,
  Height,
  terrain,
  blockers,
  1,
  3,
  6,
  3,
  4
)

echo "Testing tree and terrain occlusion"
blockers[3 * Width + 3] = 24
doAssert not lineVisible(
  Width,
  Height,
  terrain,
  blockers,
  1,
  3,
  5,
  3,
  8
)
blockers[3 * Width + 3] = 0
terrain[3 * Width + 3] = 20
doAssert not lineVisible(
  Width,
  Height,
  terrain,
  blockers,
  1,
  3,
  5,
  3,
  8
)

echo "Testing deterministic visibility maps"
terrain[3 * Width + 3] = 0
blockers[3 * Width + 3] = 24
var visible: seq[uint8]
revealVision(
  visible,
  Width,
  Height,
  terrain,
  blockers,
  [VisionSource(x: 1, z: 3, radius: 6, eyeHeight: 14)]
)
doAssert visible[3 * Width + 2] == 255
doAssert visible[3 * Width + 5] == 0
let softened = blurVisibility(visible, Width, Height)
doAssert softened.len == visible.len
doAssert softened[3 * Width + 2] > softened[3 * Width + 5]

echo "Testing the ray kernel matches live rounding"
block:
  proc roundAway(numerator, denominator: int64): int64 =
    ## Same half-away-from-zero rounding the kernel is built with.
    if numerator >= 0:
      (numerator + denominator div 2) div denominator
    else:
      -((-numerator + denominator div 2) div denominator)
  proc liveVisible(
      terrain, occluders: seq[int16], dx, dz: int32
  ): bool =
    ## Walks one ray with the original step formula.
    let steps = max(abs(dx), abs(dz))
    if steps <= 1:
      return true
    let
      sourceY = 14'i64
      targetY = 3'i64
    for step in 1'i32 ..< steps:
      let
        x = 8'i32 + int32(roundAway(int64(dx) * int64(step), int64(steps)))
        z = 8'i32 + int32(roundAway(int64(dz) * int64(step), int64(steps)))
        rayHeight = sourceY + roundAway(
          (targetY - sourceY) * int64(step),
          int64(steps)
        )
        obstacle = int64(terrain[z * 17 + x]) + int64(occluders[z * 17 + x])
      if obstacle >= rayHeight:
        return false
    true
  var
    wideTerrain = newSeq[int16](17 * 17)
    wideBlockers = newSeq[int16](17 * 17)
  wideBlockers[8 * 17 + 11] = 24
  wideTerrain[8 * 17 + 6] = 20
  for dz in -8'i32 .. 8'i32:
    for dx in -8'i32 .. 8'i32:
      if dx * dx + dz * dz > 64:
        continue
      let kernel = lineVisible(
        17, 17, wideTerrain, wideBlockers,
        8, 8, 8 + dx, 8 + dz, 8
      )
      doAssert kernel == liveVisible(wideTerrain, wideBlockers, dx, dz),
        "kernel ray " & $dx & "," & $dz & " diverged"
