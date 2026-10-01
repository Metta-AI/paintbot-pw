## Action contract teams.view.1 raw (16, paintbot-pw.teams.view.1.action.51-25-2-2-2-63x16-63x16-256-8-128): 63 x 7 u
## per-identity offset rows, then walk direction (256), walk distance (8) and look direction (128) heads the reference
## decoder (players/neural_decode.bas) reads in place of the compass step and the compass aim. Through the native ABI:
## layout calls, caller-driven decode (pw_step), the non-compass choices playing exactly as contract 15, a policy seat's
## draws (chosen 63-bin row, then the plain heads) and pw_seat_policy_extra_choices2. Build with --mm:arc --threads:on
## -d:pwTraining.
import std/[unittest, os, random, math, importutils, strutils]
import ../examples/paintbot/[sim, neural_contract, native_env, seat_view]

when not defined(pwTraining): {.error: "the native ABI exists only under -d:pwTraining".}

const Root = currentSourcePath().parentDir.parentDir
type Buffer = ptr UncheckedArray[cfloat]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])
template ibuf(a: untyped): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr a[0])
template cbuf(s: string): ptr UncheckedArray[char] = cast[ptr UncheckedArray[char]](unsafeAddr s[0])
privateAccess(NativeEnv)

proc worldOf(h: pointer): ptr World = addr cast[ptr NativeEnv](h).world
proc mapClamp(x, z: int): Point =
  Point(x: clamp(x, minX(), maxX()).int32, z: clamp(z, minZ(), maxZ()).int32)
proc walkClamp(p: Point): Point =
  Point(x: clamp(p.x, (minX()+100).int32, (maxX()-100).int32), z: clamp(p.z, (minZ()+100).int32, (maxZ()-100).int32))
proc tabCos(i, n: int): int =
  ## the decoder's table entry: round(10000 * cos(2 pi i / n)) (Nim round: half away from zero)
  int(round(10000.0 * cos(2.0 * PI * float(i) / float(n))))
proc tabSin(i, n: int): int = int(round(10000.0 * sin(2.0 * PI * float(i) / float(n))))
proc rnd10k(v: int): int =
  if v >= 0: (v + 5000) div 10000 else: -((-v + 5000) div 10000)

proc newHandle(seed: int32, contract: int32): pointer =
  result = pw_create(seed, 900)
  doAssert result != nil
  doAssert pw_set_action_contract(result, contract) == 0
proc step(h: pointer, actions: var seq[int32]): cint =
  var rewards, terminals = newSeq[cfloat](Seats)
  pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals))
proc neutral(n: int): seq[int32] =
  result = newSeq[int32](Seats*n)
  for i in 0..<Seats:
    result[i*n+5] = 31; result[i*n+6] = 31

