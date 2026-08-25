import
  std/strutils,
  polyworld/basic

proc errorContains(
    action: proc() {.closure.},
    expected: string
): bool =
  ## Returns whether an action raises the expected BASIC error text.
  try:
    action()
  except BasicError as error:
    result = expected in error.msg

echo "Testing BASIC arithmetic and case-insensitive globals"
block:
  let program = compile("""
Value = 2 + 3 * 4
wrapped = 2147483647 + 1
logic = value = 14 and not false
let oldStyle = value + 1
""")
  var runtime = initRuntime(program)
  discard runtime.run
  doAssert runtime.getGlobal("value") == 14
  doAssert runtime.getGlobal("VALUE") == 14
  doAssert runtime.getGlobal("wrapped") == low(int32)
  doAssert runtime.getGlobal("logic") == 1
  doAssert runtime.getGlobal("oldStyle") == 15

echo "Testing BASIC arrays and while loops"
block:
  let program = compile("""
dim scores(3)
i = 0
while i <= 3
  scores(i) = i * i
  i = i + 1
wend
""")
  var runtime = initRuntime(program)
  let stats = runtime.run
  doAssert runtime.arrayLength("scores") == 4
  doAssert runtime.getArray("scores", 0) == 0
  doAssert runtime.getArray("scores", 1) == 1
  doAssert runtime.getArray("scores", 2) == 4
  doAssert runtime.getArray("scores", 3) == 9
  doAssert stats.instructions > 0
  doAssert stats.workUnits > 0

echo "Testing BASIC if blocks, subs, and local parameters"
block:
  let program = compile("""
dim scores(4)

sub addScore(player, amount)
  if player >= 0 and player <= 4 then
    scores(player) = scores(player) + amount
    accepted = accepted + 1
  else
    rejected = rejected + 1
  end if
end sub

addScore(2, 7)
ADDSCORE(5, 9)
""")
  var runtime = initRuntime(program)
  discard runtime.run
  doAssert runtime.getArray("scores", 2) == 7
  doAssert runtime.getGlobal("accepted") == 1
  doAssert runtime.getGlobal("rejected") == 1

echo "Testing BASIC recursion and exit sub"
block:
  let program = compile("""
sub accumulate(n)
  if n <= 0 then
    exit sub
  end if
  total = total + n
  accumulate(n - 1)
end sub

accumulate(5)
""")
  var runtime = initRuntime(program)
  discard runtime.run
  doAssert runtime.getGlobal("total") == 15

echo "Testing fused scalar, array, branch, and call operations"
block:
  let program = compile("""
dim values(7)

sub addParam(value)
  parameterTotal = parameterTotal + value
end sub

i = 0
total = 0
even = 0
odd = 0
while i < 8
  index = i mod 8
  values(index) = values(index) + i
  total = total + values(index)
  if i mod 2 = 0 then
    even = even + 1
  else
    odd = odd + 1
  end if
  i = i + 1
wend
copy = total
addParam(copy)
""")
  var runtime = initRuntime(program)
  discard runtime.run
  doAssert runtime.getGlobal("index") == 7
  doAssert runtime.getArray("values", 7) == 7
  doAssert runtime.getGlobal("total") == 28
  doAssert runtime.getGlobal("even") == 4
  doAssert runtime.getGlobal("odd") == 4
  doAssert runtime.getGlobal("copy") == 28
  doAssert runtime.getGlobal("parameterTotal") == 28

echo "Testing print events without BASIC string values"
block:
  let program = compile("""
score = 7
print "score", score
print "done";
""")
  var
    runtime = initRuntime(program)
    output = ""
  let logger: PrintProc = proc(event: PrintEvent) =
    case event.kind
    of TextPrint:
      output.add event.text
    of ValuePrint:
      output.add $event.value
    of NewlinePrint:
      output.add '\n'
  let stats = runtime.run(logger)
  doAssert output == "score 7\ndone"
  doAssert stats.printBytes == int64(output.len)
  doAssert stats.printEvents == 5

echo "Testing host access and reset"
block:
  let program = compile("""
dim values(1)
counter = counter + 1
values(0) = counter
""")
  var runtime = initRuntime(program)
  runtime.setGlobal("COUNTER", 9)
  runtime.setArray("VALUES", 1, 23)
  discard runtime.run
  doAssert runtime.getGlobal("counter") == 10
  doAssert runtime.getArray("values", 0) == 10
  doAssert runtime.getArray("values", 1) == 23
  runtime.reset
  doAssert runtime.getGlobal("counter") == 0
  doAssert runtime.getArray("values", 1) == 0
  discard runtime.run
  doAssert runtime.getGlobal("counter") == 1

