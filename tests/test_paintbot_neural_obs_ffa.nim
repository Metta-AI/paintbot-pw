## Observation contract ffa.v1 (FFA-kin): a separate encoder, no map flip, 810 floats.
## The encode is checked column by column on a hand-set world; the v1/v2 contracts are
## unchanged and the ffa hash selects the new encoder.
import std/[unittest, math]
import ../examples/paintbot/[sim, kinship, neural_contract]

proc place(w: var World, slot: int, p: Point) =
  w.cogs[slot].hp = 3
  w.cogs[slot].shield = 0
  w.cogs[slot].pos = p
  w.cogs[slot].goal = p
  w.equipment[slot].lives = 1

proc near(p: Point, dx = 0, dz = 0): Point = point(p.x.int+dx, p.z.int+dz)

proc handSetWorld(k: Kinship): World =
  ## Seats 0, 1 and 2 alive; 0 faces 1 (visible), 2 stands behind 0 (not visible); every other
  ## seat is out of the match.
  gameMode = gmFfaKin
  kinshipOverride = some(k)
  result = newWorld(2026, 0)
  kinshipOverride = none(Kinship)
  for i in 0..<Seats:
    result.cogs[i].hp = 0
    result.equipment[i].lives = 0
  let spot = result.greatHearts[0].pos.near(0, 600)
  result.place(0, spot)
  result.place(1, spot.near(300))
  result.place(2, spot.near(-300))
  result.cogs[0].aim = spot.near(1000)
  result.cogs[0].hp = 2
  result.cogs[0].cooldown = 36
  result.equipment[0].armor = 1
  result.cogs[1].hp = 1
  result.tick = 2400
  result.seatScore[0] = 250 # 25 points
  result.seatScore[1] = 1230
  result.seatScore[5] = 40
  result.controlHearts[3].owner = 1
  result.controlHearts[4].owner = 1
  result.controlHearts[5].owner = 0
  result.heartCaptures[6] = HeartCapture(team: 2, ticks: 36, contested: true)
  result.greatHearts[0].progress = 60
  result.greatHearts[0].present = 3
  result.greatHearts[1].dormantUntil = 2400 + 720

