## Action contract teams.view.1 mode (16, paintbot-pw.teams.view.1.action.51-25-2-2-2-23x16-23x16-5-12): contract 15's
## heads, then head 7 (movement mode: head 0 / keep goal / keep leg / strafe + / strafe -) and head 8 (aim target: head
## 1 / visible-enemy centroid / control heart k), decoded by players/neural_decode.bas. Through the native ABI: the
## decode of caller-driven seats (pw_step), the layout calls, and mode 0 / target 0 playing exactly as contract 15.
## Build with --mm:arc --threads:on -d:pwTraining.
import std/[unittest, os, random, math, importutils]
import ../examples/paintbot/[sim, neural_contract, native_env, seat_view]

when not defined(pwTraining): {.error: "the native ABI exists only under -d:pwTraining".}

type Buffer = ptr UncheckedArray[cfloat]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])
template ibuf(a: untyped): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr a[0])
privateAccess(NativeEnv)

proc worldOf(h: pointer): ptr World = addr cast[ptr NativeEnv](h).world

proc mapClamp(x, z: int): Point =
  Point(x: clamp(x, minX(), maxX()).int32, z: clamp(z, minZ(), maxZ()).int32)
proc walkClamp(p: Point): Point =
  ## the world's own walk clamp (minX + 100 .. maxX - 100), as every walkTo goal gets
  Point(x: clamp(p.x, (minX()+100).int32, (maxX()-100).int32), z: clamp(p.z, (minZ()+100).int32, (maxZ()-100).int32))
proc isqrtFloor(v: int): int =
  if v <= 0: return 0
  result = int(sqrt(float(v)))
  while result*result > v: dec result
  while (result+1)*(result+1) <= v: inc result

proc newHandle(seed: int32, contract: int32): pointer =
  result = pw_create(seed, 900)
  doAssert result != nil
  doAssert pw_set_action_contract(result, contract) == 0

proc step(h: pointer, actions: var seq[int32]): cint =
  var rewards, terminals = newSeq[cfloat](Seats)
  pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals))

