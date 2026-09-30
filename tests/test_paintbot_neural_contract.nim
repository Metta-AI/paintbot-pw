## The neural policy contract on SeatView (docs/neural/seat-view.md): observations are fixed
## size and finite for every seat, fog holds (a hidden opponent or an unavailable pickup
## cannot change what the seat observes or does), the deployed selection (argmax, sampling,
## the objective forbid) is exact, and a dead seat or a bad network output is handled
## explicitly. The model's heads reach the engine only through the seat's policy.bas: the
## action-side checks run the reference decoder (players/neural_decode.bas).
import std/[unittest, math, os, options]
import polyworld/[rngs, cli]
import ../examples/paintbot/[sim, kinship, bots, seat_view, neural_contract, neural_host]

const DecodePath = currentSourcePath.parentDir / ".." / "examples" / "paintbot" / "players" / "neural_decode.bas"
let neuralPolicy = "paintbot_observe(neuralObservation())\n" &
  "run_neural_net(neuralModel(), neuralObservation(), neuralLogits(), neuralState())\n" &
  "neuralSample()\n" & readFile(DecodePath)

proc u32(s: var string, value: uint32) =
  for i in 0..3: s.add char((value shr (8*i)) and 255)

proc constantModel(logits: openArray[float32], weight = (-1, -1, 0'f32)): string =
  ## A PWNET002 teams.view.1 actor whose logits are `logits` whatever it observes: one DENSE
  ## layer with zero weights and `logits` as its bias; `weight` (output, input, value) sets
  ## one weight.
  doAssert logits.len == LogitSize
  result = "PWNET002"
  for x in [2, TeamsViewSize, LogitSize, ActionSizes.len]: result.u32(x.uint32)
  for h in ActionSizes: result.u32(h.uint32)
  result.add ObservationContractTeamsView1Hash
  result.add ActionContractTeamsView1Hash
  result.u32(1)
  result.u32(1)
  for p in [TeamsViewSize, LogitSize, 1, 0, 0, 0, 0, 0]: result.u32(p.uint32)
  for o in 0..<LogitSize:
    for i in 0..<TeamsViewSize:
      result.u32(if (o, i) == (weight[0], weight[1]): cast[uint32](weight[2]) else: 0'u32)
  for x in logits: result.u32(cast[uint32](x))

proc peaked(actions: array[ActionSizes.len, int32]): seq[float32] =
  ## Logits whose every head peaks (10) at `actions`.
  result = newSeq[float32](LogitSize)
  var offset = 0
  for head, size in ActionSizes:
    result[offset+actions[head].int] = 10
    offset += size

var bundleCount = 0
proc neuralSeats(model: string, source = neuralPolicy, manifest = ""): seq[Bot] =
  ## Every seat runs `source` over `model` (and `manifest`, when given).
  inc bundleCount
  let path = getTempDir() / ("paintbot-contract-" & $getCurrentProcessId() & "-" & $bundleCount & ".bas")
  writeFile(path, source)
  writeFile(path & ".model.bin", model)
  if manifest.len > 0: writeFile(path & ".neural.json", manifest)
  defer:
    removeFile(path)
    removeFile(path & ".model.bin")
    if manifest.len > 0: removeFile(path & ".neural.json")
  loadBots(@[BotGroup(path: path, count: Seats)])

proc teamsView(w: World, slot: int): array[TeamsViewSize, float32] =
  ## A fresh tick of views on `w`; the seat's teams.view.1 observation over a NaN-filled buffer.
  beginViews(w)
  for i in 0..<result.len: result[i] = NaN.float32
  encodeTeamsView(seatView(slot), result)

proc ffaView(w: World, slot: int, mask = 0'u32): seq[float32] =
  beginViews(w)
  let v = seatView(slot)
  result = newSeq[float32](v.ffaViewLayout.size)
  for i in 0..<result.len: result[i] = NaN.float32
  encodeFfaView(v, result, ffaViewRows(v), mask)

proc finite(xs: openArray[float32]): bool =
  for x in xs:
    if x.classify in {fcNan, fcInf, fcNegInf}: return false
  true

suite "Neural policy contract":
  setup:
    visionRulesVersion = LiveRules
    gameMode = gmTeams
    kinshipOverride = none(Kinship)
    kinLayoutPin = none(KinLayout)
  teardown:
    gameMode = gmTeams
    configureSeats(LegacySeats)
    configureMap("")
    kinLayoutPin = none(KinLayout)

  test "fixed finite observations for every seat and scratch buffers are cleared":
    var w = newWorld(2026)
    let players = loadBots(@[BotGroup(path: currentSourcePath.parentDir / ".." / "examples" / "paintbot" / "players" / "base.bas", count: Seats)])
    for tick in 0..<120:
      let commands = players.decide(w)
      deliverSpeech(w)
      w.step(commands)
    for slot in 0..<Seats:
      let obs = w.teamsView(slot)
      check obs.len == TeamsViewSize and obs.finite
      check obs[11] == float32(slot div 2)/7
      let v = seatView(slot)
      # Rows the seat has nothing for are zero, not what the buffer held.
      for i in v.heartCount.int..<TeamsHeartRows:
        for c in 0..<TeamsHeartWidth: check obs[TeamsHeartOffset + i*TeamsHeartWidth + c] == 0
      for j in 0..<LegacySeats:
        if v.visible(j) == 0:
          for c in 0..<TeamsIdentityWidth: check obs[TeamsIdentityOffset + j*TeamsIdentityWidth + c] == 0
      for i in 0..<TeamsPickupRows:
        if v.pickupVisible(i) == 0:
          for c in 0..<TeamsPickupWidth: check obs[TeamsPickupOffset + i*TeamsPickupWidth + c] == 0
      for i in v.soundCount.int..<TeamsSoundRows:
        for c in 0..<TeamsSoundWidth: check obs[TeamsSoundOffset + i*TeamsSoundWidth + c] == 0
      if v.selfHp > 0:
        let own = TeamsIdentityOffset + slot*TeamsIdentityWidth
        check obs[own] == 1 and obs[own+6] == 1 and obs[own+7] == float32(slot div 2)/7
      # encodeObservation is the same encoder.
      var again: array[TeamsViewSize, float32]
      for i in 0..<again.len: again[i] = NaN.float32
      encodeObservation(v, ocTeamsView1, again)
      check again == obs
    var short: array[TeamsViewSize-1, float32]
    expect ValueError: encodeTeamsView(seatView(0), short)
    var long: array[TeamsViewSize+1, float32]
    expect ValueError: encodeObservation(seatView(0), ocTeamsView1, long)
    # ffa.view.1 at 16 seats: every seat's observation has the match's width and is finite.
    gameMode = gmFfaKin
    kinLayoutPin = some(klCousins)
    var f = newWorld(2026)
    for slot in 0..<Seats:
      let obs = f.ffaView(slot)
      check obs.len == ffaViewLayout(Seats, f.controlHearts.len).size and obs.finite
    var wrong = newSeq[float32](ffaViewLayout(Seats, f.controlHearts.len).size + 1)
    beginViews(f)
    expect ValueError: encodeFfaView(seatView(0), wrong, ffaViewRows(seatView(0)))

  test "hidden opponents cannot change the actor observation":
    var w = newWorld(7)
    w.cogs[0].pos = point(3200,2000)
    w.cogs[0].aim = point(6200,2000)
    w.cogs[1].pos = point(-4000,2000)
    check not w.visible(0,1)
    let before = w.teamsView(0)
    check seatView(0).playerX(1) == -1 and seatView(0).playerHp(1) == 0
    w.cogs[1].pos = point(-3900,2100)
    w.cogs[1].hp = 1
    w.equipment[1].armor = 3
    check not w.visible(0,1)
    check w.teamsView(0) == before
    # FFA-kin: a cog the seat cannot see leaves no row, and its moves, hp and score change nothing.
    gameMode = gmFfaKin
    kinLayoutPin = some(klCousins)
    var f = newWorld(7)
    for i in 0..<f.cogs.len:
      f.cogs[i].hp = 0
      f.equipment[i].lives = 0
    let spot = f.greatHearts[0].pos
    for (slot, dx) in [(0, 0), (1, 300), (2, -300)]:
      f.cogs[slot].hp = FfaMaxHp.int32
      f.cogs[slot].pos = point(spot.x.int + dx, spot.z.int + 600)
      f.cogs[slot].goal = f.cogs[slot].pos
      f.equipment[slot].lives = 1
    f.cogs[0].aim = point(spot.x.int + 1000, spot.z.int + 600)
    check f.visible(0, 1) and not f.visible(0, 2)
    let first = f.ffaView(0)
    let rows = ffaViewRows(seatView(0))
    check rows.agents.len == 1 and rows.agents[0].identity == 1
    f.cogs[2].pos = point(spot.x.int - 400, spot.z.int + 700)
    f.cogs[2].hp = 3
    f.seatScore[2] = 5000
    check not f.visible(0, 2)
    check f.ffaView(0) == first

  test "unavailable pickup locations cannot leak through observations or actions":
    var w = newWorld(7)
    w.pickups[0].readyAt = w.tick+100
    let before = w.teamsView(0)
    check seatView(0).pickupVisible(0) == 0 and seatView(0).pickupX(0) == -1
    # Movement 11 = pickup 0: the reference decoder stays when it cannot see it.
    let players = neuralSeats(constantModel(peaked([11'i32, 0, 0, 0, 0])))
    check not players[0].failed
    let first = players.decide(w)
    check first[0].walk and first[0].goal == w.cogs[0].pos
    w.pickups[0].pos = point(1000,1000)
    check w.teamsView(0) == before
    let again = players.decide(w)
    check again[0].walk and again[0].goal == first[0].goal

  test "categorical and argmax deployment decode identically":
    let w = newWorld(22)
    let actions = [3'i32,18,1,1,0]
    let model = constantModel(peaked(actions))
    let argmax = neuralSeats(model).decide(w)
    let cold = neuralSeats(model, manifest = "{\"schema\": \"paintbot-neural-basic/2\", \"observation_contract\": \"" &
      ObservationContractTeamsView1Hash & "\", \"action_contract\": \"" & ActionContractTeamsView1Hash &
      "\", \"decoder\": {\"sampling\": {\"mode\": \"categorical\", \"temperature\": 0.01}}}")
    check cold[0].neural.sampling.enabled
    let sampled = cold.decide(w)
    for slot in 0..<Seats:
      check not cold[slot].failed
      check sampled[slot] == argmax[slot]
    # Seat 0 (team 0): movement 3 = control heart 2; aim 18 = compass (1, 1) at 5000, fired;
    # grenade on, sneak off.
    let me = w.cogs[0].pos
    check argmax[0].walk and argmax[0].goal == w.controlHearts[2].pos
    check argmax[0].shoot and argmax[0].chargeGrenade and not argmax[0].sneak
    check argmax[0].aim == point(clamp(me.x.int+5000, minX(), maxX()), clamp(me.z.int+5000, minZ(), maxZ()))
    # Seat 1 (team 1): the compass is mirrored.
    let other = w.cogs[1].pos
    check argmax[1].aim == point(clamp(other.x.int-5000, minX(), maxX()), clamp(other.z.int-5000, minZ(), maxZ()))

  test "dead seats and invalid network outputs are handled explicitly":
    var w = newWorld(9)
    w.cogs[0].hp = 0
    let players = neuralSeats(constantModel(peaked([1'i32,1,1,1,1])))
    let dead = players.decide(w)[0]
    check not players[0].failed
    check not dead.walk and not dead.shoot and not dead.chargeGrenade
    check not players[2].failed
    # A choice outside its head is refused (the seat stops, it does not act on it).
    let outside = neuralSeats(constantModel(peaked([1'i32,1,1,1,1])), neuralPolicy & "neuralSetChoice(0, 51)\n")
    let refused = outside.decide(newWorld(9))
    check outside[2].failed and refused[2] == Command()
    var logits = peaked([1'i32,1,1,1,1])
    logits[1] = Inf.float32
    expect ValueError: discard argmaxActions(logits)
    # A non-finite weight is refused at load; the seat never plays.
    let broken = neuralSeats(constantModel(logits))
    for slot in 0..<Seats: check broken[slot].failed
    check broken.decide(newWorld(9)) == newSeq[Command](Seats)
    # Finite weights whose output overflows (logit 1 = 3e38 + 3e38 * the always-1 "inside the
    # map" column of the seat's own probe) stop every live seat at inference; nothing is decoded.
    var huge = peaked([1'i32,1,1,1,1])
    huge[1] = 3e38
    let overflow = neuralSeats(constantModel(huge, (1, TeamsProbeOffset, 3e38'f32)))
    for slot in 0..<Seats: check not overflow[slot].failed
    let none = overflow.decide(newWorld(9))
    for slot in 0..<Seats:
      check overflow[slot].failed
      check none[slot] == Command()

suite "Decoder sampling (bundle option, not a contract change)":
  proc logitsFor(seed: int): seq[float32] =
    ## Deterministic pseudo-random logits in about [-3, 3] (a small LCG, no std/random).
    var x = uint32(seed)*2654435761'u32 + 12345
    result = newSeq[float32](LogitSize)
    for i in 0..<LogitSize:
      x = x*1664525'u32 + 1013904223'u32
      result[i] = float32(int((x shr 8) mod 6000) - 3000) / 1000'f32
  proc allHeads(temperature = 1'f32): SamplingOptions =
    result.enabled = true
    result.temperature = temperature
    for head in 0..<ActionSizes.len: result.heads[head] = true
  proc separated(seed: int): seq[float32] =
    ## logitsFor with every head's argmax lifted by 3, so no near-tie survives a cold draw.
    result = logitsFor(seed)
    let best = argmaxActions(result)
    var offset = 0
    for head, size in ActionSizes:
      result[offset+best[head]] += 3
      offset += size
  test "disabled options are exactly argmax and draw nothing":
    var options: SamplingOptions
    var rng = samplingRng(2026, 0)
    let before = rng.state
    for s in 0..<20:
      let logits = logitsFor(s)
      check sampleActions(logits, options, rng) == argmaxActions(logits)
    check rng.state == before
  test "the stream is a function of the match seed and the slot":
    check samplingSeed(2026, 0) == samplingRng(2026, 0).state
    var seeds: seq[uint64]
    for slot in 0..<Seats: seeds.add samplingSeed(2026, slot)
    for a in 0..<Seats:
      for b in a+1..<Seats: check seeds[a] != seeds[b]
    check samplingSeed(2026, 0) != samplingSeed(2027, 0)
    check samplingSeed(-1, 0) == samplingSeed(-1, 0)
    var first = samplingRng(2026, 3)
    var again = samplingRng(2026, 3)
    var other = samplingRng(2026, 4)
    var otherSeed = samplingRng(2027, 3)
    var differsBySlot, differsBySeed = false
    for s in 0..<500:
      let logits = logitsFor(s)
      let a = sampleActions(logits, allHeads(), first)
      check a == sampleActions(logits, allHeads(), again)
      if a != sampleActions(logits, allHeads(), other): differsBySlot = true
      if a != sampleActions(logits, allHeads(), otherSeed): differsBySeed = true
    check differsBySlot and differsBySeed
  test "one draw per sampled head per call; unsampled heads take argmax":
    var options = allHeads()
    options.heads = [false, true, false, true, false]
    var rng = samplingRng(11, 2)
    for s in 0..<50:
      var expected = rng
      discard expected.next(); discard expected.next()
      let logits = logitsFor(s)
      let picked = sampleActions(logits, options, rng)
      let best = argmaxActions(logits)
      check rng.state == expected.state
      check picked[0] == best[0] and picked[2] == best[2] and picked[4] == best[4]
    var every = allHeads()
    var full = samplingRng(11, 2)
    var expected = full
    for head in 0..<ActionSizes.len: discard expected.next()
    discard sampleActions(logitsFor(0), every, full)
    check full.state == expected.state
  test "draw frequencies follow softmax(logits / temperature); a cold temperature is argmax":
    var logits = newSeq[float32](LogitSize)
    # head 2 (offset 76): [0, ln 3] -> p(1) = 0.75; head 3 (78): [0, 0] -> 0.5;
    # head 4 (80): [2, 0] -> p(0) = e^2/(e^2+1) = 0.881; head 0 (51 entries) all 0 -> uniform.
    logits[77] = ln(3.0).float32
    logits[80] = 2
    var rng = samplingRng(5, 0)
    var count2, count3, count4 = 0
    var head0 = newSeq[int](51)
    const N = 20000
    for i in 0..<N:
      let a = sampleActions(logits, allHeads(), rng)
      if a[2] == 1: inc count2
      if a[3] == 1: inc count3
      if a[4] == 0: inc count4
      inc head0[a[0]]
    check abs(count2/N - 0.75) < 0.02
    check abs(count3/N - 0.5) < 0.02
    check abs(count4/N - 0.881) < 0.02
    for c in head0: check c > 250 and c < 550
    # Temperature 2 halves the log-odds of head 2: p(1) = sqrt(3)/(1+sqrt(3)) = 0.634.
    var warm = samplingRng(5, 0)
    var count2warm = 0
    for i in 0..<N:
      if sampleActions(logits, allHeads(2), warm)[2] == 1: inc count2warm
    check abs(count2warm/N - 0.634) < 0.02
    # Temperature 0.01 on separated logits: every draw is the argmax.
    var cold = samplingRng(5, 0)
    for i in 0..<2000:
      let apart = separated(i)
      check sampleActions(apart, allHeads(0.01), cold) == argmaxActions(apart)
  test "invalid logits and temperatures are rejected":
    var rng = samplingRng(1, 0)
    var bad = logitsFor(1)
    bad[10] = NaN
    expect ValueError: discard sampleActions(bad, allHeads(), rng)
    expect ValueError: discard sampleActions(logitsFor(1), allHeads(0), rng)
    expect ValueError: discard sampleActions(logitsFor(1), allHeads(11), rng)
    expect ValueError: discard sampleActions(newSeq[float32](10), allHeads(), rng)

suite "Decoder objective forbid (bundle option, not a contract change)":
  proc logitsFor(seed: int): seq[float32] =
    var x = uint32(seed)*2654435761'u32 + 12345
    result = newSeq[float32](LogitSize)
    for i in 0..<LogitSize:
      x = x*1664525'u32 + 1013904223'u32
      result[i] = float32(int((x shr 8) mod 6000) - 3000) / 1000'f32
  proc allHeads(): SamplingOptions =
    result.enabled = true
    result.temperature = 1
    for head in 0..<ActionSizes.len: result.heads[head] = true
  proc river(): ObjectiveMask =
    result[9] = true
    result[10] = true
  test "nothing forbidden is exactly argmax and exactly the sampler, draw for draw":
    var none: ObjectiveMask
    check not none.forbidsAny and river().forbidsAny
    var a = samplingRng(3, 1)
    var b = samplingRng(3, 1)
    for s in 0..<200:
      let logits = logitsFor(s)
      check argmaxActions(logits, none) == argmaxActions(logits)
      check sampleActions(logits, allHeads(), a, none) == sampleActions(logits, allHeads(), b)
      check a.state == b.state
  test "a forbidden objective is never the argmax; the next best is, every other head unchanged":
    for s in 0..<200:
      var logits = logitsFor(s)
      logits[9] = 50  # the river heart would win by far
      logits[10] = 49
      let masked = argmaxActions(logits, river())
      let plain = argmaxActions(logits)
      check plain[0] == 9
      var best = 0
      for i in 0..<ActionSizes[0]:
        if i notin [9, 10] and logits[i] > logits[best]: best = i
      check masked[0] == best.int32
      check masked[1..4] == plain[1..4]
    # A NaN is still rejected, even at a forbidden index; forbidding everything is an error.
    var bad = logitsFor(1)
    bad[9] = NaN
    expect ValueError: discard argmaxActions(bad, river())
    var every: ObjectiveMask
    for i in 0..<ActionSizes[0]: every[i] = true
    expect ValueError: discard argmaxActions(logitsFor(1), every)
  test "sampled with a forbid: never drawn, the rest renormalised, one draw per head":
    var logits = newSeq[float32](LogitSize)  # every head uniform
    logits[9] = 5; logits[10] = 5           # most of the mass sits on the river hearts
    var rng = samplingRng(5, 0)
    var counts = newSeq[int](ActionSizes[0])
    const N = 49000
    for i in 0..<N:
      var expected = rng
      for head in 0..<ActionSizes.len: discard expected.next()
      let a = sampleActions(logits, allHeads(), rng, river())
      check rng.state == expected.state
      inc counts[a[0]]
    check counts[9] == 0 and counts[10] == 0
    for i, c in counts:
      if i notin [9, 10]: check c > 800 and c < 1200   # 1000 expected
    # Sampling off with a forbid: the masked argmax, no draw.
    var off: SamplingOptions
    var quiet = samplingRng(5, 0)
    let before = quiet.state
    check sampleActions(logits, off, quiet, river()) == argmaxActions(logits, river())
    check quiet.state == before
