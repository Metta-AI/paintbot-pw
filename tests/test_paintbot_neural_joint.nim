## decoder.joint_sampling: a head's selection conditioned on another head's (neural_contract.jointSelect,
## neural_host). The condition false takes no draw and changes nothing; the condition true re-selects the head from its
## logits plus the bundle's offsets under the same exclusions and temperature (argmax at 0, else exactly one draw);
## the hosted seat applies it before the aim-phase options and logs it; the manifest parser rejects malformed options.
## Synthetic weights only.
import std/[unittest, os, random, strutils, json, math]
import polyworld/[cli, rngs]
import ../examples/paintbot/[bots, sim, neural_contract, neural_host]
import paintbot_pwnet2_fixture

proc logitsFor(r: var Rand): seq[float32] =
  result = newSeq[float32](LogitSize)
  for i in 0..<LogitSize: result[i] = float32(r.rand(4.0) - 2.0)

proc joint(offsets: openArray[float32], whenHead = 2, whenValue = 1, head = 0): JointSampling =
  result = JointSampling(enabled: true, whenHead: whenHead, whenValue: whenValue, head: head)
  for i, x in offsets: result.offsets[i] = x

suite "joint sampling (jointSelect)":
  test "the condition false changes nothing and takes no draw":
    var r = initRand(1)
    let lg = r.logitsFor()
    var rng = initRng(7, 11'u64)
    let before = rng.state
    var actions = [5'i32, 3, 0, 1, 0]
    let j = joint(newSeq[float32](51))
    check not jointSelect(lg, j, default(array[0, bool]), 1'f32, rng, actions)
    check actions == [5'i32, 3, 0, 1, 0] and rng.state == before

  test "temperature 0 takes the argmax of logits + offsets among the allowed, with no draw":
    var r = initRand(2)
    let lg = r.logitsFor()
    var offsets = newSeq[float32](51)
    offsets[17] = 100
    var rng = initRng(7, 11'u64)
    let before = rng.state
    var actions = [5'i32, 3, 1, 1, 0]
    check jointSelect(lg, joint(offsets), default(array[0, bool]), 0'f32, rng, actions)
    check actions[0] == 17 and actions[1..4] == [3'i32, 1, 1, 0] and rng.state == before
    var excluded: array[51, bool]
    excluded[17] = true
    actions = [5'i32, 3, 1, 1, 0]
    check jointSelect(lg, joint(offsets), excluded, 0'f32, rng, actions)
    var best = -1
    for i in 0..<51:
      if i != 17 and (best < 0 or lg[i] > lg[best]): best = i
    check actions[0] == best.int32

  test "sampling takes exactly one draw and follows softmax((logits + offsets) / T)":
    var r = initRand(3)
    var lg = newSeq[float32](LogitSize)
    for i in 0..<51: lg[i] = float32(r.rand(1.0))
    var offsets = newSeq[float32](51)
    offsets[0] = 3; offsets[4] = -1000
    let t = 0.8'f32
    var rng = initRng(9, 13'u64)
    var counts = newSeq[int](51)
    const n = 60000
    for k in 0..<n:
      var probe = rng
      discard probe.next()
      var actions = [1'i32, 0, 1, 0, 0]
      check jointSelect(lg, joint(offsets), default(array[0, bool]), t, rng, actions)
      check rng.state == probe.state         # one draw
      inc counts[actions[0]]
    var total = 0.0
    for i in 0..<51: total += exp((float64(lg[i]) + float64(offsets[i])) / float64(t))
    check counts[4] == 0
    for i in [0, 1, 2, 30]:
      let p = exp((float64(lg[i]) + float64(offsets[i])) / float64(t)) / total
      check abs(float64(counts[i]) / n - p) < 5 * sqrt(p * (1 - p) / n) + 1e-4

  test "a condition on another head or value, and a movement head as the condition":
    var r = initRand(4)
    let lg = r.logitsFor()
    var offsets = newSeq[float32](25)
    offsets[9] = 500
    var rng = initRng(1, 1'u64)
    var actions = [0'i32, 3, 0, 1, 0]
    check jointSelect(lg, joint(offsets, whenHead = 0, whenValue = 0, head = 1), default(array[0, bool]), 0'f32, rng, actions)
    check actions[1] == 9
    actions = [2'i32, 3, 0, 1, 0]
    check not jointSelect(lg, joint(offsets, whenHead = 0, whenValue = 0, head = 1), default(array[0, bool]), 0'f32, rng, actions)

suite "joint sampling (manifest and hosted seat)":
  proc parses(text: string): string =
    try:
      discard parseJointSampling(parseJson(text))
      "ok"
    except ValueError as e: e.msg

  proc zeros(n: int, at = -1, v = 0.0): string =
    var xs: seq[string]
    for i in 0..<n: xs.add(if i == at: $v else: "0")
    "[" & xs.join(", ") & "]"

  test "the parser accepts well-formed options and rejects the rest":
    check parses("""{"when": {"head": 2, "value": 1}, "head": 0, "offsets": """ & zeros(51, 0, 5.5) & "}") == "ok"
    check parses("""{"when": {"head": 0, "value": 50}, "head": 1, "offsets": """ & zeros(25) & "}") == "ok"
    check "differ" in parses("""{"when": {"head": 0, "value": 1}, "head": 0, "offsets": """ & zeros(51) & "}")
    check "choice of head" in parses("""{"when": {"head": 2, "value": 2}, "head": 0, "offsets": """ & zeros(51) & "}")
    check "must list 51" in parses("""{"when": {"head": 2, "value": 1}, "head": 0, "offsets": """ & zeros(25) & "}")
    check "within" in parses("""{"when": {"head": 2, "value": 1}, "head": 0, "offsets": """ & zeros(51, 3, 1001.0) & "}")
    check "needs" in parses("""{"when": {"head": 2, "value": 1}, "head": 0}""")
    check "needs head and value" in parses("""{"when": {"head": 2}, "head": 0, "offsets": """ & zeros(51) & "}")
    check "unknown" in parses("""{"when": {"head": 2, "value": 1}, "head": 0, "offsets": """ & zeros(51) & """, "t": 1}""")
    check "head index" in parses("""{"when": {"head": 5, "value": 1}, "head": 0, "offsets": """ & zeros(51) & "}")
    check "numbers" in parses("""{"when": {"head": 2, "value": 1}, "head": 0, "offsets": """ & "[" & repeat("\"0\", ", 50) & "\"0\"]}")

  const Source = """
paintbot_observe(neuralObservation())
run_neural_net(neuralModel(), neuralObservation(), neuralLogits(), neuralState())
paintbot_act(neuralLogits())
"""
  proc seats(decoder: string): array[Seats, Bot] =
    var r = initRand(77)
    let (model, _, _, _) = r.pwnet001(ObservationSize, 64)
    let path = getTempDir()/("paintbot-neural-joint-" & $getCurrentProcessId() & ".bas")
    writeFile(path, Source)
    writeFile(path & ".model.bin", model)
    writeFile(path & ".neural.json", "{\"schema\": \"paintbot-neural-basic/2\", \"observation_contract\": \"" &
      ObservationContractHash & "\", \"action_contract\": \"" & ActionContractHash & "\", \"sha256\": {}, " &
      "\"decoder\": " & decoder & "}")
    defer:
      for suffix in ["", ".model.bin", ".neural.json"]: removeFile(path & suffix)
    loadBots(@[BotGroup(path: path, count: Seats)])

  test "a sampled seat: a shoot draw always stands (offset +1000 on movement 0), and the log names the option":
    let stand = """{"sampling": {"mode": "categorical"}, "forbid_objectives": [9, 10], "joint_sampling": """ &
      """{"when": {"head": 2, "value": 1}, "head": 0, "offsets": """ & zeros(51, 0, 1000.0) & "}}"
    let players = seats(stand)
    require not players[0].failed
    var w = newWorld(2031)
    var shots, moves = 0
    for tick in 0..<120:
      let commands = players.decide(w)
      for slot in 0..<Seats:
        require not players[slot].failed
        let n = players[slot].neural
        if w.cogs[slot].hp <= 0 or not n.sampled: continue
        if n.selected[2] == 1:
          inc shots
          check n.selected[0] == 0
        elif n.selected[0] != 0: inc moves
      w.step(commands)
    check shots > 50 and moves > 50
    check players[0].neural.jointDraws > 0
    check (" joint_sampling=h2=1->h0 held=" & $players[0].neural.jointDraws) in players[0].neural.telemetry(1, 120)

  test "argmax seats: the option applies at temperature 0; without it nothing changes":
    let plain = seats("""{"fire_hold_teammates": true}""")
    let withJoint = seats("""{"fire_hold_teammates": true, "joint_sampling": {"when": {"head": 3, "value": 0}, """ &
      """"head": 4, "offsets": [0, 0]}}""")
    var a = newWorld(5)
    var b = newWorld(5)
    for tick in 0..<200:
      let ca = plain.decide(a)
      let cb = withJoint.decide(b)
      a.step(ca); b.step(cb)
    # Zero offsets at temperature 0 re-select the same argmax: the match is hash-identical.
    check a.stateHash() == b.stateHash()
    check "joint_sampling=h3=0->h4" in withJoint[0].neural.telemetry(1, 200)
    check "joint_sampling" notin plain[0].neural.telemetry(1, 200)
