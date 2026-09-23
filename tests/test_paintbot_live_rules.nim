## Normal live launch must record exactly the rules it actually executes.
import std/[os, osproc]
import polyworld/tapes
import ../examples/paintbot/[sim, game]
if "--replay" in commandLineParams():
  runHeadless()
else:
  setup() # Use the normal CLI setup path, without assigning any rules globals.
  doAssert visionRulesVersion == replayRulesVersion
  doAssert replayRulesVersion == 38
  doAssert world.glory == [world.endTick div TickRate, world.endTick div TickRate]
  for i in 0..<48: advance()
  let path = getTempDir() / ("paintbot-live-rules-" & $getCurrentProcessId() & ".replay")
  defer: removeFile(path)
  saveReplayFile(path, "paintbot_pw", replayRulesVersion.uint16, recording)
  let verification = execCmdEx(quoteShell(getAppFilename()) & " --replay " & quoteShell(path))
  doAssert verification.exitCode == 0, verification.output
  echo "Normal live rules and replay hash roundtrip verified"
