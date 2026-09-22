import std/[unittest, math]
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
          # With nothing remembered v2 resolves every head exactly as v1.
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
    check v1.shoot and v2.shoot and not v1.walk == false
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
    # Last tick: the target moved 20 in x, the seat 10 in z.
    w.tick = 1
    w.cogs[1].pos = point(t.x.int+20, t.z.int)
    w.cogs[0].pos = point(s.x.int, s.z.int+10)
    check w.decodeActions(0, actions, bodies, acV2, memory).aim ==
      point(t.x.int + 20 + 6*20, t.z.int - 5*10)
    # A body that was hidden last tick gets no lead; the seat's own drift still applies.
    var hidden = memory
    hidden.bodies[identity] = -1
    check w.decodeActions(0, actions, bodies, acV2, hidden).aim ==
      point(t.x.int + 20, t.z.int - 50)
    # A displacement beyond one tick's reach is a respawn, not a velocity.
    w.cogs[1].pos = point(t.x.int+TeleportStep+1, t.z.int)
    check w.decodeActions(0, actions, bodies, acV2, memory).aim ==
      point(t.x.int+TeleportStep+1, t.z.int - 50)
    w.cogs[0].pos = point(s.x.int, s.z.int+TeleportStep+1)
    check w.decodeActions(0, actions, bodies, acV2, memory).aim ==
      point(t.x.int+TeleportStep+1, t.z.int)
    # Directional aim, movement and the other heads ignore the version entirely.
    let compass = [45'i32, 19, 1, 1, 1]
    check w.decodeActions(0, compass, bodies, acV1, memory) ==
      w.decodeActions(0, compass, bodies, acV2, memory)
