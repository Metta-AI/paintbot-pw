## Synthetic PWNET002 builders for the tests (random weights; never trained weights).
import std/[random, math]
import ../examples/paintbot/neural_contract

proc u32*(s: var string, value: uint32) =
  for i in 0..3: s.add char((value shr (8*i)) and 255)
proc f32*(s: var string, value: float32) = s.u32(cast[uint32](value))

type Spec* = object
  code*: uint32
  params*: array[8, uint32]
  extra*: seq[uint32]      # ENTITY_ATTN group descriptors
  tensors*: seq[float32]

proc header2*(inputs: int, heads: openArray[int], layers: int,
    observationContract = ObservationContractHash, actionContract = ActionContractHash): string =
  result = "PWNET002"
  var outputs = 0
  for h in heads: outputs += h
  for x in [2, inputs, outputs, heads.len]: result.u32(x.uint32)
  for h in heads: result.u32(h.uint32)
  result.add observationContract
  result.add actionContract
  result.u32(layers.uint32)

proc encode2*(inputs: int, heads: openArray[int], specs: openArray[Spec],
    observationContract = ObservationContractHash, actionContract = ActionContractHash): string =
  result = header2(inputs, heads, specs.len, observationContract, actionContract)
  for spec in specs:
    result.u32(spec.code)
    for p in spec.params: result.u32(p)
    for x in spec.extra: result.u32(x)
    for x in spec.tensors: result.f32(x)

proc gauss*(r: var Rand, scale: float): float32 =
  float32(r.gauss(0.0, scale))
proc weights*(r: var Rand, n: int, scale: float): seq[float32] =
  for i in 0..<n: result.add r.gauss(scale)

proc dense*(r: var Rand, inputs, outputs: int, bias = false, relu = false, scale = -1.0): Spec =
  let s = if scale > 0: scale else: 1.0/sqrt(inputs.float)
  result = Spec(code: 1, params: [inputs.uint32, outputs.uint32, bias.uint32, relu.uint32, 0, 0, 0, 0])
  result.tensors = r.weights(inputs*outputs, s)
  if bias: result.tensors.add r.weights(outputs, 0.1)
