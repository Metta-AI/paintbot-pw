## pw_world_save / pw_world_load (training library only): a match saved at tick t and loaded into a fresh handle
## continues exactly as the original does (every pw_state_hash, every scripted seat's orders, every policy seat's
## choices and the seats' telemetry, for K ticks), across scripted, caller-driven, policy (contract 14) and FFA-kin
## matches; saves are deterministic and save -> load -> save is byte-identical; refusals leave the handle unchanged.
## Build with --mm:arc --threads:on -d:pwTraining.
import std/[unittest, os, random]
import ../examples/paintbot/[sim, neural_contract, native_env]

when not defined(pwTraining): {.error: "world snapshots exist only under -d:pwTraining".}

const Root = currentSourcePath().parentDir.parentDir
const Base = Root / "coworld/paintbot/players/base.bas"
type Buffer = ptr UncheckedArray[cfloat]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])
template ibuf(a: untyped): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr a[0])
template cbuf(s: string): ptr UncheckedArray[char] = cast[ptr UncheckedArray[char]](unsafeAddr s[0])

proc save(h: pointer): seq[byte] =
  let n = pw_world_save(h, nil, 0)
  doAssert n > 0
  result = newSeq[byte](n)
  doAssert pw_world_save(h, cast[ptr UncheckedArray[byte]](addr result[0]), n) == n

proc load(h: pointer, b: seq[byte]): cint =
  pw_world_load(h, cast[ptr UncheckedArray[byte]](unsafeAddr b[0]), b.len.int64)

type Kind = enum kScripted, kCaller, kPolicy

proc manifest14(): string =
  """{"schema": "paintbot-neural-basic/2", "observation_contract": """" & ObservationContractTeamsView1Hash &
    """", "action_contract": """" & ActionContractTeamsView1MoveHash & """", "decoder": {"sampling": {"mode": "categorical"}}}"""

proc setup(kind: Kind, seed, ticks: int32): pointer =
  result = pw_create(seed, ticks)
  doAssert result != nil
  let base = readFile(Base)
  case kind
  of kScripted:
    for s in 0..<Seats: doAssert pw_set_seat_script(result, s.cint, cbuf(base), base.len.int32) == 0
  of kCaller: discard
  of kPolicy:
    doAssert pw_set_action_contract(result, 14) == 0
    let pol = "paintbot_observe(neuralObservation())\nrun_neural_net(neuralModel(), neuralObservation(), neuralLogits(), neuralState())\nneuralSample()\n" &
      readFile(Root / "examples/paintbot/players/neural_decode.bas")
    let man = manifest14()
    for s in 0..<Seats:
      if s mod 2 == 0:
        doAssert pw_set_seat_policy_script(result, s.cint, cbuf(pol), pol.len.int32, cbuf(man), man.len.int32) == 0
      else:
        doAssert pw_set_seat_script(result, s.cint, cbuf(base), base.len.int32) == 0

proc play(h: pointer, kind: Kind, ticks: int, rngSeed: int): seq[uint32] =
  ## Records per tick: the state hash, every seat's orders and (policy) choices, and the stats at the end.
  var r = initRand(rngSeed)
  let heads = if kind == kPolicy: 9 else: 5
  var actions = newSeq[int32](LegacySeats*heads)
  var logits = newSeq[cfloat](LegacySeats*174)
  var rewards, terminals = newSeq[cfloat](LegacySeats)
  var orders: array[10, int32]
  var ch: array[22, int32]
  var extra: array[12, int32]
  for t in 0..<ticks:
    if terminals[0] == 1: break
    var rc: cint
    case kind
    of kScripted: rc = pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals))
    of kCaller:
      for s in 0..<LegacySeats:
        for k, n in ActionSizes: actions[s*5+k] = int32(r.rand(n-1))
      rc = pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals))
    of kPolicy:
      for i in 0..<logits.len: logits[i] = cfloat(r.gauss(0.0, 1.5))
      rc = pw_step_logits(h, ibuf(actions), fbuf(logits), fbuf(rewards), fbuf(terminals))
    doAssert rc == 0, $rc
    result.add pw_state_hash(h)
    for s in 0..<LegacySeats:
      if pw_seat_orders(h, s.cint, ibuf(orders)) == 0:
        for v in orders: result.add cast[uint32](v)
      if kind == kPolicy and s mod 2 == 0:
        doAssert pw_seat_policy_choices(h, s.cint, ibuf(ch)) == 0
        doAssert pw_seat_policy_extra_choices(h, s.cint, ibuf(extra)) == 0
        for v in ch: result.add cast[uint32](v)
        for v in extra: result.add cast[uint32](v)
  var stats: array[LegacySeats*8, int32]
  doAssert pw_seat_stats(h, ibuf(stats)) == 0
  for v in stats: result.add cast[uint32](v)

