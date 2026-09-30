## Action contract teams.view.1 movement-offset (paintbot-pw.teams.view.1.action.51-25-2-2-2-23-23-23-23):
## the aim-offset contract's seven heads, then two 23-bin heads the policy.bas reads as neuralChoice(7) /
## (8). The reference decode (players/neural_decode.bas) adds (moveOffset(dx), moveOffset(dz)) (symmetric
## log-spaced bins, 16 u .. 4000 u), mirrored for team 1, to the movement head's goal and clamps it to the
## map; nothing native computes a goal.
## Through the native ABI: pw_set_action_contract(14), nine heads per seat in pw_step,
## pw_action_layout_ext2, and a policy seat selecting the extra heads from its logits
## (pw_seat_policy_extra_choices). Build with --mm:arc --threads:on -d:pwTraining.
import std/[unittest, os, importutils, strutils]
import polyworld/cli
import ../examples/paintbot/[sim, neural_contract, native_env, bots, contract_hash]

when not defined(pwTraining): {.error: "the native ABI exists only under -d:pwTraining".}

const Root = currentSourcePath().parentDir.parentDir
type Buffer = ptr UncheckedArray[cfloat]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])
template ibuf(a: untyped): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr a[0])
template cbuf(s: string): ptr UncheckedArray[char] = cast[ptr UncheckedArray[char]](unsafeAddr s[0])
privateAccess(NativeEnv)

proc worldOf(h: pointer): ptr World = addr cast[ptr NativeEnv](h).world

proc manifestFor(action: string): string =
  """{"schema": "paintbot-neural-basic/2", "observation_contract": """" & ObservationContractTeamsView1Hash &
    """", "action_contract": """" & action & """", "decoder": {"sampling": {"mode": "categorical"}}}"""

let policy = "paintbot_observe(neuralObservation())\n" &
  "run_neural_net(neuralModel(), neuralObservation(), neuralLogits(), neuralState())\n" &
  "neuralSample()\n" & readFile(Root / "examples/paintbot/players/neural_decode.bas")

proc expectedGoal(w: World, base: Point, dx, dz, flip: int32): Point =
  ## The decode's goal (base + bins * step * flip, clamped to the map), then the world's own walk
  ## clamp (minX + 100 .. maxX - 100), which applies to every walkTo.
  let gx = clamp(base.x + moveOffset(dx.int).int32*flip, minX().int32, maxX().int32)
  let gz = clamp(base.z + moveOffset(dz.int).int32*flip, minZ().int32, maxZ().int32)
  Point(x: clamp(gx, (minX()+100).int32, (maxX()-100).int32), z: clamp(gz, (minZ()+100).int32, (maxZ()-100).int32))

