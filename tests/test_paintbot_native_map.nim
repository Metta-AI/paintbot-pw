## Per-handle maps in the training library (pw_set_map). A handle that never calls it plays
## the rules' own island exactly as the library did before the feature (golden digests
## recorded from the unmodified library); a map handle plays the world the engine builds on a
## thread that ran configureMap, whatever other handles on its thread play.
## Build with --mm:arc --threads:on -d:pwTraining. -d:pwMapGoldenRecord compiles only the
## default-handle run and prints its digests: that is how the goldens were recorded, from the
## library before this feature (its native_env has no pw_set_map).
import std/[unittest, os, random, strutils]
import ../examples/paintbot/[sim, neural_contract, native_env]

when not defined(pwTraining): {.error: "native maps exist only under -d:pwTraining".}

const Root = currentSourcePath().parentDir.parentDir
const Base = Root / "coworld/paintbot/players/base.bas"
type
  Buffer = ptr UncheckedArray[cfloat]
  Actions = array[LegacySeats*ActionSizes.len, int32]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])
template ibuf(a: untyped): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr a[0])
template cbuf(s: string): ptr UncheckedArray[char] =
  (if s.len > 0: cast[ptr UncheckedArray[char]](unsafeAddr s[0]) else: nil)

proc fillActions(actions: var Actions, seed, tick: int) =
  ## test_paintbot_native_env's pattern: a stable objective per seat, changing aim, fire and
  ## charge, mirrored seats included.
  for slot in 0..<Seats:
    let offset = slot*ActionSizes.len
    actions[offset] = int32(1+(slot div 2+seed) mod 10)
    actions[offset+1] = int32(17+(tick div 24+slot) mod 8)
    actions[offset+2] = int32(tick mod 3 == 0)
    actions[offset+3] = int32(tick mod 48 < 12)
    actions[offset+4] = int32(slot mod 3 == 0)

proc fold(digest: var uint64, hash: uint32) =
  ## FNV-1a over the little-endian bytes of each tick's state hash.
  for i in 0..3:
    digest = (digest xor uint64((hash shr (8*i)) and 255)) * 1099511628211'u64

