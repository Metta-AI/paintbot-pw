## Prints Fluffy Chrome-trace totals sorted by time.
##
##   nim r tools/summarize_trace.nim tmp/lvd_trace.json

import
  std/[algorithm, os, strutils],
  jsony

type
  TraceEvent = object
    name: string
    ph: string
    dur: float
    alloc: int
    deloc: int
  ChromeTrace = object
    traceEvents: seq[TraceEvent]
  Row = object
    name: string
    count: int
    totalUs: float
    maxUs: float
    alloc: int

proc summarize(path: string) =
  ## Loads one Fluffy trace and prints the hottest names.
  let
    raw = readFile(path)
    trace = raw.fromJson(ChromeTrace)
  var rows: seq[Row]
  for event in trace.traceEvents:
    if event.ph != "X":
      continue
    var found = false
    for row in rows.mitems:
      if row.name == event.name:
        inc row.count
        row.totalUs += event.dur
        row.maxUs = max(row.maxUs, event.dur)
        row.alloc += event.alloc
        found = true
        break
    if not found:
      rows.add Row(
        name: event.name,
        count: 1,
        totalUs: event.dur,
        maxUs: event.dur,
        alloc: event.alloc
      )
  rows.sort do (a, b: Row) -> int:
    cmp(b.totalUs, a.totalUs)
  echo path.extractFilename
  echo alignLeft("Name", 28),
    align("Count", 10),
    align("Total s", 12),
    align("Avg ms", 10),
    align("Max ms", 10),
    align("Allocs", 10)
  echo repeat("-", 80)
  for row in rows:
    let
      totalS = row.totalUs / 1_000_000.0
      avgMs = row.totalUs / float(max(row.count, 1)) / 1000.0
      maxMs = row.maxUs / 1000.0
    echo alignLeft(row.name, 28),
      align($row.count, 10),
      align(formatFloat(totalS, ffDecimal, 3), 12),
      align(formatFloat(avgMs, ffDecimal, 3), 10),
      align(formatFloat(maxMs, ffDecimal, 3), 10),
      align($row.alloc, 10)

if paramCount() < 1:
  quit("usage: summarize_trace <trace.json> [trace.json ...]", 1)
for i in 1 .. paramCount():
  let path = paramStr(i)
  if not fileExists(path):
    quit("missing trace: " & path, 1)
  summarize(path)
  echo ""
