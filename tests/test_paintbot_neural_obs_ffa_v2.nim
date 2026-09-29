## Observation contract ffa.v2 (FFA-kin at any seat count): a fixed header, then the cogs the
## seat sees (nearest first, the rest of the section zero), every control heart and both
## great hearts (nearest first). The width follows the match; the row -> entity map is
## ffaV2Rows. Checked column by column on a hand-set world, for fog (an unseen cog leaves no
## trace), for row order, and at 16 and 50 seats on the Heartland and Heartland Big configs.
import std/[unittest, math, options]
import ../examples/paintbot/[sim, kinship, neural_contract]

proc place(w: var World, slot: int, p: Point) =
  w.cogs[slot].hp = 10
  w.cogs[slot].shield = 0
  w.cogs[slot].pos = p
  w.cogs[slot].goal = p
  w.equipment[slot].lives = 1

proc near(p: Point, dx = 0, dz = 0): Point = point(p.x.int+dx, p.z.int+dz)

proc handSetWorld(k: Kinship): World =
  ## Seats 0..4 alive; 0 faces +x: 1 at +300 and 3 at (+300, +300) are in view, 4 at +600
  ## as well, 2 stands behind 0 (not visible); every other seat is out of the match.
  gameMode = gmFfaKin
  kinshipOverride = some(k)
  result = newWorld(2026, 0)
  kinshipOverride = none(Kinship)
  for i in 0..<result.cogs.len:
    result.cogs[i].hp = 0
    result.equipment[i].lives = 0
  let spot = result.greatHearts[0].pos.near(0, 600)
  result.place(0, spot)
  result.place(1, spot.near(300))
  result.place(2, spot.near(-300))
  result.place(3, spot.near(300, 300))
  result.place(4, spot.near(600))
  result.cogs[0].aim = spot.near(1000)
  result.cogs[0].hp = 7
  result.cogs[0].cooldown = 36
  result.equipment[0].armor = 1
  result.cogs[1].hp = 4
  result.tick = 2400
  result.seatScore[0] = 250 # 25 points
  result.seatScore[1] = 1230
  result.seatScore[2] = 990
  result.controlHearts[3].owner = 1
  result.controlHearts[4].owner = 1
  result.controlHearts[5].owner = 0
  result.controlHearts[7].owner = 2
  result.heartCaptures[6] = HeartCapture(team: 2, ticks: 36, contested: true)
  result.greatHearts[0].progress = 60
  result.greatHearts[0].present = 3
  result.greatHearts[1].dormantUntil = 2400 + 720

