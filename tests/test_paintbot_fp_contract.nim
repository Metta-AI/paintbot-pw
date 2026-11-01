## Floating-point contraction is a build-wide policy, set at the simulation boundary: sim.nim and
## neural_actor.nim both import fp_policy, which compiles every build containing either with
## -ffp-contract=off (gcc, clang). Before it, only neural_actor set the flag, so a build that
## imported the simulation without the actor took the compiler's default, which fuses a*b + c on an
## FMA target, and a scripted match then ended differently (see paintbot_fp_contract_witness.nim).
##
## This test builds the witness several ways, each with its own nimcache, and requires every build
## to round without fusing and to end the seed-30 match the same way:
##   default     the host compiler's own flags
##   fma         gcc/clang targeting x86-64-v3 (FMA, AVX2) on x86-64; on arm64 every build has FMA
##   fma+actor   as fma, and the witness also imports the neural actor
## On Linux x86-64 the result is also pinned to what an x86-64 baseline gcc build (no FMA, as the
## hosted game is built) computes.
import std/[unittest, os, osproc, strutils]

const
  Root = currentSourcePath().parentDir.parentDir
  Witness = Root / "tests" / "paintbot_fp_contract_witness.nim"
  # Linux x86-64, gcc without FMA (x86-64 baseline, or -ffp-contract=off): paintbot-pw e4b3305.
  PinnedMatch = "match teams seed=30 ticks=2620 winner=1 stateChain=2977D55554D087B3 final=75A5EE1E"

proc fmaHost(): bool =
  ## Whether this machine runs x86-64-v3 code. Only Linux is asked; GitHub's x86-64 runners all do.
  when defined(linux):
    let flags = readFile("/proc/cpuinfo")
    " fma " in flags and " avx2 " in flags and " bmi2 " in flags and " movbe " in flags
  else:
    true

proc builds(): seq[(string, seq[string])] =
  result.add ("default", newSeq[string]())
  when defined(amd64):
    if fmaHost():
      result.add ("fma", @["--passC:-march=x86-64-v3", "--passL:-march=x86-64-v3"])
      result.add ("fma+actor", @["--passC:-march=x86-64-v3", "--passL:-march=x86-64-v3", "-d:withNeuralActor"])
    else:
      echo "  this x86-64 CPU cannot run x86-64-v3 code: only the actor build is compared"
      result.add ("actor", @["-d:withNeuralActor"])
  else:
    # arm64 always has FMA, and clang's default contracts within an expression.
    result.add ("actor", @["-d:withNeuralActor"])

proc buildAndRun(name: string, flags: seq[string], dir: string): seq[string] =
  let tag = name.replace("+", "_")
  let exe = dir / ("witness_" & tag).addFileExt(ExeExt)
  var args = @["c", "--hints:off", "--verbosity:0", "--nimcache:" & (dir / ("cache_" & tag)), "-o:" & exe]
  args.add flags
  args.add Witness
  let build = execCmdEx(quoteShellCommand(@[getCurrentCompilerExe()] & args), workingDir = Root)
  if build.exitCode != 0:
    checkpoint build.output
    raise newException(OSError, name & " build failed")
  let run = execCmdEx(quoteShell(exe), workingDir = Root)
  if run.exitCode != 0:
    checkpoint run.output
    raise newException(OSError, name & " witness failed")
  result = run.output.strip.splitLines
  echo "  ", name, ": ", result.join(" | ")

suite "FP contraction: sim-only, FMA and actor builds end the seed-30 match the same way":
  test "every build rounds c + a*b twice and ends the witness match identically":
    let dir = getTempDir() / ("paintbot_fp_contract_" & $getCurrentProcessId())
    createDir(dir)
    defer: removeDir(dir)
    var outputs: seq[(string, seq[string])]
    for (name, flags) in builds():
      outputs.add (name, buildAndRun(name, flags, dir))
    for (name, lines) in outputs:
      checkpoint name
      check lines.len == 2
      check lines[0] == "fused=0"
      check lines == outputs[0][1]
    when defined(linux) and defined(amd64):
      check outputs[0][1][1] == PinnedMatch