suite "World snapshots":
  configureRules(NativeRules)

  for kind in [kScripted, kCaller, kPolicy]:
    for t in [1, 137, 600]:
      test "save at tick " & $t & ", load into a fresh handle: the next 300 ticks are identical (" & $kind & ")":
        let a = setup(kind, 51, 2400)
        defer: pw_destroy(a)
        discard a.play(kind, t, 7)
        let blob = save(a)
        check save(a) == blob                       # deterministic, and a save is a pure read
        let expected = a.play(kind, 300, 99)
        let b = setup(kCaller, 52, 2400)            # another seed, no scripts: the blob brings everything
        defer: pw_destroy(b)
        if kind == kPolicy: check pw_set_action_contract(b, 14) == 0
        check load(b, blob) == 0
        check save(b) == blob                       # save -> load -> save
        check b.play(kind, 300, 99) == expected

  test "FFA-kin (ffa.bas seats on an ffa.view.1 handle): save mid-match, load, identical continuation":
    let ffaSrc = readFile(Root / "coworld/paintbot/players/ffa.bas")
    proc ffaHandle(seed: int32): pointer =
      result = pw_create_observation(seed, 2400, 202)
      doAssert result != nil
      for s in 0..<Seats: doAssert pw_set_seat_script(result, s.cint, cbuf(ffaSrc), ffaSrc.len.int32) == 0
    let a = ffaHandle(61)
    defer: pw_destroy(a)
    discard a.play(kScripted, 250, 3)
    let blob = save(a)
    let expected = a.play(kScripted, 300, 4)
    let b = pw_create_observation(62, 2400, 202)
    require b != nil
    defer: pw_destroy(b)
    check load(b, blob) == 0
    check b.play(kScripted, 300, 4) == expected

  test "refusals: another observation version, a bad magic, a truncated or corrupt blob; the handle is unchanged":
    let a = setup(kScripted, 71, 2400)
    defer: pw_destroy(a)
    discard a.play(kScripted, 50, 1)
    let blob = save(a)
    let ffa = pw_create_observation(71, 2400, 202)
    require ffa != nil
    defer: pw_destroy(ffa)
    check load(ffa, blob) == -2
    let b = setup(kScripted, 72, 2400)
    defer: pw_destroy(b)
    discard b.play(kScripted, 20, 2)
    let before = save(b)
    var bad = blob
    bad[0] = byte('X')
    check load(b, bad) == -2
    check load(b, blob[0 ..< blob.len div 2]) == -3
    check save(b) == before                       # refused twice: unchanged
    var corrupt = blob
    for i in (blob.len div 3) ..< (blob.len div 3 + 64): corrupt[i] = 0xff
    let rc = load(b, corrupt)
    check rc in [-3'i32, 0'i32]                   # a corrupt payload is refused, or decodes to some valid state
    if rc == -3:
      check save(b) == before                     # refused: unchanged
    check pw_world_load(nil, nil, 0) == -1
    check pw_world_save(nil, nil, 0) == -1
