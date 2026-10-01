## Speech for FFA-kin neural seats (RULES C1: no capability beyond BASIC's).
##   - Action contract ffa.view.1 pointer shout (15, opt-in): the five pointer heads, then head 5
##     (0 nothing, 1 "hurt", 2 "at": players/ffa.bas's whole shout vocabulary), decoded by
##     players/neural_decode_ffa.bas through BASIC shout().
##   - Observation contract ffa.view.1h (203, opt-in; and ffa.view.1hu<K>): ffa.view.1's floats,
##     then 16 heard-speech rows built from the heard* builtins' values.
##   - pw_seat_shouts: what a seat said, as head-5 labels (behaviour cloning).
## Every existing contract keeps its hash and its bytes (the identity tests below).
import std/[unittest, os, importutils, random, options, strutils, algorithm]
import polyworld/cli
import ../examples/paintbot/[sim, kinship, neural_contract, native_env, seat_view, bots, neural_host, contract_hash]
import paintbot_pwnet2_fixture
privateAccess(NativeEnv)

const Root = currentSourcePath().parentDir.parentDir
const PlayersDir = Root / "examples" / "paintbot" / "players"
const DecoderFfa = staticRead("../examples/paintbot/players/neural_decode_ffa.bas")
const PolicyFfa = "paintbot_observe(neuralObservation())\nrun_neural_net(neuralModel(), neuralObservation(), " &
  "neuralLogits(), neuralState())\nneuralSample()\n" & DecoderFfa
const HeartlandConfig = """{"seed": 2026, "max_ticks": 8640, "mode": "ffa_kin", "kin_layout": "cousins"}"""
const HeartlandBigConfig = """{"seed": 2026, "max_ticks": 8640, "mode": "ffa_kin", "map": "big-twin-mesas", "kin_layout": "tribes"}"""
## What a BASIC seat that stands still says on tick t: class t mod 3, as plain BASIC.
const StayShout = """walkTo(selfX, selfY)
chargeGrenade(0)
sneak(0)
said = worldTick mod 3
if said = 1 then
  shout(strNew("hurt"))
end if
if said = 2 then
  shout(strNew("at"))
end if
"""
## The hashes of every contract that existed before this change, from origin/main 6335aab.
const PreexistingHashes = [
  ("paintbot-pw.teams.view.1", "8ee935f46326c0c513fac82c14634becf48199c364f4688553fa26aedbc1f08e"),
  ("paintbot-pw.ffa.view.1", "e959416f94c5af3c6dfbc1730009712276c6e1a2eb961c32b7e7f92e825260e9"),
  ("paintbot-pw.teams.view.1.action.51-25-2-2-2", "3250c1972b929e0fa7d7e00cc332f3af4002ae3931c113c49fc7910e01990ea1"),
  ("paintbot-pw.ffa.view.1.action.pointer", "1bce1c2d9f1ff1f520be2a9078852bd7870bf323548e797cb82e1cd623193718"),
  ("paintbot-pw.teams.view.1.action.51-25-2-2-2-23-23", "a15dddeba9ff651118ea09ab823692a79ba6a45b5687a011dfc9dec43dd0dcc2"),
  ("paintbot-pw.teams.view.1.action.51-25-2-2-2-23-23-23-23",
   "ca817149ae64bbc1b63a762974acf72b01c9f75fdd119aa84422d8de8efe16a9")]

proc fp(buffer: var seq[float32]): ptr UncheckedArray[cfloat] =
  cast[ptr UncheckedArray[cfloat]](addr buffer[0])
proc ip(buffer: var seq[int32]): ptr UncheckedArray[int32] =
  cast[ptr UncheckedArray[int32]](addr buffer[0])
proc cp(text: string): ptr UncheckedArray[char] = cast[ptr UncheckedArray[char]](unsafeAddr text[0])
proc envOf(h: pointer): ptr NativeEnv = cast[ptr NativeEnv](h)

proc hashOf(f: proc(o: ptr UncheckedArray[char]): cint): string =
  var text: array[65, char]
  if f(cast[ptr UncheckedArray[char]](addr text[0])) != 0: return "ERR"
  $cast[cstring](addr text[0])

