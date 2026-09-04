## Exercises saving and headless verification through each game's runner.
## Compile with -d:headless and a bot roster. The default is Call to Adventure;
## -d:recordGota, -d:recordHlf, or -d:recordLvd selects another game.

import
  std/[os, osproc, strutils]

when defined(recordGota):
  import ../examples/gods_of_the_arena/[game, replays, sim]
elif defined(recordHlf):
  import ../examples/heartleaf/[game, replays, sim]
elif defined(recordLvd):
  import ../examples/light_vs_dark/[game, replays, sim]
else:
  import ../examples/call_to_adventure/[game, replays, sim]

when not defined(headless):
  {.error: "Recording tests require -d:headless.".}

proc playFile(path: string): tuple[output: string, exitCode: int] =
  ## Verifies a replay in a fresh process using the same game runner.
  execCmdEx(quoteShell(getAppFilename()) & " --replay " & quoteShell(path))

proc testRecording() =
  ## Covers empty tapes, partial recordings, rewinds, and failed verification.
  when defined(recordGota):
    startReplayRecording(96)
  let
    directory = getTempDir() / ("polyworld-recording-" & $getCurrentProcessId())
    path = directory / "test.replay"
    setup = run.recorder.data.header.setup
  createDir(directory)
  defer:
    removeDir(directory)

  echo "Testing saving before the first tick"
  saveRecording(path)
  let empty = loadReplay(path)
  doAssert empty.header.setup == setup
  doAssert empty.hashes.len == 0
  let emptyPlayback = playFile(path)
  doAssert emptyPlayback.exitCode == 0, emptyPlayback.output

  echo "Testing partial recordings preserve the simulation setup"
  for i in 0 ..< 24:
    advanceGame()
  let snapshot = run.world.clone()
  for i in 0 ..< 24:
    advanceGame()
  saveRecording(path)
  let partial = loadReplay(path)
  doAssert partial.header.setup == setup
  doAssert partial.hashes.len == 48
  doAssert partial.actions.len > 0
  doAssert run.recorder.data.header.setup == setup
  let partialPlayback = playFile(path)
  doAssert partialPlayback.exitCode == 0, partialPlayback.output

  echo "Testing a rewind does not shorten the saved recording"
  run.world.restore(snapshot)
  saveRecording(path)
  let rewound = loadReplay(path)
  doAssert rewound == partial
  doAssert run.recorder.data == partial
  let rewoundPlayback = playFile(path)
  doAssert rewoundPlayback.exitCode == 0, rewoundPlayback.output

  echo "Testing divergent replays exit with failure"
  var corrupt = partial
  corrupt.hashes[0] = corrupt.hashes[0] xor 1
  saveReplay(path, corrupt)
  let corruptPlayback = playFile(path)
  doAssert corruptPlayback.exitCode != 0, corruptPlayback.output
  doAssert corruptPlayback.output.contains("first at tick 1"),
    corruptPlayback.output
  echo "Recording tests passed"

if run.replayMode:
  runHeadless()
else:
  testRecording()
