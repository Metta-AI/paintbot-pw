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
