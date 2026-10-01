## pw_world_save / pw_world_load (training library only): a match saved at tick t and loaded into a fresh handle
## continues exactly as the original does for K = 600 ticks (every pw_state_hash, every scripted seat's orders,
## every policy seat's choices, the seats' telemetry), for scripted, caller-driven and policy matches (contracts
## 11, 13 and 14) saved at ticks 1, 137, 600, just before a respawn and mid grenade flight, and for FFA-kin on a
## generated map; saves are deterministic and save -> load -> save is byte-identical; refusals return a code and
## leave the handle unchanged. Prints BLOBSHA lines so two machines' saves can be compared.
## Build with --mm:arc --threads:on -d:pwTraining.
import std/[unittest, os, random, importutils]
import ../examples/paintbot/[sim, neural_contract, native_env, contract_hash]

when not defined(pwTraining): {.error: "world snapshots exist only under -d:pwTraining".}

const Root = currentSourcePath().parentDir.parentDir
const Base = Root / "coworld/paintbot/players/base.bas"
const K = 600
type Buffer = ptr UncheckedArray[cfloat]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])
template ibuf(a: untyped): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr a[0])
template cbuf(s: string): ptr UncheckedArray[char] = cast[ptr UncheckedArray[char]](unsafeAddr s[0])
privateAccess(NativeEnv)

proc save(h: pointer): seq[byte] =
  let n = pw_world_save(h, nil, 0)
  doAssert n > 0
  result = newSeq[byte](n)
  doAssert pw_world_save(h, cast[ptr UncheckedArray[byte]](addr result[0]), n) == n

proc load(h: pointer, b: seq[byte]): cint =
  result = pw_world_load(h, cast[ptr UncheckedArray[byte]](unsafeAddr b[0]), b.len.int64)
  if result != 0:
    var msg: array[512, char]
    discard pw_world_load_error(cast[ptr UncheckedArray[char]](addr msg[0]), 512)
    echo "  pw_world_load ", result, ": ", $cast[cstring](addr msg[0])

proc sha(b: seq[byte]): string =
  var s = newString(b.len)
  if b.len > 0: copyMem(addr s[0], unsafeAddr b[0], b.len)
  sha256Hex(s)

type Kind = enum kScripted, kCaller, kPolicy11, kPolicy13, kPolicy14

proc contractOf(kind: Kind): int32 =
  case kind
  of kPolicy13: 13
  of kPolicy14: 14
  else: 11
proc heads(kind: Kind): int =
  case kind
  of kPolicy13: 7
  of kPolicy14: 9
  else: 5
proc logitWidth(kind: Kind): int =
  case kind
  of kPolicy13: 128
  of kPolicy14: 174
  else: 82
proc isPolicy(kind: Kind): bool = kind in {kPolicy11, kPolicy13, kPolicy14}

proc manifest(kind: Kind): string =
  let action = case kind
    of kPolicy13: ActionContractTeamsView1OffsetHash
    of kPolicy14: ActionContractTeamsView1MoveHash
    else: ActionContractTeamsView1Hash
  """{"schema": "paintbot-neural-basic/2", "observation_contract": """" & ObservationContractTeamsView1Hash &
    """", "action_contract": """" & action & """", "decoder": {"sampling": {"mode": "categorical"}}}"""

proc setup(kind: Kind, seed, ticks: int32): pointer =
  result = pw_create(seed, ticks)
  doAssert result != nil
  let base = readFile(Base)
  if kind.isPolicy: doAssert pw_set_action_contract(result, kind.contractOf) == 0
  case kind
  of kScripted:
    for s in 0..<Seats: doAssert pw_set_seat_script(result, s.cint, cbuf(base), base.len.int32) == 0
  of kCaller: discard
  of kPolicy11, kPolicy13, kPolicy14:
    let pol = "paintbot_observe(neuralObservation())\nrun_neural_net(neuralModel(), neuralObservation(), neuralLogits(), neuralState())\nneuralSample()\n" &
      readFile(Root / "examples/paintbot/players/neural_decode.bas")
    let man = manifest(kind)
    for s in 0..<Seats:
      if s mod 2 == 0:
        doAssert pw_set_seat_policy_script(result, s.cint, cbuf(pol), pol.len.int32, cbuf(man), man.len.int32) == 0
      else:
        doAssert pw_set_seat_script(result, s.cint, cbuf(base), base.len.int32) == 0

