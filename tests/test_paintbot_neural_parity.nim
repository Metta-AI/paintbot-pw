## Training == host parity for the view contracts. Each scenario drives the training library
## for two episodes (a mid-match reset between them) with seeded head choices for every seat
## but one scripted seat: pw_step decodes each seat's heads with the reference decoder script.
## The same match is then replayed the hosted way from the same starting worlds: every
## caller-driven seat is a hosted policy seat whose policy.bas is neuralSample + the reference
## decode (players/neural_decode.bas, neural_decode_ffa.bas), fed the chosen heads as one-hot
## logits, and the scripted seat runs the same script; the world steps as the game's loop steps
## it (decide, deliverSpeech, step). Every tick, the observation row the trainer read must equal
## the one the hosted policy.bas observed, the selection must be the chosen heads, and the
## world hashes must agree: what a policy is trained on and what it plays are the same bytes.
import std/[unittest, os, importutils]
import ../examples/paintbot/[sim, kinship, neural_contract, native_env, bots, seat_view]
privateAccess(NativeEnv)

const Root = currentSourcePath().parentDir.parentDir
const
  Decoder = staticRead("../examples/paintbot/players/neural_decode.bas")
  DecoderFfa = staticRead("../examples/paintbot/players/neural_decode_ffa.bas")
  Head = "paintbot_observe(neuralObservation())\nrun_neural_net(neuralModel(), neuralObservation(), " &
    "neuralLogits(), neuralState())\nneuralSample()\n"
  ScriptedSeat = 9

proc fp(buffer: var seq[float32]): ptr UncheckedArray[cfloat] =
  cast[ptr UncheckedArray[cfloat]](addr buffer[0])
proc ip(buffer: var seq[int32]): ptr UncheckedArray[int32] =
  cast[ptr UncheckedArray[int32]](addr buffer[0])
proc envOf(h: pointer): ptr NativeEnv = cast[ptr NativeEnv](h)

type Scenario = object
  name: string
  obs, inputs: int32
  ffa: bool
  rules: int32  # 0 = the library default
  map: int32    # -1 = the rules' own island
  ticks: int32  # the first episode's length; 0 = 360 (the second is always 120 shorter than the default, 240)

type Tick = object
  ## What the trainer saw and did on one native tick.
  rows: seq[float32]      # every seat's pw_observe row
  actions: seq[int32]
  hash: uint32
  terminal: float32
type Episode = object
  start: World            # the world right after the reset
  kinship: Kinship        # the episode's kinship (FFA-kin draws one per reset)
  ticks: seq[Tick]

proc script(ffa: bool): string =
  readFile(Root / "coworld/paintbot/players" / (if ffa: "ffa.bas" else: "base.bas"))

proc observationHash(s: Scenario): string =
  let version = ObservationContractVersion(s.obs)
  if s.inputs > 0 and version != ocFfaView1: userInputsContractHash(s.inputs.int, version)
  else: observationContractHash(version)

proc manifest(s: Scenario): string =
  result = """{"schema": "paintbot-neural-basic/2", "observation_contract": """" & s.observationHash &
    """", "action_contract": """" & (if s.ffa: ActionContractFfaView1PointerHash else: ActionContractTeamsView1Hash) & "\""
  if s.inputs > 0:
    # Zero inputs, as the training library writes for a seat without a policy script.
    result.add ", \"user_inputs\": {\"count\": " & $s.inputs & ", \"init\": ["
    for i in 0..<s.inputs.int: result.add (if i > 0: ", 0" else: "0")
    result.add "]}"
  result.add "}"

proc draw(rng: var uint64, n: int): int32 =
  rng = rng * 6364136223846793005'u64 + 1442695040888963407'u64
  int32((rng shr 33) mod uint64(n))

