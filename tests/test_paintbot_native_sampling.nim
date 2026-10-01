## Decoder sampling through the native training ABI: arguments and reset semantics,
## sampling off = argmax with no draw, a sampling seat's draws equal the reference
## sampler on the stream the hosted seat would seed for the same match seed and slot
## (so probes and deployment agree), reset reseeds, seats and seeds differ, head masks,
## temperature, and pw_step untouched: the same caller actions give the same world hash
## whether or not a seat samples. The sampling salt (pw_set_sampling_salt): 0 is byte-identical
## to never calling it, for pw_sample_actions games and policy-seat games; a non-zero salt draws
## differently, deterministically, on both paths, and never reaches the world.
## Build with --mm:arc --threads:on -d:pwTraining.
import std/[unittest, os]
import polyworld/[cli, rngs]
import ../examples/paintbot/[sim, neural_contract, native_env]

when not defined(pwTraining): {.error: "the native ABI exists only under -d:pwTraining".}

type Buffer = ptr UncheckedArray[cfloat]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])
template ibuf(a: untyped): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr a[0])

proc logitsFor(seed: int): array[LogitSize, float32] =
  var x = uint32(seed)*2654435761'u32 + 12345
  for i in 0..<LogitSize:
    x = x*1664525'u32 + 1013904223'u32
    result[i] = float32(int((x shr 8) mod 6000) - 3000) / 1000'f32
proc separated(seed: int): array[LogitSize, float32] =
  ## logitsFor with every head's argmax lifted by 3, so no near-tie survives a cold draw.
  result = logitsFor(seed)
  let best = argmaxActions(result)
  var offset = 0
  for head, size in ActionSizes:
    result[offset+best[head]] += 3
    offset += size
