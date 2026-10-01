## Action contract teams.view.1 target-conditioned aim offset (15,
## paintbot-pw.teams.view.1.action.51-25-2-2-2-23x16-23x16): contract 13's seven heads and decode, but heads 5 and 6
## carry one 23-logit row per identity (818 logits per seat) and are drawn from the row of the identity the aim head
## chose; keep or a compass aim draws nothing (the centre bin, applied temperature 0). Through the native ABI:
## pw_set_action_contract(15), pw_action_layout_ext, and policy seats fed 818-wide rows (pw_step_logits,
## pw_seat_policy_extra_choices). Build with --mm:arc --threads:on -d:pwTraining.
import std/[unittest, os, random]
import ../examples/paintbot/[sim, neural_contract, native_env]

when not defined(pwTraining): {.error: "the native ABI exists only under -d:pwTraining".}

const Root = currentSourcePath().parentDir.parentDir
type Buffer = ptr UncheckedArray[cfloat]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])
template ibuf(a: untyped): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr a[0])
template cbuf(s: string): ptr UncheckedArray[char] = cast[ptr UncheckedArray[char]](unsafeAddr s[0])

proc manifestFor(action: string): string =
  """{"schema": "paintbot-neural-basic/2", "observation_contract": """" & ObservationContractTeamsView1Hash &
    """", "action_contract": """" & action & """", "decoder": {"sampling": {"mode": "categorical"}}}"""

let policy = "paintbot_observe(neuralObservation())\n" &
  "run_neural_net(neuralModel(), neuralObservation(), neuralLogits(), neuralState())\n" &
  "neuralSample()\n" & readFile(Root / "examples/paintbot/players/neural_decode.bas")
let base = readFile(Root / "coworld/paintbot/players/base.bas")

const RowBase5 = LogitSize                       # head 5's identity rows
const RowBase6 = LogitSize + TargetRows*23       # head 6's identity rows

proc seatHandle(seed: int32, contract: int32, action: string): pointer =
  ## Even seats: policy seats under `action`; odd seats: base.bas.
  result = pw_create(seed, 2400)
  doAssert result != nil
  doAssert pw_set_action_contract(result, contract) == 0
  let manifest = manifestFor(action)
  for s in 0..<Seats:
    if s mod 2 == 0:
      doAssert pw_set_seat_policy_script(result, s.cint, cbuf(policy), policy.len.int32, cbuf(manifest),
        manifest.len.int32) == 0
    else:
      doAssert pw_set_seat_script(result, s.cint, cbuf(base), base.len.int32) == 0