suite "Action contract teams.view.1 raw (16)":
  configureRules(NativeRules)

  test "id, hash, sizes, pairing, layout_ext3 (ext2 refuses ten heads)":
    check ActionContractTeamsView1Raw == "paintbot-pw.teams.view.1.action.51-25-2-2-2-63x16-63x16-256-8-128"
    check actionContractVersion(ActionContractTeamsView1RawHash) == acTeamsView1Raw
    check actionHeadSizes(acTeamsView1Raw) == @[51, 25, 2, 2, 2, 63, 63, 256, 8, 128]
    check actionLogitSize(acTeamsView1Raw) == 2490 and LogitSizeRaw == 2490
    check actionLogitHeads(acTeamsView1Raw) == @[51, 25, 2, 2, 2, 1008, 1008, 256, 8, 128]
    check extraHeads(acTeamsView1Raw) == 5 and targetRows(acTeamsView1Raw)
    check pairs(ocTeamsView1, acTeamsView1Raw) and not pairs(ocFfaView1, acTeamsView1Raw)
    let h = newHandle(1, 16)
    defer: pw_destroy(h)
    var e3: array[13, int32]
    check pw_action_layout_ext3(h, ibuf(e3)) == 0
    check e3 == [10'i32, 51, 25, 2, 2, 2, 63, 63, 256, 8, 128, 2490, 0]
    var e2: array[12, int32]
    check pw_action_layout_ext2(h, ibuf(e2)) == -1
    check pw_set_action_contract(h, 15) == 0
    check pw_action_layout_ext3(h, ibuf(e3)) == 0
    check e3 == [7'i32, 51, 25, 2, 2, 2, 23, 23, 0, 0, 0, 818, 0]
    var hex: array[65, char]
    check pw_action_contract_hash(16, cast[ptr UncheckedArray[char]](addr hex[0]), 65) == 0
    check $cast[cstring](addr hex[0]) == ActionContractTeamsView1RawHash
    # the decoder's tables are the integer rounding of the same angles
    let decode = readFile(Root / "examples/paintbot/players/neural_decode.bas")
    for i in [0, 1, 37, 64, 129, 255]:
      check ("    rwc(" & $i & ") = " & $tabCos(i, 256)) in decode
      check ("    rws(" & $i & ") = " & $tabSin(i, 256)) in decode

  test "grid walk: a compass step becomes self + flip * round(R * (cos, sin)(2 pi i / 256)), both teams":
    var r = initRand(3)
    for slot in [0, 1, 6, 9]:
      for trial in 0..<4:
        let h = newHandle(21, 16)
        defer: pw_destroy(h)
        var actions = neutral(10)
        for t in 0..<3: check step(h, actions) == 0
        let w = worldOf(h)
        let flip = if team(slot) == 0: 1 else: -1
        let p = w[].cogs[slot].pos
        let i = r.rand(255)
        let k = r.rand(7)
        let R = WalkDistances[k]
        actions[slot*10] = int32(43 + r.rand(7))    # any compass entry
        actions[slot*10+7] = int32(i)
        actions[slot*10+8] = int32(k)
        check step(h, actions) == 0
        let want = mapClamp(p.x.int + flip * rnd10k(R * tabCos(i, 256)), p.z.int + flip * rnd10k(R * tabSin(i, 256)))
        check w[].cogs[slot].goal == walkClamp(want)

  test "fine look: a compass aim becomes self + flip * round(5000 * (cos, sin)(2 pi k / 128)); identity offsets 63 x 7 u":
    var r = initRand(4)
    for slot in [0, 1]:
      let h = newHandle(23, 16)
      defer: pw_destroy(h)
      var actions = neutral(10)
      for t in 0..<3: check step(h, actions) == 0
      let w = worldOf(h)
      let flip = if team(slot) == 0: 1 else: -1
      let p = w[].cogs[slot].pos
      let k = r.rand(127)
      actions[slot*10+1] = 17
      actions[slot*10+9] = int32(k)
      check step(h, actions) == 0
      check w[].cogs[slot].aim == mapClamp(p.x.int + flip * rnd10k(5000 * tabCos(2*k, 256)),
                                           p.z.int + flip * rnd10k(5000 * tabSin(2*k, 256)))
    # identity offsets: (b - 31) * 7 * flip on the chosen identity's position
    var tested = 0
    for slot in 0..<Seats:
      let h = newHandle(29, 16)
      defer: pw_destroy(h)
      var actions = neutral(10)
      for t in 0..<4: check step(h, actions) == 0
      let w = worldOf(h)
      beginViews(w[])
      let v = seatView(slot)
      var j = -1
      for q in 0..<Seats:
        if q != slot and v.visible(q) == 1:
          j = q; break
      if j < 0: continue
      let flip = if team(slot) == 0: 1 else: -1
      let (bx, bz) = (int32(r.rand(62)), int32(r.rand(62)))
      actions[slot*10+1] = int32(j + 1)
      actions[slot*10+5] = bx
      actions[slot*10+6] = bz
      let want = Point(x: int32(v.playerX(j).int + (bx.int - 31) * 7 * flip),
                       z: int32(v.playerY(j).int + (bz.int - 31) * 7 * flip))
      check step(h, actions) == 0
      check w[].cogs[slot].aim == mapClamp(want.x.int, want.z.int)
      inc tested
    check tested >= 4

  test "non-compass choices with centred offsets play exactly as contract 15 (300 ticks, every seat)":
    var r = initRand(6)
    let a15 = newHandle(31, 15)
    let a16 = newHandle(31, 16)
    defer: pw_destroy(a15); pw_destroy(a16)
    var x15 = newSeq[int32](Seats*7)
    var x16 = newSeq[int32](Seats*10)
    var ticks = 0
    for t in 0..<300:
      for s in 0..<Seats:
        let row = [int32(r.rand(42)), int32(r.rand(16)), int32(r.rand(1)), int32(r.rand(1)), 0'i32]
        for e in 0..4:
          x15[s*7+e] = row[e]; x16[s*10+e] = row[e]
        x15[s*7+5] = 11; x15[s*7+6] = 11
        x16[s*10+5] = 31; x16[s*10+6] = 31
        x16[s*10+7] = int32(r.rand(255)); x16[s*10+8] = int32(r.rand(7)); x16[s*10+9] = int32(r.rand(127))
      let r15 = step(a15, x15)
      let r16 = step(a16, x16)
      check r15 == r16
      check pw_state_hash(a15) == pw_state_hash(a16)
      if r15 != 0: break
      inc ticks
    check ticks > 100

  test "a policy seat draws heads 5 / 6 from the chosen identity's 63-bin row, then 7 .. 9; extra_choices2":
    let h = newHandle(3, 16)
    defer: pw_destroy(h)
    let policy = "paintbot_observe(neuralObservation())\n" &
      "run_neural_net(neuralModel(), neuralObservation(), neuralLogits(), neuralState())\n" &
      "neuralTemperature(-1, 0)\nneuralSample()\n" & readFile(Root / "examples/paintbot/players/neural_decode.bas")
    let manifest = """{"schema": "paintbot-neural-basic/2", "observation_contract": """" &
      ObservationContractTeamsView1Hash & """", "action_contract": """" & ActionContractTeamsView1RawHash & """"}"""
    check pw_set_seat_policy_script(h, 0, cbuf(policy), policy.len.int32, cbuf(manifest), manifest.len.int32) == 0
    var actions = newSeq[int32](Seats*10)
    var logits = newSeq[cfloat](Seats*2490)
    var rewards, terminals = newSeq[cfloat](Seats)
    let j = 4
    logits[51 + 1 + j] = 50                    # aim: identity j
    for q in 0..<16:
      logits[82 + q*63 + (q*2 + 3) mod 63] = 20            # head 5 row q argmax
      logits[82 + 1008 + q*63 + (q*5 + 7) mod 63] = 20     # head 6 row q argmax
    logits[82 + 2016 + 200] = 20               # head 7 = 200
    logits[82 + 2016 + 256 + 6] = 20           # head 8 = 6
    logits[82 + 2016 + 264 + 99] = 20          # head 9 = 99
    check pw_step_logits(h, ibuf(actions), fbuf(logits), fbuf(rewards), fbuf(terminals)) == 0
    var x2: array[15, int32]
    check pw_seat_policy_extra_choices2(h, 0, ibuf(x2)) == 0
    check x2[0..4] == @[int32((j*2 + 3) mod 63), int32((j*5 + 7) mod 63), 200, 6, 99]
    check x2[5..9] == x2[0..4]
    var x1: array[12, int32]
    check pw_seat_policy_extra_choices(h, 0, ibuf(x1)) == -1   # five extra heads: the 15-wide call only

  test "a contract-16 handle seats contract-11 seats but not 13, 14 or 15":
    for (seatAction, ok) in [(ActionContractTeamsView1Hash, true), (ActionContractTeamsView1OffsetHash, false),
                             (ActionContractTeamsView1MoveHash, false), (ActionContractTeamsView1TargetHash, false)]:
      let h = newHandle(3, 16)
      defer: pw_destroy(h)
      let policy = "paintbot_observe(neuralObservation())\n" &
        "run_neural_net(neuralModel(), neuralObservation(), neuralLogits(), neuralState())\n" &
        "neuralSample()\n" & readFile(Root / "examples/paintbot/players/neural_decode.bas")
      let manifest = """{"schema": "paintbot-neural-basic/2", "observation_contract": """" &
        ObservationContractTeamsView1Hash & """", "action_contract": """" & seatAction & """"}"""
      check pw_set_seat_policy_script(h, 0, cbuf(policy), policy.len.int32, cbuf(manifest), manifest.len.int32) == 0
      var actions = newSeq[int32](Seats*10)
      var logits = newSeq[cfloat](Seats*2490)
      var rewards, terminals = newSeq[cfloat](Seats)
      check (pw_step_logits(h, ibuf(actions), fbuf(logits), fbuf(rewards), fbuf(terminals)) == 0) == ok
