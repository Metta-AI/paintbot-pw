## Procedural, seamlessly tiling textures for the Wind Waker water
## experiment. Every image here is our own take on the maps the "How Wind
## Waker Builds Its Water Materials" video shows: a foam lattice, a zigzag
## displacement map, and the shoreline foam strips. All of them wrap on both
## axes so the shaders can scroll them forever.
##
## Foam strips put the shoreline at the TOP of the image (v = 0) and open
## water at the bottom (v = 1), which is the shore ring's uv convention.

import std/math, chroma, pixie

type Rgb = tuple[r, g, b: float32]

## Hashing and noise

proc hash2(x, y, seed: int): float32 =
  ## Deterministic 0..1 value for one lattice point.
  var h = uint32(x) * 374761393'u32 + uint32(y) * 668265263'u32 +
    uint32(seed) * 2246822519'u32
  h = (h xor (h shr 13)) * 1274126177'u32
  h = h xor (h shr 16)
  float32(h and 0xffffff'u32) / float32(0xffffff)

proc smoothCurve(t: float32): float32 =
  t * t * (3.0'f - 2.0'f * t)

proc tileNoise(u, v: float32, period, seed: int): float32 =
  ## Bilinear lattice noise that wraps every `period` cells.
  let
    x = u * period.float32
    y = v * period.float32
    x0 = floor(x).int
    y0 = floor(y).int
    tx = smoothCurve(x - x0.float32)
    ty = smoothCurve(y - y0.float32)
  template at(i, j: int): float32 =
    hash2(((i mod period) + period) mod period,
      ((j mod period) + period) mod period, seed)
  let
    top = at(x0, y0) * (1 - tx) + at(x0 + 1, y0) * tx
    bottom = at(x0, y0 + 1) * (1 - tx) + at(x0 + 1, y0 + 1) * tx
  top * (1 - ty) + bottom * ty

proc fbm(u, v: float32, period, seed: int, octaves = 3): float32 =
  ## Three octaves of tiling noise, normalized to 0..1.
  var
    amplitude = 1.0'f
    total = 0.0'f
    weight = 0.0'f
    p = period
  for octave in 0 ..< octaves:
    total += tileNoise(u, v, p, seed + octave * 17) * amplitude
    weight += amplitude
    amplitude *= 0.5
    p *= 2
  total / weight

proc wrap(delta: float32): float32 =
  ## Shortest signed distance on a unit torus axis.
  delta - round(delta)

proc worley(u, v: float32, cells, seed: int, jitter = 0.85'f,
    aspect = 1.0'f): tuple[f1, f2, f3: float32] =
  ## The three nearest feature-point distances on a wrapping jittered grid.
  ## `aspect` scales the horizontal distance, so values below one stretch
  ## the cells sideways without breaking the tiling.
  var best = [9.0'f, 9.0'f, 9.0'f]
  let
    cx = floor(u * cells.float32).int
    cy = floor(v * cells.float32).int
  for j in -1 .. 1:
    for i in -1 .. 1:
      let
        gx = cx + i
        gy = cy + j
        wx = ((gx mod cells) + cells) mod cells
        wy = ((gy mod cells) + cells) mod cells
        px = (gx.float32 + 0.5'f + (hash2(wx, wy, seed) - 0.5'f) * jitter) /
          cells.float32
        py = (gy.float32 + 0.5'f + (hash2(wx, wy, seed + 91) - 0.5'f) *
          jitter) / cells.float32
        dx = wrap(u - px) * aspect
        dy = wrap(v - py)
        d = sqrt(dx * dx + dy * dy)
      if d < best[0]:
        best[2] = best[1]
        best[1] = best[0]
        best[0] = d
      elif d < best[1]:
        best[2] = best[1]
        best[1] = d
      elif d < best[2]:
        best[2] = d
  (best[0], best[1], best[2])

proc soft(edge, width, x: float32): float32 =
  ## 1 below the edge, 0 above it, feathered over `width`.
  1.0'f - smoothstep(edge - width, edge + width, x)

## Image helpers

proc paint(size: int, shade: proc(u, v: float32): Rgb): Image =
  ## Fills a square image from a 0..1 uv shading callback.
  result = newImage(size, size)
  for y in 0 ..< size:
    for x in 0 ..< size:
      let
        u = (x.float32 + 0.5'f) / size.float32
        v = (y.float32 + 0.5'f) / size.float32
        c = shade(u, v)
      result.data[y * size + x] = rgbx(
        uint8(clamp(c.r, 0, 1) * 255), uint8(clamp(c.g, 0, 1) * 255),
        uint8(clamp(c.b, 0, 1) * 255), 255)

proc gray(value: float32): Rgb =
  (value, value, value)

## The maps

proc latticeValue(u, v: float32, cells, seed: int): float32 =
  ## White Voronoi edges with a small hole at every junction, like the
  ## triangular gaps in Wind Waker's foam lattice. The sample point is
  ## domain-warped first so the cells bulge instead of staying straight.
  let
    warpU = u + (fbm(u, v, 3, seed + 300) - 0.5'f) * 0.09'f
    warpV = v + (fbm(u, v, 3, seed + 400) - 0.5'f) * 0.09'f
    (f1, f2, f3) = worley(warpU, warpV, cells, seed)
    edge = soft(0.020'f, 0.006'f, f2 - f1)
    junction = soft(0.024'f, 0.005'f, f3 - f1)
    hole = soft(0.010'f, 0.005'f, f3 - f1)
  max(edge, junction) * (1.0'f - hole)

proc foamLattice*(size = 512, cells = 5, seed = 7): Image =
  ## The sea's foam lattice: white lines on black, tiled and scrolled at
  ## three scales by the water shader.
  paint(size, proc(u, v: float32): Rgb = gray(latticeValue(u, v, cells, seed)))

proc seaPreview*(size = 512): Image =
  ## The lattice tinted the way the video shows it: white over sea blue.
  paint(size, proc(u, v: float32): Rgb =
    let line = latticeValue(u, v, 5, 7)
    (0.10'f + 0.90'f * line, 0.36'f + 0.64'f * line, 0.92'f + 0.08'f * line))

proc triangleWave(t: float32): float32 =
  ## 0..1 triangle wave with period 1.
  abs(fract(t) * 2.0'f - 1.0'f)

proc warpMap*(size = 256): Image =
  ## The displacement (indirect) map: one grayscale chevron field, read
  ## twice at different offsets by the shader for the two uv axes.
  paint(size, proc(u, v: float32): Rgb =
    let
      zig = triangleWave(u * 2.0'f)
      value = 0.5'f + 0.5'f * sin((v * 2.0'f + zig * 0.35'f) * Tau)
      ripple = 0.5'f + 0.5'f * sin((u * 3.0'f + v * 1.0'f) * Tau)
    gray(value * 0.8'f + ripple * 0.2'f))

proc holes(u, v: float32, cells, seed: int, radius, aspect: float32): float32 =
  ## Elliptical cut-outs, 1 inside a hole, on a wrapping jittered grid.
  let (f1, _, _) = worley(u, v, cells, seed, 0.7'f, aspect)
  soft(radius * (0.7'f + 0.6'f * fbm(u, v, 4, seed)), 0.008'f, f1)

proc shoreFoam*(size = 256): Image =
  ## Foam that hugs the sand: a wavy strip at the shoreline with holes
  ## opening up toward its trailing edge.
  paint(size, proc(u, v: float32): Rgb =
    let
      front = 0.10'f + 0.03'f * sin(u * 3.0'f * Tau) +
        0.02'f * sin(u * 7.0'f * Tau + 1.7'f)
      back = 0.34'f + 0.04'f * sin(u * 4.0'f * Tau + 0.6'f)
      strip = smoothstep(front - 0.01'f, front + 0.01'f, v) *
        soft(back, 0.015'f, v)
      holeBand = smoothstep(0.17'f, 0.21'f, v)
      gaps = holes(u, v, 10, 21, 0.028'f, 0.5'f) * holeBand
    gray(strip * (1.0'f - gaps)))

proc shoreMask*(size = 256): Image =
  ## Coverage for the shore ring: solid at the sand, a soft wavy fade to
  ## nothing toward open water.
  paint(size, proc(u, v: float32): Rgb =
    let
      wobble = 0.04'f * sin(u * 2.0'f * Tau) + 0.02'f * sin(u * 5.0'f * Tau + 2)
      fade = soft(0.50'f + wobble, 0.18'f, v)
    gray(fade))

proc crestFoam*(size = 256): Image =
  ## The breaking crest: a spiky front edge, a wavy back edge, and a row
  ## of dark gaps behind it.
  paint(size, proc(u, v: float32): Rgb =
    let
      spikes = 0.14'f + 0.10'f * triangleWave(u * 4.0'f) +
        0.02'f * triangleWave(u * 12.0'f + 0.25'f)
      back = 0.44'f + 0.03'f * sin(u * 6.0'f * Tau)
      band = smoothstep(spikes - 0.008'f, spikes + 0.008'f, v) *
        soft(back, 0.012'f, v)
      gapBand = smoothstep(0.29'f, 0.33'f, v) * soft(0.42'f, 0.02'f, v)
      gaps = holes(u, v, 10, 33, 0.030'f, 0.5'f) * gapBand
    gray(band * (1.0'f - gaps)))

proc bandFoam*(size = 256): Image =
  ## A thick lapping band with two rows of stretched holes.
  paint(size, proc(u, v: float32): Rgb =
    let
      front = 0.16'f + 0.05'f * sin(u * 2.0'f * Tau) +
        0.02'f * sin(u * 5.0'f * Tau + 1.0'f)
      back = 0.60'f + 0.04'f * sin(u * 3.0'f * Tau + 2.0'f)
      band = smoothstep(front - 0.012'f, front + 0.012'f, v) *
        soft(back, 0.015'f, v)
      rowA = smoothstep(0.24'f, 0.28'f, v) * soft(0.40'f, 0.02'f, v)
      rowB = smoothstep(0.42'f, 0.46'f, v) * soft(0.56'f, 0.02'f, v)
      gaps = max(
        holes(u, v, 10, 44, 0.034'f, 0.45'f) * rowA,
        holes(u + 0.05'f, v, 10, 45, 0.030'f, 0.45'f) * rowB)
    gray(band * (1.0'f - gaps)))

proc shoreLattice*(size = 512): Image =
  ## Near-shore foam: the lattice under a bright wavy cap that fades out
  ## toward open water.
  paint(size, proc(u, v: float32): Rgb =
    let
      cap = 0.30'f + 0.02'f * sin(u * 4.0'f * Tau) +
        0.015'f * sin(u * 9.0'f * Tau + 0.8'f)
      inside = smoothstep(cap - 0.01'f, cap + 0.01'f, v)
      capLine = inside * soft(cap + 0.05'f, 0.02'f, v)
      fade = inside * soft(0.62'f, 0.18'f, v)
      lattice = latticeValue(u, v * 0.5'f, 4, 9)
    gray(max(capLine, fade * (0.12'f + 0.88'f * lattice))))
