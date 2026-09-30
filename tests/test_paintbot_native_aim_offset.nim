## Action contract teams.view.1 aim-offset (paintbot-pw.teams.view.1.action.51-25-2-2-2-23-23):
## the five heads, then two 23-bin heads the policy.bas reads as neuralChoice(5) / (6). The
## reference decode (players/neural_decode.bas) adds ((ix - 11) * 28, (iz - 11) * 28), mirrored
## for team 1, to an identity aim; nothing native computes a lead. Through the native ABI:
## pw_set_action_contract(13), seven heads per seat in pw_step, pw_action_layout_ext, and a
## policy seat selecting the offset heads from its logits (pw_seat_policy_offset_choices).
## Build with --mm:arc --threads:on -d:pwTraining.
import std/[unittest, os, importutils, strutils]
import polyworld/cli
import ../examples/paintbot/[sim, neural_contract, native_env, bots, contract_hash]

when not defined(pwTraining): {.error: "the native ABI exists only under -d:pwTraining".}

const Root = currentSourcePath().parentDir.parentDir
type Buffer = ptr UncheckedArray[cfloat]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])
template ibuf(a: untyped): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr a[0])
privateAccess(NativeEnv)

proc worldOf(h: pointer): ptr World = addr cast[ptr NativeEnv](h).world

proc visiblePair(w: World): (int, int) =
  ## A live seat and the lowest identity (not itself, as a body with no disguise) it sees.
  for slot in 0..<Seats:
    if w.cogs[slot].hp <= 0: continue
    for other in 0..<Seats:
      if other != slot and not w.uniforms[other] and w.visible(slot, other): return (slot, other)
  (-1, -1)

