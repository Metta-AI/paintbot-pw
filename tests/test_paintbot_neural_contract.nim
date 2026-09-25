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
  test "the hold radius (decoder.fire_hold_teammates {radius}): default 55, a wider radius holds a teammate beside the line":
    var w = newWorld(2026, 2400)
    let (s, m, t) = w.lane(0, 2, 1)
    let command = Command(walk: true, goal: s, aim: t, shoot: true)
    for (offset, heldAt55, heldAt150) in [(0, true, true), (55, true, true), (56, false, true), (100, false, true),
                                          (150, false, true), (151, false, false), (-150, false, true), (-151, false, false)]:
      w.cogs[2].pos = point(m.x.int, m.z.int + offset)
      checkpoint $offset
      check w.teammateInLine(0, t) == heldAt55
      check w.teammateInLine(0, t, FireHoldRadius.int32) == heldAt55
      check w.teammateInLine(0, t, 150) == heldAt150
      var a = command
      var b = command
      check w.holdFire(0, a) == heldAt55 and a.shoot == not heldAt55
      check w.holdFire(0, b, 150) == heldAt150 and b.shoot == not heldAt150
    # Still only up to the aim point and never behind the shooter, whatever the radius.
    w.cogs[2].pos = point(t.x.int + 300, t.z.int)
    check not w.teammateInLine(0, t, 2000)
    w.cogs[2].pos = point(s.x.int - 300, s.z.int)
    check not w.teammateInLine(0, t, 2000)
    # The widest radius is a valid argument (every product still fits in 63 bits).
    w.cogs[2].pos = point(m.x.int, m.z.int + 100)
    check w.teammateInLine(0, t, MaxFireHoldRadius)
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

