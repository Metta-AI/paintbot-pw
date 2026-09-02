import
  benchy,
  polyworld/basic

const
  ArithmeticIterations = 1_000_000
  ArraySize = 1024
  ArrayIterations = 1_000_000
  BranchIterations = 1_000_000
  CallIterations = 500_000
  HostIterations = 1_000_000
  HostCallIterations = 500_000
  BenchRuns {.intdefine.} = 10
  CompileRuns {.intdefine.} = 100

  ArithmeticSource = """
i = 0
total = 0
while i < 1000000
  total = total + i
  i = i + 1
wend
"""

  ArraySource = """
dim values(1023)
i = 0
total = 0
while i < 1000000
  index = i mod 1024
  values(index) = values(index) + i
  total = total + values(index)
  i = i + 1
wend
"""

  BranchSource = """
i = 0
even = 0
odd = 0
while i < 1000000
  if i mod 2 = 0 then
    even = even + 1
  else
    odd = odd + 1
  end if
  i = i + 1
wend
"""

  CallSource = """
sub add(value)
  total = total + value
end sub

i = 0
total = 0
while i < 500000
  add(i)
  i = i + 1
wend
"""

  HostDataSource = """
i = 0
total = 0
while i < 1000000
  total = total + delta
  i = i + 1
wend
"""

  HostCallSource = """
i = 0
total = 0
while i < 500000
  total = addDelta(total)
  i = i + 1
wend
"""

  StringIterations = 50_000

  StringBuildSource = """
i = 0
length = 0
while i < 50000
  m = strCatInt(strNew("attack "), i)
  length = length + strLen(m)
  i = i + 1
wend
"""

  StringParseSource = """
message = mail()
i = 0
total = 0
while i < 50000
  total = total + strVal(strWord(message, 1))
  i = i + 1
wend
"""

  StringFindSource = """
message = mail()
needle = strNew("34")
i = 0
found = 0
while i < 50000
  found = found + strFind(message, needle, 0)
  i = i + 1
wend
"""

proc benchLimits(): Limits =
  ## Returns limits large enough for every benchmark workload.
  result = defaultLimits()
  result.maxInstructions = 100_000_000
  result.maxWorkUnits = 100_000_000

proc addDelta(arguments: openArray[int32]): int32 =
  ## Adds a small constant in the native callback benchmark.
  arguments[0] +% 3

proc benchStringPool(): StringPool =
  ## Returns a pool large enough for allocation-heavy string benchmarks.
  var poolLimits = defaultStringLimits()
  poolLimits.maxStrings = 200_000
  poolLimits.maxStringBytes = 8 * 1024 * 1024
  initStringPool(poolLimits)

proc buildStringBench(
    source: string,
    limits: Limits
): tuple[program: Program, runtime: Runtime, pool: StringPool] =
  ## Compiles one string benchmark with its own pool and mail source.
  var host = initHost()
  let pool = benchStringPool()
  host.addStringFunctions(pool)
  let mailProc: HostProc = proc(arguments: openArray[int32]): int32 =
    pool.putString("attack 12 34 hold")
  discard host.addFunction("mail", 0, mailProc, 8)
  let program = compile(source, host, limits)
  pool.bindProgram(program)
  (program, initRuntime(program, host, limits), pool)

proc describe(name: string, program: Program, runtime: Runtime) =
  ## Prints stable bytecode and runtime-memory measurements.
  echo "  ", name,
    ": instructions=", program.instructions,
    " memory=", runtime.memoryBytes, " bytes"

let
  limits = benchLimits()
  arithmeticProgram = compile(ArithmeticSource, limits)
  arrayProgram = compile(ArraySource, limits)
  branchProgram = compile(BranchSource, limits)
  callProgram = compile(CallSource, limits)

var host = initHost()
discard host.addData("delta", 3)
discard host.addFunction("addDelta", 1, addDelta, 4)

