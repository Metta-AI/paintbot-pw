## Native training ABI for FFA-kin: observation contract ffa.v1 selection (version 101).
import std/unittest
import ../examples/paintbot/[sim, kinship, neural_contract, native_env, topography]

proc fp(buffer: var openArray[float32]): ptr UncheckedArray[cfloat] =
  cast[ptr UncheckedArray[cfloat]](addr buffer[0])

suite "Native ffa.v1 observation selection":
  test "version 101 creates 810-float rows equal to the reference encoder; 3 stays unknown":
    check pw_observation_size_for(101) == 810
    check pw_observation_size_for(3) == -1 and pw_create_observation(1, 24, 3) == nil
    var text: array[65, char]
    let buffer = cast[ptr UncheckedArray[char]](addr text[0])
    check pw_observation_contract_hash(101, buffer, 65) == 0
    check $cast[cstring](addr text[0]) == ObservationContractFfaV1Hash
    let h = pw_create_observation(9, 48, 101)
    require h != nil
    check pw_observation_contract(h) == 101 and pw_handle_observation_size(h) == 810
    check pw_reset(h, 10, 48) == 0
    check pw_observation_contract(h) == 101
    var obs = newSeq[float32](Seats*ObservationSizeFfaV1)
    var resets: array[Seats, float32]
    check pw_observe(h, fp(obs), fp(resets)) == 0
    configureRules(NativeRules)
    let reference = newWorld(10, 48)
    var expected = newSeq[float32](ObservationSizeFfaV1)
    for slot in 0..<Seats:
      encodeObservation(reference, slot, expected, ocFfaV1)
      check obs[slot*ObservationSizeFfaV1 ..< (slot+1)*ObservationSizeFfaV1] == expected
    pw_destroy(h)

# ---------------------------------------------------------------------------------------
# Task C2: game mode, kin reads, dense kin reward, pair counters and eval overrides.
import std/[importutils, math]
privateAccess(NativeEnv)

proc ip(buffer: var openArray[int32]): ptr UncheckedArray[int32] =
  cast[ptr UncheckedArray[int32]](addr buffer[0])
proc envOf(h: pointer): ptr NativeEnv = cast[ptr NativeEnv](h)
proc near(p: Point, dx = 0, dz = 0): Point = point(p.x.int+dx, p.z.int+dz)

proc ffaHandle(seed: int32, ticks = 0'i32, layout = -1'i32): pointer =
  result = pw_create(seed, 24)
  doAssert result != nil
  doAssert pw_set_game_mode(result, 1) == 0
  doAssert pw_set_kin_layout(result, layout) == 0
  doAssert pw_reset(result, seed, ticks) == 0

proc heartActions(h: pointer, tick: int): array[Seats*ActionSizes.len, int32] =
  ## Walk to a heart per seat (changing every 20 s) and fire at a compass heading.
  for slot in 0..<Seats:
    let o = slot*ActionSizes.len
    result[o] = int32(1 + (slot + tick div 480) mod 10)
    result[o+1] = int32(17 + (slot + tick div 96) mod 8)
    result[o+2] = int32((tick + slot) mod 3 == 0)

proc stats(h: pointer): seq[int32] =
  result = newSeq[int32](Seats*Seats*PairStatCount)
  doAssert pw_pair_stats(h, ip(result)) == 0
proc stat(s: seq[int32], i, j: int, p: PairStat): int32 = s[(i*Seats+j)*PairStatCount+p.ord]

proc isolate(h: pointer, placed: openArray[(int, Point)]) =
  ## Every seat out of the match except the placed ones, standing still with full hp.
  let env = envOf(h)
  for i in 0..<Seats:
    env.world.cogs[i].hp = 0
    env.world.equipment[i].lives = 0
  for (slot, p) in placed:
    env.world.cogs[slot].hp = 3
    env.world.cogs[slot].shield = 0
    env.world.cogs[slot].respawn = 0
    env.world.cogs[slot].pos = p
    env.world.cogs[slot].goal = p
    env.world.cogs[slot].aim = Point()
    env.world.equipment[slot].lives = 1
  for s in 0..<Seats: env.bodiesReady[s] = false

