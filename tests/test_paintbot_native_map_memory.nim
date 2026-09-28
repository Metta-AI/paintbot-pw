## Memory of per-handle maps in the training library. A process that plays many maps must not
## grow by a terrain table per map it has played: a generated map's terrain is read from its own
## grid, never tabled in the rules-terrain cache (which pinned about 0.6 GB per map). A thread's
## per-map navigation and cover caches (sim.parkForMap) stay, at a few MiB per map. The worlds
## themselves are covered by test_paintbot_native_map (hash-identical per map, interleaved, and
## against configureMap).
## Build with --mm:arc --threads:on -d:pwTraining. PW_MAP_MEMORY_LOG=1 prints the resident
## peak after every cycle (measured on Linux: 634 MiB with this, 6,809 MiB with every map tabled).
import std/[unittest, os, strutils]
import ../examples/paintbot/[sim, neural_contract, native_env]
when not defined(windows): import std/posix

when not defined(pwTraining): {.error: "native maps exist only under -d:pwTraining".}

const Root = currentSourcePath().parentDir.parentDir
const Base = Root / "coworld/paintbot/players/base.bas"
type
  Buffer = ptr UncheckedArray[cfloat]
  Actions = array[Seats*ActionSizes.len, int32]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])
template ibuf(a: untyped): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr a[0])
template cbuf(s: string): ptr UncheckedArray[char] =
  (if s.len > 0: cast[ptr UncheckedArray[char]](unsafeAddr s[0]) else: nil)

proc peakResidentMiB(): float =
  ## The process's peak resident set, or -1 where it is not measured (Windows).
  when defined(windows): -1.0
  else:
    var usage: RUsage
    discard getrusage(RUSAGE_SELF, addr usage)
    when defined(macosx): usage.ru_maxrss.float / (1024*1024) # bytes
    else: usage.ru_maxrss.float / 1024                         # KiB

proc play(handle: pointer, seed: int32, ticks: int) =
  ## base.bas on the odd seats (they route with the navigation cache), a fixed action pattern
  ## on the even seats.
  var actions: Actions
  var rewards, terminals: array[Seats, float32]
  for tick in 0..<ticks:
    for slot in countup(0, Seats-1, 2):
      let offset = slot*ActionSizes.len
      actions[offset] = int32(1+(slot div 2+seed) mod 10)
      actions[offset+1] = int32(17+(tick div 24+slot) mod 8)
      actions[offset+2] = int32(tick mod 3 == 0)
    if pw_step(handle, ibuf(actions), fbuf(rewards), fbuf(terminals)) != 0: break

suite "Native per-handle map memory":
  test "cycling every map keeps terrain blocks at the island's and the resident peak bounded":
    let source = readFile(Base)
    let ticks = parseInt(getEnv("PW_MAP_MEMORY_TICKS", "120"))
    var handles: array[3, pointer]
    for i in 0..<handles.len:
      handles[i] = pw_create(int32(50+i), ticks.int32)
      require handles[i] != nil
      for slot in countup(1, Seats-1, 2):
        require pw_set_seat_script(handles[i], slot.cint, cbuf(source), source.len.int32) == 0
    # The island's terrain is tabled as before.
    for i, h in handles: play(h, int32(50+i), ticks)
    let islandBlocks = pw_terrain_cache_blocks()
    check islandBlocks > 0
    var peaks: seq[float]
    for cycle in 0..<3:
      for map in 0..<MapNames.len:
        let h = handles[map mod handles.len]
        let seed = int32(1000*cycle+map)
        require pw_set_map(h, map.cint) == 0
        require pw_reset(h, seed, ticks.int32) == 0
        play(h, seed, ticks)
      peaks.add peakResidentMiB()
      if getEnv("PW_MAP_MEMORY_LOG") == "1":
        echo "cycle ", cycle, ": peak ", peaks[^1].formatFloat(ffDecimal, 0), " MiB, terrain blocks ",
          pw_terrain_cache_blocks()
    # No generated map adds a terrain block.
    check pw_terrain_cache_blocks() == islandBlocks
    when not defined(windows):
      checkpoint "peaks MiB: " & $peaks
      check peaks[^1] < 1536
      # A plateau: the later cycles replay maps the process has seen and add (almost) nothing.
      check peaks[2] - peaks[0] < 128
    for h in handles: pw_destroy(h)
