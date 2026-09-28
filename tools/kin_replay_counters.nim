## kin-replay-counters: the FFA-kin pair counters (pw_pair_stats) of recorded Heartland matches.
##
## Loads each replay with game.loadRecording (gameVersion 1040: the recorded kinship, seed and
## end tick), rebuilds the match in a training-library handle (native_env: FFA mode, the recorded
## kinship as an eval override), drives every seat with its recorded command through
## pw_set_seat_command and checks every frame's state hash, so the counters are exactly the ones a
## live pw_step match would have counted. Engine files are untouched: this is a client of the
## native ABI, compiled into one executable.
##
## Output: one JSON object per replay per line on stdout (tools/kin_replay_stats.py reads it):
##   {"path", "seed", "ticks", "end_tick", "names": [16], "family": [16], "layout", "r": [256],
##    "genes": [16], "pairs": [16*16*13], "seat": [48] (pw_kin_seat_stats), "scores": [16] (R_i),
##    "results": [8]}
## or {"path", "error"} when the replay cannot be read or does not reproduce.
##
## It can also record a short local FFA-kin match (every seat running one BASIC file), which the
## smoke test uses so it never depends on a replay recorded under older rules:
##   kin-replay-counters --record OUT.replay --bot FILE.bas [--bot ...] [--seed N] [--ticks N] [--layout N]
##
## Build (from the repository root; POLYWORLD_DEPS as for any build):
##   nim c --mm:arc --threads:on -d:pwTraining -d:headless -d:release -o:tmp/kin-replay-counters \
##     tools/kin_replay_counters.nim
## Run: tmp/kin-replay-counters REPLAY [REPLAY ...]      (hosted replays are gzipped: gunzip first)
import std/[os, json, strutils, options]
import polyworld/cli
import ../examples/paintbot/[sim, game, bots, kinship, native_env]

when not defined(pwTraining): {.error: "kin_replay_counters needs -d:pwTraining".}

const PairInts = Seats * Seats * PairStatCount

proc commandInts(c: Command): array[9, int32] =
  [int32(c.walk), c.goal.x, c.goal.z, int32(c.shoot), c.aim.x, c.aim.z,
   int32(c.chargeGrenade), int32(c.sneak), int32(c.direct)]

proc counters(path: string): JsonNode =
  result = %*{"path": path}
  var r: Recording
  try:
    r = loadRecording(path)
  except CatchableError as e:
    result["error"] = %("cannot load: " & e.msg)
    return
  if gameMode != gmFfaKin:
    result["error"] = %"not an FFA-kin (gameVersion 1040) replay"
    return
  let k = activeKinship
  if r.endTick > HeartMeterMatchTicks:
    result["error"] = %("end tick " & $r.endTick & " exceeds the library limit")
    return
  let h = pw_create(r.seed, r.endTick.int32)
  defer: pw_destroy(h)
  var family: array[Seats, int8]
  var genes: array[Seats, uint32]
  var ibd: array[Seats * Seats, int8]
  for i in 0..<Seats:
    family[i] = k.family[i]
    genes[i] = k.genes[i]
    for j in 0..<Seats: ibd[i * Seats + j] = k.ibd[i][j]
  doAssert pw_set_game_mode(h, 1) == 0
  doAssert pw_set_kin_layout(h, k.layout.ord.int32) == 0
  doAssert pw_set_kin_override(h, cast[ptr UncheckedArray[int8]](addr family[0]),
    cast[ptr UncheckedArray[uint32]](addr genes[0]), cast[ptr UncheckedArray[int8]](addr ibd[0])) == 0
  doAssert pw_reset(h, r.seed, r.endTick.int32) == 0
  var actions: array[Seats * 5, int32]
  var rewards, terminals: array[Seats, cfloat]
  var res: array[8, cfloat]
  var ticks = 0
  for f in r.frames:
    for s in 0..<Seats:
      var nine = commandInts(f.commands[s])
      doAssert pw_set_seat_command(h, s.cint, cast[ptr UncheckedArray[int32]](addr nine[0])) == 0
    doAssert pw_step(h, cast[ptr UncheckedArray[int32]](addr actions[0]),
      cast[ptr UncheckedArray[cfloat]](addr rewards[0]), cast[ptr UncheckedArray[cfloat]](addr terminals[0])) == 0
    inc ticks
    if pw_state_hash(h) != f.hash:
      result["error"] = %("hash mismatch at tick " & $ticks &
        " (replay recorded under different rules than this build)")
      return
  var pairs: array[PairInts, int32]
  var seat: array[48, cfloat]
  var kin: array[Seats * Seats, cfloat]
  var scores: array[Seats, cfloat]
  var libGenes: array[Seats, uint32]
  doAssert pw_pair_stats(h, cast[ptr UncheckedArray[int32]](addr pairs[0])) == 0
  doAssert pw_kin_seat_stats(h, cast[ptr UncheckedArray[cfloat]](addr seat[0])) == 0
  doAssert pw_kin(h, cast[ptr UncheckedArray[cfloat]](addr kin[0])) == 0
  doAssert pw_scores(h, cast[ptr UncheckedArray[cfloat]](addr scores[0])) == 0
  doAssert pw_genes(h, cast[ptr UncheckedArray[uint32]](addr libGenes[0])) == 0
  doAssert pw_results(h, cast[ptr UncheckedArray[cfloat]](addr res[0])) == 0
  var names = newJArray()
  for i in 0..<Seats: names.add %r.names[i]
  result["seed"] = %r.seed
  result["ticks"] = %ticks
  result["end_tick"] = %r.endTick
  result["names"] = names
  result["layout"] = %k.layout.ord
  result["family"] = %(@family)
  result["genes"] = %(@libGenes)
  result["r"] = %(@kin)
  result["pairs"] = %(@pairs)
  result["seat"] = %(@seat)
  result["scores"] = %(@scores)
  result["results"] = %(@res)

