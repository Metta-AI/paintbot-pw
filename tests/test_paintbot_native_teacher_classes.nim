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

  test "arguments":
    let h = pw_create(1, 100)
    var cmd: array[10, int32]
    var out1: array[TeacherClassBytes, uint8]
    check pw_teacher_classes(nil, 0, ibuf(cmd), ubuf(out1), TeacherClassBytes.cint) == -1
    check pw_teacher_classes(h, 16, ibuf(cmd), ubuf(out1), TeacherClassBytes.cint) == -1
    check pw_teacher_classes(h, 0, ibuf(cmd), ubuf(out1), (TeacherClassBytes-1).cint) == -1
    check pw_teacher_classes(h, 0, nil, ubuf(out1), TeacherClassBytes.cint) == -1
    pw_destroy(h)
