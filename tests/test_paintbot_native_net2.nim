## The training library's pw_net_* ABI runs the hosted seat's PWNET001/PWNET002 code: the
## same loader verdicts, bit-identical inference, and a trainer that zeroes the state on
## pw_observe's reset mask and argmaxes pw_net_infer's logits plays the hosted neural seats'
## match hash for hash (deaths and respawns included). Synthetic weights only.
import std/[unittest, os, random, strutils]
import polyworld/cli
import ../examples/paintbot/[sim, neural_contract, native_env, bots, neural_host, neural_actor]
import paintbot_pwnet2_fixture

type Buffer = ptr UncheckedArray[float32]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])
template ibuf(a: untyped): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr a[0])
template i64buf(a: untyped): ptr UncheckedArray[int64] = cast[ptr UncheckedArray[int64]](addr a[0])
template cbuf(a: untyped): ptr UncheckedArray[char] = cast[ptr UncheckedArray[char]](addr a[0])

proc load(model: string, message: var string): pointer =
  var error: array[256, char]
  var data = model
  result = pw_net_load(addr data[0], data.len.int64, cbuf(error), 256)
  message = $cast[cstring](addr error[0])

proc attentionNet(r: var Rand, inputs = ObservationSize): string =
  encode2(inputs, ActionSizes, [
    r.attention([[104'u32, 8, 16, 8, 0], [24'u32, 8, 10, 8, 0]], 32, 4, 1, 48, 0, 24),
    concat(232, 160),
    r.dense(2*32+24+160, 96, bias = true, relu = true),
    r.rmsnorm(96),
    r.mingru(96, 96, highway = true, bias = true),
    residual(3),
    r.mingru(96, 48, highway = false),
    r.dense(48, LogitSize, bias = true, scale = 1.0)])

suite "pw_net ABI":
  test "load, info, verdicts and inference equal the hosted loader":
    var r = initRand(2718)
    var message = ""
    let model = r.attentionNet()
    let net = load(model, message)
    require net != nil
    check message == ""
    let actor = loadActor(model)
    var info: array[8, int64]
    check pw_net_info(net, i64buf(info)) == 0
    check info == [2'i64, ObservationSize, LogitSize, 144, 5, 8, actor.parameterCount, actor.operationCount]
    var heads: array[32, int32]
    check pw_net_head_sizes(net, ibuf(heads), 32) == 5
    check heads[0..4] == [51'i32, 25, 2, 2, 2]
    var contracts: array[140, char]
    check pw_net_contracts(net, cbuf(contracts), 140) == 0
    check $cast[cstring](addr contracts[0]) == ObservationContractHash & " " & ActionContractHash
    var hostState = newSeq[float32](144)
    var hostLogits = newSeq[float32](LogitSize)
    var state = newSeq[float32](144)
    var logits = newSeq[float32](LogitSize)
    for step in 0..<100:
      var obs = r.observation(ObservationSize)
      actor.infer(obs, hostState, hostLogits)
      check pw_net_infer(net, fbuf(obs), fbuf(state), fbuf(logits)) == 0
      check bits(state) == bits(hostState) and bits(logits) == bits(hostLogits)
    # A failed inference leaves the caller's state and logits untouched.
    var obs = r.observation(ObservationSize)
    obs[3] = NaN.float32
    let before = (bits(state), bits(logits))
    check pw_net_infer(net, fbuf(obs), fbuf(state), fbuf(logits)) == -2
    check (bits(state), bits(logits)) == before
    pw_net_destroy(net)
    # PWNET001 runs through the same entry points.
    let (v1, _, _, _) = r.pwnet001(ObservationSize, 64)
    let old = load(v1, message)
    require old != nil
    check pw_net_info(old, i64buf(info)) == 0
    check info[0] == 1 and info[3] == 64 and info[7] == loadActor(v1).operationCount
    pw_net_destroy(old)
    # Rejections carry the hosted loader's reason; over-budget models are refused as hosted.
    check load(model[0..^2], message) == nil and "truncated" in message
    let big = encode2(ObservationSize, ActionSizes, [
      r.attention([[104'u32, 8, 16, 8, 0], [24'u32, 8, 10, 8, 0], [232'u32, 5, 32, 5, 0]], 128, 4, 2, 256, 0, 24),
      r.dense(280, LogitSize)])
    check load(big, message) == nil
    check message == "neural actor exceeds native operation budget: " & $loadActor(big).operationCount & " > 4000000"
    check load("PWNET00", message) == nil and message == "invalid neural actor length"

const NeuralSource = """
paintbot_observe(neuralObservation())
run_neural_net(neuralModel(), neuralObservation(), neuralLogits(), neuralState())
paintbot_act(neuralLogits())
"""

suite "Hosted PWNET002 seats and the native ABI":
  configureRules(NativeRules)
  test "argmax over pw_net_infer with pw_observe's resets plays the hosted match hash for hash":
    var allDeaths = 0
    for seed in [5'i32, 6]:
      var r = initRand(seed)
      let model = r.attentionNet()
      let path = getTempDir()/("paintbot-native-net2-" & $seed & ".bas")
      writeFile(path, NeuralSource)
      writeFile(path & ".model.bin", model)
      let players = loadBots(@[BotGroup(path: path, count: Seats)])
      removeFile(path); removeFile(path & ".model.bin")
      var message = ""
      let net = load(model, message)
      require net != nil
      var world = newWorld(seed, 1500)
      let handle = pw_create(seed, 1500)
      require handle != nil
      var obs = newSeq[float32](Seats*ObservationSize)
      var resets: array[Seats, float32]
      var states = newSeq[float32](Seats*144)
      var logits = newSeq[float32](LogitSize)
      var actions: array[Seats*ActionSizes.len, int32]
      var rewards, terminals: array[Seats, float32]
      var steps, stateResets, deaths = 0
      while world.winner == -1 and world.tick < world.endTick:
        require pw_observe(handle, fbuf(obs), fbuf(resets)) == 0
        for slot in 0..<Seats:
          if resets[slot] != 0:
            inc stateResets
            for i in 0..<144: states[slot*144+i] = 0
          require pw_net_infer(net, cast[Buffer](addr obs[slot*ObservationSize]),
            cast[Buffer](addr states[slot*144]), fbuf(logits)) == 0
          let picked = argmaxActions(logits)
          for head in 0..<ActionSizes.len: actions[slot*ActionSizes.len+head] = picked[head].int32
          if world.cogs[slot].hp <= 0: inc deaths
        let commands = players.decide(world)
        for slot in 0..<Seats: require not players[slot].failed
        world.step(commands)
        require pw_step(handle, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
        require pw_state_hash(handle) == world.stateHash()
        inc steps
      for slot in 0..<Seats:
        check bits(players[slot].neural.state) == bits(states[slot*144 ..< (slot+1)*144])
      checkpoint "seed " & $seed & " steps " & $steps & " state resets " & $stateResets & " dead seat-ticks " & $deaths
      check steps > 300 and stateResets >= Seats
      allDeaths += deaths
      pw_destroy(handle)
      pw_net_destroy(net)
    check allDeaths > 0
