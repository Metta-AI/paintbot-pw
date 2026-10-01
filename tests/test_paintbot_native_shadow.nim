## Net-teacher shadow (pw_set_seat_command on a policy seat + pw_seat_decided_orders): a policy seat
## given a raw command still runs its policy.bas on the trainer's logits, so its BASIC state, user
## inputs and sampling advance as if it had acted, while the world executes the raw (student)
## command; pw_seat_decided_orders reads what the program decided. Checked tick for tick against an
## independent hosted loop (the game's own decide / deliverSpeech / step over the staged bundle) in
## which the teacher bot decides on the same world and its order is then replaced by the student's.
## Synthetic actor (seeded random weights). Build with --mm:arc --threads:on -d:pwTraining.
import std/[unittest, os, random, strutils]
import polyworld/[cli, basic]
import ../examples/paintbot/[sim, neural_contract, neural_actor, native_env, bots]

when not defined(pwTraining): {.error: "native policy scripts exist only under -d:pwTraining".}

const Root = currentSourcePath().parentDir.parentDir
const Base = Root / "coworld/paintbot/players/base.bas"
const DecoderSource = staticRead("../examples/paintbot/players/neural_decode.bas")
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
  result.add ActionContractTeamsView1Hash
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
  Teacher = 0
  Manifest = """{"schema": "paintbot-neural-basic/2", "observation_contract": "$1",
 "action_contract": "$2", "sha256": {},
 "decoder": {"sampling": {"mode": "categorical", "temperature": 0.9}},
 "user_inputs": {"count": 2, "init": [1500, -700]}}"""
  # State that must keep advancing under the shadow: a user input written every tick from the
  # program's own running counter, and the reference decode's aim keep.
  Policy = """
dim shadowTicks(1)
shadowTicks(0) = shadowTicks(0) + 1
neuralInput(0, shadowTicks(0))
neuralInput(1, selfX)
paintbot_observe(neuralObservation())
run_neural_net(neuralModel(), neuralObservation(), neuralLogits(), neuralState())
neuralSample()
""" & DecoderSource