echo "Testing named host data and function calls"
block:
  var
    host = initHost()
    actionCount = 0'i32
    lastEntity = 0'i32
    lastX = 0'i32
    lastY = 0'i32
  discard host.addData("tick", 10)
  let add: HostProc = proc(arguments: openArray[int32]): int32 =
    doAssert arguments.len == 2
    arguments[0] +% arguments[1]
  let readSecret: HostProc = proc(arguments: openArray[int32]): int32 =
    doAssert arguments.len == 0
    5
  let moveEntity: HostProc = proc(arguments: openArray[int32]): int32 =
    doAssert arguments.len == 3
    inc actionCount
    lastEntity = arguments[0]
    lastX = arguments[1]
    lastY = arguments[2]
    arguments[0] +% arguments[1] +% arguments[2]
  discard host.addFunction("add", 2, add, 4)
  discard host.addFunction("readSecret", 0, readSecret, 3)
  discard host.addFunction("moveEntity", 3, moveEntity, 12)
  let program = compile("""
nested = add(add(tick, readSecret()), add(3, 4))
result = moveEntity(7, nested, tick)
moveEntity(8, 1, 2)
""", host)
  var runtime = initRuntime(program, host)
  let tickId = program.hostDataIndex("tick")
  doAssert tickId >= 0
  runtime.setData(tickId, 11)
  doAssert runtime.getData("tick") == 11
  runtime.setData("TICK", 12)
  doAssert runtime.getData("tick") == 12
  runtime.setData(tickId, 11)
  let stats = runtime.run
  doAssert runtime.getData("tick") == 11
  doAssert runtime.getGlobal("nested") == 23
  doAssert runtime.getGlobal("result") == 41
  doAssert actionCount == 2
  doAssert lastEntity == 8
  doAssert lastX == 1
  doAssert lastY == 2
  doAssert stats.instructions > 0
  doAssert stats.workUnits >= 35
  doAssert errorContains(
    proc() = discard compile("tick = 1\n", host),
    "read-only"
  )
  doAssert errorContains(
    proc() = discard initRuntime(program),
    "missing BASIC host data binding"
  )

echo "Testing persistent restart, isolated runtimes, and a host action"
block:
  var
    host = initHost()
    lastX = 0'i32
    lastY = 0'i32
  let goTo: HostProc = proc(arguments: openArray[int32]): int32 =
    doAssert arguments.len == 2
    lastX = arguments[0]
    lastY = arguments[1]
    1
  discard host.addFunction("walkTo", 2, goTo, 20)
  let program = compile("""
runs = runs + 1
walkTo(runs, 34)
""", host)
  var runtime = initRuntime(program, host)
  discard runtime.run
  doAssert runtime.getGlobal("runs") == 1
  doAssert lastX == 1
  doAssert lastY == 34
  runtime.restart
  discard runtime.run
  doAssert runtime.getGlobal("runs") == 2
  doAssert lastX == 2
  var otherRuntime = initRuntime(program, host)
  discard otherRuntime.run
  doAssert otherRuntime.getGlobal("runs") == 1
  doAssert runtime.getGlobal("runs") == 2

block:
  var
    host = initHost()
    calls = 0
    limits = defaultLimits()
  let blocked: HostProc = proc(arguments: openArray[int32]): int32 =
    doAssert arguments.len == 0
    inc calls
    1
  discard host.addFunction("blocked", 0, blocked, 20)
  limits.maxWorkUnits = 10
  let program = compile("blocked()\n", host, limits)
  var runtime = initRuntime(program, host, limits)
  doAssert errorContains(
    proc() = discard runtime.run,
    "work limit"
  )
  doAssert calls == 0
  var instructionLimits = defaultLimits()
  instructionLimits.maxInstructions = 0
  var instructionRuntime = initRuntime(
    program,
    host,
    instructionLimits
  )
  doAssert errorContains(
    proc() = discard instructionRuntime.run,
    "instruction limit"
  )
  doAssert calls == 0
  let memoryBytes = initRuntime(program, host).memoryBytes
  var memoryLimits = defaultLimits()
  memoryLimits.maxMemoryBytes = memoryBytes - 1
  doAssert errorContains(
    proc() = discard initRuntime(program, host, memoryLimits),
    "memory limit"
  )

echo "Testing work, memory, output, bounds, and call limits"
block:
  var limits = defaultLimits()
  limits.maxInstructions = 2
  let program = compile("first = 1\nsecond = 2\n", limits)
  var runtime = initRuntime(program, limits)
  doAssert errorContains(
    proc() = discard runtime.run,
    "instruction limit"
  )
  doAssert runtime.instructionsUsed == 0

