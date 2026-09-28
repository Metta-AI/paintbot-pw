## Native training ABI, observation contract v3 and v3u<K>: chosen at create, rows of 514
## (+ K) floats, identical to the reference encoder and to the hosted seat's own observation;
## the world (and its hash) never depends on it. Synthetic actor (seeded random weights) only.
## Build with --mm:arc --threads:on -d:pwTraining.
import std/[unittest, os, random, strutils]
import polyworld/[cli, basic]
import ../examples/paintbot/[sim, neural_contract, neural_actor, native_env, bots]

when not defined(pwTraining): {.error: "the native library exists only under -d:pwTraining".}

const Root = currentSourcePath().parentDir.parentDir
const Base = Root / "coworld/paintbot/players/base.bas"
type Buffer = ptr UncheckedArray[cfloat]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])
template ibuf(a: untyped): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr a[0])
template cbuf(s: string): ptr UncheckedArray[char] =
  (if s.len > 0: cast[ptr UncheckedArray[char]](unsafeAddr s[0]) else: nil)

proc u32(s: var string, value: uint32) =
  for i in 0..3: s.add char((value shr (8*i)) and 255)
proc randomModel(seed: int, inputs: int, observationContract: string): string =
  const h = 64
  var r = initRand(seed)
  result = "PWNET001"
  let n = inputs*h + 3*h*h + LogitSize*h
  for x in [1,inputs,h,LogitSize,ActionSizes.len,n]: result.u32(x.uint32)
  result.add observationContract
  result.add ActionContractV2Hash
  for x in ActionSizes: result.u32(x.uint32)
  for i in 0..<n:
    let scale = if i < inputs*h: 0.08 elif i < inputs*h + 3*h*h: 0.15 else: 0.6
    result.u32(cast[uint32](float32(r.rand(2.0) - 1.0) * float32(scale)))

proc hashText(f: proc(output: ptr UncheckedArray[char]): cint): (cint, string) =
  var text: array[65, char]
  let code = f(cast[ptr UncheckedArray[char]](addr text[0]))
  (code, (if code == 0: $cast[cstring](addr text[0]) else: ""))

proc setPolicy(handle: pointer, seat: int, source, manifest: string): cint =
  pw_set_seat_policy_script(handle, seat.cint, cbuf(source), source.len.int32, cbuf(manifest), manifest.len.int32)
proc setScript(handle: pointer, seat: int, source: string): cint =
  pw_set_seat_script(handle, seat.cint, cbuf(source), source.len.int32)

const
  K = 3
  Manifest = """{"schema": "paintbot-neural-basic/2", "observation_contract": "$1",
 "action_contract": "$2", "sha256": {},
 "decoder": {"sampling": {"mode": "categorical", "temperature": 0.9}},
 "user_inputs": {"count": 3, "init": [1500, -700, 42]}}"""
  Policy = """
if worldTick mod 7 = 0 then
  neuralInput(0, selfX + worldTick)
  neuralInput(1, heartY - selfY)
end if
neuralInput(2, livesLeft * 100 + selfHp)
paintbot_observe(neuralObservation())
run_neural_net(neuralModel(), neuralObservation(), neuralLogits(), neuralState())
neuralSample()
neuralDecode()
neuralIssue()
"""