proc student(t: int): array[9, int32] =
  ## The raw command the student "plays" on tick t: a wandering walk goal (verbatim), an aim inside
  ## the map (so the engine's clamp is the identity), a shot every 7th tick.
  let gx = int32(((t * 137) mod 3000) - 1500)
  let gz = int32(((t * 71) mod 3000) - 1500)
  [1'i32, gx, gz, int32(t mod 7 == 0), gz div 2, gx div 2, 0, int32(t mod 11 == 0), 0]

proc toCommand(c: array[9, int32]): Command =
  Command(walk: c[0] == 1, goal: Point(x: c[1], z: c[2]), shoot: c[3] == 1, aim: Point(x: c[4], z: c[5]),
          chargeGrenade: c[6] == 1, sneak: c[7] == 1, direct: c[8] == 1)

proc ten(c: Command, ran: bool): array[10, int32] =
  [c.walk.int32, c.goal.x, c.goal.z, c.shoot.int32, c.aim.x, c.aim.z, c.chargeGrenade.int32, c.sneak.int32,
   c.direct.int32, ran.int32]

type HostRun = object
  hashes: seq[uint32]
  decided: seq[Command]          # the teacher program's own order each tick
  selected: seq[array[ActionSizes.len, int32]]
  sampled: seq[bool]
  inputs: seq[seq[int32]]

proc hostRun(model, manifest: string, seed: int32, ticks: int, shadow: bool): HostRun =
  ## The game's own loop: seat Teacher runs the bundle, the rest base.bas. With shadow, the teacher
  ## decides on the world as usual, then the world executes student(t) for its seat instead.
  let path = getTempDir()/("paintbot-shadow-host-" & $getCurrentProcessId() & ".bas")
  writeFile(path, Policy)
  writeFile(path & ".model.bin", model)
  writeFile(path & ".neural.json", manifest)
  defer:
    for suffix in ["", ".model.bin", ".neural.json"]: removeFile(path & suffix)
  resetOracle()
  var players = newSeq[Bot](Seats)
  let neural = loadBots(@[BotGroup(path: path, count: 1)])
  let plain = loadBots(@[BotGroup(path: Base, count: Seats)])
  for slot in 0..<Seats: players[slot] = if slot == Teacher: neural[0] else: plain[slot]
  var w = newWorld(seed, ticks.int32)
  var t = 0
  while w.tick < ticks and w.winner == -1:
    var commands = players.decide(w)
    deliverSpeech(w)
    check not players[Teacher].failed
    result.decided.add commands[Teacher]
    result.selected.add players[Teacher].neural.selected
    result.sampled.add players[Teacher].neural.sampled
    result.inputs.add players[Teacher].neural.userInputs
    if shadow: commands[Teacher] = toCommand(student(t))
    w.step(commands)
    result.hashes.add w.stateHash()
    inc t

suite "Net-teacher shadow: pw_set_seat_command on a policy seat, pw_seat_decided_orders":
  configureRules(NativeRules)
  let baseSource = readFile(Base)
  let contract = userInputsContractHash(K)
  let manifest = Manifest % [contract, ActionContractTeamsView1Hash]
  let model = randomModel(5, TeamsViewSize + K, contract)

  test "arguments; an unscripted seat and a fresh handle report zeros with ran = 0":
    var out10: array[10, int32]
    check pw_seat_decided_orders(nil, 0, ibuf(out10)) == -1
    let h = pw_create_observation_inputs(3, 100, K)
    require h != nil
    defer: pw_destroy(h)
    check pw_seat_decided_orders(h, -1, ibuf(out10)) == -1
    check pw_seat_decided_orders(h, Seats.cint, ibuf(out10)) == -1
    check pw_seat_decided_orders(h, 0, nil) == -1
    check pw_seat_decided_orders(h, 0, ibuf(out10)) == 0
    check out10 == default(array[10, int32])
    require setScript(h, 1, baseSource) == 0
    var actions: array[LegacySeats*ActionSizes.len, int32]
    var rewards, terminals: array[LegacySeats, float32]
    check pw_seat_decided_orders(h, 1, ibuf(out10)) == 0 and out10[9] == 0   # no step yet
    require pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
    check pw_seat_decided_orders(h, 0, ibuf(out10)) == 0 and out10 == default(array[10, int32])
    check pw_seat_decided_orders(h, 1, ibuf(out10)) == 0 and out10[9] == 1
    var orders: array[10, int32]
    check pw_seat_orders(h, 1, ibuf(orders)) == 0
    for i in 0..8: check out10[i] == orders[i]                     # no replacement: decided = executed
    # a raw command on the scripted seat: executed = the command, decided = the script's order
    let nine = student(3)
    check pw_set_seat_command(h, 1, ibuf(nine)) == 0
    require pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
    check pw_seat_orders(h, 1, ibuf(orders)) == 0
    for i in 0..8: check orders[i] == nine[i]
    check pw_seat_decided_orders(h, 1, ibuf(out10)) == 0 and out10[9] == 1
    # pw_reset and a script change start over at ran = 0
    check pw_reset(h, 4, 100) == 0
    check pw_seat_decided_orders(h, 1, ibuf(out10)) == 0 and out10 == default(array[10, int32])
    require pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
    require setScript(h, 1, baseSource) == 0
    check pw_seat_decided_orders(h, 1, ibuf(out10)) == 0 and out10 == default(array[10, int32])

  test "shadowed policy seat == hosted teacher on the student's world, tick for tick (and unshadowed: decided = executed)":
    let actor = loadActor(model)
    var shadowTicksDiffer = 0
    for (seed, ticks, shadow) in [(21'i32, 900, true), (22'i32, 700, true), (23'i32, 500, false)]:
      checkpoint "seed " & $seed & " shadow " & $shadow
      let host = hostRun(model, manifest, seed, ticks, shadow)
      let handle = pw_create_observation_inputs(seed, ticks.int32, K)
      require handle != nil
      for slot in 0..<Seats:
        if slot == Teacher: require setPolicy(handle, slot, Policy, manifest) == 0
        else: require setScript(handle, slot, baseSource) == 0
      let n = TeamsViewSize + K
      var state = newSeq[float32](actor.hiddenSize)
      var alive = false
      var observations = newSeq[float32](Seats*n)
      var resets: array[LegacySeats, float32]
      var actions: array[LegacySeats*ActionSizes.len, int32]
      var logits: array[LegacySeats*LogitSize, float32]
      var rewards, terminals: array[LegacySeats, float32]
      for t, hash in host.hashes:
        require pw_observe(handle, fbuf(observations), fbuf(resets)) == 0
        # the teacher's user inputs keep advancing under the shadow: the row's tail is what its
        # policy.bas left last tick, the hosted bot's own values
        if t > 0:
          for i in 0..<K: require observations[Teacher*n+TeamsViewSize+i] == userInputFeature(host.inputs[t-1][i])
        let isAlive = observations[Teacher*n+2] > 0
        if not isAlive or not alive or t == 0:
          for i in 0..<actor.hiddenSize: state[i] = 0
        alive = isAlive
        if isAlive:
          var output = newSeq[float32](LogitSize)
          actor.infer(observations.toOpenArray(Teacher*n, Teacher*n+n-1), state, output)
          for i in 0..<LogitSize: logits[Teacher*LogitSize+i] = output[i]
        let nine = student(t)
        if shadow: require pw_set_seat_command(handle, Teacher.cint, ibuf(nine)) == 0
        require pw_step_logits(handle, ibuf(actions), fbuf(logits), fbuf(rewards), fbuf(terminals)) == 0
        # the world executed the student's command (or, unshadowed, the teacher's own)
        require pw_state_hash(handle) == hash
        var decided, orders: array[10, int32]
        require pw_seat_decided_orders(handle, Teacher.cint, ibuf(decided)) == 0
        require decided == ten(host.decided[t], true)
        require pw_seat_orders(handle, Teacher.cint, ibuf(orders)) == 0
        if shadow:
          for i in 0..8: require orders[i] == nine[i]
          if ten(host.decided[t], true)[0..8] != nine[0..8]: inc shadowTicksDiffer
        else:
          for i in 0..8: require orders[i] == decided[i]
        var choices: array[22, int32]
        require pw_seat_policy_choices(handle, Teacher.cint, ibuf(choices)) == 0
        require (choices[0] == 1) == host.sampled[t]
        if host.sampled[t]:
          for head in 0..<ActionSizes.len: require choices[1+head] == host.selected[t][head]
      check pw_seat_script_status(handle, Teacher.cint, nil, 0) == 1
      pw_destroy(handle)
    check shadowTicksDiffer > 500     # the teacher's order really differs from what was executed