proc tick(h: pointer, kind: Kind, r: var Rand, rec: var seq[uint32]): bool =
  ## One step; false once the match has ended. Records the state hash, orders and policy choices.
  let hs = kind.heads
  var actions = newSeq[int32](LegacySeats*hs)
  var logits = newSeq[cfloat](LegacySeats*kind.logitWidth)
  var rewards, terminals = newSeq[cfloat](LegacySeats)
  var orders: array[10, int32]
  var ch: array[22, int32]
  var extra: array[12, int32]
  var rc: cint
  case kind
  of kScripted: rc = pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals))
  of kCaller:
    for s in 0..<LegacySeats:
      for k, n in ActionSizes: actions[s*5+k] = int32(r.rand(n-1))
    rc = pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals))
  of kPolicy11, kPolicy13, kPolicy14:
    for i in 0..<logits.len: logits[i] = cfloat(r.gauss(0.0, 1.5))
    rc = pw_step_logits(h, ibuf(actions), fbuf(logits), fbuf(rewards), fbuf(terminals))
  doAssert rc == 0, $rc
  rec.add pw_state_hash(h)
  for s in 0..<LegacySeats:
    if pw_seat_orders(h, s.cint, ibuf(orders)) == 0:
      for v in orders: rec.add cast[uint32](v)
    if kind.isPolicy and s mod 2 == 0:
      doAssert pw_seat_policy_choices(h, s.cint, ibuf(ch)) == 0
      for v in ch: rec.add cast[uint32](v)
      if kind != kPolicy11:
        doAssert pw_seat_policy_extra_choices(h, s.cint, ibuf(extra)) == 0
        for v in extra: rec.add cast[uint32](v)
  terminals[0] != 1

proc play(h: pointer, kind: Kind, ticks: int, rngSeed: int): seq[uint32] =
  var r = initRand(rngSeed)
  for t in 0..<ticks:
    if not h.tick(kind, r, result): break
  var stats: array[LegacySeats*8, int32]
  doAssert pw_seat_stats(h, ibuf(stats)) == 0
  for v in stats: result.add cast[uint32](v)
  var eight: array[8, int32]
  var six: array[6, int32]
  for s in 0..<LegacySeats:
    doAssert pw_seat_grenade_stats(h, s.cint, ibuf(six)) == 0
    doAssert pw_seat_equip_stats(h, s.cint, ibuf(eight)) == 0
    for v in six: result.add cast[uint32](v)
    for v in eight: result.add cast[uint32](v)

type At = enum at1, at137, at600, atRespawn, atGrenade

proc runTo(h: pointer, kind: Kind, at: At): int =
  ## Plays the match to the save point; returns the tick it stopped at (-1: the point never came).
  var r = initRand(7)
  var rec: seq[uint32]
  let env = cast[ptr NativeEnv](h)
  for t in 1..2000:
    if not h.tick(kind, r, rec): return -1
    case at
    of at1: (if t == 1: return t)
    of at137: (if t == 137: return t)
    of at600: (if t == 600: return t)
    of atRespawn:
      for i in 0..<env.n:
        if env.world.cogs[i].hp <= 0 and env.world.cogs[i].respawn == 1: return t
    of atGrenade:
      if env.world.grenades.len > 0: return t
  -1

