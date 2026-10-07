## pw_register_map (training library only): train-* arenas (mapgen --layout-scale, examples/paintbot/maps/train)
## registered at startup, before any handle, and played by index.
## - Registration: indices follow MapNames, pw_map_count / pw_map_name include them; bad arguments (nil, empty, taken,
##   over-long names, malformed blobs, a full registry) give -1, and any call after the first pw_create* gives -2.
## - Each arena plays rules-49 base.bas matches (16 seats, the teams game): the standard bounds (the observation's
##   span), 10 hearts, 28 pickups all inside the 32 observation rows, every live cog on the island every tick, cogs
##   moving and fighting, deterministic hash sequences, and a teams.view.1i observation that encodes.
## - Identity: Heartwick and twin-mesas play the same state-hash sequence in this process (arenas registered) as in a
##   child process that never registers (this binary with --digest-only), and a Heartwick handle interleaved on one
##   thread with an arena handle matches its solo run (the per-map terrain, cover and nav caches stay apart).
## Build with --mm:arc --threads:on -d:pwTraining -d:headless.
import std/[unittest, os, osproc, strutils, importutils, hashes]
import ../examples/paintbot/[sim, neural_contract, native_env]

when not defined(pwTraining): {.error: "pw_register_map exists only under -d:pwTraining".}

privateAccess(NativeEnv)
const Root = currentSourcePath().parentDir.parentDir
const Arenas = ["train-arena-4", "train-arena-9"]
type Buffer = ptr UncheckedArray[cfloat]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])
template ibuf(a: untyped): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr a[0])

proc blob(name: string): string = readFile(Root / "examples/paintbot/maps/train" / (name & ".pbmap"))
proc register(name, data: string): cint =
  pw_register_map(name.cstring, (if data.len > 0: unsafeAddr data[0] else: nil), data.len.int32)

proc compiledIndex(name: string): cint =
  if name == "": return -1
  for i, m in MapNames:
    if m == name: return i.cint
  doAssert false, "unknown map " & name

proc scripted(seed, ticks: int32, map: cint): pointer =
  result = pw_create(seed, ticks)
  doAssert result != nil
  doAssert pw_set_rules(result, 49) == 0
  doAssert pw_set_map(result, map) == 0
  doAssert pw_reset(result, seed, ticks) == 0
  let base = readFile(Root / "coworld/paintbot/players/base.bas")
  for slot in 0..<Seats:
    doAssert pw_set_seat_script(result, slot.cint, cast[ptr UncheckedArray[char]](unsafeAddr base[0]), base.len.int32) == 0

proc stepAll(h: pointer): bool =
  ## One tick of a scripted match; true at the terminal.
  var actions: array[LegacySeats*ActionSizes.len, int32]
  var rewards, terminals: array[LegacySeats, float32]
  doAssert pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
  terminals[0] == 1

proc hashRun(seed, ticks: int32, map: cint): string =
  ## The state-hash sequence of one scripted match, as a digest.
  let h = scripted(seed, ticks, map)
  var acc: Hash = 0
  var n = 0
  for t in 0..<ticks:
    let done = h.stepAll()
    acc = acc !& hash(pw_state_hash(h)); inc n
    if done: break
  pw_destroy(h)
  $(!$acc) & ":" & $n

const Reference = [(4801'i32, ""), (4802'i32, "twin-mesas")]
const RefTicks = 3000'i32
proc referenceDigests(): string =
  for (seed, map) in Reference: result.add hashRun(seed, RefTicks, compiledIndex(map)) & " "

if paramCount() >= 1 and paramStr(1) == "--digest-only":
  # The child: never registers anything.
  echo "DIGESTS ", referenceDigests()
  quit 0

var arenaIndex: array[Arenas.len, cint]

