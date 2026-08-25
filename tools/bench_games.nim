## Times a default headless match of each Polyworld game.
##
## Compiles Light vs Dark, Gods of the Arena, and Call to Adventure with
## `-d:headless`, runs each with its stock `base.bas` bots for the default
## twenty minutes, and prints a wall-clock table.
##
## Run from the repository root:
##   nim r tools/bench_games.nim

import
  std/[os, osproc, streams, strutils, times]

type
  GameBench = object
    name*: string
    source*: string
    bot*: string

const
  Benches = [
    GameBench(
      name: "Light vs Dark",
      source: "examples/light_vs_dark/lvd.nim",
      bot: "examples/light_vs_dark/players/base.bas:2"
    ),
    GameBench(
      name: "Gods of the Arena",
      source: "examples/gods_of_the_arena/gota.nim",
      bot: "examples/gods_of_the_arena/players/base.bas:10"
    ),
    GameBench(
      name: "Call to Adventure",
      source: "examples/call_to_adventure/cta.nim",
      bot: "examples/call_to_adventure/players/base.bas:4"
    )
  ]

proc runLogged(command: string, args: seq[string]): (string, int) =
  ## Runs a process and returns its combined output and exit code.
  let process = startProcess(
    command = command,
    args = args,
    options = {poStdErrToStdOut, poUsePath}
  )
  result[0] = process.outputStream.readAll()
  result[1] = waitForExit(process)
  close(process)

proc compileHeadless(source, outputPath: string) =
  ## Builds one game as a release headless binary.
  echo "Compiling ", source
  createDir(outputPath.parentDir)
  let (output, code) = runLogged("nim", @[
    "c",
    "-d:release",
    "-d:headless",
    "--hints:off",
    "-o:" & outputPath,
    source
  ])
  if code != 0:
    quit(output, 1)

proc timeMatch(binary, bot: string): float64 =
  ## Runs one default-length headless match and returns wall seconds.
  echo "Running ", binary.extractFilename
  let started = epochTime()
  let (output, code) = runLogged(binary, @["--bot", bot])
  result = epochTime() - started
  if code != 0:
    echo output
    quit("headless match failed: " & binary, 1)

proc printTable(names: openArray[string], seconds: openArray[float64]) =
  ## Prints an aligned wall-clock table.
  echo ""
  echo alignLeft("Game", 20), " ", align("Seconds", 8)
  echo repeat("-", 20), " ", repeat("-", 8)
  for i, name in names:
    echo alignLeft(name, 20), " ",
      align(formatFloat(seconds[i], ffDecimal, 2), 8)

if not fileExists(Benches[0].source):
  quit("Run this from the polyworld repository root.", 1)

let cache = getTempDir() / "polyworld-bench"
var
  names: seq[string]
  seconds: seq[float64]
for bench in Benches:
  let binary = cache / bench.source.splitFile.name
  compileHeadless(bench.source, binary)
  names.add bench.name
  seconds.add timeMatch(binary, bench.bot)
printTable(names, seconds)