proc heartland(seats: int, config: string, ticks = 240'i32, version = 202'i32, userInputs = 0'i32): pointer =
  result = if userInputs == 0: pw_create_observation(7, 0, version)
           else: pw_create_observation_inputs_v(7, 0, version, userInputs)
  doAssert result != nil
  doAssert pw_set_rules(result, LiveRules) == 0
  doAssert pw_set_config_json(result, cp(config), config.len.int32, nil, 0) == 0
  doAssert pw_set_seats(result, seats.int32) == 0
  doAssert pw_reset(result, 2026, ticks) == 0

proc script(h: pointer, seat: int, source: string) =
  doAssert pw_set_seat_script(h, seat.cint, cp(source), source.len.int32) == 0

proc ffaSource(): string = readFile(Root / "coworld/heartland/players/ffa.bas")

proc layoutOf(h: pointer): FfaViewLayout = ffaViewLayout(pw_seats(h).int, envOf(h).world.controlHearts.len)

proc shoutsOf(h: pointer, seat: int): seq[int32] =
  result = newSeq[int32](4)
  doAssert pw_seat_shouts(h, seat.cint, ip(result)) == 0

proc label(class: int): seq[int32] =
  ## pw_seat_shouts of a seat that said exactly ShoutVocabulary[class - 1] (nothing for 0).
  if class == 0: @[0'i32, 0, 0, 0] else: @[class.int32, int32(1 shl (class - 1)), 1, 0]

proc manifestFor(observation, action: string, decoder = ""): string =
  "{\"schema\": \"paintbot-neural-basic/2\", \"observation_contract\": \"" & observation &
    "\", \"action_contract\": \"" & action & "\"" & (if decoder.len > 0: ", \"decoder\": " & decoder else: "") & "}"

var bundleCount = 0
proc bundle(source, model: string, manifest = "", count = Seats): seq[Bot] =
  inc bundleCount
  let path = getTempDir() / ("paintbot-shout-" & $getCurrentProcessId() & "-" & $bundleCount & ".bas")
  writeFile(path, source)
  writeFile(path & ".model.bin", model)
  if manifest.len > 0: writeFile(path & ".neural.json", manifest)
  defer:
    removeFile(path)
    removeFile(path & ".model.bin")
    if manifest.len > 0: removeFile(path & ".neural.json")
  loadBots(@[BotGroup(path: path, count: count)])

proc loadError(model: string, manifest = ""): string =
  inc bundleCount
  let path = getTempDir() / ("paintbot-shout-load-" & $getCurrentProcessId() & "-" & $bundleCount & ".bas")
  writeFile(path, "")
  writeFile(path & ".model.bin", model)
  if manifest.len > 0: writeFile(path & ".neural.json", manifest)
  defer:
    removeFile(path)
    removeFile(path & ".model.bin")
    if manifest.len > 0: removeFile(path & ".neural.json")
  try:
    discard loadNeuralSeat(path, 0)
    ""
  except ValueError as e:
    e.msg

proc heardExpected(v: SeatView): seq[float32] =
  ## The heard rows re-derived from the SeatView procs (encodeFfaHeard's documented columns).
  result = newSeq[float32](FfaHeardSize)
  let spanX = float32(v.mapMaxX - v.mapMinX)
  let spanZ = float32(v.mapMaxY - v.mapMinY)
  for i in 0..<min(v.heardCount.int, FfaHeardRows):
    let o = i*FfaHeardWidth
    let text = v.heardText(i)
    result[o] = 1
    if text == "hurt": result[o+1] = 1
    elif text == "at": result[o+2] = 1
    else: result[o+3] = 1
    result[o+4] = float32(v.heardX(i) - v.selfX) / spanX
    result[o+5] = float32(v.heardY(i) - v.selfY) / spanZ
    let s = v.heardSlot(i).int
    if v.kin(s) >= 0: result[o+6] = float32(v.kin(s)) / 100
    result[o+7] = float32(s) / 255

suite "FFA speech: action contract ffa.view.1 pointer shout, observation contract ffa.view.1h":
  setup:
    visionRulesVersion = LiveRules
  teardown:
    configureSeats(LegacySeats)
    gameMode = gmTeams
    configureMap("")
    kinLayoutPin = none(KinLayout)

  test "ids, hashes, pairing, heads; every pre-existing contract hash unchanged":
    for (id, hash) in PreexistingHashes: check sha256Hex(id) == hash
    check ObservationContractTeamsView1Hash == PreexistingHashes[0][1]
    check ObservationContractFfaView1Hash == PreexistingHashes[1][1]
    check ActionContractTeamsView1Hash == PreexistingHashes[2][1]
    check ActionContractFfaView1PointerHash == PreexistingHashes[3][1]
    check ActionContractTeamsView1OffsetHash == PreexistingHashes[4][1]
    check ActionContractTeamsView1MoveHash == PreexistingHashes[5][1]
    for (version, i) in [(11'i32, 2), (12'i32, 3), (13'i32, 4), (14'i32, 5)]:
      check hashOf(proc(o: ptr UncheckedArray[char]): cint = pw_action_contract_hash(version, o, 65)) ==
        PreexistingHashes[i][1]
    check hashOf(proc(o: ptr UncheckedArray[char]): cint = pw_observation_contract_hash(201, o, 65)) ==
      PreexistingHashes[0][1]
    check hashOf(proc(o: ptr UncheckedArray[char]): cint = pw_observation_contract_hash(202, o, 65)) ==
      PreexistingHashes[1][1]
    # The shout action contract.
    check ActionContractFfaView1PointerShout == "paintbot-pw.ffa.view.1.action.pointer.shout-hurt-at"
    check ActionContractFfaView1PointerShoutHash == sha256Hex(ActionContractFfaView1PointerShout)
    check ActionContractFfaView1PointerShoutHash == "894ce29bf6ab31b035852e03a2b5d00e8a1222d12daf4fa3122541ad0867b63c"
    check acFfaView1PointerShout.int == 15
    check actionContractVersion(ActionContractFfaView1PointerShoutHash) == acFfaView1PointerShout
    check actionContractId(acFfaView1PointerShout) == ActionContractFfaView1PointerShout
    check actionContractHash(acFfaView1PointerShout) == ActionContractFfaView1PointerShoutHash
    check hashOf(proc(o: ptr UncheckedArray[char]): cint = pw_action_contract_hash(15, o, 65)) ==
      ActionContractFfaView1PointerShoutHash
    check hashOf(proc(o: ptr UncheckedArray[char]): cint = pw_action_contract_hash(16, o, 65)) == "ERR"
    check pairs(ocFfaView1, acFfaView1PointerShout) and pairs(ocFfaView1, acFfaView1Pointer)
    check not pairs(ocTeamsView1, acFfaView1PointerShout)
    check not pairs(ocFfaView1, acTeamsView1) and not pairs(ocFfaView1, acTeamsView1Move)
    check extraHeads(acFfaView1PointerShout) == 1 and extraHeads(acFfaView1Pointer) == 0
    let l = ffaViewLayout(16, 10)
    check pointerHeads(l, acFfaView1PointerShout) == pointerHeads(l) & @[3]
    check pointerHeads(l, acFfaView1Pointer) == pointerHeads(l)
    # The vocabulary: exactly ffa.bas's shout() texts.
    check ShoutVocabulary == ["hurt", "at"] and ShoutClasses == 3
    var said: seq[string]
    for line in ffaSource().splitLines:
      let at = line.find("shout(strNew(\"")
      if at >= 0: said.add line[at + 14 ..< line.find("\"", at + 14)]
    check said == @["hurt", "at"]
    check shoutClass("hurt") == 1 and shoutClass("at") == 2
    for other in ["", "Hurt", "hurt ", "at!", "Grenade out!"]: check shoutClass(other) == 0
    check shoutText(0) == "" and shoutText(1) == "hurt" and shoutText(2) == "at" and shoutText(3) == ""
    # The heard observation contracts: ffa.view.1h and ffa.view.1hu<K>, disjoint from every other family.
    check ObservationContractFfaView1Heard == "paintbot-pw.ffa.view.1h"
    check ObservationContractFfaView1HeardHash == "639e845831dc4d4da2914a2cd15d6b0d11d5c58f2cdf8928045043d673c2047c"
    check heardContractHash(0) == ObservationContractFfaView1HeardHash
    check heardContractId(7) == "paintbot-pw.ffa.view.1hu7" and heardContractHash(7) == sha256Hex("paintbot-pw.ffa.view.1hu7")
    check heardContractFromHash(heardContractHash(7)) == 7 and heardContractFromHash(heardContractHash(0)) == 0
    check heardContractFromHash(ObservationContractFfaView1Hash) == -1
    check heardContractFromHash(userInputsContractHash(7, ocFfaView1)) == -1
    check userInputsContract(heardContractHash(7))[1] == 0
    var seen: seq[string]
    for k in 0..MaxUserInputs:
      seen.add heardContractHash(k)
      if k > 0:
        seen.add userInputsContractHash(k)
        seen.add userInputsContractHash(k, ocFfaView1)
    seen.add ObservationContractTeamsView1Hash
    seen.add ObservationContractFfaView1Hash
    var unique = seen
    unique.sort()
    var unequal = 0
    for i, x in unique:
      if i == 0 or x != unique[i-1]: inc unequal
    check unequal == seen.len
    check hashOf(proc(o: ptr UncheckedArray[char]): cint = pw_observation_contract_hash(203, o, 65)) ==
      ObservationContractFfaView1HeardHash
    for k in 1'i32..MaxUserInputs.int32:
      check hashOf(proc(o: ptr UncheckedArray[char]): cint = pw_user_inputs_contract_hash_v(203, k, o, 65)) ==
        heardContractHash(k.int)
    check hashOf(proc(o: ptr UncheckedArray[char]): cint = pw_user_inputs_contract_hash_v(203, 0, o, 65)) == "ERR"
    check hashOf(proc(o: ptr UncheckedArray[char]): cint = pw_user_inputs_contract_hash_v(204, 1, o, 65)) == "ERR"
    check pw_create_observation(7, 0, 204) == nil
    check pw_create_observation_inputs_v(7, 0, 204, 3) == nil
    check pw_observation_size_for(203) == -1

  test "native ABI: contract 15 on ffa handles only; six heads; layout words 14/15 on 203":
    let h = heartland(16, HeartlandConfig, 24, 203)
    check pw_observation_contract(h) == 203 and pw_action_contract(h) == acFfaView1Pointer.cint
    let l = h.layoutOf
    check pw_handle_observation_size(h) == l.size + FfaHeardSize
    var words = newSeq[int32](ObservationLayoutWords)
    check pw_observation_layout(h, ip(words)) == 0
    check words == @[int32(l.size + FfaHeardSize), 24, 24, 15, 44, l.heartOffset.int32, l.heartRows.int32, 12,
      l.greatOffset.int32, 2, 12, 0, 16, l.heartRows.int32, l.size.int32, FfaHeardRows]
    check pw_set_action_contract(h, 15) == 0 and pw_action_contract(h) == 15
    var eight = newSeq[int32](8)
    check pw_action_layout(h, ip(eight)) == -1
    var ten = newSeq[int32](10)
    check pw_action_layout_ext(h, ip(ten)) == 0
    let heads = pointerHeads(l, acFfaView1PointerShout)
    var total = 0
    for x in heads: total += x
    check ten == @[6'i32, heads[0].int32, heads[1].int32, 2, 2, 2, 3, 0, total.int32, 0]
    check pw_reset(h, 2026, 24) == 0 and pw_action_contract(h) == 15  # kept across resets
    check pw_set_action_contract(h, 12) == 0
    check pw_set_action_contract(h, 13) == -1 and pw_set_action_contract(h, 16) == -1
    let u = heartland(16, HeartlandConfig, 24, 203, 3)
    check pw_observation_contract(u) == 203 and pw_handle_user_inputs(u) == 3
    check pw_handle_observation_size(u) == l.size + FfaHeardSize + 3
    pw_destroy(u)
    pw_destroy(h)
    let t = pw_create_observation(7, 24, 201)
    check pw_set_action_contract(t, 15) == -1
    var o = newSeq[int32](4)
    check pw_seat_shouts(t, 0, ip(o)) == 0 and o == @[0'i32, 0, 0, 0]
    check pw_seat_shouts(t, 16, ip(o)) == -1 and pw_seat_shouts(nil, 0, ip(o)) == -1
    check pw_set_seat_override(t, 0, 63) == 0 and pw_set_seat_override(t, 0, 64) == -1
    pw_destroy(t)

  test "decode: head-5 class c is BASIC's own shout of ShoutVocabulary[c - 1], tick for tick":
    # A: seat 0 caller-driven under contract 15 (stay, keep aim, head 5 = t mod 3). B: seat 0 a
    # plain BASIC script that stands still and shouts the same class. Every other seat runs
    # ffa.bas (which listens for "hurt"). Same world, same observations (heard rows included),
    # same speech labels, every tick.
    let a = heartland(16, HeartlandConfig, 240, 203)
    let b = heartland(16, HeartlandConfig, 240, 203)
    check pw_set_action_contract(a, 15) == 0
    let ffa = ffaSource()
    for seat in 1..<16:
      a.script(seat, ffa)
      b.script(seat, ffa)
    b.script(0, StayShout)
    let n = pw_handle_observation_size(a).int
    let l = a.layoutOf
    var oa = newSeq[float32](16*n)
    var ob = newSeq[float32](16*n)
    var resets = newSeq[float32](16)
    var actA = newSeq[int32](16*6)
    var actB = newSeq[int32](16*5)
    var rewards = newSeq[float32](16)
    var terminals = newSeq[float32](16)
    var heardFromZero, classMatched, spoke = 0
    for tick in 0..<240:
      check pw_observe(a, fp(oa), fp(resets)) == 0
      check pw_observe(b, fp(ob), fp(resets)) == 0
      require oa == ob
      for seat in 1..<16:
        for i in 0..<FfaHeardRows:
          let o = seat*n + l.size + i*FfaHeardWidth
          if oa[o] == 1 and oa[o+7] == 0:
            inc heardFromZero
            let c = (tick - 1) mod 3
            if c > 0 and oa[o+c] == 1: inc classMatched
      let c = tick mod 3
      actA[5] = c.int32
      let alive = envOf(a).world.cogs[0].hp > 0  # a dead seat's script and decoder do not run
      check pw_step(a, ip(actA), fp(rewards), fp(terminals)) == 0
      check pw_step(b, ip(actB), fp(rewards), fp(terminals)) == 0
      require pw_state_hash(a) == pw_state_hash(b)
      check a.shoutsOf(0) == (if alive: label(c) else: label(0))
      check a.shoutsOf(0) == b.shoutsOf(0)
      if alive and c > 0: inc spoke
      check envOf(a).decoderShouts[0] == (if alive and c > 0: @[shoutText(c)] else: newSeq[string]())
      for seat in 1..<16: check a.shoutsOf(seat) == b.shoutsOf(seat)
    check spoke > 100 and heardFromZero > 0 and classMatched > 0
    pw_destroy(a)
    pw_destroy(b)

  test "silent head 5 plays contract 12's match byte for byte; speech is delivered with no script":
    for (seats, config) in [(16, HeartlandConfig), (50, HeartlandBigConfig)]:
      let a = heartland(seats, config, 240)
      let b = heartland(seats, config, 240)
      check pw_set_action_contract(a, 15) == 0
      let ha = pointerHeads(a.layoutOf, acFfaView1PointerShout)
      let n = pw_handle_observation_size(a).int
      var oa = newSeq[float32](seats*n)
      var ob = newSeq[float32](seats*n)
      var resets = newSeq[float32](seats)
      var actA = newSeq[int32](seats*6)
      var actB = newSeq[int32](seats*5)
      var rewards = newSeq[float32](seats)
      var terminals = newSeq[float32](seats)
      var r = initRand(seats)
      for tick in 0..<200:
        check pw_observe(a, fp(oa), fp(resets)) == 0
        check pw_observe(b, fp(ob), fp(resets)) == 0
        require oa == ob
        for slot in 0..<seats:
          for head in 0..<5:
            let x = int32(r.rand(ha[head]-1))
            actA[slot*6+head] = x
            actB[slot*5+head] = x
          actA[slot*6+5] = 0
        check pw_step(a, ip(actA), fp(rewards), fp(terminals)) == 0
        check pw_step(b, ip(actB), fp(rewards), fp(terminals)) == 0
        require pw_state_hash(a) == pw_state_hash(b)
        for slot in 0..<seats: check a.shoutsOf(slot) == label(0)
      # Now every seat shouts at random: no seat listens, so the world is still the same, and
      # the speech reaches the seats in earshot (delivered although no script runs).
      var heardAny = false
      for tick in 0..<40:
        for slot in 0..<seats:
          for head in 0..<5:
            let x = int32(r.rand(ha[head]-1))
            actA[slot*6+head] = x
            actB[slot*5+head] = x
          actA[slot*6+5] = int32(r.rand(2))
        check pw_step(a, ip(actA), fp(rewards), fp(terminals)) == 0
        check pw_step(b, ip(actB), fp(rewards), fp(terminals)) == 0
        require pw_state_hash(a) == pw_state_hash(b)
        for slot in 0..<seats:
          let s = a.shoutsOf(slot)
          if s[2] > 0: check s == label(actA[slot*6+5].int)
          if envOf(a).scriptHeard[slot].len > 0: heardAny = true
      check heardAny
      check envOf(b).scriptCount == 0
      pw_destroy(a)
      pw_destroy(b)

  test "ffa.view.1h rows: ffa.view.1 byte for byte, then heard rows re-derived from the SeatView":
    for (seats, config, ticks) in [(16, HeartlandConfig, 240'i32), (50, HeartlandBigConfig, 120'i32)]:
      let h = heartland(seats, config, ticks, 203)
      let p = heartland(seats, config, ticks, 202)
      let u = heartland(seats, config, ticks, 203, 3)
      let ffa = ffaSource()
      for seat in 0..<seats:
        h.script(seat, ffa)
        p.script(seat, ffa)
        u.script(seat, ffa)
      let l = h.layoutOf
      let n = pw_handle_observation_size(h).int
      let np = pw_handle_observation_size(p).int
      let nu = pw_handle_observation_size(u).int
      check n == l.size + FfaHeardSize and np == l.size and nu == n + 3
      var oh = newSeq[float32](seats*n)
      var op = newSeq[float32](seats*np)
      var ou = newSeq[float32](seats*nu)
      var resets = newSeq[float32](seats)
      var actions = newSeq[int32](seats*5)
      var rewards = newSeq[float32](seats)
      var terminals = newSeq[float32](seats)
      var rows, hurt, at = 0
      for tick in 0..<ticks:
        check pw_observe(h, fp(oh), fp(resets)) == 0
        check pw_observe(p, fp(op), fp(resets)) == 0
        check pw_observe(u, fp(ou), fp(resets)) == 0
        heard = envOf(h).scriptHeard
        beginViews(envOf(h).world)
        for slot in 0..<seats:
          for i in 0..<np: require cast[uint32](oh[slot*n+i]) == cast[uint32](op[slot*np+i])
          for i in 0..<n: require cast[uint32](ou[slot*nu+i]) == cast[uint32](oh[slot*n+i])
          for j in 0..<3: require ou[slot*nu+n+j] == 0
          let want = heardExpected(seatView(slot))
          for i in 0..<FfaHeardSize: require cast[uint32](oh[slot*n+np+i]) == cast[uint32](want[i])
          for i in 0..<FfaHeardRows:
            let o = slot*n + np + i*FfaHeardWidth
            if oh[o] == 1:
              inc rows
              if oh[o+1] == 1: inc hurt
              if oh[o+2] == 1: inc at
        check pw_step(h, ip(actions), fp(rewards), fp(terminals)) == 0
        check pw_step(p, ip(actions), fp(rewards), fp(terminals)) == 0
        check pw_step(u, ip(actions), fp(rewards), fp(terminals)) == 0
        require pw_state_hash(h) == pw_state_hash(p) and pw_state_hash(u) == pw_state_hash(p)
      check rows > 0 and hurt > 0 and at > 0
      pw_destroy(h)
      pw_destroy(p)
      pw_destroy(u)

  test "pw_seat_shouts labels ffa.bas; override bit 32 makes a scripted seat say its decoder's class":
    # A: seat 0 runs ffa.bas under override 32 (contract 15, head 5 = t mod 3): it moves as
    # ffa.bas but says what head 5 says. B: seat 0 runs ffa.bas with its shout() calls removed
    # and the StayShout speech added. Same world, same observations, every tick; A's label is
    # still what ffa.bas said.
    let ffa = ffaSource()
    var muted = ffa.replace("shout(strNew(\"hurt\"))", "mutedHurt = 1").replace("shout(strNew(\"at\"))", "mutedAt = 1")
    check muted != ffa
    muted = "said = worldTick mod 3\nif said = 1 then\n  shout(strNew(\"hurt\"))\nend if\nif said = 2 then\n" &
      "  shout(strNew(\"at\"))\nend if\n" & muted
    let a = heartland(16, HeartlandConfig, 240, 203)
    let b = heartland(16, HeartlandConfig, 240, 203)
    check pw_set_action_contract(a, 15) == 0
    for seat in 0..<16:
      a.script(seat, ffa)
      b.script(seat, if seat == 0: muted else: ffa)
    check pw_set_seat_override(a, 0, 32) == 0
    let n = pw_handle_observation_size(a).int
    var oa = newSeq[float32](16*n)
    var ob = newSeq[float32](16*n)
    var resets = newSeq[float32](16)
    var actA = newSeq[int32](16*6)
    var actB = newSeq[int32](16*5)
    var rewards = newSeq[float32](16)
    var terminals = newSeq[float32](16)
    var scriptSpoke, differs = 0
    for tick in 0..<240:
      check pw_observe(a, fp(oa), fp(resets)) == 0
      check pw_observe(b, fp(ob), fp(resets)) == 0
      require oa == ob
      let c = tick mod 3
      actA[5] = c.int32
      check pw_step(a, ip(actA), fp(rewards), fp(terminals)) == 0
      check pw_step(b, ip(actB), fp(rewards), fp(terminals)) == 0
      require pw_state_hash(a) == pw_state_hash(b)
      let s = a.shoutsOf(0)
      if s[2] > 0:
        inc scriptSpoke
        check s[3] == 0 and s[0] in 1'i32..2'i32
        if s[0] != c.int32: inc differs
      check envOf(a).scriptShouts[0].len == s[2]
    check scriptSpoke > 0 and differs > 0
    # Bit 32 under contract 12 silences the seat: its decoder never shouts.
    let q = heartland(16, HeartlandConfig, 48, 202)
    for seat in 0..<16: q.script(seat, ffa)
    check pw_set_seat_override(q, 0, 32) == 0
    var oq = newSeq[float32](16*pw_handle_observation_size(q).int)
    var silenced = 0
    for tick in 0..<48:
      check pw_observe(q, fp(oq), fp(resets)) == 0
      check pw_step(q, ip(actB), fp(rewards), fp(terminals)) == 0
      check envOf(q).decoderShouts[0].len == 0
      if envOf(q).scriptShouts[0].len > 0: inc silenced
    pw_destroy(q)
    pw_destroy(a)
    pw_destroy(b)

  test "a policy seat under contract 15: head 5 drawn after the five, shouted through BASIC":
    let h = heartland(16, HeartlandConfig, 48, 202)
    check pw_set_action_contract(h, 15) == 0
    let man = manifestFor(ObservationContractFfaView1Hash, ActionContractFfaView1PointerShoutHash,
      """{"sampling": {"mode": "categorical", "temperature": 1.0, "heads": [5]}}""")
    check pw_set_seat_policy_script(h, 0, cp(PolicyFfa), PolicyFfa.len.int32, cp(man), man.len.int32) == 0
    let ffa = ffaSource()
    for seat in 1..<16: h.script(seat, ffa)
    let heads = pointerHeads(h.layoutOf, acFfaView1PointerShout)
    var width = 0
    for x in heads: width += x
    let n = pw_handle_observation_size(h).int
    var obs = newSeq[float32](16*n)
    var resets = newSeq[float32](16)
    var actions = newSeq[int32](16*6)
    var logits = newSeq[float32](16*width)
    var rewards = newSeq[float32](16)
    var terminals = newSeq[float32](16)
    var extra = newSeq[int32](12)
    var counts: array[3, int]
    for tick in 0..<48:
      check pw_observe(h, fp(obs), fp(resets)) == 0
      # Head 5's logits: "at" far ahead on even ticks, all equal on odd ticks (drawn).
      logits[width-3] = 0
      logits[width-2] = 0
      logits[width-1] = (if tick mod 2 == 0: 50'f32 else: 0'f32)
      check pw_step_logits(h, ip(actions), fp(logits), fp(rewards), fp(terminals)) == 0
      check pw_seat_policy_extra_choices(h, 0, ip(extra)) == 0
      if extra == newSeq[int32](12): continue  # the seat did not select (dead)
      let c = extra[4].int  # final head 5 (the decode read it)
      if tick mod 2 == 0: check c == 2
      check extra[8] == 1000  # temperature_milli5
      inc counts[c]
      check h.shoutsOf(0) == label(c)
    check counts[2] > 0 and counts[0] + counts[1] > 0
    pw_destroy(h)
    # The bundle's sampling heads: 5 under the shout contract; 6 never; 5 not under plain pointer.
    let p = heartland(16, HeartlandConfig, 24, 202)
    check pw_set_action_contract(p, 15) == 0
    let bad = manifestFor(ObservationContractFfaView1Hash, ActionContractFfaView1PointerShoutHash,
      """{"sampling": {"mode": "categorical", "heads": [6]}}""")
    check pw_set_seat_policy_script(p, 0, cp(PolicyFfa), PolicyFfa.len.int32, cp(bad), bad.len.int32) == 2
    pw_destroy(p)

  test "hosted ffa.view.1h + pointer shout: loads, observes heard rows, decodes head 5 into shout()":
    configureSeats(16)
    gameMode = gmFfaKin
    kinLayoutPin = some(klCousins)
    var r = initRand(15)
    let l = matchLayout()
    let heads = pointerHeads(l, acFfaView1PointerShout)
    var total = 0
    for x in heads: total += x
    let width = l.size + FfaHeardSize
    let heardHash = heardContractHash(0)
    let model = encode2(width, heads, [r.dense(width, total, bias = true)], heardHash, ActionContractFfaView1PointerShoutHash)
    let sampled = manifestFor(heardHash, ActionContractFfaView1PointerShoutHash,
      """{"sampling": {"mode": "categorical", "temperature": 1.0, "heads": [5]}}""")
    # Loader checks.
    check loadError(model) == "" and loadError(model, sampled) == ""
    check "ffa.view.1h layout" in loadError(encode2(l.size, heads, [r.dense(l.size, total)], heardHash,
      ActionContractFfaView1PointerShoutHash))
    check "ffa.view.1 layout" in loadError(encode2(l.size, pointerHeads(l), [r.dense(l.size, total - 3)],
      ObservationContractFfaView1Hash, ActionContractFfaView1PointerShoutHash))
    check "cannot be played under action contract" in loadError(encode2(width, ActionSizes,
      [r.dense(width, LogitSize)], heardHash, ActionContractTeamsView1Hash))
    check "heads 6, 7 and 8" in loadError(model, manifestFor(heardHash, ActionContractFfaView1PointerShoutHash,
      """{"sampling": {"mode": "categorical", "heads": [0, 6]}}"""))
    check "heads 5 and 6 need" in loadError(encode2(l.size, pointerHeads(l), [r.dense(l.size, total - 3)],
      ObservationContractFfaView1Hash, ActionContractFfaView1PointerHash), manifestFor(ObservationContractFfaView1Hash,
      ActionContractFfaView1PointerHash, """{"sampling": {"mode": "categorical", "heads": [5]}}"""))
    let k3 = encode2(width + 3, heads, [r.dense(width + 3, total)], heardContractHash(3), ActionContractFfaView1PointerShoutHash)
    check "observation contract ffa.view.1hu3 needs manifest user_inputs" in loadError(k3)
    let k3man = manifestFor(heardContractHash(3), ActionContractFfaView1PointerShoutHash)
    check loadError(k3, k3man[0 ..< ^1] & ", \"user_inputs\": {\"count\": 3, \"init\": [0, 0, 0]}}") == ""
    # Play: every seat is the bundle; each tick a live seat shouts exactly the class head 5 chose.
    var players = bundle(PolicyFfa, model, sampled, count = 16)
    for slot in 0..<16: check players[slot].neural.heads == heads and players[slot].neural.heard
    var w = newWorld(2026, 240)
    var counts: array[3, int]
    var heardRows = 0
    while w.winner == -1 and w.tick < w.endTick:
      let commands = players.decide(w)
      for slot in 0..<16:
        require not players[slot].failed
        if w.cogs[slot].hp <= 0: continue
        let seat = players[slot].neural
        check seat.observation.len == width
        let c = seat.offsetChoices[0].int
        inc counts[c]
        check shouts[slot] == (if c == 0: newSeq[string]() else: @[shoutText(c)])
        for i in 0..<FfaHeardRows:
          if seat.observation[l.size + i*FfaHeardWidth] == 1: inc heardRows
      deliverSpeech(w)
      w.step(commands)
    check counts[0] > 0 and counts[1] > 0 and counts[2] > 0 and heardRows > 0