suite "Action contract teams.view.1 target-conditioned aim offset (15)":
  configureRules(NativeRules)

  test "id, hash, version, sizes and pairing":
    check actionContractVersion(ActionContractTeamsView1TargetHash) == acTeamsView1Target
    check actionContractId(acTeamsView1Target) == "paintbot-pw.teams.view.1.action.51-25-2-2-2-23x16-23x16"
    check actionHeadSizes(acTeamsView1Target) == @[51, 25, 2, 2, 2, 23, 23]
    check actionLogitSize(acTeamsView1Target) == 818 and LogitSizeTarget == 818
    check actionLogitHeads(acTeamsView1Target) == @[51, 25, 2, 2, 2, 368, 368]
    check extraHeads(acTeamsView1Target) == 2 and targetRows(acTeamsView1Target)
    check pairs(ocTeamsView1, acTeamsView1Target) and not pairs(ocFfaView1, acTeamsView1Target)
    for c in [acTeamsView1, acTeamsView1Offset, acTeamsView1Move]:
      check not targetRows(c)
      var sum = 0
      for x in actionHeadSizes(c): sum += x
      check actionLogitSize(c) == sum

  test "pw_set_action_contract(15), pw_action_layout_ext and the contract hash":
    let h = pw_create(1, 600)
    require h != nil
    defer: pw_destroy(h)
    check pw_set_action_contract(h, 15) == 0
    var ten: array[10, int32]
    check pw_action_layout_ext(h, ibuf(ten)) == 0
    check ten == [7'i32, 51, 25, 2, 2, 2, 23, 23, 818, 0]
    var hex: array[65, char]
    check pw_action_contract_hash(15, cast[ptr UncheckedArray[char]](addr hex[0]), 65) == 0
    check $cast[cstring](addr hex[0]) == ActionContractTeamsView1TargetHash
    let ffa = pw_create_observation(1, 600, 202)
    require ffa != nil
    defer: pw_destroy(ffa)
    check pw_set_action_contract(ffa, 15) == -1

  test "heads 5 and 6 are drawn from the chosen identity's row; keep and compass aims draw nothing":
    let h = seatHandle(5, 15, ActionContractTeamsView1TargetHash)
    defer: pw_destroy(h)
    var actions = newSeq[int32](Seats*7)
    var logits = newSeq[cfloat](Seats*818)
    var rewards, terminals = newSeq[cfloat](Seats)
    var extra: array[12, int32]
    var identities, targetless = 0
    for step in 0..<90:
      if terminals[0] == 1: break
      let a = step mod 26                  # 0 keep, 1..16 identity a - 1, 17..25 compass (only 17..24 exist)
      let aim = min(a, 24)
      for i in 0..<logits.len: logits[i] = 0
      for s in countup(0, Seats-1, 2):
        let row = s*818
        logits[row + 51 + aim] = 50        # the aim head picks `aim`
        for j in 0..<TargetRows:
          logits[row + RowBase5 + j*23 + (j*3 + 1) mod 23] = 50
          logits[row + RowBase6 + j*23 + (j*5 + 2) mod 23] = 50
      check pw_step_logits(h, ibuf(actions), fbuf(logits), fbuf(rewards), fbuf(terminals)) == 0
      for s in countup(0, Seats-1, 2):
        check pw_seat_policy_extra_choices(h, s.cint, ibuf(extra)) == 0
        var ch: array[22, int32]
        check pw_seat_policy_choices(h, s.cint, ibuf(ch)) == 0
        if ch[0] != 1: continue           # the seat did not select this tick (dead)
        let chosen = ch[2]                # the aim head's draw (a mask may move it off `aim`)
        if chosen in 1'i32..16'i32:
          let j = chosen.int - 1
          check extra[0] == ((j*3 + 1) mod 23).int32 and extra[1] == ((j*5 + 2) mod 23).int32
          check extra[4] == extra[0] and extra[5] == extra[1]
          check extra[8] > 0 and extra[9] > 0
          inc identities
        else:
          check extra[0] == 11 and extra[1] == 11 and extra[8] == 0 and extra[9] == 0
          inc targetless
    check identities > 100 and targetless > 20

  test "with every row equal to contract 13's offset logits and an identity aim, 15 plays exactly as 13":
    var r = initRand(17)
    var hashes, bins: array[2, seq[int32]]
    var feed = newSeq[seq[cfloat]](200)
    for t in 0..<200:
      feed[t] = newSeq[cfloat](Seats*128)
      for i in 0..<feed[t].len: feed[t][i] = cfloat(r.gauss(0.0, 1.5))
      for s in 0..<Seats:
        feed[t][s*128 + 51] = -50          # never keep
        for c in 17..24: feed[t][s*128 + 51 + c] = -50   # never a compass point
    for k, (contract, width, action) in [(13'i32, 128, ActionContractTeamsView1OffsetHash),
                                         (15'i32, 818, ActionContractTeamsView1TargetHash)]:
      let h = seatHandle(23, contract, action)
      defer: pw_destroy(h)
      var actions = newSeq[int32](Seats*7)
      var logits = newSeq[cfloat](Seats*width)
      var rewards, terminals = newSeq[cfloat](Seats)
      var extra: array[12, int32]
      for t in 0..<200:
        if terminals[0] == 1: break
        for s in 0..<Seats:
          for i in 0..<82: logits[s*width + i] = feed[t][s*128 + i]
          if width == 128:
            for i in 82..<128: logits[s*width + i] = feed[t][s*128 + i]
          else:
            for j in 0..<TargetRows:
              for b in 0..<23:
                logits[s*width + RowBase5 + j*23 + b] = feed[t][s*128 + 82 + b]
                logits[s*width + RowBase6 + j*23 + b] = feed[t][s*128 + 105 + b]
        check pw_step_logits(h, ibuf(actions), fbuf(logits), fbuf(rewards), fbuf(terminals)) == 0
        hashes[k].add cast[int32](pw_state_hash(h))
        for s in countup(0, Seats-1, 2):
          check pw_seat_policy_extra_choices(h, s.cint, ibuf(extra)) == 0
          var ch: array[22, int32]
          check pw_seat_policy_choices(h, s.cint, ibuf(ch)) == 0
          if ch[0] == 1: check ch[2] in 1'i32..16'i32   # the premise: every draw targets an identity
          bins[k].add extra[0]
          bins[k].add extra[1]
    check hashes[0].len > 100
    check hashes[0] == hashes[1]
    check bins[0] == bins[1]

  test "a contract-15 handle seats contract-11 seats (the 82-logit prefix) but not 13 or 14":
    for (seatAction, ok) in [(ActionContractTeamsView1Hash, true), (ActionContractTeamsView1OffsetHash, false),
                             (ActionContractTeamsView1MoveHash, false)]:
      let h = pw_create(3, 600)
      require h != nil
      defer: pw_destroy(h)
      check pw_set_action_contract(h, 15) == 0
      let manifest = manifestFor(seatAction)
      check pw_set_seat_policy_script(h, 0, cbuf(policy), policy.len.int32, cbuf(manifest), manifest.len.int32) == 0
      var actions = newSeq[int32](Seats*7)
      var logits = newSeq[cfloat](Seats*818)
      var rewards, terminals = newSeq[cfloat](Seats)
      check (pw_step_logits(h, ibuf(actions), fbuf(logits), fbuf(rewards), fbuf(terminals)) == 0) == ok