suite "Decoder aim snap (bundle option, not a contract change)":
  setup:
    visionRulesVersion = 37
  proc place(w: var World, seat: int, offsets: openArray[(int, int, int)]): Point =
    ## `seat` in the open, facing its first placed body, with each (body, dx, dz) placed at
    ## its offset, every line clear, every placed body visible to the seat and no pickup
    ## near the seat; everyone else far away along the edge, still and unshielded. Returns
    ## the seat's position.
    for slot in 0..<Seats:
      w.cogs[slot].pos = point(200 + slot*80, maxZ() - 60)
    for gz in countup(1000, 3000, 100):
      for gx in countup(200, 4000, 100):
        let s = point(gx, gz)
        if w.blocked(s) or w.trenchAt(s) >= 0: continue
        var ok = true
        for pickup in w.pickups:
          if distance2(pickup.pos, s) < 300*300: ok = false
        for (body, dx, dz) in offsets:
          let p = point(gx + dx, gz + dz)
          if p.x < minX()+100 or p.x > maxX()-100 or p.z < minZ()+100 or p.z > maxZ()-100 or
              w.blocked(p) or w.trenchAt(p) >= 0 or not w.lineClear(s, p):
            ok = false
            break
        if not ok: continue
        w.cogs[seat].pos = s
        w.cogs[seat].aim = point(gx + 2*offsets[0][1], gz + 2*offsets[0][2])
        for (body, dx, dz) in offsets: w.cogs[body].pos = point(gx + dx, gz + dz)
        for (body, dx, dz) in offsets:
          if not w.visible(seat, body): ok = false
        if not ok: continue
        for slot in 0..<Seats:
          w.cogs[slot].goal = w.cogs[slot].pos
          w.cogs[slot].shield = 0
          w.equipment[slot].armor = 0
        return s
    raise newException(AssertionDefect, "no open placement")
  proc offsetAt(degrees: float, reach: int): (int, int) =
    (int(round(float(reach) * cos(degrees * PI / 180))), int(round(float(reach) * sin(degrees * PI / 180))))
  let snap = aimSnapOptions(DefaultAimSnapMillideg)
  test "options: 22.5 degrees is cos_q15 30274; the angle is validated":
    check snap.enabled and snap.maxAngleMillideg == 22500 and snap.cosQ15 == 30274
    check aimSnapOptions(90000).cosQ15 == 0 and aimSnapOptions(1).cosQ15 == AimSnapCosScale
    for bad in [0'i32, -1, 90001]:
      check aimSnapOptionsError(bad) != ""
      expect ValueError: discard aimSnapOptions(bad)
    check aimSnapOptionsError(45000) == ""
  test "a compass shoot order within the angle of a visible enemy takes that enemy's identity":
    # Compass index 17 is east (+x) for team 0. Enemy seat 1 at 20 degrees: snapped; at
    # 25 degrees: not; at 22.4 / 22.6 around the threshold.
    for (degrees, snaps) in [(0.0, true), (10.0, true), (-20.0, true), (22.4, true), (22.6, false), (25.0, false), (-25.0, false)]:
      var w = newWorld(2026, 2400)
      let (dx, dz) = offsetAt(degrees, 2000)
      discard w.place(0, [(1, dx, dz)])
      let bodies = w.observedBodies(0)
      let identity = identityOf(bodies, 1)
      require identity >= 0
      var a = [3'i32, 17, 1, 1, 1]
      checkpoint $degrees
      check w.aimSnapActions(0, a, bodies, snap) == snaps
      check a == (if snaps: [3'i32, int32(identity+1), 1, 1, 1] else: [3'i32, 17, 1, 1, 1])
    # Every compass heading: an enemy 15 degrees off it is snapped from that heading only.
    for k in 0..7:
      var w = newWorld(2026, 2400)
      let heading = float(k) * 45.0
      let (dx, dz) = offsetAt(heading + 15.0, 1500)
      discard w.place(0, [(1, dx, dz)])
      w.cogs[0].aim = point(w.cogs[0].pos.x.int + dx*2, w.cogs[0].pos.z.int + dz*2)  # face it
      let bodies = w.observedBodies(0)
      require identityOf(bodies, 1) >= 0
      for index in 17'i32..24'i32:
        var a = [0'i32, index, 1, 0, 0]
        checkpoint $k & " " & $index
        check w.aimSnapActions(0, a, bodies, snap) == (index == 17 + k)
  test "nearest in angle wins, then the nearer body, then the lower identity":
    var w = newWorld(2026, 2400)
    let (ax, az) = offsetAt(18.0, 1200)
    let (bx, bz) = offsetAt(6.0, 3000)
    discard w.place(0, [(1, ax, az), (3, bx, bz)])
    var bodies = w.observedBodies(0)
    var a = [0'i32, 17, 1, 0, 0]
    check w.aimSnapActions(0, a, bodies, snap)
    check a[1] == int32(identityOf(bodies, 3) + 1)   # 6 degrees beats 18, farther or not
    # Same bearing: the nearer body.
    var w2 = newWorld(2026, 2400)
    let (cx, cz) = offsetAt(10.0, 2600)
    discard w2.place(0, [(1, cx, cz), (3, cx div 2, cz div 2)])
    bodies = w2.observedBodies(0)
    var b = [0'i32, 17, 1, 0, 0]
    check w2.aimSnapActions(0, b, bodies, snap)
    check b[1] == int32(identityOf(bodies, 3) + 1)
    # Same bearing and distance (two bodies on one point): the lower identity index.
    var w3 = newWorld(2026, 2400)
    discard w3.place(0, [(5, 2000, 300), (3, 2000, 300)])
    bodies = w3.observedBodies(0)
    let i3 = identityOf(bodies, 3)
    let i5 = identityOf(bodies, 5)
    require i3 >= 0 and i5 >= 0
    var c = [0'i32, 17, 1, 0, 0]
    check w3.aimSnapActions(0, c, bodies, snap)
    check c[1] == int32(min(i3, i5) + 1)
  test "team 1 compass headings are mirrored; teammates, disguised enemies and unseen enemies are never snapped":
    # Seat 1 (team 1): compass 17 points west in world space.
    var w = newWorld(2026, 2400)
    discard w.place(1, [(0, -2000, 200)])
    w.cogs[1].aim = point(w.cogs[1].pos.x.int - 3000, w.cogs[1].pos.z.int)
    var bodies = w.observedBodies(1)
    require identityOf(bodies, 0) >= 0
    var a = [0'i32, 17, 1, 0, 0]
    check w.aimSnapActions(1, a, bodies, snap)
    check a[1] == int32(identityOf(bodies, 0) + 1)
    var east = [0'i32, 21, 1, 0, 0]   # compass 4 = east for team 1
    check not w.aimSnapActions(1, east, bodies, snap)
    # A teammate in the cone: untouched.
    var t = newWorld(2026, 2400)
    discard t.place(0, [(2, 2000, 100)])
    var b = [0'i32, 17, 1, 0, 0]
    check not t.aimSnapActions(0, b, t.observedBodies(0), snap)
    check b[1] == 17
    # An enemy in a uniform reads as a teammate (apparent team): untouched.
    var u = newWorld(2026, 2400)
    discard u.place(0, [(1, 2000, 100)])
    u.uniforms[1] = true
    let ub = u.observedBodies(0)
    var c = [0'i32, 17, 1, 0, 0]
    check not u.aimSnapActions(0, c, ub, snap)
    # Facing north, an enemy just north of east is outside the vision cone: not in the
    # seat's bodies, not snapped, though the geometry would qualify.
    var f = newWorld(2026, 2400)
    let s = f.place(0, [(1, 2000, 100)])
    f.cogs[0].aim = point(s.x.int, s.z.int + 3000)
    require not f.visible(0, 1)
    var d = [0'i32, 17, 1, 0, 0]
    check not f.aimSnapActions(0, d, f.observedBodies(0), snap)
  test "only a live seat's compass shoot orders; disabled is untouched":
    var w = newWorld(2026, 2400)
    discard w.place(0, [(1, 2000, 100)])
    let bodies = w.observedBodies(0)
    for heads in [[0'i32, 17, 0, 0, 0],   # no shoot order
                  [0'i32, 0, 1, 0, 0],    # keep aim
                  [0'i32, 2, 1, 0, 0]]:   # an identity already
      var a = heads
      check not w.aimSnapActions(0, a, bodies, snap)
      check a == heads
    var off = [0'i32, 17, 1, 0, 0]
    check not w.aimSnapActions(0, off, bodies, AimSnapOptions())
    var behind = [0'i32, 21, 1, 0, 0]   # west: the enemy is behind
    check not w.aimSnapActions(0, behind, bodies, aimSnapOptions(90000))
    var wide = [0'i32, 18, 1, 0, 0]    # south-east (+x,+z) is 42 degrees off: only a wide snap takes it
    check not w.aimSnapActions(0, wide, bodies, snap)
    check w.aimSnapActions(0, wide, bodies, aimSnapOptions(45000))
    w.cogs[0].hp = 0
    var dead = [0'i32, 17, 1, 0, 0]
    check not w.aimSnapActions(0, dead, bodies, snap)
  test "the snapped order hits a still target 15 degrees off the compass heading; the compass order misses":
    var w = newWorld(2026, 2400)
    let (dx, dz) = offsetAt(15.0, 1200)
    discard w.place(0, [(1, dx, dz)])
    require w.cogs[0].cooldown == 0 and w.equipment[0].windup == 0 and not w.equipment[0].sprayCan
    var memory: AimMemory
    memory.resetAimMemory()
    let bodies = w.observedBodies(0)
    var compass = [0'i32, 17, 1, 0, 0]
    var snapped = compass
    require w.aimSnapActions(0, snapped, bodies, snap)
    for (name, heads, expectedHp) in [("compass", compass, 3'i32), ("snapped", snapped, 2'i32)]:
      var trial = w
      let command = trial.decodeActions(0, heads, bodies, acV2, memory)
      for tick in 0..GunWindupTicks:
        var commands: array[Seats, Command]
        commands[0] = if tick == 0: command else: Command(aim: command.aim)
        trial.step(commands)
      checkpoint name
      check trial.cogs[1].hp == expectedHp

suite "Decoder steady shot (bundle option, not a contract change)":
  setup:
    visionRulesVersion = 37
  test "the order tick: a shoot order the gun takes stands the seat; every other head stands":
    var w = newWorld(2026, 2400)
    require w.cogs[0].hp > 0 and not w.equipment[0].sprayCan
    w.cogs[0].cooldown = 0
    w.equipment[0].windup = 0
    var a = [7'i32, 17, 1, 1, 1]
    check w.steadyShotActions(0, a, true) == ssOrder
    check a == [SteadyMovement, 17, 1, 1, 1]
    w.cogs[0].cooldown = 1          # the step decrements before it tests: 1 still fires
    var b = [7'i32, 3, 1, 0, 0]
    check w.steadyShotActions(0, b, true) == ssOrder and b[0] == 0
    for (cooldown, shoot) in [(2'i32, 1'i32), (24'i32, 1'i32), (0'i32, 0'i32)]:
      w.cogs[0].cooldown = cooldown
      var c = [7'i32, 3, shoot, 0, 0]
      checkpoint $cooldown & " " & $shoot
      check w.steadyShotActions(0, c, true) == ssNone
      check c == [7'i32, 3, shoot, 0, 0]
    w.cogs[0].cooldown = 0
    var off = [7'i32, 3, 1, 0, 0]
    check w.steadyShotActions(0, off, false) == ssNone and off[0] == 7
    w.equipment[0].sprayCan = true   # the spray can replaces the gun: no windup to steady
    var spray = [7'i32, 3, 1, 0, 0]
    check w.steadyShotActions(0, spray, true) == ssNone and spray[0] == 7
    w.equipment[0].sprayCan = false
    w.cogs[0].hp = 0
    var dead = [7'i32, 3, 1, 0, 0]
    check w.steadyShotActions(0, dead, true) == ssNone and dead[0] == 7
  test "the windup ticks: windup 5..1 stands the seat whatever the shoot head says":
    var w = newWorld(2026, 2400)
    for windup in 1'i32..GunWindupTicks.int32:
      w.equipment[0].windup = windup
      for shoot in 0'i32..1'i32:
        var a = [12'i32, 20, shoot, 0, 0]
        check w.steadyShotActions(0, a, true) == ssWindup
        check a == [SteadyMovement, 20, shoot, 0, 0]
    w.equipment[0].sprayCan = true   # a frozen gun windup under a spray can is not held
    var s = [12'i32, 20, 1, 0, 0]
    check w.steadyShotActions(0, s, true) == ssNone
  test "gunTakesOrder is exactly the engine's windup start, over a whole match of bot play":
    var w = newWorld(77, 1800)
    var predicted, started, lateCooldown = 0
    while w.winner == -1 and w.tick < w.endTick:
      var commands: array[Seats, Command]
      var takes: array[Seats, bool]
      for slot in 0..<Seats:
        var actions: array[ActionSizes.len, int32]
        w.trainingBotActions(slot, 2, actions)
        actions[2] = int32((w.tick + slot) mod 4 != 0)
        commands[slot] = w.decodeActions(slot, actions)
        takes[slot] = commands[slot].shoot and w.gunTakesOrder(slot)
      var cooldowns: array[Seats, int32]
      for slot in 0..<Seats: cooldowns[slot] = w.cogs[slot].cooldown
      w.step(commands)
      for slot in 0..<Seats:
        if w.cogs[slot].hp <= 0: continue   # a death on the step clears the windup
        let begun = w.equipment[slot].windup == GunWindupTicks
        if takes[slot]: inc predicted
        if begun: inc started
        if takes[slot] and cooldowns[slot] == 1: inc lateCooldown
        check takes[slot] == begun
    check predicted > 100 and predicted == started and lateCooldown > 0
  test "a steadied shot: the seat stands from the order until the ray leaves, six decisions, then walks; the v2 lead subtracts nothing":
    var w = newWorld(2026, 2400)
    for slot in 0..<Seats:
      w.cogs[slot].pos = point(200 + slot*80, maxZ() - 60)
      w.cogs[slot].goal = w.cogs[slot].pos
    # Seat 0 in the open with room to walk east; a shoot order every decision.
    var s: Point
    block find:
      for gz in countup(1000, 3000, 100):
        for gx in countup(600, 4000, 100):
          s = point(gx, gz)
          var clear = true
          for pickup in w.pickups:
            if distance2(pickup.pos, s) < 600*600: clear = false
          if clear and w.openGround(s, point(gx + 400, gz)) and w.walkClear(s, point(gx + 400, gz)): break find
    w.cogs[0].pos = s; w.cogs[0].goal = s; w.cogs[0].aim = point(s.x.int + 3000, s.z.int)
    w.cogs[0].cooldown = 0
    w.equipment[0].windup = 0
    w.equipment[0].armor = 0
    var memory: AimMemory
    memory.resetAimMemory()
    var held: seq[SteadyShotHold]
    var positions: seq[Point]
    for tick in 0..8:
      var heads = [int32(43), 17, 1, 0, 0]   # compass east, fire
      held.add w.steadyShotActions(0, heads, true)
      var commands: array[Seats, Command]
      commands[0] = w.decodeActions(0, heads, w.observedBodies(0), acV2, memory)
      positions.add w.cogs[0].pos
      w.step(commands)
    check held == @[ssOrder, ssWindup, ssWindup, ssWindup, ssWindup, ssWindup, ssNone, ssNone, ssNone]
    # Still from the order's pre-step position through the tick the ray leaves; walking after.
    check w.equipment[0].windup == 0
    for k in 0..5: check positions[k] == s
    check positions[6] == s and positions[7] != s
    # Under v2 the order tick's planned own step is zero: an identity order decodes to the
    # body's position plus its lead only.
    var v = newWorld(2026, 2400)
    var heads = [int32(43), 1, 1, 0, 0]
    check v.steadyShotActions(0, heads, true) == ssOrder
    check v.plannedStep(0, v.cogs[0].pos, false) == Point()

proc placeOpen(w: var World, seat: int, offsets: openArray[(int, int, int)], facing = (1, 0)): Point =
  ## `seat` in the open facing `facing`, with each (body, dx, dz) at its offset, every line
  ## clear and every placed body visible to the seat, no pickup near; everyone else far
  ## away along the edge, still and unshielded; nobody carrying or disguised. Returns the
  ## seat's position.
  for slot in 0..<Seats:
    w.cogs[slot].pos = point(200 + slot*80, maxZ() - 60)
    w.cogs[slot].carrying = false
    w.uniforms[slot] = false
  for gz in countup(900, 3100, 100):
    for gx in countup(200, 6000, 100):
      let s = point(gx, gz)
      if w.blocked(s) or w.trenchAt(s) >= 0 or inWater(s) or inWater(point(gx - 300, gz)): continue
      var ok = true
      for pickup in w.pickups:
        if distance2(pickup.pos, s) < 300*300: ok = false
      for (body, dx, dz) in offsets:
        let p = point(gx + dx, gz + dz)
        if p.x < minX()+100 or p.x > maxX()-100 or p.z < minZ()+100 or p.z > maxZ()-100 or
            w.blocked(p) or w.trenchAt(p) >= 0 or not w.lineClear(s, p):
          ok = false
          break
      if not ok: continue
      w.cogs[seat].pos = s
      w.cogs[seat].aim = point(gx + 3000*facing[0], gz + 3000*facing[1])
      for (body, dx, dz) in offsets: w.cogs[body].pos = point(gx + dx, gz + dz)
      for (body, dx, dz) in offsets:
        if not w.visible(seat, body): ok = false
      if not ok: continue
      for slot in 0..<Seats:
        w.cogs[slot].goal = w.cogs[slot].pos
        w.cogs[slot].shield = 0
        w.equipment[slot].armor = 0
      return s
  raise newException(AssertionDefect, "no open placement")

proc diag3Retarget(w: World, slot: int, actions: array[ActionSizes.len, int32], bodies: array[Seats, int],
    version: ActionContractVersion, memory: AimMemory, maxRange, hpWeight, carryWeight: float64): int =
  ## pw-diag3's --retarget transliterated (diag3_run.py retarget_aim, mode base): it reads the
  ## seat's encoded observation identity block (float thresholds, hp = round(hp/3 * 3)) and
  ## pw_action_candidates' aim points (goal 0 = own position), float64 costs, strict
  ## minimum in identity order. Returns the aim index 1..16 or 0 for none.
  var obs: array[ObservationSize, float32]
  w.encodeObservation(slot, obs, bodies)
  let me = w.cogs[slot]
  let (found, goal) = w.goalCandidate(slot, actions[0].int)
  let ownStep = if version == acV2: w.plannedStep(slot, if found: goal else: me.pos, actions[4] != 0) else: Point()
  var bestCost = 0.0
  for k in 1..16:
    let (aimFound, aim) = w.aimCandidate(slot, k, bodies, version, memory, ownStep)
    if not aimFound: continue
    let row = 24 + 80 + 8*(k-1)
    if obs[row] < 0.5 or obs[row+3] > -0.5: continue
    let hp = round(float64(obs[row+4]) * 3)
    let d2 = (float64(aim.x) - float64(me.pos.x))^2 + (float64(aim.z) - float64(me.pos.z))^2
    if d2 > maxRange*maxRange: continue
    let cost = d2 - (3 - hp) * hpWeight - (if obs[row+5] > 0.5: carryWeight else: 0.0)
    if result == 0 or cost < bestCost:
      result = k
      bestCost = cost

proc diag3GateDrops(w: World, slot: int, actions: array[ActionSizes.len, int32], bodies: array[Seats, int],
    version: ActionContractVersion, memory: AimMemory, maxRange: float64): bool =
  ## pw-diag3's --shot-gate transliterated (diag3_run.py gate_drop), on the heads before
  ## the snap, reading the world as its diag state did: the seat's visible mask, true
  ## teams, hp > 0 and the float 22.5-degree cone (30274 / 32768), best by cosine.
  let me = w.cogs[slot]
  let k = actions[1].int
  if k in 1..16:
    let (found, goal) = w.goalCandidate(slot, actions[0].int)
    let ownStep = if version == acV2: w.plannedStep(slot, if found: goal else: me.pos, actions[4] != 0) else: Point()
    let (aimFound, aim) = w.aimCandidate(slot, k, bodies, version, memory, ownStep)
    return aimFound and hypot(float64(aim.x - me.pos.x), float64(aim.z - me.pos.z)) > maxRange
  if k < 17: return false
  let flip = if team(slot) == 0: 1.0 else: -1.0
  let delta = [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)][k - 17]
  let n = hypot(float64(delta[0]), float64(delta[1]))
  let hx = float64(delta[0]) * flip / n
  let hz = float64(delta[1]) * flip / n
  var bestCos = -2.0
  var bestD = -1.0
  for j in 0..<Seats:
    if j == slot or not w.visible(slot, j) or team(j) == team(slot) or w.cogs[j].hp <= 0: continue
    let vx = float64(w.cogs[j].pos.x - me.pos.x)
    let vz = float64(w.cogs[j].pos.z - me.pos.z)
    let d = hypot(vx, vz)
    if d == 0: continue
    let c = (vx*hx + vz*hz) / d
    if c >= 30274.0 / 32768.0 and c > bestCos:
      bestCos = c
      bestD = d
  bestD < 0 or bestD > maxRange

suite "Decoder aim retarget (bundle option, not a contract change)":
  setup:
    visionRulesVersion = 37
  let retarget = aimRetargetOptions()
  var memory: AimMemory
  memory.resetAimMemory()
  test "options: base.bas's defaults, validated ranges":
    check retarget.enabled and retarget.maxRange == 5250 and retarget.hpWeight == 160000 and
      retarget.carryWeight == 2500000
    check aimRetargetOptionsError(1, 0, 0) == "" and aimRetargetOptionsError(20000, 1_000_000_000, 1_000_000_000) == ""
    for (r, h, c) in [(0'i32, 0'i32, 0'i32), (-1'i32, 0'i32, 0'i32), (20001'i32, 0'i32, 0'i32),
                      (5250'i32, -1'i32, 0'i32), (5250'i32, 1_000_000_001'i32, 0'i32),
                      (5250'i32, 0'i32, -1'i32), (5250'i32, 0'i32, 1_000_000_001'i32)]:
      check aimRetargetOptionsError(r, h, c) != ""
      expect ValueError: discard aimRetargetOptions(r, h, c)
    check not AimRetargetOptions().enabled
  test "the enemy with the smallest d^2 - (3 - hp) * 160000 - carrying * 2500000 within range wins":
    for version in [acV1, acV2]:
      # Nearest: seat 3 (d^2 2252500) beats seat 1 (2560000) and seat 5 (5780000).
      var w = newWorld(2026, 2400)
      discard w.placeOpen(0, [(1, 1600, 0), (3, 1300, 750), (5, 2300, -700)])
      var bodies = w.observedBodies(0)
      var a = [0'i32, 17, 1, 0, 0]
      check w.aimRetargetActions(0, a, bodies, version, memory, retarget)
      check a == [0'i32, int32(identityOf(bodies, 3) + 1), 1, 0, 0]
      # Seat 1 at hp 1: 2560000 - 2*160000 = 2240000 < 2252500.
      w.cogs[1].hp = 1
      a = [0'i32, 17, 1, 0, 0]
      check w.aimRetargetActions(0, a, bodies, version, memory, retarget)
      check a[1] == int32(identityOf(bodies, 1) + 1)
      # Seat 5 carrying a heart: 5780000 - 2500000 = 3280000 loses; at d^2 3250000: 750000 wins.
      w.cogs[5].carrying = true
      a = [0'i32, 17, 1, 0, 0]
      check w.aimRetargetActions(0, a, bodies, version, memory, retarget)
      check a[1] == int32(identityOf(bodies, 1) + 1)
      var w2 = newWorld(2026, 2400)
      discard w2.placeOpen(0, [(1, 1600, 0), (3, 1300, 750), (5, 1700, -600)])
      w2.cogs[5].carrying = true
      bodies = w2.observedBodies(0)
      a = [0'i32, 2, 1, 0, 0]
      check w2.aimRetargetActions(0, a, bodies, version, memory, retarget)
      check a[1] == int32(identityOf(bodies, 5) + 1)
      # Weights are parameters: with no carrier weight the nearest wins again.
      a = [0'i32, 2, 1, 0, 0]
      check w2.aimRetargetActions(0, a, bodies, version, memory, aimRetargetOptions(5250, 160000, 0))
      check a[1] == int32(identityOf(bodies, 3) + 1)
  test "range is measured to the aim candidate: 5250 inclusive, and v2's own-step lead moves it":
    var w = newWorld(2026, 2400)
    discard w.placeOpen(0, [(1, 5250, 0)])
    var bodies = w.observedBodies(0)
    var a = [0'i32, 17, 1, 0, 0]
    check w.aimRetargetActions(0, a, bodies, acV2, memory, retarget)
    var w2 = newWorld(2026, 2400)
    discard w2.placeOpen(0, [(1, 5260, 0)])
    bodies = w2.observedBodies(0)
    a = [0'i32, 17, 1, 0, 0]
    check not w2.aimRetargetActions(0, a, bodies, acV2, memory, retarget)
    check a == [0'i32, 17, 1, 0, 0]
    check w2.aimRetargetActions(0, a, bodies, acV2, memory, aimRetargetOptions(5260))
    # Walking west (compass movement 47 for team 0) puts the v2 aim point 5 steps east of
    # the body: an enemy at 5150 is then beyond 5250 and not retargeted; standing, it is.
    var w3 = newWorld(2026, 2400)
    discard w3.placeOpen(0, [(1, 5150, 0)])
    bodies = w3.observedBodies(0)
    let step = w3.plannedStep(0, w3.goalCandidate(0, 47)[1], false)
    require step.x < -20
    var walking = [47'i32, 17, 1, 0, 0]
    check not w3.aimRetargetActions(0, walking, bodies, acV2, memory, retarget)
    check w3.aimRetargetActions(0, walking, bodies, acV1, memory, retarget)   # v1: the body itself
    var standing = [0'i32, 17, 1, 0, 0]
    check w3.aimRetargetActions(0, standing, bodies, acV2, memory, retarget)
  test "identity and compass shoot orders are retargeted; keep aim, no shot, dead or disabled are not":
    var w = newWorld(2026, 2400)
    discard w.placeOpen(0, [(1, 1200, 0), (3, 2500, 300)])
    let bodies = w.observedBodies(0)
    let near = int32(identityOf(bodies, 1) + 1)
    let far = int32(identityOf(bodies, 3) + 1)
    for aim in [far, 20'i32, 24'i32]:
      var a = [3'i32, aim, 1, 1, 1]
      check w.aimRetargetActions(0, a, bodies, acV2, memory, retarget)
      check a == [3'i32, near, 1, 1, 1]
    var already = [3'i32, near, 1, 0, 0]
    check not w.aimRetargetActions(0, already, bodies, acV2, memory, retarget)   # the rule's pick already
    check already == [3'i32, near, 1, 0, 0]
    for heads in [[3'i32, 0, 1, 0, 0], [3'i32, 17, 0, 0, 0], [3'i32, far, 0, 1, 0]]:
      var a = heads
      check not w.aimRetargetActions(0, a, bodies, acV2, memory, retarget)
      check a == heads
    var off = [3'i32, 17, 1, 0, 0]
    check not w.aimRetargetActions(0, off, bodies, acV2, memory, AimRetargetOptions())
    w.cogs[0].hp = 0
    var dead = [3'i32, 17, 1, 0, 0]
    check not w.aimRetargetActions(0, dead, bodies, acV2, memory, retarget)
  test "teammates, disguised enemies and unseen enemies are never picked; ties go to the lower identity":
    var w = newWorld(2026, 2400)
    discard w.placeOpen(0, [(2, 900, 0), (1, 2000, 200)])
    var bodies = w.observedBodies(0)
    var a = [0'i32, 17, 1, 0, 0]
    check w.aimRetargetActions(0, a, bodies, acV2, memory, retarget)
    check a[1] == int32(identityOf(bodies, 1) + 1)   # the nearer teammate is skipped
    w.uniforms[1] = true   # the enemy now reads as a teammate
    bodies = w.observedBodies(0)
    a = [0'i32, 17, 1, 0, 0]
    check not w.aimRetargetActions(0, a, bodies, acV2, memory, retarget)
    var f = newWorld(2026, 2400)
    let s = f.placeOpen(0, [(1, 2000, 100)])
    f.cogs[0].aim = point(s.x.int, s.z.int + 3000)   # facing north: the enemy is outside the cone
    require not f.visible(0, 1)
    a = [0'i32, 17, 1, 0, 0]
    check not f.aimRetargetActions(0, a, f.observedBodies(0), acV2, memory, retarget)
    var t = newWorld(2026, 2400)
    discard t.placeOpen(0, [(5, 2000, 300), (3, 2000, 300)])
    bodies = t.observedBodies(0)
    a = [0'i32, 17, 1, 0, 0]
    check t.aimRetargetActions(0, a, bodies, acV2, memory, retarget)
    check a[1] == int32(min(identityOf(bodies, 3), identityOf(bodies, 5)) + 1)

suite "Decoder shot gate (bundle option, not a contract change)":
  setup:
    visionRulesVersion = 37
  let gate = shotGateOptions()
  let snap = aimSnapOptions(DefaultAimSnapMillideg)
  var memory: AimMemory
  memory.resetAimMemory()
  proc gated(w: World, slot: int, heads: array[ActionSizes.len, int32], bodies: array[Seats, int],
      options: ShotGateOptions, snapOn = true): (bool, array[ActionSizes.len, int32]) =
    ## Snap (when on), then the gate, as the decoders run them.
    var a = heads
    let before = a
    let snapped = snapOn and w.aimSnapActions(slot, a, bodies, snap)
    result[0] = w.shotGateActions(slot, a, before, snapped, bodies, acV2, memory, options)
    result[1] = a
  test "options: 5250 by default, validated range":
    check gate.enabled and gate.maxRange == 5250
    check shotGateOptionsError(1) == "" and shotGateOptionsError(20000) == ""
    for bad in [0'i32, -1, 20001]:
      check shotGateOptionsError(bad) != ""
      expect ValueError: discard shotGateOptions(bad)
  test "a compass order the snap cannot turn into an enemy is dropped; a snapped one within range stands":
    var w = newWorld(2026, 2400)
    discard w.placeOpen(0, [(1, 2000, 200)])
    let bodies = w.observedBodies(0)
    let enemy = int32(identityOf(bodies, 1) + 1)
    check w.gated(0, [3'i32, 17, 1, 1, 0], bodies, gate) == (false, [3'i32, enemy, 1, 1, 0])
    check w.gated(0, [3'i32, 19, 1, 1, 0], bodies, gate) == (true, [3'i32, 19, 0, 1, 0])     # north: nothing there
    check w.gated(0, [3'i32, 17, 1, 1, 0], bodies, gate, snapOn = false) == (true, [3'i32, 17, 0, 1, 0])
  test "a snapped enemy beyond range drops the order, and the aim goes back to the compass":
    var w = newWorld(2026, 2400)
    discard w.placeOpen(0, [(1, 5400, 300)])
    let bodies = w.observedBodies(0)
    require identityOf(bodies, 1) >= 0
    check w.gated(0, [0'i32, 17, 1, 0, 0], bodies, gate) == (true, [0'i32, 17, 0, 0, 0])
    let wide = shotGateOptions(5500)
    check w.gated(0, [0'i32, 17, 1, 0, 0], bodies, wide) == (false, [0'i32, int32(identityOf(bodies, 1) + 1), 1, 0, 0])
  test "identity orders: dropped only when the aim candidate lies beyond range; keep aim and unseen identities pass":
    var w = newWorld(2026, 2400)
    discard w.placeOpen(0, [(1, 5300, 0), (3, 1500, 400), (2, 1000, -300)])
    let bodies = w.observedBodies(0)
    let far = int32(identityOf(bodies, 1) + 1)
    let near = int32(identityOf(bodies, 3) + 1)
    let mate = int32(identityOf(bodies, 2) + 1)
    check w.gated(0, [0'i32, far, 1, 0, 0], bodies, gate) == (true, [0'i32, far, 0, 0, 0])
    check w.gated(0, [0'i32, near, 1, 0, 0], bodies, gate) == (false, [0'i32, near, 1, 0, 0])
    check w.gated(0, [0'i32, mate, 1, 0, 0], bodies, gate) == (false, [0'i32, mate, 1, 0, 0])   # diag3: range only
    check w.gated(0, [0'i32, 0, 1, 0, 0], bodies, gate) == (false, [0'i32, 0, 1, 0, 0])
    var unseen = -1
    for identity in 0..<Seats:
      if bodies[identity] < 0: unseen = identity
    require unseen >= 0
    check w.gated(0, [0'i32, int32(unseen + 1), 1, 0, 0], bodies, gate) == (false, [0'i32, int32(unseen + 1), 1, 0, 0])
  test "no shot, a dead seat or the option off: untouched":
    var w = newWorld(2026, 2400)
    discard w.placeOpen(0, [(1, 2000, 200)])
    let bodies = w.observedBodies(0)
    check w.gated(0, [0'i32, 19, 0, 0, 0], bodies, gate) == (false, [0'i32, 19, 0, 0, 0])
    check w.gated(0, [0'i32, 19, 1, 0, 0], bodies, ShotGateOptions()) == (false, [0'i32, 19, 1, 0, 0])
    w.cogs[0].hp = 0
    check w.gated(0, [0'i32, 19, 1, 0, 0], bodies, gate) == (false, [0'i32, 19, 1, 0, 0])

suite "Aim retarget and shot gate equal pw-diag3's counterfactuals over whole matches":
  setup:
    visionRulesVersion = 39
  test "retarget equals diag3_run.py --retarget on every live shoot order; the gate equals --shot-gate wherever no body is disguised":
    var decisions, retargets, gateCompared, gateDrops, disguisedDiffers = 0
    for seed in [11'i32, 12]:
      var w = newWorld(seed, 3000)
      var memories: array[Seats, AimMemory]
      for slot in 0..<Seats: memories[slot].resetAimMemory()
      var rng = initRng(seed, 0x5245544152474554'u64)
      let retarget = aimRetargetOptions()
      let gate = shotGateOptions()
      let snap = aimSnapOptions(DefaultAimSnapMillideg)
      while w.winner == -1 and w.tick < w.endTick:
        var commands: array[Seats, Command]
        for slot in 0..<Seats:
          var heads: array[ActionSizes.len, int32]
          w.trainingBotActions(slot, 2, heads)
          let r = int(rng.next() mod 100)
          heads[0] = if r < 50: heads[0] elif r < 85: int32(43 + int(rng.next() mod 8)) else: 0'i32
          let q = int(rng.next() mod 100)
          heads[1] = if q < 35: heads[1] elif q < 55: int32(1 + int(rng.next() mod 16))
                     elif q < 95: int32(17 + int(rng.next() mod 8)) else: 0'i32
          heads[2] = int32(rng.next() mod 3 != 0)
          heads[4] = int32(rng.next() mod 10 == 0)
          let bodies = w.observedBodies(slot)
          let version = if slot mod 4 < 2: acV2 else: acV1
          if w.cogs[slot].hp > 0 and heads[2] != 0:
            inc decisions
            # Retarget: the engine rule against the transliteration.
            var a = heads
            let reference = w.diag3Retarget(slot, heads, bodies, version, memories[slot], 5250, 160000, 2500000)
            let changed = w.aimRetargetActions(slot, a, bodies, version, memories[slot], retarget)
            if heads[1] == 0:
              check not changed and a == heads
            else:
              check a[1] == (if reference > 0: int32(reference) else: heads[1])
              check changed == (reference > 0 and reference != heads[1])
            if changed: inc retargets
            # Gate, after the retarget and the snap, against diag3's gate on the retargeted heads.
            let before = a
            var snapped = a
            let didSnap = w.aimSnapActions(slot, snapped, bodies, snap)
            let dropped = w.shotGateActions(slot, snapped, before, didSnap, bodies, version, memories[slot], gate)
            let expected = w.diag3GateDrops(slot, before, bodies, version, memories[slot], 5250)
            var disguised = false
            for j in 0..<Seats:
              if w.uniforms[j] and w.visible(slot, j): disguised = true
            if disguised:
              if dropped != expected: inc disguisedDiffers
            else:
              inc gateCompared
              check dropped == expected
              if dropped: check snapped == [before[0], before[1], 0, before[3], before[4]]
            if dropped: inc gateDrops
            heads = if dropped: snapped else: (if didSnap: snapped else: a)
          commands[slot] = w.decodeActions(slot, heads, bodies, version, memories[slot])
          if version == acV2: memories[slot].recordAimMemory(w, slot, bodies)
        w.step(commands)
    checkpoint "decisions " & $decisions & " retargets " & $retargets & " gate compared " & $gateCompared &
      " drops " & $gateDrops & " disguised differ " & $disguisedDiffers
    check decisions > 5000 and retargets > 500 and gateCompared > 5000 and gateDrops > 500

suite "Decoder spray options (bundle options, not a contract change)":
  setup:
    visionRulesVersion = 39
  var memory: AimMemory
  memory.resetAimMemory()
  proc arm(w: var World, slot: int) =
    w.equipment[slot].sprayCan = true
    w.equipment[slot].sprayCooldown = 0
    w.equipment[slot].windup = 0
  test "options: defaults and validated ranges":
    check sprayAimOptions() == SprayAimOptions(enabled: true, maxRange: 850)
    check sprayGateOptions() == SprayGateOptions(enabled: true, maxTeammates: 0, minEnemies: 1)
    for bad in [0'i32, -1, 851]:
      check sprayAimOptionsError(bad) != ""
      expect ValueError: discard sprayAimOptions(bad)
    for (t, e) in [(-1'i32, 1'i32), (8'i32, 1'i32), (0'i32, -1'i32), (0'i32, 9'i32)]:
      check sprayGateOptionsError(t, e) != ""
      expect ValueError: discard sprayGateOptions(t, e)
    check sprayGateOptionsError(7, 8) == "" and sprayGateOptionsError(0, 0) == ""
  test "the would-be cone equals the engine's sprayTouches once the spray is locked, over whole matches":
    var compared, touched = 0
    for seed in [5'i32, 6]:
      var w = newWorld(seed, 1500)
      while w.winner == -1 and w.tick < 1200:
        for slot in 0..<Seats:
          if w.cogs[slot].hp <= 0: continue
          for k in 0..2:
            let me = w.cogs[slot].pos
            let aim = point(me.x.int + [700, -300, 50][k] + slot*13, me.z.int + [100, 600, -800][k] - slot*7)
            var locked = w
            locked.equipment[slot].sprayAim = direction(me, aim, SprayReach)
            for j in 0..<Seats:
              if j == slot or w.cogs[j].hp <= 0: continue
              let a = locked.sprayTouches(slot, j)
              check a == w.sprayConeHolds(me, aim, w.cogs[j].pos)
              inc compared
              if a: inc touched
        var commands: array[Seats, Command]
        for slot in 0..<Seats:
          var heads: array[ActionSizes.len, int32]
          w.trainingBotActions(slot, 2, heads)
          commands[slot] = w.decodeActions(slot, heads)
        w.step(commands)
    checkpoint $compared & " " & $touched
    check compared > 100000 and touched > 500
  test "spray gate: an enemy in the cone and no teammate lets the order through; otherwise it is dropped":
    var w = newWorld(2026, 2400)
    discard w.placeOpen(0, [(1, 500, 0), (2, 300, -400), (3, 1500, 1300)])
    w.arm(0)
    let bodies = w.observedBodies(0)
    let enemy = int32(identityOf(bodies, 1) + 1)
    let far = int32(identityOf(bodies, 3) + 1)
    let gate = sprayGateOptions()
    var a = [0'i32, enemy, 1, 0, 0]
    check not w.sprayGateActions(0, a, bodies, acV2, memory, gate) and a[2] == 1
    var b = [0'i32, far, 1, 0, 0]   # toward an enemy beyond the reach: no enemy in the cone
    check w.sprayGateActions(0, b, bodies, acV2, memory, gate) and b == [0'i32, far, 0, 0, 0]
    check w.sprayCone(0, w.cogs[1].pos, bodies) == (1, 0)
    var e = [0'i32, far, 1, 0, 0]   # min_enemies 0: an empty cone is allowed
    check not w.sprayGateActions(0, e, bodies, acV2, memory, sprayGateOptions(0, 0))
    # A teammate in the cone: dropped by default, allowed with max_teammates 1.
    w.cogs[2].pos = point(w.cogs[1].pos.x.int - 60, w.cogs[1].pos.z.int + 40)
    require w.visible(0, 2)
    let bodies2 = w.observedBodies(0)
    check w.sprayCone(0, w.cogs[1].pos, bodies2) == (1, 1)
    var c = [0'i32, enemy, 1, 0, 0]
    check w.sprayGateActions(0, c, bodies2, acV2, memory, gate) and c[2] == 0
    var d = [0'i32, enemy, 1, 0, 0]
    check not w.sprayGateActions(0, d, bodies2, acV2, memory, sprayGateOptions(1, 1))
  test "spray aim: the enemy whose cone holds the most enemies; ties nearest, then lower hp; else the order stands":
    var w = newWorld(2026, 2400)
    discard w.placeOpen(0, [(1, 300, 300), (3, 600, -100), (5, 660, -60), (7, 3000, 0)])
    w.arm(0)
    let bodies = w.observedBodies(0)
    let opts = sprayAimOptions()
    var a = [0'i32, 17, 1, 0, 0]
    check w.sprayAimActions(0, a, bodies, acV2, memory, opts)
    # 3 and 5 stand together: aiming at either holds both; 3 is nearer.
    check a[1] == int32(identityOf(bodies, 3) + 1)
    check w.sprayCone(0, w.cogs[3].pos, bodies)[0] == 2
    # Equal counts: the nearer; at equal distance the lower hp.
    var t = newWorld(2026, 2400)
    discard t.placeOpen(0, [(1, 400, 200), (3, 400, -200)])
    t.arm(0)
    t.cogs[3].hp = 1
    let tb = t.observedBodies(0)
    var b = [0'i32, 0, 1, 0, 0]
    check t.sprayAimActions(0, b, tb, acV2, memory, opts)
    check b[1] == int32(identityOf(tb, 3) + 1)
    # Range: with max_range 300 nobody qualifies (bodies ~447 away) and the order stands.
    var c = [0'i32, 17, 1, 0, 0]
    check not t.sprayAimActions(0, c, tb, acV2, memory, sprayAimOptions(300)) and c[1] == 17
    # Already aimed at the pick: unchanged, not counted.
    var d = [0'i32, int32(identityOf(tb, 3) + 1), 1, 0, 0]
    check not t.sprayAimActions(0, d, tb, acV2, memory, opts)
  test "both options leave everything alone without a ready spray can, without a shoot order, or disabled":
    var w = newWorld(2026, 2400)
    discard w.placeOpen(0, [(1, 500, 0), (2, 400, 60)])
    let bodies = w.observedBodies(0)
    for (can, cooldown, shoot) in [(false, 0'i32, 1'i32), (true, 3'i32, 1'i32), (true, 0'i32, 0'i32)]:
      w.equipment[0].sprayCan = can
      w.equipment[0].sprayCooldown = cooldown
      var a = [0'i32, 17, shoot, 0, 0]
      check not w.sprayAimActions(0, a, bodies, acV2, memory, sprayAimOptions())
      check not w.sprayGateActions(0, a, bodies, acV2, memory, sprayGateOptions())
      check a == [0'i32, 17, shoot, 0, 0]
    w.arm(0)
    var off = [0'i32, 17, 1, 0, 0]
    check not w.sprayAimActions(0, off, bodies, acV2, memory, SprayAimOptions())
    check not w.sprayGateActions(0, off, bodies, acV2, memory, SprayGateOptions())
    w.cogs[0].hp = 0
    check not w.sprayGateActions(0, off, bodies, acV2, memory, sprayGateOptions())