suite "Observation contract ffa.v1":
  setup:
    visionRulesVersion = 40
    gameMode = gmFfaKin
    kinshipOverride = none(Kinship)
  teardown:
    gameMode = gmTeams

  test "sizes, offsets, hash and version selection":
    check ObservationSizeFfaV1 == 810
    check FfaIdentityOffset == 8 and FfaHeartOffset == 680 and FfaGreatOffset == 740 and FfaTerrainOffset == 752
    check observationSize(ocFfaV1) == 810
    check observationContractVersion(ObservationContractFfaV1Hash) == ocFfaV1
    check observationContractHash(ocFfaV1) == ObservationContractFfaV1Hash
    check observationContractId(ocFfaV1) == "paintbot-pw.rules40.obs.ffa.v1.float810"
    # The v1 and v2 contracts are untouched.
    check observationContractVersion(ObservationContractHash) == ocV1
    check observationContractVersion(ObservationContractV2Hash) == ocV2
    check observationSize(ocV1) == 448 and observationSize(ocV2) == 506
    expect ValueError: discard observationContractVersion("0" & ObservationContractFfaV1Hash[1..^1])
    var w = handSetWorld(kinshipFor(klPairs, 7))
    var short = newSeq[float32](809)
    expect ValueError: encodeObservation(w, 0, short, ocFfaV1)
    var right = newSeq[float32](810)
    expect ValueError: encodeObservation(w, Seats, right, ocFfaV1)

  test "hand-set world encodes column by column":
    let k = kinshipFor(klPairs, 7)
    var w = handSetWorld(k)
    var o = newSeq[float32](ObservationSizeFfaV1)
    encodeObservation(w, 0, o, ocFfaV1)
    let spanX = float32(maxX()-minX())
    let spanZ = float32(maxZ()-minZ())
    let me = w.cogs[0].pos
    # Self.
    check o[0] == float32(me.x - Width div 2)/spanX
    check o[1] == float32(me.z - Height div 2)/spanZ
    check o[2] == 2'f32/3 and o[3] == 1'f32/3 and o[4] == 36'f32/72
    check o[5] == 25'f32/1000 and o[6] == 1 and o[7] == float32(FfaMatchTicks-2400)/8640
    proc row(j: int): int = FfaIdentityOffset + j*FfaIdentityRowSize
    # Own identity row: at the origin, visible, alive, r = 1.
    check o[row(0)] == 0 and o[row(0)+1] == 0 and o[row(0)+2] == 1 and o[row(0)+3] == 1
    check o[row(0)+37] == 1
    # Seat 1: visible, relative position and hp, genes, r, score, hearts held.
    check w.visible(0, 1) and not w.visible(0, 2)
    check o[row(1)] == 300'f32/spanX and o[row(1)+1] == 0
    check o[row(1)+2] == 1 and o[row(1)+3] == 1 and o[row(1)+4] == 1'f32/3
    for b in 0..<Loci:
      check o[row(1)+5+b] == (if ((k.genes[1] shr b) and 1) == 1: 1'f32 else: -1'f32)
    check o[row(1)+37] == float32(k.r(0, 1))
    check o[row(1)+38] == 123'f32/1000 and o[row(1)+39] == 2'f32/10
    check o[row(1)+40] == 0 and o[row(1)+41] == 0
    # Seat 2: alive but behind, so position and hp are hidden; public columns remain.
    check o[row(2)] == 0 and o[row(2)+1] == 0 and o[row(2)+2] == 0 and o[row(2)+3] == 1 and o[row(2)+4] == 0
    check o[row(2)+37] == float32(k.r(0, 2))
    # Seat 5: out of the match, not visible; score and genes still public.
    check o[row(5)+2] == 0 and o[row(5)+3] == 0 and o[row(5)+38] == 4'f32/1000
    check o[row(5)+5] == (if (k.genes[5] and 1) == 1: 1'f32 else: -1'f32)
    # Hearts: neutral, owned by kin/others, owned by self, a contested capture.
    proc heart(i: int): int = FfaHeartOffset + i*FfaHeartRowSize
    let h0 = w.controlHearts[0].pos
    check o[heart(0)] == float32(h0.x - Width div 2)/spanX and o[heart(0)+1] == float32(h0.z - Height div 2)/spanZ
    check o[heart(0)+2] == -1 and o[heart(0)+5] == 0
    check o[heart(3)+2] == float32(k.r(0, 1)) and o[heart(3)+5] == 0
    check o[heart(5)+2] == 1 and o[heart(5)+5] == 1
    check o[heart(6)+3] == 36'f32/HeartCaptureTicks and o[heart(6)+4] == 1
    # Great hearts: charging with three present; dormant for 720 more ticks.
    proc great(g: int): int = FfaGreatOffset + g*FfaGreatRowSize
    check o[great(0)+2] == 1 and o[great(0)+3] == 3'f32/16
    check o[great(0)+4] == 60'f32/GreatHeartCaptureTicks and o[great(0)+5] == 0
    check o[great(1)+2] == -1 and o[great(1)+4] == 0 and o[great(1)+5] == 720'f32/1440
    # Terrain block: v2's columns 0..53, then visible others wet/dry and two zeros.
    var t = newSeq[float32](TerrainBlockSize)
    encodeTerrainBlock(w, 0, t, w.observedBodies(0))
    for c in 0..53: check o[FfaTerrainOffset+c] == t[c]
    check o[FfaTerrainOffset+54] + o[FfaTerrainOffset+55] == 1'f32/8
    check o[FfaTerrainOffset+56] == 0 and o[FfaTerrainOffset+57] == 0
    for v in o: check v.classify notin {fcNan, fcInf, fcNegInf}

  test "no map flip: an odd seat sees the same absolute frame":
    let k = kinshipFor(klPairs, 7)
    var w = handSetWorld(k)
    w.cogs[1].aim = w.cogs[0].pos
    var o = newSeq[float32](ObservationSizeFfaV1)
    encodeObservation(w, 1, o, ocFfaV1)
    let spanX = float32(maxX()-minX())
    check o[0] == float32(w.cogs[1].pos.x - Width div 2)/spanX
    check o[FfaIdentityOffset + 0*FfaIdentityRowSize] == -300'f32/spanX # seat 0 is to the west
    # Movement and aim compass heads are unflipped for odd seats in FFA too.
    let (found, goal) = w.goalCandidate(1, 43) # compass (1, 0)
    check found and goal.x > w.cogs[1].pos.x

  test "the kin mask zeroes r-to-me (genes-only ablation)":
    let k = kinshipFor(klClones, 7)
    var w = handSetWorld(k)
    var plain = newSeq[float32](ObservationSizeFfaV1)
    var masked = newSeq[float32](ObservationSizeFfaV1)
    encodeFfaObservation(w, 0, plain, w.observedBodies(0), k, 0)
    encodeFfaObservation(w, 0, masked, w.observedBodies(0), k, FfaObsMaskKin)
    var differing = 0
    for c in 0..<ObservationSizeFfaV1:
      if plain[c] != masked[c]: inc differing
    check plain[FfaIdentityOffset + FfaIdentityRowSize + 37] == 1 # clones: r = 1
    for j in 0..<Seats: check masked[FfaIdentityOffset + j*FfaIdentityRowSize + 37] == 0
    # A kin-owned heart reads as "someone else's" (0); neutral and own stay -1 and 1.
    check masked[FfaHeartOffset + 3*FfaHeartRowSize + 2] == 0
    check masked[FfaHeartOffset + 0*FfaHeartRowSize + 2] == -1
    check masked[FfaHeartOffset + 5*FfaHeartRowSize + 2] == 1
    # Genes are kept; only the r columns and kin-owned heart columns changed.
    check masked[FfaIdentityOffset + FfaIdentityRowSize + 5] == plain[FfaIdentityOffset + FfaIdentityRowSize + 5]
    check differing == Seats + 2 # 16 r columns + hearts 3 and 4 (owned by seat 1)

  test "the teams game never reads kin: kin and seat-ownership columns are zero":
    gameMode = gmTeams
    var w = newWorld(2026, 0)
    var o = newSeq[float32](ObservationSizeFfaV1)
    encodeObservation(w, 0, o, ocFfaV1)
    for j in 0..<Seats:
      for c in 5..39: check o[FfaIdentityOffset + j*FfaIdentityRowSize + c] == 0
    for i in 0..<10:
      check o[FfaHeartOffset + i*FfaHeartRowSize + 2] in [-1'f32, 0'f32]
      check o[FfaHeartOffset + i*FfaHeartRowSize + 5] == 0
    for c in FfaGreatOffset..<FfaTerrainOffset: check o[c] == 0
