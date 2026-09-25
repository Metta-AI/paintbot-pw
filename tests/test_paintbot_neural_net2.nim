## PWNET002 (neural_actor.nim): loader validation, the published operation count, the
## PWNET001 identity (a PWNET001 actor re-encoded as DENSE -> MINGRU highway -> DENSE runs
## bit for bit the same), every layer type, no allocation during inference, and the hosted
## seat running a PWNET002 package. Synthetic weights only.
import std/[unittest, os, random, strutils, math, sequtils]
import polyworld/cli
import ../examples/paintbot/[bots, sim, neural_contract, neural_host, neural_actor]
import paintbot_pwnet2_fixture

proc rejects(data: string, fragment = ""): bool =
  try:
    discard loadActor(data)
    false
  except ValueError as e:
    fragment.len == 0 or fragment in e.msg

suite "PWNET002 actor":
  test "a PWNET001 actor re-encoded as DENSE -> MINGRU highway -> DENSE is bit-identical":
    var r = initRand(20260925)
    for (inputs, hidden) in [(448, 64), (506, 128), (448, 256), (17, 64)]:
      let (v1, e, rec, dec) = r.pwnet001(inputs, hidden)
      let v2 = encode2(inputs, ActionSizes, [
        Spec(code: 1, params: [inputs.uint32, hidden.uint32, 0, 0, 0, 0, 0, 0], tensors: e),
        Spec(code: 3, params: [hidden.uint32, hidden.uint32, 1, 0, 0, 0, 0, 0], tensors: rec),
        Spec(code: 1, params: [hidden.uint32, LogitSize.uint32, 0, 0, 0, 0, 0, 0], tensors: dec)])
      let a = loadActor(v1)
      let b = loadActor(v2)
      check a.actorFormat == 1 and b.actorFormat == 2
      check a.operationCount == b.operationCount
      check b.stateSize == hidden and b.modelTag == "pwnet2-l3-s" & $hidden and a.modelTag == "w" & $hidden
      var sa = newSeq[float32](hidden)
      var sb = newSeq[float32](hidden)
      var la = newSeq[float32](LogitSize)
      var lb = newSeq[float32](LogitSize)
      for step in 0..<200:
        if step mod 37 == 0:
          for i in 0..<hidden:
            sa[i] = 0; sb[i] = 0
        let obs = r.observation(inputs)
        a.infer(obs, sa, la)
        b.infer(obs, sb, lb)
        check bits(la) == bits(lb)
        check bits(sa) == bits(sb)

  test "the published operation count":
    var r = initRand(7)
    let net = loadActor(encode2(506, ActionSizes, [
      r.dense(506, 64, bias = true, relu = true),           # 2*506*64 + 64 + 64
      r.rmsnorm(64),                                        # 4*64 + 16
      r.mingru(64, 64, highway = true, bias = true),        # 2*64*192 + 192 + 32*64
      r.mingru(64, 32, highway = false),                    # 2*64*64 + 32*32
      concat(0, 24),                                      # 24
      r.dense(56, 56),                                      # 2*56*56
      residual(5),                                          # 56
      r.dense(56, LogitSize)]))                             # 2*56*82
    let expected = 2*506*64 + 64 + 64 + 4*64 + 16 + 2*64*192 + 192 + 32*64 + 2*64*64 + 32*32 + 24 +
      2*56*56 + 56 + 2*56*82
    check net.operationCount == expected
    check net.stateSize == 96
    # ENTITY_ATTN: T tokens, d, h heads, F, P passthrough (neural_actor.md).
    let (T, d, h, F, P) = (26, 64, 4, 64, 24)
    let attn = r.attention([[24'u32, 8, 10, 8, 0], [104'u32, 8, 16, 8, 0]], d, h, 2, F, 0, P)
    let tnet = loadActor(encode2(506, ActionSizes, [attn, r.dense(2*d+P, LogitSize)]))
    let embed = 26*(2*8*d + d)
    let perBlock = 2*T*(4*d + 16) + T*(6*d*d + 3*d) + T*T*(4*d + 13*h) + 8*h*T + T*(2*d*d + d) + T*d +
      T*(2*d*F + 2*F) + T*(2*F*d + d) + T*d
    let pool = T + 2*T*d + d + 8 + P
    check tnet.operationCount == embed + 2*perBlock + pool + 2*(2*d+P)*LogitSize
    # The documented example (neural_actor.md): 3,307,774 operations.
    let example = loadActor(encode2(506, ActionSizes, [attn, concat(232, 274),
      r.mingru(426, 128, highway = false, bias = true), r.dense(128, LogitSize, bias = true)]))
    check example.operationCount == 3_307_774

  test "every layer type runs, recurrent state is all MINGRU states in layer order":
    var r = initRand(99)
    let actor = loadActor(encode2(506, ActionSizes, [
      r.attention([[104'u32, 8, 16, 8, 0], [24'u32, 8, 10, 8, AttnAlwaysValid]], 32, 4, 1, 48, 0, 24),
      concat(448, 58),
      r.dense(2*32+24+58, 96, bias = true, relu = true),
      r.rmsnorm(96),
      r.mingru(96, 96, highway = true, bias = true),
      residual(3),
      r.mingru(96, 40, highway = false),
      r.dense(40, LogitSize, bias = true)]))
    check actor.stateSize == 136 and actor.layerCount == 8
    var state = newSeq[float32](136)
    var logits = newSeq[float32](LogitSize)
    for step in 0..<50:
      actor.infer(r.observation(506), state, logits)
      for x in logits: check classify(x) notin {fcNan, fcInf, fcNegInf}
    check state.anyIt(it != 0)

  test "attention masks invalid tokens and pools zeros when none is valid":
    var r = initRand(5)
    let actor = loadActor(encode2(64, [2, 2, 2], [
      r.attention([[0'u32, 8, 8, 8, 0]], 8, 2, 1, 16, 0, 0), r.dense(16, 6)]))
    var state: seq[float32]
    var a, b = newSeq[float32](6)
    var obs = newSeq[float32](64)
    actor.infer(obs, state, a)           # no valid token: pooled zeros, logits zero
    check a == newSeq[float32](6)
    for i in 0..<64: obs[i] = float32(r.rand(2.0) - 1.0)
    for t in 0..<8: obs[8*t] = 0
    obs[8*3] = 1
    actor.infer(obs, state, a)
    # Changing only masked tokens' features changes nothing.
    for t in [0, 1, 2, 4, 5, 6, 7]:
      for c in 1..7: obs[8*t+c] = float32(r.rand(2.0) - 1.0)
    actor.infer(obs, state, b)
    check bits(a) == bits(b)

  test "inference does not allocate":
    var r = initRand(3)
    let actor = loadActor(encode2(506, ActionSizes, [
      r.attention([[104'u32, 8, 16, 8, 0]], 32, 4, 1, 32, 0, 24),
      r.mingru(88, 64, highway = false, bias = true), r.dense(64, LogitSize)]))
    var state = newSeq[float32](64)
    var logits = newSeq[float32](LogitSize)
    let obs = r.observation(506)
    actor.infer(obs, state, logits)
    let before = getOccupiedMem()
    for i in 0..<20: actor.infer(obs, state, logits)
    check getOccupiedMem() == before

  test "loader rejects malformed files cleanly":
    var r = initRand(11)
    let good = encode2(64, [2, 2, 2], [r.dense(64, 16, bias = true), r.mingru(16, 16, true), r.dense(16, 6)])
    discard loadActor(good)
    check rejects(good[0..^2], "truncated")
    check rejects(good & "\0\0\0\0", "trailing")
    for cut in [8, 12, 20, 24, 40, 100, 160, 175, 200]:
      check rejects(good[0..<cut])
    # Header fields.
    var bad = good
    bad[8] = '\3'
    check rejects(bad, "version")
    check rejects(encode2(64, [2, 2, 2], [r.dense(64, 7)]), "last layer width")
    check rejects(encode2(64, [2, 2, 2], [r.dense(63, 6)]), "DENSE input")
    check rejects(encode2(64, [2, 2, 2], []), "layer count")
    var flagged = r.dense(64, 6)
    flagged.params[2] = 2
    check rejects(encode2(64, [2, 2, 2], [flagged]), "must be 0 or 1")
    var unusedSet = r.dense(64, 6)
    unusedSet.params[7] = 1
    check rejects(encode2(64, [2, 2, 2], [unusedSet]), "unused parameter")
    check rejects(encode2(64, [2, 2, 2], [Spec(code: 9)]), "unknown layer type")
    check rejects(encode2(64, [2, 2, 2], [r.mingru(64, 32, highway = true), r.dense(32, 6)]), "highway")
    check rejects(encode2(64, [2, 2, 2], [r.dense(64, 6), residual(1)]), "earlier layer")
    check rejects(encode2(64, [2, 2, 2], [r.dense(64, 5), residual(0)]), "last layer width")
    check rejects(encode2(64, [2, 2, 2], [r.dense(64, 2), concat(60, 5)]), "outside the input")
    check rejects(encode2(64, [2, 2, 2], [r.rmsnorm(64, 0'f32), r.dense(64, 6)]), "eps")
    check rejects(encode2(64, [2, 2, 2], [r.rmsnorm(64, NaN.float32), r.dense(64, 6)]), "eps")
    check rejects(encode2(64, [2, 2, 2], [r.attention([[60'u32, 8, 1, 8, 0]], 8, 2, 1, 8, 0, 0), r.dense(16, 6)]),
      "outside the input")
    check rejects(encode2(64, [2, 2, 2], [r.attention([[0'u32, 8, 8, 8, 8]], 8, 2, 1, 8, 0, 0), r.dense(16, 6)]),
      "valid index")
    check rejects(encode2(64, [2, 2, 2], [r.attention([[0'u32, 8, 8, 8, 0]], 8, 3, 1, 8, 0, 0), r.dense(16, 6)]),
      "heads")
    check rejects(encode2(64, [2, 2, 2], [r.attention([[0'u32, 1, 60, 4, 0], [0'u32, 1, 10, 4, 0]], 8, 2, 1, 8, 0, 0),
      r.dense(16, 6)]), "tokens")
    var nonfinite = r.dense(64, 6)
    nonfinite.tensors[5] = Inf.float32
    check rejects(encode2(64, [2, 2, 2], [nonfinite]), "nonfinite")
    check rejects(encode2(64, [2, 2, 2], [r.dense(64, 6)], observationContract = repeat('G', 64)), "contract")
    # Fuzz: random truncations and byte flips either load or raise ValueError, never crash.
    var loaded = 0
    for trial in 0..<3000:
      var data = good
      case trial mod 3
      of 0: data = data[0..<r.rand(data.len-1)]
      of 1:
        for flips in 0..<1+r.rand(3): data[r.rand(data.len-1)] = char(r.rand(255))
      else:
        let at = 8 + 4*r.rand(40)
        if at + 4 <= data.len:
          for i in 0..3: data[at+i] = char(r.rand(255))
      try:
        let a = loadActor(data)
        inc loaded
        var state = newSeq[float32](a.stateSize)
        var logits = newSeq[float32](a.outputSize)
        try: a.infer(newSeq[float32](a.inputSize), state, logits)
        except ValueError: discard
      except ValueError: discard
    check loaded > 0

const NeuralSource = """
paintbot_observe(neuralObservation())
run_neural_net(neuralModel(), neuralObservation(), neuralLogits(), neuralState())
paintbot_act(neuralLogits())
"""

proc seatFixture(model: string): array[Seats, Bot] =
  let path = getTempDir()/"paintbot-neural-net2-test.bas"
  writeFile(path, NeuralSource)
  writeFile(path & ".model.bin", model)
  defer:
    removeFile(path)
    removeFile(path & ".model.bin")
  loadBots(@[BotGroup(path: path, count: Seats)])

suite "PWNET002 hosted seat":
  test "a PWNET002 package plays, its telemetry names the model, state resets like PWNET001":
    var r = initRand(42)
    let model = encode2(ObservationSize, ActionSizes, [
      r.attention([[104'u32, 8, 16, 8, 0], [24'u32, 8, 10, 8, 0]], 32, 4, 1, 32, 0, 24),
      r.mingru(88, 64, highway = false, bias = true),
      r.dense(64, LogitSize, bias = true)])
    let players = seatFixture(model)
    var w = newWorld(2026)
    for tick in 0..<40:
      discard players.decide(w)
      check not players[0].failed
      w.step(default(array[Seats, Command]))
    let actor = loadActor(model)
    check players[0].neural.state.len == 64
    check players[0].neural.nativeWork == actor.operationCount
    check players[0].neural.telemetry(actor.operationCount, 40) ==
      "neural: peak_ops=" & $actor.operationCount & " budget=4000000 model=pwnet2-l3-s64 ticks=40"

  test "an over-budget PWNET002 model is rejected at load with its cost":
    var r = initRand(43)
    let model = encode2(ObservationSize, ActionSizes, [
      r.attention([[104'u32, 8, 16, 8, 0], [24'u32, 8, 10, 8, 0], [232'u32, 5, 32, 5, 0]], 128, 4, 2, 256, 0, 24),
      r.dense(280, LogitSize)])
    let actor = loadActor(model)
    check actor.operationCount > 4_000_000
    let path = getTempDir()/"paintbot-neural-net2-budget.bas"
    writeFile(path, NeuralSource)
    writeFile(path & ".model.bin", model)
    defer:
      removeFile(path)
      removeFile(path & ".model.bin")
    try:
      discard loadNeuralSeat(path, 0)
      check false
    except NeuralBudgetError as e:
      check e.operations == actor.operationCount
      check e.model == "pwnet2-l2-s0"
      check neuralTelemetry(e.operations, e.model, 0) ==
        "neural: peak_ops=" & $actor.operationCount & " budget=4000000 model=pwnet2-l2-s0 ticks=0"

suite "PWNET002 with user inputs (observation contract v2u<K>)":
  proc userInputNet(k: int, contract: string, inputs = ObservationSizeV2 + k): string =
    ## DENSE(inputs -> 8) picking the K user-input columns (506..) into y[0..K-1], then
    ## DENSE(8 -> 82) copying y[0..K-1] to logits[0..K-1]: the logits read the user inputs.
    var w1 = newSeq[float32](8*inputs)
    for j in 0..<min(k, 8):
      if ObservationSizeV2 + j < inputs: w1[j*inputs + ObservationSizeV2 + j] = 1
    var w2 = newSeq[float32](LogitSize*8)
    for j in 0..<min(k, 8): w2[j*8 + j] = 1
    encode2(inputs, ActionSizes, [
      Spec(code: 1, params: [inputs.uint32, 8, 0, 0, 0, 0, 0, 0], tensors: w1),
      Spec(code: 1, params: [8, LogitSize.uint32, 0, 0, 0, 0, 0, 0], tensors: w2)],
      observationContract = contract, actionContract = ActionContractV2Hash)
  proc inputsBundle(source, model: string, count: int, contract: string): array[Seats, Bot] =
    let path = getTempDir()/("paintbot-neural-net2-inputs-" & $getCurrentProcessId() & ".bas")
    writeFile(path, source)
    writeFile(path & ".model.bin", model)
    var init: seq[string]
    for i in 0..<count: init.add $(5*(i+1))
    writeFile(path & ".neural.json", "{\"schema\": \"paintbot-neural-basic/2\", \"observation_contract\": \"" &
      contract & "\", \"action_contract\": \"" & ActionContractV2Hash & "\", \"sha256\": {}, " &
      "\"user_inputs\": {\"count\": " & $count & ", \"init\": [" & init.join(", ") & "]}}")
    defer:
      for suffix in ["", ".model.bin", ".neural.json"]: removeFile(path & suffix)
    loadBots(@[BotGroup(path: path, count: Seats)])
  const Source = """
neuralInput(0, worldTick * 10)
neuralInput(2, -worldTick)
paintbot_observe(neuralObservation())
run_neural_net(neuralModel(), neuralObservation(), neuralLogits(), neuralState())
paintbot_act(neuralLogits())
"""

  test "a PWNET002 v2u3 bundle loads, costs its 509 inputs, and its net reads the inputs one tick later":
    const k = 3
    let contract = UserInputsContractHashes[k-1]
    let model = userInputNet(k, contract)
    let actor = loadActor(model)
    check actor.inputSize == ObservationSizeV2 + k
    check actor.operationCount == 2*(ObservationSizeV2 + k)*8 + 2*8*LogitSize
    let players = inputsBundle(Source, model, k, contract)
    check not players[0].failed
    check players[0].neural.observation.len == ObservationSizeV2 + k
    var world = newWorld(33)
    var ranBefore: array[Seats, bool]
    for tick in 0..<60:
      let commands = players.decide(world)
      for slot in 0..<Seats: require not players[slot].failed
      # Every seat that ran this tick: logits[j] = the user input j it set on the tick before
      # (the manifest's init on the match's first tick), divided by 1000.
      for slot in 0..<Seats:
        let ran = world.cogs[slot].hp > 0
        defer: ranBefore[slot] = ran
        if not ran or (tick > 0 and not ranBefore[slot]): continue
        let lg = players[slot].neural.logits
        if tick == 0:
          check lg[0] == 0.005'f32 and lg[1] == 0.010'f32 and lg[2] == 0.015'f32
        else:
          check lg[0] == float32((tick-1)*10) / 1000'f32
          check lg[1] == 0.010'f32
          check lg[2] == float32(-(tick-1)) / 1000'f32
      world.step(commands)
    check players[0].neural.telemetry(actor.operationCount, 60) ==
      "neural: peak_ops=" & $actor.operationCount & " budget=4000000 model=pwnet2-l2-s0 ticks=60"

  test "a mismatched K, contract or width is rejected":
    let k3 = UserInputsContractHashes[2]
    let k2 = UserInputsContractHashes[1]
    check not inputsBundle(Source, userInputNet(3, k3), 3, k3)[0].failed
    check inputsBundle(Source, userInputNet(3, k3), 2, k3)[0].failed                 # manifest K 2, contract v2u3
    check inputsBundle(Source, userInputNet(3, k2, ObservationSizeV2 + 3), 3, k3)[0].failed  # actor names v2u2
    check inputsBundle(Source, userInputNet(3, k2, ObservationSizeV2 + 3), 2, k2)[0].failed  # v2u2 with 509 inputs
    check inputsBundle(Source, userInputNet(3, k3, ObservationSizeV2), 3, k3)[0].failed      # v2u3 with 506 inputs
