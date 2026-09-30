## The decoder option forbid_objectives through the native training ABI: arguments and reset
## semantics; pw_sample_actions never selects a forbidden objective (argmax or draw, the
## reference sampler on the hosted seat's stream) and pw_step refuses one from the caller
## without stepping; and hosted neural seats with the forbid (and sampling) play the ABI's
## world hash for hash. (The strafe legs were a native decoder rule, retired for BASIC parity.)
## Build with --mm:arc --threads:on -d:pwTraining.
import std/[unittest, os, strutils]
import polyworld/[rngs, cli]
import ../examples/paintbot/[sim, neural_contract, native_env, bots, neural_host]

when not defined(pwTraining): {.error: "the native ABI exists only under -d:pwTraining".}

type Buffer = ptr UncheckedArray[cfloat]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])
template ibuf(a: untyped): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr a[0])

const River = [9'i32, 10]
const DecoderSource = staticRead("../examples/paintbot/players/neural_decode.bas")

proc logitsFor(seed: int): array[LogitSize, float32] =
  var x = uint32(seed)*2654435761'u32 + 12345
  for i in 0..<LogitSize:
    x = x*1664525'u32 + 1013904223'u32
    result[i] = float32(int((x shr 8) mod 6000) - 3000) / 1000'f32

proc riverMask(): ObjectiveMask =
  result[9] = true
  result[10] = true

suite "Native decoder objective forbid":
  configureRules(NativeRules)
  test "arguments, read-back and reset semantics":
    let h = pw_create(1, 240)
    require h != nil
    defer: pw_destroy(h)
    var mask: array[ActionSizes[0], int32]
    check pw_seat_forbidden_objectives(h, 0, ibuf(mask)) == 0
    for v in mask: check v == 0
    var river = River
    var bad = [9'i32, 9]
    var outside = [51'i32]
    var negative = [-1'i32]
    var every: array[ActionSizes[0], int32]
    for i in 0..<ActionSizes[0]: every[i] = i.int32
    check pw_set_seat_forbid_objectives(nil, 0, ibuf(river), 2) == -1
    check pw_set_seat_forbid_objectives(h, -1, ibuf(river), 2) == -1
    check pw_set_seat_forbid_objectives(h, Seats.cint, ibuf(river), 2) == -1
    check pw_set_seat_forbid_objectives(h, 0, ibuf(river), -1) == -1
    check pw_set_seat_forbid_objectives(h, 0, nil, 2) == -1
    check pw_set_seat_forbid_objectives(h, 0, ibuf(bad), 2) == -1
    check pw_set_seat_forbid_objectives(h, 0, ibuf(outside), 1) == -1
    check pw_set_seat_forbid_objectives(h, 0, ibuf(negative), 1) == -1
    check pw_set_seat_forbid_objectives(h, 0, ibuf(every), ActionSizes[0].int32) == -1
    check pw_set_seat_forbid_objectives(h, 0, ibuf(every), ActionSizes[0].int32 - 1) == 0  # 50 left allowed
    check pw_seat_forbidden_objectives(h, 0, ibuf(mask)) == ActionSizes[0] - 1
    check pw_set_seat_forbid_objectives(h, 0, ibuf(river), 2) == 0
    check pw_seat_forbidden_objectives(h, 0, ibuf(mask)) == 2
    for i, v in mask: check v == int32(i in [9, 10])
    check pw_seat_forbidden_objectives(h, 0, nil) == 2
    check pw_seat_forbidden_objectives(nil, 0, nil) == -1
    check pw_seat_forbidden_objectives(h, Seats.cint, nil) == -1
    # A failed call leaves the mask as it was; kept across reset; count 0 clears.
    check pw_set_seat_forbid_objectives(h, 0, ibuf(bad), 2) == -1
    check pw_seat_forbidden_objectives(h, 0, nil) == 2
    check pw_reset(h, 2, 240) == 0
    check pw_seat_forbidden_objectives(h, 0, nil) == 2
    check pw_set_seat_forbid_objectives(h, 0, nil, 0) == 0
    check pw_seat_forbidden_objectives(h, 0, nil) == 0
  test "pw_sample_actions never selects a forbidden objective, argmax or sampled on the hosted stream":
    let h = pw_create(7, 14400)
    require h != nil
    defer: pw_destroy(h)
    var river = River
    check pw_set_seat_forbid_objectives(h, 3, ibuf(river), 2) == 0
    for s in 0..<200:
      var logits = logitsFor(s)
      logits[9] = 20
      var picked: array[ActionSizes.len, int32]
      check pw_sample_actions(h, 3, fbuf(logits), ibuf(picked)) == 0
      check picked == argmaxActions(logits, riverMask())
      check picked[0] notin [9'i32, 10]
    check pw_set_seat_sampling(h, 3, 1000, 0) == 0
    var options: SamplingOptions
    options.enabled = true
    options.temperature = 1
    for head in 0..<ActionSizes.len: options.heads[head] = true
    var reference = samplingRng(7, 3)
    for s in 0..<500:
      var logits = logitsFor(s)
      logits[9] = 4; logits[10] = 4
      var picked: array[ActionSizes.len, int32]
      check pw_sample_actions(h, 3, fbuf(logits), ibuf(picked)) == 0
      check picked == sampleActions(logits, options, reference, riverMask())
      check picked[0] notin [9'i32, 10]
    check pw_seat_sample_draws(h, 3) == 500
  test "pw_step refuses a forbidden objective from the caller without stepping; scripted seats are exempt":
    let h = pw_create(11, 240)
    let plain = pw_create(11, 240)
    require h != nil and plain != nil
    defer:
      pw_destroy(h)
      pw_destroy(plain)
    var river = River
    check pw_set_seat_forbid_objectives(h, 4, ibuf(river), 2) == 0
    var actions: array[LegacySeats*ActionSizes.len, int32]
    var rewards, terminals: array[LegacySeats, cfloat]
    let before = pw_state_hash(h)
    actions[4*ActionSizes.len] = 10
    check pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == -3
    check pw_state_hash(h) == before
    actions[4*ActionSizes.len] = 9
    check pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == -3
    # Another seat may choose it; the forbidding seat choosing anything else steps exactly
    # like a handle without the forbid.
    actions[4*ActionSizes.len] = 3
    actions[5*ActionSizes.len] = 9
    for tick in 0..<60:
      check pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
      check pw_step(plain, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
      check pw_state_hash(h) == pw_state_hash(plain)
    # A seat driven by its script (override 0) ignores the caller's action, so it is not checked.
    var idle = "walkTo(selfX, selfY)\n"
    check pw_set_seat_script(h, 4, cast[ptr UncheckedArray[char]](addr idle[0]), idle.len.int32) == 0
    actions[4*ActionSizes.len] = 9
    check pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
    check pw_set_seat_override(h, 4, 1) == 0
    check pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == -3
    # Dead seats (whose actions the decoder ignores) are exempt: the hosted-vs-ABI suite
    # below hands dead seats index 0, which it forbids, through every death in its matches.

suite "Hosted neural seats and the native ABI take the same decoder path":
  configureRules(NativeRules)
  proc u32(s: var string, value: uint32) =
    for i in 0..3: s.add char((value shr (8*i)) and 255)
  proc zeroModel(): string =
    ## A valid teams.view.1 actor whose logits are all zero: argmax takes index 0 of every
    ## head, a sampled head is a uniform draw over its allowed candidates.
    const h = 64
    const n = TeamsViewSize*h + 3*h*h + LogitSize*h
    result = "PWNET001"
    for x in [1,TeamsViewSize,h,LogitSize,ActionSizes.len,n]: result.u32(x.uint32)
    result.add ObservationContractTeamsView1Hash
    result.add ActionContractTeamsView1Hash
    for x in ActionSizes: result.u32(x.uint32)
    result.add repeat('\0', n*4)
  proc neuralSeats(decoder: string): seq[Bot] =
    let path = getTempDir()/"paintbot-native-river-strafe-test.bas"
    writeFile(path, "paintbot_observe(neuralObservation())\n" &
      "run_neural_net(neuralModel(), neuralObservation(), neuralLogits(), neuralState())\n" &
      "neuralSample()\n" & DecoderSource)
    writeFile(path & ".model.bin", zeroModel())
    writeFile(path & ".neural.json", "{\"schema\": \"paintbot-neural-basic/2\", \"observation_contract\": \"" &
      ObservationContractTeamsView1Hash & "\", \"action_contract\": \"" & ActionContractTeamsView1Hash & "\", \"sha256\": {}, \"decoder\": " & decoder & "}")
    defer:
      removeFile(path); removeFile(path & ".model.bin"); removeFile(path & ".neural.json")
    loadBots(@[BotGroup(path: path, count: Seats)])
  test "forbid + sampling, and forbid alone: every hosted seat's world equals the ABI's, hash for hash, across deaths":
    # Every seat runs the bundle (selection, then the reference decode in BASIC); the ABI
    # handle gets the same options on every seat and the zero logits through
    # pw_sample_actions, then pw_step decodes with the same script.
    var deaths = 0
    for (decoder, sampled) in [("{\"forbid_objectives\": [0, 9, 10], \"sampling\": {\"mode\": \"categorical\"}}", true),
                               ("{\"forbid_objectives\": [0, 9, 10]}", false)]:
      for seed in [3'i32, 4]:
        let players = neuralSeats(decoder)
        var world = newWorld(seed, 600)
        let handle = pw_create(seed, 600)
        require handle != nil
        var forbid = [0'i32, 9, 10]
        for slot in 0..<Seats:
          check pw_set_seat_forbid_objectives(handle, slot.cint, ibuf(forbid), 3) == 0
          if sampled: check pw_set_seat_sampling(handle, slot.cint, 1000, 0) == 0
        var actions: array[LegacySeats*ActionSizes.len, int32]
        var rewards, terminals: array[LegacySeats, float32]
        var zero: array[LogitSize, float32]
        var steps = 0
        var decisions: array[LegacySeats, int]
        while world.winner == -1 and world.tick < world.endTick:
          # A hosted seat decides (and draws) only while alive on the pre-step world, so the
          # ABI caller selects actions for exactly those seats; a dead seat's are ignored.
          for slot in 0..<Seats:
            let o = slot*ActionSizes.len
            for head in 0..<ActionSizes.len: actions[o+head] = 0
            if world.cogs[slot].hp > 0:
              inc decisions[slot]
              require pw_sample_actions(handle, slot.cint, fbuf(zero), ibuf(actions.toOpenArray(o, o+ActionSizes.len-1))) == 0
            else: inc deaths
          let commands = players.decide(world)
          for slot in 0..<Seats: require not players[slot].failed
          world.step(commands)
          require pw_step(handle, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
          require pw_state_hash(handle) == world.stateHash()
          inc steps
        for slot in 0..<Seats:
          # Zero logits: the unmasked argmax objective is index 0, forbidden, on every decision.
          check players[slot].neural.telemetry(10, steps).contains(" forbid_objectives=0,9,10 forbid_hits=" & $decisions[slot])
          if sampled: check pw_seat_sample_draws(handle, slot.cint) == players[slot].neural.sampleDraws.cint
        checkpoint decoder & " seed " & $seed
        check steps > 100
        pw_destroy(handle)
    check deaths > 0   # dead seat-ticks: the decoder's per-life state crossed respawns
