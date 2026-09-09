## Gods of the Arena match setup, command line, and the headless runner.
##
## Owns the one live match and decides where each tick's hero commands
## come from: ten BASIC programs, or the recorded action stream when
## replaying.

import
  std/[math, os, strformat, strutils, times],
  polyworld/[cli, profiles, tapes],
  content,
  maps,
  sim,
  bots,
  controls,
  replays

when defined(coworld):
  import polyworld/coworld

proc usage() =
  ## Prints the command-line and compile-time configuration surface.
  echo "Gods of the Arena"
  echo "  --bot:PATH              Fill one of the 10 hero slots."
  echo "  --bot:PATH:N            Fill N of the 10 slots with that file."
  echo "  --bot PATH[:N]          The equivalent two-argument form."
  echo "  --player                Control the first hero; supply 9 bots."
  echo "  --player:N              Control hero N (1-10); supply 9 bots."
  echo "  --replay PATH           Play an action replay instead of bots."
  echo "  --record PATH           Record bot actions to a replay."
  echo "  --seconds NUMBER        Duration in seconds (default 1200)."
  echo "  --minutes NUMBER        Duration in minutes (default 20)."
  echo "  --ticks NUMBER          Duration in ticks (default 28800)."
  echo "  --seed NUMBER           Live game map seed."
  echo "  --spawn-interval NUMBER Seconds between waves."
  echo "  --play=false            Start the graphical transport paused."
  echo "  --speed NUMBER          Graphical start speed: 1, 2, 4, or 16."
  echo "  --windowSize WxH        Graphical window, such as 1024x576."
  echo "  --vsync:off             Unlock the frame rate (default on)."
  echo "Compile with -d:headless for command-line simulation."
  echo "Compile with -d:emscripten for the web backend."

proc parseGameOptions(): GameOptions =
  ## Parses runtime game, bot, replay, and simulation configuration.
  result = GameOptions(
    seed: 2026,
    seconds: DefaultMinutes * 60,
    maximumTicks: DefaultDurationTicks,
    spawnIntervalTicks: 10 * TickRate.int32,
    speed: 1,
    windowWidth: 1920,
    windowHeight: 1080
  )
  let arguments = commandLineParams()
  var index = 0
  while index < arguments.len:
    let argument = arguments[index]
    if result.takeCommonFlag(arguments, index, argument):
      discard
    else:
      case argument
      of "--spawn-interval":
        var seconds: float64
        try:
          seconds = parseFloat(
            arguments.argumentValue(index, "--spawn-interval")
          )
        except ValueError:
          fail("--spawn-interval must be a number")
        if seconds <= 0:
          fail("--spawn-interval must be positive")
        if seconds > int32.high.float64 / TickRate.float64:
          fail("--spawn-interval is too large")
        result.spawnIntervalTicks = int32(round(
          seconds * TickRate.float64
        ))
        if result.spawnIntervalTicks <= 0:
          fail("--spawn-interval must be positive")
      of "--help", "-h":
        usage()
        quit(0)
      else:
        fail("unknown argument: " & argument)
    inc index
  result.validateGameOptions(
    HeroClassCount,
    "live games require exactly 10 bots"
  )

var options* =
  when defined(coworld):
    coworldOptions(10)
  else:
    parseGameOptions()

var run*: Game

block:
  startGameProfile()
  var
    replayMode = options.replayPath.len > 0
    mapSeed = options.seed
    replayData: ReplayData
  if replayMode:
    profileBlock "replay":
      replayData = loadReplay(options.replayPath)
    mapSeed = replayData.header.setup.mapSeed
  var gameMap: MapData
  profileBlock "map":
    gameMap = generateMap(mapSeed)
  run = newGame(
    gameMap,
    if replayMode:
      int32(replayData.header.setup.spawnIntervalTicks)
    else:
      options.spawnIntervalTicks,
    if replayMode: 0 else: HeroClassCount,
    replayMode,
    replayData
  )
  if replayMode:
    run.replayPlayer = initReplayPlayer(replayData)
    run.historyPlayback = true
  else:
    loadBots(run, options.botGroups, options.playerSlot)

proc advanceGame*() =
  ## Advances one tick, including live BASIC decisions.
  tickWorld(run, proc() =
    flushPlayerCommands(run)
    runBotDecisions(run)
  )

## Headless reporting and replay recording.

proc teamHeroLevels(team: Team): string =
  ## Formats the current hero levels for one team.
  for hero in run.world.heroes:
    if hero.team != team:
      continue
    if result.len > 0:
      result.add " "
    result.add "L" & $hero.level

