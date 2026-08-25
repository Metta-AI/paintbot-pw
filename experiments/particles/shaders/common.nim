## Shared Shady particle evaluation used by every billboard vertex shader.

import
  shady, vmath

const MaxPathSamples* = 125

type ParticleParams* = object
  emitterPosition*: Vec3
  emissionRate*: float32
  lifetime*: float32
  lifetimeJitter*: float32
  particleCount*: int32
  startTime*: float32
  time*: float32
  seed*: float32
  pathCount*: int32
  spawnShape*: int32
  spawnRadius*: float32
  spawnSize*: Vec3
  direction*: Vec3
  spread*: float32
  speed*: float32
  speedJitter*: float32
  motionMode*: int32
  orbitSpeed*: float32
  drag*: float32
  acceleration*: Vec3
  turbulence*: float32
  frequency*: float32
  sizeJitter*: float32
  fadeIn*: float32
  fadeOut*: float32
  startSize*: float32
  endSize*: float32
  startColor*: Vec4
  endColor*: Vec4

var
  uViewProjection*: Uniform[Mat4]
  uCameraRight*: Uniform[Vec3]
  uCameraUp*: Uniform[Vec3]
  uCameraForward*: Uniform[Vec3]
  uTime*: Uniform[float32]
  uStartTime*: Uniform[float32]
  uParticleCount*: Uniform[int32]
  uSeed*: Uniform[float32]
  uEmissionRate*: Uniform[float32]
  uLifetime*: Uniform[float32]
  uLifetimeJitter*: Uniform[float32]
  uSpawnShape*: Uniform[int32]
  uEmitterPosition*: Uniform[Vec3]
  uSpawnSize*: Uniform[Vec3]
  uSpawnRadius*: Uniform[float32]
  uSpread*: Uniform[float32]
  uMotionMode*: Uniform[int32]
  uDirection*: Uniform[Vec3]
  uSpeed*: Uniform[float32]
  uSpeedJitter*: Uniform[float32]
  uAcceleration*: Uniform[Vec3]
  uDrag*: Uniform[float32]
  uTurbulence*: Uniform[float32]
  uFrequency*: Uniform[float32]
  uOrbitSpeed*: Uniform[float32]
  uStartSize*: Uniform[float32]
  uEndSize*: Uniform[float32]
  uSizeJitter*: Uniform[float32]
  uStretch*: Uniform[float32]
  uStartColor*: Uniform[Vec4]
  uEndColor*: Uniform[Vec4]
  uFadeIn*: Uniform[float32]
  uFadeOut*: Uniform[float32]
  uBillboardMode*: Uniform[int32]
  uPathCount*: Uniform[int32]
  uPathTexture*: Uniform[Sampler2D]

