## Public synthetic checkpoint regressions; training backend only.
import std/[unittest, json, strutils]
import ../examples/paintbot/[native_env, contract_hash]

const Source = """
TYPE Memo
  text AS STRING
END TYPE
DIM memo AS Memo
memo.text = memo.text + "x"
x = x + rnd(100)
walkTo(selfX + x, selfY)
"""
proc save(h: pointer): seq[byte] =
  let n = pw_world_save(h, nil, 0)
  doAssert n > 0
  result = newSeq[byte](n)
  doAssert pw_world_save(h, cast[ptr UncheckedArray[byte]](addr result[0]), n) == n
proc load(h: pointer, b: seq[byte]): cint =
  pw_world_load(h, cast[ptr UncheckedArray[byte]](unsafeAddr b[0]), b.len.int64)
proc step(h: pointer) =
  var a: array[80, int32]
  var r, t: array[16, cfloat]
  doAssert pw_step(h, cast[ptr UncheckedArray[int32]](addr a[0]),
    cast[ptr UncheckedArray[cfloat]](addr r[0]), cast[ptr UncheckedArray[cfloat]](addr t[0])) == 0
proc status(h: pointer): string =
  let n = pw_debug_status_json(h, nil, 0)
  doAssert n > 0
  result = newString(n)
  doAssert pw_debug_status_json(h, cast[ptr UncheckedArray[char]](addr result[0]), n) == n
proc trace(h: pointer): string =
  let n = pw_debug_trace_json(h, nil, 0)
  doAssert n > 0
  result = newString(n)
  doAssert pw_debug_trace_json(h, cast[ptr UncheckedArray[char]](addr result[0]), n) == n
proc scripted(): pointer =
  result = pw_create(71, 600)
  let source = Source
  for s in 0..<16:
    doAssert pw_set_seat_script(result, s.cint,
      cast[ptr UncheckedArray[char]](unsafeAddr source[0]), source.len.int32) == 0

suite "owned BASIC checkpoints":
  test "string generations and RNG continue with identical snapshot bytes":
    let a = scripted()
    let b = pw_create(72, 600)
    defer: pw_destroy(a); pw_destroy(b)
    step(a)
    let checkpoint = save(a)
    check load(b, checkpoint) == 0
    check save(b) == checkpoint
    for t in 0..<4:
      step(a); step(b)
      check pw_state_hash(a) == pw_state_hash(b)
      check parseJson(status(a))["controller_sha256"] == parseJson(status(b))["controller_sha256"]
      let equal = save(a) == save(b)
      check equal

  test "successful load clears trace but keeps destination tracing; refusals preserve it":
    let a = scripted()
    let b = scripted()
    defer: pw_destroy(a); pw_destroy(b)
    step(a)
    let checkpoint = save(a)
    check pw_debug_set_trace(b, 1) == 0
    step(b)
    check pw_debug_trace_json(b, nil, 0) > 0
    let before = save(b)
    let beforeStatus = status(b)
    let beforeTrace = trace(b)
    for position in [0, 40, checkpoint.len div 2, checkpoint.len - 1]:
      var bad = checkpoint
      bad[position] = bad[position] xor 1
      check load(b, bad) < 0
      let unchanged = save(b) == before
      check unchanged
      check status(b) == beforeStatus
      check trace(b) == beforeTrace
    # A valid checksum but invalid source exercises the late rebuild refusal, not only
    # the early checksum guard. Restore must remain transactional here too.
    var text = newString(checkpoint.len)
    copyMem(addr text[0], unsafeAddr checkpoint[0], checkpoint.len)
    let at = text.find(Source)
    require at >= 0
    text[at] = '@'
    let digest = sha256Hex(text[0 ..< text.len - 72])
    for i, c in digest: text[text.len - 64 + i] = c
    var late = newSeq[byte](text.len)
    copyMem(addr late[0], unsafeAddr text[0], text.len)
    check load(b, late) == -3
    let lateUnchanged = save(b) == before
    check lateUnchanged
    check status(b) == beforeStatus
    check trace(b) == beforeTrace
    check load(b, checkpoint) == 0
    check parseJson(status(b))["trace_enabled"].getBool
    check pw_debug_trace_json(b, nil, 0) == -2
    let equal = save(b) == checkpoint
    check equal