proc train(s: Scenario, h: pointer): seq[Episode] =
  ## The native half: two episodes of seeded heads, every row and hash recorded.
  if s.ffa: doAssert pw_set_game_mode(h, 1) == 0
  if s.rules > 0: doAssert pw_set_rules(h, s.rules) == 0
  doAssert pw_set_map(h, s.map) == 0
  let source = script(s.ffa)
  var rng = 0x9E3779B97F4A7C15'u64
  for episode in 0..1:
    let length = if episode == 0 and s.ticks > 0: s.ticks else: int32(360 - 120*episode)
    doAssert pw_reset(h, int32(2026 + episode), length) == 0
    if episode == 0:
      doAssert pw_set_seat_script(h, ScriptedSeat, cast[ptr UncheckedArray[char]](unsafeAddr source[0]),
        source.len.int32) == 0
    var e = Episode(start: envOf(h).world, kinship: envOf(h).kinship)
    let width = pw_handle_observation_size(h).int
    var heads = newSeq[int32](8)
    doAssert pw_action_layout(h, ip(heads)) == 0
    var rewards = newSeq[float32](LegacySeats)
    var terminals = newSeq[float32](LegacySeats)
    var resets = newSeq[float32](LegacySeats)
    for tick in 0..<length.int + 40:
      var t = Tick(rows: newSeq[float32](LegacySeats*width), actions: newSeq[int32](LegacySeats*ActionSizes.len))
      doAssert pw_observe(h, fp(t.rows), fp(resets)) == 0
      for slot in 0..<LegacySeats:
        let o = slot*ActionSizes.len
        t.actions[o] = draw(rng, heads[1])
        t.actions[o+1] = draw(rng, heads[2])
        t.actions[o+2] = int32(draw(rng, 3) == 0)
        t.actions[o+3] = int32(draw(rng, 20) == 0)
        t.actions[o+4] = int32(draw(rng, 8) == 0)
      let code = pw_step(h, ip(t.actions), fp(rewards), fp(terminals))
      if code == -2: break
      doAssert code == 0, "pw_step failed: " & $code
      t.hash = pw_state_hash(h)
      t.terminal = terminals[0]
      e.ticks.add t
      if terminals[0] == 1: break
    result.add e

proc host(s: Scenario, h: pointer, episodes: seq[Episode]): int =
  ## The hosted half: the same starting worlds and head choices through hosted policy seats.
  ## Returns the ticks compared.
  discard pw_state_hash(h) # installs the handle's rules, map, mode and kinship on this thread
  let policy = Head & (if s.ffa: DecoderFfa else: Decoder)
  let source = script(s.ffa)
  for e in episodes:
    var bots = newSeq[Bot](LegacySeats)
    for slot in 0..<LegacySeats:
      bots[slot] = if slot == ScriptedSeat: loadScriptBot(source, slot)
                   else: loadPolicyBot(policy, s.manifest, slot, s.observationHash)
    heard = newSeq[seq[HeardMessage]](LegacySeats)
    activeKinship = e.kinship
    var w = e.start
    for t in e.ticks:
      let width = t.rows.len div LegacySeats
      var alive: array[LegacySeats, bool]
      for slot in 0..<LegacySeats:
        alive[slot] = w.cogs[slot].hp > 0
        if slot == ScriptedSeat: continue
        let bot = bots[slot]
        for i in 0..<bot.neural.fedLogits.len: bot.neural.fedLogits[i] = 0
        var offset = 0
        for head in 0..<ActionSizes.len:
          bot.neural.fedLogits[offset + t.actions[slot*ActionSizes.len + head].int] = 1
          offset += bot.neural.heads[head]
        bot.neural.logitsFed = true
      let commands = decide(bots, w)
      deliverSpeech(w)
      for slot in 0..<LegacySeats:
        if slot == ScriptedSeat or not alive[slot]: continue
        let bot = bots[slot]
        check not bot.failed
        if bot.failed: echo "seat ", slot, ": ", bot.error
        check bot.neural.sampled
        check @(bot.neural.selected) == t.actions[slot*ActionSizes.len ..< (slot+1)*ActionSizes.len]
        let row = t.rows[slot*width ..< (slot+1)*width]
        check bot.neural.observation == row
        if bot.neural.observation != row:
          for i in 0..<width:
            if bot.neural.observation[i] != row[i]:
              echo "DIFF tick ", w.tick, " seat ", slot, " col ", i, " host ", bot.neural.observation[i], " native ", row[i]
          return
      check not bots[ScriptedSeat].failed
      w.step(commands)
      check w.stateHash() == t.hash
      if w.stateHash() != t.hash: return
      check float32((w.winner != -1 or w.tick >= w.endTick).int) == t.terminal
      inc result