proc rmsnorm*(r: var Rand, d: int, eps = 1e-5'f32): Spec =
  result = Spec(code: 2, params: [d.uint32, cast[uint32](eps), 0, 0, 0, 0, 0, 0])
  for i in 0..<d: result.tensors.add 1'f32 + r.gauss(0.1)
proc mingru*(r: var Rand, inputs, hidden: int, highway: bool, bias = false): Spec =
  let g = if highway: 3 else: 2
  result = Spec(code: 3, params: [inputs.uint32, hidden.uint32, highway.uint32, bias.uint32, 0, 0, 0, 0])
  result.tensors = r.weights(g*hidden*inputs, 1.0/sqrt(inputs.float))
  if bias: result.tensors.add r.weights(g*hidden, 0.1)
proc residual*(start: int): Spec = Spec(code: 4, params: [start.uint32, 0, 0, 0, 0, 0, 0, 0])
proc concat*(offset, length: int): Spec = Spec(code: 6, params: [offset.uint32, length.uint32, 0, 0, 0, 0, 0, 0])
proc attention*(r: var Rand, groups: openArray[array[5, uint32]], d, heads, blocks, ff, passOffset,
    passLength: int, eps = 1e-5'f32): Spec =
  result = Spec(code: 5, params: [groups.len.uint32, d.uint32, heads.uint32, blocks.uint32, ff.uint32,
    passOffset.uint32, passLength.uint32, cast[uint32](eps)])
  for g in groups:
    for x in g: result.extra.add x
  for g in groups:
    let width = g[3].int
    result.tensors.add r.weights(d*width, 1.0/sqrt(width.float))
    result.tensors.add r.weights(d, 0.1)
  for b in 0..<blocks:
    for i in 0..<d: result.tensors.add 1'f32 + r.gauss(0.1)
    result.tensors.add r.weights(3*d*d, 1.0/sqrt(d.float))
    result.tensors.add r.weights(3*d, 0.1)
    result.tensors.add r.weights(d*d, 1.0/sqrt(d.float))
    result.tensors.add r.weights(d, 0.1)
    for i in 0..<d: result.tensors.add 1'f32 + r.gauss(0.1)
    result.tensors.add r.weights(ff*d, 1.0/sqrt(d.float))
    result.tensors.add r.weights(ff, 0.1)
    result.tensors.add r.weights(d*ff, 1.0/sqrt(ff.float))
    result.tensors.add r.weights(d, 0.1)

proc tokenMlp*(r: var Rand, tokens: int, segments: openArray[array[3, uint32]], validSegment, validIndex: uint32,
    widths: openArray[int]): Spec =
  ## TOKEN_MLP: segments are (offset, stride, length); widths are the shared MLP's layer outputs.
  result = Spec(code: 7, params: [tokens.uint32, segments.len.uint32, validSegment, validIndex, widths.len.uint32,
    0, 0, 0])
  var n = 0
  for s in segments:
    for x in s: result.extra.add x
    n += s[2].int
  for o in widths: result.extra.add o.uint32
  for o in widths:
    result.tensors.add r.weights(o*n, 1.0/sqrt(n.float))
    result.tensors.add r.weights(o, 0.1)
    n = o
proc tokenMix*(r: var Rand, source, tokenIn, width, z: int): Spec =
  ## TOKEN_MIX: Ue [z, tokenIn], b [z], Uy [z, width].
  result = Spec(code: 8, params: [source.uint32, z.uint32, 0, 0, 0, 0, 0, 0])
  result.tensors = r.weights(z*tokenIn, 1.0/sqrt(tokenIn.float))
  result.tensors.add r.weights(z, 0.1)
  result.tensors.add r.weights(z*width, 1.0/sqrt(width.float))
proc pointerHead*(r: var Rand, source, offset, z: int): Spec =
  ## POINTER: v [z], c [1].
  result = Spec(code: 9, params: [source.uint32, offset.uint32, 0, 0, 0, 0, 0, 0])
  result.tensors = r.weights(z, 1.0/sqrt(z.float))
  result.tensors.add r.weights(1, 0.1)

const NoExclude* = 0xFFFF_FFFF'u32

proc segmentNear*(tokens, base, stride, x, z, valid: int, exclude: uint32, candidate: int,
    scaleX, scaleZ, radius: float32, dst, dstStride: int): Spec =
  ## SEGMENT_NEAR (parameter-free): the 8 params, then scale_x, scale_z, radius (FP32 bits), dst, dst_stride.
  result = Spec(code: 10, params: [tokens.uint32, base.uint32, stride.uint32, x.uint32, z.uint32, valid.uint32,
    exclude, candidate.uint32])
  result.extra = @[cast[uint32](scaleX), cast[uint32](scaleZ), cast[uint32](radius), dst.uint32, dstStride.uint32]

proc identityNear*(dst: int, radius = 150'f32): Spec =
  ## The identity block of contract v1/v2 (16 tokens of 8 at 104; x 1, z 2, flag 0, "is self" 6, relative team 3),
  ## "an observed teammate within `radius` of the segment to this identity", flags at dst ..< dst+16.
  segmentNear(16, 104, 8, 1, 2, 0, 6, 3, 16000, 9600, radius, dst, 1)

proc shifted*(specs: seq[Spec], first: Spec): seq[Spec] =
  ## `first` as layer 0 in front of specs, with the TOKEN_MIX / POINTER sources renumbered.
  result = @[first]
  for s in specs:
    var t = s
    if t.code in [4'u32, 8, 9]: t.params[0] += 1
    result.add t

const
  ## The per-identity token of an entity-factored actor over contract v2u32: identity j's 8 floats, its 2 terrain
  ## floats, the seat's own 24 + 2 (shared: stride 0) and two user inputs of its own (506+j, 522+j).
  IdentityTokenSegments* = [[104'u32, 8, 8], [470'u32, 2, 2], [0'u32, 0, 24], [448'u32, 0, 2], [506'u32, 1, 1],
    [522'u32, 1, 1]]

proc entityFactored*(r: var Rand, inputs = 538, d = 128, z = 64, hidden = 128,
    segments: openArray[array[3, uint32]] = IdentityTokenSegments): seq[Spec] =
  ## TOKEN_MLP -> CONCAT_INPUT -> DENSE -> MINGRU -> TOKEN_MIX -> DENSE -> POINTER into the 16 aim identities.
  @[r.tokenMlp(16, segments, 0, 0, [d, d]),
    concat(0, inputs),
    r.dense(2*d + inputs, hidden),
    r.mingru(hidden, hidden, highway = true),
    r.tokenMix(0, d, hidden, z),
    r.dense(hidden + 2*z, LogitSize, bias = true),
    r.pointerHead(4, 52, z)]

proc pwnet001*(r: var Rand, inputs, hidden: int): (string, seq[float32], seq[float32], seq[float32]) =
  let e = r.weights(inputs*hidden, 1.0/sqrt(inputs.float))
  let rec = r.weights(3*hidden*hidden, 1.0/sqrt(hidden.float))
  let dec = r.weights(LogitSize*hidden, 1.0/sqrt(hidden.float))
  var s = "PWNET001"
  for x in [1, inputs, hidden, LogitSize, ActionSizes.len, e.len+rec.len+dec.len]: s.u32(x.uint32)
  s.add ObservationContractHash
  s.add ActionContractHash
  for x in ActionSizes: s.u32(x.uint32)
  for t in [e, rec, dec]:
    for x in t: s.f32(x)
  (s, e, rec, dec)

proc bits*(xs: openArray[float32]): seq[uint32] =
  for x in xs: result.add cast[uint32](x)

proc observation*(r: var Rand, n: int): seq[float32] =
  result = newSeq[float32](n)
  for i in 0..<n:
    # Mostly features in [-1, 1] with 0/1 flags, as the contract encodes them.
    result[i] = if r.rand(1.0) < 0.3: float32(r.rand(1)) else: float32(r.rand(2.0) - 1.0)

proc nearScene*(r: var Rand, obs: var seq[float32], tokens = 16, base = 104, stride = 8, grid = 32.0) =
  ## Contract v1/v2 identity-block geometry for SEGMENT_NEAR tests: per token a 0/1 presence flag (+0), x and z
  ## on a 1/grid lattice so exact ties (d = 0, d = L2, distance = radius) occur (+1, +2), a relative team of +1 / -1
  ## (+3), and "is self" on token 0 (+6).
  for n in 0..<tokens:
    let at = base + n*stride
    obs[at] = float32(r.rand(9) < 7)
    obs[at+1] = float32(float(r.rand(16) - 8) / grid)
    obs[at+2] = float32(float(r.rand(16) - 8) / grid)
    obs[at+3] = if r.rand(1) == 0: 1'f32 else: -1'f32
    obs[at+6] = float32(n == 0)

proc nearFlagsReference*(spec: Spec, obs: openArray[float32]): seq[float32] =
  ## An independent float64 SEGMENT_NEAR (neural_actor.md), straight from the spec's words: the flags, in order.
  let p = spec.params
  let t = p[0].int
  let scaleX = cast[float32](spec.extra[0]).float64
  let scaleZ = cast[float32](spec.extra[1]).float64
  let radius = cast[float32](spec.extra[2]).float64
  var valid, cand: seq[bool]
  var vx, vz: seq[float64]
  for n in 0..<t:
    let at = p[1].int + n*p[2].int
    let ok = obs[at + p[5].int] > 0.5 and not (p[6] != NoExclude and obs[at + p[6].int] > 0.5)
    valid.add ok
    cand.add(ok and obs[at + p[7].int] > 0.5)
    vx.add obs[at + p[3].int].float64 * scaleX
    vz.add obs[at + p[4].int].float64 * scaleZ
  for n in 0..<t:
    var flag = false
    let l2 = vx[n]*vx[n] + vz[n]*vz[n]
    if valid[n] and l2 > 0:
      for m in 0..<t:
        if not cand[m]: continue
        let d = vx[m]*vx[n] + vz[m]*vz[n]
        if 0 <= d and d <= l2 and (vx[m]*vx[m] + vz[m]*vz[m]) - d*d/l2 <= radius*radius:
          flag = true
          break
    result.add float32(flag)

proc withNearFlags*(spec: Spec, obs: seq[float32]): seq[float32] =
  ## The observation as SEGMENT_NEAR's view: the reference flags written at dst + n*dst_stride.
  result = obs
  let flags = nearFlagsReference(spec, obs)
  for n, f in flags: result[spec.extra[3].int + n*spec.extra[4].int] = f
