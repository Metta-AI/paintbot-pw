## Training-library world snapshots (pw_world_save / pw_world_load in native_env.nim): a deterministic binary
## codec over plain Nim values. Integers and enums are written little-endian at a fixed width, floats as their raw
## bits, strings and seqs length-prefixed, arrays and objects field by field in declaration order (fieldPairs, which
## also visits private fields), Options and refs with a presence byte. Closures, pointers and the types a snapshot
## restores by other means (the BASIC runtime and string pool, compiled programs, network actors, the per-tick seat
## view) are skipped: the caller handles them. Equal values encode to equal bytes on every machine.
when not defined(pwTraining): {.error: "snapshot.nim is part of the training library only (-d:pwTraining)".}

import std/[options, typetraits]
import bassy
import seat_view, neural_actor

type
  SnapWriter* = object
    data*: seq[byte]
  SnapReader* = object
    data*: seq[byte]
    at*: int
  SnapError* = object of ValueError

proc fail*(r: SnapReader, what: string) {.noreturn.} =
  raise newException(SnapError, "world snapshot: " & what & " at byte " & $r.at)

proc putU64*(w: var SnapWriter, v: uint64) =
  for i in 0..7: w.data.add byte((v shr (8*i)) and 0xff)
proc getU64*(r: var SnapReader): uint64 =
  if r.at + 8 > r.data.len: r.fail("truncated")
  for i in 0..7: result = result or (uint64(r.data[r.at+i]) shl (8*i))
  r.at += 8
proc putBytes*(w: var SnapWriter, b: openArray[byte]) =
  w.putU64(b.len.uint64)
  for x in b: w.data.add x
proc getBytes*(r: var SnapReader): seq[byte] =
  let n = r.getU64()
  if n > uint64(r.data.len - r.at): r.fail("bad length")
  result = r.data[r.at ..< r.at + n.int]
  r.at += n.int

proc skipped(T: typedesc): bool {.compileTime.} =
  ## Types the codec does not walk: restored by other means or rebuilt (see the module doc).
  T is Runtime or T is StringPool or T is Program or T is Actor or T is SeatView or T is proc or T is ptr or
    T is pointer

proc put*[T](w: var SnapWriter, x: T) =
  when skipped(T):
    discard
  elif T is Value:
    w.putU64(uint64(ord(x.kind)))
    case x.kind
    of IntegerValue:
      w.putU64(cast[uint32](x.asInt).uint64)
    of FixedValue:
      w.putU64(cast[uint32](x.asFixed).uint64)
    of StringValue:
      w.putU64(x.stringOwner.uint64)
      w.putU64(cast[uint32](x.stringHandle).uint64)
    of ArrayValue, BlobValue:
      w.putU64(x.bufferOwner.uint64)
      w.putU64(cast[uint32](x.bufferSlot).uint64)
  elif T is bool:
    w.putU64(uint64(ord(x)))
  elif T is enum:
    # raw bits: a zero-initialized field of an enum whose values start above 0 holds a value outside the enum, and
    # a snapshot reproduces it as it is
    var raw = 0'u64
    copyMem(addr raw, unsafeAddr x, sizeof(T))
    w.putU64(raw)
  elif T is char:
    w.putU64(uint64(ord(x)))
  elif T is SomeSignedInt:
    w.putU64(cast[uint64](int64(x)))
  elif T is SomeUnsignedInt:
    w.putU64(uint64(x))
  elif T is float32:
    w.putU64(uint64(cast[uint32](x)))
  elif T is float64 or T is float:
    w.putU64(cast[uint64](x))
  elif T is string:
    w.putU64(x.len.uint64)
    for c in x: w.data.add byte(c)
  elif T is seq:
    w.putU64(x.len.uint64)
    for e in x: w.put(e)
  elif T is array:
    for e in x: w.put(e)
  elif T is set:
    var n = 0'u64
    for e in x: inc n
    w.putU64(n)
    for e in x: w.put(e)
  elif T is Option:
    w.putU64(uint64(ord(x.isSome)))
    if x.isSome: w.put(x.get)
  elif T is ref:
    w.putU64(uint64(ord(not x.isNil)))
    if not x.isNil: w.put(x[])
  elif T is tuple or T is object:
    for _, f in fieldPairs(x): w.put(f)
  elif T is distinct:
    w.put(distinctBase(T)(x))
  else:
    {.error: "snapshot: no encoding for " & $T.}

proc get*[T](r: var SnapReader, x: var T) =
  when skipped(T):
    discard
  elif T is Value:
    let kind = r.getU64()
    if kind > uint64(ord(high(ValueKind))):
      r.fail("bad BASIC value kind")
    case ValueKind(kind)
    of IntegerValue:
      x = toValue(cast[int32](uint32(r.getU64())))
    of FixedValue:
      x = toValue(cast[Fixed](uint32(r.getU64())))
    of StringValue:
      let owner = uint32(r.getU64())
      x = stringValue(owner, cast[int32](uint32(r.getU64())))
    of ArrayValue, BlobValue:
      let owner = uint32(r.getU64())
      x = bufferValue(
        ValueKind(kind), owner, cast[int32](uint32(r.getU64()))
      )
  elif T is bool:
    x = r.getU64() != 0
  elif T is enum:
    var raw = r.getU64()
    copyMem(addr x, addr raw, sizeof(T))
  elif T is char:
    x = char(r.getU64() and 0xff)
  elif T is SomeSignedInt:
    x = T(cast[int64](r.getU64()))
  elif T is SomeUnsignedInt:
    x = T(r.getU64())
  elif T is float32:
    x = cast[float32](uint32(r.getU64() and 0xffffffff'u64))
  elif T is float64 or T is float:
    x = cast[float64](r.getU64())
  elif T is string:
    let n = r.getU64()
    if n > uint64(r.data.len - r.at): r.fail("bad string length")
    x = newString(n.int)
    for i in 0..<n.int: x[i] = char(r.data[r.at+i])
    r.at += n.int
  elif T is seq:
    let n = r.getU64()
    if n > uint64(r.data.len - r.at): r.fail("bad seq length")   # every element takes >= 1 byte or is skipped
    x.setLen(n.int)
    for i in 0..<n.int: r.get(x[i])
  elif T is array:
    for i in low(x)..high(x): r.get(x[i])
  elif T is set:
    let n = r.getU64()
    if n > uint64(r.data.len - r.at): r.fail("bad set length")
    x = {}
    for i in 0..<n.int:
      var e: elementType(x)
      r.get(e); x.incl e
  elif T is Option:
    if r.getU64() != 0:
      var v: typeof(x.get)
      r.get(v); x = some(v)
    else:
      x = none(typeof(x.get))
  elif T is ref:
    if r.getU64() != 0:
      if x.isNil: new(x)
      r.get(x[])
    else:
      x = nil
  elif T is tuple or T is object:
    for _, f in fieldPairs(x): r.get(f)
  elif T is distinct:
    var b: distinctBase(T)
    r.get(b); x = T(b)
  else:
    {.error: "snapshot: no decoding for " & $T.}