suite "pw_register_map":
  test "registration before any handle; bad arguments":
    let compiled = pw_map_count()
    check compiled == MapNames.len.cint
    let a4 = blob("train-arena-4")
    check register("", a4) == -1
    check pw_register_map(nil, unsafeAddr a4[0], a4.len.int32) == -1
    check register("train-arena-4", "") == -1
    check register("train-arena-4", a4[0..^2]) == -1            # truncated
    check register("train-arena-4", "PBMAP002" & a4[8..^1]) == -1 # wrong magic
    check register("x".repeat(32), a4) == -1                    # longer than 31 bytes
    check register("twin-mesas", a4) == -1                      # a compiled map's name
    for i, name in Arenas:
      arenaIndex[i] = register(name, blob(name))
      check arenaIndex[i] == compiled + i.cint
    check register("train-arena-4", a4) == -1                   # taken
    check pw_map_count() == compiled + Arenas.len.cint
    var buf: array[32, char]
    for i, name in Arenas:
      check pw_map_name(arenaIndex[i], cast[ptr UncheckedArray[char]](addr buf[0]), 32) == 0
      check $cast[cstring](addr buf[0]) == name
    check pw_map_name(pw_map_count(), cast[ptr UncheckedArray[char]](addr buf[0]), 32) == -1
    # Fill the registry (MaxTrainingMaps), then one more is refused.
    for k in Arenas.len..<MaxTrainingMaps: check register("train-fill-" & $k, a4) == compiled + k.cint
    check register("train-overflow", a4) == -1
    check pw_map_count() == compiled + MaxTrainingMaps.cint

  test "Heartwick and twin-mesas: the same hash sequence with and without registration":
    let child = execCmdEx(quoteShell(getAppFilename()) & " --digest-only")
    check child.exitCode == 0
    var theirs = ""
    for line in child.output.splitLines:
      if line.startsWith("DIGESTS "): theirs = line["DIGESTS ".len..^1]
    let ours = referenceDigests()
    echo "reference digests (registered / never registered): ", ours, "/ ", theirs
    check theirs.len > 0 and ours == theirs

  test "each arena plays rules-49 base.bas: bounds, items, on-island cogs, contact, determinism":
    const Ticks = 4000'i32
    for i, name in Arenas:
      let idx = arenaIndex[i]
      let h = scripted(4810'i32 + i.int32, Ticks, idx)
      let env = cast[ptr NativeEnv](h)
      check pw_map(h) == idx
      check minX() == -4800 and minZ() == -2800 and maxX() == 11200 and maxZ() == 6800
      check env.world.controlHearts.len == 10
      check env.world.pickups.len == 28 and env.world.pickups.len <= 32
      var first: seq[Point]
      for s in 0..<Seats: first.add env.world.cogs[s].pos
      var moved, damage, ticks, offIsland = 0
      var drained: array[8*512, int32]
      for t in 0..<Ticks:
        let done = h.stepAll()
        inc ticks
        damage += pw_damage_events(h, cast[ptr UncheckedArray[int32]](addr drained[0]), 512).int
        for s in 0..<Seats:
          let p = env.world.cogs[s].pos
          if env.world.cogs[s].hp > 0 and islandMargin(p.x.int, p.z.int) < Radius div 3 + 40: inc offIsland
        if done: break
      for s in 0..<Seats:
        if env.world.cogs[s].pos != first[s]: inc moved
      echo name, ": ", ticks, " ticks, ", damage, " damage events, ", moved, " / ", Seats, " cogs moved"
      check offIsland == 0
      check moved >= Seats div 2
      check damage > 0
      pw_destroy(h)
      check hashRun(4820'i32 + i.int32, 1500, idx) == hashRun(4820'i32 + i.int32, 1500, idx)

  test "an arena observation encodes (teams.view.1i)":
    let h = pw_create_observation(4830, 600, 207)
    check h != nil
    check pw_set_rules(h, 49) == 0 and pw_set_map(h, arenaIndex[1]) == 0 and pw_reset(h, 4830, 600) == 0
    var ob = newSeq[cfloat](16*837)
    var rs: array[16, cfloat]
    check pw_observe(h, fbuf(ob), fbuf(rs)) == 0
    var finite = true
    for v in ob:
      if v != v: finite = false
    check finite
    pw_destroy(h)

  test "an arena handle and a Heartwick handle on one thread keep their own caches":
    const Ticks = 1500'i32
    let solo = hashRun(4840, Ticks, -1)
    let a = scripted(4840, Ticks, -1)
    let b = scripted(4841, Ticks, arenaIndex[1])
    var acc: Hash = 0
    var n = 0
    for t in 0..<Ticks:
      let done = a.stepAll()
      acc = acc !& hash(pw_state_hash(a)); inc n
      discard b.stepAll()
      if done: break
    pw_destroy(a); pw_destroy(b)
    check $(!$acc) & ":" & $n == solo

  test "after a handle exists: -2":
    check register("train-late", blob("train-arena-9")) == -2
