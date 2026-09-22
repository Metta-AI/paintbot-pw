## The viewer overlay payload is parsed by JSON.parse, which rejects nan and
## inf. Every window size, including the 0x0 window of a hidden iframe, must
## therefore project to finite numbers.
import std/[unittest, math]
import vmath
import ../examples/paintbot/projection

proc finite(x: float32): bool = x.classify notin {fcNan, fcInf, fcNegInf}
proc finite(p: array[2, float32]): bool = finite(p[0]) and finite(p[1])
proc finite(m: Mat4): bool =
  result = true
  for i in 0..3:
    for j in 0..3:
      if not finite(m[i, j]): return false

proc camera(width, height: int): Mat4 =
  let cam = spectatorCamera(vec3(0, 0, 0), 60, 0, 0.92, width, height)
  cam.projection*cam.view

suite "Paintbot viewer projection":
  test "800x600 viewport keeps every overlay point finite at 1x and 2x pixels":
    # An 800x600 page leaves a 800x472 canvas under the viewer chrome.
    for scale in [1, 2]:
      let vp = camera(800*scale, 472*scale)
      check finite(vp)
      let heart = projected(vp, vec3(0, 0.4, 0))
      check finite(heart)
      check heart[0] > 0.45 and heart[0] < 0.55
      check heart[1] > 0.3 and heart[1] < 0.8
      check finite(screenPoint(vp, vec3(5, 1, -3)))
      for corner in groundFootprint(vp): check finite(corner)
    # The pixel ratio changes only the pixel count, not the framing.
    check projected(camera(800, 472), vec3(3, 0.4, 2)) ==
        projected(camera(1600, 944), vec3(3, 0.4, 2))

  test "zero-size windows never emit nan":
    # A hidden or not-yet-laid-out iframe reports a 0x0 drawable; the wasm used
    # to emit "bottom":[nan,nan] and JSON.parse killed the main loop.
    for (w, h) in [(0, 0), (0, 472), (800, 0), (1, 1)]:
      let vp = camera(w, h)
      check finite(vp)
      check finite(projected(vp, vec3(1, 0.4, 2)))
      check finite(projected(vp, vec3(0, 6.2, 0)))
      check finite(screenPoint(vp, vec3(1, 1, 2)))
      for corner in groundFootprint(vp): check finite(corner)

  test "narrow viewports pull the camera back, never to infinity":
    check fittedDistance(60, viewportAspect(800, 472)) == 60
    check fittedDistance(60, viewportAspect(472, 800)) > 60
    check finite(fittedDistance(60, viewportAspect(0, 0)))
    check finite(fittedDistance(60, viewportAspect(0, 600)))

  test "points behind the camera and degenerate matrices land off screen":
    let cam = spectatorCamera(vec3(0, 0, 0), 60, 0, 0.92, 800, 472)
    let vp = cam.projection*cam.view
    let behind = cam.eye+(cam.eye-vec3(0, 0, 0))
    check projected(vp, behind) == OffScreen
    var bad: Mat4
    for i in 0..3:
      for j in 0..3: bad[i, j] = NaN
    check projected(bad, vec3(1, 0.4, 2)) == OffScreen
    check screenPoint(bad, vec3(1, 1, 2)) == OffScreen
    for corner in groundFootprint(bad): check finite(corner)
    check finiteOr([NaN.float32, 1], [7'f32, 7]) == [7'f32, 7]
    check finiteOr([0.25'f32, 1], [7'f32, 7]) == [0.25'f32, 1]