proc recordMatch(output: string, bots: seq[string], seed, ticks, layout: int32) =
  ## A local FFA-kin match recorded as game.advance records a live one: the seats split evenly
  ## over `bots` in seat order, each seat named after its file (the per-policy readout key).
  replayRulesVersion = 40
  visionRulesVersion = 40
  configureRules(40)
  gameMode = gmFfaKin
  kinshipOverride = (if layout >= 0: some(kinshipFor(KinLayout(layout), seed)) else: none(Kinship))
  var groups: seq[BotGroup]
  var names: seq[string]
  for n, bot in bots:
    let count = Seats div bots.len + (if n < Seats mod bots.len: 1 else: 0)
    groups.add BotGroup(path: bot, count: count)
    for _ in 0..<count: names.add bot.extractFilename
  var players = loadBots(groups)
  world = newWorld(seed, ticks)
  var rec = Recording(seed: seed, endTick: world.endTick)
  for i in 0..<Seats: rec.names[i] = names[i]
  while world.winner == -1:
    let commands = players.decide(world)
    deliverSpeech(world)
    world.step(commands)
    rec.frames.add Frame(commands: commands, hash: world.stateHash())
  for slot in 0..<Seats:
    if players[slot].failed: quit("seat " & $slot & " failed to run " & names[slot], 1)
  saveRecording(output, rec)
  kinshipOverride = none(Kinship)
  gameMode = gmTeams

when isMainModule:
  let args = commandLineParams()
  if args.len == 0:
    quit("usage: kin-replay-counters REPLAY [...] | --record OUT --bot FILE [--seed N] [--ticks N] [--layout N]", 2)
  if args[0] == "--record":
    var output = ""
    var bots: seq[string]
    var seed = 2026'i32
    var layout = -1'i32
    var ticks = 600'i32
    var i = 1
    while i < args.len:
      let value = if i + 1 < args.len: args[i + 1] else: ""
      case args[i]
      of "--bot": bots.add value
      of "--seed": seed = parseInt(value).int32
      of "--ticks": ticks = parseInt(value).int32
      of "--layout": layout = parseInt(value).int32
      else: output = args[i]; i -= 1
      i += 2
    if output.len == 0 or bots.len == 0: quit("--record needs OUT and --bot FILE", 2)
    recordMatch(output, bots, seed, ticks, layout)
    echo output
  else:
    for path in args:
      echo $counters(path)