suite "Action contract teams.view.1 aim-offset":
  configureRules(NativeRules)
  test "id, hash, heads and pairing":
    check ActionContractTeamsView1Offset == "paintbot-pw.teams.view.1.action.51-25-2-2-2-23-23"
    check ActionContractTeamsView1OffsetHash == sha256Hex(ActionContractTeamsView1Offset)
    check actionContractVersion(ActionContractTeamsView1OffsetHash) == acTeamsView1Offset
    check actionHeadSizes(acTeamsView1Offset) == @[51, 25, 2, 2, 2, 23, 23]
    check LogitSizeOffset == 128
    check pairs(ocTeamsView1, acTeamsView1Offset) and pairs(ocTeamsView1, acTeamsView1)
    check not pairs(ocFfaView1, acTeamsView1Offset)

  test "pw_set_action_contract, pw_action_layout(_ext) and the contract hash":
    let h = pw_create(7, 600)
    require h != nil
    defer: pw_destroy(h)
    check pw_action_contract(h) == 11
    check pw_set_action_contract(h, 12) == -1
    check pw_set_action_contract(h, 2) == -1
    check pw_set_action_contract(h, 13) == 0
    check pw_action_contract(h) == 13
    var layout: array[8, int32]
    check pw_action_layout(h, ibuf(layout)) == -1
    var ext: array[10, int32]
    check pw_action_layout_ext(h, ibuf(ext)) == 0
    check ext == [7'i32, 51, 25, 2, 2, 2, 23, 23, 128, 0]
    var hash: array[65, char]
    check pw_action_contract_hash(13, cast[ptr UncheckedArray[char]](addr hash[0]), 65) == 0
    check $cast[cstring](addr hash[0]) == ActionContractTeamsView1OffsetHash
    check pw_reset(h, 8, 600) == 0
    check pw_action_contract(h) == 13  # kept across resets
    let ffa = pw_create_observation(7, 600, 202)
    require ffa != nil
    defer: pw_destroy(ffa)
    check pw_set_action_contract(ffa, 13) == -1
    check pw_set_action_contract(ffa, 12) == 0

  test "pw_step: an identity aim moves by the offset bins, mirrored for team 1; centre bins add nothing":
    var checkedSides: set[int8]
    for seed in 1'i32..60'i32:
      if checkedSides == {0'i8, 1'i8}: break
      for (ix, iz) in [(11'i32, 11'i32), (15'i32, 7'i32), (0'i32, 22'i32)]:
        let h = pw_create(seed, 600)
        require h != nil
        defer: pw_destroy(h)
        check pw_set_action_contract(h, 13) == 0
        var actions = newSeq[int32](Seats*7)
        var rewards, terminals = newSeq[cfloat](Seats)
        # Walk everyone a little so they face each other, then look for a visible pair.
        for step in 0..<40:
          check pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
        let w = worldOf(h)
        let (slot, target) = visiblePair(w[])
        if slot < 0: continue
        let flip = if team(slot) == 0: 1'i32 else: -1'i32
        let before = w[].cogs[target].pos
        for i in 0..<actions.len: actions[i] = 0
        actions[slot*7+1] = int32(target+1)
        actions[slot*7+5] = ix
        actions[slot*7+6] = iz
        check pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
        let expected = Point(x: clamp(before.x + (ix-11)*28*flip, minX().int32, maxX().int32),
                             z: clamp(before.z + (iz-11)*28*flip, minZ().int32, maxZ().int32))
        check w[].cogs[slot].aim == expected
        checkedSides.incl team(slot).int8
    check checkedSides == {0'i8, 1'i8}

  test "a policy seat selects the offset heads from its logits; argmax and temperature":
    let h = pw_create(3, 600)
    require h != nil
    defer: pw_destroy(h)
    check pw_set_action_contract(h, 13) == 0
    let policy = "paintbot_observe(neuralObservation())\n" &
      "run_neural_net(neuralModel(), neuralObservation(), neuralLogits(), neuralState())\n" &
      "neuralSample()\n" & readFile(Root / "examples/paintbot/players/neural_decode.bas")
    let manifest = """{"schema": "paintbot-neural-basic/2", "observation_contract": """" &
      ObservationContractTeamsView1Hash & """", "action_contract": """" & ActionContractTeamsView1OffsetHash & """"}"""
    check pw_set_seat_policy_script(h, 0, cast[ptr UncheckedArray[char]](unsafeAddr policy[0]), policy.len.int32,
      cast[ptr UncheckedArray[char]](unsafeAddr manifest[0]), manifest.len.int32) == 0
    var actions = newSeq[int32](Seats*7)
    var logits = newSeq[cfloat](Seats*128)
    var rewards, terminals = newSeq[cfloat](Seats)
    logits[82 + 17] = 5    # head 5 argmax = 17
    logits[82 + 23 + 4] = 5  # head 6 argmax = 4
    check pw_step_logits(h, ibuf(actions), fbuf(logits), fbuf(rewards), fbuf(terminals)) == 0
    var choices: array[6, int32]
    check pw_seat_policy_offset_choices(h, 0, ibuf(choices)) == 0
    check choices == [17'i32, 4, 17, 4, 0, 0]
    check pw_seat_policy_offset_choices(h, 1, ibuf(choices)) == -1  # not a policy seat
    let hot = policy.replace("neuralSample()", "neuralTemperature(5, 1000)\nneuralSample()")
    check pw_set_seat_policy_script(h, 0, cast[ptr UncheckedArray[char]](unsafeAddr hot[0]), hot.len.int32,
      cast[ptr UncheckedArray[char]](unsafeAddr manifest[0]), manifest.len.int32) == 0
    for i in 0..<logits.len: logits[i] = 0
    var seen: set[int8]
    for step in 0..<60:
      check pw_step_logits(h, ibuf(actions), fbuf(logits), fbuf(rewards), fbuf(terminals)) == 0
      check pw_seat_policy_offset_choices(h, 0, ibuf(choices)) == 0
      if choices[0] >= 0: seen.incl choices[0].int8
      check choices[4] == 1000 and choices[5] == 0 and choices[1] == 0
    check seen.card > 5  # uniform logits at temperature 1: many bins drawn

import std/random
import ./paintbot_pwnet2_fixture
from ../examples/paintbot/neural_host import loadNeuralSeat

suite "Hosted aim-offset seats":
  test "a hosted aim-offset actor loads, samples heads 5 and 6 and plays; a five-head width is refused":
    var r = initRand(13)
    let model = encode2(TeamsViewSize, ActionSizesOffset, [r.dense(TeamsViewSize, LogitSizeOffset, bias = true)],
      ObservationContractTeamsView1Hash, ActionContractTeamsView1OffsetHash)
    let dir = getTempDir() / ("paintbot-aim-offset-" & $getCurrentProcessId())
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
          check players[slot].neural.offsetChoices[0] in 0'i32..22'i32
          seen.incl players[slot].neural.offsetChoices[0].int8
      w.step(commands)
    for slot in 0..<Seats: check not players[slot].failed
    check seen.card > 5
    # The same dense layer with five-head sizes under the aim-offset hash is refused.
    writeFile(path & ".model.bin", encode2(TeamsViewSize, ActionSizes, [r.dense(TeamsViewSize, LogitSize, bias = true)],
      ObservationContractTeamsView1Hash, ActionContractTeamsView1OffsetHash))
    expect ValueError: discard loadNeuralSeat(path, 0)
