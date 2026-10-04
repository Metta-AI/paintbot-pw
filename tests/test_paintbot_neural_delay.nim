## DELAY (PWNET002 layer 16): an exact one-inference delay of a slice of the current vector. y = [x, prev]; prev =
## init on a fresh or zeroed state, else the slice x[offset ..< offset+len] the layer read on the previous inference.
## Its state slice (len + 1 floats: the slice, then a primed flag) sits in layer order with the MINGRU states and is
## committed only with them. Covers the loader's rules and cost; the forward semantics (first call, later calls,
## reset, state round trip, failed inference); a DELAY inside a stack and next to MINGRU against float32
## reimplementations; models without DELAY unchanged; and native rollouts through the training library (pw_net_load /
## pw_net_infer, state zeroed on pw_observe's reset flag as the trainers and the gate harness do) on Heartwick and a
## generated map, over deaths, respawns and a new match. Synthetic weights only.
## Build with --mm:arc --threads:on -d:pwTraining.
import std/[unittest, random, strutils, math]
import ../examples/paintbot/[kinship, neural_contract, neural_actor, native_env]
import paintbot_pwnet2_fixture

when not defined(pwTraining): {.error: "the native rollout part needs -d:pwTraining".}

type Buffer = ptr UncheckedArray[cfloat]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])
template ibuf(a: untyped): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr a[0])
template cbuf(s: string): ptr UncheckedArray[char] =
  (if s.len > 0: cast[ptr UncheckedArray[char]](unsafeAddr s[0]) else: nil)

proc rejects(data: string, fragment: string): bool =
  try:
    discard loadActor(data)
    false
  except ValueError as e:
    fragment in e.msg

proc obsOf(r: var Rand, n: int): seq[float32] =
  for i in 0..<n: result.add float32(r.rand(2.0) - 1.0)

