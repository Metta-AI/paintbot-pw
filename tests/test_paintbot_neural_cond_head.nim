## COND_HEAD (PWNET002 layer 13): a learned conditional action head. The model carries W [size(head),
## size(whenHead)]; after the tick's selection the host selects `head` again from its logits plus column a of W
## (a = the choice selected for `whenHead`), under the head's mask and temperature (argmax at 0, else one draw).
## Covers the selection rule (the same draw as decoder.joint_sampling with that column as offsets), its
## distribution, the loader's rules and cost, the hosted seat, and the training library's policy seat fed the
## same W through pw_set_seat_conditionals (tick-for-tick hash equality). Synthetic weights only.
## Build with --mm:arc --threads:on -d:pwTraining.
import std/[unittest, os, random, strutils, math]
import polyworld/[cli, rngs]
import ../examples/paintbot/[sim, neural_contract, neural_actor, neural_host, native_env, bots]
import paintbot_pwnet2_fixture

when not defined(pwTraining): {.error: "the policy-seat part needs -d:pwTraining".}

type Buffer = ptr UncheckedArray[cfloat]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])
template ibuf(a: untyped): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr a[0])
template cbuf(s: string): ptr UncheckedArray[char] =
  (if s.len > 0: cast[ptr UncheckedArray[char]](unsafeAddr s[0]) else: nil)

proc rejects(data: string, fragment: string): bool =
  try:
    discard loadActor(data)
    false
  except ValueError as e:
    fragment in e.msg

proc logitsFor(r: var Rand): seq[float32] =
  result = newSeq[float32](LogitSize)
  for i in 0..<LogitSize: result[i] = float32(r.rand(4.0) - 2.0)

proc standWhenFiring(r: var Rand): seq[float32] =
  ## W [51, 2] for COND_HEAD(2 -> 0): column 0 (no shot) small noise, column 1 (shot) +1000 on movement 0.
  result = newSeq[float32](51*2)
  for j in 0..<51:
    result[j*2] = float32(r.rand(0.6) - 0.3)
    result[j*2+1] = if j == 0: 1000'f32 else: float32(r.rand(0.6) - 0.3)

proc condModel(r: var Rand, cond: seq[Spec], hidden = 64): string =
  ## DENSE -> MINGRU(highway) -> DENSE over observation contract teams.view.1, then the COND_HEAD layers.
  var specs = @[r.dense(TeamsViewSize, hidden), r.mingru(hidden, hidden, highway = true),
    r.dense(hidden, LogitSize, scale = 0.6/sqrt(hidden.float))]
  for c in cond: specs.add c
  encode2(TeamsViewSize, ActionSizes, specs)

