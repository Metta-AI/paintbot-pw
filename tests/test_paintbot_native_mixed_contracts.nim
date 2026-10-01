## Mixed action contracts on one handle (training library only): a policy seat's contract is its manifest's, and
## on a handle set to a wider teams contract it reads the leading logits of its row. Sixteen contract-11 policy
## seats on a contract-13 or contract-14 handle, fed rows whose first 82 logits are X (the rest noise), play tick
## for tick as the same seats on a contract-11 handle fed X (state hash and every seat's choices); contract-11 and
## contract-14 seats share a contract-14 handle; a seat wider than its handle is still an error.
## Build with --mm:arc --threads:on -d:pwTraining.
import std/[unittest, os, random]
import ../examples/paintbot/[sim, neural_contract, native_env]

when not defined(pwTraining): {.error: "the native environment exists only under -d:pwTraining".}

const Root = currentSourcePath().parentDir.parentDir
type Buffer = ptr UncheckedArray[cfloat]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])
template ibuf(a: untyped): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr a[0])
template cbuf(s: string): ptr UncheckedArray[char] = cast[ptr UncheckedArray[char]](unsafeAddr s[0])

const Policy = "paintbot_observe(neuralObservation())\nrun_neural_net(neuralModel(), neuralObservation(), neuralLogits(), neuralState())\nneuralSample()\n"

proc width(contract: int32): int = (case contract
  of 13: 128
  of 14: 174
  else: 82)
proc heads(contract: int32): int = (case contract
  of 13: 7
  of 14: 9
  else: 5)

proc manifest(contract: int32): string =
  let action = case contract
    of 13: ActionContractTeamsView1OffsetHash
    of 14: ActionContractTeamsView1MoveHash
    else: ActionContractTeamsView1Hash
  """{"schema": "paintbot-neural-basic/2", "observation_contract": """" & ObservationContractTeamsView1Hash &
    """", "action_contract": """" & action & """", "decoder": {"sampling": {"mode": "categorical"}}}"""

proc setup(seed: int32, handleContract: int32, seatContract: proc(seat: int): int32): pointer =
  result = pw_create(seed, 2400)
  doAssert result != nil
  if handleContract != 11: doAssert pw_set_action_contract(result, handleContract) == 0
  let pol = Policy & readFile(Root / "examples/paintbot/players/neural_decode.bas")
  for s in 0..<Seats:
    let man = manifest(seatContract(s))
    doAssert pw_set_seat_policy_script(result, s.cint, cbuf(pol), pol.len.int32, cbuf(man), man.len.int32) == 0

proc play(h: pointer, handleContract: int32, ticks: int, extras: bool): seq[uint32] =
  ## Every seat's leading 82 logits come from one stream (seed 5); the columns past 82 from another, so a handle
  ## of any width feeds the same main logits.
  var main = initRand(5)
  var noise = initRand(77)
  let w = width(handleContract)
  var actions = newSeq[int32](LegacySeats*heads(handleContract))
  var logits = newSeq[cfloat](LegacySeats*w)
  var rewards, terminals = newSeq[cfloat](LegacySeats)
  var ch: array[22, int32]
  var extra: array[12, int32]
  for t in 0..<ticks:
    if terminals[0] == 1: break
    for s in 0..<LegacySeats:
      for i in 0..<82: logits[s*w+i] = cfloat(main.gauss(0.0, 1.5))
      for i in 82..<w: logits[s*w+i] = cfloat(noise.gauss(0.0, 1.5))
    let rc = pw_step_logits(h, ibuf(actions), fbuf(logits), fbuf(rewards), fbuf(terminals))
    doAssert rc == 0, $rc
    result.add pw_state_hash(h)
    for s in 0..<LegacySeats:
      doAssert pw_seat_policy_choices(h, s.cint, ibuf(ch)) == 0
      for v in ch: result.add cast[uint32](v)
      if extras:
        doAssert pw_seat_policy_extra_choices(h, s.cint, ibuf(extra)) == 0
        for v in extra: result.add cast[uint32](v)

suite "Mixed action contracts on one handle":
  configureRules(NativeRules)

  test "contract-11 seats on a contract-13 / contract-14 handle play exactly as on a contract-11 handle":
    let a = setup(41, 11, proc(seat: int): int32 = 11)
    let expected = play(a, 11, 900, false)
    pw_destroy(a)
    check expected.len > 900
    for wide in [13'i32, 14'i32]:
      let b = setup(41, wide, proc(seat: int): int32 = 11)
      check play(b, wide, 900, false) == expected
      var extra: array[12, int32]
      for s in 0..<Seats:                               # a seat without extra heads reads as zeros here
        check pw_seat_policy_extra_choices(b, s.cint, ibuf(extra)) == 0 and extra == default(array[12, int32])
      pw_destroy(b)

  test "contract-11, 13 and 14 seats share a contract-14 handle; the run is deterministic":
    proc mix(seat: int): int32 = [11'i32, 14'i32, 13'i32, 14'i32][seat mod 4]
    let a = setup(43, 14, mix)
    let first = play(a, 14, 600, true)
    var extra: array[12, int32]
    var movedOffsets = 0
    for s in 0..<Seats:
      check pw_seat_policy_extra_choices(a, s.cint, ibuf(extra)) == 0
      if mix(s) == 11: check extra == default(array[12, int32])
      if mix(s) == 13: check extra[2] == 0 and extra[3] == 0   # no movement-offset heads
      if mix(s) == 14 and (extra[2] != 0 or extra[3] != 0): inc movedOffsets
    check movedOffsets > 0
    pw_destroy(a)
    let b = setup(43, 14, mix)
    check play(b, 14, 600, true) == first
    pw_destroy(b)

  test "a contract-11 seat's narrow handle is unchanged; a seat wider than its handle is refused at the step":
    let a = setup(45, 11, proc(seat: int): int32 = 11)
    var extra: array[12, int32]
    check pw_seat_policy_extra_choices(a, 0, ibuf(extra)) == -1     # as before on a contract-11 handle
    pw_destroy(a)
    let b = setup(45, 11, proc(seat: int): int32 = (if seat == 3: 14 else: 11))
    var actions = newSeq[int32](LegacySeats*5)
    var logits = newSeq[cfloat](LegacySeats*82)
    var rewards, terminals = newSeq[cfloat](LegacySeats)
    check pw_step_logits(b, ibuf(actions), fbuf(logits), fbuf(rewards), fbuf(terminals)) != 0
    pw_destroy(b)
