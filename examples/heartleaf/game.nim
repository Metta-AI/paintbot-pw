## Heartleaf match setup, command line, and the headless runner.
##
## Owns the one live world and decides where each tick's commands come from:
## nine BASIC villagers in a live game, or the recorded action stream when
## replaying. Everything else about a tick is identical between the two,
## which is what makes a replay reproduce its game exactly.

import
  std/[os, strformat, times],
  polyworld/[cli, controllers, profiles, tapes],
  content,
  maps as mapgen,
  sim,
  bots,
  controls,
  replays

proc usage() =
  ## Prints the command-line and compile-time configuration surface.
  echo """
Heartleaf, a village dinner-party week between nine BASIC villagers.

  --bot PATH[:N]   Fill N of the nine villager slots with one program.
  --player         Control villager one; supply eight bots.
  --player:N       Control villager N (1 .. 9); supply eight bots.
  --replay PATH    Play a recorded game instead of running bots.
  --record PATH    Record this game to a replay file.
  --days N         Days in the week (default 7).
  --seed N         Map seed (default 2026).
  --play=false     Start the graphical transport paused.
  --speed N        Graphical start speed: 1, 2, 4, or 16.
  --windowSize WxH Graphical window, such as 800x400.
  --vsync:off      Unlock the frame rate (default on).
  --help           Show this message.

Compile with -d:headless for a command-line game.
Compile with -d:emscripten for the web backend.
Compile with -d:takeScreenshot for a deterministic capture."""

proc parseGameOptions(): (GameOptions, int32) =
  ## Reads the command line into a validated game description.
  var options = GameOptions(
    seed: DefaultSeed,
    speed: 1,
    windowWidth: 1024,
    windowHeight: 576
  )
  var dayCount = DefaultDayCount
  let arguments = commandLineParams()
  var index = 0
  while index < arguments.len:
    let argument = arguments[index]
    if options.takeCommonFlag(arguments, index, argument):
      discard
    else:
      case argument
      of "--days":
        dayCount = parsePositiveInt32(
          arguments.argumentValue(index, "--days"), "--days")
        if dayCount > MaxDayCount:
          fail("--days must be at most " & $MaxDayCount)
      of "--help", "-h":
        usage()
        quit(0)
      else:
        fail("unknown argument: " & argument)
    inc index
  options.setMaximumTicks(gameLengthTicks(dayCount))
  options.validateGameOptions(
    VillagerCount,
    "a live game requires exactly nine bots"
  )
  (options, dayCount)

let
  parsed = parseGameOptions()
  options* = parsed[0]
  optionDays = parsed[1]

var run*: Game

block:
  startProfileTrace()
  var
    mapSeed = options.seed
    dayCount = optionDays
  if options.replayPath.len > 0:
    var replayData: ReplayData
    profileBlock "replay":
      replayData = loadReplay(options.replayPath)
    mapSeed = replayData.header.setup.mapSeed
    dayCount = int32(replayData.header.setup.dayCount)
    var gameMap: MapData
    profileBlock "map":
      gameMap = generateMap(mapSeed)
    gameMap.validateMap()
    if replayData.header.setup.mapHash != gameMap.hash:
      raise newException(ReplayError,
        "this replay was recorded on a different map generator")
    if replayData.header.setup.contentHash != contentHash():
      raise newException(ReplayError,
        "this replay was recorded against different game tuning")
    run = newGame(gameMap, dayCount)
    run.replayMode = true
    run.replayData = replayData
    run.replayPlayer = initReplayPlayer(replayData)
    run.historyPlayback = true
  else:
    var gameMap: MapData
    profileBlock "map":
      gameMap = generateMap(mapSeed)
    gameMap.validateMap()
    run = newGame(gameMap, dayCount)
    let
      kinds = controllerKinds(VillagerCount, options.playerSlot)
      expanded = options.botGroups.expandBotSources(kinds)
    loadBots(run, expanded)
    run.recorder = initReplayRecorder(Setup(
      mapSeed: mapSeed,
      tickRate: uint16(TickRate),
      gridTiles: uint16(GridSide),
      decisionTicks: uint16(DecisionTicks),
      dayCount: uint16(dayCount),
      maximumTicks: uint32(gameLengthTicks(dayCount)),
      mapHash: gameMap.hash,
      contentHash: contentHash()
    ))
    run.replayPlayer = ReplayPlayer(data: run.recorder.data)

