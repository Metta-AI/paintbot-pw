import std/[unittest, math]
import polyworld/rngs
import ../examples/paintbot/[sim, neural_contract]

suite "Neural policy contract":
  setup:
    visionRulesVersion = 37
  test "fixed finite observations for every seat and scratch buffers are cleared":
    let w = newWorld(2026)
    var obs: array[ObservationSize,float32]
    for slot in 0..<Seats:
      for i in 0..<obs.len: obs[i] = NaN.float32
      encodeObservation(w,slot,obs)
      for value in obs: check classify(value) notin {fcNan,fcInf,fcNegInf}
      for i in 442..<448: check obs[i] == 0
      check obs[19] == float32(slot div 2)/7
  test "hidden opponents cannot change the actor observation":
    var w = newWorld(7)
    w.cogs[0].pos = point(3200,2000)
    w.cogs[0].aim = point(6200,2000)
    w.cogs[1].pos = point(-4000,2000)
    check not w.visible(0,1)
    var before,after: array[ObservationSize,float32]
    encodeObservation(w,0,before)
    w.cogs[1].pos = point(-3900,2100)
    w.cogs[1].hp = 1
    w.equipment[1].armor = 3
    check not w.visible(0,1)
    encodeObservation(w,0,after)
    check before == after
  test "unavailable pickup locations cannot leak through observations or actions":
    var w = newWorld(7)
    w.pickups[0].readyAt = w.tick+100
    var before,after: array[ObservationSize,float32]
    encodeObservation(w,0,before)
    let action = [11'i32,0,0,0,0]
    let first = decodeActions(w,0,action)
    w.pickups[0].pos = point(1000,1000)
    encodeObservation(w,0,after)
    check before == after
    check decodeActions(w,0,action) == first
    check first.goal == w.cogs[0].pos
  test "categorical and argmax deployment decode identically":
    let w = newWorld(22)
    let actions = [3'i32,18,1,1,0]
    var logits: array[LogitSize,float32]
    var offset = 0
    for i,size in ActionSizes:
      logits[offset+actions[i].int] = 10
      offset += size
    check decodeActions(w,0,actions) == decodeLogits(w,0,logits)
    check decodeActions(w,0,actions).goal == w.controlHearts[2].pos
  test "dead seats and invalid network outputs are handled explicitly":
    var w = newWorld(9)
    w.cogs[0].hp = 0
    let dead = decodeActions(w,0,[1'i32,1,1,1,1])
    check not dead.walk and not dead.shoot and not dead.chargeGrenade
    expect ValueError: discard decodeActions(w,0,[51'i32,0,0,0,0])
    var logits: array[LogitSize,float32]
    logits[1] = Inf.float32
    expect ValueError: discard decodeLogits(w,0,logits)

proc identityOf(bodies: array[Seats,int], body: int): int =
  for identity, b in bodies:
    if b == body: return identity
  -1

proc openGround(w: World, shooter, target: Point): bool =
  ## A shot's whole geometry in the open: no cover on the line, no trench on either
  ## end, and a straight walk for the target for the ticks the ray needs.
  if w.blocked(shooter) or w.blocked(target): return false
  if w.trenchAt(shooter) >= 0 or w.trenchAt(target) >= 0: return false
  if not w.lineClear(shooter, target): return false
  for k in 0..8:
    let p = point(target.x.int, target.z.int + k*MoveSpeed)
    if w.blocked(p) or w.trenchAt(p) >= 0 or not w.walkClear(target, p): return false
  true

suite "Neural policy contract v2 (lead-compensated identity aim)":
  setup:
    visionRulesVersion = 37
  test "v2 has its own contract id and hash, and hashes name their versions":
    check ActionContractV2 == "paintbot-pw.rules37.action.v2.51-25-2-2-2"
    check ActionContractV2 != ActionContract
    check ActionContractV2Hash != ActionContractHash
    check ActionContractV2Hash.len == 64 and ActionContractHash.len == 64
    check actionContractVersion(ActionContractHash) == acV1
    check actionContractVersion(ActionContractV2Hash) == acV2
    check actionContractHash(acV1) == ActionContractHash
    check actionContractHash(acV2) == ActionContractV2Hash
    check actionContractId(acV2) == ActionContractV2
    expect ValueError: discard actionContractVersion("0" & ActionContractHash[1..^1])
    check LeadTargetMoves == 6 and LeadOwnMoves == 5
  test "v1 decoding is unchanged by the versioned decoder":
    var memory: AimMemory
    memory.resetAimMemory()
    for seed in [3'i32, 11, 2026]:
      var w = newWorld(seed, 2400)
      for tick in 0..<60:
        var commands: array[Seats, Command]
        for slot in 0..<Seats:
          let a = [int32(1+(slot+tick) mod 50), int32((tick*7+slot) mod 25),
                   int32(tick mod 2), int32(tick mod 5 == 0), int32(slot mod 2)]
          let bodies = w.observedBodies(slot)
          let plain = w.decodeActions(slot, a)
          check plain == w.decodeActions(slot, a, bodies)
          check plain == w.decodeActions(slot, a, bodies, acV1, memory)
          check plain == w.decodeActions(slot, a, acV1, memory)
          # With nothing remembered and the seat holding still (movement head 0),
          # v2 resolves every head exactly as v1; directional aims always do.
          let still = [0'i32, a[1], a[2], a[3], a[4]]
          check w.decodeActions(slot, still, bodies, acV1, memory) ==
            w.decodeActions(slot, still, bodies, acV2, memory)
          if a[1] notin 1'i32..16'i32:
            check plain == w.decodeActions(slot, a, bodies, acV2, memory)
          commands[slot] = plain
        w.step(commands)
  test "a v2 identity aim at a moving target lands where the v1 aim misses":
    var w = newWorld(2026, 2400)
    let shooter = 0
    let target = 1
    # Everyone else stands still far from the lane; the two cogs face each other in
    # the open at 1200 units, the target walking straight across the line of fire.
    var s, t: Point
    var found = false
    for gz in countup(600, 3400, 200):
      for gx in countup(0, 5000, 200):
        s = point(gx, gz)
        t = point(gx + 1200, gz)
        if not w.openGround(s, t): continue
        for slot in 0..<Seats:
          if slot notin [shooter, target] and distance2(w.cogs[slot].pos, s) < 2500*2500: continue
        w.cogs[shooter].pos = s; w.cogs[shooter].goal = s; w.cogs[shooter].aim = t
        w.cogs[target].pos = t; w.cogs[target].goal = t
        if w.visible(shooter, target): found = true
        if found: break
      if found: break
    require found
    for slot in 0..<Seats:
      w.cogs[slot].goal = w.cogs[slot].pos
      w.cogs[slot].shield = 0 # No spawn protection: a hit must register.
      w.equipment[slot].armor = 0
    require w.cogs[shooter].cooldown == 0 and w.equipment[shooter].windup == 0
    require not w.equipment[shooter].sprayCan and w.equipment[shooter].armor == 0
    require w.cogs[target].hp == 3
    let far = point(t.x.int, maxZ()-100)
    var walk = Command(walk: true, direct: true, goal: far)
    # One preparatory tick: the target moves, both seats record what they saw.
    var memory: AimMemory
    memory.resetAimMemory()
    memory.recordAimMemory(w, shooter, w.observedBodies(shooter))
    block:
      var commands: array[Seats, Command]
      commands[target] = walk
      w.step(commands)
    require w.cogs[target].pos == point(t.x.int, t.z.int + MoveSpeed)
    t = w.cogs[target].pos
    let bodies = w.observedBodies(shooter)
    let identity = identityOf(bodies, target)
    require identity >= 0
    let actions = [0'i32, int32(identity+1), 1, 0, 0]
    let v1 = w.decodeActions(shooter, actions, bodies, acV1, memory)
    let v2 = w.decodeActions(shooter, actions, bodies, acV2, memory)
    check v1.aim == t
    check v2.aim == point(t.x.int, t.z.int + LeadTargetMoves*MoveSpeed)
    check v1.shoot and v2.shoot and v1.walk and v2.walk
    # Fire each aim in its own copy of the world; the ray leaves after the windup.
    for (name, command, expectedHp) in [("v1", v1, 3'i32), ("v2", v2, 2'i32)]:
      var trial = w
      var fired = false
      for tick in 0..GunWindupTicks:
        var commands: array[Seats, Command]
        commands[target] = walk
        if tick == 0: commands[shooter] = command
        else: commands[shooter] = Command(aim: command.aim)
        trial.step(commands)
        require trial.cogs[target].pos == point(t.x.int, t.z.int + (tick+1)*MoveSpeed)
        if trial.equipment[shooter].windup == 0 and tick > 0: fired = true
      check fired
      checkpoint name
      check trial.cogs[target].hp == expectedHp
  test "v2 leads only what the seat saw last tick and ignores teleports":
    var w = newWorld(7, 2400)
    var s, t: Point
    var found = false
    for gz in countup(600, 3400, 200):
      for gx in countup(0, 5000, 200):
        s = point(gx, gz)
        t = point(gx + 1200, gz)
        if not w.openGround(s, t): continue
        w.cogs[0].pos = s; w.cogs[0].goal = s
        w.cogs[1].pos = t; w.cogs[1].goal = t
        if w.visible(0, 1): found = true
        if found: break
      if found: break
    require found
    for slot in 0..<Seats: w.cogs[slot].goal = w.cogs[slot].pos
    let bodies = w.observedBodies(0)
    let identity = identityOf(bodies, 1)
    require identity >= 0
    let actions = [0'i32, int32(identity+1), 0, 0, 0]
    var memory: AimMemory
    memory.resetAimMemory()
    memory.recordAimMemory(w, 0, bodies)
    # Stale memory (not last tick) resolves to the body, as v1 does.
    w.tick = 5
    check w.decodeActions(0, actions, bodies, acV2, memory).aim == t
    # Last tick: the target moved 20 in x; the seat stays (movement head 0: no drift).
    w.tick = 1
    w.cogs[1].pos = point(t.x.int+20, t.z.int)
    check w.decodeActions(0, actions, bodies, acV2, memory).aim ==
      point(t.x.int + 20 + 6*20, t.z.int)
    # A body that was hidden last tick gets no lead.
    var hidden = memory
    hidden.bodies[identity] = -1
    check w.decodeActions(0, actions, bodies, acV2, hidden).aim == point(t.x.int + 20, t.z.int)
    # A displacement beyond one tick's reach is a respawn, not a velocity.
    w.cogs[1].pos = point(t.x.int+TeleportStep+1, t.z.int)
    check w.decodeActions(0, actions, bodies, acV2, memory).aim ==
      point(t.x.int+TeleportStep+1, t.z.int)
    # The seat's own drift is the move its movement head orders now: a compass step
    # east (team 0, index 43) walks 28 units a tick in the open, so the aim point moves
    # 5 x 28 back against it; sneaking halves the step; a heart far away, the same.
    w.cogs[1].pos = t
    let east = [43'i32, int32(identity+1), 0, 0, 0]
    let step = w.plannedStep(0, point(s.x.int+200, s.z.int), false)
    check step == point(MoveSpeed, 0)
    check w.decodeActions(0, east, bodies, acV2, memory).aim == point(t.x.int - 5*MoveSpeed, t.z.int)
    let sneakEast = [43'i32, int32(identity+1), 0, 0, 1]
    check w.decodeActions(0, sneakEast, bodies, acV2, memory).aim == point(t.x.int - 5*(MoveSpeed div 2), t.z.int)
    check w.decodeActions(0, east, bodies, acV1, memory).aim == t
    # Directional aim, movement and the other heads ignore the version entirely.
    let compass = [45'i32, 19, 1, 1, 1]
    check w.decodeActions(0, compass, bodies, acV1, memory) ==
      w.decodeActions(0, compass, bodies, acV2, memory)

suite "Decoder fire hold (bundle option, not a contract change)":
  setup:
    visionRulesVersion = 37
  proc lane(w: var World, shooter, mate, target: int): (Point, Point, Point) =
    ## Shooter, teammate and target on one open east-west line: the teammate 600 units
    ## ahead of the shooter, the target 1200. Everyone else stands far away.
    var s, m, t: Point
    var found = false
    # Everyone else stands in a row along the far edge, off every lane searched below.
    for slot in 0..<Seats:
      if slot notin [shooter, mate, target]:
        w.cogs[slot].pos = point(200 + slot*80, maxZ() - 60)
    for gz in countup(600, 3200, 200):
      for gx in countup(0, 5000, 200):
        s = point(gx, gz); m = point(gx + 600, gz); t = point(gx + 1200, gz)
        if not w.openGround(s, t) or w.blocked(m) or w.trenchAt(m) >= 0: continue
        w.cogs[shooter].pos = s; w.cogs[shooter].goal = s; w.cogs[shooter].aim = t
        w.cogs[mate].pos = m; w.cogs[mate].goal = m; w.cogs[mate].aim = t
        w.cogs[target].pos = t; w.cogs[target].goal = t
        if w.visible(shooter, target) and w.visible(shooter, mate): found = true
        if found: break
      if found: break
    require found
    for slot in 0..<Seats:
      w.cogs[slot].goal = w.cogs[slot].pos
      w.cogs[slot].shield = 0
      w.equipment[slot].armor = 0
    (s, m, t)
  test "a teammate in the line of fire holds the order; off the line or beyond the target it fires":
    var w = newWorld(2026, 2400)
    let shooter = 0
    let mate = 2 # Same team as seat 0 (slot mod 2).
    let target = 1
    let (s, m, t) = w.lane(shooter, mate, target)
    require team(mate) == team(shooter) and team(target) != team(shooter)
    require w.cogs[shooter].cooldown == 0 and w.equipment[shooter].windup == 0
    require not w.equipment[shooter].sprayCan
    let bodies = w.observedBodies(shooter)
    let identity = identityOf(bodies, target)
    require identity >= 0
    let actions = [0'i32, int32(identity+1), 1, 0, 0]
    var memory: AimMemory
    memory.resetAimMemory()
    # Off (the default): the order fires, byte-identical to before the option existed.
    let plain = w.decodeActions(shooter, actions, bodies, acV1, memory)
    check plain.shoot and plain.aim == t
    check w.decodeActions(shooter, actions, bodies, acV1, memory, false) == plain
    # On: the teammate 600 units ahead sits on the ray, so the shoot order is held and
    # nothing else changes.
    let held = w.decodeActions(shooter, actions, bodies, acV1, memory, true)
    check not held.shoot
    var expected = plain
    expected.shoot = false
    check held == expected
    check w.teammateInLine(shooter, t)
    # The same under contract v2 and through the logits path.
    check not w.decodeActions(shooter, actions, bodies, acV2, memory, true).shoot
    var logits = newSeq[float32](LogitSize)
    logits[51 + identity + 1] = 1; logits[51 + 25 + 1] = 1 # aim = target, fire = 1
    check not w.decodeLogits(shooter, logits, bodies, acV1, memory, true).shoot
    check w.decodeLogits(shooter, logits, bodies, acV1, memory).shoot
    # Off the line: perpendicular offsets just past the tolerance fire, within it hold.
    w.cogs[mate].pos = point(m.x.int, m.z.int + FireHoldRadius + 1)
    check w.decodeActions(shooter, actions, bodies, acV1, memory, true).shoot
    w.cogs[mate].pos = point(m.x.int, m.z.int + FireHoldRadius)
    check not w.decodeActions(shooter, actions, bodies, acV1, memory, true).shoot
    w.cogs[mate].pos = point(m.x.int, m.z.int - 200)
    check w.decodeActions(shooter, actions, bodies, acV1, memory, true).shoot
    # Beyond the target, or behind the shooter, the teammate is not in the way.
    w.cogs[mate].pos = point(t.x.int + 300, t.z.int)
    check w.decodeActions(shooter, actions, bodies, acV1, memory, true).shoot
    w.cogs[mate].pos = point(s.x.int - 300, s.z.int)
    check w.decodeActions(shooter, actions, bodies, acV1, memory, true).shoot
    # A dead teammate on the line is not a body the gun can hit.
    w.cogs[mate].pos = m
    w.cogs[mate].hp = 0
    check w.decodeActions(shooter, actions, bodies, acV1, memory, true).shoot
    w.cogs[mate].hp = 3
    # An enemy on the line is the point of shooting.
    check w.decodeActions(shooter, [0'i32, int32(identityOf(bodies, target)+1), 1, 0, 0],
      bodies, acV1, memory, true).shoot == false # the mate is back on the line
    w.cogs[mate].pos = point(m.x.int, m.z.int + 400)
    w.cogs[3].pos = m; w.cogs[3].goal = m; w.cogs[3].hp = 3; w.cogs[3].shield = 0
    let bodies2 = w.observedBodies(shooter)
    check w.decodeActions(shooter, [0'i32, int32(identityOf(bodies2, target)+1), 1, 0, 0],
      bodies2, acV1, memory, true).shoot
    # A directional aim past the teammate is held too; one the other way is not.
    w.cogs[3].pos = point(s.x.int - 3000, s.z.int - 3000)
    w.cogs[mate].pos = m
    let bodies3 = w.observedBodies(shooter)
    check not w.decodeActions(shooter, [0'i32, 17, 1, 0, 0], bodies3, acV1, memory, true).shoot # east
    check w.decodeActions(shooter, [0'i32, 21, 1, 0, 0], bodies3, acV1, memory, true).shoot # west
    # A walk order with no aim order aims at its goal, as the world applies it.
    var walkOnly = Command(walk: true, goal: t, shoot: true)
    check w.orderedAim(shooter, walkOnly) == t
    check w.holdFire(shooter, walkOnly) and not walkOnly.shoot
    var aimed = Command(walk: true, goal: t, aim: point(s.x.int, s.z.int - 2000), shoot: true)
    check not w.holdFire(shooter, aimed) and aimed.shoot
    # Not shooting: nothing to hold.
    var quiet = Command(walk: true, goal: t)
    check not w.holdFire(shooter, quiet)
  test "the held order is the one the gun would have landed on the teammate":
    var w = newWorld(2026, 2400)
    let shooter = 0
    let mate = 2
    let target = 1
    let (s, m, t) = w.lane(shooter, mate, target)
    discard s; discard m
    require w.cogs[mate].hp == 3 and w.cogs[target].hp == 3
    let bodies = w.observedBodies(shooter)
    let identity = identityOf(bodies, target)
    require identity >= 0
    let actions = [0'i32, int32(identity+1), 1, 0, 0]
    var memory: AimMemory
    memory.resetAimMemory()
    let fired = w.decodeActions(shooter, actions, bodies, acV1, memory, false)
    let held = w.decodeActions(shooter, actions, bodies, acV1, memory, true)
    require fired.shoot and not held.shoot and fired.aim == t
    for (name, command, mateHp) in [("fired", fired, 2'i32), ("held", held, 3'i32)]:
      var trial = w
      for tick in 0..GunWindupTicks:
        var commands: array[Seats, Command]
        commands[shooter] = if tick == 0: command else: Command(aim: command.aim)
        trial.step(commands)
      checkpoint name
      check trial.cogs[mate].hp == mateHp
      check trial.cogs[target].hp == 3

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

suite "Decoder strafe legs (bundle option, not a contract change)":
  setup:
    visionRulesVersion = 37
  proc contact(w: var World, seat, enemy: int, gap = 1200): (Point, Point) =
    ## `seat` and `enemy` 1200 units apart on an open east-west line, both seeing each
    ## other; every other seat stands far away along the edge.
    for slot in 0..<Seats:
      if slot notin [seat, enemy]: w.cogs[slot].pos = point(200 + slot*80, maxZ() - 60)
    for gz in countup(600, 3200, 200):
      for gx in countup(0, 5000, 200):
        let s = point(gx, gz)
        let e = point(gx + gap, gz)
        if not w.openGround(s, e): continue
        w.cogs[seat].pos = s; w.cogs[enemy].pos = e
        w.cogs[seat].goal = s; w.cogs[enemy].goal = e
        w.cogs[seat].aim = e; w.cogs[enemy].aim = s
        if w.visible(seat, enemy) and w.visible(enemy, seat): return (s, e)
    raise newException(AssertionDefect, "no open contact line")
  proc options(reverse = 800'i32, range = DefaultStrafeRange): StrafeOptions =
    result = defaultStrafeOptions()
    result.reversePermille = reverse
    result.range = range
  test "defaults are the pw-diag values; the parameters are validated":
    let d = defaultStrafeOptions()
    check d.enabled and d.range == 5250 and d.legTicks == [3'i32, 6] and d.shotLegTicks == [6'i32, 9] and d.reversePermille == 800
    check strafeOptionsError(d) == ""
    for bad in [StrafeOptions(enabled: true, range: 0, legTicks: [3'i32, 6], shotLegTicks: [6'i32, 9]),
                StrafeOptions(enabled: true, range: 20001, legTicks: [3'i32, 6], shotLegTicks: [6'i32, 9]),
                StrafeOptions(enabled: true, range: 5250, legTicks: [0'i32, 6], shotLegTicks: [6'i32, 9]),
                StrafeOptions(enabled: true, range: 5250, legTicks: [7'i32, 6], shotLegTicks: [6'i32, 9]),
                StrafeOptions(enabled: true, range: 5250, legTicks: [3'i32, 73], shotLegTicks: [6'i32, 9]),
                StrafeOptions(enabled: true, range: 5250, legTicks: [3'i32, 6], shotLegTicks: [5'i32, 9]),
                StrafeOptions(enabled: true, range: 5250, legTicks: [3'i32, 6], shotLegTicks: [9'i32, 8]),
                StrafeOptions(enabled: true, range: 5250, legTicks: [3'i32, 6], shotLegTicks: [6'i32, 9], reversePermille: 1001),
                StrafeOptions(enabled: true, range: 5250, legTicks: [3'i32, 6], shotLegTicks: [6'i32, 9], reversePermille: -1)]:
      check strafeOptionsError(bad) != ""
    check initStrafeState(0).zig == 1 and initStrafeState(3).zig == 1 and initStrafeState(4).zig == -1 and initStrafeState(15).zig == -1
    check strafeSeed(2026, 0) != samplingSeed(2026, 0) and strafeSeed(2026, 0) != strafeSeed(2026, 1)
  test "in contact the movement head becomes a compass leg perpendicular to the enemy, held for its length":
    var w = newWorld(2026, 2400)
    let (s, e) = w.contact(0, 1)
    discard s; discard e
    let bodies = w.observedBodies(0)
    var state = initStrafeState(0)
    var rng = strafeRng(2026, 0)
    var o = options(reverse = 0)   # never reverse: zig stays +1
    var actions = [5'i32, 0, 0, 0, 0]
    check w.strafeActions(0, actions, bodies, o, state, rng)
    # Enemy due east of a team-0 seat, zig +1: perpendicular (0, +1) -> compass 2 -> index 45.
    # The objective (heart 5) is blended in, so allow the neighbouring headings too.
    check actions[0] in 43'i32..50'i32
    check actions[1..4] == [0'i32, 0, 0, 0]
    check state.legs == 1 and state.leg in 2'i32..5'i32 and state.ticks == 1
    # Without an objective to blend (index 0 = keep) the leg is exactly perpendicular.
    state = initStrafeState(0)
    actions = [0'i32, 0, 0, 0, 0]
    check w.strafeActions(0, actions, bodies, o, state, rng)
    check actions[0] == 45
    let length = state.leg + 1
    check length in 3'i32..6'i32
    # The leg holds its heading until it runs out, then a new one starts.
    for k in 1..<length:
      var again = [0'i32, 0, 0, 0, 0]
      check w.strafeActions(0, again, bodies, o, state, rng)
      check again[0] == 45 and state.legs == 1
    var next = [0'i32, 0, 0, 0, 0]
    check w.strafeActions(0, next, bodies, o, state, rng)
    check state.legs == 2 and next[0] == 45   # no reversal at permille 0
    # Always reverse: consecutive legs alternate sides of the line (45 <-> 49).
    var flipper = initStrafeState(0)
    var headings: seq[int32]
    while flipper.legs < 4:
      var a = [0'i32, 0, 0, 0, 0]
      let before = flipper.legs
      check w.strafeActions(0, a, bodies, options(reverse = 1000), flipper, rng)
      if flipper.legs != before: headings.add a[0]
    check headings == @[49'i32, 45, 49, 45]
  test "a ready shot with too little leg left starts a shot leg; the shot itself stands":
    var w = newWorld(2026, 2400)
    discard w.contact(0, 1)
    let bodies = w.observedBodies(0)
    require w.cogs[0].cooldown == 0 and w.equipment[0].windup == 0 and not w.equipment[0].sprayCan
    var rng = strafeRng(7, 0)
    for trial in 0..<50:
      var state = initStrafeState(0)
      var a = [0'i32, 0, 0, 0, 0]
      check w.strafeActions(0, a, bodies, options(), state, rng)   # a plain leg
      check state.leg + 1 in 3'i32..6'i32
      var shot = [0'i32, 0, 1, 0, 0]
      let legsBefore = state.legs
      check w.strafeActions(0, shot, bodies, options(), state, rng)
      check shot[2] == 1
      # A plain leg has at most 5 ticks left after its first, fewer than the 6 a shot
      # needs, so the ready shot starts a new shot leg of 6..9 ticks.
      check state.legs == legsBefore + 1
      check state.leg + 1 in 6'i32..9'i32
      # A shot while a long enough leg runs does not restart it.
      let legsNow = state.legs
      var shot2 = [0'i32, 0, 1, 0, 0]
      if state.leg >= 6:
        check w.strafeActions(0, shot2, bodies, options(), state, rng)
        check state.legs == legsNow
    # A shoot order the gun cannot take (cooling down) does not ask for a shot leg.
    var cooling = w
    cooling.cogs[0].cooldown = 10
    var state = initStrafeState(0)
    var a = [0'i32, 0, 0, 0, 0]
    check cooling.strafeActions(0, a, bodies, options(), state, rng)
    var shot = [0'i32, 0, 1, 0, 0]
    let legs = state.legs
    if state.leg > 0:
      check cooling.strafeActions(0, shot, bodies, options(), state, rng)
      check state.legs == legs
  test "out of contact, out of range, dead, in a trench or disabled: untouched and the leg ends":
    var w = newWorld(2026, 2400)
    discard w.contact(0, 1, 1200)
    var rng = strafeRng(1, 0)
    var state = initStrafeState(0)
    var a = [7'i32, 3, 1, 0, 1]
    check w.strafeActions(0, a, w.observedBodies(0), options(), state, rng)
    require state.leg > 0
    # Range shorter than the gap.
    var b = [7'i32, 3, 1, 0, 1]
    check not w.strafeActions(0, b, w.observedBodies(0), options(range = 1000), state, rng)
    check b == [7'i32, 3, 1, 0, 1] and state.leg == 0
    # No visible enemy (the only one is dead).
    var gone = w
    gone.cogs[1].hp = 0
    var c = [7'i32, 3, 1, 0, 1]
    check not gone.strafeActions(0, c, gone.observedBodies(0), options(), state, rng)
    check c == [7'i32, 3, 1, 0, 1]
    # The seat itself dead.
    var dead = w
    dead.cogs[0].hp = 0
    check not dead.strafeActions(0, c, w.observedBodies(0), options(), state, rng)
    # Disabled options: untouched, no draw.
    let before = rng.state
    var off: StrafeOptions
    check not w.strafeActions(0, c, w.observedBodies(0), off, state, rng)
    check rng.state == before and c == [7'i32, 3, 1, 0, 1]
    # A teammate is never a threat.
    var mates = newWorld(2026, 2400)
    discard mates.contact(0, 2)
    var d = [7'i32, 3, 1, 0, 1]
    check not mates.strafeActions(0, d, mates.observedBodies(0), options(), state, rng)
    # In a trench (base.bas holds its trench in contact).
    if w.trenches.len > 0:
      var dug = w
      let t = w.trenches[0]
      dug.cogs[0].pos = point(t.x.int + t.w.int div 2, t.z.int + t.h.int div 2)
      require dug.trenchAt(dug.cogs[0].pos) >= 0
      var e = [7'i32, 3, 1, 0, 1]
      check not dug.strafeActions(0, e, w.observedBodies(0), options(), state, rng)
  test "team 1 legs are perpendicular in world space too, and forbidden headings are skipped":
    var w = newWorld(2026, 2400)
    let (s, e) = w.contact(1, 0)   # seat 1 (team 1) at s, enemy seat 0 due east at e
    let bodies = w.observedBodies(1)
    var state = initStrafeState(1)
    var rng = strafeRng(2026, 1)
    var a = [0'i32, 0, 0, 0, 0]
    check w.strafeActions(1, a, bodies, options(reverse = 0), state, rng)
    let (found, goal) = w.goalCandidate(1, a[0].int)
    require found
    check goal.x == s.x          # moves along z only: perpendicular to the east-west line
    check goal.z != s.z
    discard e
    # Forbid both perpendicular compass headings: the next nearest allowed heading.
    var mask: ObjectiveMask
    mask[45] = true; mask[49] = true
    var zero = initStrafeState(0)
    var w2 = newWorld(2026, 2400)
    discard w2.contact(0, 1)
    var b = [0'i32, 0, 0, 0, 0]
    check w2.strafeActions(0, b, w2.observedBodies(0), options(reverse = 0), zero, rng, mask)
    check b[0] notin [45'i32, 49] and b[0] in [44'i32, 46]
    var all: ObjectiveMask
    for i in 43..50: all[i] = true
    var none = initStrafeState(0)
    var c = [0'i32, 0, 0, 0, 0]
    check not w2.strafeActions(0, c, w2.observedBodies(0), options(), none, rng, all)
    check c[0] == 0
  test "the same stream and world replay the same legs; another stream differs":
    var w = newWorld(2026, 2400)
    discard w.contact(0, 1)
    let bodies = w.observedBodies(0)
    proc run(w: World, seed: int32): seq[int32] =
      var state = initStrafeState(0)
      var rng = strafeRng(seed, 0)
      for tick in 0..<400:
        var a = [0'i32, 0, int32(tick mod 3 == 0), 0, 0]
        discard w.strafeActions(0, a, bodies, defaultStrafeOptions(), state, rng)
        result.add a[0]
    check run(w, 2026) == run(w, 2026)
    check run(w, 2026) != run(w, 2027)
