## The SeatView perception boundary (docs/neural/seat-view.md, item 7), enforced on the source:
## seat_view.nim is the only perception module that may read the world. The neural modules
## import neither `sim` nor anything else that names the world type; bots.nim's host() (the
## BASIC builtins) names neither the world type nor the old `active` world; and the training-only
## privileged labels (training_labels.nim) are imported by the native training library alone
## and refuse to compile without -d:pwTraining.
import std/[unittest, os, strutils, osproc]

const
  Root = currentSourcePath().parentDir.parentDir
  Paintbot = Root / "examples/paintbot"
  NeuralModules = ["neural_contract.nim", "neural_actor.nim", "neural_host.nim"]

proc imports(text: string): seq[string] =
  ## Every module an `import` / `from ... import` / `include` line names (last path segment).
  for line in text.splitLines:
    let s = line.strip
    var names = ""
    if s.startsWith("import ") or s.startsWith("include "): names = s.split(maxsplit = 1)[1]
    elif s.startsWith("from ") and " import " in s: names = s.split(maxsplit = 2)[1]
    else: continue
    names = names.replace("[", ",").replace("]", ",")
    for part in names.split(','):
      let n = part.strip.split(' ')[0]
      if n.len > 0: result.add n.split('/')[^1]

proc hasWord(text, word: string): bool =
  ## Whether `word` occurs in `text` as a whole identifier (not inside a longer one).
  const ident = {'a'..'z', 'A'..'Z', '0'..'9', '_'}
  var at = text.find(word)
  while at >= 0:
    let before = at == 0 or text[at-1] notin ident
    let after = at + word.len >= text.len or text[at+word.len] notin ident
    if before and after: return true
    at = text.find(word, at + 1)
  false

proc hostBody(text: string): string =
  ## The text of bots.nim's host() proc: from its header to the next top-level proc.
  let start = text.find("proc host(")
  doAssert start >= 0, "bots.nim has no host() proc"
  let next = text.find("\nproc ", start + 1)
  doAssert next > start
  text[start ..< next]

suite "SeatView boundary":
  test "the neural modules neither import sim nor name the world type":
    for name in NeuralModules:
      let text = readFile(Paintbot / name)
      let mods = imports(text)
      check "sim" notin mods
      check "mechanics" notin mods
      check "training_labels" notin mods
      check not text.hasWord("World")
      if "sim" in mods or text.hasWord("World"): echo "boundary broken in ", name

  test "bots.nim host() reads only SeatView: no World, no `active`":
    let body = hostBody(readFile(Paintbot / "bots.nim"))
    check body.contains("seatView(slot)")
    check not body.hasWord("World")
    check not body.hasWord("active")

  test "the probe itself catches a violation":
    check "sim" in imports("import std/math\nimport sim, kinship\n")
    check "sim" in imports("import ../examples/paintbot/[sim, bots]\n")
    check "sim" in imports("from sim import World\n")
    check "WorldView x".hasWord("World") == false and "a World.".hasWord("World")
    check hostBody("proc host(slot: int) =\n  discard active.cogs\nproc other() = discard\n").hasWord("active")

  test "training_labels is imported only by native_env and needs -d:pwTraining":
    var importers: seq[string]
    for path in walkDirRec(Root / "examples"):
      if not path.endsWith(".nim"): continue
      if "training_labels" in imports(readFile(path)): importers.add path.extractFilename
    check importers == @["native_env.nim"]
    for name in @["seat_view.nim", "bots.nim"] & @NeuralModules:
      check "training_labels" notin imports(readFile(Paintbot / name))
    check readFile(Paintbot / "training_labels.nim").contains("when not defined(pwTraining): {.error:")
    # The probe sits under the repository so config.nims gives it the engine's paths.
    let probe = Root / "tests" / ("tmp_boundary_labels_probe_" & $getCurrentProcessId() & ".nim")
    # A relative import with forward slashes: an absolute Windows path would be read as escapes.
    writeFile(probe, "import ../examples/paintbot/training_labels\n")
    defer: removeFile(probe)
    let (output, code) = execCmdEx("nim check --hints:off " & quoteShell(probe))
    check code != 0
    check "training_labels is training-only" in output

  test "the sample neural policy ends with the reference decode, verbatim":
    let policy = readFile(Paintbot / "players/neural_policy.bas")
    let decode = readFile(Paintbot / "players/neural_decode.bas")
    check policy.endsWith(decode)
    check "neuralSample()" in policy
    for retired in ["paintbot_act", "neuralDecode", "neuralIssue", "cmdSet", "neuralAimX", "neuralGoalX"]:
      check retired notin policy
      check retired notin decode
