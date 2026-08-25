import
  std/tables,
  polyworld/rngs

echo "Testing stream reproducibility"
block:
  var first = initRng(2026, 0xA0761D6478BD642F'u64)
  var second = initRng(2026, 0xA0761D6478BD642F'u64)
  for _ in 0 ..< 1000:
    doAssert first.next() == second.next()

echo "Testing that salts separate streams"
block:
  var map = initRng(2026, 0xA0761D6478BD642F'u64)
  var combat = initRng(2026, 0xE7037ED1A0B428DB'u64)
  var matches = 0
  for _ in 0 ..< 1000:
    if map.next() == combat.next():
      inc matches
  doAssert matches == 0, "salted streams should not coincide"

echo "Testing that nearby seeds diverge immediately"
block:
  var first = initRng(1, 0'u64)
  var second = initRng(2, 0'u64)
  doAssert first.next() != second.next()

echo "Testing below stays in range"
block:
  var rng = initRng(7, 0'u64)
  for bound in [1'i32, 2, 3, 6, 100, 1024, 65537]:
    for _ in 0 ..< 5000:
      let value = rng.below(bound)
      doAssert value >= 0 and value < bound, "below(" & $bound & ") escaped"
  doAssert rng.below(0) == 0
  doAssert rng.below(-5) == 0

echo "Testing below is reasonably uniform"
block:
  var rng = initRng(99, 0'u64)
  var counts: array[6, int]
  for _ in 0 ..< 60_000:
    inc counts[rng.below(6)]
  for count in counts:
    doAssert count > 9000 and count < 11_000, "die roll skewed: " & $counts

echo "Testing between is inclusive on both ends"
block:
  var rng = initRng(5, 0'u64)
  var seen: Table[int32, bool]
  for _ in 0 ..< 5000:
    let value = rng.between(-3, 3)
    doAssert value >= -3 and value <= 3
    seen[value] = true
  for value in -3'i32 .. 3'i32:
    doAssert seen.hasKey(value), "between never produced " & $value
  doAssert rng.between(4, 4) == 4
  doAssert rng.between(9, 2) == 9

echo "Testing state alone restores a stream"
block:
  var rng = initRng(2026, 0'u64)
  for _ in 0 ..< 50:
    discard rng.next()
  var restored = Rng(state: rng.state)
  for _ in 0 ..< 50:
    doAssert rng.next() == restored.next()

echo "Rng tests passed"
