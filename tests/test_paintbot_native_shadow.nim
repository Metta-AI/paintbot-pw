## Net-teacher shadow (pw_set_seat_command on a policy seat + pw_seat_decided_orders): a policy seat
## given a raw command still runs its policy.bas on the trainer's logits, so its BASIC state, user
## inputs and sampling advance as if it had acted, while the world executes the raw (student)
## command; pw_seat_decided_orders reads what the program decided. Checked tick for tick against an
## independent hosted loop (the game's own decide / deliverSpeech / step over the staged bundle) in
## which the teacher bot decides on the same world and its order is then replaced by the student's.
## Synthetic actor (seeded random weights). Build with --mm:arc --threads:on -d:pwTraining.
import std/[unittest, os, random, strutils]
import bassy
import polyworld/[cli]
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
  shadowDecided: seq[Command]    # with a shadow source: the shadow script's order each tick
  selected: seq[array[ActionSizes.len, int32]]
  sampled: seq[bool]
  inputs: seq[seq[int32]]

proc hostRun(model, manifest: string, seed: int32, ticks: int, shadow: bool, shadowSrc = ""): HostRun =
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
  let neural = loadBots(@[BotGroup(path: path, count: Seats)])
  let plain = loadBots(@[BotGroup(path: Base, count: Seats)])
  for slot in 0..<Seats: players[slot] = if slot == Teacher: neural[slot] else: plain[slot]
  # the reference shadow: its own bot for the teacher's slot, deciding on the pre-step world before the tick's
  # decide, hearing what the seat hears (decide resets the shout lists, so its shouts go nowhere)
  var shadowBots = newSeq[Bot](Seats)
  if shadowSrc.len > 0: shadowBots[Teacher] = loadScriptBot(shadowSrc, Teacher)
  var w = newWorld(seed, ticks.int32)
  var t = 0
  while w.tick < ticks and w.winner == -1:
    if shadowSrc.len > 0: result.shadowDecided.add decideSeats(shadowBots, w)[Teacher]
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


type MultiRun = object
  hashes: seq[uint32]
  decided: seq[seq[Command]]         # [tick][seat]: each learner's policy.bas order (executed)
  shadowDecided: seq[seq[Command]]   # [tick][seat]: each learner's shadow script order
  inputs: seq[seq[seq[int32]]]       # [tick][seat]: each learner's user inputs after its decision
  alive: seq[seq[bool]]              # [tick][seat]: alive on the pre-step world