proc decide(w: World) =
  ## Supplies one decision tick's commands from whichever source owns them.
  if run.historyPlayback:
    if run.recorder != nil:
      run.replayPlayer.data = run.recorder.data
    var action: ReplayAction
    while run.replayPlayer.takeActionAt(uint32(w.tick), action):
      w.applyReplayAction(action)
  else:
    flushPlayerCommands(run)
    runBotDecisions(run)

proc verifyTick(game: Game) =
  ## Compares one tick against its recorded fingerprint.
  let hashes =
    if game.recorder != nil: game.recorder.data.hashes
    else: game.replayPlayer.data.hashes
  hashes.checkReplayHash(
    uint32(game.world.tick),
    game.stateHash(),
    game.hashCheck
  )

proc advanceGame*() =
  ## Advances the live world by one tick and verifies it when replaying.
  run.world.tickWorld(decide)
  if run.historyPlayback:
    run.verifyTick()
  elif run.recorder != nil:
    run.recorder.recordHash(run.stateHash())

proc saveRecording*() =
  ## Writes the recorded game, trimmed to the tick it actually ended on.
  if run.recorder == nil or options.recordPath.len == 0:
    return
  run.recorder.data.header.setup.maximumTicks = uint32(run.world.tick)
  run.recorder.data.hashes.setLen(run.world.tick)
  let directory = options.recordPath.parentDir
  if directory.len > 0:
    createDir(directory)
  saveReplay(options.recordPath, run.recorder.data)

proc describeResult*(): string =
  ## One line naming the villager with the best week.
  if not run.world.over:
    return "game unfinished"
  var
    best = 0
    tied = false
  for slot in 1 ..< VillagerCount:
    if run.world.villagers[slot].score >
        run.world.villagers[best].score:
      best = slot
      tied = false
    elif run.world.villagers[slot].score ==
        run.world.villagers[best].score:
      tied = true
  if tied:
    &"a tie at {run.world.villagers[best].score} points"
  else:
    &"{VillagerNames[best]} wins with " &
      &"{run.world.villagers[best].score} points"

proc runHeadless*() =
  ## Runs a whole game with no renderer, as fast as the machine allows.
  startProfileTrace()
  defer:
    finishProfileTrace()
  let started = epochTime()
  while run.world.tick < run.maximumTicks and not run.world.over:
    advanceGame()
    if profileShouldDump(run.world.tick):
      finishProfileTrace()
  let
    elapsed = max(epochTime() - started, 0.000001)
    simulated = run.world.tick.float64 / TickRate.float64

  echo &"seed {run.mapSeed}  ticks {run.world.tick}/{run.maximumTicks}  " &
    &"{simulated:.1f}s simulated in {elapsed:.2f}s " &
    &"({simulated / elapsed:.0f}x real time)"
  for slot in 0 ..< VillagerCount:
    let v = run.world.villagers[slot]
    echo &"  {VillagerNames[slot]:>8}  score {v.score:>4}  " &
      &"carrying {v.carriedTotal():>3}  hosted points " &
      &"{run.world.lastTally[slot].hostPoints:>3} on the last night"
  if not run.replayMode:
    for slot in 0 ..< VillagerCount:
      let brain = run.brains[slot]
      if brain == nil:
        continue
      if brain.failed:
        echo &"  {VillagerNames[slot]:>8}  script FAILED: {brain.lastError}"
  echo "  ", describeResult()
  echo &"  {pathSearches} path searches, {pathExpansions} expansions"

  if run.replayMode:
    if not run.replayPlayer.finished:
      echo "error: the replay still had commands left to run"
      quit(1)
    if run.hashCheck.mismatches > 0:
      echo &"error: {run.hashCheck.mismatches} state hash mismatches, " &
        &"first at tick {run.hashCheck.firstTick} " &
        &"(reproduce with --seed {run.mapSeed})"
      quit(1)
    echo "  replay verified: every tick matched its recorded hash"
  else:
    saveRecording()
    if options.recordPath.len > 0:
      echo &"  recorded {run.recorder.data.actions.len} commands to " &
        options.recordPath
