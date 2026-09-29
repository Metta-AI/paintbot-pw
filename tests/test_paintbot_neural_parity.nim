## Parity of the fixed-width neural contracts across engine changes. Every observation
## contract with a fixed width (v1, v2, v3, v2u<K>, ffa.v1) and both action contracts (v1, v2)
## are driven through the training library for a few hundred ticks with seeded actions, the
## decoder options on some seats, a scripted seat and a mid-match reset; every observation
## row, reset flag, action candidate, terminal, tick, winner and world hash is folded into one
## FNV-1a digest per scenario. The digests were recorded on origin/main 0ff41d2 (before
## observation contract ffa.v2 and N-seat handles); an engine change that moves any byte a
## fixed contract's policy sees or any decoded command fails here.
import std/[unittest, os, strutils]
import ../examples/paintbot/[sim, neural_contract, native_env]

const Root = currentSourcePath().parentDir.parentDir

type Digest = object
  h: uint64

proc init(): Digest = Digest(h: 0xcbf29ce484222325'u64)
proc add(d: var Digest, p: pointer, n: int) =
  let bytes = cast[ptr UncheckedArray[uint8]](p)
  for i in 0..<n:
    d.h = (d.h xor bytes[i].uint64) * 0x100000001b3'u64
proc add[T](d: var Digest, v: T) =
  var x = v
  d.add(addr x, sizeof(T))
proc add[T](d: var Digest, s: seq[T]) =
  if s.len > 0: d.add(unsafeAddr s[0], s.len*sizeof(T))

proc fp(buffer: var seq[float32]): ptr UncheckedArray[cfloat] =
  cast[ptr UncheckedArray[cfloat]](addr buffer[0])
proc ip(buffer: var seq[int32]): ptr UncheckedArray[int32] =
  cast[ptr UncheckedArray[int32]](addr buffer[0])

type Scenario = object
  name: string
  obs, contract, inputs: int32
  ffa: bool
  rules: int32  # 0 = the library default
  map: int32    # -1 = the rules' own island
  options: bool # decoder options on seats 2..7

proc script(name: string): string = readFile(Root / "coworld/paintbot/players" / name)

var steps: int  # pw_step calls that stepped, for the print mode

proc run(s: Scenario): uint64 =
  var d = init()
  steps = 0
  let h = if s.inputs > 0: pw_create_observation_inputs_v(7, 0, s.obs, s.inputs)
          else: pw_create_observation(7, 0, s.obs)
  doAssert h != nil
  if s.ffa: doAssert pw_set_game_mode(h, 1) == 0
  if s.rules > 0: doAssert pw_set_rules(h, s.rules) == 0
  doAssert pw_set_map(h, s.map) == 0
  doAssert pw_set_action_contract(h, s.contract) == 0
  if s.options:
    doAssert pw_set_seat_strafe(h, 2, 5250, 3, 6, 6, 9, 800) == 0
    doAssert pw_set_seat_aim_snap(h, 3, 22500) == 0
    doAssert pw_set_seat_steady_shot(h, 4, 1) == 0
    doAssert pw_set_seat_aim_retarget(h, 5, 1, 5250, 160000, 2500000) == 0
    doAssert pw_set_seat_shot_gate(h, 6, 5250) == 0
    doAssert pw_set_seat_fire_hold(h, 7, 1) == 0
  let source = script(if s.ffa: "ffa.bas" else: "base.bas")
  doAssert pw_reset(h, 2026, 360) == 0
  doAssert pw_set_seat_script(h, 9, cast[ptr UncheckedArray[char]](unsafeAddr source[0]), source.len.int32) == 0
  let width = pw_handle_observation_size(h).int
  var obs = newSeq[float32](LegacySeats*width)
  var resets = newSeq[float32](LegacySeats)
  var actions = newSeq[int32](LegacySeats*ActionSizes.len)
  var rewards = newSeq[float32](LegacySeats)
  var terminals = newSeq[float32](LegacySeats)
  var goals = newSeq[int32](ActionSizes[0]*2)
  var aims = newSeq[int32](ActionSizes[1]*2)
  var results = newSeq[float32](8)
  var rng = 0x9E3779B97F4A7C15'u64
  proc draw(rng: var uint64, n: int): int32 =
    rng = rng * 6364136223846793005'u64 + 1442695040888963407'u64
    int32((rng shr 33) mod uint64(n))
  for episode in 0..1:
    if episode == 1: doAssert pw_reset(h, 2027, 240) == 0
    for tick in 0..<400:
      doAssert pw_observe(h, fp(obs), fp(resets)) == 0
      d.add obs
      d.add resets
      for slot in 0..<LegacySeats:
        let o = slot*ActionSizes.len
        actions[o] = draw(rng, ActionSizes[0])
        actions[o+1] = draw(rng, ActionSizes[1])
        actions[o+2] = int32(draw(rng, 3) == 0)
        actions[o+3] = int32(draw(rng, 20) == 0)
        actions[o+4] = int32(draw(rng, 8) == 0)
      let probe = tick mod LegacySeats
      doAssert pw_action_candidates(h, probe.cint, actions[probe*ActionSizes.len],
        actions[probe*ActionSizes.len+4], ip(goals), ip(aims)) == 0
      d.add goals
      d.add aims
      let code = pw_step(h, ip(actions), fp(rewards), fp(terminals))
      d.add code
      if code != 0: break
      inc steps
      # Rewards stay out of the digest: the FFA reward sums float64 products a C compiler may
      # fuse (FMA) on some targets, and the world hash below already pins what was played.
      d.add terminals
      d.add pw_state_hash(h)
      doAssert pw_results(h, fp(results)) == 0
      d.add results[0 .. 1]  # tick and winner (the FFA scores are float sums, like the rewards)
  pw_destroy(h)
  d.h

const Scenarios = [
  Scenario(name: "v1 obs, v1 actions, teams", obs: 1, contract: 1, map: -1, options: true),
  Scenario(name: "v2 obs, v2 actions, teams, rules 47", obs: 2, contract: 2, rules: 47, map: -1, options: true),
  Scenario(name: "v3 obs, v2 actions, teams, rules 47, crater", obs: 3, contract: 2, rules: 47, map: 3, options: true),
  Scenario(name: "v2u4 obs, v1 actions, teams", obs: 2, inputs: 4, contract: 1, map: -1),
  Scenario(name: "v3u2 obs, v2 actions, teams, rules 47", obs: 3, inputs: 2, contract: 2, rules: 47, map: -1),
  Scenario(name: "ffa.v1 obs, v1 actions, FFA-kin", obs: 101, contract: 1, ffa: true, map: -1),
  Scenario(name: "ffa.v1 obs, v2 actions, FFA-kin, rules 47", obs: 101, contract: 2, ffa: true, rules: 47, map: -1, options: true),
  Scenario(name: "ffa.v1 obs, v2 actions, FFA-kin, rules 47, twin-mesas", obs: 101, contract: 2, ffa: true, rules: 47, map: 0)]

# Recorded on origin/main 0ff41d2 (PWPARITY_PRINT=1 prints them).
const Golden: array[Scenarios.len, uint64] = [
  0xDF80AC7227887D07'u64, 0xD04F07C05217E7A1'u64, 0xAAD92B85A1D61D66'u64, 0xC49A997E0E75C672'u64,
  0xE2BF1FE51D49FC45'u64, 0x2BB355999AFDA0FB'u64, 0x66C91BEE84EB8CF8'u64, 0xF729E5FF6B53E866'u64]

suite "Fixed-width neural contracts are byte-identical":
  for i, s in Scenarios:
    test s.name:
      let digest = run(s)
      if existsEnv("PWPARITY_PRINT"): echo "  ", s.name, ": 0x", digest.toHex, " (", steps, " steps)"
      check digest == Golden[i]

  test "the teams game at rules 48 plays and observes exactly as at rules 47":
    # Rules 48 (the FFA-kin fog of war) changes nothing in the teams game.
    var teams48 = Scenarios[1]
    teams48.rules = 48
    check run(teams48) == Golden[1]
    var v3at48 = Scenarios[2]
    v3at48.rules = 48
    check run(v3at48) == Golden[2]
