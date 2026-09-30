## Per-handle rules and game config in the training library (pw_set_rules,
## pw_set_config_json). A handle that calls neither plays exactly as the library did before
## (goldens recorded from the library before pw_set_map existed); a handle given a manifest
## variant's game_config and the live rules plays the world the hosted game plays for it.
## Build with --mm:arc --threads:on -d:pwTraining. PW_CONFIG_SEEDS (seeds per variant, default
## 1), PW_CONFIG_TICKS (tick cap, default 300), PW_CONFIG_VARIANTS (comma-separated variant ids,
## default every variant) and PW_CONFIG_REPORT (a JSON-lines file of each host/native pair)
## widen the host-parity test into a battery.
import std/[unittest, os, json, strutils, options]
import polyworld/cli
import ../examples/paintbot/[sim, bots, kinship, game, neural_contract, native_env]

when not defined(pwTraining): {.error: "native configs exist only under -d:pwTraining".}

const Root = currentSourcePath().parentDir.parentDir
const Base = Root / "coworld/paintbot/players/base.bas"
const Manifest = Root / "coworld/paintbot/coworld_manifest_template.json"
type
  Buffer = ptr UncheckedArray[cfloat]
  Actions = array[LegacySeats*ActionSizes.len, int32]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])
template ibuf(a: untyped): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr a[0])
template cbuf(s: string): ptr UncheckedArray[char] =
  (if s.len > 0: cast[ptr UncheckedArray[char]](unsafeAddr s[0]) else: nil)

proc fillActions(actions: var Actions, seed, tick: int) =
  for slot in 0..<Seats:
    let offset = slot*ActionSizes.len
    actions[offset] = int32(1+(slot div 2+seed) mod 10)
    actions[offset+1] = int32(17+(tick div 24+slot) mod 8)
    actions[offset+2] = int32(tick mod 3 == 0)
    actions[offset+3] = int32(tick mod 48 < 12)
    actions[offset+4] = int32(slot mod 3 == 0)

proc fold(digest: var uint64, hash: uint32) =
  for i in 0..3:
    digest = (digest xor uint64((hash shr (8*i)) and 255)) * 1099511628211'u64