proc hostMulti(model, manifest: string, seed: int32, ticks: int, learners: seq[int], shadowSrc: string): MultiRun =
  ## The game's own loop with a policy bundle on every learner seat and base.bas elsewhere; each learner's
  ## reference shadow is its own bot deciding on the pre-step world before the tick's decide.
  let path = getTempDir()/("paintbot-shadow-multi-" & $getCurrentProcessId() & ".bas")
  writeFile(path, Policy)
  writeFile(path & ".model.bin", model)
  writeFile(path & ".neural.json", manifest)
  defer:
    for suffix in ["", ".model.bin", ".neural.json"]: removeFile(path & suffix)
  resetOracle()
  heard = @[]
  var players = newSeq[Bot](Seats)
  let neural = loadBots(@[BotGroup(path: path, count: Seats)])
  let plain = loadBots(@[BotGroup(path: Base, count: Seats)])
  for slot in 0..<Seats: players[slot] = if slot in learners: neural[slot] else: plain[slot]
  var shadowBots = newSeq[Bot](Seats)
  for slot in learners: shadowBots[slot] = loadScriptBot(shadowSrc, slot)
  var w = newWorld(seed, ticks.int32)
  while w.tick < ticks and w.winner == -1:
    var alive = newSeq[bool](Seats)
    for slot in 0..<Seats: alive[slot] = w.cogs[slot].hp > 0
    result.alive.add alive
    result.shadowDecided.add decideSeats(shadowBots, w)
    let commands = players.decide(w)
    deliverSpeech(w)
    result.decided.add commands
    var inputs = newSeq[seq[int32]](Seats)
    for slot in learners: inputs[slot] = players[slot].neural.userInputs
    result.inputs.add inputs
    w.step(commands)
    result.hashes.add w.stateHash()

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

  test "a shadow SCRIPT on a policy seat: the seat's policy.bas and the world are untouched; decided = the hosted shadow":
    let actor = loadActor(model)
    var differs = 0
    for (seed, ticks) in [(31'i32, 900), (32'i32, 600)]:
      checkpoint "seed " & $seed
      let host = hostRun(model, manifest, seed, ticks, false, baseSource)
      let handle = pw_create_observation_inputs(seed, ticks.int32, K)
      require handle != nil
      for slot in 0..<Seats:
        if slot == Teacher: require setPolicy(handle, slot, Policy, manifest) == 0
        else: require setScript(handle, slot, baseSource) == 0
      require pw_set_seat_shadow_script(handle, Teacher.cint, cbuf(baseSource), baseSource.len.int32) == 0
      check pw_seat_shadow_status(handle, Teacher.cint) == 1
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
        if t > 0:   # the policy seat's own policy.bas keeps writing its user inputs
          for i in 0..<K: require observations[Teacher*n+TeamsViewSize+i] == userInputFeature(host.inputs[t-1][i])
        let isAlive = observations[Teacher*n+2] > 0
        if not isAlive or not alive or t == 0:
          for i in 0..<actor.hiddenSize: state[i] = 0
        alive = isAlive
        if isAlive:
          var output = newSeq[float32](LogitSize)
          actor.infer(observations.toOpenArray(Teacher*n, Teacher*n+n-1), state, output)
          for i in 0..<LogitSize: logits[Teacher*LogitSize+i] = output[i]
        require pw_step_logits(handle, ibuf(actions), fbuf(logits), fbuf(rewards), fbuf(terminals)) == 0
        require pw_state_hash(handle) == hash                 # the hosted world WITHOUT any shadow
        var decided, orders: array[10, int32]
        require pw_seat_decided_orders(handle, Teacher.cint, ibuf(decided)) == 0
        require decided[0..8] == ten(host.shadowDecided[t], true)[0..8] and decided[9] == 2
        require pw_seat_orders(handle, Teacher.cint, ibuf(orders)) == 0
        require orders[0..8] == ten(host.decided[t], true)[0..8]   # the net's own command executed
        if decided[0..8] != orders[0..8]: inc differs
        var choices: array[22, int32]
        require pw_seat_policy_choices(handle, Teacher.cint, ibuf(choices)) == 0
        require (choices[0] == 1) == host.sampled[t]
      check pw_seat_shadow_status(handle, Teacher.cint) == 1
      pw_destroy(handle)
    check differs > 300

  test "a shadow script's shouts are dropped; fresh globals per reset; caller-driven seat; status codes; save / load":
    let Shouter = "dim c(1)\nc(0) = c(0) + 1\nshout(\"x\")\nwalkTo(c(0), 7)\n"
    let Listener = "walkTo(heardCount(), 0)\n"
    var actions: array[LegacySeats*ActionSizes.len, int32]
    var rewards, terminals: array[LegacySeats, float32]
    var o: array[10, int32]
    check pw_set_seat_shadow_script(nil, 0, nil, 0) == -1
    check pw_seat_shadow_status(nil, 0) == -1
    # positive control: the same shouter as seat 0's REAL script is heard by some listener (every other seat
    # listens; teammates spawn within hearing range)
    let control = pw_create(51, 200)
    require control != nil
    defer: pw_destroy(control)
    require setScript(control, 0, Shouter) == 0
    for slot in 1..<Seats: require setScript(control, slot, Listener) == 0
    var heardMax = 0
    for t in 0..<20:
      require pw_step(control, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
      for slot in 1..<Seats:
        require pw_seat_orders(control, slot.cint, ibuf(o)) == 0
        heardMax = max(heardMax, o[1].int)
    check heardMax >= 1
    # as a SHADOW on caller-driven seat 0 it is never heard, and the world equals a twin without it
    let h = pw_create(51, 200)
    let twin = pw_create(51, 200)
    require h != nil and twin != nil
    defer: pw_destroy(h); pw_destroy(twin)
    check pw_set_seat_shadow_script(h, Seats.cint, cbuf(Shouter), Shouter.len.int32) == -1
    let broken = "walkTo("
    check pw_set_seat_shadow_script(h, 0, cbuf(broken), broken.len.int32) == 1
    check pw_seat_shadow_status(h, 0) == 2
    require pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
    require pw_step(twin, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
    check pw_seat_decided_orders(h, 0, ibuf(o)) == 0 and o[9] == 0     # a failed shadow decides nothing
    check pw_set_seat_shadow_script(h, 0, nil, 0) == 0 and pw_seat_shadow_status(h, 0) == 0
    require pw_set_seat_shadow_script(h, 0, cbuf(Shouter), Shouter.len.int32) == 0
    for slot in 1..<Seats: require setScript(h, slot, Listener) == 0 and setScript(twin, slot, Listener) == 0
    for t in 0..<20:
      for slot in 1..<Seats:   # seat 0 stays (alive, so its shadow keeps deciding); the rest move at random
        for head, size in ActionSizes: actions[slot*ActionSizes.len+head] = int32((t * 7 + slot * 3 + head) mod size)
      require pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
      require pw_step(twin, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
      check pw_state_hash(h) == pw_state_hash(twin)
      require pw_seat_decided_orders(h, 0, ibuf(o)) == 0
      check o[9] == 2 and o[0] == 1 and o[1] == int32(t + 1) and o[2] == 7    # its own globals advance
      for slot in 1..<Seats:
        require pw_seat_orders(h, slot.cint, ibuf(o)) == 0
        check o[1] == 0                                                        # nobody hears the shadow
    # save at this tick, play 5, load, play 5 again: the shadow's runtime state is part of the snapshot
    let size = pw_world_save(h, nil, 0)
    require size > 0
    var blob = newSeq[byte](size)
    require pw_world_save(h, cast[ptr UncheckedArray[byte]](addr blob[0]), size) == size
    var first: seq[int32]
    for t in 0..<5:
      require pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
      require pw_seat_decided_orders(h, 0, ibuf(o)) == 0
      first.add o[1]
    check first == @[21'i32, 22, 23, 24, 25]
    require pw_world_load(h, cast[ptr UncheckedArray[byte]](addr blob[0]), size) == 0
    for t in 0..<5:
      require pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
      require pw_seat_decided_orders(h, 0, ibuf(o)) == 0
      check o[1] == first[t]
    # pw_reset installs a fresh runtime: the counter starts over
    require pw_reset(h, 52, 200) == 0
    check pw_seat_decided_orders(h, 0, ibuf(o)) == 0 and o[9] == 0
    require pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
    check pw_seat_decided_orders(h, 0, ibuf(o)) == 0 and o[9] == 2 and o[1] == 1
    check pw_seat_shadow_status(h, 0) == 1

  test "teacher-forced replay: a shadow decides exactly what the same script decides when seated; pw_script_decide changes nothing":
    # The record: seat 0 plays the student's raw commands, the rest base.bas. Every replay forces every seat's
    # recorded command (pw_set_seat_command) and must reproduce the record's world tick for tick; seat 0's teacher
    # (base.bas) runs either as a shadow (ran = 2) or seated under the forced command (ran = 1). Without listeners
    # nothing seat 0 hears depends on its own shouts, so shadow == seated exactly. With base.bas listeners (scripted
    # but forced) the seated teacher's shouts reach them; the shadow's never do (documented); the shadow still
    # decides identically whether or not pw_script_decide took the tick's decision ahead of the step.
    const Ticks = 600
    type Mode = enum mShadow, mSeated, mShadowListeners, mShadowListenersPre, mSeatedListeners
    var differs = 0
    for seed in [61'i32, 62]:
      checkpoint "seed " & $seed
      var actions: array[LegacySeats*ActionSizes.len, int32]
      var rewards, terminals: array[LegacySeats, float32]
      var o: array[10, int32]
      let rec = pw_create(seed, Ticks)
      require rec != nil
      for slot in 1..<Seats: require setScript(rec, slot, baseSource) == 0
      var executed: seq[seq[array[9, int32]]]
      var hashes: seq[uint32]
      for t in 0..<Ticks:
        let nine = student(t)
        require pw_set_seat_command(rec, 0, ibuf(nine)) == 0
        if pw_step(rec, ibuf(actions), fbuf(rewards), fbuf(terminals)) != 0: break
        var row = newSeq[array[9, int32]](Seats)
        for slot in 0..<Seats:
          require pw_seat_orders(rec, slot.cint, ibuf(o)) == 0
          for i in 0..8: row[slot][i] = o[i]
        executed.add row
        hashes.add pw_state_hash(rec)
      pw_destroy(rec)
      check hashes.len > 300
      var decided: array[Mode, seq[array[10, int32]]]
      for mode in Mode:
        checkpoint "mode " & $mode
        let h = pw_create(seed, Ticks)
        require h != nil
        let listeners = mode in {mShadowListeners, mShadowListenersPre, mSeatedListeners}
        if listeners:
          for slot in 1..<Seats: require setScript(h, slot, baseSource) == 0
        if mode in {mSeated, mSeatedListeners}: require setScript(h, 0, baseSource) == 0
        else: require pw_set_seat_shadow_script(h, 0, cbuf(baseSource), baseSource.len.int32) == 0
        for t, row in executed:
          for slot in 0..<Seats:
            var cmd = row[slot]
            require pw_set_seat_command(h, slot.cint, ibuf(cmd)) == 0
          if mode == mShadowListenersPre: require pw_script_decide(h) == 1
          require pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
          require pw_state_hash(h) == hashes[t]                  # the forced replay is the record's world
          require pw_seat_orders(h, 0, ibuf(o)) == 0
          for i in 0..8: require o[i] == row[0][i]               # seat 0 executed the student's command
          require pw_seat_decided_orders(h, 0, ibuf(o)) == 0
          require o[9] == (if mode in {mSeated, mSeatedListeners}: 1'i32 else: 2'i32)
          decided[mode].add o
        if mode in {mShadow, mShadowListeners, mShadowListenersPre}: check pw_seat_shadow_status(h, 0) == 1
        pw_destroy(h)
      for t in 0..<executed.len:
        check decided[mShadow][t][0..8] == decided[mSeated][t][0..8]
        check decided[mShadowListeners][t] == decided[mShadowListenersPre][t]
        if decided[mShadow][t][0..8] != executed[t][0][0..8]: inc differs
      var listenerAgree = 0
      for t in 0..<executed.len:
        if decided[mShadowListeners][t][0..8] == decided[mSeatedListeners][t][0..8]: inc listenerAgree
      echo "seed ", seed, ": shadow vs seated with listeners agree on ", listenerAgree, "/", executed.len, " ticks"
    check differs > 300   # the teacher's order really differs from the forced one

  test "the TC worker's sequence: 8 learner policy seats with shadows, pw_reset between episodes, observe_seats / seat_state":
    # pw-features' per-episode call order: pw_reset, install the seats, shadow script on each learner seat and
    # NULL on the rest, pw_observe_seats + pw_seat_state; per tick: logits, pw_step_logits, pw_seat_policy_choices,
    # pw_seat_decided_orders on the learner seats, pw_observe_seats + pw_seat_state. Checked against the hosted
    # game without shadows (world, executed orders, user inputs) and each learner's hosted reference shadow.
    let actor = loadActor(model)
    let learners = @[0, 2, 4, 6, 8, 10, 12, 14]
    var mask = 0'u32
    for slot in learners: mask = mask or (1'u32 shl slot)
    let n = TeamsViewSize + K
    let handle = pw_create_observation_inputs(70, 400, K)
    require handle != nil
    defer: pw_destroy(handle)
    var differs, rows = 0
    for (seed, ticks) in [(71'i32, 500), (72'i32, 400)]:
      checkpoint "seed " & $seed
      let host = hostMulti(model, manifest, seed, ticks, learners, baseSource)
      require pw_reset(handle, seed, ticks.int32) == 0
      for slot in 0..<Seats:
        if slot in learners: require setPolicy(handle, slot, Policy, manifest) == 0
        else: require setScript(handle, slot, baseSource) == 0
      for slot in 0..<Seats:
        if slot in learners:
          require pw_set_seat_shadow_script(handle, slot.cint, cbuf(baseSource), baseSource.len.int32) == 0
          require pw_seat_shadow_status(handle, slot.cint) == 1
        else:
          require pw_set_seat_shadow_script(handle, slot.cint, nil, 0) == 0
          require pw_seat_shadow_status(handle, slot.cint) == 0
      var observations = newSeq[float32](Seats*n)
      var resets: array[LegacySeats, float32]
      var bodies = newSeq[float32](Seats*8)
      var actions: array[LegacySeats*ActionSizes.len, int32]
      var logits: array[LegacySeats*LogitSize, float32]
      var rewards, terminals: array[LegacySeats, float32]
      var states = newSeq[seq[float32]](Seats)
      var wasAlive = newSeq[bool](Seats)
      for slot in learners: states[slot] = newSeq[float32](actor.hiddenSize)
      require pw_observe_seats(handle, mask, fbuf(observations), fbuf(resets)) == 0
      require pw_seat_state(handle, fbuf(bodies)) == 0
      for t, hash in host.hashes:
        for slot in learners:
          let isAlive = observations[slot*n+2] > 0
          if not isAlive or not wasAlive[slot] or t == 0:
            for i in 0..<actor.hiddenSize: states[slot][i] = 0
          wasAlive[slot] = isAlive
          if isAlive:
            var output = newSeq[float32](LogitSize)
            actor.infer(observations.toOpenArray(slot*n, slot*n+n-1), states[slot], output)
            for i in 0..<LogitSize: logits[slot*LogitSize+i] = output[i]
        require pw_step_logits(handle, ibuf(actions), fbuf(logits), fbuf(rewards), fbuf(terminals)) == 0
        require pw_state_hash(handle) == hash                 # the hosted world WITHOUT any shadow
        for slot in learners:
          var choices: array[22, int32]
          require pw_seat_policy_choices(handle, slot.cint, ibuf(choices)) == 0
          var decided, orders: array[10, int32]
          require pw_seat_decided_orders(handle, slot.cint, ibuf(decided)) == 0
          require decided[9] == 2
          require decided[0..8] == ten(host.shadowDecided[t][slot], true)[0..8]
          require pw_seat_orders(handle, slot.cint, ibuf(orders)) == 0
          require orders[0..8] == ten(host.decided[t][slot], true)[0..8]   # each net's own command executed
          if host.alive[t][slot]:
            inc rows
            if decided[0..8] != orders[0..8]: inc differs
        for slot in 0..<Seats:
          if slot notin learners:
            var decided: array[10, int32]
            require pw_seat_decided_orders(handle, slot.cint, ibuf(decided)) == 0
            require decided[9] == 1                                         # a scripted seat's own program
        require pw_observe_seats(handle, mask, fbuf(observations), fbuf(resets)) == 0
        require pw_seat_state(handle, fbuf(bodies)) == 0
        for slot in learners:   # each policy.bas keeps writing its user inputs under its shadow
          for i in 0..<K: require observations[slot*n+TeamsViewSize+i] == userInputFeature(host.inputs[t][slot][i])
      for slot in learners: check pw_seat_shadow_status(handle, slot.cint) == 1
    check rows > 2000 and differs * 10 > rows   # the teachers really disagree with the nets
