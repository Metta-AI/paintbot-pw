import
  bassy,
  ../examples/paintbot/basic_states

echo "Testing BASIC state snapshots (saveState / restoreState)"
block:
  # A counter, an array and a string survive between runs; a snapshot taken between runs and restored into a fresh
  # runtime of the same program continues exactly as the original does.
  let source = """
dim hist(8)
count = count + 1
hist(count mod 8) = hist(count mod 8) + count
total = 0
i = 0
while i < 8
  total = total + hist(i)
  i = i + 1
wend
"""
  let program = compile(source)
  var original = initRuntime(program)
  for i in 0 ..< 5:
    original.restart; discard original.run
  let snap = original.saveState
  var resumed = initRuntime(program)
  resumed.restoreState(snap)
  doAssert resumed.saveState == snap
  for i in 0 ..< 7:
    original.restart; discard original.run
    resumed.restart; discard resumed.run
    doAssert resumed.getGlobal("count") == original.getGlobal("count")
    doAssert resumed.getGlobal("total") == original.getGlobal("total")
  doAssert original.getGlobal("count") == 12
  # A different program refuses the snapshot and leaves the runtime as it was.
  var other = initRuntime(compile("x = 1\n"))
  let before = other.saveState
  doAssert (try: (other.restoreState(snap); false) except ValueError: true)
  doAssert other.saveState == before
  doAssert (try: (resumed.restoreState(snap[0 ..< snap.len div 2]); false) except ValueError: true)
  # A string pool round-trips its arena and handles.
  let pool = initStringPool()
  pool.bindProgram(program)
  let ps = pool.saveState
  let pool2 = initStringPool()
  pool2.bindProgram(program)
  pool2.restoreState(ps)
  doAssert pool2.saveState == ps

echo "Testing record views, fixed numbers, and strings after restore"
block:
  let program = compile("""
TYPE Memory
  ticks AS INTEGER
  fraction AS FIXED
  text AS STRING
END TYPE
DIM memory AS Memory
DIM records(2) AS Memory
memory.ticks = memory.ticks + 1
memory.fraction = memory.fraction + 3 / 2
memory.text = memory.text + "x"
records(0).ticks = memory.ticks
records(0).fraction = memory.fraction
records(0).text = memory.text
""")
  var
    original = initRuntime(program)
    resumed = initRuntime(program)
  let
    ticks = resumed.globalView("memory.ticks")
    records = resumed.arrayView("records.ticks")
  if jitSupported():
    doAssert original.compileNative() > 0
    doAssert resumed.compileNative() > 0
  for i in 0 ..< 5:
    original.restart()
    discard original.run()
  let saved = original.saveState()
  resumed.restoreState(saved)
  doAssert resumed.saveState() == saved
  doAssert ticks.value == toValue(5)
  doAssert records[0] == toValue(5)
  for i in 0 ..< 7:
    original.restart()
    discard original.run()
    resumed.restart()
    discard resumed.run()
    doAssert ticks.value == original.getGlobalValue("memory.ticks")
    doAssert records[0] == original.getArrayValue("records.ticks", 0)
    doAssert resumed.getGlobalValue("memory.fraction") ==
      original.getGlobalValue("memory.fraction")
    doAssert resumed.getStringGlobal("memory.text") ==
      original.getStringGlobal("memory.text")
    doAssert resumed.getStringArray("records.text", 0) ==
      original.getStringArray("records.text", 0)
  doAssert ticks.value == toValue(12)
  doAssert resumed.getStringGlobal("memory.text") == "xxxxxxxxxxxx"

echo "Bassy snapshot tests passed"
