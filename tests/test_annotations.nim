## The same policy surface with absent, bounded, and failing output destinations.
import std/[json, os, strutils, tempfiles], bassy
import polyworld/annotations

const Source = """
code = ANNOTATE(123, strNew("intent"), strNew("selectTarget"), strNew("{""target"":7}"))
after = 42
"""

block:
  let strings = initStringPool()
  var schema = initHost()
  schema.addStringFunctions(strings)
  schema.addAnnotationFunctions(strings)
  let program = compile(Source, schema)
  strings.bindProgram(program)
  var runtime = initRuntime(program, schema)
  discard runtime.run()
  doAssert runtime.getGlobal("code") == ord(AnnotationDisabled)
  doAssert runtime.getGlobal("after") == 42
  echo "Annotation API works without an output destination"

block:
  let directory = createTempDir("annotation-bindings-", "")
  defer: removeDir(directory)
  let first = newAnnotationSink(directory / "first.jsonl")
  let second = newAnnotationSink(directory / "second.jsonl")
  let unused = newAnnotationSink(directory / "unused.jsonl")
  let strings = initStringPool()
  var schema = initHost()
  schema.addStringFunctions(strings)
  schema.addAnnotationFunctions(strings)
  let program = compile(Source, schema)
  strings.bindProgram(program)
  for sink in [first, second]:
    var host = initHost()
    host.addStringFunctions(strings)
    host.addAnnotationFunctions(strings, sink)
    var runtime = initRuntime(program, host)
    for i in 0 .. 1:
      runtime.restart()
      discard runtime.run()
      doAssert runtime.getGlobal("code") == ord(AnnotationAccepted)
      doAssert runtime.getGlobal("after") == 42
  doAssert first.close() == AnnotationAccepted
  doAssert second.close() == AnnotationAccepted
  doAssert unused.close() == AnnotationAccepted
  doAssert readFile(directory / "first.jsonl") == readFile(directory / "second.jsonl")
  doAssert readFile(directory / "first.jsonl").count('\n') == 2
  doAssert not fileExists(directory / "unused.jsonl")
  doAssert first.annotate(0, "intent", "f", "{}") == AnnotationDisabled
  echo "Shared program, private destinations, unused output and buffered cleanup passed"

block:
  let directory = createTempDir("annotation-errors-", "")
  defer: removeDir(directory)
  let sink = newAnnotationSink(directory / "events.jsonl")
  let strings = initStringPool()
  var host = initHost()
  host.addStringFunctions(strings)
  host.addAnnotationFunctions(strings, sink)
  for args in ["[1,2]", "5", "{}}", "{", "{\"x\":}", "{\"x\":1e9999}"]:
    let source = "code = ANNOTATE(123, strNew(\"intent\"), strNew(\"f\"), strNew(\"" &
      args.replace("\"", "\"\"") & "\"))\nafter = 42\n"
    let program = compile(source, host)
    strings.bindProgram(program)
    var runtime = initRuntime(program, host)
    discard runtime.run()
    doAssert runtime.getGlobal("code") == ord(AnnotationInvalid)
    doAssert runtime.getGlobal("after") == 42
  let program = compile("code = ANNOTATE(1, -1, -1, -1)\nafter = 42", host)
  strings.bindProgram(program)
  var runtime = initRuntime(program, host)
  discard runtime.run()
  doAssert runtime.getGlobal("code") == ord(AnnotationInvalid)
  doAssert runtime.getGlobal("after") == 42
  doAssert sink.annotate(0, "", "f", "{}") == AnnotationInvalid
  doAssert sink.annotate(0, "intent", repeat('x', 257), "{}") == AnnotationInvalid
  doAssert sink.annotate(0, "intent", "f",
    "{\"nested\":" & repeat('[', 65) & "0" & repeat(']', 65) & "}") == AnnotationInvalid
  doAssert sink.annotate(0, "intent", "f", repeat('x', AnnotationEventLimit + 1)) == AnnotationTooLarge
  doAssert sink.annotate(0, "intent", "f", "{}") == AnnotationAccepted
  doAssert sink.close() == AnnotationAccepted
  doAssert readFile(directory / "events.jsonl").count('\n') == 1
  echo "Invalid input and event limit do not disable the VM or poison later events"

for payloadSize in [0, 1900]:
  let directory = createTempDir("annotation-budget-", "")
  defer: removeDir(directory)
  let sink = newAnnotationSink(directory / "events.jsonl")
  let args = "{\"payload\":\"" & repeat('x', payloadSize) & "\"}"
  for tick in 0 ..< AnnotationCountLimit:
    doAssert sink.annotate(int32(tick), "intent", "f", args) == AnnotationAccepted
  let strings = initStringPool()
  var host = initHost()
  host.addStringFunctions(strings)
  host.addAnnotationFunctions(strings, sink)
  let program = compile(Source, host)
  strings.bindProgram(program)
  var runtime = initRuntime(program, host)
  discard runtime.run()
  doAssert runtime.getGlobal("code") == ord(AnnotationBudgetExceeded)
  doAssert runtime.getGlobal("after") == 42
  doAssert sink.close() == AnnotationAccepted
  doAssert getFileSize(directory / "events.jsonl") <= AnnotationFileLimit
  doAssert readFile(directory / "events.jsonl").count('\n') == AnnotationCountLimit
  echo "1000-event budget preserves accepted events without stopping the policy"

block:
  let directory = createTempDir("annotation-io-", "")
  defer: removeDir(directory)
  # Opening a directory as an output file returns an immediate error.
  let sink = newAnnotationSink(directory)
  doAssert sink.annotate(0, "intent", "f", "{}") == AnnotationWriteFailed
  let strings = initStringPool()
  var host = initHost()
  host.addStringFunctions(strings)
  host.addAnnotationFunctions(strings, sink)
  let program = compile(Source, host)
  strings.bindProgram(program)
  var runtime = initRuntime(program, host)
  discard runtime.run()
  doAssert runtime.getGlobal("code") == ord(AnnotationWriteFailed)
  doAssert runtime.getGlobal("after") == 42
  doAssert sink.close() == AnnotationWriteFailed
  echo "I/O failure is returned immediately and does not stop the policy"

block:
  let directory = createTempDir("annotation-burst-", "")
  defer: removeDir(directory)
  var sinks: seq[AnnotationSink]
  for slot in 0 ..< 10:
    sinks.add newAnnotationSink(directory / ($slot & ".jsonl"))
  for tick in 0 ..< 300:
    for sink in sinks:
      doAssert sink.annotate(int32(tick), "intent", "f", "{}") == AnnotationAccepted
  for slot, sink in sinks:
    doAssert sink.close() == AnnotationAccepted
    let lines = readFile(directory / ($slot & ".jsonl")).strip().splitLines()
    doAssert lines.len == 300
    for tick, line in lines:
      doAssert parseJson(line)["time"].getInt() == tick
  echo "Ten-seat burst preserves every accepted event in per-seat order"

when defined(linux) and not defined(emscripten):
  block:
    let sink = newAnnotationSink("/dev/full")
    let status = sink.annotate(0, "intent", "f", "{}")
    doAssert status in {AnnotationAccepted, AnnotationWriteFailed}
    doAssert sink.close() == AnnotationWriteFailed
    echo "Buffered flush failure is reported without raising"
