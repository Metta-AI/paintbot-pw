## Spectator camera fit and HUD overlay projection for the Paintbot viewer.
##
## The overlay payload crosses into JavaScript through JSON.parse, which rejects
## nan and inf, so every number produced here must be finite for any window
## size, including the 0x0 window of a hidden or not-yet-laid-out iframe.
import std/math
import vmath

const OffScreen* = [-100'f32, -100'f32]
  ## Normalised screen point the overlay treats as "not visible".

proc finite(x: float32): bool = x.classify notin {fcNan, fcInf, fcNegInf}

proc finiteOr*(p, fallback: array[2, float32]): array[2, float32] =
  ## Replaces a point with any non-finite coordinate by `fallback`.
  if finite(p[0]) and finite(p[1]): p else: fallback

proc viewportAspect*(width, height: int): float32 =
  ## Width over height of the drawable, each clamped to a pixel: a hidden or
  ## not-yet-laid-out iframe reports 0x0, and a zero width would otherwise fit
  ## the camera at an infinite distance and turn the whole projection into nan.
  max(1, width).float32/max(1, height).float32

proc fittedDistance*(distance, aspect: float32): float32 =
  ## Pulls the camera back on viewports narrower than 16:10 so the framed
  ## action still fits horizontally.
  distance*max(1'f32, 1.6'f32/aspect)

proc spectatorCamera*(target: Vec3, distance, yaw, tilt: float32,
    width, height: int): tuple[eye: Vec3, view, projection: Mat4] =
  ## Orbit camera around `target` for a `width` x `height` pixel drawable.
  let aspect = viewportAspect(width, height)
  result.eye = target+vec3(sin(yaw)*cos(tilt), sin(tilt), cos(yaw)*cos(tilt))*
      fittedDistance(distance, aspect)
  result.view = lookAt(result.eye, target, vec3(0, 1, 0))
  result.projection = perspective(45'f32, aspect, 0.1'f32, 600'f32)

proc projected*(vp: Mat4, p: Vec3): array[2, float32] =
  ## Normalised screen position of a world point, or `OffScreen` when the
  ## point is behind the camera or the projection is degenerate.
  let clip = vp*vec4(p, 1)
  # `not (w > 0)` also rejects a nan w, which `w <= 0` lets through.
  if not (clip.w > 0): return OffScreen
  finiteOr([(clip.x/clip.w*0.5+0.5).float32, (0.5-clip.y/clip.w*0.5).float32],
      OffScreen)

proc screenPoint*(vp: Mat4, p: Vec3): array[2, float32] =
  ## Unclipped normalised screen position used for cog markers; points behind
  ## the camera keep their mirrored coordinates as the overlay expects.
  let clip = vp*vec4(p, 1)
  finiteOr([(clip.x/clip.w*0.5+0.5).float32, (0.5-clip.y/clip.w*0.5).float32],
      OffScreen)

proc groundFootprint*(vp: Mat4): array[4, array[2, float32]] =
  ## World x/z of the four view corners cast onto the ground plane, for the
  ## minimap camera outline.
  let inverse = vp.inverse
  for i, corner in [vec2(-1, -1), vec2(1, -1), vec2(1, 1), vec2(-1, 1)]:
    let a = inverse*vec4(corner.x, corner.y, -1, 1)
    let b = inverse*vec4(corner.x, corner.y, 1, 1)
    let origin = vec3(a.x, a.y, a.z)/a.w
    let ray = vec3(b.x, b.y, b.z)/b.w-origin
    let point = origin+ray*clamp(-origin.y/ray.y, 0'f32, 1'f32)
    # A degenerate view has no ground footprint; collapse it onto the target
    # rather than sending nan to the minimap.
    result[i] = finiteOr([point.x, point.z], [0'f32, 0'f32])
