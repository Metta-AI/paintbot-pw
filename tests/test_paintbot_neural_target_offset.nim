## POINTER_K (PWNET002 layer 15) and action contract 15 (teams.view.1 target-conditioned aim offset): K logits per
## token, out[offset + n*K + k] += V[k] . z_n + c[k] over the source's valid tokens. Row k of a POINTER_K is
## exactly a POINTER with v = V[k], c = c[k] (same float32 terms in the same order); its published cost; its
## rejections; and a hosted contract-15 actor (818 logits) that loads, plays and draws no offset without a target.
import std/[unittest, random, os]
import ../examples/paintbot/[sim, bots, neural_contract, neural_actor]
from ../examples/paintbot/neural_host import loadNeuralSeat
import paintbot_pwnet2_fixture

const Root = currentSourcePath().parentDir.parentDir

proc rejects(data: string, fragment: string): bool =
  try:
    discard loadActor(data)
    false
  except ValueError as e:
    fragment in e.msg

proc observation(r: var Rand, n: int): seq[float32] =
  for i in 0..<n: result.add float32(r.rand(2.0) - 1.0)

proc run(actor: Actor, obs: seq[float32]): seq[float32] =
  var state = newSeq[float32](actor.stateSize)
  result = newSeq[float32](actor.outputSize)
  actor.infer(obs, state, result)

proc zeroDense(inputs, outputs: int): Spec =
  Spec(code: 1, params: [inputs.uint32, outputs.uint32, 0, 0, 0, 0, 0, 0], tensors: newSeq[float32](inputs*outputs))

suite "POINTER_K":
  test "row k of POINTER_K is exactly a POINTER with V[k], c[k]; masked tokens add nothing":
    var r = initRand(151)
    const T = 5
    const K = 3
    const Z = 6
    for trial in 0..<20:
      let mlp = r.tokenMlp(T, [[0'u32, 8, 6], [50'u32, 0, 3]], 0, 0, [8, Z])   # 5 tokens of 6 at stride 8
      let pk = r.pointerK(0, 2, Z, K)
      # TOKEN_MLP pools its rows to 2*Z (mean, max); a zero DENSE to 2 + T*K logits, then the rows from offset 2.
      let many = loadActor(encode2(64, [2, T*K], [mlp, zeroDense(2*Z, 2 + T*K), pk]))
      var obs = r.observation(64)
      for n in 0..<T: obs[8*n] = float32(r.rand(1))
      if trial == 0:
        for n in 0..<T: obs[8*n] = 0
      let y = many.run(obs)
      check y[0] == 0 and y[1] == 0
      for k in 0..<K:
        var one = Spec(code: 9, params: [0'u32, 0, 0, 0, 0, 0, 0, 0])
        one.tensors = pk.tensors[k*Z ..< (k+1)*Z]
        one.tensors.add pk.tensors[K*Z + k]
        let single = loadActor(encode2(64, [T], [mlp, zeroDense(2*Z, T), one]))
        let s = single.run(obs)
        for n in 0..<T:
          check cast[uint32](y[2 + n*K + k]) == cast[uint32](s[n])
          if obs[8*n] == 0: check y[2 + n*K + k] == 0

  test "the published cost: the copy, then per token and row a dot product, its bias and the add":
    var r = initRand(152)
    let mlp = r.tokenMlp(16, IdentityTokenSegments, 0, 0, [8, 7])
    let a = loadActor(encode2(538, [82, 368], [mlp, zeroDense(2*7, 450), r.pointerK(0, 82, 7, 23)]))
    let base = loadActor(encode2(538, [82, 368], [mlp, zeroDense(2*7, 450)]))
    check pointerKOps(16, 7, 450, 23) == 450 + 16*23*(2*7 + 2)
    check a.operationCount == base.operationCount + pointerKOps(16, 7, 450, 23)
    check pointerKOps(5, 4, 9, 1) == pointerOps(5, 4, 9)

  test "rejections: a non-token source, K out of range, rows past the width":
    var r = initRand(153)
    let mlp = r.tokenMlp(4, [[0'u32, 8, 8]], 0, 0, [5])
    check rejects(encode2(32, [12], [r.dense(32, 12), r.pointerK(0, 0, 12, 3)]), "POINTER_K source must name")
    check rejects(encode2(32, [12], [mlp, zeroDense(10, 12), r.pointerK(0, 0, 5, 0)]), "logits per token")
    check rejects(encode2(32, [12], [mlp, zeroDense(10, 12), r.pointerK(0, 1, 5, 3)]), "exceeds width")
    check not rejects(encode2(32, [12], [mlp, zeroDense(10, 12), r.pointerK(0, 0, 5, 3)]), "")

suite "Hosted target-offset seats (action contract 15)":
  test "a contract-15 actor loads and plays; keep and compass aims draw the centre bin; 128-wide is refused":
    configureRules(NativeRules)
    var r = initRand(154)
    let heads = actionLogitHeads(acTeamsView1Target)
    let model = encode2(TeamsViewSize, heads, [r.dense(TeamsViewSize, LogitSizeTarget, bias = true)],
      ObservationContractTeamsView1Hash, ActionContractTeamsView1TargetHash)
    let dir = getTempDir() / ("paintbot-target-offset-" & $getCurrentProcessId())
    createDir(dir)
    defer: removeDir(dir)
    let path = dir / "policy.bas"
    writeFile(path, "paintbot_observe(neuralObservation())\n" &
      "run_neural_net(neuralModel(), neuralObservation(), neuralLogits(), neuralState())\n" &
      "neuralTemperature(-1, 1000)\nneuralSample()\n" & readFile(Root / "examples/paintbot/players/neural_decode.bas"))
    writeFile(path & ".model.bin", model)
    var players = loadBots(@[BotGroup(path: path, count: Seats)])
    var w = newWorld(4)
    var targeted, untargeted = 0
    for tick in 0..<120:
      let commands = players.decide(w)
      for slot in 0..<Seats:
        let n = players[slot].neural
        if not n.sampled: continue
        if n.selected[1] in 1'i32..16'i32:
          check n.offsetChoices[0] in 0'i32..22'i32 and n.appliedOffsetTemperatures[0] == 1000
          inc targeted
        else:
          check n.offsetChoices[0] == 11 and n.offsetChoices[1] == 11
          check n.appliedOffsetTemperatures[0] == 0 and n.appliedOffsetTemperatures[1] == 0
          inc untargeted
      w.step(commands)
    for slot in 0..<Seats: check not players[slot].failed
    check targeted > 0
    writeFile(path & ".model.bin", encode2(TeamsViewSize, ActionSizesOffset,
      [r.dense(TeamsViewSize, LogitSizeOffset, bias = true)], ObservationContractTeamsView1Hash,
      ActionContractTeamsView1TargetHash))
    expect ValueError: discard loadNeuralSeat(path, 0)
