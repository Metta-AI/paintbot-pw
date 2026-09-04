## Checks the shared recorder and the game-specific frame budget.

import
  std/[os, strutils],
  silky/profiles as silkyProfiles,
  polyworld/profiles

echo "Testing Polyworld uses Silky's profile state"
when ActiveTracePath.len > 0:
  startGameProfile()
  doAssert silkyProfiles.profileTraceActive()
  startGameProfile()
  profileBlock "game startup":
    discard
  for i in 0 ..< 5:
    beginProfileFrame()
    profileBlock "loading splash":
      discard
    endProfileFrame()
  doAssert silkyProfiles.profileTraceActive()
  when ProfileFrames > 0:
    for i in 1 ..< ProfileFrames:
      doAssert not noteProfileFrame()
    doAssert noteProfileFrame()
  else:
    finishGameProfile()
  doAssert not silkyProfiles.profileTraceActive()
  doAssert not noteProfileFrame()
  doAssert fileExists(ActiveTracePath)
  doAssert "game startup" in readFile(ActiveTracePath)
  doAssert "loading splash" in readFile(ActiveTracePath)
else:
  startGameProfile()
  doAssert not silkyProfiles.profileTraceActive()

block:
  let path = getTempDir() / "polyworld-runtime-profile.json"
  doAssert toggleRuntimeProfileTrace(path) == ""
  doAssert profileTraceActive()
  silkyProfiles.profileBlock "shared runtime recorder":
    discard
  doAssert not noteProfileFrame()
  doAssert toggleRuntimeProfileTrace(path) == path
  doAssert not profileTraceActive()
  doAssert "shared runtime recorder" in readFile(path)
  removeFile(path)

echo "Profile tests passed"