proc geneRow(k: Kinship, j: int): seq[float32] =
  for b in 0..<Loci: result.add(if ((k.genes[j] shr b) and 1'u32) == 1'u32: 1'f32 else: -1'f32)

proc containsRun(o: seq[float32], run: seq[float32]): bool =
  for start in 0..(o.len - run.len):
    var same = true
    for i, v in run:
      if o[start+i] != v:
        same = false
        break
    if same: return true
  false

proc cog(l: FfaV2Layout, k: int): int = l.cogOffset + k*FfaV2CogWidth
proc heart(l: FfaV2Layout, k: int): int = l.heartOffset + k*FfaV2HeartWidth
proc great(l: FfaV2Layout, k: int): int = l.greatOffset + k*FfaV2GreatWidth

suite "Observation contract ffa.v2":
  setup:
    visionRulesVersion = LiveRules
    gameMode = gmFfaKin
    kinshipOverride = none(Kinship)
    kinLayoutPin = none(KinLayout)
  teardown:
    gameMode = gmTeams
    configureSeats(LegacySeats)
    configureMap("")
    kinLayoutPin = none(KinLayout)

  test "id, hash, version selection and the per-match layout":
    check ObservationContractFfaV2 == "paintbot-pw.rules48.obs.ffa.v2"
    check observationContractVersion(ObservationContractFfaV2Hash) == ocFfaV2
    check observationContractHash(ocFfaV2) == ObservationContractFfaV2Hash
    check observationContractId(ocFfaV2) == ObservationContractFfaV2
    check ocFfaV2.int == 102
    expect ValueError: discard observationSize(ocFfaV2)
    # The fixed contracts are untouched.
    check observationSize(ocV1) == 448 and observationSize(ocV2) == 506 and
      observationSize(ocV3) == 514 and observationSize(ocFfaV1) == 810
    let small = ffaV2Layout(16, 10)
    check small.cogOffset == 24 and small.cogRows == 15
    check small.heartOffset == 24 + 15*44 and small.heartRows == 10
    check small.greatOffset == small.heartOffset + 10*12 and small.greatRows == 2
    check small.size == 24 + 15*44 + 10*12 + 2*12
    let big = ffaV2Layout(50, 100)
    check big.size == 24 + 49*44 + 100*12 + 2*12
    expect ValueError: discard ffaV2Layout(1, 10)
    expect ValueError: discard ffaV2Layout(MaxSeats+1, 10)
    var w = handSetWorld(kinshipFor(klPairs, 7))
    check w.ffaV2Layout.size == ffaV2Layout(Seats, w.controlHearts.len).size
    var short = newSeq[float32](w.ffaV2Layout.size - 1)
    expect ValueError: encodeObservation(w, 0, short, ocFfaV2)

  test "hand-set world encodes column by column":
    let k = kinshipFor(klPairs, 7)
    var w = handSetWorld(k)
    let l = w.ffaV2Layout
    var o = newSeq[float32](l.size)
    encodeObservation(w, 0, o, ocFfaV2)
    let spanX = float32(maxX()-minX())
    let spanZ = float32(maxZ()-minZ())
    let diag = sqrt(float64(spanX)*float64(spanX) + float64(spanZ)*float64(spanZ))
    let me = w.cogs[0].pos
    check w.visible(0, 1) and w.visible(0, 3) and w.visible(0, 4) and not w.visible(0, 2)
    # Header: ffa.v1's self block, then match constants and own state only.
    check o[0] == float32(me.x - Width div 2)/spanX and o[1] == float32(me.z - Height div 2)/spanZ
    check o[2] == 7'f32/10 and o[3] == 1'f32/10 and o[4] == 36'f32/72
    check o[5] == 25'f32/1000 and o[6] == 1 and o[7] == float32(FfaMatchTicks-2400)/8640
    check o[8] == float32(Seats)/64 and o[9] == float32(w.controlHearts.len)/100
    check o[10] == float32(w.endTick-2400)/float32(w.endTick)
    check o[11] == 1'f32/float32(w.controlHearts.len)
    check o[12] == float32(w.territoryBoost(0, k))/float32(TerritoryBoostPercent)
    check o[13] == inWater(me).float32 and o[14] == float32(w.elevation(me))/TerrainHeightScale
    check o[15] == 3'f32/64 and o[16] == float32(Seats-1)/64
    check o[17] == float32(w.controlHearts.len)/100 and o[18] == 1
    for c in 19..23: check o[c] == 0
    # Cogs: the three the seat sees, nearest first (1 at 300, 3 at 424, 4 at 600), then zeros.
    let rows = w.ffaV2Rows(0)
    check rows.cogs == @[1, 3, 4] and rows.bodies == @[1, 3, 4]
    let r0 = l.cog(0)
    check o[r0] == 1 and o[r0+1] == 300'f32/spanX and o[r0+2] == 0 and o[r0+3] == 1
    check o[r0+4] == 4'f32/10
    for b in 0..<Loci: check o[r0+5+b] == geneRow(k, 1)[b]
    check o[r0+37] == float32(k.r(0, 1)) and o[r0+38] == 123'f32/1000 and o[r0+39] == 2'f32/10
    check o[r0+40] == float32(300.0/diag)
    check o[r0+41] == inWater(w.cogs[1].pos).float32
    check o[r0+42] == float32(w.elevation(w.cogs[1].pos)-w.elevation(me))/TerrainHeightScale
    check o[r0+43] == 1'f32/255
    check o[l.cog(1)+43] == 3'f32/255 and o[l.cog(2)+43] == 4'f32/255
    check o[l.cog(1)+1] == 300'f32/spanX and o[l.cog(1)+2] == 300'f32/spanZ
    for k2 in 3..<l.cogRows:
      for c in 0..<FfaV2CogWidth: check o[l.cog(k2)+c] == 0
    # Control hearts: every heart, nearest first, ties by index.
    check rows.hearts.len == w.controlHearts.len
    var last = -1'i64
    for kk, i in rows.hearts:
      let d = distance2(me, w.controlHearts[i].pos)
      check d >= last
      last = d
      let h = l.heart(kk)
      let p = w.controlHearts[i].pos
      check o[h] == 1 and o[h+1] == float32(p.x-me.x)/spanX and o[h+2] == float32(p.z-me.z)/spanZ
      check o[h+3] == float32(p.x - Width div 2)/spanX and o[h+4] == float32(p.z - Height div 2)/spanZ
      let owner = w.controlHearts[i].owner
      check o[h+5] == (if owner < 0: -1'f32 elif owner == 0: 1'f32 else: float32(k.r(0, owner.int)))
      check o[h+8] == float32((owner == 0).int)
      check o[h+9] == float32(sqrt(float64(distance2(me, p)))/diag)
      if i == 6: check o[h+6] == 36'f32/HeartCaptureTicks and o[h+7] == 1
    # Great hearts: both, nearest first.
    for kk in 0..1:
      let g = w.greatHearts[rows.greats[kk]]
      let o2 = l.great(kk)
      check o[o2] == 1 and o[o2+1] == float32(g.pos.x-me.x)/spanX
    check rows.greats[0] == 0
    check o[l.great(0)+5] == 1 and o[l.great(0)+6] == 3'f32/16 and o[l.great(0)+7] == 60'f32/GreatHeartCaptureTicks
    check o[l.great(1)+5] == -1 and o[l.great(1)+8] == 720'f32/1440
    for v in o: check v.classify notin {fcNan, fcInf, fcNegInf}

  test "a cog the seat cannot see leaves no row and no trace":
    let k = kinshipFor(klPairs, 7)
    var w = handSetWorld(k)
    # Seat 2 stands behind seat 0; move seat 4 far out of range too.
    w.cogs[4].pos = w.cogs[0].pos.near(-3000, 1500)
    check not w.visible(0, 2) and not w.visible(0, 4)
    var o = newSeq[float32](w.ffaV2Layout.size)
    encodeObservation(w, 0, o, ocFfaV2)
    let rows = w.ffaV2Rows(0)
    check rows.cogs == @[1, 3]
    check 2 notin rows.cogs and 4 notin rows.cogs
    let l = w.ffaV2Layout
    # Neither hidden seat's genome, id or score appears anywhere in the observation.
    for hidden in [2, 4]:
      if k.genes[hidden] != k.genes[1] and k.genes[hidden] != k.genes[3]:
        check not o.containsRun(geneRow(k, hidden))
      for kk in 0..<l.cogRows: check o[l.cog(kk)+43] != float32(hidden)/255
    check float32(990)/10000 notin o[l.cogOffset ..< l.heartOffset]
    # Only the seen cogs count; the valid flags say so.
    check o[15] == 2'f32/64
    var valid = 0
    for kk in 0..<l.cogRows:
      if o[l.cog(kk)] != 0: inc valid
    check valid == 2
    # Rows past the seen cogs are all zero, whatever the unseen cogs do.
    w.seatScore[2] = 5000
    w.cogs[2].hp = 3
    var again = newSeq[float32](l.size)
    encodeObservation(w, 0, again, ocFfaV2)
    check again[l.cogOffset ..< l.heartOffset] == o[l.cogOffset ..< l.heartOffset]
    check again[0 ..< l.cogOffset] == o[0 ..< l.cogOffset]

  test "rows are nearest first, ties by seat id; hearts ties by index":
    let k = kinshipFor(klStrangers, 3)
    var w = handSetWorld(k)
    let me = w.cogs[0].pos
    # Seats 5 and 3 at the same distance in view: the lower id first.
    w.place(5, me.near(300, -300))
    check w.visible(0, 5)
    check distance2(me, w.cogs[5].pos) == distance2(me, w.cogs[3].pos)
    let rows = w.ffaV2Rows(0)
    check rows.cogs == @[1, 3, 5, 4]
    # Two hearts at the same distance: the lower index first.
    w.controlHearts[8].pos = me.near(0, 900)
    w.controlHearts[2].pos = me.near(0, -900)
    let again = w.ffaV2Rows(0)
    let a = again.hearts.find(2)
    let b = again.hearts.find(8)
    check a >= 0 and b == a + 1

  test "the kin mask zeroes every r column":
    let k = kinshipFor(klPairs, 7)
    var w = handSetWorld(k)
    let l = w.ffaV2Layout
    var o = newSeq[float32](l.size)
    encodeFfaV2Observation(w, 0, o, w.ffaV2Rows(0), k, FfaObsMaskKin)
    for kk in 0..<l.cogRows: check o[l.cog(kk)+37] == 0
    check o[12] == 0
    let rows = w.ffaV2Rows(0)
    for kk, i in rows.hearts:
      let owner = w.controlHearts[i].owner
      if owner > 0: check o[l.heart(kk)+5] == 0
      if owner == 0: check o[l.heart(kk)+5] == 1
      if owner < 0: check o[l.heart(kk)+5] == -1

  for (seats, map, layout) in [(16, "", klCousins), (50, "big-twin-mesas", klTribes)]:
    test "every seat encodes at " & $seats & " seats (" & (if map == "": "Heartland" else: "Heartland Big") & ")":
      configureSeats(seats)
      configureMap(map)
      kinLayoutPin = some(layout)
      var w = newWorld(2026, 0)
      check w.cogs.len == seats
      let l = w.ffaV2Layout
      check l.cogRows == seats - 1 and l.heartRows == w.controlHearts.len
      if map != "": check w.controlHearts.len == 100
      var o = newSeq[float32](l.size)
      for slot in 0..<seats:
        encodeObservation(w, slot, o, ocFfaV2)
        let rows = w.ffaV2Rows(slot)
        check rows.cogs.len <= seats - 1
        for kk, j in rows.cogs:
          check j != slot and w.visible(slot, j)
          check o[l.cog(kk)] == 1 and o[l.cog(kk)+43] == float32(j)/255
          if kk > 0:
            let before = distance2(w.cogs[slot].pos, w.cogs[rows.cogs[kk-1]].pos)
            let here = distance2(w.cogs[slot].pos, w.cogs[j].pos)
            check before < here or (before == here and rows.cogs[kk-1] < j)
        for kk in rows.cogs.len..<l.cogRows: check o[l.cog(kk)] == 0
        for kk in 0..<l.heartRows: check o[l.heart(kk)] == 1
        for v in o: check v.classify notin {fcNan, fcInf, fcNegInf}
