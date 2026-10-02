## pw_teacher_classes / pw_teacher_classes_exact (training library only): the fast teacher class masks equal
## the reference's
## (every bin decoded by the reference decoder script, every predicate tested bin by bin) on scripted
## matches, sampled seat-ticks across rules 48 island and generated maps; the call changes nothing
## (hashes identical to a match that never calls it); every mask is well formed.
## Build with --mm:arc --threads:on -d:pwTraining.
import std/[unittest, os]
import ../examples/paintbot/[sim, neural_contract, native_env, teacher_classes]

when not defined(pwTraining): {.error: "teacher class masks exist only in the training library".}

const Root = currentSourcePath().parentDir.parentDir
const Base = Root / "coworld/paintbot/players/base.bas"
type Buffer = ptr UncheckedArray[cfloat]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])
template ibuf(a: untyped): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr a[0])
template ubuf(a: untyped): ptr UncheckedArray[uint8] = cast[ptr UncheckedArray[uint8]](addr a[0])

proc scripted(seed: int32, map: int32, source: string): pointer =
  result = pw_create(seed, 14400)
  doAssert pw_set_rules(result, 48) == 0
  doAssert pw_set_map(result, map) == 0
  doAssert pw_reset(result, seed, 14400) == 0
  for slot in 0..<Seats:
    doAssert pw_set_seat_script(result, slot.cint, cast[ptr UncheckedArray[char]](unsafeAddr source[0]),
      source.len.int32) == 0

suite "Teacher class masks":
  let source = readFile(Base)

  test "fast masks equal the reference decoder's, and the call changes nothing":
    var compared, orders = 0
    for (seed, map) in [(61'i32, -1'i32), (62'i32, 3'i32)]:
      checkpoint "seed " & $seed & " map " & $map
      let plain = scripted(seed, map, source)
      let probed = scripted(seed, map, source)
      var actions: array[LegacySeats*ActionSizes.len, int32]
      var rewards, terminals: array[LegacySeats, float32]
      for tick in 0..<600:
        if tick mod 150 == 149:
          doAssert pw_script_decide(probed) >= 0
          for seat in [tick mod 16, (tick+5) mod 16]:
            var cmd: array[10, int32]
            doAssert pw_seat_orders(probed, seat.cint, ibuf(cmd)) == 0
            var fast, slow: array[TeacherClassBytes, uint8]
            let r = pw_teacher_classes(probed, seat.cint, ibuf(cmd), ubuf(fast), TeacherClassBytes.cint)
            if r == -2: continue
            check r == TeacherClassBytes
            check pw_teacher_classes_reference(probed, seat.cint, ibuf(cmd), ubuf(slow), TeacherClassBytes.cint, 0) == TeacherClassBytes
            check fast == slow
            # The exact walk class: fast-exact equals its reference, and contains every bin of the default.
            var exact, exactRef: array[TeacherClassBytes, uint8]
            check pw_teacher_classes_exact(probed, seat.cint, ibuf(cmd), ubuf(exact), TeacherClassBytes.cint) == TeacherClassBytes
            check pw_teacher_classes_reference(probed, seat.cint, ibuf(cmd), ubuf(exactRef), TeacherClassBytes.cint, 1) == TeacherClassBytes
            check exact == exactRef
            for i in 0..<TeacherClassBytes: check (fast[i] and not exact[i]) == 0
            check fast[TcFireAt] in [1'u8, 2] and fast[TcGrenadeAt] in [1'u8, 2] and fast[TcSneakAt] in [1'u8, 2]
            inc compared
            if cmd[3] != 0: inc orders
        doAssert pw_step(plain, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
        doAssert pw_step(probed, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
        check pw_state_hash(plain) == pw_state_hash(probed)
        if terminals[0] == 1: break
      pw_destroy(plain); pw_destroy(probed)
    check compared >= 4

  test "in-step masks equal the call on the same pre-step world (shadow teachers, both walk modes)":
    var compared = 0
    let a = scripted(71, 4, source)
    let b = scripted(71, 4, source)
    for h in [a, b]:
      for seat in [1'i32, 5, 9]:
        doAssert pw_set_seat_shadow_script(h, seat.cint, cast[ptr UncheckedArray[char]](unsafeAddr source[0]),
          source.len.int32) == 0
    var actions: array[LegacySeats*ActionSizes.len, int32]
    var rewards, terminals: array[LegacySeats, float32]
    for tick in 0..<240:
      let exact = if tick mod 60 == 59: 0x2'u32 else: 0'u32
      check pw_set_teacher_classes(a, 0xAAAA'u32, exact) == 0
      doAssert pw_script_decide(b) >= 0
      var want: array[16, array[TeacherClassBytes, uint8]]
      var have: array[16, bool]
      for seat in countup(1, 15, 2):
        var cmd: array[10, int32]
        doAssert pw_seat_decided_orders(b, seat.cint, ibuf(cmd)) == 0
        if cmd[9] != 2: doAssert pw_seat_orders(b, seat.cint, ibuf(cmd)) == 0
        let r = if (exact and (1'u32 shl seat)) != 0: pw_teacher_classes_exact(b, seat.cint, ibuf(cmd), ubuf(want[seat]), TeacherClassBytes.cint)
                else: pw_teacher_classes(b, seat.cint, ibuf(cmd), ubuf(want[seat]), TeacherClassBytes.cint)
        have[seat] = r == TeacherClassBytes
      doAssert pw_step(a, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
      doAssert pw_step(b, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
      check pw_state_hash(a) == pw_state_hash(b)
      for seat in countup(1, 15, 2):
        if not have[seat]: continue
        var got: array[TeacherClassBytes, uint8]
        check pw_teacher_classes_last(a, seat.cint, ubuf(got), TeacherClassBytes.cint) == TeacherClassBytes
        check got == want[seat]
        inc compared
      if terminals[0] == 1: break
    check compared > 100
    pw_destroy(a); pw_destroy(b)

  test "arguments":
    let h = pw_create(1, 100)
    var cmd: array[10, int32]
    var out1: array[TeacherClassBytes, uint8]
    check pw_teacher_classes(nil, 0, ibuf(cmd), ubuf(out1), TeacherClassBytes.cint) == -1
    check pw_teacher_classes(h, 16, ibuf(cmd), ubuf(out1), TeacherClassBytes.cint) == -1
    check pw_teacher_classes(h, 0, ibuf(cmd), ubuf(out1), (TeacherClassBytes-1).cint) == -1
    check pw_teacher_classes(h, 0, nil, ubuf(out1), TeacherClassBytes.cint) == -1
    pw_destroy(h)
