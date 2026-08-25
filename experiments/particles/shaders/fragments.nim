## Shady fragment shaders for classic soft alpha and additive particles.

import
  shady, vmath

proc softAlphaFragment*(
  fragmentUv: Vec2,
  fragmentColor: Vec4,
  fragmentLife: float32,
  fragmentSeed: float32,
  fragmentAlive: float32,
  fragColor: var Vec4
) =
  ## Draws a softly feathered alpha-blended particle.
  if fragmentAlive < 0.5'f:
    discardFragment()
  let
    point: Vec2 = fragmentUv * 2.0'f - 1.0'f
    radius = length(point)
    edgeNoise = sin(
      (point.x + point.y) * 9.0'f + fragmentSeed * 31.0'f
    ) * 0.04'f
    coverage = 1.0'f - smoothstep(
      0.34'f,
      1.0'f + edgeNoise,
      radius
    )
    flicker = 0.92'f + sin(
      fragmentLife * 12.0'f + fragmentSeed * 17.0'f
    ) * 0.08'f
    alpha = fragmentColor.w * coverage * flicker
  if alpha < 0.005'f:
    discardFragment()
  fragColor = vec4(fragmentColor.xyz, alpha)

proc softAdditiveFragment*(
  fragmentUv: Vec2,
  fragmentColor: Vec4,
  fragmentLife: float32,
  fragmentSeed: float32,
  fragmentAlive: float32,
  fragColor: var Vec4
) =
  ## Draws a bright radially feathered additive particle.
  if fragmentAlive < 0.5'f:
    discardFragment()
  let
    point: Vec2 = fragmentUv * 2.0'f - 1.0'f
    radiusSquared = dot(point, point)
    glow = exp(-radiusSquared * 3.2'f)
    core = exp(-radiusSquared * 14.0'f)
    flicker = 0.88'f + 0.12'f * sin(
      fragmentLife * 19.0'f + fragmentSeed * 43.0'f
    )
    alpha = fragmentColor.w * min(1.0'f, glow + core) * flicker
  if alpha < 0.005'f:
    discardFragment()
  fragColor = vec4(
    fragmentColor.xyz * (0.7'f + core * 0.8'f),
    alpha
  )
