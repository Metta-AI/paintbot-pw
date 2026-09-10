import std/[os, strutils]
import jsony
import polyworld/[cli, tapes]
import sim, bots
when defined(coworld): import polyworld/coworld

type
  Frame* = object
    commands*: array[Seats, Command]
    hash*: uint32
  LegacyRecording = object
    seed*: int32
    frames*: seq[Frame]
  Communication* = object
    tick*, slot*: int
    text*: string
  Recording* = object
    seed*: int32
    frames*: seq[Frame]
    names*: array[Seats, string]
    communications*: seq[Communication]
proc loadRecording*(path: string): Recording =
  if loadReplayFileHeader(path).gameVersion == 1:
    let old = loadReplayFile(path, "paintbot_pw", 1, LegacyRecording)
    result.seed = old.seed
    result.frames = old.frames
  else:
    result = loadReplayFile(path, "paintbot_pw", 2, Recording)
  if result.frames.len > 28800 or result.communications.len > 20000:
    raise newException(ReplayError, "Replay limits exceeded")
  for i in 0..<Seats:
    if result.names[i].len == 0: result.names[i] = (if team(i) ==
        0: "Ember" else: "Azure") & " " & $(i div 2 + 1)
    if result.names[i].len > 256: raise newException(ReplayError, "Invalid player name")
  for item in result.communications:
    if item.slot notin 0..<Seats or item.tick notin 0..result.frames.len or
        item.text.len > 1024:
      raise newException(ReplayError, "Invalid communication")
var
  world*: World
  recording*: Recording
  replayMode*: bool
  options*: GameOptions
  players: array[Seats, Bot]
  bridge: File
proc setup*() =
  when defined(coworld): options = coworldOptions(Seats)
  else:
    options = GameOptions(seed: 2026, maximumTicks: 7200, speed: 1)
    let args = commandLineParams(); var i = 0
    while i < args.len:
      if not options.takeCommonFlag(args, i, args[i]): raise newException(
          ValueError, "Unknown argument: "&args[i])
      inc i
  replayMode = options.replayPath.len > 0
  if replayMode:
    recording = loadRecording(options.replayPath)
    if recording.frames.len > 28800: raise newException(ValueError, "Replay tick limit exceeded")
    world = newWorld(recording.seed)
  else:
    world = newWorld(options.seed); recording.seed = options.seed
    players = loadBots(options.botGroups)
    when defined(coworld):
      for i in 0..<min(Seats, config.players.len): recording.names[
          i] = config.players[i].name
    if getEnv("PW_POLICY_FD").len > 0:
      if not open(bridge, FileHandle(parseInt(getEnv("PW_POLICY_FD"))),
          fmReadWrite): raise newException(IOError, "Cannot open policy bridge")
proc advance*() =
  if replayMode:
    if world.tick >= recording.frames.len: return
    if world.winner >= 0: raise newException(ReplayError, "Replay has frames after victory")
    let f = recording.frames[world.tick]
    world.step(f.commands)
    if world.stateHash() != f.hash: raise newException(ReplayError,
        "Replay hash mismatch at " & $world.tick)
  else:
    var commands = players.decide(world)
    for slot, messages in shouts:
      for message in messages:
        if recording.communications.len < 20000:
          recording.communications.add Communication(tick: world.tick+1,
              slot: slot, text: message)
    if bridge != nil:
      bridge.writeLine(world.toJson()); bridge.flushFile()
      let external = bridge.readLine().fromJson(seq[tuple[slot: int,
          command: Command, chat: seq[string]]])
      for item in external:
        if item.slot < 0 or item.slot >= Seats: raise newException(ValueError, "Invalid WASM slot")
        commands[item.slot] = item.command
        for message in item.chat:
          if message.len > 1024: raise newException(ValueError, "Communication too long")
          if recording.communications.len < 20000:
            recording.communications.add Communication(tick: world.tick+1,
                slot: item.slot, text: message)
    world.step(commands)
    recording.frames.add Frame(commands: commands, hash: world.stateHash())
proc runHeadless*() =
  setup()
  let limit = if replayMode: recording.frames.len else: options.maximumTicks.int
  while world.tick < limit and world.winner < 0: advance()
  if replayMode and world.tick != limit: raise newException(ReplayError, "Replay has frames after victory")
  if not replayMode and options.recordPath.len > 0: saveReplayFile(
      options.recordPath, "paintbot_pw", 2, recording)
  echo "ticks=", world.tick, " captures=", world.captures, " hash=",
      world.stateHash()
  when defined(coworld):
    finishCoworld(CoworldResults(scores: world.scores(), ticks: world.tick,
        seed: world.seed, outcome: if world.winner <
        0: "time_limit" else: $world.winner))
