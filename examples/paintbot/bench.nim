## Opt-in inclusive timers for the simulation's hot spots (`-d:pwBench`). Without the
## define every probe compiles to nothing, so shipped builds and replays are unaffected.
type BenchKind* = enum
  bkStep, bkDecide, bkVisible, bkLineClear, bkBlocked, bkWalkClear, bkTraversable, bkWaypoint

when defined(pwBench):
  import std/[monotimes, strutils, strformat]
  var benchNs*: array[BenchKind, int64]
  var benchCalls*: array[BenchKind, int64]
  proc benchNow*(): int64 = getMonoTime().ticks
  proc benchRecord*(kind: BenchKind, start: int64) =
    {.cast(gcsafe).}:
      benchNs[kind] += benchNow()-start
      inc benchCalls[kind]
  template benchEnter*(kind: BenchKind) =
    let benchStart = benchNow()
    defer: benchRecord(kind, benchStart)
  proc benchReport*(ticks: int): string =
    for k in BenchKind:
      let ms = benchNs[k].float/1e6
      result.add &"{($k)[2..^1]:<12} {ms:>10.1f} ms total {ms/ticks.float:>8.3f} ms/tick {benchCalls[k]:>11} calls {(if benchCalls[k] > 0: benchNs[k].float/benchCalls[k].float/1000 else: 0.0):>8.2f} us/call\n"
else:
  template benchEnter*(kind: BenchKind) = discard
