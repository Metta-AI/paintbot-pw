## Field walking must not depend on padding or pointer width.

import polyworld/hashes

type
  Point = object
    x: int32
    y: int32

  Box = object
    origin: Point
    size: int32
    flags: bool

  Kind = enum
    RedKind, BlueKind

echo "Testing integers mix both halves"
block:
  var a, b = HashySeed
  a.addHashy(1'u64)
  b.addHashy(1'u32)
  doAssert a != b, "uint64 must not truncate to the low half"
  var low, high = HashySeed
  low.addHashy(1'u64)
  high.addHashy(1'u64 shl 32)
  doAssert low != high, "the high half must participate"

echo "Testing int widens to int64"
block:
  var asInt, asInt64 = HashySeed
  asInt.addHashy(1.int)
  asInt64.addHashy(1'i64)
  doAssert asInt == asInt64, "int must hash as int64"

echo "Testing uint widens to uint64"
block:
  var asUint, asUint64 = HashySeed
  asUint.addHashy(1.uint)
  asUint64.addHashy(1'u64)
  doAssert asUint == asUint64, "uint must hash as uint64"

echo "Testing strings mix length then bytes"
block:
  var expected = HashySeed
  expected.addHashy(3'i32)
  expected.addHashy(uint8(ord('a')))
  expected.addHashy(uint8(ord('b')))
  expected.addHashy(uint8(ord('c')))
  doAssert hashy("abc") == expected
  doAssert hashy("ab") != hashy("abc")
  doAssert hashy("ba") != hashy("ab")

echo "Testing sequences mix length then elements"
block:
  var expected = HashySeed
  expected.addHashy(2'i32)
  expected.addHashy(1'i32)
  expected.addHashy(2'i32)
  doAssert hashy(@[1'i32, 2'i32]) == expected
  doAssert hashy(@[1'i32]) != hashy(@[1'i32, 0'i32])

echo "Testing objects walk fields, not packed memory"
block:
  var expected = HashySeed
  expected.addHashy(3'i32)
  expected.addHashy(4'i32)
  expected.addHashy(5'i32)
  expected.addHashy(true)
  doAssert hashy(Box(
    origin: Point(x: 3, y: 4),
    size: 5,
    flags: true
  )) == expected

echo "Testing nested sequences of objects"
block:
  let kids = @[Point(x: 1, y: 2), Point(x: 3, y: 4)]
  var expected = HashySeed
  expected.addHashy(kids)
  doAssert hashy(kids) == expected
  doAssert hashy(@[Point(x: 1, y: 2)]) != hashy(@[Point(x: 2, y: 1)])

echo "Testing enums mix as their ordinal"
block:
  doAssert hashy(RedKind) != hashy(BlueKind)

echo "Testing empty values"
block:
  doAssert hashy("") != HashySeed
  doAssert hashy(newSeq[int32]()) != hashy(@[0'i32])

echo "Hash tests passed"