const
  DefaultTicks = 600
  # tests/test_paintbot_native_map.nim's goldens: recorded from the library before per-handle
  # maps (main 1512438), {seed, FNV-1a of the 600 per-tick state hashes, last hash}.
  DefaultGolden = [(7'i32, 11266663677668710009'u64, 352507994'u32),
    (1001'i32, 6868282711088312779'u64, 2626221708'u32),
    (424242'i32, 2418612431003963041'u64, 3271808267'u32)]

proc setConfig(handle: pointer, text: string, message: var string): cint =
  var error: array[512, char]
  result = pw_set_config_json(handle, cbuf(text), text.len.int32,
    cast[ptr UncheckedArray[char]](addr error[0]), 512)
  message = $cast[cstring](addr error[0])

proc defaultRun(seed: int32, explicit: bool): (uint64, uint32) =
  ## test_paintbot_native_map's default run: odd seats base.bas, even seats the action pattern.
  ## explicit: the handle is first given rules 40 and an empty config, which must change nothing.
  let source = readFile(Base)
  let handle = pw_create(seed, DefaultTicks.int32)
  doAssert handle != nil
  if explicit:
    var message: string
    doAssert pw_set_rules(handle, NativeRules) == 0
    doAssert handle.setConfig("{}", message) == 0
    doAssert pw_reset(handle, seed, DefaultTicks.int32) == 0
  for slot in countup(1, Seats-1, 2):
    doAssert pw_set_seat_script(handle, slot.cint, cbuf(source), source.len.int32) == 0
  var actions: Actions
  var rewards, terminals: array[LegacySeats, float32]
  var digest = 14695981039346656037'u64
  var last: uint32
  for tick in 0..<DefaultTicks:
    actions.fillActions(seed.int, tick)
    doAssert pw_step(handle, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
    last = pw_state_hash(handle)
    digest.fold(last)
  pw_destroy(handle)
  (digest, last)

type
  Variant = object
    id, config: string
  Run = object
    hashes: seq[uint32]
    winner: int
    tick: int
    results: array[8, float32]

proc variants(): seq[Variant] =
  ## The deployed manifest's variants, each game_config verbatim.
  let only = getEnv("PW_CONFIG_VARIANTS")
  for v in parseFile(Manifest)["variants"]:
    if only.len > 0 and v["id"].getStr notin only.split(','): continue
    result.add Variant(id: v["id"].getStr, config: $v["game_config"])

proc hostRun(config: string, seed: int32, ticks: int, rules = LiveRules): Run =
  ## The hosted game's live path (game.setup, game.advance): applyGameConfig, the live rules
  ## (or `rules`), the config's map and vision (CoworldConfig), its vision range and glory,
  ## newLiveWorld, BASIC
  ## seats deciding on the pre-step world, speech, step.
  applyGameConfig(config)
  let node = parseJson(config)
  configureRules(rules)
  configureMap(node{"map"}.getStr(""))
  configureVision(node{"vision"}.getStr(""))
  checkVisionRange(visionRangeChoice, visionMode())
  configureVisionRange(visionRangeChoice)
  configureGlory(gloryChoice)
  var w = newLiveWorld(seed, ticks.int32)
  let players = loadBots(@[BotGroup(path: Base, count: Seats)])
  while w.winner == -1 and w.tick < w.endTick:
    let commands = players.decide(w)
    deliverSpeech(w)
    w.step(commands)
    result.hashes.add w.stateHash()
  result.winner = w.winner
  result.tick = w.tick
  if not ffa():
    result.results = [w.tick.float32, w.winner.float32, w.glory[0].float32, w.glory[1].float32,
      0, 0, 0, 0]
  # Leave the thread as a training thread finds it: no host pin, the default awards.
  kinLayoutPin = none(KinLayout)
  gameMode = gmTeams
  configureMap(""); configureVision(""); configureVisionRange(0); configureGlory(DefaultGloryConfig)

proc nativeHandle(config: string, rules: int, seed: int32, ticks: int): pointer =
  result = pw_create(seed, ticks.int32)
  doAssert result != nil
  var message: string
  doAssert pw_set_rules(result, rules.cint) == 0
  doAssert result.setConfig(config, message) == 0, message
  doAssert pw_reset(result, seed, ticks.int32) == 0
  let source = readFile(Base)
  for slot in 0..<Seats:
    doAssert pw_set_seat_script(result, slot.cint, cbuf(source), source.len.int32) == 0

proc nativeStep(handle: pointer, run: var Run): bool =
  ## One tick with every seat scripted; false once the match is over.
  var actions: Actions
  var rewards, terminals: array[LegacySeats, float32]
  let rc = pw_step(handle, ibuf(actions), fbuf(rewards), fbuf(terminals))
  if rc != 0: return false
  run.hashes.add pw_state_hash(handle)
  discard pw_results(handle, fbuf(run.results))
  run.tick = run.results[0].int
  run.winner = run.results[1].int
  terminals[0] == 0

proc nativeRun(config: string, rules: int, seed: int32, ticks: int): Run =
  let handle = nativeHandle(config, rules, seed, ticks)
  while handle.nativeStep(result): discard
  pw_destroy(handle)

proc firstDifference(got, expected: seq[uint32]): int =
  for t in 0..<min(got.len, expected.len):
    if got[t] != expected[t]: return t+1
  if got.len != expected.len: return min(got.len, expected.len)+1

template checkSame(label: string, got, expected: seq[uint32]) =
  let tick = firstDifference(got, expected)
  if tick != 0: checkpoint label & ": first difference at tick " & $tick
  check tick == 0

suite "Native per-handle rules and game config":
  test "rules and config ABI":
    check pw_rules_latest() == LiveRules
    check LiveRules == replayRulesVersion                  # what live games record
    check pw_set_rules(nil, NativeRules) == -1
    check pw_rules(nil) == -1
    let handle = pw_create(5, 60)
    require handle != nil
    check pw_rules(handle) == NativeRules
    check pw_set_rules(handle, NativeRules-1) == -1
    check pw_set_rules(handle, LiveRules+1) == -1
    check pw_set_rules(handle, LiveRules) == 0
    check pw_rules(handle) == NativeRules                  # the current world keeps its rules
    check pw_reset(handle, 5, 60) == 0
    check pw_rules(handle) == LiveRules
    check pw_reset(handle, 6, 60) == 0                     # kept across resets
    check pw_rules(handle) == LiveRules
    var message: string
    check handle.setConfig("""{"map": "crater", "glory": {"behind_lives": 5}}""", message) == 0
    check message == ""
    check pw_map(handle) == -1
    check pw_reset(handle, 6, 60) == 0
    check pw_map(handle) == mapIndex("crater")
    check handle.setConfig("""{"seed": 1, "max_ticks": 9, "tokens": [], "players": [], "slots": []}""", message) == 0
    check pw_reset(handle, 6, 60) == 0
    # Absent keys take the host's defaults, except "map": the handle keeps crater.
    check pw_map(handle) == mapIndex("crater") and pw_game_mode(handle) == 0
    check handle.setConfig("""{"map": ""}""", message) == 0            # "" is the island
    check pw_reset(handle, 6, 60) == 0
    check pw_map(handle) == -1
    check pw_set_config_json(nil, nil, 0, nil, 0) == -1
    check pw_set_config_json(handle, nil, 3, nil, 0) == -1
    # A config the host refuses is refused with the host's words, and changes nothing.
    for (text, expected) in [
        ("""[]""", "Paintbot config must be an object"),
        ("""{"spawn": 1}""", "Unknown Paintbot config key: spawn"),
        ("""{"glory": {"behind": 5}}""", "Unknown Paintbot glory key: behind"),
        ("""{"glory": {"behind_lives": 1001}}""", ""),
        ("""{"mode": "ffa_kin", "glory": {"behind_lives": 5}}""", "Paintbot glory awards apply to the teams game only"),
        ("""{"kin_layout": "pairs"}""", ""),
        ("""{"mode": "chess"}""", "Unknown Paintbot mode: chess"),
        ("""{"map": "nowhere"}""", "Unknown Paintbot map: nowhere"),
        ("""{"map": 3}""", "Paintbot map must be a string"),
        ("""{"vision": "x-ray"}""", "Unknown Paintbot vision mode: x-ray"),
        ("""{"mode": "ffa_kin", "vision": "team"}""", "Team vision applies to the teams game only"),
        ("""{"vision_range": 0}""", "Paintbot vision_range must be an integer 1..200 (metres)"),
        ("""{"vision_range": 201}""", "Paintbot vision_range must be an integer 1..200 (metres)"),
        ("""{"vision_range": "20"}""", "Paintbot vision_range must be an integer 1..200 (metres)"),
        ("""{"vision_range": 20.5}""", "Paintbot vision_range must be an integer 1..200 (metres)"),
        ("""{"vision": "team", "vision_range": 20}""",
          "Paintbot vision_range applies to per-cog vision only, not \"vision\": \"team\""),
        ("""{"glory": """, "")]:
      checkpoint text
      check handle.setConfig(text, message) == -2
      check message.len > 0
      if expected.len > 0: check message == expected
    check pw_reset(handle, 6, 60) == 0
    check pw_map(handle) == -1 and pw_rules(handle) == LiveRules
    # The same refusals from the host's own paths.
    expect ValueError: applyGameConfig("""{"mode": "ffa_kin", "glory": {"behind_lives": 5}}""")
    expect ValueError: configureMap("nowhere")
    expect ValueError: configureVision("x-ray")
    expect ValueError: applyGameConfig("""{"vision_range": 0}""")
    expect ValueError: configureVisionRange(201)
    kinLayoutPin = none(KinLayout); gameMode = gmTeams
    pw_destroy(handle)

  test "default handles, and explicit defaults, are byte-identical to the library before":
    for (seed, digest, last) in DefaultGolden:
      checkpoint "seed " & $seed
      check defaultRun(seed, false) == (digest, last)
      check defaultRun(seed, true) == (digest, last)

  test "every manifest variant at the live rules == the hosted game's live path":
    let seeds = parseInt(getEnv("PW_CONFIG_SEEDS", "1"))
    let ticks = parseInt(getEnv("PW_CONFIG_TICKS", "300"))
    let report = getEnv("PW_CONFIG_REPORT")
    var lines: seq[string]
    for v in variants():
      for k in 0..<seeds:
        let seed = int32(9100+k)
        checkpoint v.id & " seed " & $seed
        let expected = hostRun(v.config, seed, ticks)
        let got = nativeRun(v.config, LiveRules, seed, ticks)
        checkSame(v.id, got.hashes, expected.hashes)
        check got.winner == expected.winner and got.tick == expected.tick
        if "ffa_kin" notin v.config:
          check got.results[0..3] == expected.results[0..3]  # tick, winner, glory
        if report.len > 0:
          lines.add $(%*{"variant": v.id, "config": parseJson(v.config), "rules": LiveRules,
            "seed": seed, "ticks": expected.tick, "winner": expected.winner,
            "glory": [expected.results[2], expected.results[3]],
            "host_last_hash": (if expected.hashes.len > 0: expected.hashes[^1] else: 0'u32),
            "native_last_hash": (if got.hashes.len > 0: got.hashes[^1] else: 0'u32),
            "identical": firstDifference(got.hashes, expected.hashes) == 0})
    if report.len > 0: writeFile(report, lines.join("\n") & "\n")

  test "configs beyond the manifest's, and older rules, == the hosted game's live path":
    # Keys and values no variant uses today (team vision, other awards, a sampled FFA layout),
    # and the host at older rules against a handle set to them.
    let ticks = parseInt(getEnv("PW_CONFIG_TICKS", "300"))
    for (config, rules) in [("""{"vision": "team", "glory": {"behind_lives": 5}}""", LiveRules),
        ("""{"map": "crater", "vision": "team", "glory": {"quiet_supplies": 0, "heart": 50}}""", LiveRules),
        ("""{"glory": {"quiet_supplies": 40, "quiet_supplies_seconds": 7, "behind_lives_seconds": 2}}""", LiveRules),
        ("""{"mode": "ffa_kin"}""", LiveRules), ("""{"mode": "ffa_kin"}""", NativeRules),
        ("""{"mode": "ffa_kin", "map": "atoll"}""", 43),
        ("""{"map": "highlands", "glory": {"behind_lives": 5}}""", NativeRules),
        ("""{"vision_range": 20, "glory": {"behind_lives": 5}}""", LiveRules),
        ("""{"vision_range": 20}""", NativeRules),
        ("""{"map": "crater", "vision_range": 12}""", LiveRules),
        ("""{"mode": "ffa_kin", "vision_range": 20}""", LiveRules)]:
      checkpoint config & " at rules " & $rules
      let expected = hostRun(config, 77, ticks, rules)
      let got = nativeRun(config, rules, 77, ticks)
      checkSame(config, got.hashes, expected.hashes)
      if "ffa_kin" notin config: check got.results[0..3] == expected.results[0..3]

  test "handles with different rules and configs interleaved on one thread == each alone":
    let ticks = 250
    let specs = [("""{"glory": {"behind_lives": 5}}""", LiveRules, 31'i32),
                 ("""{}""", NativeRules, 32'i32),
                 ("""{"map": "crater", "glory": {"behind_lives": 5, "heart": 50}}""", LiveRules, 33'i32),
                 ("""{"map": "big-twin-mesas", "vision": "team"}""", LiveRules, 34'i32),
                 ("""{"mode": "ffa_kin", "kin_layout": "cousins"}""", LiveRules, 35'i32),
                 ("""{"vision_range": 20}""", LiveRules, 36'i32),
                 ("""{"mode": "ffa_kin", "vision_range": 15}""", LiveRules, 37'i32)]
    var alone: seq[Run]
    for (config, rules, seed) in specs: alone.add nativeRun(config, rules, seed, ticks)
    var handles: seq[pointer]
    var runs = newSeq[Run](specs.len)
    for (config, rules, seed) in specs: handles.add nativeHandle(config, rules, seed, ticks)
    var live = newSeq[bool](specs.len)
    for i in 0..<specs.len: live[i] = true
    while true:
      var any = false
      for i, h in handles:
        if live[i]:
          live[i] = h.nativeStep(runs[i]); any = true
      if not any: break
    for i in 0..<specs.len:
      checkSame("spec " & $i, runs[i].hashes, alone[i].hashes)
      pw_destroy(handles[i])

  test "vision_range changes BASIC play, and a range covering the map changes nothing":
    let unlimited = nativeRun("""{}""", LiveRules, 71, 300)
    check nativeRun("""{"vision_range": 200}""", LiveRules, 71, 300).hashes == unlimited.hashes
    check nativeRun("""{"vision_range": 20}""", LiveRules, 71, 300).hashes != unlimited.hashes
    # A later config without the key restores unlimited sight from the next reset.
    let handle = nativeHandle("""{"vision_range": 20}""", LiveRules, 71, 300)
    var message: string
    check handle.setConfig("""{}""", message) == 0
    check pw_reset(handle, 71, 300) == 0
    let source = readFile(Base)
    for slot in 0..<Seats:
      check pw_set_seat_script(handle, slot.cint, cbuf(source), source.len.int32) == 0
    var got: Run
    while handle.nativeStep(got): discard
    checkSame("range cleared", got.hashes, unlimited.hashes)
    pw_destroy(handle)

  test "a config without \"map\" keeps the handle's pw_set_map map":
    for name in ["crater", "atoll", "big-deep-forest"]:
      checkpoint name
      let league = """{"glory": {"behind_lives": 5}}"""
      let named = """{"map": "$1", "glory": {"behind_lives": 5}}""" % name
      # pw_set_map then a map-less config, in either order, == the config naming the map.
      var message: string
      let expected = nativeRun(named, LiveRules, 61, 200)
      for configFirst in [false, true]:
        let handle = pw_create(61, 200)
        require handle != nil
        check pw_set_rules(handle, LiveRules) == 0
        if configFirst: check handle.setConfig(league, message) == 0
        check pw_set_map(handle, mapIndex(name).cint) == 0
        if not configFirst: check handle.setConfig(league, message) == 0
        check pw_reset(handle, 61, 200) == 0
        check pw_map(handle) == mapIndex(name)
        let source = readFile(Base)
        for slot in 0..<Seats:
          check pw_set_seat_script(handle, slot.cint, cbuf(source), source.len.int32) == 0
        var got: Run
        while handle.nativeStep(got): discard
        checkSame(name & (if configFirst: " config first" else: " map first"), got.hashes, expected.hashes)
        check got.hashes != nativeRun(league, LiveRules, 61, 200).hashes # not Heartwick
        pw_destroy(handle)

  test "rules and config set mid-game leave the current world alone until the next reset":
    let seed = 41'i32
    let control = nativeHandle("{}", NativeRules, seed, 200)
    let handle = nativeHandle("{}", NativeRules, seed, 200)
    var a, b: Run
    for tick in 0..<120:
      if tick == 60:
        var message: string
        check pw_set_rules(handle, LiveRules) == 0
        check handle.setConfig("""{"map": "delta", "glory": {"quiet_supplies": 500}}""", message) == 0
      check control.nativeStep(a) == handle.nativeStep(b)
    checkSame("mid-game", b.hashes, a.hashes)
    check pw_rules(handle) == NativeRules and pw_map(handle) == -1
    pw_destroy(control)
    pw_destroy(handle)