suite "Action contract teams.view.1 movement-offset":
  configureRules(NativeRules)
  test "id, hash, heads, pairing and the decode's step":
    check ActionContractTeamsView1Move == "paintbot-pw.teams.view.1.action.51-25-2-2-2-23-23-23-23"
    check ActionContractTeamsView1MoveHash == sha256Hex(ActionContractTeamsView1Move)
    check actionContractVersion(ActionContractTeamsView1MoveHash) == acTeamsView1Move
    check actionHeadSizes(acTeamsView1Move) == @[51, 25, 2, 2, 2, 23, 23, 23, 23]
    check LogitSizeMove == 174
    check extraHeads(acTeamsView1Move) == 4 and extraHeads(acTeamsView1Offset) == 2 and extraHeads(acTeamsView1) == 0
    check pairs(ocTeamsView1, acTeamsView1Move)
    check not pairs(ocFfaView1, acTeamsView1Move)
    # The table is symmetric, log-spaced (ratio 250^(1/10)) and reaches 4000 u; the reference decode (BASIC
    # has no Nim constants) holds the same table.
    check moveOffset(11) == 0 and moveOffset(12) == 16 and moveOffset(10) == -16
    check moveOffset(22) == 4000 and moveOffset(0) == -4000
    for b in 0..22: check moveOffset(b) == -moveOffset(22 - b)
    for j in 1..<MoveOffsetTable.len:
      let ratio = MoveOffsetTable[j] / MoveOffsetTable[j-1]
      check ratio > 1.6 and ratio < 1.9
    let decode = readFile(Root / "examples/paintbot/players/neural_decode.bas")
    for j, v in MoveOffsetTable:
      check ("  if mvj = " & $(j+1) & " then\n    mo = " & $v & "\n  end if") in decode

  test "pw_set_action_contract(14), pw_action_layout_ext2 and the contract hash; the older calls refuse 14":
    let h = pw_create(7, 600)
    require h != nil
    defer: pw_destroy(h)
    check pw_set_action_contract(h, 14) == 0
    check pw_action_contract(h) == 14
    var layout: array[8, int32]
    check pw_action_layout(h, ibuf(layout)) == -1
    var ext: array[10, int32]
    check pw_action_layout_ext(h, ibuf(ext)) == -1
    var ext2: array[12, int32]
    check pw_action_layout_ext2(h, ibuf(ext2)) == 0
    check ext2 == [9'i32, 51, 25, 2, 2, 2, 23, 23, 23, 23, 174, 0]
    var hash: array[65, char]
    check pw_action_contract_hash(14, cast[ptr UncheckedArray[char]](addr hash[0]), 65) == 0
    check $cast[cstring](addr hash[0]) == ActionContractTeamsView1MoveHash
    check pw_reset(h, 8, 600) == 0
    check pw_action_contract(h) == 14  # kept across resets
    # ext2 describes the other contracts too.
    check pw_set_action_contract(h, 13) == 0
    check pw_action_layout_ext2(h, ibuf(ext2)) == 0
    check ext2 == [7'i32, 51, 25, 2, 2, 2, 23, 23, 0, 0, 128, 0]
    check pw_set_action_contract(h, 11) == 0
    check pw_action_layout_ext2(h, ibuf(ext2)) == 0
    check ext2 == [5'i32, 51, 25, 2, 2, 2, 0, 0, 0, 0, 82, 0]
    let ffa = pw_create_observation(7, 600, 202)
    require ffa != nil
    defer: pw_destroy(ffa)
    check pw_set_action_contract(ffa, 14) == -1

  test "pw_step: the walk goal moves by the offset bins from stay and from a compass step, mirrored for team 1":
    for (m, dx, dz) in [(0'i32, 11'i32, 11'i32), (0'i32, 15'i32, 7'i32), (0'i32, 0'i32, 22'i32),
                        (43'i32, 11'i32, 11'i32), (43'i32, 19'i32, 3'i32)]:
      for slot in [0, 1]:   # team 0 and team 1
        let h = pw_create(5, 600)
        require h != nil
        defer: pw_destroy(h)
        check pw_set_action_contract(h, 14) == 0
        var actions = newSeq[int32](Seats*9)
        var rewards, terminals = newSeq[cfloat](Seats)
        for i in 0..<Seats:
          for e in 5..8: actions[i*9+e] = 11
        for step in 0..<3:
          check pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
        let w = worldOf(h)
        let flip = if team(slot) == 0: 1'i32 else: -1'i32
        let pos = w[].cogs[slot].pos
        let base = if m == 0: pos
                   else: Point(x: clamp(pos.x + flip*200, minX().int32, maxX().int32), z: pos.z)  # compass 0 = +x
        actions[slot*9] = m
        actions[slot*9+7] = dx
        actions[slot*9+8] = dz
        check pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
        check w[].cogs[slot].goal == expectedGoal(w[], base, dx, dz, flip)

  test "a policy seat selects heads 7 and 8 after 5 and 6; pw_seat_policy_extra_choices":
    let h = pw_create(3, 600)
    require h != nil
    defer: pw_destroy(h)
    check pw_set_action_contract(h, 14) == 0
    let argmax = policy.replace("neuralSample()", "neuralTemperature(-1, 0)\nneuralSample()")
    let manifest = manifestFor(ActionContractTeamsView1MoveHash)
    check pw_set_seat_policy_script(h, 0, cbuf(argmax), argmax.len.int32, cbuf(manifest), manifest.len.int32) == 0
    var actions = newSeq[int32](Seats*9)
    var logits = newSeq[cfloat](Seats*174)
    var rewards, terminals = newSeq[cfloat](Seats)
    logits[82 + 17] = 5           # head 5 argmax = 17
    logits[82 + 23 + 4] = 5       # head 6 argmax = 4
    logits[128 + 20] = 5          # head 7 argmax = 20
    logits[128 + 23 + 2] = 5      # head 8 argmax = 2
    check pw_step_logits(h, ibuf(actions), fbuf(logits), fbuf(rewards), fbuf(terminals)) == 0
    var extra: array[12, int32]
    check pw_seat_policy_extra_choices(h, 0, ibuf(extra)) == 0
    check extra == [17'i32, 4, 20, 2, 17, 4, 20, 2, 0, 0, 0, 0]
    var six: array[6, int32]
    check pw_seat_policy_offset_choices(h, 0, ibuf(six)) == -1   # a movement-offset seat: use the extra call
    check pw_seat_policy_extra_choices(h, 1, ibuf(extra)) == -1  # not a policy seat
    # decoder.sampling covers heads 7 and 8 (no heads list): temperature 1 on every extra head.
    check pw_set_seat_policy_script(h, 0, cbuf(policy), policy.len.int32, cbuf(manifest), manifest.len.int32) == 0
    for i in 0..<logits.len: logits[i] = 0
    var seen7: set[int8]
    for step in 0..<60:
      check pw_step_logits(h, ibuf(actions), fbuf(logits), fbuf(rewards), fbuf(terminals)) == 0
      check pw_seat_policy_extra_choices(h, 0, ibuf(extra)) == 0
      check extra[8..11] == [1000'i32, 1000, 1000, 1000]
      seen7.incl extra[2].int8
    check seen7.card > 5

  test "heads 5 and 6 draw the same under 13 and 14 when 7 and 8 are argmax":
    let heads56 = policy.replace("neuralSample()",
      "neuralTemperature(-1, 0)\nneuralTemperature(5, 1000)\nneuralTemperature(6, 1000)\nneuralSample()")
    var draws: array[2, seq[int32]]
    for k, (contract, width, action) in [(13'i32, 128, ActionContractTeamsView1OffsetHash),
                                         (14'i32, 174, ActionContractTeamsView1MoveHash)]:
      let h = pw_create(9, 600)
      require h != nil
      defer: pw_destroy(h)
      check pw_set_action_contract(h, contract) == 0
      let manifest = manifestFor(action)
      check pw_set_seat_policy_script(h, 0, cbuf(heads56), heads56.len.int32, cbuf(manifest), manifest.len.int32) == 0
      var actions = newSeq[int32](Seats*9)
      var logits = newSeq[cfloat](Seats*width)
      var rewards, terminals = newSeq[cfloat](Seats)
      var extra: array[12, int32]
      for step in 0..<50:
        check pw_step_logits(h, ibuf(actions), fbuf(logits), fbuf(rewards), fbuf(terminals)) == 0
        check pw_seat_policy_extra_choices(h, 0, ibuf(extra)) == 0
        draws[k].add extra[0]
        draws[k].add extra[1]
    check draws[0] == draws[1]
    check draws[0].len == 100

  test "a contract-13 seat reports heads 5 and 6 through both calls; a seven-head seat cannot step on a 14 handle":
    let h = pw_create(3, 600)
    require h != nil
    defer: pw_destroy(h)
    check pw_set_action_contract(h, 13) == 0
    let manifest = manifestFor(ActionContractTeamsView1OffsetHash)
    check pw_set_seat_policy_script(h, 0, cbuf(policy), policy.len.int32, cbuf(manifest), manifest.len.int32) == 0
    var actions = newSeq[int32](Seats*9)
    var logits = newSeq[cfloat](Seats*174)
    var rewards, terminals = newSeq[cfloat](Seats)
    check pw_step_logits(h, ibuf(actions), fbuf(logits), fbuf(rewards), fbuf(terminals)) == 0
    var six: array[6, int32]
    var extra: array[12, int32]
    check pw_seat_policy_offset_choices(h, 0, ibuf(six)) == 0
    check pw_seat_policy_extra_choices(h, 0, ibuf(extra)) == 0
    check extra[0] == six[0] and extra[1] == six[1] and extra[4] == six[2] and extra[5] == six[3]
    check extra[8] == six[4] and extra[9] == six[5]
    check extra[2] == 0 and extra[3] == 0 and extra[10] == 0 and extra[11] == 0
    let h14 = pw_create(3, 600)
    require h14 != nil
    defer: pw_destroy(h14)
    check pw_set_action_contract(h14, 14) == 0
    check pw_set_seat_policy_script(h14, 0, cbuf(policy), policy.len.int32, cbuf(manifest), manifest.len.int32) == 0
    check pw_step_logits(h14, ibuf(actions), fbuf(logits), fbuf(rewards), fbuf(terminals)) == -1

  test "decoder.sampling.heads 7 and 8 need the movement-offset contract":
    let h = pw_create(3, 600)
    require h != nil
    defer: pw_destroy(h)
    let bad = """{"schema": "paintbot-neural-basic/2", "observation_contract": """" & ObservationContractTeamsView1Hash &
      """", "action_contract": """" & ActionContractTeamsView1OffsetHash &
      """", "decoder": {"sampling": {"mode": "categorical", "heads": [0, 7]}}}"""
    check pw_set_seat_policy_script(h, 0, cbuf(policy), policy.len.int32, cbuf(bad), bad.len.int32) == 2
    let good = bad.replace(ActionContractTeamsView1OffsetHash, ActionContractTeamsView1MoveHash)
    check pw_set_seat_policy_script(h, 0, cbuf(policy), policy.len.int32, cbuf(good), good.len.int32) == 0

import std/random
import ./paintbot_pwnet2_fixture
from ../examples/paintbot/neural_host import loadNeuralSeat

suite "Hosted movement-offset seats":
  test "a hosted movement-offset actor loads, samples heads 7 and 8 and plays; a seven-head width is refused":
    var r = initRand(17)
    let model = encode2(TeamsViewSize, ActionSizesMove, [r.dense(TeamsViewSize, LogitSizeMove, bias = true)],
      ObservationContractTeamsView1Hash, ActionContractTeamsView1MoveHash)
    let dir = getTempDir() / ("paintbot-move-offset-" & $getCurrentProcessId())
    createDir(dir)
    defer: removeDir(dir)
    let path = dir / "policy.bas"
    writeFile(path, "paintbot_observe(neuralObservation())\n" &
      "run_neural_net(neuralModel(), neuralObservation(), neuralLogits(), neuralState())\n" &
      "neuralTemperature(-1, 1000)\nneuralSample()\n" & readFile(Root / "examples/paintbot/players/neural_decode.bas"))
    writeFile(path & ".model.bin", model)
    var players = loadBots(@[BotGroup(path: path, count: Seats)])
    var w = newWorld(4)
    var seen: set[int8]
    for tick in 0..<120:
      let commands = players.decide(w)
      for slot in 0..<Seats:
        if players[slot].neural.sampled:
          check players[slot].neural.offsetChoices[2] in 0'i32..22'i32
          seen.incl players[slot].neural.offsetChoices[2].int8
      w.step(commands)
    for slot in 0..<Seats: check not players[slot].failed
    check seen.card > 5
    writeFile(path & ".model.bin", encode2(TeamsViewSize, ActionSizesOffset,
      [r.dense(TeamsViewSize, LogitSizeOffset, bias = true)], ObservationContractTeamsView1Hash,
      ActionContractTeamsView1MoveHash))
    expect ValueError: discard loadNeuralSeat(path, 0)
