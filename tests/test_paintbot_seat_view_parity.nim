## SeatView parity (docs/neural/seat-view.md, item 7): every observation column of the view
## contracts (teams.view.1, ffa.view.1) equals the value derived here, independently, from the
## seat's SeatView procs on the same tick, over simulated play with random disguises, in the
## teams game and in FFA-kin at 16 and 24 seats; the BASIC builtins read those same procs; and
## the fire-hold regression: of two bodies sharing an identity every view proc reports the
## nearer one, and the helper that saw both (holdFire) no longer exists.
import std/[unittest, random, math, os, algorithm]
import polyworld/[cli]
import ../examples/paintbot/[sim, bots, kinship, neural_contract]

const Root = currentSourcePath().parentDir.parentDir

proc flipOf(slot: int): float32 = (if team(slot) == 0 or ffa(): 1'f32 else: -1'f32)
proc rel(value, side: int): float32 = (if value < 0: 0'f32 elif value == side: 1'f32 else: -1'f32)

proc expectTeams(v: SeatView): seq[float32] =
  ## teams.view.1 from its documented table, read off the view.
  result = newSeq[float32](512)
  let side = v.selfTeam.int
  let flip = flipOf(v.slot)
  let spanX = float32(v.mapMaxX - v.mapMinX)
  let spanZ = float32(v.mapMaxY - v.mapMinY)
  let cx = (v.mapMinX + v.mapMaxX) div 2
  let cz = (v.mapMinY + v.mapMaxY) div 2
  let sx = v.selfX
  let sz = v.selfY
  let own = v.terrainHeight(sx.int, sz.int)
  proc dx(x: int32): float32 = float32(x - sx) * flip / spanX
  proc dz(z: int32): float32 = float32(z - sz) * flip / spanZ
  proc dh(x, z: int32): float32 = float32(v.terrainHeight(x.int, z.int) - own) / 800
  let self = [float32(sx - cx) * flip / spanX, float32(sz - cz) * flip / spanZ, float32(v.selfHp) / float32(maxHp()),
    float32(v.armorHp) / 3, float32(v.livesLeft) / 4, float32(v.hasGrenade), float32(v.hasSpray),
    float32(v.grenadeCharge) / 24, float32(v.carrying), float32(v.hasUniform), float32((v.trenchId >= 0).int),
    float32(v.selfId div 2) / 7, float32(v.worldTick) / 14400, float32(v.waterAt(sx.int, sz.int)),
    float32(own) / 800, float32(v.glory(side)) / 1000, float32(v.glory(1-side)) / 1000,
    float32(v.teamLives(side)) / 32, float32(v.teamLives(1-side)) / 32, float32(v.teamCogsOut(side)) / 16,
    float32(v.teamCogsOut(1-side)) / 16, float32(v.awardBehind) / 10, float32(v.awardBehindSeconds) / 60,
    float32(v.awardBehindCogs) / 10, float32(v.awardBehindCogsSeconds) / 60]
  for i, x in self: result[i] = x
  for i in 0..<min(10, v.heartCount.int):
    let o = 25 + 10*i
    let (x, z) = (v.controlX(i), v.controlY(i))
    for k, value in [1'f32, dx(x), dz(z), rel(v.controlOwner(i).int, side), rel(v.controlCaptureTeam(i).int, side),
        float32(v.controlCaptureTicks(i)) / 72, float32(v.controlContested(i)), float32(v.controlPoints(i)) / 5,
        float32(v.waterAt(x.int, z.int)), dh(x, z)]:
      result[o+k] = value
  for j in 0..<16:
    if v.visible(j) == 0: continue
    let o = 125 + 10*j
    let (x, z) = (v.playerX(j), v.playerY(j))
    for k, value in [1'f32, dx(x), dz(z), rel(v.playerTeam(j).int, side), float32(v.playerHp(j)) / float32(maxHp()),
        float32(v.playerCarrying(j)), float32((j == v.selfId.int).int), float32(j div 2) / 7,
        float32(v.waterAt(x.int, z.int)), dh(x, z)]:
      result[o+k] = value
  for i in 0..<32:
    # The contract predates the rules-49 kinds (mister, sniper, radar) and shows none of them.
    if v.pickupVisible(i) == 0 or v.pickupKind(i) > 4: continue
    for k, value in [1'f32, dx(v.pickupX(i)), dz(v.pickupY(i)), float32(v.pickupKind(i)) / 4, float32(i) / 31]:
      result[285 + 5*i + k] = value
  for i in 0..<min(8, v.soundCount.int):
    for k, value in [1'f32, float32(v.soundKind(i)) / 4,
        float32((v.soundDirection(i).int + (if side == 0: 0 else: 4)) mod 8) / 7,
        float32(v.soundDistance(i)) / 4, float32(v.soundAge(i)) / 24]:
      result[445 + 5*i + k] = value
  const compass = [(0, 0), (1,0), (1,1), (0,1), (-1,1), (-1,0), (-1,-1), (0,-1), (1,-1)]
  for k, d in compass:
    let px = sx.int + int(flip) * d[0] * 200
    let pz = sz.int + int(flip) * d[1] * 200
    let inside = px >= v.mapMinX and px <= v.mapMaxX and pz >= v.mapMinY and pz <= v.mapMaxY
    result[485 + 3*k] = float32(inside.int)
    result[485 + 3*k + 1] = float32(v.waterAt(px, pz))
    result[485 + 3*k + 2] = float32(v.terrainHeight(px, pz) - own) / 800

proc expectFfa(v: SeatView): seq[float32] =
  ## ffa.view.1 from its documented table, read off the view.
  let seats = v.seatCount.int
  let hearts = v.heartCount.int
  let cogRows = min(seats - 1, 64)
  result = newSeq[float32](24 + cogRows*44 + hearts*12 + 2*12)
  let hp = float32(maxHp())
  let spanX = float32(v.mapMaxX - v.mapMinX)
  let spanZ = float32(v.mapMaxY - v.mapMinY)
  let cx = (v.mapMinX + v.mapMaxX) div 2
  let cz = (v.mapMinY + v.mapMaxY) div 2
  let diag = sqrt(float64(spanX)*float64(spanX) + float64(spanZ)*float64(spanZ))
  let sx = v.selfX
  let sz = v.selfY
  let own = v.terrainHeight(sx.int, sz.int)
  let me = v.selfId.int
  proc dist(x, z: int32): float32 = float32(sqrt(float64(distance2(Point(x: sx, z: sz), Point(x: x, z: z)))) / diag)
  proc dh(x, z: int32): float32 = float32(v.terrainHeight(x.int, z.int) - own) / 800
  proc kinOf(j: int): float32 = (if v.kin(j) < 0: 0'f32 else: float32(v.kin(j)) / 100)
  var held = newSeq[int](seats)
  for h in 0..<hearts:
    if v.heartOwner(h) in 0'i32..<seats.int32: inc held[v.heartOwner(h)]
  var near = 0
  discard v.nearAgents(20000)  # the seat's own list: the cog rows are exactly it
  near = v.nearAgents(20000).int
  let header = [float32(sx - cx) / spanX, float32(sz - cz) / spanZ, float32(v.selfHp) / hp, float32(v.armorHp) / hp,
    float32(max(0'i32, v.seatScore(me))) / 10000, float32((v.selfHp > 0).int), float32(v.worldTick) / 8640,
    float32(v.livesLeft) / 4, float32(seats) / 64, float32(hearts) / 100, float32(held[me]) / float32(max(1, hearts)),
    float32(v.territoryBoost) / 30, float32(v.waterAt(sx.int, sz.int)), float32(own) / 800,
    float32(min(near, cogRows)) / 64, float32(cogRows) / 64, float32(hearts) / 100, 1'f32, float32(v.hasGrenade),
    float32(v.hasSpray), float32(v.carrying), float32((v.trenchId >= 0).int)]
  for i, x in header: result[i] = x
  for k in 0..<min(near, cogRows):
    let o = 24 + 44*k
    let j = v.nearAgentId(k).int
    let (x, z) = (v.nearAgentX(k), v.nearAgentY(k))
    result[o] = 1
    result[o+1] = float32(x - sx) / spanX
    result[o+2] = float32(z - sz) / spanZ
    result[o+3] = 1
    result[o+4] = float32(v.nearAgentHp(k)) / hp
    for b in 0..<32:
      let g = v.gene(j, b)
      result[o+5+b] = if g < 0: 0'f32 elif g == 1: 1'f32 else: -1'f32
    result[o+37] = kinOf(j)
    result[o+38] = float32(max(0'i32, v.seatScore(j))) / 10000
    result[o+39] = float32(held[j]) / 10
    result[o+40] = dist(x, z)
    result[o+41] = float32(v.waterAt(x.int, z.int))
    result[o+42] = dh(x, z)
    result[o+43] = float32(j) / 255
  # Heart rows nearest first (ties by index), then the great hearts likewise.
  var order: seq[(int64, int)]
  for h in 0..<hearts: order.add (distance2(Point(x: sx, z: sz), Point(x: v.controlX(h), z: v.controlY(h))), h)
  order.sort()
  let heartOffset = 24 + 44*cogRows
  for k, e in order:
    let i = e[1]
    let o = heartOffset + 12*k
    let (x, z) = (v.controlX(i), v.controlY(i))
    let owner = v.heartOwner(i).int
    for c, value in [1'f32, float32(x - sx) / spanX, float32(z - sz) / spanZ, float32(x - cx) / spanX,
        float32(z - cz) / spanZ, (if owner < 0: -1'f32 elif owner == me: 1'f32 else: kinOf(owner)),
        float32(v.controlCaptureTicks(i)) / 72, float32(v.controlContested(i)), float32((owner == me).int),
        dist(x, z), float32(v.waterAt(x.int, z.int)), dh(x, z)]:
      result[o+c] = value
  var greats: seq[(int64, int)]
  for g in 0..<2: greats.add (distance2(Point(x: sx, z: sz), Point(x: v.greatHeartX(g), z: v.greatHeartY(g))), g)
  greats.sort()
  for k, e in greats:
    let g = e[1]
    let o = heartOffset + 12*hearts + 12*k
    let (x, z) = (v.greatHeartX(g), v.greatHeartY(g))
    for c, value in [1'f32, float32(x - sx) / spanX, float32(z - sz) / spanZ, float32(x - cx) / spanX,
        float32(z - cz) / spanZ,
        (if v.greatHeartDormant(g) > 0: -1'f32 elif v.greatHeartProgress(g) > 0: 1'f32 else: 0'f32),
        float32(v.greatHeartPresent(g)) / 16, float32(v.greatHeartProgress(g)) / 120,
        float32(v.greatHeartDormant(g)) / 1440, dist(x, z), float32(v.waterAt(x.int, z.int)), dh(x, z)]:
      result[o+c] = value

proc checkColumns(actual, expected: openArray[float32], what: string): int =
  ## The number of columns that differ (each printed).
  doAssert actual.len == expected.len, what & ": width " & $actual.len & " vs " & $expected.len
  for i in 0..<actual.len:
    if actual[i] != expected[i]:
      inc result
      if result <= 5: echo what, " column ", i, ": encoder ", actual[i], " view ", expected[i]

proc play(w: var World, rng: var Rand, ticks: int, disguise: bool, check: proc(w: World)) =
  var commands = newSeq[Command](Seats)
  for tick in 0..<ticks:
    if tick mod 30 == 0:
      for i in 0..<Seats:
        commands[i] = Command(walk: true, goal: point(rng.rand(minX()+200..maxX()-200), rng.rand(minZ()+200..maxZ()-200)),
          aim: point(rng.rand(minX()..maxX()), rng.rand(minZ()..maxZ())), shoot: rng.rand(3) == 0)
    w.step(commands)
    if disguise and tick mod 45 == 44 and visionRulesVersion >= 27:
      for i in 0..<Seats: w.uniforms[i] = rng.rand(2) == 0
    if tick mod 40 == 39: check(w)

suite "SeatView parity":
  teardown:
    gameMode = gmTeams
    configureSeats(LegacySeats)

  test "teams.view.1: every column equals its SeatView derivation over play with disguises":
    var rng = initRand(11)
    var bad, checked, seen = 0
    for seed in [2026'i32, 7, 99]:
      var w = newWorld(seed)
      w.play(rng, 400, true, proc(w: World) =
        beginViews(w)
        for slot in 0..<Seats:
          let v = seatView(slot)
          var output = newSeq[float32](TeamsViewSize)
          encodeTeamsView(v, output)
          let expected = expectTeams(v)
          bad += checkColumns(output, expected, "seed " & $seed & " seat " & $slot)
          for j in 0..<LegacySeats:
            if j != slot and v.visible(j) == 1: inc seen
          if checked == 0:
            # The comparison is sharp: one column off by one ulp is caught.
            var off = output
            off[200] = cast[float32](cast[uint32](off[200]) + 1)
            check checkColumns(off, expected, "perturbed") == 1
          inc checked)
    check checked > 100
    check seen > 100
    check bad == 0

  for seats in [16, 24]:
    test "ffa.view.1 at " & $seats & " seats: every column equals its SeatView derivation":
      gameMode = gmFfaKin
      configureSeats(seats)
      var rng = initRand(seats)
      var bad, checked = 0
      for seed in [3'i32, 41]:
        var w = newWorld(seed)
        w.play(rng, 400, false, proc(w: World) =
          beginViews(w)
          for slot in 0..<Seats:
            let v = seatView(slot)
            let rows = ffaViewRows(v)
            var output = newSeq[float32](ffaViewLayout(v).size)
            encodeFfaView(v, output, rows)
            bad += checkColumns(output, expectFfa(v), "seed " & $seed & " seat " & $slot)
            # The row map is the seat's nearAgents(20000) list, identity for identity.
            let n = v.nearAgents(20000).int
            check rows.agents.len == min(n, ffaViewLayout(v).cogRows)
            for k, a in rows.agents: check a.identity == v.nearAgentId(k)
            inc checked)
      check checked > 50
      check bad == 0

  test "the BASIC builtins read the same SeatView procs":
    var w = newWorld(5)
    var rng = initRand(5)
    w.play(rng, 200, true, proc(w: World) = discard)
    let path = getTempDir() / "paintbot-seat-view-parity.bas"
    defer: removeFile(path)
    for (a, b) in [("playerX(3)", "playerY(3)"), ("nearAgents(5000)", "nearAgentId(0)"), ("pickupX(0)", "controlOwner(1)"),
                   ("soundCount()", "visible(6)"), ("terrainHeight(selfX, selfY)", "waterAt(selfX, selfY)")]:
      writeFile(path, "walkTo(" & a & ", " & b & ")\n")
      var players = loadBots(@[BotGroup(path: path, count: Seats)])
      let commands = players.decide(w)
      beginViews(w)
      for slot in 0..<Seats:
        if w.cogs[slot].hp <= 0: continue
        let v = seatView(slot)
        let x = case a
          of "playerX(3)": v.playerX(3)
          of "nearAgents(5000)": v.nearAgents(5000)
          of "pickupX(0)": v.pickupX(0)
          of "soundCount()": v.soundCount
          else: v.terrainHeight(v.selfX.int, v.selfY.int)
        let z = case b
          of "playerY(3)": v.playerY(3)
          of "nearAgentId(0)": v.nearAgentId(0)
          of "controlOwner(1)": v.controlOwner(1)
          of "visible(6)": v.visible(6)
          else: v.waterAt(v.selfX.int, v.selfY.int)
        check commands[slot].goal == Point(x: x, z: z)

  test "two bodies sharing an identity: every view proc and the encoder report only the nearer":
    # The retired fire-hold helper (neural_contract.holdFire / teammateInLine) tested every
    # body carrying a teammate's identity, the farther impersonated one included. It is gone,
    # and nothing a seat perceives separates the two bodies.
    check not compiles(holdFire)
    check not compiles(teammateInLine)
    doAssert visionRulesVersion >= 27
    for nearerIsImpostor in [true, false]:
      var w = newWorld(2026)
      for i in 0..<Seats:
        w.cogs[i].pos = point(minX() + 300 + 150*i, minZ() + 300)
        w.cogs[i].aim = point(minX() + 300 + 150*i, minZ() + 300)
      # Seat 0 looks along +x at its teammate 2 and the enemy 3, who wears a uniform and so
      # carries identity 2 (3 xor 1) in seat 0's eyes.
      w.cogs[0].pos = point(2000, 2000)
      w.cogs[0].aim = point(3000, 2000)
      let (impostorX, genuineX) = if nearerIsImpostor: (2400'i32, 2800'i32) else: (2800'i32, 2400'i32)
      w.cogs[3].pos = point(impostorX, 2000)
      w.cogs[2].pos = point(genuineX, 2010)
      w.uniforms[3] = true
      doAssert w.observedSeat(0, 3) == 2 and w.visible(0, 3) and w.visible(0, 2)
      beginViews(w)
      let v = seatView(0)
      let nearer = min(impostorX, genuineX)
      check v.visible(2) == 1
      check v.playerX(2) == nearer
      check v.visible(3) == 0  # identity 3 is carried by nobody seat 0 sees
      var sharing = 0
      let n = v.nearAgents(20000)
      for k in 0..<n:
        if v.nearAgentId(k) == 2:
          inc sharing
          check v.nearAgentX(k) == nearer
      check sharing == 1
      var output = newSeq[float32](TeamsViewSize)
      encodeTeamsView(v, output)
      let o = TeamsIdentityOffset + 2*TeamsIdentityWidth
      check output[o] == 1
      check output[o+1] == float32(nearer - v.selfX) / float32(v.mapMaxX - v.mapMinX)
      # The farther body leaves no trace: the observation is the same with it removed.
      var w2 = w
      if nearerIsImpostor: w2.cogs[2].hp = 0 else: w2.cogs[3].hp = 0
      beginViews(w2)
      var output2 = newSeq[float32](TeamsViewSize)
      encodeTeamsView(seatView(0), output2)
      for j in 0..<LegacySeats:
        if j == 2: continue
        let row = TeamsIdentityOffset + j*TeamsIdentityWidth
        for c in 0..<TeamsIdentityWidth: check output[row+c] == output2[row+c]
      for c in 0..<TeamsIdentityWidth: check output[o+c] == output2[o+c]