proc dense32(x, w, b: openArray[float32], m: int, relu = false): seq[float32] =
  ## neural_actor's DENSE, term for term: a float32 sum from +0 over i ascending, then the bias (b empty: none).
  let n = x.len
  for o in 0..<m:
    var sum = 0'f32
    for i in 0..<n: sum += x[i]*w[o*n+i]
    if b.len > 0: sum = sum + b[o]
    if relu and not (sum > 0'f32): sum = 0'f32
    result.add sum

proc step(actor: Actor, obs: seq[float32], state: var seq[float32]): seq[float32] =
  result = newSeq[float32](actor.outputSize)
  actor.infer(obs, state, result)

proc fnv(h: var uint64, xs: openArray[float32]) =
  for x in xs:
    let b = cast[uint32](x)
    for k in 0..3:
      h = (h xor ((b shr (8*k)) and 255).uint64) * 0x100000001b3'u64

suite "DELAY loader":
  test "params, weights, state, cost":
    let init = @[0.5'f32, -1, 2, 0.25]
    let a = loadActor(encode2(10, [7, 7], [delay(3, 4, init)]))
    check a.stateSize == 5 and a.operationCount == 4 and a.parameterCount == 4 and a.layerCount == 1
    check a.modelTag == "pwnet2-l1-s5"
    var r = initRand(1601)
    let b = loadActor(encode2(10, [3, 3], [r.dense(10, 8), r.mingru(8, 8, highway = true), delay(2, 3, init[0..2]),
      r.dense(11, 6, bias = true)]))
    check b.stateSize == 8 + 3 + 1
    check b.operationCount == 2*10*8 + (2*8*3*8 + 32*8) + 3 + (2*11*6 + 6)

  test "the loader's checks":
    var r = initRand(1602)
    let tail = r.dense(14, 14)
    check rejects(encode2(10, [7, 7], [delay(0, 0, newSeq[float32]()), r.dense(10, 14)]), "DELAY slice outside the width 10")
    check rejects(encode2(10, [7, 7], [delay(7, 4, newSeq[float32](4)), tail]), "DELAY slice outside")
    check rejects(encode2(10, [7, 7], [delay(11, 1, newSeq[float32](1)), r.dense(11, 14)]), "DELAY slice outside")
    var spec = delay(3, 4, newSeq[float32](4))
    spec.params[2] = 1
    check rejects(encode2(10, [7, 7], [spec, tail]), "unused parameter 2 must be 0")
    check rejects(encode2(10, [7, 7], [delay(3, 4, newSeq[float32](3))]), "")           # short init
    check rejects(encode2(10, [7, 7], [delay(3, 4, newSeq[float32](5))]), "trailing")   # long init
    check rejects(encode2(10, [7, 7], [delay(3, 4, @[0'f32, NaN, 0, 0])]), "nonfinite neural weight")
    # State: 11 + 21 + ... + 1281 = 2558, then 1537 more = 4095 of 4096; one more DELAY (2 floats) is over.
    var chain: seq[Spec]
    var w = 10
    while w < 2560:
      chain.add delay(0, w, newSeq[float32](w))
      w *= 2
    chain.add delay(0, 1536, newSeq[float32](1536))
    let fits = chain & @[r.dense(4096, 10)]
    check loadActor(encode2(10, [5, 5], fits)).stateSize == 4095
    check rejects(encode2(10, [5, 6], fits & @[delay(0, 1, @[0'f32])]), "recurrent state exceeds 4096")
    check rejects(encode2(10, [5, 5], [r.dense(10, 4000), delay(0, 200, newSeq[float32](200)), r.dense(4200, 10)]),
      "DELAY output exceeds 4096")
    check rejects(encode2(10, [5, 5], [r.dense(10, 10), condHead(0, 1, newSeq[float32](25)),
      delay(0, 1, @[0'f32]), r.dense(11, 10)]), "COND_HEAD layers must come after every other layer")

suite "DELAY forward":
  test "first call reads init, later calls the previous slice, a zeroed state init again":
    var r = initRand(1603)
    let init = @[0.5'f32, -1, 2, 0.25]
    let a = loadActor(encode2(10, [7, 7], [delay(3, 4, init)]))
    var state = newSeq[float32](5)
    var prev: seq[float32]
    for t in 0..<60:
      if t in [17, 18, 40]:
        for x in state.mitems: x = 0
        prev = @[]
      let obs = r.obsOf(10)
      let y = a.step(obs, state)
      check bits(y[0 ..< 10]) == bits(obs)
      check bits(y[10 ..< 14]) == bits(if prev.len == 0: init else: prev)
      check bits(state) == bits(obs[3 ..< 7] & @[1'f32])
      prev = obs[3 ..< 7]

  test "the state is everything: a round trip through a fresh actor continues exactly; the flag decides":
    var r = initRand(1604)
    let init = r.weights(5, 1.0)
    let data = encode2(12, [8, 9], [delay(7, 5, init)])
    let a = loadActor(data)
    var state = newSeq[float32](6)
    for t in 0..<5: discard a.step(r.obsOf(12), state)
    var copy = state
    let b = loadActor(data)
    for t in 0..<10:
      let obs = r.obsOf(12)
      check bits(a.step(obs, state)) == bits(b.step(obs, copy))
      check bits(state) == bits(copy)
    let obs = r.obsOf(12)
    let m = @[1.5'f32, -2, 3, 0.125, 7]
    for flag in [1'f32, 2, -1, 1e-30]:   # any non-zero flag is primed
      var s = m & @[flag]
      check bits(a.step(obs, s)[12 ..< 17]) == bits(m)
    for flag in [0'f32, -0'f32]:
      var s = m & @[flag]
      check bits(a.step(obs, s)[12 ..< 17]) == bits(init)

  test "a failed inference commits no DELAY state":
    var r = initRand(1605)
    var big = r.dense(14, 6)
    let a = loadActor(encode2(10, [3, 3], [delay(0, 4, newSeq[float32](4)), big]))
    var state = newSeq[float32](5)
    discard a.step(r.obsOf(10), state)
    let before = state
    var bad = r.obsOf(10)
    bad[2] = NaN
    expect ValueError: discard a.step(bad, state)
    check bits(state) == bits(before)
    # A nonfinite intermediate after the DELAY ran: its staged state is not committed either.
    var huge = big
    for x in huge.tensors.mitems: x = 3e38
    let c = loadActor(encode2(10, [3, 3], [delay(0, 4, newSeq[float32](4)), huge]))
    var s = before
    expect ValueError: discard c.step(@[1'f32, 1, 1, 1, 1, 1, 1, 1, 1, 1], s)
    check bits(s) == bits(before)

  test "inside a stack: DENSE -> DELAY -> DENSE equals a float32 reimplementation":
    var r = initRand(1606)
    let d0 = r.dense(10, 6, bias = true, relu = true)
    let init = r.weights(3, 1.0)
    let d1 = r.dense(9, 5, bias = true)
    let a = loadActor(encode2(10, [2, 3], [d0, delay(1, 3, init), d1]))
    var state = newSeq[float32](a.stateSize)
    var prev: seq[float32]
    for t in 0..<40:
      if t == 25:
        for x in state.mitems: x = 0
        prev = @[]
      let obs = r.obsOf(10)
      let h = dense32(obs, d0.tensors[0 ..< 60], d0.tensors[60 ..< 66], 6, relu = true)
      let p = if prev.len == 0: init else: prev
      check bits(a.step(obs, state)) == bits(dense32(h & p, d1.tensors[0 ..< 45], d1.tensors[45 ..< 50], 5))
      prev = h[1 ..< 4]

  test "next to MINGRU: state in layer order, both recurrences exact":
    var r = initRand(1607)
    let d0 = r.dense(10, 8)
    let gru = r.mingru(8, 8, highway = true, bias = true)
    let init = r.weights(3, 1.0)
    let d1 = r.dense(11, 6, bias = true)
    let a = loadActor(encode2(10, [3, 3], [d0, gru, delay(2, 3, init), d1]))
    let plain = loadActor(encode2(10, [4, 4], [d0, gru]))          # the same weights, no DELAY
    check a.stateSize == 12 and plain.stateSize == 8
    var sa = newSeq[float32](12)
    var sp = newSeq[float32](8)
    var prev: seq[float32]
    for t in 0..<50:
      if t in [10, 33]:
        for x in sa.mitems: x = 0
        for x in sp.mitems: x = 0
        prev = @[]
      let obs = r.obsOf(10)
      let y = plain.step(obs, sp)
      let p = if prev.len == 0: init else: prev
      check bits(a.step(obs, sa)) == bits(dense32(y & p, d1.tensors[0 ..< 66], d1.tensors[66 ..< 72], 6))
      check bits(sa[0 ..< 8]) == bits(sp)
      check bits(sa[8 ..< 12]) == bits(y[2 ..< 5] & @[1'f32])
      prev = y[2 ..< 5]
    # DELAY first: its state comes first, the MINGRU's after it.
    let init2 = r.weights(4, 1.0)
    let e0 = r.dense(14, 8)
    let b = loadActor(encode2(10, [4, 4], [delay(0, 4, init2), e0, gru]))
    let ref2 = loadActor(encode2(14, [4, 4], [e0, gru]))
    var sb = newSeq[float32](13)
    var sr = newSeq[float32](8)
    prev = @[]
    for t in 0..<20:
      let obs = r.obsOf(10)
      let p = if prev.len == 0: init2 else: prev
      check bits(b.step(obs, sb)) == bits(ref2.step(obs & p, sr))
      check bits(sb[0 ..< 5]) == bits(obs[0 ..< 4] & @[1'f32])
      check bits(sb[5 ..< 13]) == bits(sr)
      prev = obs[0 ..< 4]

suite "models without DELAY are unchanged":
  # One model per pre-DELAY layer kind family (1..15) and PWNET001, fixed seeds. The integers (operations, state,
  # parameters, layers) are pinned on every platform; the logits and states over 40 inferences with a reset at 20
  # are pinned (FNV-1a over the bits) where the reference values were taken, Linux x86-64 (gcc, glibc: no FMA
  # contraction, the same exp), from paintbot-pw d32eb17's engine before DELAY existed.
  proc models(): seq[(string, string)] =
    var r = initRand(1608)
    result.add ("pwnet001", r.pwnet001(64, 64)[0])
    result.add ("every-core-kind", encode2(506, ActionSizes, [
      r.attention([[104'u32, 8, 16, 8, 0], [24'u32, 8, 10, 8, AttnAlwaysValid]], 32, 4, 1, 48, 0, 24),
      concat(448, 58), r.dense(2*32+24+58, 96, bias = true, relu = true), r.rmsnorm(96),
      r.mingru(96, 96, highway = true, bias = true), residual(3), r.mingru(96, 40, highway = false),
      r.dense(40, LogitSize, bias = true)]))
    result.add ("entity-factored", encode2(538, ActionSizes, r.entityFactored(d = 32, z = 16, hidden = 32)))
    result.add ("segment-near", encode2(538, ActionSizes,
      shifted(r.entityFactored(d = 32, z = 16, hidden = 32), identityNear(522))))
    result.add ("token-norm-pair-cond", encode2(56, [4, 5], [
      r.tokenMlp(6, [[0'u32, 8, 8], [48'u32, 0, 8]], 0, 0, [9], norm = true), concat(48, 8),
      r.tokenPair(0, 9, 4, 0, 8, 1, 2), r.tokenMix(2, 17, 60, 5, norm = true), r.dense(70, 9, bias = true),
      r.pointerHead(3, 2, 5), condHead(0, 1, r.weights(20, 1.0))]))
    result.add ("attnpool-pointerk-pad", encode2(64, [4, 30], [
      r.attention([[0'u32, 8, 8, 8, 0]], 8, 2, 1, 8, 0, 0), r.tokenMix(0, 8, 16, 6), r.attnPool(0, 28, 8, 2, 4, 3),
      r.dense(34, 10), pad(4, 24), r.pointerK(0, 4, 8, 3)]))

  const Pinned = [   # name, operations, state, parameters, layers, FNV-1a (Linux x86-64), from d32eb17's engine
    ("pwnet001", 45312'i64, 64, 21632, 3, 9522867052175402586'u64),
    ("every-core-kind", 637670'i64, 136, 61202, 8, 7602464062475122526'u64),
    ("entity-factored", 151614'i64, 32, 31027, 7, 6382265262580994703'u64),
    ("segment-near", 155352'i64, 32, 31027, 8, 2343674922970009433'u64),
    ("token-norm-pair-cond", 11995'i64, 0, 1352, 7, 16244214446357824563'u64),
    ("attnpool-pointerk-pad", 17894'i64, 0, 1395, 6, 8327079862116349237'u64)]

  test "integers everywhere, values on Linux x86-64":
    var r = initRand(1609)
    for (name, data) in models():
      let actor = loadActor(data)
      var h = 0xcbf29ce484222325'u64
      var state = newSeq[float32](actor.stateSize)
      for t in 0..<40:
        if t == 20:
          for x in state.mitems: x = 0
        let y = actor.step(r.observation(actor.inputSize), state)
        h.fnv(y)
        h.fnv(state)
      let got = (name, actor.operationCount.int64, actor.stateSize, actor.parameterCount, actor.layerCount, h)
      echo "golden ", got
      var found = false
      for p in Pinned:
        if p[0] != name: continue
        found = true
        check (p[1], p[2], p[3], p[4]) == (got[1], got[2], got[3], got[4])
        when defined(linux) and defined(amd64):
          check p[5] == got[5]
      check found

suite "DELAY on native rollouts (training library)":
  test "DELAY of the whole pw_observe row equals the row of the seat's previous inference; init after a reset":
    const BaseSource = staticRead("../examples/paintbot/players/base.bas")
    let source = BaseSource
    const K = 35
    let h = pw_create_observation_inputs_v(16_001, 2400, ocTeamsView1t.int32, K)
    require h != nil
    let width = pw_handle_observation_size(h).int
    require width == TeamsViewTSize + K
    var r = initRand(1610)
    let init = r.weights(width, 1.0)
    let first = min(1024, width)
    let model = encode2(width, [first, 2*width - first], [delay(0, width, init)])
    var err = newString(256)
    let net = pw_net_load(cbuf(model), model.len.int64, cast[ptr UncheckedArray[char]](addr err[0]), 256)
    require net != nil
    var info: array[8, int64]
    require pw_net_info(net, cast[ptr UncheckedArray[int64]](addr info[0])) == 0
    check info[3] == width + 1 and info[7] == width
    var rows = newSeq[float32](LegacySeats*width)
    var resets = newSeq[float32](LegacySeats)
    var actions = newSeq[int32](LegacySeats*ActionSizes.len)
    var rewards, terminals = newSeq[float32](LegacySeats)
    var logits = newSeq[float32](2*width)
    var states: array[LegacySeats, seq[float32]]
    var last: array[LegacySeats, seq[float32]]   # the row the seat's last inference read since its last reset
    var rows0, delayed, deaths, respawns, matches = 0
    var dead: array[LegacySeats, bool]
    # Heartwick (the rules' own island), a generated map, and a new match on it by pw_reset.
    for (map, seed) in [(-1'i32, 16_001'i32), (0'i32, 16_002'i32), (0'i32, 16_003'i32)]:
      require pw_set_map(h, map) == 0
      require pw_reset(h, seed, 2400) == 0
      inc matches
      for slot in 0..<LegacySeats:
        require pw_set_seat_script(h, slot.cint, cbuf(source), source.len.int32) == 0
        states[slot] = newSeq[float32](width + 1)
      for tick in 0..<2400:
        require pw_observe(h, fbuf(rows), fbuf(resets)) == 0
        for slot in 0..<LegacySeats:
          let row = rows[slot*width ..< (slot+1)*width]
          let isDead = row[2] <= 0   # teams.view.1 column 2: own hp
          if isDead and not dead[slot]: inc deaths
          if dead[slot] and not isDead: inc respawns
          dead[slot] = isDead
          if tick == 0: check resets[slot] > 0
          if resets[slot] > 0:   # the gate harness's rule (view_eval: st[s] = 0 when rst[s] > 0)
            for x in states[slot].mitems: x = 0
            last[slot] = @[]
          var row2 = row
          require pw_net_infer(net, fbuf(row2), fbuf(states[slot]), fbuf(logits)) == 0
          inc rows0
          check bits(logits[0 ..< width]) == bits(row)
          if last[slot].len == 0:
            check bits(logits[width ..< 2*width]) == bits(init)
          else:
            inc delayed
            check bits(logits[width ..< 2*width]) == bits(last[slot])
          last[slot] = row
        let code = pw_step(h, ibuf(actions), fbuf(rewards), fbuf(terminals))
        if code == -2 or terminals[0] == 1: break
        require code == 0
    echo "native DELAY rows=", rows0, " delayed=", delayed, " deaths=", deaths, " respawns=", respawns,
      " matches=", matches
    check delayed > 0 and deaths > 0 and respawns > 0
    pw_net_destroy(net)
    pw_destroy(h)
