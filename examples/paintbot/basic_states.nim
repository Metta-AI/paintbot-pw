## Adapts the pinned Bassy runtime to Paintbot training snapshots.
## Mutable fields are encoded explicitly while programs, callbacks, record
## bindings, and compiled machine code remain attached to the rebuilt runtime.

import
  bassy,
  snapshot

const
  RuntimeFields = [
    "strings", "buffers", "stringLiterals", "stringRoots", "stringGlobals",
    "stringCells", "stringHostData", "limits", "globals", "memory",
    "arrayReady", "loadedArrays", "registers", "arguments", "frames",
    "hostData", "integerArguments", "pc", "base", "routine", "depth",
    "remainingInstructions", "remainingWork", "printedBytes", "printedEvents",
    "allocatedBytes", "finished", "handedBack"
  ]
  RuntimeBindings = [
    "program", "arrayLoaders", "hostCallbacks", "machine", "machineShape",
    "printer", "nativeError"
  ]
  FixedLengths = [
    "stringLiterals", "stringRoots", "stringGlobals", "stringCells",
    "stringHostData", "globals", "memory", "arrayReady", "loadedArrays",
    "registers", "arguments", "frames", "hostData", "integerArguments"
  ]
  PoolFields = ["limits", "arena", "spans", "literalHandles"]

proc programState(program: Program): seq[byte] =
  ## Identifies bytecode and storage layout without lookup-table internals.
  var writer: SnapWriter
  writer.put(not program.isNil)
  if not program.isNil:
    for name, field in fieldPairs(program[]):
      when name notin [
        "globalIds", "arrayIds", "routineIds", "hostDataIds", "hostFunctionIds"
      ]:
        writer.put(field)
  writer.data

proc fingerprint[T: Runtime | StringPool](state: T): seq[byte] =
  ## Identifies the immutable program behind a runtime or handle string pool.
  for name, field in fieldPairs(state[]):
    when name == "program":
      return programState(field)

proc saveState*(runtime: Runtime): seq[byte] =
  ## Saves mutable Bassy storage while retaining host bindings and JIT code.
  var writer: SnapWriter
  writer.putBytes(runtime.fingerprint())
  for name, field in fieldPairs(runtime[]):
    when name in RuntimeFields:
      writer.put(field)
    elif name notin RuntimeBindings:
      {.error: "Review new Bassy runtime field for snapshots: " & name.}
  writer.data

proc restoreState*(runtime: var Runtime, data: openArray[byte]) =
  ## Restores into the same program without replacing bound record views.
  var reader = SnapReader(data: @data)
  if reader.getBytes() != runtime.fingerprint():
    reader.fail("BASIC snapshot is from a different program")
  var restored = runtime[]
  for name, field in fieldPairs(restored):
    when name in RuntimeFields:
      system.reset(field)
      reader.get(field)
  if reader.at != reader.data.len:
    reader.fail("trailing BASIC state bytes")
  for name, field in fieldPairs(runtime[]):
    when name in RuntimeFields:
      for restoredName, value in fieldPairs(restored):
        when name == restoredName:
          when name in FixedLengths:
            if field.len != value.len:
              reader.fail("BASIC storage layout differs: " & name)
          elif name == "limits":
            if field != value:
              reader.fail("BASIC limits differ")
  for name, field in fieldPairs(runtime[]):
    when name in RuntimeFields:
      for restoredName, value in fieldPairs(restored):
        when name == restoredName:
          field = move(value)

proc saveState*(pool: StringPool): seq[byte] =
  ## Saves the bounded handle string pool and its literal handles.
  var writer: SnapWriter
  writer.putBytes(pool.fingerprint())
  for name, field in fieldPairs(pool[]):
    when name in PoolFields:
      writer.put(field)
    elif name != "program":
      {.error: "Review new Bassy string pool field for snapshots: " & name.}
  writer.data

proc restoreState*(pool: StringPool, data: openArray[byte]) =
  ## Restores handle strings after validating the program and pool limits.
  var reader = SnapReader(data: @data)
  if reader.getBytes() != pool.fingerprint():
    reader.fail("BASIC string snapshot is from a different program")
  var restored = pool[]
  for name, field in fieldPairs(restored):
    when name in PoolFields:
      system.reset(field)
      reader.get(field)
  if reader.at != reader.data.len:
    reader.fail("trailing BASIC string state bytes")
  for name, field in fieldPairs(pool[]):
    when name == "limits":
      for restoredName, value in fieldPairs(restored):
        when name == restoredName:
          if field != value:
            reader.fail("BASIC string pool limits differ")
  for name, field in fieldPairs(pool[]):
    when name in PoolFields:
      for restoredName, value in fieldPairs(restored):
        when name == restoredName:
          field = move(value)
