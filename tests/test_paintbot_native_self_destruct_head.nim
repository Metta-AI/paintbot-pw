## Action contract teams.view.1 self-destruct (17, paintbot-pw.teams.view.1.action.51-25-2-2-2-2): teams.view.1's five
## heads, then head 5 = self-destruct (0 no, 1 yes), which the reference decoder (players/neural_decode.bas) turns into
## BASIC's selfDestruct() when neuralLayout(21) = 2. Through the native ABI:
## - id, hash, sizes, logit width 84, pairing with every teams observation contract, layout_ext;
## - caller-driven seats (pw_step): head 5 = 0 plays exactly as contract 11 (random heads 0 .. 4, rules 49, every
##   seat, every tick's hash); head 5 = 1 makes a live cog self-destruct at rules 49 (the cog dies and pw_damage_events logs
##   its own death as weapon 5; an unscripted seat's pw_seat_orders reads zeros by design) and does nothing at rules 48;
## - policy seats (pw_step_logits): head 5's argmax follows its two logits (the init bias (0, -14.2) never fires);
##   pw_seat_policy_extra_choices reports head 5;
## - zero-widening: a contract-11 policy seat and its contract-17 twin whose head 5 reads (0, -30) under ARGMAX (head 5
##   left out of the sampled heads: no draw) play byte-identically while heads 0 .. 4 are SAMPLED (T = 1) from the same
##   random logits for 600 ticks.
## Build with --mm:arc --threads:on -d:pwTraining -d:headless.
import std/[unittest, os, random, importutils]
import ../examples/paintbot/[sim, neural_contract, native_env]

when not defined(pwTraining): {.error: "the native ABI exists only under -d:pwTraining".}

const Root = currentSourcePath().parentDir.parentDir
type Buffer = ptr UncheckedArray[cfloat]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])
template ibuf(a: untyped): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr a[0])
template cbuf(s: string): ptr UncheckedArray[char] = cast[ptr UncheckedArray[char]](unsafeAddr s[0])
privateAccess(NativeEnv)

const Decoder = Root / "examples/paintbot/players/neural_decode.bas"

proc newHandle(seed: int32, contract: int32, rules = 49'i32, ticks = 900'i32): pointer =
  result = pw_create(seed, ticks)
  doAssert result != nil
  doAssert pw_set_action_contract(result, contract) == 0
  doAssert pw_set_rules(result, rules) == 0
  doAssert pw_reset(result, seed, ticks) == 0

proc policyScript(temperatures: string): string =
  "paintbot_observe(neuralObservation())\n" &
    "run_neural_net(neuralModel(), neuralObservation(), neuralLogits(), neuralState())\n" &
    temperatures & "neuralSample()\n" & readFile(Decoder)

proc manifestFor(action: string): string =
  """{"schema": "paintbot-neural-basic/2", "observation_contract": """" & ObservationContractTeamsView1Hash &
    """", "action_contract": """" & action & """"}"""

