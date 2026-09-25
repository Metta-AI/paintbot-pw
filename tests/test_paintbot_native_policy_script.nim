## Policy-script seats in the training library (PLAN-neural-basic-io part C): a bundle's
## policy.bas and manifest drive a seat with the trainer's logits, and play exactly as the
## hosted seat plays the same bundle. Synthetic actor (seeded random weights) only.
## Build with --mm:arc --threads:on -d:pwTraining.
import std/[unittest, os, random, strutils]
import polyworld/[cli, basic]
import ../examples/paintbot/[sim, neural_contract, neural_actor, native_env, bots]

when not defined(pwTraining): {.error: "native policy scripts exist only under -d:pwTraining".}

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

proc setPolicy(handle: pointer, seat: int, source, manifest: string): cint =
  pw_set_seat_policy_script(handle, seat.cint, cbuf(source), source.len.int32, cbuf(manifest), manifest.len.int32)
proc setScript(handle: pointer, seat: int, source: string): cint =
  pw_set_seat_script(handle, seat.cint, cbuf(source), source.len.int32)

const
  K = 2
  Manifest = """{"schema": "paintbot-neural-basic/2", "observation_contract": "$1",
 "action_contract": "$2", "sha256": {},
 "decoder": {"sampling": {"mode": "categorical", "temperature": 0.9}, "forbid_objectives": [3],
  "strafe_legs": {}, "aim_retarget": {}, "shot_gate": {}, "spray_aim": {}, "steady_shot": {},
  "fire_hold_teammates": {"radius": 150}},
 "user_inputs": {"count": 2, "init": [1500, -700]}}"""
  # Every part at once: goal inputs written from BASIC, a BASIC mask and a state-dependent
  # temperature, the head-level phase, a command edit, the issue.
  Policy = """
if worldTick mod 50 = 0 then
  neuralInput(0, selfX + worldTick)
  neuralInput(1, heartY - selfY)
end if
neuralMask(0, 1536)
if selfHp < 3 then
  neuralTemperature(-1, 0)
end if
if carrying then
  neuralTemperature(1, 400)
end if
paintbot_observe(neuralObservation())
run_neural_net(neuralModel(), neuralObservation(), neuralLogits(), neuralState())
neuralSample()
if neuralChoice(2) = 1 and neuralObs(8) > 900 then
  neuralSetChoice(2, 0)
end if
neuralDecode()
cmdSet(6, 0)
neuralIssue()
"""

proc hostRun(model, manifest: string, seed: int32, ticks: int, policySeats: set[int8]):
    (seq[uint32], seq[array[Seats, array[ActionSizes.len, int32]]], seq[array[Seats, bool]], seq[array[Seats, seq[int32]]]) =
  ## The game's own loop over staged bundle files: policy seats run the bundle, the rest base.bas.
  let path = getTempDir()/("paintbot-policy-host-" & $getCurrentProcessId() & ".bas")
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
    let commands = players.decide(w)
    deliverSpeech(w)
    var selected: array[Seats, array[ActionSizes.len, int32]]
    var sampled: array[Seats, bool]
    var inputs: array[Seats, seq[int32]]
    for slot in 0..<Seats:
      if slot.int8 notin policySeats: continue
      check not players[slot].failed
      selected[slot] = players[slot].neural.selected
      sampled[slot] = players[slot].neural.sampled
      inputs[slot] = players[slot].neural.userInputs
    w.step(commands)
    result[0].add w.stateHash()
    result[1].add selected
    result[2].add sampled
    result[3].add inputs

