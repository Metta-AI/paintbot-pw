## Map-size benchmark: plays one headless match through the normal setup path and reports
## wall time plus the `-d:pwBench` probes. Not a CI test.
##
##   nim c -d:release -d:pwBench -d:pwBenchMaps -o:tmp/bench tests/bench_paintbot_maps.nim
##   BENCH_TICKS=2400 tmp/bench --map:big-deep-forest --bot:examples/paintbot/players/jev.bas:16
## Add `--threads:on --mm:arc -d:pwTraining` for the indexed build (cover grid, ray memo,
## terrain cache); the final hash must match the plain build's.
import std/[os, strutils, monotimes, times, strformat]
import ../examples/paintbot/[sim, game]

let ticks = parseInt(getEnv("BENCH_TICKS", "2400"))
let setupStart = getMonoTime()
setup()
let setupMs = (getMonoTime()-setupStart).inMilliseconds
let start = getMonoTime()
while world.tick < ticks and world.winner == -1: advance()
let ms = (getMonoTime()-start).inMilliseconds
echo &"map={mapName()} cover={world.cover.len} bounds=[{minX()},{minZ()},{maxX()},{maxZ()}] " &
  &"ticks={world.tick} setup_ms={setupMs} run_ms={ms} ms_per_tick={ms.float/max(world.tick, 1).float:.3f} " &
  &"hash={world.stateHash()}"
when defined(pwBench): echo benchReport(max(world.tick, 1))