proc hostRun(model, manifest: string, seed: int32, ticks: int, policySeats: set[int8]):
    (seq[uint32], seq[array[Seats, seq[float32]]]) =
  ## The game's own loop over staged bundle files: policy seats run the bundle, the rest
  ## base.bas. Per tick: the world hash after the step, and each policy seat's observation
  ## (empty when its script did not run that tick: dead).
  let path = getTempDir()/("paintbot-obs-v3-host-" & $getCurrentProcessId() & ".bas")
  writeFile(path, Policy)
  writeFile(path & ".model.bin", model)
  writeFile(path & ".neural.json", manifest)
  defer:
    for suffix in ["", ".model.bin", ".neural.json"]: removeFile(path & suffix)
  resetOracle()
  var players: array[Seats, Bot]
  let neural = loadBots(@[BotGroup(path: path, count: Seats)])
  let plain = loadBots(@[BotGroup(path: Base, count: Seats)])
  for slot in 0..<Seats: players[slot] = if slot.int8 in policySeats: neural[slot] else: plain[slot]
  var w = newWorld(seed, ticks.int32)
  while w.tick < ticks and w.winner == -1:
    var alive: array[Seats, bool]
    for slot in 0..<Seats: alive[slot] = w.cogs[slot].hp > 0
    let commands = players.decide(w)
    deliverSpeech(w)
    var observed: array[Seats, seq[float32]]
    for slot in 0..<Seats:
      if slot.int8 notin policySeats: continue
      check not players[slot].failed
      if alive[slot]: observed[slot] = players[slot].neural.observation
    w.step(commands)
    result[0].add w.stateHash()
    result[1].add observed