const Scenarios = [
  Scenario(name: "teams.view.1, teams", obs: 201, map: -1),
  Scenario(name: "teams.view.1, teams, rules 47", obs: 201, rules: 47, map: -1),
  Scenario(name: "teams.view.1, teams, rules 47, crater", obs: 201, rules: 47, map: 3),
  Scenario(name: "teams.view.1u4, teams", obs: 201, inputs: 4, map: -1),
  Scenario(name: "teams.view.1h, teams, rules 48", obs: 203, rules: 48, map: -1),
  Scenario(name: "teams.view.1s, teams, rules 48", obs: 204, rules: 48, map: -1),
  Scenario(name: "teams.view.1su4, teams, rules 47, crater", obs: 204, inputs: 4, rules: 47, map: 3),
  Scenario(name: "teams.view.1t, teams, rules 48", obs: 205, rules: 48, map: -1),
  Scenario(name: "teams.view.1tu4, teams, rules 47, crater", obs: 205, inputs: 4, rules: 47, map: 3),
  # 2900 ticks: past both hunt-clock caps (720 and 2760 ticks)
  Scenario(name: "teams.view.1t, teams, rules 48, 2900 ticks", obs: 205, rules: 48, map: -1, ticks: 2900),
  Scenario(name: "teams.view.1p, teams, rules 48", obs: 206, rules: 48, map: -1),
  Scenario(name: "teams.view.1pu4, teams, rules 47, crater", obs: 206, inputs: 4, rules: 47, map: 3),
  Scenario(name: "teams.view.1p, teams, rules 48, twin-mesas, 1500 ticks", obs: 206, rules: 48, map: 0, ticks: 1500),
  Scenario(name: "ffa.view.1, FFA-kin", obs: 202, ffa: true, map: -1),
  Scenario(name: "ffa.view.1, FFA-kin, rules 48 (fog of war)", obs: 202, ffa: true, rules: 48, map: -1),
  Scenario(name: "ffa.view.1, FFA-kin, rules 47, twin-mesas", obs: 202, ffa: true, rules: 47, map: 0)]

proc handleFor(s: Scenario): pointer =
  result = if s.inputs > 0: pw_create_observation_inputs_v(7, 0, s.obs, s.inputs)
           else: pw_create_observation(7, 0, s.obs)
  doAssert result != nil

suite "Training == host parity on the view contracts":
  for s in Scenarios:
    test s.name:
      let h = handleFor(s)
      let episodes = train(s, h)
      check episodes.len == 2 and episodes[0].ticks.len > 100 and episodes[1].ticks.len > 100
      let compared = host(s, h, episodes)
      check compared == episodes[0].ticks.len + episodes[1].ticks.len
      pw_destroy(h)

  test "the teams game at rules 48 plays and observes exactly as at rules 47":
    # Rules 48 (the FFA-kin fog of war) changes nothing in the teams game.
    proc record(s: Scenario): seq[(seq[float32], uint32)] =
      let h = handleFor(s)
      for e in train(s, h):
        for t in e.ticks: result.add (t.rows, t.hash)
      pw_destroy(h)
    for base in [Scenarios[1], Scenarios[2]]:
      var at48 = base
      at48.rules = 48
      let a = record(base)
      check a.len > 200
      check record(at48) == a
