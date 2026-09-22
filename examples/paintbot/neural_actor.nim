## Restricted FP32 PufferLib actor, no training framework dependency.
## Equations match PufferLib 6ffa5b10 src/algo.cu (MIT); see neural_actor.md.
import std/[math, os]

type
  Actor* = ref object
    inputSize*, hiddenSize*, outputSize*: int
    headSizes*: seq[int]
    observationContract*, actionContract*: string
    encoder, recurrent, decoder: seq[float32]

const
  ActorMagic* = "PWNET001"
  MaxActorParameters* = 2_000_000

proc finite(x: float32): bool = classify(x) notin {fcNan, fcInf, fcNegInf}
proc readU32(data: string, pos: var int): uint32 =
  if pos + 4 > data.len: raise newException(ValueError, "truncated neural actor")
  for i in 0..3: result = result or (uint32(ord(data[pos+i])) shl (8*i))
  pos += 4

proc loadActor*(data: string): Actor =
  if data.len < 8 or data[0..<8] != ActorMagic:
    raise newException(ValueError, "invalid neural actor magic")
  var p = 8
  let version = readU32(data, p)
  let inputs = int(readU32(data, p))
  let hidden = int(readU32(data, p))
  let outputs = int(readU32(data, p))
  let heads = int(readU32(data, p))
  let parameters = int(readU32(data, p))
  if version != 1 or inputs notin 1..4096 or hidden notin [64,128,256] or
      outputs notin 2..1024 or heads notin 1..32:
    raise newException(ValueError, "unsupported neural actor dimensions/version")
  let expected = inputs*hidden + 3*hidden*hidden + outputs*hidden
  if parameters != expected or expected > MaxActorParameters or
      data.len != 32 + 128 + heads*4 + expected*4:
    raise newException(ValueError, "invalid neural actor length/parameter count")
  new(result)
  result.inputSize = inputs; result.hiddenSize = hidden; result.outputSize = outputs
  result.observationContract = data[p..<p+64]; p += 64
  result.actionContract = data[p..<p+64]; p += 64
  for hash in [result.observationContract, result.actionContract]:
    for c in hash:
      if c notin {'0'..'9', 'a'..'f'}:
        raise newException(ValueError, "invalid neural contract hash")
  var total = 0
  for i in 0..<heads:
    let size = int(readU32(data,p))
    if size notin 2..1024: raise newException(ValueError, "invalid categorical head")
    result.headSizes.add(size); total += size
  if total != outputs: raise newException(ValueError, "head/output mismatch")
  for dest in [addr result.encoder, addr result.recurrent, addr result.decoder]:
    let n = if dest == addr result.encoder: inputs*hidden
            elif dest == addr result.recurrent: 3*hidden*hidden
            else: outputs*hidden
    dest[].setLen(n)
    for i in 0..<n:
      let bits = readU32(data,p)
      let x = cast[float32](bits)
      if not finite(x): raise newException(ValueError, "nonfinite neural weight")
      dest[][i] = x

proc loadActorFile*(path: string): Actor =
  if getFileSize(path) > int64(32+128+128+MaxActorParameters*4):
    raise newException(ValueError, "neural actor file too large")
  loadActor(readFile(path))

proc operationCount*(actor: Actor): int =
  2*(actor.encoder.len + actor.recurrent.len + actor.decoder.len) + 32*actor.hiddenSize

proc sigmoid(x: float32): float32 =
  # Same stable branches as the pinned GPU sigmoid and lerp kernels.
  let z = exp(-abs(x))
  if x >= 0: 1'f32 / (1'f32 + z) else: z / (1'f32 + z)

proc interpolate(a, b, weight: float32): float32 =
  let delta = b-a
  if abs(weight) < 0.5'f32: a + weight*delta
  else: b - delta*(1'f32-weight)

proc infer*(actor: Actor, obs: openArray[float32], state: var seq[float32],
    logits: var seq[float32]) =
  if obs.len != actor.inputSize or state.len != actor.hiddenSize or
      logits.len != actor.outputSize:
    raise newException(ValueError, "neural buffer shape mismatch")
  for x in obs:
    if not finite(x): raise newException(ValueError, "nonfinite neural input")
  for x in state:
    if not finite(x): raise newException(ValueError, "nonfinite neural state")
  # Fixed bounded stack scratch: no inference allocations and no partial outputs.
  var x, next, y: array[256,float32]
  var combined: array[768,float32]
  var output: array[1024,float32]
  let h = actor.hiddenSize
  for o in 0..<h:
    var sum = 0'f32
    for i in 0..<obs.len: sum += obs[i]*actor.encoder[o*obs.len+i]
    x[o] = sum
  for o in 0..<3*h:
    var sum = 0'f32
    for i in 0..<h: sum += x[i]*actor.recurrent[o*h+i]
    combined[o] = sum
  for i in 0..<h:
    let candidate = if combined[i] >= 0: combined[i]+0.5'f32 else: sigmoid(combined[i])
    let gate = sigmoid(combined[h+i])
    next[i] = interpolate(state[i], candidate, gate)
    let highway = sigmoid(combined[2*h+i])
    y[i] = highway*next[i] + (1'f32-highway)*x[i]
    if not finite(next[i]) or not finite(y[i]):
      raise newException(ValueError, "nonfinite neural intermediate")
  for o in 0..<actor.outputSize:
    var sum = 0'f32
    for i in 0..<h: sum += y[i]*actor.decoder[o*h+i]
    if not finite(sum): raise newException(ValueError, "nonfinite neural output")
    output[o] = sum
  for i in 0..<h: state[i] = next[i]
  for i in 0..<actor.outputSize: logits[i] = output[i]
