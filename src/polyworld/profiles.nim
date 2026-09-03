## Fluffy profiling for Polyworld.
##
## `{.measure.}` and `profileBlock` always record while a trace is active.
## Compile-time capture: `-d:profileTracePath=tmp/x.json -d:profileFrames=100`.
## Runtime capture: F2 starts a trace, F2 again writes tmp/fluffy.json and
## opens the Fluffy viewer.

import
  std/os,
  fluffy/measure

when not defined(emscripten):
  import std/osproc

export measure

const
  ProfileTracePath* {.strdefine.} = ""
  MapProfileTracePath* {.strdefine.} = ""
  ProfileFrames* {.intdefine.} = 0
  RuntimeTracePath* = "tmp/fluffy.json"
  ActiveTracePath* =
    if ProfileTracePath.len > 0:
      ProfileTracePath
    else:
      MapProfileTracePath

var
  profileStarted = false
  profileDumped = false
  profileFrameCount = 0
  runtimeTracing = false

proc ensureProfileDir(path: string) =
  ## Creates the parent directory for the profile trace.
  let dir = path.parentDir()
  if dir.len > 0:
    createDir(dir)

proc startProfileTrace*() =
  ## Starts the compile-time Fluffy capture once.
  if profileStarted:
    return
  when ActiveTracePath.len > 0:
    profileStarted = true
    ensureProfileDir(ActiveTracePath)
    echo "Profile trace enabled: ", ActiveTracePath
    echo "Profile frames: ", ProfileFrames
    startTrace()

proc finishProfileTrace*() =
  ## Stops and writes the compile-time Fluffy capture once.
  when ActiveTracePath.len > 0:
    if not profileStarted or profileDumped:
      return
    profileDumped = true
    endTrace()
    ensureProfileDir(ActiveTracePath)
    dumpMeasures(ActiveTracePath)

proc profileShouldDump*(frames: int): bool =
  ## Returns true when the compile-time frame budget has elapsed.
  ProfileFrames > 0 and frames >= ProfileFrames and not profileDumped

proc noteProfileFrame*(): bool =
  ## Counts one presented frame. True when the compile-time budget finished.
  if not profileStarted or profileDumped:
    return false
  inc profileFrameCount
  if ProfileFrames > 0 and profileFrameCount >= ProfileFrames:
    finishProfileTrace()
    return true
  false

template profileBlock*(name: string, body: untyped) =
  ## Measures a named block while a Fluffy trace is active.
  measurePush(name)
  try:
    body
  finally:
    measurePop()

proc fluffyNimPath(): string =
  ## Finds the Fluffy viewer next to this repo.
  let
    fromHere = currentSourcePath().parentDir / "../../.." / "fluffy" / "src" / "fluffy.nim"
    fromCwd = getCurrentDir() / ".." / "fluffy" / "src" / "fluffy.nim"
  if fileExists(fromHere):
    return fromHere.normalizedPath
  if fileExists(fromCwd):
    return fromCwd.normalizedPath
  ""

proc openFluffy(path: string) =
  ## Opens the written trace in the Fluffy viewer.
  when defined(emscripten):
    discard
  else:
    let
      absPath = path.absolutePath
      fluffyNim = fluffyNimPath()
    if fluffyNim.len == 0:
      echo "Fluffy viewer not found; open ", absPath, " by hand"
      return
    let fluffyRoot = fluffyNim.parentDir.parentDir
    echo "Opening Fluffy: ", absPath
    discard startProcess(
      "nim",
      workingDir = fluffyRoot,
      args = ["r", "src/fluffy.nim", absPath],
      options = {poUsePath}
    )

proc toggleRuntimeTrace*() =
  ## F2: start a runtime capture, or write it and open Fluffy.
  when defined(emscripten):
    discard
  else:
    if runtimeTracing:
      endTrace()
      ensureProfileDir(RuntimeTracePath)
      dumpMeasures(RuntimeTracePath)
      runtimeTracing = false
      if fileExists(RuntimeTracePath):
        openFluffy(RuntimeTracePath)
    else:
      startTrace()
      runtimeTracing = true
      echo "Runtime Fluffy trace started; F2 writes ", RuntimeTracePath