proc teamHeroXp(team: Team): int =
  ## Returns all lifetime XP earned by one team's heroes.
  for hero in run.world.heroes:
    if hero.team == team:
      result += hero.totalXp

proc teamHeroGold(team: Team): int =
  ## Returns all unspent gold earned by one team's heroes.
  for hero in run.world.heroes:
    if hero.team == team:
      result += hero.gold

proc teamTowerCount(team: Team): int =
  ## Returns the number of standing towers owned by one team.
  for tower in run.world.towers:
    if tower.team == team and tower.hp > 0:
      inc result

proc heroVmStatus*(): tuple[active, decisions: int] =
  ## Reports live VM decisions or consumed replay actions.
  if run.replayMode:
    result.active = run.world.heroes.len
    result.decisions = run.replayPlayer.actionIndex
  else:
    for vm in run.heroVms:
      if vm != nil and not vm.failed:
        inc result.active
      if vm != nil:
        result.decisions += vm.decisions

proc startReplayRecording*(maximumTicks: uint32) =
  ## Starts the in-memory action tape for a live match.
  run.recorder = initReplayRecorder(
    currentSetup(run, maximumTicks)
  )
  run.replayPlayer = ReplayPlayer(data: run.recorder.data)

proc saveRecording*(path = options.recordPath) =
  ## Finalizes and saves a requested action replay.
  if run.recorder == nil or path.len == 0:
    return
  saveReplay(path, run.recorder.data)
  echo &"replay saved: {path} " &
    &"({run.recorder.data.actions.len} actions)"

when defined(headless):
  const HeadlessTickRate = TickRate

  proc printHeadlessSummary(steps: int, started: float64) =
    ## Prints the deterministic result and measured execution speed.
    let
      elapsed = max(epochTime() - started, 0.000001)
      simulated = steps.float64 / HeadlessTickRate.float64
      speedup = simulated / elapsed
      vmStatus = heroVmStatus()
      redFortHp = max(run.world.forts[0].hp, 0'i32)
      blueFortHp = max(run.world.forts[1].hp, 0'i32)
      outcome =
        if run.world.gameOver:
          if run.world.winner == RedTeam: "red won" else: "blue won"
        else:
          "time limit"
    echo &"result: {outcome}"
    echo &"simulated: {simulated:.2f} s in {elapsed:.4f} s " &
      &"({speedup:.1f}x real time)"
    echo &"forts: red {redFortHp} hp, blue {blueFortHp} hp"
    echo &"towers: red {teamTowerCount(RedTeam)}, " &
      &"blue {teamTowerCount(BlueTeam)}"
    echo &"hash: {run.stateHash().toHex(16)} map " &
      &"{run.map.hash.toHex(16)}"
    echo &"heroes: red {teamHeroLevels(RedTeam)}, " &
      &"blue {teamHeroLevels(BlueTeam)}"
    echo &"economy: red {teamHeroXp(RedTeam)} XP / " &
      &"{teamHeroGold(RedTeam)} gold, blue {teamHeroXp(BlueTeam)} XP / " &
      &"{teamHeroGold(BlueTeam)} gold"
    if run.replayMode:
      echo &"replay: {vmStatus.decisions}/" &
        &"{run.replayData.actions.len} actions"
      if run.hashCheck.mismatches > 0:
        echo &"replay hashes: {run.hashCheck.mismatches} mismatches"
    else:
      echo &"scripts: {vmStatus.active}/{run.world.heroes.len} active, " &
        &"{vmStatus.decisions} decisions"

  proc runHeadless*() =
    ## Runs a live game or replay immediately with fixed simulation ticks.
    let
      stepLimit =
        if run.replayMode:
          run.replayData.hashes.len
        else:
          int(options.maximumTicks)
      started = epochTime()
    if not run.replayMode:
      startReplayRecording(uint32(stepLimit))
    startGameProfile()
    defer:
      finishGameProfile()
    var steps = 0
    while steps < stepLimit and
        (run.replayMode or not run.world.gameOver) and
        run.recordingError.len == 0:
      advanceGame()
      inc steps
      if profileShouldDump(steps):
        finishGameProfile()
    if run.recordingError.len > 0:
      raise newException(ReplayError, run.recordingError)
    if run.replayMode:
      run.hashCheck.requireReplayComplete(
        uint32(run.world.tick),
        run.replayData.hashes.len
      )
      if not run.replayPlayer.finished:
        raise newException(
          ReplayError,
          "replay simulation did not consume every action"
        )
    else:
      saveRecording()
    printHeadlessSummary(steps, started)