suite "Native policy-script seats":
  configureRules(NativeRules)
  let baseSource = readFile(Base)
  let contract = UserInputsContractHashes[K-1]
  let manifest = Manifest % [contract, ActionContractV2Hash]
  let model = randomModel(3, ObservationSizeV2 + K, contract)

  test "arguments, contracts, status codes and the pw_step guard":
    check pw_create_observation_inputs(1, 100, -1) == nil
    check pw_create_observation_inputs(1, 100, 33) == nil
    let zero = pw_create_observation_inputs(1, 100, 0)
    check pw_handle_observation_size(zero) == ObservationSizeV2 and pw_handle_user_inputs(zero) == 0
    pw_destroy(zero)
    let handle = pw_create_observation_inputs(1, 100, K)
    require handle != nil
    check pw_handle_observation_size(handle) == ObservationSizeV2 + K
    check pw_handle_user_inputs(handle) == K
    check pw_observation_contract(handle) == 2
    var hash: array[65, char]
    check pw_user_inputs_contract_hash(K, cast[ptr UncheckedArray[char]](addr hash[0]), 65) == 0
    check $cast[cstring](addr hash[0]) == contract
    check pw_user_inputs_contract_hash(0, cast[ptr UncheckedArray[char]](addr hash[0]), 65) == -1
    check pw_user_inputs_contract_hash(33, cast[ptr UncheckedArray[char]](addr hash[0]), 65) == -1
    check pw_set_seat_policy_script(nil, 0, nil, 0, nil, 0) == -1
    check setPolicy(handle, 16, Policy, manifest) == -1
    var message: array[256, char]
    let msg = cast[ptr UncheckedArray[char]](addr message[0])
    # A manifest for another observation contract, a bad user_inputs, a bad decoder: rejected (2).
    check setPolicy(handle, 0, Policy, Manifest % [ObservationContractV2Hash, ActionContractV2Hash]) == 2
    check pw_seat_script_status(handle, 0, msg, 256) == 2
    check ($cast[cstring](msg)).startsWith("policy manifest rejected: manifest observation contract")
    check setPolicy(handle, 0, Policy, manifest.replace("[1500, -700]", "[1500]")) == 2
    check setPolicy(handle, 0, Policy, manifest.replace("\"steady_shot\": {}", "\"steady\": {}")) == 2
    check setPolicy(handle, 0, Policy, "") == 2
    check setPolicy(handle, 0, "walkTo(", manifest) == 1
    check setPolicy(handle, 0, Policy, manifest) == 0
    check pw_seat_script_status(handle, 0, nil, 0) == 1
    var actions: array[Seats*ActionSizes.len, int32]
    var logits: array[Seats*LogitSize, float32]
    var rewards, terminals: array[Seats, float32]
    check pw_step(handle, ibuf(actions), fbuf(rewards), fbuf(terminals)) == -4
    check pw_script_decide(handle) == -4
    check pw_step_logits(handle, ibuf(actions), nil, fbuf(rewards), fbuf(terminals)) == -1
    check pw_step_logits(handle, ibuf(actions), fbuf(logits), fbuf(rewards), fbuf(terminals)) == 0
    var choices: array[22, int32]
    check pw_seat_policy_choices(handle, 1, ibuf(choices)) == -1
    check pw_seat_policy_choices(handle, 0, ibuf(choices)) == 0
    check choices[0] == 1
    check choices[16] == (1536 or 8) and choices[17] == 0     # BASIC mask 9, 10 + manifest forbid 3
    for head in 1..4: check choices[17+head] == 0
    check choices[11] == 900 and choices[12] == 900          # the manifest's 0.9 (hp 3, not carrying)
    # A plain script replaces the policy seat; removing it re-enables pw_step.
    check setScript(handle, 0, "walkTo(selfX, selfY)\n") == 0
    check pw_seat_policy_choices(handle, 0, ibuf(choices)) == -1
    check pw_step(handle, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
    check setPolicy(handle, 0, Policy, manifest) == 0
    check setPolicy(handle, 0, "", "") == 0
    check pw_seat_script_status(handle, 0, nil, 0) == 0
    check pw_step(handle, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
    pw_destroy(handle)

  test "training == host: trainer logits through pw_step_logits replay the hosted bundle tick for tick":
    let actor = loadActor(model)
    for (seed, ticks, seats) in [(11'i32, 900, {0'i8, 1, 2, 3, 4, 5, 6, 7}), (12'i32, 900, {0'i8, 3, 8, 13}),
                                 (13'i32, 700, {0'i8..15'i8})]:
      checkpoint "seed " & $seed
      let (expected, selected, sampled, inputs) = hostRun(model, manifest, seed, ticks, seats)
      let handle = pw_create_observation_inputs(seed, ticks.int32, K)
      require handle != nil
      for slot in 0..<Seats:
        if slot.int8 in seats: require setPolicy(handle, slot, Policy, manifest) == 0
        else: require setScript(handle, slot, baseSource) == 0
      let n = ObservationSizeV2 + K
      for pass in 0..1:
        if pass == 1: check pw_reset(handle, seed, ticks.int32) == 0
        # The trainer's side: the actor on each seat's pw_observe row, its state reset by
        # the hosted rule (dead, or alive after death, or a new match).
        var states: array[Seats, seq[float32]]
        var alive: array[Seats, bool]
        for slot in 0..<Seats: states[slot] = newSeq[float32](actor.hiddenSize)
        var observations = newSeq[float32](Seats*n)
        var resets: array[Seats, float32]
        var actions: array[Seats*ActionSizes.len, int32]
        var logits: array[Seats*LogitSize, float32]
        var rewards, terminals: array[Seats, float32]
        var respawns = 0
        for t, hash in expected:
          require pw_observe(handle, fbuf(observations), fbuf(resets)) == 0
          for slot in 0..<Seats:
            if slot.int8 notin seats: continue
            if t > 0:
              # The observation's user-input tail is what the seat's script left last tick.
              for i in 0..<K: require observations[slot*n+ObservationSizeV2+i] == userInputFeature(inputs[t-1][slot][i])
            else:
              check observations[slot*n+ObservationSizeV2] == 1.5'f32 and observations[slot*n+ObservationSizeV2+1] == -0.7'f32
          for slot in 0..<Seats:
            if slot.int8 in seats: continue
            for i in 0..<K: require observations[slot*n+ObservationSizeV2+i] == 0
          # Liveness from the observation's own hp feature (column 2 = hp / 3).
          for slot in 0..<Seats:
            if slot.int8 notin seats: continue
            let isAlive = observations[slot*n+2] > 0
            if not isAlive or not alive[slot] or t == 0:
              for i in 0..<actor.hiddenSize: states[slot][i] = 0
            if isAlive and not alive[slot] and t > 0: inc respawns
            alive[slot] = isAlive
            if isAlive:
              var output = newSeq[float32](LogitSize)
              actor.infer(observations.toOpenArray(slot*n, slot*n+n-1), states[slot], output)
              for i in 0..<LogitSize: logits[slot*LogitSize+i] = output[i]
          require pw_step_logits(handle, ibuf(actions), fbuf(logits), fbuf(rewards), fbuf(terminals)) == 0
          require pw_state_hash(handle) == hash
          for slot in 0..<Seats:
            if slot.int8 notin seats: continue
            var choices: array[22, int32]
            require pw_seat_policy_choices(handle, slot.cint, ibuf(choices)) == 0
            require (choices[0] == 1) == sampled[t][slot]
            if sampled[t][slot]:
              for head in 0..<ActionSizes.len: require choices[1+head] == selected[t][slot][head]
        for slot in 0..<Seats: check pw_seat_script_status(handle, slot.cint, nil, 0) == 1
        check respawns > 0
      pw_destroy(handle)