proc command(h: pointer, slot: int, shoot: bool, aim: Point) =
  var nine = [0'i32, 0, 0, shoot.int32, aim.x, aim.z, 0, 0, 0]
  let p = envOf(h).world.cogs[slot].pos
  nine[1] = p.x; nine[2] = p.z
  doAssert pw_set_seat_command(h, slot.cint, ip(nine)) == 0

proc idleStep(h: pointer): array[Seats, float32] =
  var actions: array[Seats*ActionSizes.len, int32]
  var terminals: array[Seats, float32]
  doAssert pw_step(h, ip(actions), fp(result), fp(terminals)) == 0

proc lane(h: pointer, length: int): Point =
  ## A dry, flat, unobstructed east-west stretch of `length` units, away from every heart.
  let w = envOf(h).world
  var z = minZ() + 800
  while z < maxZ() - 800:
    var x = minX() + 800
    while x < maxX() - 800 - length:
      let a = point(x, z)
      let b = point(x + length, z)
      var ok = w.lineClear(a, b) and w.lineClear(b, a) and
        abs(terrainHeight(a.x.int, a.z.int) - terrainHeight(b.x.int, b.z.int)) < 20
      var k = 0
      while ok and k <= length:
        let q = point(x + k, z)
        if w.blocked(q) or riverBlend(q.x.int, q.z.int) > 0: ok = false
        for heart in w.controlHearts:
          if distance2(q, heart.pos) < 600*600: ok = false
        for heart in w.greatHearts:
          if distance2(q, heart.pos) < 600*600: ok = false
        k += 50
      if ok: return a
      x += 200
    z += 200
  doAssert false, "no open lane"

proc open(h: pointer, dz = 0): Point =
  let g = envOf(h).world.greatHearts[1].pos
  point(g.x.int, g.z.int + 700 + dz)

suite "Native FFA-kin ABI":
  test "the mode and kin layout apply at the next reset and are kept across resets":
    let h = pw_create(3, 240)
    check pw_game_mode(h) == 0 and pw_set_game_mode(h, 1) == 0 and pw_game_mode(h) == 0
    check pw_set_game_mode(h, 2) == -1 and pw_set_kin_layout(h, 6) == -1 and pw_set_kin_layout(h, -2) == -1
    check pw_set_kin_layout(h, 5) == 0 # clones
    check pw_reset(h, 3, 0) == 0
    check pw_game_mode(h) == 1 and envOf(h).world.endTick == FfaMatchTicks
    var r = newSeq[float32](Seats*Seats)
    check pw_kin(h, fp(r)) == 0
    for v in r: check v == 1
    check pw_reset(h, 4, 0) == 0 # kept
    check pw_game_mode(h) == 1
    check pw_set_kin_layout(h, 1) == 0 and pw_reset(h, 4, 0) == 0
    check pw_kin(h, fp(r)) == 0
    let pairs = kinshipFor(klPairs, 4)
    for i in 0..<Seats:
      for j in 0..<Seats: check r[i*Seats+j] == float32(pairs.r(i, j))
    var genes: array[Seats, uint32]
    check pw_genes(h, cast[ptr UncheckedArray[uint32]](addr genes[0])) == 0
    check genes == pairs.genes
    check pw_set_game_mode(h, 0) == 0 and pw_reset(h, 4, 0) == 0
    check pw_game_mode(h) == 0 and pw_kin(h, fp(r)) == 0
    for v in r: check v == 0
    pw_destroy(h)

  test "summed rewards equal terminal R_i/4320 and each step's split sums to delta R":
    for (seed, layout) in [(11'i32, -1'i32), (12'i32, 5'i32), (13'i32, 1'i32)]:
      let h = ffaHandle(seed, 2400, layout)
      var total: array[Seats, float64]
      var afterDeath: array[Seats, float64]
      var before, after: array[Seats, float32]
      var split: array[2*Seats, float32]
      var rewards, terminals: array[Seats, float32]
      var worst = 0.0
      var tick = 0
      check pw_scores(h, fp(before)) == 0
      while true:
        var actions = heartActions(h, tick)
        let code = pw_step(h, ip(actions), fp(rewards), fp(terminals))
        if code == -2: break
        require code == 0
        check pw_scores(h, fp(after)) == 0
        check pw_reward_split(h, fp(split)) == 0
        var seatNow = newSeq[float32](Seats*3)
        check pw_kin_seat_stats(h, fp(seatNow)) == 0
        for i in 0..<Seats:
          total[i] += rewards[i].float64
          if seatNow[3*i] >= 0 and seatNow[3*i] < float32(envOf(h).world.tick - 1):
            afterDeath[i] += rewards[i].float64
          check abs(split[2*i].float64 + split[2*i+1].float64 - rewards[i].float64) < 1e-9
          worst = max(worst, abs((after[i] - before[i]).float64/4320 - rewards[i].float64))
        before = after
        inc tick
        if terminals[0] == 1: break
      check worst < 1e-6
      var final: array[Seats, float32]
      check pw_scores(h, fp(final)) == 0
      var earned = 0
      for i in 0..<Seats:
        check abs(total[i] - final[i].float64/4320) < 1e-5
        if total[i] > 0: inc earned
      check earned > 0 # the match paid somebody (the check above is not vacuous)
      var seat = newSeq[float32](Seats*3)
      check pw_kin_seat_stats(h, fp(seat)) == 0
      for i in 0..<Seats:
        check abs(seat[3*i+1].float64 + seat[3*i+2].float64 - total[i]) < 1e-5
      if layout == 5:
        # Clones: every score pays everyone, so the dead keep earning.
        var dead = 0
        for i in 0..<Seats:
          if seat[3*i] >= 0:
            inc dead
            check afterDeath[i] > 0
        check dead > 0
      pw_destroy(h)

  test "a shooting pair: damage, kill, visibility, range and nearness":
    let h = ffaHandle(21, 0, 3)
    let p = lane(h, 300)
    h.isolate([(0, p), (1, p.near(300)), (2, open(h, 1400))])
    var ticks = 0
    while envOf(h).world.cogs[1].hp > 0 and ticks < 400:
      h.command(0, true, envOf(h).world.cogs[1].pos)
      discard h.idleStep()
      inc ticks
    let s = h.stats()
    check envOf(h).world.cogs[1].hp == 0
    check s.stat(0, 1, psDamage) == 3 and s.stat(0, 1, psKills) == 1
    check s.stat(1, 0, psDamage) == 0 and s.stat(1, 0, psKills) == 0 # negative control
    check s.stat(0, 1, psVisible) > 0 and s.stat(0, 1, psInRange) == s.stat(0, 1, psVisible)
    check s.stat(0, 1, psNear) > 0 and s.stat(1, 0, psNear) == s.stat(0, 1, psNear)
    check s.stat(0, 2, psNear) == 0 and s.stat(0, 2, psDamage) == 0
    var seat = newSeq[float32](Seats*3)
    check pw_kin_seat_stats(h, fp(seat)) == 0
    check seat[3*1] >= 0 and seat[3*0] == -1
    pw_destroy(h)

  test "a defence: hurting the attacker of a third seat, and the chance to":
    let h = ffaHandle(22, 0, 1)
    let p = lane(h, 600)
    # 2 <- 1 <- 0 along x: 1 shoots 2, then 0 shoots 1.
    h.isolate([(2, p), (1, p.near(300)), (0, p.near(600)), (3, open(h, 1400))])
    envOf(h).world.cogs[0].aim = p
    var ticks = 0
    while h.stats().stat(1, 2, psDamage) == 0 and ticks < 200:
      h.command(1, true, envOf(h).world.cogs[2].pos)
      discard h.idleStep()
      inc ticks
    require h.stats().stat(1, 2, psDamage) > 0
    check h.stats().stat(0, 2, psDefendOpp) > 0 # 0 could see 1, who had just hit 2
    check h.stats().stat(0, 2, psDefend) == 0
    ticks = 0
    while h.stats().stat(0, 1, psDamage) == 0 and ticks < 60:
      h.command(0, true, envOf(h).world.cogs[1].pos)
      discard h.idleStep()
      inc ticks
    let s = h.stats()
    check s.stat(0, 1, psDamage) > 0
    check s.stat(0, 2, psDefend) == s.stat(0, 1, psDamage) # every hit on 1 defended 2
    check s.stat(0, 2, psCostlyDefend) == 0 # 0 was at full health
    for j in 0..<Seats:
      check s.stat(1, j, psDefend) == 0 # 2 had hurt nobody
      check s.stat(0, j, psDeathAfterDefend) == 0
    check s.stat(3, 2, psDefendOpp) == 0 # 3 stands far off
    pw_destroy(h)

  test "a contest and a yield opportunity at a heart, then a heart pass":
    let h = ffaHandle(23, 0, 1)
    let heart = envOf(h).world.controlHearts[4].pos
    h.isolate([(3, heart), (4, heart.near(300)), (5, open(h, 1400))])
    for tick in 0..<10: discard h.idleStep()
    var s = h.stats()
    check envOf(h).world.heartCaptures[4].team == 3
    check s.stat(4, 3, psYieldOpp) == 10 and s.stat(4, 3, psContest) == 0
    check s.stat(5, 3, psYieldOpp) == 0 and s.stat(3, 4, psYieldOpp) == 0
    envOf(h).world.cogs[4].pos = heart.near(60)
    envOf(h).world.cogs[4].goal = heart.near(60)
    for tick in 0..<5: discard h.idleStep()
    s = h.stats()
    check envOf(h).world.heartCaptures[4].contested
    check s.stat(4, 3, psContest) == 5 and s.stat(4, 3, psYieldOpp) == 10 # contested: no yield
    check s.stat(3, 4, psContest) == 0 # 4 is not the capturer
    # 4 leaves; 3 finishes the capture and owns the heart; 3 leaves and 4 takes it over.
    envOf(h).world.cogs[4].pos = heart.near(1200)
    envOf(h).world.cogs[4].goal = heart.near(1200)
    for tick in 0..<HeartCaptureTicks: discard h.idleStep()
    require envOf(h).world.controlHearts[4].owner == 3
    envOf(h).world.cogs[3].pos = heart.near(-1200)
    envOf(h).world.cogs[3].goal = heart.near(-1200)
    envOf(h).world.cogs[4].pos = heart
    envOf(h).world.cogs[4].goal = heart
    for tick in 0..<HeartCaptureTicks+1: discard h.idleStep()
    s = h.stats()
    check envOf(h).world.controlHearts[4].owner == 4
    check s.stat(4, 3, psHeartPass) == 1 and s.stat(3, 4, psHeartPass) == 0
    pw_destroy(h)

  test "a great-heart co-capture counts the three who shared it, nobody else":
    let h = ffaHandle(24, 0, 1)
    let spot = envOf(h).world.greatHearts[0].pos
    h.isolate([(5, spot), (6, spot.near(100)), (7, spot.near(-100)), (8, spot.near(900))])
    var rewards: array[Seats, float32]
    for tick in 0..<GreatHeartCaptureTicks: rewards = h.idleStep()
    let s = h.stats()
    check envOf(h).world.greatShare[5] == 200
    for (i, j) in [(5, 6), (6, 5), (5, 7), (7, 6)]: check s.stat(i, j, psCoCapture) == 1
    check s.stat(5, 8, psCoCapture) == 0 and s.stat(8, 5, psCoCapture) == 0
    check s.stat(5, 5, psCoCapture) == 0
    # The capture tick's reward: 20 points each to 5, 6 and 7, kin-weighted.
    let k = envOf(h).kinship
    for i in 0..<Seats:
      var expected = 0.0
      for j in 5..7: expected += k.r(i, j) * 20.0
      check abs(rewards[i].float64 - expected/4320) < 1e-7
    pw_destroy(h)

  test "overrides apply at reset; in the teams game nothing changes, hash for hash":
    let plain = pw_create(31, 480)
    let knobs = pw_create(31, 480)
    var family: array[Seats, int8]
    var genes: array[Seats, uint32]
    var ibd: array[Seats*Seats, int8]
    for i in 0..<Seats:
      family[i] = int8(i div 8)
      genes[i] = uint32(i * 7919)
      for j in 0..<Seats: ibd[i*Seats+j] = (if i == j: 32'i8 elif i div 8 == j div 8: 16'i8 else: 0'i8)
    var grouping: array[Seats, int8]
    for i in 0..<Seats: grouping[i] = int8(i mod 4)
    let fam = cast[ptr UncheckedArray[int8]](addr family[0])
    let gen = cast[ptr UncheckedArray[uint32]](addr genes[0])
    let ib = cast[ptr UncheckedArray[int8]](addr ibd[0])
    check pw_set_kin_override(knobs, fam, gen, ib) == 0
    check pw_set_spawn_grouping(knobs, cast[ptr UncheckedArray[int8]](addr grouping[0])) == 0
    check pw_set_kin_layout(knobs, 5) == 0
    check pw_set_obs_mask(knobs, 1) == 0 and pw_set_obs_mask(knobs, 2) == -1
    # Invalid kinships are refused.
    ibd[1] = 5 # asymmetric
    check pw_set_kin_override(knobs, fam, gen, ib) == -1
    ibd[1] = 0; ibd[0] = 31 # diagonal must be 32
    check pw_set_kin_override(knobs, fam, gen, ib) == -1
    ibd[0] = 32
    check pw_reset(plain, 32, 480) == 0 and pw_reset(knobs, 32, 480) == 0
    check pw_game_mode(knobs) == 0
    var r1, r2, t1, t2: array[Seats, float32]
    for tick in 0..<480:
      var a1 = heartActions(plain, tick)
      var a2 = a1
      check pw_step(plain, ip(a1), fp(r1), fp(t1)) == 0
      check pw_step(knobs, ip(a2), fp(r2), fp(t2)) == 0
      check pw_state_hash(plain) == pw_state_hash(knobs)
      check r1 == r2 and t1 == t2
    for v in knobs.stats(): check v == 0
    # The same handle in FFA: the override is the kinship from the next reset on.
    check pw_set_game_mode(knobs, 1) == 0
    var r = newSeq[float32](Seats*Seats)
    check pw_kin(knobs, fp(r)) == 0 and r[1] == 0 # still the teams world
    check pw_reset(knobs, 33, 0) == 0
    check pw_kin(knobs, fp(r)) == 0
    check r[0] == 1 and r[1] == 0.5 and r[8] == 0
    var got: array[Seats, uint32]
    check pw_genes(knobs, cast[ptr UncheckedArray[uint32]](addr got[0])) == 0
    check got == genes
    # Spawn anchors follow the grouping (four groups), not the two families.
    for i in 0..<Seats:
      for j in 0..<Seats:
        check (envOf(knobs).world.spawnAnchor[i] == envOf(knobs).world.spawnAnchor[j]) == (i mod 4 == j mod 4)
    pw_destroy(plain); pw_destroy(knobs)

  test "kin invariance through the ABI: one spawn grouping, two kinships, identical hashes":
    proc run(genesSalt: uint32, r: int8): seq[uint32] =
      let h = pw_create(41, 24)
      var family: array[Seats, int8]
      var genes: array[Seats, uint32]
      var ibd: array[Seats*Seats, int8]
      for i in 0..<Seats:
        family[i] = int8(i div 4)
        genes[i] = uint32(i+1) * genesSalt
        for j in 0..<Seats: ibd[i*Seats+j] = (if i == j: 32'i8 elif i div 4 == j div 4: r else: 0'i8)
      var grouping: array[Seats, int8]
      for i in 0..<Seats: grouping[i] = int8(i div 2)
      doAssert pw_set_game_mode(h, 1) == 0
      doAssert pw_set_kin_override(h, cast[ptr UncheckedArray[int8]](addr family[0]),
        cast[ptr UncheckedArray[uint32]](addr genes[0]), cast[ptr UncheckedArray[int8]](addr ibd[0])) == 0
      doAssert pw_set_spawn_grouping(h, cast[ptr UncheckedArray[int8]](addr grouping[0])) == 0
      doAssert pw_reset(h, 41, 600) == 0
      var rewards, terminals: array[Seats, float32]
      for tick in 0..<600:
        var actions = heartActions(h, tick)
        if pw_step(h, ip(actions), fp(rewards), fp(terminals)) != 0: break
        result.add pw_state_hash(h)
      pw_destroy(h)
    let a = run(2654435761'u32, 16)
    let b = run(40503'u32, 8)
    check a.len > 0 and a == b
    # Negative control: without the grouping override the families (i div 4) place spawns.
    let h = pw_create(41, 24)
    doAssert pw_set_game_mode(h, 1) == 0 and pw_set_kin_layout(h, 0) == 0
    doAssert pw_reset(h, 41, 600) == 0
    var rewards, terminals: array[Seats, float32]
    var actions = heartActions(h, 0)
    doAssert pw_step(h, ip(actions), fp(rewards), fp(terminals)) == 0
    check pw_state_hash(h) != a[0]
    pw_destroy(h)

  test "the kin mask zeroes r-to-me in pw_observe rows":
    let h = pw_create_observation(51, 24, 101)
    doAssert pw_set_game_mode(h, 1) == 0 and pw_set_kin_layout(h, 5) == 0 and pw_reset(h, 51, 0) == 0
    var obs = newSeq[float32](Seats*ObservationSizeFfaV1)
    var resets: array[Seats, float32]
    check pw_observe(h, fp(obs), fp(resets)) == 0
    check obs[FfaIdentityOffset + FfaIdentityRowSize + 37] == 1 # clones
    check pw_set_obs_mask(h, 1) == 0
    check pw_observe(h, fp(obs), fp(resets)) == 0
    for slot in 0..<Seats:
      for j in 0..<Seats:
        check obs[slot*ObservationSizeFfaV1 + FfaIdentityOffset + j*FfaIdentityRowSize + 37] == 0
    # The rows otherwise equal the reference encoder on the handle's world and kinship.
    var expected = newSeq[float32](ObservationSizeFfaV1)
    encodeFfaObservation(envOf(h).world, 3, expected, envOf(h).world.observedBodies(3),
      envOf(h).kinship, FfaObsMaskKin)
    check obs[3*ObservationSizeFfaV1 ..< 4*ObservationSizeFfaV1] == expected
    pw_destroy(h)

  test "an FFA handle and a teams handle interleaved on one thread do not disturb each other":
    proc run(handles: openArray[pointer]): seq[seq[uint32]] =
      result = newSeq[seq[uint32]](handles.len)
      var rewards, terminals: array[Seats, float32]
      for tick in 0..<240:
        for k, h in handles:
          var actions = heartActions(h, tick)
          doAssert pw_step(h, ip(actions), fp(rewards), fp(terminals)) == 0
          result[k].add pw_state_hash(h)
      for h in handles: pw_destroy(h)
    proc teams(): pointer = pw_create(61, 240)
    let teamsAlone = run([teams()])[0]
    let ffaAlone = run([ffaHandle(62, 0, 2)])[0]
    # Created in both orders, so whichever handle set the thread's mode last, the other runs.
    let both = run([teams(), ffaHandle(62, 0, 2)])
    check both[0] == teamsAlone and both[1] == ffaAlone
    let swapped = run([ffaHandle(62, 0, 2), teams()])
    check swapped[0] == ffaAlone and swapped[1] == teamsAlone
    check teamsAlone != ffaAlone

suite "Native FFA-kin seat scripts, results and bots":
  const FfaBas = staticRead("../coworld/paintbot/players/ffa.bas")
  proc setScript(h: pointer, seat: int, source: string): cint =
    pw_set_seat_script(h, seat.cint, cast[ptr UncheckedArray[char]](unsafeAddr source[0]), source.len.int32)
  proc status(h: pointer, seat: int): (cint, string) =
    var text: array[512, char]
    let code = pw_seat_script_status(h, seat.cint, cast[ptr UncheckedArray[char]](addr text[0]), 512)
    (code, $cast[cstring](addr text[0]))

  test "ffa.bas on all 16 seats of an FFA handle plays a whole match without script errors":
    let h = ffaHandle(71, 0)
    for seat in 0..<Seats: check h.setScript(seat, FfaBas) == 0
    var actions: array[Seats*ActionSizes.len, int32]
    var rewards, terminals: array[Seats, float32]
    var ticks = 0
    while true:
      let code = pw_step(h, ip(actions), fp(rewards), fp(terminals))
      if code == -2: break
      require code == 0
      inc ticks
      if terminals[0] == 1: break
    check ticks > 0
    for seat in 0..<Seats:
      let (code, message) = h.status(seat)
      check code == 1
      if code != 1: echo "seat ", seat, ": ", message
    var scores: array[Seats, float32]
    check pw_scores(h, fp(scores)) == 0
    var total = 0.0
    for v in scores: total += v
    check total > 0
    var results: array[8, float32]
    check pw_results(h, fp(results)) == 0
    check results[0] == float32(envOf(h).world.tick) and results[1] == -3
    check results[4] == max(scores) and scores[results[5].int] == results[4]
    check results[3] > 0 and results[2] >= 0 and results[2] <= 16
    echo "  ffa.bas match: ", ticks, " ticks, seats standing ", results[2], ", best R ", results[4]
    pw_destroy(h)

  test "an FFA script set before the switching reset compiles at that reset; teams refuses it":
    let h = pw_create(72, 240)
    check h.setScript(0, FfaBas) == 1 # the teams game has no kin(), gene(), ...
    let (code, message) = h.status(0)
    check code == 2 and message.len > 0
    var actions: array[Seats*ActionSizes.len, int32]
    var rewards, terminals: array[Seats, float32]
    check pw_step(h, ip(actions), fp(rewards), fp(terminals)) == 0 # the disabled seat idles
    check pw_set_game_mode(h, 1) == 0 and pw_reset(h, 72, 240) == 0
    check h.status(0)[0] == 1
    for tick in 0..<48: check pw_step(h, ip(actions), fp(rewards), fp(terminals)) == 0
    check h.status(0)[0] == 1
    check pw_set_game_mode(h, 0) == 0 and pw_reset(h, 72, 240) == 0
    check h.status(0)[0] == 2
    pw_destroy(h)

  test "pw_bot_actions is unsupported in FFA; pw_results keeps the teams layout in teams":
    let f = ffaHandle(73, 0)
    var actions: array[Seats*ActionSizes.len, int32]
    check pw_bot_actions(f, 0, 1, ip(actions)) == -1
    var results: array[8, float32]
    check pw_results(f, fp(results)) == 0
    check results[1] == -1 and results[2] == 16 and results[3] == 0 and results[6] == 0
    pw_destroy(f)
    let t = pw_create(73, 240)
    check pw_bot_actions(t, 0, 1, ip(actions)) == 0
    check pw_results(t, fp(results)) == 0
    let w = envOf(t).world
    check results[2] == float32(w.glory[0]) and results[3] == float32(w.glory[1])
    pw_destroy(t)
