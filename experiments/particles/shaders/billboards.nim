## Shady vertex shaders for camera-facing and velocity-stretched billboards.

import
  shady, vmath,
  common

proc billboardVertex*(
  gl_Position: var Vec4,
  fragmentUv: var Vec2,
  fragmentColor: var Vec4,
  fragmentLife: var float32,
  fragmentSeed: var float32,
  fragmentAlive: var float32
) =
  ## Expands one GPU instance into a camera-facing four-vertex billboard.
  let
    vertexId = gl_VertexID
    particleId = gl_InstanceID.float32
  fragmentUv = vec2(
    (vertexId mod 2'i32).float32,
    (vertexId div 2'i32).float32
  )
  var
    params: ParticleParams
    position: Vec3
    velocity: Vec3
    size: float32
  params.emitterPosition = uEmitterPosition
  params.emissionRate = uEmissionRate
  params.lifetime = uLifetime
  params.lifetimeJitter = uLifetimeJitter
  params.particleCount = uParticleCount
  params.startTime = uStartTime
  params.time = uTime
  params.seed = uSeed
  params.pathCount = uPathCount
  params.spawnShape = uSpawnShape
  params.spawnRadius = uSpawnRadius
  params.spawnSize = uSpawnSize
  params.direction = uDirection
  params.spread = uSpread
  params.speed = uSpeed
  params.speedJitter = uSpeedJitter
  params.motionMode = uMotionMode
  params.orbitSpeed = uOrbitSpeed
  params.drag = uDrag
  params.acceleration = uAcceleration
  params.turbulence = uTurbulence
  params.frequency = uFrequency
  params.sizeJitter = uSizeJitter
  params.fadeIn = uFadeIn
  params.fadeOut = uFadeOut
  params.startSize = uStartSize
  params.endSize = uEndSize
  params.startColor = uStartColor
  params.endColor = uEndColor
  evaluateParticle(
    params,
    uPathTexture,
    particleId,
    position,
    velocity,
    size,
    fragmentColor,
    fragmentLife,
    fragmentSeed,
    fragmentAlive
  )
  if fragmentAlive < 0.5'f:
    gl_Position = vec4(2.0'f, 2.0'f, 2.0'f, 1.0'f)
  else:
    let corner: Vec2 = fragmentUv * 2.0'f - 1.0'f
    var
      right: Vec3 = uCameraRight
      up: Vec3 = uCameraUp
    if uBillboardMode == 1'i32:
      up = vec3(0.0'f, 1.0'f, 0.0'f)
      right = cross(up, uCameraForward)
      let rightLength = length(right)
      if rightLength > 0.0001'f:
        right = right / rightLength
      else:
        right = uCameraRight
    var worldPosition: Vec3 = position
    worldPosition += right * corner.x * size
    worldPosition += up * corner.y * size
    gl_Position = uViewProjection * vec4(worldPosition, 1.0'f)

proc stretchedVertex*(
  gl_Position: var Vec4,
  fragmentUv: var Vec2,
  fragmentColor: var Vec4,
  fragmentLife: var float32,
  fragmentSeed: var float32,
  fragmentAlive: var float32
) =
  ## Expands one GPU instance into a velocity-aligned stretched billboard.
  let
    vertexId = gl_VertexID
    particleId = gl_InstanceID.float32
  fragmentUv = vec2(
    (vertexId mod 2'i32).float32,
    (vertexId div 2'i32).float32
  )
  var
    params: ParticleParams
    position: Vec3
    velocity: Vec3
    size: float32
  params.emitterPosition = uEmitterPosition
  params.emissionRate = uEmissionRate
  params.lifetime = uLifetime
  params.lifetimeJitter = uLifetimeJitter
  params.particleCount = uParticleCount
  params.startTime = uStartTime
  params.time = uTime
  params.seed = uSeed
  params.pathCount = uPathCount
  params.spawnShape = uSpawnShape
  params.spawnRadius = uSpawnRadius
  params.spawnSize = uSpawnSize
  params.direction = uDirection
  params.spread = uSpread
  params.speed = uSpeed
  params.speedJitter = uSpeedJitter
  params.motionMode = uMotionMode
  params.orbitSpeed = uOrbitSpeed
  params.drag = uDrag
  params.acceleration = uAcceleration
  params.turbulence = uTurbulence
  params.frequency = uFrequency
  params.sizeJitter = uSizeJitter
  params.fadeIn = uFadeIn
  params.fadeOut = uFadeOut
  params.startSize = uStartSize
  params.endSize = uEndSize
  params.startColor = uStartColor
  params.endColor = uEndColor
  evaluateParticle(
    params,
    uPathTexture,
    particleId,
    position,
    velocity,
    size,
    fragmentColor,
    fragmentLife,
    fragmentSeed,
    fragmentAlive
  )
  if fragmentAlive < 0.5'f:
    gl_Position = vec4(2.0'f, 2.0'f, 2.0'f, 1.0'f)
  else:
    var along: Vec3 = velocity
    along -= uCameraForward * dot(along, uCameraForward)
    let alongLength = length(along)
    if alongLength > 0.0001'f:
      along = along / alongLength
    else:
      along = uCameraUp
    var side: Vec3 = cross(uCameraForward, along)
    let sideLength = length(side)
    if sideLength > 0.0001'f:
      side = side / sideLength
    else:
      side = uCameraRight
    let
      corner: Vec2 = fragmentUv * 2.0'f - 1.0'f
      lengthScale = 1.0'f + length(velocity) * uStretch
    var worldPosition: Vec3 = position
    worldPosition += side * corner.x * size
    worldPosition += along * corner.y * size * lengthScale
    gl_Position = uViewProjection * vec4(worldPosition, 1.0'f)