func hashValue(value: float32): float32 =
  ## Produces a repeatable pseudo-random value in the zero-to-one range.
  var valueFraction = fract(value * 0.1031'f)
  valueFraction *= valueFraction + 33.33'f
  valueFraction *= valueFraction + valueFraction
  result = fract(valueFraction)

proc randomFloat(state: var float32): float32 =
  ## Advances a shader-local pseudo-random stream.
  state += 1.0'f
  result = hashValue(state)

proc randomUnitVector(state: var float32): Vec3 =
  ## Produces a uniformly distributed unit vector.
  let
    y = randomFloat(state) * 2.0'f - 1.0'f
    angle = randomFloat(state) * 6.28318530718'f
    radius = sqrt(max(0.0'f, 1.0'f - y * y))
  result = vec3(cos(angle) * radius, y, sin(angle) * radius)

func safeDirection(value: Vec3): Vec3 =
  ## Normalizes a direction while preserving a useful zero-vector fallback.
  let valueLength = length(value)
  if valueLength < 0.0001'f:
    result = vec3(0.0'f, 1.0'f, 0.0'f)
  else:
    result = value / valueLength

proc pathSample(pathTexture: Sampler2D, index: int32): Vec4 =
  ## Fetches one timestamped path position from the portable path texture.
  result = texelFetch(pathTexture, ivec2(index, 0'i32), 0)

proc pathPosition(
  params: ParticleParams,
  pathTexture: Sampler2D,
  sampleTime: float32
): Vec3 =
  ## Interpolates the bounded emitter path at an arbitrary simulation time.
  if params.pathCount <= 0'i32:
    return params.emitterPosition
  let first: Vec4 = pathSample(pathTexture, 0'i32)
  if sampleTime <= first.w:
    return first.xyz
  for i in 1 ..< MaxPathSamples:
    if i.int32 >= params.pathCount:
      break
    let
      previous: Vec4 = pathSample(pathTexture, i.int32 - 1'i32)
      current: Vec4 = pathSample(pathTexture, i.int32)
    if sampleTime <= current.w:
      let
        width = max(current.w - previous.w, 0.0001'f)
        amount = clamp(
          (sampleTime - previous.w) / width,
          0.0'f,
          1.0'f
        )
      return mix(previous.xyz, current.xyz, amount)
  let
    latest: Vec4 = pathSample(
      pathTexture,
      max(params.pathCount - 1'i32, 0'i32)
    )
    width = max(params.time - latest.w, 0.0001'f)
    amount = clamp(
      (sampleTime - latest.w) / width,
      0.0'f,
      1.0'f
    )
  result = mix(latest.xyz, params.emitterPosition, amount)

proc coneDirection(
  params: ParticleParams,
  state: var float32,
  direction: Vec3
): Vec3 =
  ## Randomizes a direction inside the configured cone angle.
  let forward: Vec3 = safeDirection(direction)
  var helper: Vec3 = vec3(0.0'f, 1.0'f, 0.0'f)
  if abs(forward.y) > 0.95'f:
    helper = vec3(1.0'f, 0.0'f, 0.0'f)
  let
    right: Vec3 = normalize(cross(forward, helper))
    up: Vec3 = normalize(cross(right, forward))
    angle = randomFloat(state) * 6.28318530718'f
    radius = tan(params.spread * 0.01745329252'f) *
      sqrt(randomFloat(state))
  result = normalize(
    forward +
    right * cos(angle) * radius +
    up * sin(angle) * radius
  )

proc spawnOffset(params: ParticleParams, state: var float32): Vec3 =
  ## Produces a position offset for the selected spawn shape.
  if params.spawnShape == 1'i32:
    let radius = params.spawnRadius * pow(
      randomFloat(state),
      0.3333333333'f
    )
    return randomUnitVector(state) * radius
  if params.spawnShape == 2'i32:
    let randomValue: Vec3 = vec3(
      randomFloat(state),
      randomFloat(state),
      randomFloat(state)
    )
    return (randomValue * 2.0'f - 1.0'f) * params.spawnSize
  if params.spawnShape == 3'i32 or params.spawnShape == 4'i32:
    let
      angle = randomFloat(state) * 6.28318530718'f
      radius = params.spawnRadius * sqrt(randomFloat(state))
    return vec3(cos(angle) * radius, 0.0'f, sin(angle) * radius)
  result = vec3(0.0'f)

proc dragDisplacement(
  params: ParticleParams,
  velocity: Vec3,
  age: float32
): Vec3 =
  ## Integrates velocity using an analytic exponential drag curve.
  if params.drag < 0.0001'f:
    result = velocity * age
  else:
    result = velocity * (1.0'f - exp(-params.drag * age)) /
      params.drag

proc turbulenceOffset(
  params: ParticleParams,
  age, randomSeed: float32
): Vec3 =
  ## Returns a deterministic procedural turbulence displacement.
  if params.turbulence <= 0.0001'f:
    return vec3(0.0'f)
  let
    phase = randomSeed * 31.4159'f
    frequency = max(params.frequency, 0.01'f)
  result = vec3(
    sin(age * frequency + phase),
    sin(age * frequency * 1.37'f + phase * 1.7'f),
    cos(age * frequency * 0.83'f + phase * 2.3'f)
  ) * params.turbulence * age

proc evaluateParticle*(
  params: ParticleParams,
  pathTexture: Sampler2D,
  particleId: float32,
  position: var Vec3,
  velocity: var Vec3,
  size: var float32,
  color: var Vec4,
  lifeT: var float32,
  randomSeed: var float32,
  alive: var float32
) =
  ## Evaluates one stateless particle entirely from its ID, time, and emitter.
  position = params.emitterPosition
  velocity = vec3(0.0'f)
  size = 0.0'f
  color = vec4(0.0'f)
  lifeT = 0.0'f
  randomSeed = 0.0'f
  alive = 0.0'f

  let
    emissionRate = max(params.emissionRate, 0.001'f)
    maximumLife = max(
      params.lifetime * (
        1.0'f + max(params.lifetimeJitter, 0.0'f)
      ),
      0.001'f
    )
    period = max(params.particleCount.float32 / emissionRate, maximumLife)
    firstBirth = params.startTime + particleId / emissionRate
  if params.time < firstBirth:
    return

  let
    cycle = floor((params.time - firstBirth) / period)
    birthTime = firstBirth + cycle * period
  var state =
    particleId * 17.0'f +
    params.seed * 0.123'f +
    (cycle + 1.0'f) * 157.0'f
  randomSeed = randomFloat(state)
  let
    life = max(
      0.01'f,
      params.lifetime * mix(
        1.0'f - params.lifetimeJitter,
        1.0'f + params.lifetimeJitter,
        randomFloat(state)
      )
    )
    age = params.time - birthTime
  if age < 0.0'f or age >= life:
    return

  lifeT = clamp(age / life, 0.0'f, 1.0'f)
  var basePosition: Vec3 = pathPosition(
    params,
    pathTexture,
    birthTime
  )
  if params.spawnShape == 5'i32:
    let history = randomFloat(state) * min(life, 4.0'f)
    basePosition = pathPosition(
      params,
      pathTexture,
      birthTime - history
    )
  let offset: Vec3 = spawnOffset(params, state)
  var direction: Vec3 = safeDirection(params.direction)
  if params.spawnShape == 4'i32:
    direction = coneDirection(params, state, direction)
  let speed = max(
    0.0'f,
    params.speed * mix(
      1.0'f - params.speedJitter,
      1.0'f + params.speedJitter,
      randomFloat(state)
    )
  )
  velocity = direction * speed

  if params.motionMode == 1'i32:
    if length(offset) > 0.0001'f:
      direction = normalize(offset)
    else:
      direction = randomUnitVector(state)
    velocity = direction * speed

  if params.motionMode == 2'i32 or params.motionMode == 3'i32:
    var radial: Vec3 = offset
    let flatLength = length(vec2(radial.x, radial.z))
    if flatLength < 0.0001'f:
      let angle = randomFloat(state) * 6.28318530718'f
      radial = vec3(
        cos(angle),
        0.0'f,
        sin(angle)
      ) * params.spawnRadius
    let angle = params.orbitSpeed * age
    var radiusScale = 1.0'f
    if params.motionMode == 3'i32:
      radiusScale = max(0.08'f, 1.0'f - lifeT * 0.82'f)
    let rotated: Vec3 = vec3(
      radial.x * cos(angle) - radial.z * sin(angle),
      radial.y,
      radial.x * sin(angle) + radial.z * cos(angle)
    ) * radiusScale
    position = basePosition + rotated
    position.y += direction.y * speed * age
    velocity = vec3(
      -rotated.z * params.orbitSpeed,
      direction.y * speed,
      rotated.x * params.orbitSpeed
    )
  elif params.motionMode == 4'i32:
    let
      sampleTime = params.time - lifeT * min(life, 4.0'f)
      previous: Vec3 = pathPosition(
        params,
        pathTexture,
        sampleTime - 0.02'f
      )
    position = pathPosition(params, pathTexture, sampleTime) + offset
    velocity = (position - offset - previous) / 0.02'f
    position += direction * speed * age
  else:
    position = basePosition + offset + dragDisplacement(
      params,
      velocity,
      age
    )
    position += params.acceleration * (0.5'f * age * age)
    velocity = velocity * exp(-params.drag * age) +
      params.acceleration * age

  position += turbulenceOffset(params, age, randomSeed)
  let
    sizeRandom = mix(
      1.0'f - params.sizeJitter,
      1.0'f + params.sizeJitter,
      randomFloat(state)
    )
    curve = lifeT * lifeT * (3.0'f - 2.0'f * lifeT)
  var alpha = 1.0'f
  if params.fadeIn > 0.0001'f:
    alpha *= smoothstep(0.0'f, params.fadeIn, lifeT)
  if params.fadeOut > 0.0001'f:
    alpha *= 1.0'f - smoothstep(
      1.0'f - params.fadeOut,
      1.0'f,
      lifeT
    )

  size = max(
    0.001'f,
    mix(params.startSize, params.endSize, curve) * sizeRandom
  )
  color = mix(params.startColor, params.endColor, curve)
  color.w *= alpha
  alive = 1.0'f
