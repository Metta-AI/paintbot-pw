import polyworld/noises

echo "Testing roundDivision"
block:
  doAssert roundDivision(5, 2) == 3
  doAssert roundDivision(4, 2) == 2
  doAssert roundDivision(-5, 2) == -3
  doAssert roundDivision(-4, 2) == -2
  doAssert roundDivision(0, 7) == 0
  doAssert roundDivision(1024, 1024) == 1

echo "Testing smoothstep endpoints"
block:
  doAssert smoothstep(0) == 0
  doAssert smoothstep(MapBlendScale) == MapBlendScale
  doAssert smoothstep(-10) == 0
  doAssert smoothstep(MapBlendScale + 10) == MapBlendScale
  let mid = smoothstep(MapBlendScale div 2)
  doAssert mid > 0 and mid < MapBlendScale

echo "Testing blendHeight"
block:
  doAssert blendHeight(10, 20, 0) == 10
  doAssert blendHeight(10, 20, MapBlendScale) == 20
  doAssert blendHeight(10, 20, MapBlendScale div 2) == 15

echo "Testing packedHeights"
block:
  let packed = packedHeights([1'i32, -2, 3, 4])
  doAssert packed == [1'i16, -2, 3, 4]

echo "Testing valueNoise is deterministic"
block:
  const Stream = 0xA0761D6478BD642F'u64
  doAssert valueNoise(2026, Stream, 10, 20, 8) ==
    valueNoise(2026, Stream, 10, 20, 8)
  doAssert valueNoise(2026, Stream, 10, 20, 8) !=
    valueNoise(2027, Stream, 10, 20, 8)
  doAssert valueNoise(2026, Stream, 10, 20, 8) !=
    valueNoise(2026, Stream xor 1, 10, 20, 8)

echo "Testing valueNoise lattice is even across the origin"
block:
  const Stream = 0xE7037ED1A0B428DB'u64
  # Truncating division would put x = -1 in cell 0. Flooring puts it in
  # cell -1, so the sample must differ from the same offset on the
  # positive side of a different cell.
  let
    negative = valueNoise(9, Stream, -1, 0, 8)
    positive = valueNoise(9, Stream, 7, 0, 8)
  doAssert negative != positive,
    "negative coordinates must not share the origin lattice cell"

echo "Noise helper tests passed"