suite "World snapshots":
  configureRules(NativeRules)

  for kind in Kind:
    for at in At:
      test "save " & $at & ", load into a fresh handle: the next " & $K & " ticks are identical (" & $kind & ")":
        let a = setup(kind, 51, 2400)
        defer: pw_destroy(a)
        let t = a.runTo(kind, at)
        require t > 0
        let blob = save(a)
        check save(a) == blob                       # deterministic, and a save is a pure read
        echo "  BLOBSHA ", kind, " ", at, " t=", t, " ", sha(blob)
        let expected = a.play(kind, K, 99)
        let b = setup(kCaller, 52, 2400)            # another seed, no scripts: the blob brings everything
        defer: pw_destroy(b)
        if kind.isPolicy: check pw_set_action_contract(b, kind.contractOf) == 0
        check load(b, blob) == 0
        check save(b) == blob                       # save -> load -> save
        check b.play(kind, K, 99) == expected

  test "FFA-kin on a generated map (ffa.bas seats, ffa.view.1): save mid-match, load, identical continuation":
    let ffaSrc = readFile(Root / "coworld/paintbot/players/ffa.bas")
    let a = pw_create_observation(61, 2400, 202)
    require a != nil
    defer: pw_destroy(a)
    require pw_set_game_mode(a, 1) == 0 and pw_set_map(a, 1) == 0 and pw_reset(a, 61, 2400) == 0
    require pw_game_mode(a) == 1 and pw_map(a) == 1
    for s in 0..<Seats: require pw_set_seat_script(a, s.cint, cbuf(ffaSrc), ffaSrc.len.int32) == 0
    discard a.play(kScripted, 250, 3)
    let blob = save(a)
    check save(a) == blob
    echo "  BLOBSHA ffa t=250 ", sha(blob)
    let expected = a.play(kScripted, K, 4)
    let b = pw_create_observation(62, 2400, 202)   # teams mode, the island: the blob brings the FFA-kin world
    require b != nil
    defer: pw_destroy(b)
    check load(b, blob) == 0
    check pw_game_mode(b) == 1 and pw_map(b) == 1
    check save(b) == blob
    check b.play(kScripted, K, 4) == expected

  test "refusals: another build, observation version or seat count, a bad magic, truncated or corrupt blobs; the handle is unchanged":
    let a = setup(kScripted, 71, 2400)
    defer: pw_destroy(a)
    discard a.play(kScripted, 50, 1)
    let blob = save(a)
    let b = setup(kScripted, 72, 2400)
    defer: pw_destroy(b)
    discard b.play(kScripted, 20, 2)
    let before = save(b)
    # another observation version
    let ffa = pw_create_observation(71, 2400, 202)
    require ffa != nil
    defer: pw_destroy(ffa)
    check load(ffa, blob) == -2
    # another seat count (an FFA-kin handle with 24 seats, a 16-seat FFA-kin blob)
    let f16 = pw_create_observation(73, 2400, 202)
    require f16 != nil
    defer: pw_destroy(f16)
    require pw_set_game_mode(f16, 1) == 0 and pw_reset(f16, 73, 2400) == 0
    let f24 = pw_create_observation(74, 2400, 202)
    require f24 != nil
    defer: pw_destroy(f24)
    require pw_set_game_mode(f24, 1) == 0 and pw_set_seats(f24, 24) == 0 and pw_reset(f24, 74, 2400) == 0
    let f24before = save(f24)
    check load(f24, save(f16)) == -2
    check save(f24) == f24before
    # a bad magic, another build id (byte 40 lies inside the build id string)
    var bad = blob
    bad[0] = byte('X')
    check load(b, bad) == -2
    var other = blob
    other[40] = if other[40] == byte('0'): byte('1') else: byte('0')
    check load(b, other) == -2
    check save(b) == before
    # truncated anywhere
    for k in 1..32:
      let cut = blob.len * k div 33
      check load(b, blob[0 ..< cut]) == -3
    check save(b) == before
    # corrupt lengths or values anywhere past the header: the checksum trailer refuses every one
    for k in 1..32:
      var corrupt = blob
      let at = 96 + (blob.len - 104) * k div 33
      for i in at ..< at+8: corrupt[i] = 0xff
      check load(b, corrupt) == -3
    check save(b) == before
    check pw_world_load(nil, nil, 0) == -1
    check pw_world_save(nil, nil, 0) == -1
    check pw_world_save(b, nil, -1) == -1