block:
  var limits = defaultLimits()
  limits.maxInstructions = 3
  let program = compile("first = 1\nsecond = 2\n", limits)
  var runtime = initRuntime(program, limits)
  let stats = runtime.run
  doAssert stats.instructions == 3
  doAssert runtime.instructionsUsed == 3

block:
  var limits = defaultLimits()
  limits.maxWorkUnits = 30
  let program = compile("""
i = 0
while true
  i = i + 1
wend
""")
  var runtime = initRuntime(program, limits)
  doAssert errorContains(
    proc() = discard runtime.run,
    "work limit"
  )

block:
  var limits = defaultLimits()
  limits.maxMemoryBytes = 16
  let program = compile("dim values(100)\n")
  doAssert errorContains(
    proc() = discard initRuntime(program, limits),
    "memory limit"
  )

block:
  let program = compile("dim values(1)\nvalues(-1) = 3\n")
  var runtime = initRuntime(program)
  doAssert errorContains(
    proc() = discard runtime.run,
    "outside 0"
  )

block:
  var limits = defaultLimits()
  limits.maxCallDepth = 4
  let program = compile("""
sub recurse(n)
  recurse(n + 1)
end sub
recurse(0)
""")
  var runtime = initRuntime(program, limits)
  doAssert errorContains(
    proc() = discard runtime.run,
    "call depth"
  )

block:
  var limits = defaultLimits()
  limits.maxPrintBytes = 2
  let program = compile("print \"long\"\n")
  var runtime = initRuntime(program, limits)
  doAssert errorContains(
    proc() = discard runtime.run,
    "print byte limit"
  )

echo "Testing BASIC syntax and type restrictions"
block:
  doAssert errorContains(
    proc() = discard compile("value = \"not a value\"\n"),
    "integer expression"
  )
  doAssert errorContains(
    proc() = discard compile("if true then\nvalue = 1\n"),
    "missing 'end if'"
  )
  doAssert errorContains(
    proc() = discard compile("dim values(2)\ndim values(3)\n"),
    "duplicate BASIC name"
  )
  doAssert errorContains(
    proc() = discard compile("goto = 10\n"),
    "not a scalar variable"
  )

echo "Testing malformed source remains a controlled BASIC error"
block:
  let malformed = [
    "sub",
    "sub example(",
    "sub example()\n",
    "sub outer()\nsub inner()\nend sub\nend sub\n",
    "if true then\nsub nested()\nend sub\nend if\n",
    "if true then\ndim nested(1)\nend if\n",
    "end if\n",
    "if then\nend if\n",
    "value =\n",
    "dim\n",
    "dim values(\n",
    "missing(\n",
    "print 1 +\n",
    "values[0] = 1\n",
    "while\nwend\n"
  ]
  for source in malformed:
    doAssert errorContains(
      proc() = discard compile(source),
      ""
    )

block:
  let program = compile("rem Anything here is ignored: !@#$%^&*\nvalue = 3\n")
  var runtime = initRuntime(program)
  discard runtime.run
  doAssert runtime.getGlobal("value") == 3

block:
  let source =
    "value = " & "(".repeat(DefaultMaxSyntaxDepth + 1) & "1" &
    ")".repeat(DefaultMaxSyntaxDepth + 1) & "\n"
  doAssert errorContains(
    proc() = discard compile(source),
    "syntax nesting"
  )

block:
  const Alphabet =
    "abcdefghijklmnopqrstuvwxyz0123456789()=+-*/<>,;:\n\"' "
  var fuzzState = 0x51a7e123'u32
  for caseIndex in 0 ..< 2000:
    fuzzState = fuzzState xor (fuzzState shl 13)
    fuzzState = fuzzState xor (fuzzState shr 17)
    fuzzState = fuzzState xor (fuzzState shl 5)
    let length = int(fuzzState mod 80) + 1
    var source = newStringOfCap(length)
    for characterIndex in 0 ..< length:
      fuzzState = fuzzState xor (fuzzState shl 13)
      fuzzState = fuzzState xor (fuzzState shr 17)
      fuzzState = fuzzState xor (fuzzState shl 5)
      let index = int(
        (fuzzState xor uint32(caseIndex + characterIndex)) mod
        uint32(Alphabet.len)
      )
      source.add Alphabet[index]
    try:
      discard compile(source)
    except BasicError:
      discard

echo "BASIC tests passed"