suite "COND_HEAD selection (reselectHead)":
  test "the same selection and draw as decoder.joint_sampling with the column as offsets":
    var r = initRand(1)
    for trial in 0..<400:
      let lg = r.logitsFor()
      let head = [0, 1, 3][trial mod 3]
      let size = ActionSizes[head]
      var offsets = newSeq[float32](size)
      for i in 0..<size: offsets[i] = float32(r.rand(6.0) - 3.0)
      var j = JointSampling(enabled: true, whenHead: 2, whenValue: 1, head: head)
      for i in 0..<size: j.offsets[i] = offsets[i]
      var excluded: array[51, bool]
      if trial mod 4 == 0:
        for i in 0..<size:
          if r.rand(3) == 0: excluded[i] = true
        excluded[r.rand(size-1)] = false
      let t = [0'f32, 0.5, 1, 2.5][trial mod 4]
      var a = initRng(int32(trial), 5'u64)
      var b = a
      var actions = [3'i32, 4, 1, 0, 1]
      check jointSelect(lg, j, excluded.toOpenArray(0, size-1), t, a, actions)
      var offset = 0
      for h in 0..<head: offset += ActionSizes[h]
      check reselectHead(lg, offset, size, offsets, excluded.toOpenArray(0, size-1), t, b) == actions[head]
      check a.state == b.state

  test "argmax at temperature 0 with no draw; one draw and softmax((logits + column) / T) otherwise":
    var r = initRand(2)
    let lg = r.logitsFor()
    var offsets = newSeq[float32](51)
    offsets[17] = 100
    var rng = initRng(7, 11'u64)
    let before = rng.state
    check reselectHead(lg, 0, 51, offsets, default(array[0, bool]), 0'f32, rng) == 17
    check rng.state == before
    var small = newSeq[float32](51)
    for i in 0..<51: small[i] = float32(r.rand(1.0))
    small[4] = -1000
    let t = 0.8'f32
    var counts = newSeq[int](51)
    const n = 60000
    for k in 0..<n:
      var probe = rng
      discard probe.next()
      inc counts[reselectHead(lg, 0, 51, small, default(array[0, bool]), t, rng)]
      check rng.state == probe.state
    var total = 0.0
    for i in 0..<51: total += exp((float64(lg[i]) + float64(small[i])) / float64(t))
    check counts[4] == 0
    for i in [0, 1, 2, 30]:
      let p = exp((float64(lg[i]) + float64(small[i])) / float64(t)) / total
      check abs(float64(counts[i]) / n - p) < 5 * sqrt(p * (1 - p) / n) + 1e-4

suite "COND_HEAD in the model file":
  test "loads, passes the logits through, costs the copy and the column add":
    var r = initRand(3)
    let w = r.standWhenFiring()
    let plain = loadActor(r.condModel(@[]))
    var r2 = initRand(3)
    discard r2.standWhenFiring()
    let actor = loadActor(r2.condModel(@[condHead(2, 0, w)]))
    check actor.conditionals.len == 1
    check actor.conditionals[0].whenHead == 2 and actor.conditionals[0].head == 0
    check actor.conditionals[0].weights == w
    check conditionalOffsets(actor.conditionals[0], 1, ActionSizes)[0] == 1000'f32
    check actor.operationCount == plain.operationCount + LogitSize + 51
    check actor.parameterCount == plain.parameterCount + 102
    check plain.conditionals.len == 0
    var obs = newSeq[float32](TeamsViewSize)
    for i in 0..<obs.len: obs[i] = float32(r.rand(2.0) - 1.0)
    var s1 = newSeq[float32](plain.stateSize)
    var s2 = newSeq[float32](actor.stateSize)
    var l1 = newSeq[float32](LogitSize)
    var l2 = newSeq[float32](LogitSize)
    plain.infer(obs, s1, l1)
    actor.infer(obs, s2, l2)
    check l1 == l2 and s1 == s2

  test "the loader's rules":
    var r = initRand(4)
    let w = r.standWhenFiring()
    check rejects(r.condModel(@[condHead(2, 2, newSeq[float32](4))]), "must differ")
    check rejects(r.condModel(@[condHead(5, 0, newSeq[float32](102))]), "COND_HEAD heads must be")
    check rejects(r.condModel(@[condHead(2, 0, w[0 ..< 100])]), "")
    check rejects(r.condModel(@[condHead(2, 0, w), condHead(3, 0, newSeq[float32](102))]), "already re-selected")
    check rejects(r.condModel(@[condHead(2, 0, w), condHead(0, 2, newSeq[float32](102))]),
      "earlier COND_HEAD's condition")
    var specs = @[r.dense(TeamsViewSize, 64), condHead(2, 0, w), r.mingru(64, 64, highway = true),
      r.dense(64, LogitSize)]
    check rejects(encode2(TeamsViewSize, ActionSizes, specs), "must come after every other layer")
    var nonfinite = w
    nonfinite[5] = Inf.float32
    check rejects(r.condModel(@[condHead(2, 0, nonfinite)]), "nonfinite")
    # A chain is allowed: 2 -> 0 (movement follows the shot), then 0 -> 1 (aim follows the movement).
    let chain = loadActor(r.condModel(@[condHead(2, 0, w), condHead(0, 1, newSeq[float32](25*51))]))
    check chain.conditionals.len == 2

suite "COND_HEAD on the hosted seat and the training policy seat":
  configureRules(NativeRules)
  # The policy selects the heads (neuralSample) and acts through the reference BASIC decode.
  const Source = """
paintbot_observe(neuralObservation())
run_neural_net(neuralModel(), neuralObservation(), neuralLogits(), neuralState())
neuralSample()
""" & staticRead("../examples/paintbot/players/neural_decode.bas")
  proc manifestFor(decoder: string): string =
    "{\"schema\": \"paintbot-neural-basic/2\", \"observation_contract\": \"" & ObservationContractTeamsView1Hash &
      "\", \"action_contract\": \"" & ActionContractTeamsView1Hash & "\", \"sha256\": {}" &
      (if decoder.len > 0: ", \"decoder\": " & decoder else: "") & "}"

  proc seats(model, decoder: string): seq[Bot] =
    let path = getTempDir()/("paintbot-neural-cond-" & $getCurrentProcessId() & ".bas")
    writeFile(path, Source)
    writeFile(path & ".model.bin", model)
    writeFile(path & ".neural.json", manifestFor(decoder))
    defer:
      for suffix in ["", ".model.bin", ".neural.json"]: removeFile(path & suffix)
    loadBots(@[BotGroup(path: path, count: Seats)])

  const Sampled = """{"sampling": {"mode": "categorical"}}"""

  test "a sampled seat: every shot stands (W column 1 = +1000 on movement 0); the log names the heads":
    var r = initRand(5)
    let w = r.standWhenFiring()
    let players = seats(r.condModel(@[condHead(2, 0, w)]), Sampled)
    require not players[0].failed
    var world = newWorld(2031)
    var shots, moves = 0
    for tick in 0..<150:
      let commands = players.decide(world)
      for slot in 0..<Seats:
        require not players[slot].failed
        let n = players[slot].neural
        if world.cogs[slot].hp <= 0 or not n.sampled: continue
        if n.selected[2] == 1:
          inc shots
          check n.selected[0] == 0
        elif n.selected[0] != 0: inc moves
      world.step(commands)
    check shots > 50 and moves > 50
    check players[0].neural.conditionalDraws > 0
    check (" cond_heads=h2->h0 draws=" & $players[0].neural.conditionalDraws) in players[0].neural.telemetry(1, 150)

  test "argmax seats with W = 0 play hash for hash as the model without COND_HEAD":
    var r = initRand(6)
    let model = r.condModel(@[])
    var r2 = initRand(6)
    let withCond = r2.condModel(@[condHead(3, 4, newSeq[float32](4))])
    let a = seats(model, "")
    let b = seats(withCond, "")
    var wa = newWorld(5)
    var wb = newWorld(5)
    for tick in 0..<200:
      let ca = a.decide(wa)
      let cb = b.decide(wb)
      wa.step(ca); wb.step(cb)
    check wa.stateHash() == wb.stateHash()
    check "cond_heads=h3->h4 draws=0" in b[0].neural.telemetry(1, 200)
    check "cond_heads" notin a[0].neural.telemetry(1, 200)

  test "a COND_HEAD twin of a joint_sampling bundle (zero column 0, the offsets as column 1) plays it bitwise":
    var r = initRand(9)
    var offsets = newSeq[float32](51)
    for j in 0..<51: offsets[j] = float32(r.rand(4.0) - 2.0)
    offsets[0] = 3.5
    var w = newSeq[float32](51*2)
    for j in 0..<51: w[j*2+1] = offsets[j]
    var ra = initRand(10)
    let plain = ra.condModel(@[])
    var rb = initRand(10)
    let twin = rb.condModel(@[condHead(2, 0, w)])
    var parts: seq[string]
    for x in offsets: parts.add $x
    let joint = """{"sampling": {"mode": "categorical", "temperature": 0.9}, "joint_sampling": """ &
      """{"when": {"head": 2, "value": 1}, "head": 0, "offsets": [""" & parts.join(", ") & "]}}"
    let a = seats(plain, joint)
    let b = seats(twin, """{"sampling": {"mode": "categorical", "temperature": 0.9}}""")
    require not a[0].failed and not b[0].failed
    var wa = newWorld(77)
    var wb = newWorld(77)
    var held = 0
    for tick in 0..<250:
      let ca = a.decide(wa)
      let cb = b.decide(wb)
      for slot in 0..<Seats:
        require a[slot].neural.sampled == b[slot].neural.sampled
        if a[slot].neural.sampled:
          require a[slot].neural.selected == b[slot].neural.selected
      wa.step(ca); wb.step(cb)
      require wa.stateHash() == wb.stateHash()
    for slot in 0..<Seats: held += a[slot].neural.jointDraws
    check held > 50
    var draws = 0
    for slot in 0..<Seats: draws += b[slot].neural.conditionalDraws
    check draws == held   # a draw exactly where the joint condition held

  test "decoder.joint_sampling and COND_HEAD layers together are rejected":
    var r = initRand(7)
    let joint = """{"joint_sampling": {"when": {"head": 3, "value": 0}, "head": 4, "offsets": [0, 0]}}"""
    let players = seats(r.condModel(@[condHead(2, 0, r.standWhenFiring())]), joint)
    check players[0].failed

  test "training == host: pw_set_seat_conditionals + trainer logits replay the hosted COND_HEAD bundle":
    var r = initRand(8)
    let w = r.standWhenFiring()
    let model = r.condModel(@[condHead(2, 0, w)])
    let actor = loadActor(model)
    const seed = 21'i32
    const ticks = 600
    let policySeats = {0'i8, 2, 5, 9, 12}
    let baseSource = readFile(currentSourcePath().parentDir.parentDir / "coworld/paintbot/players/base.bas")
    # The host.
    let path = getTempDir()/("paintbot-neural-cond-host-" & $getCurrentProcessId() & ".bas")
    writeFile(path, Source)
    writeFile(path & ".model.bin", model)
    writeFile(path & ".neural.json", manifestFor(Sampled))
    resetOracle()
    let neural = loadBots(@[BotGroup(path: path, count: Seats)])
    let plain = loadBots(@[BotGroup(path: currentSourcePath().parentDir.parentDir / "coworld/paintbot/players/base.bas",
      count: Seats)])
    for suffix in ["", ".model.bin", ".neural.json"]: removeFile(path & suffix)
    var players = newSeq[Bot](Seats)
    for slot in 0..<Seats: players[slot] = if slot.int8 in policySeats: neural[slot] else: plain[slot]
    var world = newWorld(seed, ticks.int32)
    var hashes: seq[uint32]
    while world.tick < ticks and world.winner == -1:
      let commands = players.decide(world)
      deliverSpeech(world)
      world.step(commands)
      hashes.add world.stateHash()
    check neural[0].neural.conditionalDraws > 0
    # The training library: policy seats with the same W, fed the actor's logits.
    let handle = pw_create_observation(seed, ticks.int32, 201)
    require handle != nil
    let manifest = manifestFor(Sampled)
    let source = Source
    var pairs = [2'i32, 0]
    var weights = w
    for slot in 0..<Seats:
      if slot.int8 in policySeats:
        require pw_set_seat_policy_script(handle, slot.cint, cbuf(source), source.len.int32, cbuf(manifest),
          manifest.len.int32) == 0
        require pw_set_seat_conditionals(handle, slot.cint, 1, ibuf(pairs), fbuf(weights), weights.len.int32) == 0
      else:
        require pw_set_seat_script(handle, slot.cint, cbuf(baseSource), baseSource.len.int32) == 0
    # Argument and rule checks.
    check pw_set_seat_conditionals(handle, 1, 1, ibuf(pairs), fbuf(weights), weights.len.int32) == -1   # not a policy seat
    check pw_set_seat_conditionals(handle, 0, 1, ibuf(pairs), fbuf(weights), 100) == -2
    var same = [2'i32, 2]
    check pw_set_seat_conditionals(handle, 0, 1, ibuf(same), fbuf(weights), 4) == -2
    let n = TeamsViewSize
    var observations = newSeq[float32](Seats*n)
    var resets: array[LegacySeats, float32]
    var actions: array[LegacySeats*ActionSizes.len, int32]
    var logits: array[LegacySeats*LogitSize, float32]
    var rewards, terminals: array[LegacySeats, float32]
    var states: array[LegacySeats, seq[float32]]
    var alive: array[LegacySeats, bool]
    for slot in 0..<Seats: states[slot] = newSeq[float32](actor.stateSize)
    var shots = 0
    for t, hash in hashes:
      require pw_observe(handle, fbuf(observations), fbuf(resets)) == 0
      for slot in 0..<Seats:
        if slot.int8 notin policySeats: continue
        let isAlive = observations[slot*n+2] > 0
        if not isAlive or not alive[slot] or t == 0:
          for i in 0..<actor.stateSize: states[slot][i] = 0
        alive[slot] = isAlive
        if isAlive:
          var output = newSeq[float32](LogitSize)
          actor.infer(observations.toOpenArray(slot*n, slot*n+n-1), states[slot], output)
          for i in 0..<LogitSize: logits[slot*LogitSize+i] = output[i]
      require pw_step_logits(handle, ibuf(actions), fbuf(logits), fbuf(rewards), fbuf(terminals)) == 0
      require pw_state_hash(handle) == hash
      for slot in 0..<Seats:
        if slot.int8 notin policySeats: continue
        var choices: array[22, int32]
        require pw_seat_policy_choices(handle, slot.cint, ibuf(choices)) == 0
        if choices[0] == 1 and choices[3] == 1:
          inc shots
          check choices[1] == 0   # selected movement after the COND_HEAD: stand
    check shots > 20
    # Cleared with count 0: the seat plays without it from its next selection.
    check pw_set_seat_conditionals(handle, 0, 0, nil, nil, 0) == 0
    pw_destroy(handle)