suite "Action contract teams.view.1 self-destruct (17)":
  test "id, hash, sizes, pairing, layout_ext":
    check ActionContractTeamsView1SelfDestruct == "paintbot-pw.teams.view.1.action.51-25-2-2-2-2"
    check actionContractHash(acTeamsView1SelfDestruct) == ActionContractTeamsView1SelfDestructHash
    check actionContractVersion(ActionContractTeamsView1SelfDestructHash) == acTeamsView1SelfDestruct
    check actionHeadSizes(acTeamsView1SelfDestruct) == @[51, 25, 2, 2, 2, 2]
    check actionLogitSize(acTeamsView1SelfDestruct) == 84 and extraHeads(acTeamsView1SelfDestruct) == 1
    for obs in [201'i32, 203, 204, 205, 206, 207]:
      let h = pw_create_observation(5, 300, obs)
      if h == nil: continue
      check pw_set_action_contract(h, 17) == 0
      var lay: array[10, int32]
      check pw_action_layout(h, ibuf(lay)) == -1          # six heads: the _ext call
      check pw_action_layout_ext(h, ibuf(lay)) == 0
      check lay[0] == 6 and lay[1..6] == [51'i32, 25, 2, 2, 2, 2] and lay[8] == 84
      pw_destroy(h)
    var hash: array[65, char]
    check pw_action_contract_hash(17, cast[ptr UncheckedArray[char]](addr hash[0]), 65) == 0
    check $cast[cstring](addr hash[0]) == ActionContractTeamsView1SelfDestructHash

  test "caller-driven: head 5 = 0 plays exactly as contract 11 (rules 49, random heads, every seat)":
    var r = initRand(17)
    let a = newHandle(4951, 11)
    let b = newHandle(4951, 17)
    var x = newSeq[int32](Seats*5)
    var y = newSeq[int32](Seats*6)
    var rewards, terminals, t2 = newSeq[cfloat](Seats)
    for t in 0..<600:
      for s in 0..<Seats:
        for k in 0..<5:
          let v = int32(r.rand(ActionSizes[k] - 1))
          x[s*5+k] = v; y[s*6+k] = v
        y[s*6+5] = 0
      check pw_step(a, ibuf(x), fbuf(rewards), fbuf(terminals)) == 0
      check pw_step(b, ibuf(y), fbuf(rewards), fbuf(t2)) == 0
      check pw_state_hash(a) == pw_state_hash(b)
      if terminals[0] == 1: break
    pw_destroy(a); pw_destroy(b)

  test "caller-driven: head 5 = 1 self-destructs a live cog at rules 49 (death, damage log 5); nothing at 48":
    for rules in [49'i32, 48]:
      let h = newHandle(4952, 17, rules)
      let env = cast[ptr NativeEnv](h)
      var acts = newSeq[int32](Seats*6)
      var rewards, terminals = newSeq[cfloat](Seats)
      for t in 0..<30: doAssert pw_step(h, ibuf(acts), fbuf(rewards), fbuf(terminals)) == 0
      discard pw_damage_events(h, nil, 0)
      var drop = newSeq[int32](8*256)
      discard pw_damage_events(h, ibuf(drop), 256)
      check env.world.cogs[0].hp > 0
      acts[5] = 1
      check pw_step(h, ibuf(acts), fbuf(rewards), fbuf(terminals)) == 0
      var ev = newSeq[int32](8*64)
      let n = pw_damage_events(h, ibuf(ev), 64)
      var own = false
      for i in 0..<n:
        if ev[i*8+1] == 0 and ev[i*8+2] == 0 and ev[i*8+3] == 5 and ev[i*8+6] == 1: own = true
      if rules == 49:
        check env.world.cogs[0].hp == 0 and own
      else:
        check env.world.cogs[0].hp > 0 and not own
      pw_destroy(h)

  test "policy seat: head 5 follows its logits; the init bias (0, -14.2) never fires; extra_choices reports it":
    let h = newHandle(4953, 17)
    defer: pw_destroy(h)
    let env = cast[ptr NativeEnv](h)
    let policy = policyScript("")
    let manifest = manifestFor(ActionContractTeamsView1SelfDestructHash)
    check pw_set_seat_policy_script(h, 0, cbuf(policy), policy.len.int32, cbuf(manifest), manifest.len.int32) == 0
    var actions = newSeq[int32](Seats*6)
    var logits = newSeq[cfloat](Seats*84)
    var rewards, terminals = newSeq[cfloat](Seats)
    logits[82] = 0; logits[83] = -14.2
    for t in 0..<40:
      check pw_step_logits(h, ibuf(actions), fbuf(logits), fbuf(rewards), fbuf(terminals)) == 0
      var o: array[11, int32]
      doAssert pw_seat_orders_ex(h, 0, ibuf(o)) == 0
      check o[10] == 0
    var x: array[12, int32]
    check pw_seat_policy_extra_choices(h, 0, ibuf(x)) == 0
    check x[0] == 0 and x[4] == 0
    check env.world.cogs[0].hp > 0
    logits[83] = 5
    check pw_step_logits(h, ibuf(actions), fbuf(logits), fbuf(rewards), fbuf(terminals)) == 0
    check pw_seat_policy_extra_choices(h, 0, ibuf(x)) == 0
    check x[0] == 1 and x[4] == 1
    check env.world.cogs[0].hp == 0                       # rules 49: it blew up

  test "zero-widening: contract 11 vs its 17 twin (head 5 (0, -30), argmax) with heads 0 .. 4 sampled play identically":
    var r = initRand(4954)
    let a = newHandle(4954, 11)
    let b = newHandle(4954, 17)
    let policy = policyScript("neuralTemperature(0, 1000)\nneuralTemperature(1, 1000)\nneuralTemperature(2, 1000)\n" &
      "neuralTemperature(3, 1000)\nneuralTemperature(4, 1000)\n")
    let m11 = manifestFor(ActionContractTeamsView1Hash)
    let m17 = manifestFor(ActionContractTeamsView1SelfDestructHash)
    for s in 0..<Seats:
      doAssert pw_set_seat_policy_script(a, s.cint, cbuf(policy), policy.len.int32, cbuf(m11), m11.len.int32) == 0
      doAssert pw_set_seat_policy_script(b, s.cint, cbuf(policy), policy.len.int32, cbuf(m17), m17.len.int32) == 0
    var x = newSeq[int32](Seats*5)
    var y = newSeq[int32](Seats*6)
    var la = newSeq[cfloat](Seats*82)
    var lb = newSeq[cfloat](Seats*84)
    var rewards, terminals, t2 = newSeq[cfloat](Seats)
    var same = 0
    var ticks = 0
    for t in 0..<600:
      for s in 0..<Seats:
        for k in 0..<82:
          let v = float32(r.rand(4.0) - 2.0)
          la[s*82+k] = v; lb[s*84+k] = v
        lb[s*84+82] = 0; lb[s*84+83] = -30
      check pw_step_logits(a, ibuf(x), fbuf(la), fbuf(rewards), fbuf(terminals)) == 0
      check pw_step_logits(b, ibuf(y), fbuf(lb), fbuf(rewards), fbuf(t2)) == 0
      inc ticks
      if pw_state_hash(a) == pw_state_hash(b): inc same
      if terminals[0] == 1: break
    check same == ticks
    for s in 0..<Seats:
      var o: array[11, int32]
      doAssert pw_seat_orders_ex(b, s.cint, ibuf(o)) == 0
      check o[10] == 0
    echo "zero-widening: ", same, " / ", ticks, " ticks identical"
    pw_destroy(a); pw_destroy(b)
