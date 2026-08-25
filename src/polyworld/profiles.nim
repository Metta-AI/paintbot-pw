## Opt-in Fluffy profiling.
##
## `{.measure.}` is available in every build. It is a no-op unless a trace
## path is passed at compile time with `-d:profileTracePath=...` or the
## older `-d:mapProfileTracePath=...`.
##
## Graphical clients import silky, which also reads `ProfileTracePath` and
## will restart Fluffy on the first UI frame. Use `mapProfileTracePath`
## for graphics traces so startup blocks are kept.

const
  ProfileTracePath* {.strdefine.} = ""
  MapProfileTracePath* {.strdefine.} = ""
  ProfileFrames* {.intdefine.} = 0
  ActiveTracePath* =
    if ProfileTracePath.len > 0:
      ProfileTracePath
    else:
      MapProfileTracePath

when ActiveTracePath.len > 0:
  import
    std/os,
    fluffy/measure

  export measure

  var
    profileStarted = false
    profileDumped = false
    profileFrameCount = 0

  proc ensureProfileDir() =
    ## Creates the parent directory for the profile trace.
    let dir = ActiveTracePath.parentDir()
    if dir.len > 0:
      createDir(dir)

  proc startProfileTrace*() =
    ## Starts the Fluffy trace capture once.
    if profileStarted:
      return
    profileStarted = true
    ensureProfileDir()
    echo "Profile trace enabled: ", ActiveTracePath
    echo "Profile frames: ", ProfileFrames
    startTrace()

  proc finishProfileTrace*() =
    ## Stops and writes the Fluffy trace capture once.
    if not profileStarted or profileDumped:
      return
    profileDumped = true
    endTrace()
    ensureProfileDir()
    dumpMeasures(ActiveTracePath)

  proc profileShouldDump*(frames: int): bool =
    ## Returns true when the profile frame budget has elapsed.
    ProfileFrames > 0 and frames >= ProfileFrames and not profileDumped

  proc noteProfileFrame*(): bool =
    ## Counts one presented frame. True when the trace budget just finished.
    if not profileStarted or profileDumped:
      return false
    inc profileFrameCount
    if ProfileFrames > 0 and profileFrameCount >= ProfileFrames:
      finishProfileTrace()
      return true
    false

  template profileBlock*(name: string, body: untyped) =
    ## Measures a named block while profiling is enabled.
    measurePush(name)
    try:
      body
    finally:
      measurePop()
else:
  import std/macros

  macro measure*(fn: untyped): untyped =
    ## Leaves a measured procedure unchanged when profiling is disabled.
    fn

  proc startProfileTrace*() =
    ## Leaves profiling disabled.
    discard

  proc finishProfileTrace*() =
    ## Leaves profiling disabled.
    discard

  proc profileShouldDump*(frames: int): bool =
    ## Returns false when profiling is disabled.
    false

  proc noteProfileFrame*(): bool =
    ## Returns false when profiling is disabled.
    false

  template profileBlock*(name: string, body: untyped) =
    ## Runs a block without profiling.
    body