suite "Native observation contract v3":
  test "version selection, sizes, hashes and invalid arguments":
    check pw_observation_size_for(3) == 514
    check pw_observation_size_for(1) == 448 and pw_observation_size_for(2) == 506 and
      pw_observation_size_for(101) == 810
    check pw_observation_size_for(4) == -1 and pw_observation_size_for(0) == -1
    check pw_create_observation(1, 24, 4) == nil
    check pw_create_observation(1, HeartMeterMatchTicks+1, 3) == nil
    check hashText(proc(o: ptr UncheckedArray[char]): cint = pw_observation_contract_hash(3, o, 65)) ==
      (0.cint, ObservationContractV3Hash)
    check hashText(proc(o: ptr UncheckedArray[char]): cint = pw_observation_contract_hash(3, o, 64))[0] == -1
    check hashText(proc(o: ptr UncheckedArray[char]): cint = pw_observation_contract_hash(2, o, 65)) ==
      (0.cint, ObservationContractV2Hash)
    let three = pw_create_observation(5, 24, 3)
    require three != nil
    check pw_observation_contract(three) == 3 and pw_handle_observation_size(three) == 514
    check pw_handle_user_inputs(three) == 0
    check pw_reset(three, 6, 24) == 0 # kept across reset
    check pw_observation_contract(three) == 3 and pw_handle_observation_size(three) == 514
    # v3 is the teams game's: FFA-kin is refused on a v3 handle, allowed on the others.
    check pw_set_game_mode(three, 1) == -1
    check pw_set_game_mode(three, 0) == 0
    let two = pw_create_observation(5, 24, 2)
    check pw_set_game_mode(two, 1) == 0
    pw_destroy(three); pw_destroy(two)

  test "v3u<K> handles and hashes; version 2 is pw_create_observation_inputs":
    check pw_create_observation_inputs_v(1, 100, 1, 3) == nil
    check pw_create_observation_inputs_v(1, 100, 101, 3) == nil
    check pw_create_observation_inputs_v(1, 100, 3, -1) == nil
    check pw_create_observation_inputs_v(1, 100, 3, 65) == nil
    check pw_create_observation_inputs_v(1, HeartMeterMatchTicks+1, 3, 3) == nil
    for k in [1'i32, 3, 32, 63, 64]:
      let h3 = pw_create_observation_inputs_v(1, 100, 3, k)
      let h2 = pw_create_observation_inputs_v(1, 100, 2, k)
      require h3 != nil and h2 != nil
      check pw_observation_contract(h3) == 3 and pw_handle_user_inputs(h3) == k
      check pw_handle_observation_size(h3) == 514 + k
      check pw_observation_contract(h2) == 2 and pw_handle_user_inputs(h2) == k
      check pw_handle_observation_size(h2) == 506 + k
      check pw_set_game_mode(h3, 1) == -1
      check hashText(proc(o: ptr UncheckedArray[char]): cint = pw_user_inputs_contract_hash_v(3, k, o, 65)) ==
        (0.cint, V3UserInputsContractHashes[k-1])
      check hashText(proc(o: ptr UncheckedArray[char]): cint = pw_user_inputs_contract_hash_v(2, k, o, 65)) ==
        hashText(proc(o: ptr UncheckedArray[char]): cint = pw_user_inputs_contract_hash(k, o, 65))
      pw_destroy(h3); pw_destroy(h2)
    for (v, k) in [(3'i32, 0'i32), (3'i32, 65'i32), (1'i32, 3'i32), (101'i32, 3'i32)]:
      check hashText(proc(o: ptr UncheckedArray[char]): cint = pw_user_inputs_contract_hash_v(v, k, o, 65))[0] == -1
    check hashText(proc(o: ptr UncheckedArray[char]): cint = pw_user_inputs_contract_hash_v(3, 3, o, 64))[0] == -1
    let zero = pw_create_observation_inputs_v(1, 100, 3, 0)
    check pw_observation_contract(zero) == 3 and pw_handle_observation_size(zero) == 514 and
      pw_handle_user_inputs(zero) == 0
    pw_destroy(zero)

  test "v3 rows equal the reference encoder over random seeds and ticks; v2 and v3 handles step hash for hash":
    let seeds = parseInt(getEnv("PW_PARITY_SEEDS", "4"))
    var r = initRand(20260928)
    var rows = 0
    for n in 0..<seeds:
      let seed = int32(r.rand(1_000_000))
      let ticks = 240 + r.rand(1200)
      configureRules(NativeRules)
      var reference = newWorld(seed, ticks.int32)
      let v2 = pw_create_observation(seed, ticks.int32, 2)
      let v3 = pw_create_observation(seed, ticks.int32, 3)
      let v3u = pw_create_observation_inputs_v(seed, ticks.int32, 3, 5)
      require v2 != nil and v3 != nil and v3u != nil
      var actions: array[Seats*ActionSizes.len, int32]
      var commands: array[Seats, Command]
      var rewards, terminals, resets2, resets3, resetsU: array[Seats, float32]
      var obs2 = newSeq[float32](Seats*ObservationSizeV2)
      var obs3 = newSeq[float32](Seats*ObservationSizeV3)
      var obsU = newSeq[float32](Seats*(ObservationSizeV3+5))
      var expected: array[ObservationSizeV3, float32]
      let every = 1 + r.rand(15)
      while reference.winner == -1 and reference.tick < reference.endTick:
        if reference.tick mod every == 0:
          require pw_observe(v2, fbuf(obs2), fbuf(resets2)) == 0
          require pw_observe(v3, fbuf(obs3), fbuf(resets3)) == 0
          require pw_observe(v3u, fbuf(obsU), fbuf(resetsU)) == 0
          check resets2 == resets3 and resets3 == resetsU
          for slot in 0..<Seats:
            encodeObservation(reference, slot, expected, ocV3)
            for i in 0..<ObservationSizeV3:
              require obs3[slot*ObservationSizeV3+i] == expected[i]
              require obsU[slot*(ObservationSizeV3+5)+i] == expected[i]
            for i in 0..<5: require obsU[slot*(ObservationSizeV3+5)+ObservationSizeV3+i] == 0
            for i in 0..<ObservationSizeV2: require obs2[slot*ObservationSizeV2+i] == expected[i]
            inc rows
        for slot in 0..<Seats:
          let offset = slot*ActionSizes.len
          trainingBotActions(reference, slot, 2, actions.toOpenArray(offset, offset+ActionSizes.len-1))
          commands[slot] = decodeActions(reference, slot, actions.toOpenArray(offset, offset+ActionSizes.len-1))
        reference.step(commands)
        for h in [v2, v3, v3u]:
          require pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
          require pw_state_hash(h) == reference.stateHash()
      pw_destroy(v2); pw_destroy(v3); pw_destroy(v3u)
    check rows > 0

  test "pw_observe_seats writes only the chosen v3 rows":
    let handle = pw_create_observation(9, 24, 3)
    var obs = newSeq[float32](Seats*ObservationSizeV3)
    var resets: array[Seats, float32]
    for i in 0..<obs.len: obs[i] = -9
    for i in 0..<resets.len: resets[i] = -9
    check pw_observe_seats(handle, (1'u32 shl 4) or (1'u32 shl 11), fbuf(obs), fbuf(resets)) == 0
    configureRules(NativeRules)
    let w = newWorld(9, 24)
    var expected: array[ObservationSizeV3, float32]
    for slot in 0..<Seats:
      if slot in [4, 11]:
        encodeObservation(w, slot, expected, ocV3)
        for i in 0..<ObservationSizeV3: check obs[slot*ObservationSizeV3+i] == expected[i]
        check resets[slot] == 1
      else:
        for i in 0..<ObservationSizeV3: check obs[slot*ObservationSizeV3+i] == -9
    pw_destroy(handle)

  test "training == host on v3u<K>: every policy seat's pw_observe row is the hosted seat's observation":
    configureRules(NativeRules)
    let baseSource = readFile(Base)
    let contract = V3UserInputsContractHashes[K-1]
    let manifest = Manifest % [contract, ActionContractV2Hash]
    let model = randomModel(3, ObservationSizeV3 + K, contract)
    let actor = loadActor(model)
    let n = ObservationSizeV3 + K
    var r = initRand(7)
    var compared = 0
    for (seed, ticks, seats) in [(31'i32, 900, {0'i8, 1, 2, 3, 4, 5, 6, 7}), (int32(r.rand(100_000)), 700, {0'i8, 3, 8, 13}),
                                 (int32(r.rand(100_000)), 600, {0'i8..15'i8})]:
      checkpoint "seed " & $seed
      let (expected, observed) = hostRun(model, manifest, seed, ticks, seats)
      let handle = pw_create_observation_inputs_v(seed, ticks.int32, 3, K)
      require handle != nil
      # A manifest naming v2u<K> is not this handle's contract.
      check setPolicy(handle, 0, Policy, Manifest % [UserInputsContractHashes[K-1], ActionContractV2Hash]) == 2
      for slot in 0..<Seats:
        if slot.int8 in seats: require setPolicy(handle, slot, Policy, manifest) == 0
        else: require setScript(handle, slot, baseSource) == 0
      var states: array[Seats, seq[float32]]
      var alive: array[Seats, bool]
      for slot in 0..<Seats: states[slot] = newSeq[float32](actor.hiddenSize)
      var observations = newSeq[float32](Seats*n)
      var resets: array[Seats, float32]
      var actions: array[Seats*ActionSizes.len, int32]
      var logits: array[Seats*LogitSize, float32]
      var rewards, terminals: array[Seats, float32]
      for t, hash in expected:
        require pw_observe(handle, fbuf(observations), fbuf(resets)) == 0
        for slot in 0..<Seats:
          if slot.int8 notin seats:
            for i in 0..<K: require observations[slot*n+ObservationSizeV3+i] == 0
            continue
          if observed[t][slot].len > 0:
            require observed[t][slot].len == n
            for i in 0..<n: require observations[slot*n+i] == observed[t][slot][i]
            inc compared
        for slot in 0..<Seats:
          if slot.int8 notin seats: continue
          let isAlive = observations[slot*n+2] > 0
          if not isAlive or not alive[slot] or t == 0:
            for i in 0..<actor.hiddenSize: states[slot][i] = 0
          alive[slot] = isAlive
          if isAlive:
            var output = newSeq[float32](LogitSize)
            actor.infer(observations.toOpenArray(slot*n, slot*n+n-1), states[slot], output)
            for i in 0..<LogitSize: logits[slot*LogitSize+i] = output[i]
        require pw_step_logits(handle, ibuf(actions), fbuf(logits), fbuf(rewards), fbuf(terminals)) == 0
        require pw_state_hash(handle) == hash
      for slot in 0..<Seats: check pw_seat_script_status(handle, slot.cint, nil, 0) == 1
      pw_destroy(handle)
    check compared > 5000