proc options(temperature = 1'f32, mask = 0): SamplingOptions =
  result.enabled = true
  result.temperature = temperature
  for head in 0..<ActionSizes.len: result.heads[head] = mask == 0 or (mask and (1 shl head)) != 0
proc sample(handle: pointer, seat: int, logits: var array[LogitSize, float32]): array[ActionSizes.len, int32] =
  require pw_sample_actions(handle, seat.cint, fbuf(logits), ibuf(result)) == 0

suite "Native ABI decoder sampling":
  test "arguments and defaults":
    let h = pw_create(7, 14400)
    require h != nil
    defer: pw_destroy(h)
    check pw_set_seat_sampling(nil, 0, 1000, 0) == -1
    check pw_set_seat_sampling(h, -1, 1000, 0) == -1
    check pw_set_seat_sampling(h, Seats.cint, 1000, 0) == -1
    check pw_set_seat_sampling(h, 0, -1, 0) == -1
    check pw_set_seat_sampling(h, 0, 5, 0) == -1
    check pw_set_seat_sampling(h, 0, 10001, 0) == -1
    check pw_set_seat_sampling(h, 0, 1000, 32) == -1
    check pw_set_seat_sampling(h, 0, 1000, -1) == -1
    check pw_set_seat_sampling(h, 0, 0, 0) == 0
    check pw_set_seat_sampling(h, 0, 10, 31) == 0
    check pw_set_seat_sampling(h, 0, 10000, 0) == 0
    var logits = logitsFor(0)
    var actions: array[ActionSizes.len, int32]
    check pw_sample_actions(nil, 0, fbuf(logits), ibuf(actions)) == -1
    check pw_sample_actions(h, Seats.cint, fbuf(logits), ibuf(actions)) == -1
    check pw_sample_actions(h, 0, nil, ibuf(actions)) == -1
    check pw_sample_actions(h, 0, fbuf(logits), nil) == -1
    logits[3] = NaN
    check pw_sample_actions(h, 0, fbuf(logits), ibuf(actions)) == -1
    check pw_seat_sample_draws(nil, 0) == -1
    check pw_seat_sample_draws(h, Seats.cint) == -1
  test "sampling off is argmax with no draw; on, the draws are the reference sampler's on the hosted seat's stream":
    let h = pw_create(7, 14400)
    require h != nil
    defer: pw_destroy(h)
    for s in 0..<20:
      var logits = logitsFor(s)
      check sample(h, 3, logits) == argmaxActions(logits)
    check pw_seat_sample_draws(h, 3) == 0
    check pw_set_seat_sampling(h, 3, 1000, 0) == 0
    var reference = samplingRng(7, 3)
    var sequence: seq[array[ActionSizes.len, int32]]
    for s in 0..<200:
      var logits = logitsFor(s)
      let picked = sample(h, 3, logits)
      check picked == sampleActions(logits, options(), reference)
      sequence.add picked
    check pw_seat_sample_draws(h, 3) == 200
    # Reset on the same seed reseeds the stream: the same sequence again, counts cleared.
    check pw_reset(h, 7, 14400) == 0
    check pw_seat_sample_draws(h, 3) == 0
    for s in 0..<200:
      var logits = logitsFor(s)
      check sample(h, 3, logits) == sequence[s]
    # Another seed, and another seat on the same seed, draw differently.
    check pw_reset(h, 8, 14400) == 0
    var differs = false
    for s in 0..<200:
      var logits = logitsFor(s)
      if sample(h, 3, logits) != sequence[s]: differs = true
    check differs
    check pw_reset(h, 7, 14400) == 0
    check pw_set_seat_sampling(h, 4, 1000, 0) == 0
    differs = false
    for s in 0..<200:
      var logits = logitsFor(s)
      if sample(h, 4, logits) != sequence[s]: differs = true
    check differs
    # Two handles on the same seed agree.
    let other = pw_create(7, 14400)
    require other != nil
    defer: pw_destroy(other)
    check pw_set_seat_sampling(other, 3, 1000, 0) == 0
    for s in 0..<200:
      var logits = logitsFor(s)
      check sample(other, 3, logits) == sequence[s]
  test "head masks and temperature follow the reference options":
    let h = pw_create(9, 14400)
    require h != nil
    defer: pw_destroy(h)
    check pw_set_seat_sampling(h, 0, 2000, 0b01010) == 0
    check pw_set_seat_sampling(h, 1, 10, 0) == 0
    var masked = samplingRng(9, 0)
    for s in 0..<100:
      var logits = logitsFor(s)
      let picked = sample(h, 0, logits)
      check picked == sampleActions(logits, options(2, 0b01010), masked)
      let best = argmaxActions(logits)
      check picked[0] == best[0] and picked[2] == best[2] and picked[4] == best[4]
      var apart = separated(s)
      check sample(h, 1, apart) == argmaxActions(apart)
    check pw_seat_sample_draws(h, 0) == 100 and pw_seat_sample_draws(h, 1) == 100
    # Off again: argmax, no further draws counted.
    check pw_set_seat_sampling(h, 0, 0, 0) == 0
    var logits = logitsFor(0)
    check sample(h, 0, logits) == argmaxActions(logits)
    check pw_seat_sample_draws(h, 0) == 100
  test "pw_step and the world hash are untouched by sampling":
    let plain = pw_create(2026, 14400)
    let sampling = pw_create(2026, 14400)
    require plain != nil and sampling != nil
    defer:
      pw_destroy(plain)
      pw_destroy(sampling)
    for seat in 0..<Seats: check pw_set_seat_sampling(sampling, seat.cint, 1000, 0) == 0
    var actions: array[LegacySeats*ActionSizes.len, int32]
    var rewards, terminals: array[LegacySeats, cfloat]
    var observations: array[LegacySeats*TeamsViewSize, cfloat]
    var resets: array[LegacySeats, cfloat]
    for tick in 0..<300:
      # The same caller actions for both handles; the sampling handle also draws, which
      # must not reach the world.
      for slot in 0..<Seats:
        var logits = logitsFor(tick*Seats + slot)
        var picked: array[ActionSizes.len, int32]
        check pw_sample_actions(sampling, slot.cint, fbuf(logits), ibuf(picked)) == 0
        let best = argmaxActions(logits)
        for head in 0..<ActionSizes.len: actions[slot*ActionSizes.len+head] = best[head]
      for handle in [plain, sampling]:
        check pw_step(handle, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
        check pw_observe(handle, fbuf(observations), fbuf(resets)) == 0
      check pw_state_hash(plain) == pw_state_hash(sampling)
    check pw_seat_sample_draws(sampling, 0) == 300

const
  Root = currentSourcePath().parentDir.parentDir
  Base = Root / "coworld/paintbot/players/base.bas"
  PolicySource = "paintbot_observe(neuralObservation())\n" &
    "run_neural_net(neuralModel(), neuralObservation(), neuralLogits(), neuralState())\nneuralSample()\n" &
    staticRead("../examples/paintbot/players/neural_decode.bas")
  PolicyManifest = """{"schema": "paintbot-neural-basic/2", "observation_contract": """" &
    ObservationContractTeamsView1Hash & """", "action_contract": """" & ActionContractTeamsView1Hash &
    """", "decoder": {"sampling": {"mode": "categorical"}}}"""
template cbuf(s: string): ptr UncheckedArray[char] = cast[ptr UncheckedArray[char]](unsafeAddr s[0])

type Record = object
  actions: seq[int32]   # every seat's executed head choices, tick by tick
  hashes: seq[uint32]   # pw_state_hash after every step

proc sampledGame(salt: int64, call: bool, seed = 2026'i32, ticks = 400): Record =
  ## Every seat samples (T = 1, every head) and steps on its own draws: the native game a
  ## pw_sample_actions trainer plays.
  let h = pw_create(seed, 14400)
  doAssert h != nil
  defer: pw_destroy(h)
  if call: doAssert pw_set_sampling_salt(h, salt) == 0
  for seat in 0..<Seats: doAssert pw_set_seat_sampling(h, seat.cint, 1000, 0) == 0
  doAssert pw_reset(h, seed, 14400) == 0
  var actions: array[LegacySeats*ActionSizes.len, int32]
  var rewards, terminals: array[LegacySeats, cfloat]
  for tick in 0..<ticks:
    for slot in 0..<Seats:
      var logits = logitsFor(tick*Seats + slot)
      var picked: array[ActionSizes.len, int32]
      doAssert pw_sample_actions(h, slot.cint, fbuf(logits), ibuf(picked)) == 0
      for head in 0..<ActionSizes.len:
        actions[slot*ActionSizes.len+head] = picked[head]
        result.actions.add picked[head]
    doAssert pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
    result.hashes.add pw_state_hash(h)
  doAssert pw_seat_sample_draws(h, 0) == ticks.cint

type SaltCall = enum scNone, scBeforeInstall, scAfterInstall
proc policyGame(salt: int64, call: SaltCall, seed = 77'i32, ticks = 300): Record =
  ## Even seats run a categorical-sampling bundle (policy.bas + manifest) on fixed trainer
  ## logits, odd seats base.bas: the native paired game an evaluator plays. Played twice, the
  ## second time after pw_reset on the same seed, which must repeat the first exactly.
  let h = pw_create(seed, 14400)
  doAssert h != nil
  defer: pw_destroy(h)
  if call == scBeforeInstall: doAssert pw_set_sampling_salt(h, salt) == 0
  let base = readFile(Base)
  for s in 0..<Seats:
    if s mod 2 == 0:
      doAssert pw_set_seat_policy_script(h, s.cint, cbuf(PolicySource), PolicySource.len.int32,
        cbuf(PolicyManifest), PolicyManifest.len.int32) == 0
    else:
      doAssert pw_set_seat_script(h, s.cint, cbuf(base), base.len.int32) == 0
  if call == scAfterInstall:
    doAssert pw_set_sampling_salt(h, salt) == 0
    doAssert pw_reset(h, seed, 14400) == 0
  var actions: array[LegacySeats*ActionSizes.len, int32]
  var logits: array[LegacySeats*LogitSize, cfloat]
  var rewards, terminals: array[LegacySeats, cfloat]
  var choices: array[22, int32]
  var passes: array[2, Record]
  for pass in 0..1:
    if pass == 1: doAssert pw_reset(h, seed, 14400) == 0
    for tick in 0..<ticks:
      for slot in 0..<Seats:
        let row = logitsFor(tick*Seats + slot)
        for i in 0..<LogitSize: logits[slot*LogitSize+i] = row[i]
      doAssert pw_step_logits(h, ibuf(actions), fbuf(logits), fbuf(rewards), fbuf(terminals)) == 0
      passes[pass].hashes.add pw_state_hash(h)
      for s in countup(0, Seats-1, 2):
        doAssert pw_seat_policy_choices(h, s.cint, ibuf(choices)) == 0
        for v in choices: passes[pass].actions.add v
    for s in 0..<Seats: doAssert pw_seat_script_status(h, s.cint, nil, 0) == 1
  doAssert passes[0] == passes[1], "a reset on the same seed must replay the match"
  passes[0]

suite "Native ABI sampling salt":
  test "the salted stream: 0 is samplingRng, every other salt moves every (seed, slot) stream":
    check mixSamplingSalt(0) == 0
    for salt in [1'i64, 2, -1, high(int64), low(int64)]: check mixSamplingSalt(salt) != 0
    for (seed, slot) in [(7'i32, 3), (-1'i32, 0), (2026'i32, 15)]:
      check samplingRngSalted(seed, slot, 0) == samplingRng(seed, slot)
      check samplingRngSalted(seed, slot, 1) != samplingRng(seed, slot)
      check samplingRngSalted(seed, slot, 1) != samplingRngSalted(seed, slot, 2)
      check samplingRngSalted(seed, slot, 1) == samplingRngSalted(seed, slot, 1)
      check samplingRngSalted(seed, slot, 1) != samplingRngSalted(seed, (slot+1) mod Seats, 1)
  test "arguments, reset timing, and pw_sample_actions draws on the salted stream":
    check pw_set_sampling_salt(nil, 1) == -1
    let h = pw_create(7, 14400)
    require h != nil
    defer: pw_destroy(h)
    check pw_set_seat_sampling(h, 3, 1000, 0) == 0
    # Set mid-match: the current match keeps its unsalted stream.
    check pw_set_sampling_salt(h, 5) == 0
    var plain = samplingRng(7, 3)
    for s in 0..<50:
      var logits = logitsFor(s)
      check sample(h, 3, logits) == sampleActions(logits, options(), plain)
    # From the next reset (and every later one: the salt is kept), the salted stream.
    for round in 0..1:
      check pw_reset(h, 7, 14400) == 0
      var salted = samplingRngSalted(7, 3, 5)
      for s in 0..<200:
        var logits = logitsFor(s)
        check sample(h, 3, logits) == sampleActions(logits, options(), salted)
    # Back to 0: the unsalted stream again from the next reset.
    check pw_set_sampling_salt(h, 0) == 0
    check pw_reset(h, 7, 14400) == 0
    plain = samplingRng(7, 3)
    for s in 0..<200:
      var logits = logitsFor(s)
      check sample(h, 3, logits) == sampleActions(logits, options(), plain)
  test "pw_sample_actions game: salt 0 is byte-identical to no call; a salt draws differently, deterministically":
    let none = sampledGame(0, call = false)
    let zero = sampledGame(0, call = true)
    check zero.actions == none.actions
    check zero.hashes == none.hashes
    let one = sampledGame(1, call = true)
    check one == sampledGame(1, call = true)
    check one.actions != none.actions
    check sampledGame(2, call = true).actions != one.actions
    check sampledGame(-1, call = true).actions != none.actions
  test "policy-seat game: salt 0 is byte-identical to no call; a salt draws differently, deterministically":
    let none = policyGame(0, scNone)
    check policyGame(0, scBeforeInstall) == none
    check policyGame(0, scAfterInstall) == none
    let one = policyGame(1, scBeforeInstall)
    check policyGame(1, scBeforeInstall) == one
    check policyGame(1, scAfterInstall) == one
    check one.actions != none.actions
    check policyGame(2, scBeforeInstall).actions != one.actions
  test "the salt never reaches the world: same caller actions, same hashes":
    let plain = pw_create(2026, 14400)
    let salted = pw_create(2026, 14400)
    require plain != nil and salted != nil
    defer:
      pw_destroy(plain)
      pw_destroy(salted)
    check pw_set_sampling_salt(salted, 99) == 0
    for handle in [plain, salted]:
      check pw_reset(handle, 2026, 14400) == 0
      for seat in 0..<Seats: check pw_set_seat_sampling(handle, seat.cint, 1000, 0) == 0
    check pw_state_hash(plain) == pw_state_hash(salted)
    var actions: array[LegacySeats*ActionSizes.len, int32]
    var rewards, terminals: array[LegacySeats, cfloat]
    for tick in 0..<300:
      for slot in 0..<Seats:
        var logits = logitsFor(tick*Seats + slot)
        var picked: array[ActionSizes.len, int32]
        check pw_sample_actions(salted, slot.cint, fbuf(logits), ibuf(picked)) == 0
        let best = argmaxActions(logits)
        for head in 0..<ActionSizes.len: actions[slot*ActionSizes.len+head] = best[head]
      for handle in [plain, salted]:
        check pw_step(handle, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
      check pw_state_hash(plain) == pw_state_hash(salted)
