## Decoder sampling through the native training ABI: arguments and reset semantics,
## sampling off = argmax with no draw, a sampling seat's draws equal the reference
## sampler on the stream the hosted seat would seed for the same match seed and slot
## (so probes and deployment agree), reset reseeds, seats and seeds differ, head masks,
## temperature, and pw_step untouched: the same caller actions give the same world hash
## whether or not a seat samples. Build with --mm:arc --threads:on -d:pwTraining.
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
    var actions: array[Seats*ActionSizes.len, int32]
    var rewards, terminals: array[Seats, cfloat]
    var observations: array[Seats*ObservationSize, cfloat]
    var resets: array[Seats, cfloat]
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