let
  hostDataProgram = compile(HostDataSource, host, limits)
  hostCallProgram = compile(HostCallSource, host, limits)

var
  arithmeticRuntime = initRuntime(arithmeticProgram, limits)
  arrayRuntime = initRuntime(arrayProgram, limits)
  branchRuntime = initRuntime(branchProgram, limits)
  callRuntime = initRuntime(callProgram, limits)
  hostDataRuntime = initRuntime(hostDataProgram, host, limits)
  hostCallRuntime = initRuntime(hostCallProgram, host, limits)

var
  (stringBuildProgram, stringBuildRuntime, stringBuildPool) =
    buildStringBench(StringBuildSource, limits)
  (stringParseProgram, stringParseRuntime, stringParsePool) =
    buildStringBench(StringParseSource, limits)
  (stringFindProgram, stringFindRuntime, stringFindPool) =
    buildStringBench(StringFindSource, limits)

echo "BASIC register VM benchmark"
echo "  arithmetic iterations=", ArithmeticIterations
echo "  array iterations=", ArrayIterations, " elements=", ArraySize
echo "  branch iterations=", BranchIterations
echo "  call iterations=", CallIterations
echo "  host data iterations=", HostIterations
echo "  host call iterations=", HostCallIterations
echo "  string iterations=", StringIterations
describe("arithmetic", arithmeticProgram, arithmeticRuntime)
describe("array", arrayProgram, arrayRuntime)
describe("branch", branchProgram, branchRuntime)
describe("call", callProgram, callRuntime)
describe("host data", hostDataProgram, hostDataRuntime)
describe("host call", hostCallProgram, hostCallRuntime)
describe("string build", stringBuildProgram, stringBuildRuntime)
describe("string parse", stringParseProgram, stringParseRuntime)
describe("string find", stringFindProgram, stringFindRuntime)

timeIt("compile arithmetic", CompileRuns):
  let program = compile(ArithmeticSource, limits)
  keep(program.instructions)

timeIt("execute arithmetic", BenchRuns):
  arithmeticRuntime.reset
  let stats = arithmeticRuntime.run
  keep(stats.workUnits)
  keep(arithmeticRuntime.getGlobal("total"))

timeIt("execute arrays", BenchRuns):
  arrayRuntime.reset
  let stats = arrayRuntime.run
  keep(stats.workUnits)
  keep(arrayRuntime.getGlobal("total"))

timeIt("execute branches", BenchRuns):
  branchRuntime.reset
  let stats = branchRuntime.run
  keep(stats.workUnits)
  keep(branchRuntime.getGlobal("even"))

timeIt("execute sub calls", BenchRuns):
  callRuntime.reset
  let stats = callRuntime.run
  keep(stats.workUnits)
  keep(callRuntime.getGlobal("total"))

timeIt("execute host data", BenchRuns):
  hostDataRuntime.reset
  let stats = hostDataRuntime.run
  keep(stats.workUnits)
  keep(hostDataRuntime.getGlobal("total"))

timeIt("execute host calls", BenchRuns):
  hostCallRuntime.reset
  let stats = hostCallRuntime.run
  keep(stats.workUnits)
  keep(hostCallRuntime.getGlobal("total"))

timeIt("execute string build", BenchRuns):
  stringBuildPool.reset
  stringBuildRuntime.reset
  let stats = stringBuildRuntime.run
  keep(stats.workUnits)
  keep(stringBuildRuntime.getGlobal("length"))

timeIt("execute string parse", BenchRuns):
  stringParsePool.reset
  stringParseRuntime.reset
  let stats = stringParseRuntime.run
  keep(stats.workUnits)
  keep(stringParseRuntime.getGlobal("total"))

timeIt("execute string find", BenchRuns):
  stringFindPool.reset
  stringFindRuntime.reset
  let stats = stringFindRuntime.run
  keep(stats.workUnits)
  keep(stringFindRuntime.getGlobal("found"))