suite "Action contract teams.view.1 mode (16)":
  configureRules(NativeRules)

  test "id, hash, sizes, pairing, layout_ext2":
    check ActionContractTeamsView1Mode == "paintbot-pw.teams.view.1.action.51-25-2-2-2-23x16-23x16-5-12"
    check actionContractVersion(ActionContractTeamsView1ModeHash) == acTeamsView1Mode
    check actionHeadSizes(acTeamsView1Mode) == @[51, 25, 2, 2, 2, 23, 23, 5, 12]
    check actionLogitSize(acTeamsView1Mode) == 835 and LogitSizeMode == 835
    check actionLogitHeads(acTeamsView1Mode) == @[51, 25, 2, 2, 2, 368, 368, 5, 12]
    check extraHeads(acTeamsView1Mode) == 4 and targetRows(acTeamsView1Mode)
    check pairs(ocTeamsView1, acTeamsView1Mode) and not pairs(ocFfaView1, acTeamsView1Mode)
    let h = newHandle(1, 16)
    defer: pw_destroy(h)
    var ext2: array[12, int32]
    check pw_action_layout_ext2(h, ibuf(ext2)) == 0
    check ext2 == [9'i32, 51, 25, 2, 2, 2, 23, 23, 5, 12, 835, 0]
    var hex: array[65, char]
    check pw_action_contract_hash(16, cast[ptr UncheckedArray[char]](addr hex[0]), 65) == 0
    check $cast[cstring](addr hex[0]) == ActionContractTeamsView1ModeHash
    let ffa = pw_create_observation(1, 600, 202)
    defer: pw_destroy(ffa)
    check pw_set_action_contract(ffa, 16) == -1

  test "mode 0 and target 0 play exactly as contract 15 (same heads 0..6, every seat, 300 ticks)":
    var r = initRand(5)
    let a15 = newHandle(9, 15)
    let a16 = newHandle(9, 16)
    defer: pw_destroy(a15); pw_destroy(a16)
    var x15 = newSeq[int32](Seats*7)
    var x16 = newSeq[int32](Seats*9)
    var ticks = 0
    for t in 0..<300:
      for s in 0..<Seats:
        let row = [int32(r.rand(50)), int32(r.rand(24)), int32(r.rand(1)), int32(r.rand(1)), 0'i32,
                   int32(r.rand(22)), int32(r.rand(22))]
        for e in 0..6:
          x15[s*7+e] = row[e]
          x16[s*9+e] = row[e]
        x16[s*9+7] = 0
        x16[s*9+8] = 0
      let r15 = step(a15, x15)
      let r16 = step(a16, x16)
      check r15 == r16
      check pw_state_hash(a15) == pw_state_hash(a16)
      if r15 != 0: break
      inc ticks
    check ticks > 100

  test "keep goal re-issues last tick's goal, whatever head 0 says (both teams)":
    for slot in [0, 1]:
      let h = newHandle(5, 16)
      defer: pw_destroy(h)
      var actions = newSeq[int32](Seats*9)
      for i in 0..<Seats:
        actions[i*9+5] = 11; actions[i*9+6] = 11
      for t in 0..<3: check step(h, actions) == 0
      let w = worldOf(h)
      let flip = if team(slot) == 0: 1 else: -1
      let pA = w[].cogs[slot].pos
      let gA = mapClamp(pA.x.int + flip*200, pA.z.int)   # compass 43 = +x in the team frame
      actions[slot*9] = 43
      check step(h, actions) == 0
      check w[].cogs[slot].goal == walkClamp(gA)
      actions[slot*9] = 0
      actions[slot*9+7] = 1
      for t in 0..<3:   # keep, keep, keep: the same goal each tick
        check step(h, actions) == 0
        check w[].cogs[slot].goal == walkClamp(gA)

  test "keep leg = self + (last goal - last position), integer, clamped":
    let slot = 2
    let h = newHandle(7, 16)
    defer: pw_destroy(h)
    var actions = newSeq[int32](Seats*9)
    for i in 0..<Seats:
      actions[i*9+5] = 11; actions[i*9+6] = 11
    for t in 0..<3: check step(h, actions) == 0
    let w = worldOf(h)
    let pA = w[].cogs[slot].pos
    let gA = mapClamp(pA.x.int + 200, pA.z.int + 200)   # compass 1 = (+1, +1), team 0
    actions[slot*9] = 44
    check step(h, actions) == 0
    let pB = w[].cogs[slot].pos
    actions[slot*9] = 0
    actions[slot*9+7] = 2
    check step(h, actions) == 0
    check w[].cogs[slot].goal == walkClamp(mapClamp(pB.x.int + gA.x.int - pA.x.int, pB.z.int + gA.z.int - pA.z.int))

  test "keep with no goal known (a life's first decided tick) stays":
    let h = newHandle(11, 16)
    defer: pw_destroy(h)
    var actions = newSeq[int32](Seats*9)
    for i in 0..<Seats:
      actions[i*9] = 43; actions[i*9+5] = 11; actions[i*9+6] = 11; actions[i*9+7] = 1
    let w = worldOf(h)
    let p0 = w[].cogs[4].pos
    check step(h, actions) == 0
    check w[].cogs[4].goal == walkClamp(p0)

  test "strafe +/- = a 200-unit step perpendicular to head 1's identity (integer math), both teams":
    var tested = 0
    for slot in 0..<Seats:
      let h = newHandle(13, 16)
      defer: pw_destroy(h)
      var actions = newSeq[int32](Seats*9)
      for i in 0..<Seats:
        actions[i*9+5] = 11; actions[i*9+6] = 11
      for t in 0..<4: check step(h, actions) == 0
      let w = worldOf(h)
      beginViews(w[])
      let v = seatView(slot)
      var j = -1
      for k in 0..<Seats:
        if k != slot and v.visible(k) == 1:
          j = k
          break
      if j < 0: continue
      let p = w[].cogs[slot].pos
      let dx = v.playerX(j).int - p.x.int
      let dz = v.playerY(j).int - p.z.int
      let L = isqrtFloor(dx*dx + dz*dz)
      if L == 0: continue
      for (mode, ss) in [(3'i32, 1), (4'i32, -1)]:
        let h2 = newHandle(13, 16)
        defer: pw_destroy(h2)
        var a2 = newSeq[int32](Seats*9)
        for i in 0..<Seats:
          a2[i*9+5] = 11; a2[i*9+6] = 11
        for t in 0..<4: check step(h2, a2) == 0
        a2[slot*9+1] = int32(j + 1)
        a2[slot*9+7] = mode
        check step(h2, a2) == 0
        let want = mapClamp(p.x.int + (ss * (-dz) * 200) div L, p.z.int + (ss * dx * 200) div L)
        check worldOf(h2)[].cogs[slot].goal == walkClamp(want)
        inc tested
    check tested >= 4

  test "aim target: control heart k, out-of-range k falls back to head 1, centroid of visible enemies":
    let slot = 0
    let h = newHandle(17, 16)
    defer: pw_destroy(h)
    var actions = newSeq[int32](Seats*9)
    for i in 0..<Seats:
      actions[i*9+5] = 11; actions[i*9+6] = 11
    for t in 0..<3: check step(h, actions) == 0
    let w = worldOf(h)
    let hearts = w[].controlHearts.len
    check hearts > 0
    actions[slot*9+8] = 2   # heart 0
    check step(h, actions) == 0
    check w[].cogs[slot].aim == w[].controlHearts[0].pos
    # k >= heartCount(): head 1's aim stands (compass 17 = +x, 5000 units, clamped)
    let p = w[].cogs[slot].pos
    actions[slot*9+1] = 17
    actions[slot*9+8] = int32(2 + hearts)
    if 2 + hearts <= 11:
      check step(h, actions) == 0
      check w[].cogs[slot].aim == mapClamp(p.x.int + 5000, p.z.int)
    # centroid: every visible enemy identity's playerX / playerY, integer mean (Nim div = BASIC div)
    beginViews(w[])
    let v = seatView(slot)
    var n, sx, sz = 0
    for k in 0..<Seats:
      if k mod 2 != team(slot) and v.visible(k) == 1:
        inc n; sx += v.playerX(k).int; sz += v.playerY(k).int
    actions[slot*9+1] = 17
    actions[slot*9+8] = 1
    let p2 = w[].cogs[slot].pos
    check step(h, actions) == 0
    if n > 0:
      check w[].cogs[slot].aim == Point(x: int32(sx div n), z: int32(sz div n))
    else:
      check w[].cogs[slot].aim == mapClamp(p2.x.int + 5000, p2.z.int)   # none visible: head 1's aim stands
