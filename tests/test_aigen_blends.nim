import
  std/math,
  vmath,
  ../experiments/terrain/aigen_blends

proc close(a, b: Vec4, epsilon = 0.0001'f): bool =
  ## Compares all four blend channels within floating-point tolerance.
  result = abs(a.x - b.x) < epsilon and abs(a.y - b.y) < epsilon and
    abs(a.z - b.z) < epsilon and abs(a.w - b.w) < epsilon

proc rockAmount(
  x, z: float32,
  height = true,
  strength = 1.2'f
): float32 =
  ## Samples one rock tile surrounded by grass across all neighboring cells.
  let
    origin = floor(vec2(x, z) - vec2(0.5))
    position = vec2(x, z) - origin - vec2(0.5)
  var
    materials = vec4(0.0)
    heights = vec4(0.25)
  for dz in 0 .. 1:
    for dx in 0 .. 1:
      if origin.x.int + dx == 0 and origin.y.int + dz == 0:
        materials[dz * 2 + dx] = 6
        heights[dz * 2 + dx] = 0.75
  var weights = materialWeights(radialWeights(position), materials)
  if height:
    weights = reliefWeights(weights, heights, strength, 0.12)
  for slot in 0 .. 3:
    if materials[slot] == 6:
      result += weights[slot]

echo "Testing circular support and exact tile-center ownership"
block:
  doAssert close(radialWeights(vec2(0)), vec4(1, 0, 0, 0))
  doAssert close(radialWeights(vec2(1, 0)), vec4(0, 1, 0, 0))
  doAssert close(radialWeights(vec2(0, 1)), vec4(0, 0, 1, 0))
  doAssert close(radialWeights(vec2(1)), vec4(0, 0, 0, 1))
  doAssert close(radialWeights(vec2(0.5)), vec4(0.25))
  for i in 0 .. 90:
    let angle = i.float32 * PI.float32 / 180.0'f
    let position = vec2(cos(angle), sin(angle)) * 0.8'f
    doAssert abs(radialWeights(position).x - 0.1296'f) < 0.0001
  for enabled in [false, true]:
    doAssert rockAmount(0.5, 0.5, enabled) == 1
    for (x, z) in [(-0.5'f, 0.5'f), (1.5'f, 0.5'f),
        (0.5'f, -0.5'f), (0.5'f, 1.5'f)]:
      doAssert rockAmount(x, z, enabled) == 0

echo "Testing shared materials combine before height competition"
block:
  let
    threeGrasses = materialWeights(vec4(0.1, 0.3, 0.3, 0.3), vec4(6, 0, 0, 0))
    oneGrass = materialWeights(vec4(0.1, 0.9, 0, 0), vec4(6, 0, -1, -1))
  doAssert close(threeGrasses, oneGrass)
  doAssert close(
    reliefWeights(threeGrasses, vec4(0.75, 0.25, 0.25, 0.25), 1.2, 0.12),
    reliefWeights(oneGrass, vec4(0.75, 0.25, 1, 1), 1.2, 0.12)
  )
  doAssert close(materialWeights(vec4(0.25), vec4(2)), vec4(1, 0, 0, 0))
  doAssert close(
    materialWeights(vec4(0.25), vec4(-1, 4, -1, -1)), vec4(0, 1, 0, 0)
  )
  doAssert close(
    reliefWeights(vec4(0, 1, 0, 0), vec4(1, 0, 1, 1), 2, 0.12),
    vec4(0, 1, 0, 0)
  )
  for amount in [0.000001'f, 0.0001'f, 0.001'f]:
    doAssert close(
      reliefWeights(vec4(1 - amount, amount, 0, 0), vec4(0, 1, 1, 1), 2, 0.02),
      vec4(1, 0, 0, 0)
    ), "Tiny coverage must not win through height alone."

echo "Testing rounded patches remain continuous across the tile grid"
block:
  for strength in [0.0'f, 1.2'f, 2.0'f]:
    for i in 0 .. 100:
      let coordinate = -0.5'f + i.float32 * 0.02'f
      for boundary in [-0.5'f, 0.0'f, 0.5'f, 1.0'f, 1.5'f]:
        doAssert abs(
          rockAmount(boundary - 0.00001, coordinate, strength > 0, strength) -
          rockAmount(boundary + 0.00001, coordinate, strength > 0, strength)
        ) < 0.001
        doAssert abs(
          rockAmount(coordinate, boundary - 0.00001, strength > 0, strength) -
          rockAmount(coordinate, boundary + 0.00001, strength > 0, strength)
        ) < 0.001
      doAssert abs(rockAmount(coordinate, 0.2, strength > 0, strength) -
        rockAmount(0.2, coordinate, strength > 0, strength)) < 0.0001

echo "Terrain blend tests passed"