const
  DefaultSeeds = [7'i32, 1001, 424242]
  DefaultTicks = 600
  # Recorded from the library before pw_set_map existed (Metta-AI/paintbot-pw main 1512438)
  # with -d:pwMapGoldenRecord: {seed, FNV-1a of the 600 per-tick state hashes, last hash}.
  DefaultGolden: array[3, (int32, uint64, uint32)] = [
    (7'i32, 11266663677668710009'u64, 352507994'u32),
    (1001'i32, 6868282711088312779'u64, 2626221708'u32),
    (424242'i32, 2418612431003963041'u64, 3271808267'u32)]

proc defaultRun(seed: int32): (uint64, uint32) =
  ## A default handle (no map call): the odd seats run base.bas, the even seats the action
  ## pattern; the digest of every tick's state hash and the last hash.
  let source = readFile(Base)
  let handle = pw_create(seed, DefaultTicks.int32)
  doAssert handle != nil
  for slot in countup(1, Seats-1, 2):
    doAssert pw_set_seat_script(handle, slot.cint, cbuf(source), source.len.int32) == 0
  var actions: Actions
  var rewards, terminals: array[LegacySeats, float32]
  var digest = 14695981039346656037'u64
  var last: uint32
  for tick in 0..<DefaultTicks:
    actions.fillActions(seed.int, tick)
    doAssert pw_step(handle, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
    last = pw_state_hash(handle)
    digest.fold(last)
  for slot in 0..<Seats: doAssert pw_seat_script_status(handle, slot.cint, nil, 0) == int32(slot mod 2)
  pw_destroy(handle)
  (digest, last)

when defined(pwMapGoldenRecord):
  for seed in DefaultSeeds:
    let (digest, last) = defaultRun(seed)
    echo "(", seed, "'i32, ", digest, "'u64, ", last, "'u32),"
else:
  const MapTicks = 300

  proc mapRun(handle: pointer, seed: int32, ticks: int): seq[uint32] =
    ## Steps a handle with the action pattern; the state hash after every tick.
    var actions: Actions
    var rewards, terminals: array[LegacySeats, float32]
    for tick in 0..<ticks:
      actions.fillActions(seed.int, tick)
      doAssert pw_step(handle, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
      result.add pw_state_hash(handle)

  proc aloneRun(map: int, seed: int32, ticks: int): seq[uint32] =
    ## A fresh handle on `map` (-1 the island), set before its first reset, stepped alone.
    let handle = pw_create(seed, ticks.int32)
    doAssert handle != nil
    doAssert pw_set_map(handle, map.cint) == 0
    doAssert pw_reset(handle, seed, ticks.int32) == 0
    doAssert pw_map(handle) == map
    result = mapRun(handle, seed, ticks)
    pw_destroy(handle)

  type ReferenceJob = object
    map: int
    seed: int32
    ticks: int
    hashes: seq[uint32]

  proc referenceThread(job: ptr ReferenceJob) {.thread.} =
    ## The engine's own path (the hosted game, arch_roll): a thread bound to the library's
    ## rules and the map by configureRules and configureMap, a world from newWorld, commands
    ## decoded from the same actions.
    {.cast(gcsafe).}:
      configureRules(NativeRules)
      configureMap(if job.map < 0: "" else: MapNames[job.map])
      var world = newWorld(job.seed, job.ticks.int32)
      var actions: Actions
      var commands: array[LegacySeats, Command]
      for tick in 0..<job.ticks:
        actions.fillActions(job.seed.int, tick)
        for slot in 0..<Seats:
          let offset = slot*ActionSizes.len
          commands[slot] = decodeActions(world, slot, actions.toOpenArray(offset, offset+ActionSizes.len-1))
        world.step(commands)
        job.hashes.add world.stateHash()

  proc referenceRun(map: int, seed: int32, ticks: int): seq[uint32] =
    var job = ReferenceJob(map: map, seed: seed, ticks: ticks)
    var thread: Thread[ptr ReferenceJob]
    createThread(thread, referenceThread, addr job)
    joinThread(thread)
    job.hashes

  proc firstDifference(got, expected: seq[uint32]): int =
    ## The first tick (1-based) whose state hash differs, or a length mismatch; 0 if none.
    for t in 0..<min(got.len, expected.len):
      if got[t] != expected[t]: return t+1
    if got.len != expected.len: return min(got.len, expected.len)+1

  template checkSame(label: string, got, expected: seq[uint32]) =
    ## A template, so the check fails the enclosing test.
    let tick = firstDifference(got, expected)
    if tick != 0: checkpoint label & ": first difference at tick " & $tick
    check tick == 0

  suite "Native per-handle maps":
    test "map ABI: count, names, arguments":
      check pw_map_count() == MapNames.len
      var name: array[32, char]
      let output = cast[ptr UncheckedArray[char]](addr name[0])
      for i, expected in MapNames:
        check pw_map_name(i.cint, output, 32) == 0
        check $cast[cstring](output) == expected
        check pw_map_name(i.cint, output, expected.len.cint) == -1  # no room for the NUL
      check pw_map_name(-1, output, 1) == 0 and name[0] == '\0'
      check pw_map_name(MapNames.len.cint, output, 32) == -1
      check pw_map_name(-2, output, 32) == -1
      check pw_map_name(0, nil, 32) == -1
      check pw_set_map(nil, 0) == -1
      check pw_map(nil) == -2
      let handle = pw_create(3, 50)
      require handle != nil
      check pw_map(handle) == -1
      check pw_set_map(handle, -2) == -1
      check pw_set_map(handle, MapNames.len.cint) == -1
      check pw_set_map(handle, MapNames.high.cint) == 0
      check pw_map(handle) == -1                        # the current world keeps the island
      check pw_reset(handle, 3, 50) == 0
      check pw_map(handle) == MapNames.high
      check pw_reset(handle, 4, 50) == 0                # kept across resets
      check pw_map(handle) == MapNames.high
      check pw_set_map(handle, -1) == 0
      check pw_reset(handle, 4, 50) == 0
      check pw_map(handle) == -1
      pw_destroy(handle)

    test "default handles are byte-identical to the library before maps":
      for i, seed in DefaultSeeds:
        checkpoint "seed " & $seed
        let (digest, last) = defaultRun(seed)
        check (seed, digest, last) == DefaultGolden[i]

    test "every map: pw_set_map + pw_reset == a thread that ran configureMap":
      for map in -1..MapNames.high:
        let seed = int32(501+map)
        checkpoint "map " & (if map < 0: "(island)" else: MapNames[map])
        let expected = referenceRun(map, seed, MapTicks)
        let handle = pw_create(seed, MapTicks.int32)
        require handle != nil
        check pw_set_map(handle, map.cint) == 0
        check pw_reset(handle, seed, MapTicks.int32) == 0
        checkSame("map " & $map, mapRun(handle, seed, MapTicks), expected)
        pw_destroy(handle)
        if map >= 0:
          # The map took effect: not the island's world for the same seed.
          check expected != referenceRun(-1, seed, MapTicks)

    test "handles on different maps interleaved on one thread == each alone":
      # archipelago and delta carry the same number of cover pieces; the island shares none.
      for (a, b) in [(mapIndex("archipelago"), mapIndex("delta")), (-1, mapIndex("crater")),
                     (mapIndex("deep-forest"), mapIndex("deep-forest"))]:
        checkpoint "maps " & $a & " / " & $b
        let (seedA, seedB) = (61'i32, 62'i32)
        let expectedA = aloneRun(a, seedA, MapTicks)
        let expectedB = aloneRun(b, seedB, MapTicks)
        let ha = pw_create(seedA, MapTicks.int32)
        let hb = pw_create(seedB, MapTicks.int32)
        require ha != nil and hb != nil
        check pw_set_map(ha, a.cint) == 0 and pw_reset(ha, seedA, MapTicks.int32) == 0
        check pw_set_map(hb, b.cint) == 0 and pw_reset(hb, seedB, MapTicks.int32) == 0
        var gotA, gotB: seq[uint32]
        var actions: Actions
        var rewards, terminals: array[LegacySeats, float32]
        for tick in 0..<MapTicks:
          actions.fillActions(seedA.int, tick)
          require pw_step(ha, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
          gotA.add pw_state_hash(ha)
          actions.fillActions(seedB.int, tick)
          require pw_step(hb, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
          gotB.add pw_state_hash(hb)
        checkSame("interleaved A", gotA, expectedA)
        checkSame("interleaved B", gotB, expectedB)
        pw_destroy(ha)
        pw_destroy(hb)
      # A map handle whose world may reuse a destroyed handle's memory: the thread's
      # geometry caches (keyed by the cover's address and count) must not carry over.
      let expected = aloneRun(mapIndex("delta"), 63, MapTicks)
      for round in 0..3:
        let old = pw_create(64, MapTicks.int32)
        require old != nil
        check pw_set_map(old, mapIndex("archipelago").cint) == 0 and pw_reset(old, 64, MapTicks.int32) == 0
        discard mapRun(old, 64, 40)
        pw_destroy(old)
        let fresh = pw_create(63, MapTicks.int32)
        require fresh != nil
        check pw_set_map(fresh, mapIndex("delta").cint) == 0 and pw_reset(fresh, 63, MapTicks.int32) == 0
        checkSame("after a destroyed archipelago handle, round " & $round, mapRun(fresh, 63, MapTicks), expected)
        pw_destroy(fresh)

    test "pw_set_map mid-game leaves the current world alone until the next reset":
      let seed = 71'i32
      let ticks = 200
      let map = mapIndex("highlands")
      # Contract v2 carries the terrain block, which reads the thread's map.
      let control = pw_create_observation(seed, ticks.int32, 2)
      let handle = pw_create_observation(seed, ticks.int32, 2)
      require control != nil and handle != nil
      let n = ObservationSizeV2
      var observed, expected = newSeq[float32](Seats*n)
      var resets: array[LegacySeats, float32]
      var actions: Actions
      var rewards, terminals: array[LegacySeats, float32]
      for tick in 0..<ticks:
        if tick == ticks div 2:
          check pw_set_map(handle, map.cint) == 0
          check pw_map(handle) == -1
        actions.fillActions(seed.int, tick)
        require pw_step(control, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
        require pw_step(handle, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
        require pw_state_hash(handle) == pw_state_hash(control)
        if tick mod 25 == 24:
          require pw_observe(control, fbuf(expected), fbuf(resets)) == 0
          require pw_observe(handle, fbuf(observed), fbuf(resets)) == 0
          require observed == expected
      check pw_map(handle) == -1
      check pw_reset(handle, seed, 50) == 0
      check pw_map(handle) == map
      checkSame("after the reset", mapRun(handle, seed, 50), referenceRun(map, seed, 50))
      pw_destroy(control)
      pw_destroy(handle)

    test "a policy-script seat and base.bas seats on map handles: 200 ticks, no script errors":
      const
        K = 2
        Manifest = """{"schema": "paintbot-neural-basic/2", "observation_contract": "$1",
 "action_contract": "$2", "sha256": {},
 "decoder": {"sampling": {"mode": "categorical", "temperature": 0.9}},
 "user_inputs": {"count": 2, "init": [1500, -700]}}"""
        Policy = """
if worldTick mod 50 = 0 then
  neuralInput(0, selfX + worldTick)
  neuralInput(1, heartY - selfY)
end if
paintbot_observe(neuralObservation())
run_neural_net(neuralModel(), neuralObservation(), neuralLogits(), neuralState())
neuralSample()
neuralDecode()
neuralIssue()
"""
      let contract = UserInputsContractHashes[K-1]
      let manifest = Manifest % [contract, ActionContractV2Hash]
      let baseSource = readFile(Base)
      let policy = Policy
      var r = initRand(5)
      for map in [mapIndex("twin-mesas"), mapIndex("deep-forest"), mapIndex("serpent-river")]:
        checkpoint "map " & MapNames[map]
        let seed = int32(81+map)
        let handle = pw_create_observation_inputs(seed, 200, K)
        require handle != nil
        check pw_set_map(handle, map.cint) == 0
        check pw_reset(handle, seed, 200) == 0
        check pw_set_seat_policy_script(handle, 0, cbuf(policy), policy.len.int32,
          cbuf(manifest), manifest.len.int32) == 0
        for slot in 1..<Seats:
          check pw_set_seat_script(handle, slot.cint, cbuf(baseSource), baseSource.len.int32) == 0
        var actions: Actions
        var logits: array[LegacySeats*LogitSize, float32]
        var rewards, terminals: array[LegacySeats, float32]
        var choices: array[22, int32]
        var decided = 0
        for tick in 0..<200:
          for i in 0..<LogitSize: logits[i] = float32(r.rand(4.0)-2.0)
          require pw_step_logits(handle, ibuf(actions), fbuf(logits), fbuf(rewards), fbuf(terminals)) == 0
          if pw_seat_policy_choices(handle, 0, ibuf(choices)) == 0 and choices[0] == 1: inc decided
        check pw_results(handle, fbuf(rewards)) == 0
        check rewards[0] == 200                          # the whole match ran
        check decided > 100
        check pw_map(handle) == map
        var message: array[256, char]
        for slot in 0..<Seats:
          let status = pw_seat_script_status(handle, slot.cint, cast[ptr UncheckedArray[char]](addr message[0]), 256)
          if status != 1: checkpoint "seat " & $slot & ": " & $cast[cstring](addr message[0])
          check status == 1
        pw_destroy(handle)
