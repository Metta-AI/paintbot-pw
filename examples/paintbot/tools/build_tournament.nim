import std/[os, osproc]

const
  Sources = currentSourcePath().parentDir
  Root = Sources.parentDir.parentDir.parentDir
  Destination = Root / "tmp/paintbot/tools"

createDir(Destination)
for action in ["check", "c"]:
  let command = "nim " & action & " --nimcache:" &
    quoteShell(Destination / "cache") & " -o:" &
    quoteShell(Destination / "tournament") & " " &
    quoteShell(Sources / "tournament.nim")
  if execCmd(command) != 0:
    quit(1)
echo "Runner: ", Destination / "tournament"
