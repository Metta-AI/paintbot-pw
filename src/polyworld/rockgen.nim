import
  std/[algorithm, math, random, tables],
  chroma, gltf, pixie, vmath,
  naturalassets, images

const
  Tau = 2.0'f * PI.float32
  Epsilon = 0.00001'f
  PresetNames* = ["Tall angular", "Low compact", "Broken slab", "River stone",
    "Forest pebble", "Upright fieldstone", "Low wedge", "Leaning shard",
    "Broad boulder"]
  FillUv* = vec2(0.125, 0.375)
  TrimTop* = 0.008'f
  TrimBottom* = 0.020'f
  TilePadding* = 0.003'f

type
  RockgenError* = object of CatchableError
  RockRegion* = enum
    Edge, Fill, Detail
  DetailKind* = enum
    Mixed, Cracks, Scuffs
  RockSettings* = object
    seed*, sides*, crownCuts*, chips*, fillSubdivisions*: int
    width*, height*, depth*, irregularity*, taper*, crown*: float32
    cornerClip*, shoulder*, chipSize*: float32
    lean*, trimWidth*, detailChance*, detailSize*, detailOffset*: float32
    detailKind*: DetailKind
    shadeVariation*, mottling*, trimChance*: float32
    tint*: Vec3
    removeBottom*: bool
    floorCut*: float32
  RockVertex* = object
    position*, normal*: Vec3
    uv*: Vec2
    shade*: float32
    region*: RockRegion
    tile*: int
  RockMesh* = object
    vertices*: seq[RockVertex]
    indices*: seq[uint32]
  RockFace* = object
    points*: seq[Vec3]
    normal*: Vec3
    firstIndex*, indexCount*, detailTile*: int
    patch*: array[4, Vec3]
  RockGeometry* = object
    mesh*: RockMesh
    faces*: seq[RockFace]
    minimum*, maximum*: Vec3
    details*: int
  RockMaterials* = object
    stone*, regions*: Material
  PlaneFace = object
    points: seq[Vec3]
    normal: Vec3
  EdgeHit = object
    point: Vec2
    amount: float32

proc preset*(index: int, seed = 42): RockSettings =
  ## Returns a reproducible recipe for one of the rock silhouettes.
  result = RockSettings(
    seed: seed, sides: 4, crownCuts: 4, chips: 5, fillSubdivisions: 0,
    width: 2.6, height: 3.8, depth: 2.25,
    irregularity: 0.2, taper: 0.14, crown: 0.85, lean: 0.06,
    cornerClip: 0.27, shoulder: 0.52, chipSize: 0.14,
    trimWidth: 0.18, trimChance: 0.45,
    detailChance: 0.18, detailSize: 0.8,
    detailOffset: 0.22, detailKind: Mixed, shadeVariation: 0.1,
    mottling: 0.2, tint: vec3(0.69, 0.72, 0.83)
  )
  case index
  of 0:
    discard
  of 1:
    result.width = 3.1
    result.height = 2.3
    result.depth = 2.6
    result.sides = 5
    result.shoulder = 0.2
    result.cornerClip = 0.18
    result.taper = 0.2
    result.crown = 0.65
    result.lean = 0.05
  of 2:
    result.width = 4.2
    result.height = 1.6
    result.depth = 2.4
    result.sides = 4
    result.crownCuts = 3
    result.crown = 1.2
    result.lean = -0.15
    result.tint = vec3(0.82, 0.84, 0.88)
  of 3:
    result.width = 3.0
    result.height = 2.7
    result.depth = 2.7
    result.sides = 6
    result.crownCuts = 5
    result.irregularity = 0.1
    result.taper = 0
    result.lean = 0
    result.crown = 0.85
    result.cornerClip = 0.12
    result.shoulder = 0.25
    result.trimWidth = 0.04
    result.detailChance = 0.2
    result.tint = vec3(0.86, 0.86, 0.9)
  of 4:
    result.width = 2.5
    result.height = 1.7
    result.depth = 2.25
    result.shoulder = 0.3
    result.detailChance = 0.18
    result.tint = vec3(0.98, 0.97, 0.95)
  of 5:
    result.width = 2.5
    result.height = 3.0
    result.depth = 2.3
    result.crown = 1.2
    result.shoulder = 0.65
    result.tint = vec3(0.98, 0.96, 0.93)
  of 6:
    result.width = 3.4
    result.height = 1.45
    result.depth = 2.4
    result.lean = 0.3
    result.crown = 0.55
    result.shoulder = 0.45
    result.tint = vec3(0.97, 0.94, 0.9)
  of 7:
    result.width = 2.3
    result.height = 3.5
    result.depth = 2.0
    result.lean = 0.38
    result.shoulder = 0.05
    result.crown = 0.5
    result.cornerClip = 0.15
    result.tint = vec3(0.67, 0.7, 0.82)
  of 8:
    result.width = 3.4
    result.height = 3.2
    result.depth = 2.8
    result.shoulder = 0.2
    result.crown = 1.3
    result.irregularity = 0.3
    result.tint = vec3(0.72, 0.74, 0.85)
  else:
    raise newException(RockgenError, "Unknown rock preset: " & $index)

proc validate*(settings: RockSettings) {.raises: [RockgenError].} =
  ## Rejects invalid, nonfinite, or unbounded generation parameters.
  template requireRange(value, low, high: untyped) =
    ## Evaluates a field once and checks its supported finite range.
    block:
      let number = value
      if not (number >= typeof(number)(low) and
        number <= typeof(number)(high)):
          raise newException(RockgenError, astToStr(value) &
            " is out of range")
  requireRange(settings.seed, 0, 1_000_000_000)
  requireRange(settings.sides, 4, 12)
  requireRange(settings.crownCuts, 3, 12)
  requireRange(settings.chips, 0, 12)
  requireRange(settings.fillSubdivisions, 0, 2)
  requireRange(settings.floorCut, 0, 0.9)
  requireRange(settings.chipSize, 0, 0.25)
  requireRange(settings.width, 0.5, 8)
  requireRange(settings.height, 0.5, 10)
  requireRange(settings.depth, 0.5, 8)
  requireRange(settings.irregularity, 0, 0.4)
  requireRange(settings.taper, -0.3, 0.45)
  requireRange(settings.crown, 0.4, 1.6)
  requireRange(settings.cornerClip, 0, 0.45)
  requireRange(settings.shoulder, 0, 0.85)
  requireRange(settings.lean, -0.5, 0.5)
  requireRange(settings.trimWidth, 0, 0.4)
  requireRange(settings.trimChance, 0, 1)
  requireRange(settings.detailChance, 0, 1)
  requireRange(settings.detailSize, 0.15, 0.9)
  requireRange(settings.detailOffset, 0, 0.6)
  requireRange(settings.shadeVariation, 0, 0.4)
  requireRange(settings.mottling, 0, 0.4)
  for i in 0 ..< 3:
    requireRange(settings.tint[i], 0, 1)

proc basis(normal: Vec3): tuple[u, v: Vec3] =
  ## Builds an orthonormal face basis with outward counterclockwise winding.
  let axis =
    if abs(normal.y) < 0.9'f:
      vec3(0, 1, 0)
    else:
      vec3(1, 0, 0)
  result.u = normalize(cross(axis, normal))
  result.v = cross(normal, result.u)

proc center(points: seq[Vec3]): Vec3 =
  ## Averages a convex face's vertices to obtain an interior point.
  for point in points:
    result += point
  result /= points.len.float32

proc addUnique(points: var seq[Vec3], point: Vec3) =
  ## Collects a cut-plane corner once despite meeting it on adjacent faces.
  for existing in points:
    if lengthSq(existing - point) < Epsilon * Epsilon:
      return
  points.add point

proc clip(faces: var seq[PlaneFace], normal: Vec3, distance: float32) =
  ## Clips a closed convex solid and closes the cut with one planar polygon.
  var
    kept: seq[PlaneFace]
    cuts: seq[Vec3]
  for face in faces:
    var points: seq[Vec3]
    for i, a in face.points:
      let
        b = face.points[(i + 1) mod face.points.len]
        da = dot(normal, a) - distance
        db = dot(normal, b) - distance
      if da <= 0:
        points.addUnique(a)
      if (da < 0 and db > 0) or (da > 0 and db < 0):
        let point = a + (b - a) * (da / (da - db))
        points.addUnique(point)
        cuts.addUnique(point)
      elif abs(da) < Epsilon:
        cuts.addUnique(a)
    if points.len >= 3:
      kept.add PlaneFace(points: points, normal: face.normal)
  if cuts.len >= 3:
    let
      origin = center(cuts)
      axes = basis(normal)
    cuts.sort(proc(a, b: Vec3): int =
      ## Orders cut vertices around their outward-facing plane normal.
      cmp(
        arctan2(dot(a - origin, axes.v), dot(a - origin, axes.u)),
        arctan2(dot(b - origin, axes.v), dot(b - origin, axes.u))
      )
    )
    kept.add PlaneFace(points: cuts, normal: normal)
  for face in kept:
    let origin = center(face.points)
    for i, point in face.points:
      let edge = face.points[(i + 1) mod face.points.len] - point
      if length(edge) < 0.002'f or
        dot(cross(edge, origin - point), face.normal) /
        length(edge) < 0.001'f:
          return
  faces = move(kept)

proc silhouette(settings: RockSettings): seq[PlaneFace] =
  ## Cuts an irregular convex rock from a box using seeded support planes.
  var rng = initRand(settings.seed)
  for normal in [vec3(1, 0, 0), vec3(-1, 0, 0), vec3(0, 1, 0),
    vec3(0, -1, 0), vec3(0, 0, 1), vec3(0, 0, -1)]:
      let
        axes = basis(normal)
        origin = normal * 2.0'f
        u = axes.u * 2.0'f
        v = axes.v * 2.0'f
      result.add PlaneFace(
        points: @[origin - u - v, origin + u - v,
          origin + u + v, origin - u + v],
        normal: normal
      )
  result.clip(vec3(0, -1, 0), 0.85)
  let
    rotation = rng.rand(-0.15 .. 0.15).float32
    top = normalize(vec3(
      rng.rand(-1.0 .. 1.0).float32 * settings.irregularity,
      1,
      rng.rand(-1.0 .. 1.0).float32 * settings.irregularity
    ))
  result.clip(top, 1.0)
  var angles: seq[float32]
  for i in 0 ..< settings.sides:
    let
      angle = rotation + Tau * (i.float32 +
        rng.rand(-0.4 .. 0.4).float32 * settings.irregularity) /
        settings.sides.float32
      slope = settings.taper + rng.rand(-1.3 .. 1.3).float32 *
        settings.irregularity
      normal = normalize(vec3(cos(angle), slope, sin(angle)))
      distance = 0.95'f + rng.rand(-0.8 .. 0.8).float32 *
        settings.irregularity
    result.clip(normal, distance)
    angles.add angle
  if settings.cornerClip > 0:
    for i, angle in angles:
      let
        next =
          if i == angles.high:
            angles[0] + Tau
          else:
            angles[i + 1]
        middle = (angle + next) * 0.5'f
        tip = 0.95'f / cos((next - angle) * 0.5'f)
        slope = settings.taper + rng.rand(-1.8 .. 1.8).float32 *
          settings.irregularity
        plane = vec3(cos(middle), slope, sin(middle))
        distance = tip - (tip - 0.95'f) * settings.cornerClip * 2
      result.clip(normalize(plane), distance / length(plane))
  for i in 0 ..< settings.crownCuts:
    let
      angle = rotation + Tau * (i.float32 +
        rng.rand(-0.6 .. 0.6).float32 * settings.irregularity) /
        settings.crownCuts.float32
      slope = settings.crown *
        (1.0'f + rng.rand(-0.7 .. 0.7).float32 * settings.irregularity)
      plane = vec3(cos(angle), slope, sin(angle))
      distance = 0.95'f + slope * settings.shoulder +
        rng.rand(-0.8 .. 0.8).float32 * settings.irregularity
    result.clip(normalize(plane), distance / length(plane))
  for i in 0 ..< 4:
    let
      angle = rotation + Tau * (i.float32 + 0.5'f) / 4.0'f
      plane = vec3(cos(angle), -1.1, sin(angle))
    result.clip(normalize(plane), 1.7'f / length(plane))
  for i in 0 ..< settings.chips:
    var corners: seq[Vec3]
    for face in result:
      for point in face.points:
        if point.y > -0.5'f:
          corners.addUnique(point)
    if corners.len == 0 or settings.chipSize == 0:
      break
    let point = corners[rng.rand(corners.high)]
    var normal = vec3(0)
    for face in result:
      for corner in face.points:
        if lengthSq(corner - point) < Epsilon * Epsilon:
          normal += face.normal
          break
    normal = normalize(normal)
    let distance = dot(normal, point) - settings.chipSize *
      rng.rand(0.6 .. 1.4).float32
    result.clip(normal, max(0.35'f, distance))
  var
    minimum = vec3(Inf.float32)
    maximum = vec3(-Inf.float32)
  for face in result.mitems:
    for point in face.points.mitems:
      point.x += settings.lean * point.y
      minimum = min(minimum, point)
      maximum = max(maximum, point)
  let scale = vec3(settings.width, settings.height, settings.depth) /
    (maximum - minimum)
  for face in result.mitems:
    for point in face.points.mitems:
      point = (point - minimum) * scale -
        vec3(settings.width * 0.5'f, 0, settings.depth * 0.5'f)
    let origin = center(face.points)
    var normal = vec3(0)
    for i, point in face.points:
      normal += cross(point - origin,
        face.points[(i + 1) mod face.points.len] - origin)
    face.normal = normalize(normal)

proc cross2(a, b: Vec2): float32 =
  ## Returns the signed two-dimensional cross product.
  a.x * b.y - a.y * b.x

proc inradius(points: seq[Vec2], origin: Vec2): float32 =
  ## Measures clearance from an interior point to every polygon edge.
  result = Inf.float32
  for i, point in points:
    let edge = points[(i + 1) mod points.len] - point
    result = min(result, cross2(edge, origin - point) / length(edge))

proc tileUv*(tile: int, point: Vec2): Vec2 =
  ## Maps local detail coordinates into one padded cell of the 4x4 atlas.
  vec2((tile mod 4).float32, (tile div 4).float32) * 0.25'f +
    vec2(TilePadding) + point * (0.25'f - TilePadding * 2)

proc addTriangle(
  mesh: var RockMesh,
  points: array[3, Vec2],
  uvs: array[3, Vec2],
  origin, u, v, normal: Vec3,
  shade: float32,
  region: RockRegion,
  tile: int,
  subdivisions = 0
) =
  ## Emits one outward triangle with explicit face normals and UV seams.
  if cross2(points[1] - points[0], points[2] - points[0]) <= 0:
    raise newException(RockgenError, "Invalid face triangulation")
  if region == Fill and subdivisions > 0 and
    cross2(points[1] - points[0], points[2] - points[0]) > 0.02'f:
      let
        middle = points[0] * 0.28'f + points[1] * 0.33'f +
          points[2] * 0.39'f
        uv = FillUv
      for i in 0 ..< 3:
        let next = (i + 1) mod 3
        mesh.addTriangle(
          [middle, points[i], points[next]],
          [uv, uvs[i], uvs[next]],
          origin, u, v, normal, shade, region, tile, subdivisions - 1
        )
      return
  for i in 0 ..< 3:
    mesh.indices.add mesh.vertices.len.uint32
    mesh.vertices.add RockVertex(
      position: origin + u * points[i].x + v * points[i].y,
      normal: normal, uv: uvs[i], shade: shade, region: region, tile: tile
    )

proc addFill(
  mesh: var RockMesh,
  points: seq[Vec2],
  origin, u, v, normal: Vec3,
  shade: float32,
  subdivisions: int
) =
  ## Triangulates fill from its boundary with optional pigment subdivisions.
  var remaining: seq[int]
  for i in 0 ..< points.len:
    remaining.add i
  while remaining.len > 3:
    var
      best = -1
      bestQuality = 0.0'f
    for i, index in remaining:
      let
        previous = remaining[(i + remaining.len - 1) mod remaining.len]
        next = remaining[(i + 1) mod remaining.len]
        a = points[previous]
        b = points[index]
        c = points[next]
        area = cross2(b - a, c - a)
      if area <= 0:
        continue
      var occupied = false
      for candidate in remaining:
        if candidate in [previous, index, next]:
          continue
        let point = points[candidate]
        if cross2(b - a, point - a) >= -Epsilon * Epsilon and
          cross2(c - b, point - b) >= -Epsilon * Epsilon and
          cross2(a - c, point - c) >= -Epsilon * Epsilon:
            occupied = true
            break
      let quality = area /
        (lengthSq(b - a) + lengthSq(c - a) + lengthSq(c - b))
      if not occupied and quality > bestQuality:
        best = i
        bestQuality = quality
    if best < 0:
      raise newException(RockgenError, "Cannot triangulate fill polygon")
    mesh.addTriangle(
      [points[remaining[(best + remaining.len - 1) mod remaining.len]],
        points[remaining[best]],
        points[remaining[(best + 1) mod remaining.len]]],
      [FillUv, FillUv, FillUv], origin, u, v, normal,
      shade, Fill, 4, subdivisions
    )
    remaining.delete(best)
  mesh.addTriangle(
    [points[remaining[0]], points[remaining[1]], points[remaining[2]]],
    [FillUv, FillUv, FillUv], origin, u, v, normal,
    shade, Fill, 4, subdivisions
  )

proc relaxFill(mesh: var RockMesh, firstIndex: int, normal: Vec3) =
  ## Flips interior fill diagonals to reduce thin pigment triangles.
  var
    points: seq[Vec3]
    triangles: seq[array[3, int]]
    slots: seq[int]
  for i in countup(firstIndex, mesh.indices.high, 3):
    if mesh.vertices[mesh.indices[i]].region != Fill:
      continue
    var triangle: array[3, int]
    for j in 0 ..< 3:
      let point = mesh.vertices[mesh.indices[i + j]].position
      var index = -1
      for k, existing in points:
        if lengthSq(existing - point) < 0.000000000001'f:
          index = k
          break
      if index < 0:
        index = points.len
        points.add point
      triangle[j] = index
    triangles.add triangle
    slots.add i
  proc quality(a, b, c: int): float32 =
    ## Measures signed triangle area relative to its squared edge lengths.
    let
      ab = points[b] - points[a]
      ac = points[c] - points[a]
      bc = points[c] - points[b]
    dot(cross(ab, ac), normal) /
      (lengthSq(ab) + lengthSq(ac) + lengthSq(bc))
  for pass in 0 ..< 12:
    var
      edges = initTable[(int, int), tuple[index, corner: int]]()
      touched = newSeq[bool](triangles.len)
      changed = false
    for i in 0 ..< triangles.len:
      for j in 0 ..< 3:
        if touched[i]:
          break
        let
          a = triangles[i][j]
          b = triangles[i][(j + 1) mod 3]
          c = triangles[i][(j + 2) mod 3]
          key = (min(a, b), max(a, b))
        if not edges.hasKey(key):
          edges[key] = (i, j)
          continue
        let other = edges[key]
        if touched[other.index]:
          continue
        let
          d = triangles[other.index][(other.corner + 2) mod 3]
          before = min(quality(a, b, c), quality(b, a, d))
          after = min(quality(c, d, b), quality(d, c, a))
        if after > before + 0.00001'f:
          triangles[i] = [c, d, b]
          triangles[other.index] = [d, c, a]
          touched[i] = true
          touched[other.index] = true
          changed = true
    if not changed:
      break
  for i, triangle in triangles:
    for j in 0 ..< 3:
      mesh.vertices[mesh.indices[slots[i] + j]].position = points[triangle[j]]

proc buildFace(
  geometry: var RockGeometry,
  face: PlaneFace,
  settings: RockSettings,
  rng: var Rand
) =
  ## Triangulates a coplanar trim ring and a filled core around a square.
  let
    origin = center(face.points)
    axes = basis(face.normal)
    shade = 1.0'f - rng.rand(1.0).float32 * settings.shadeVariation
    firstIndex = geometry.mesh.indices.len
    edgeTile = rng.rand(3)
    subdivisions =
      if settings.mottling > 0:
        settings.fillSubdivisions
      else:
        0
  var
    outer, inner: seq[Vec2]
    info = RockFace(points: face.points, normal: face.normal,
      firstIndex: firstIndex, detailTile: -1)
  for point in face.points:
    let projected = vec2(dot(point - origin, axes.u),
      dot(point - origin, axes.v))
    outer.add projected
  let hasTrim = inradius(outer, vec2(0)) *
    max(0.01'f, settings.trimWidth) > 0.0001'f
  for point in outer:
    inner.add point *
      (if hasTrim: 1.0'f - max(0.01'f, settings.trimWidth) else: 1.0'f)
  let
    radius = inradius(inner, vec2(0))
    makeDetail = rng.rand(1.0).float32 < settings.detailChance and hasTrim and
      radius > 0.07'f and face.normal.y > -0.8'f
  var
    patch: array[4, Vec2]
    ring: seq[Vec2]
    edges = newSeq[seq[Vec2]](inner.len)
    fills: seq[seq[Vec2]]
  if makeDetail:
    let
      angle = rng.rand(Tau.float64).float32
      offsetAngle = rng.rand(Tau.float64).float32
      offset = vec2(cos(offsetAngle), sin(offsetAngle)) * radius *
        settings.detailOffset
      half = inradius(inner, offset) * settings.detailSize / sqrt(2.0'f)
      u = vec2(cos(angle), sin(angle)) * half
      v = vec2(-u.y, u.x)
    patch = [offset - u - v, offset + u - v,
      offset + u + v, offset - u + v]
    case settings.detailKind
    of Mixed:
      info.detailTile = rng.rand(5 .. 15)
    of Cracks:
      info.detailTile = rng.rand(5 .. 10)
    of Scuffs:
      info.detailTile = rng.rand(11 .. 15)
    for i, point in patch:
      info.patch[i] = origin + axes.u * point.x + axes.v * point.y
    for i, a in inner:
      let
        b = inner[(i + 1) mod inner.len]
        edge = b - a
      var hits: seq[EdgeHit]
      for corner in patch:
        let
          direction = corner - offset
          divisor = cross2(direction, edge)
        if abs(divisor) < Epsilon * Epsilon:
          continue
        let
          ray = cross2(a - offset, edge) / divisor
          amount = cross2(a - offset, direction) / divisor
        if ray > 1 and amount * length(edge) > Epsilon * 8 and
          (1.0'f - amount) * length(edge) > Epsilon * 8:
            hits.add EdgeHit(point: a + edge * amount, amount: amount)
      hits.sort(proc(a, b: EdgeHit): int =
        ## Orders square-corner ray intersections along an inner edge.
        cmp(a.amount, b.amount)
      )
      edges[i].add a
      for hit in hits:
        edges[i].add hit.point
      ring.add edges[i]
      edges[i].add b
    var corners: array[4, int]
    for i, corner in patch:
      let direction = normalize(corner - offset)
      var best = -Inf.float32
      for j, point in ring:
        let alignment = dot(normalize(point - offset), direction)
        if alignment > best:
          best = alignment
          corners[i] = j
    for i in 0 ..< 4:
      let next = (i + 1) mod 4
      var
        polygon = @[patch[i]]
        index = corners[i]
      polygon.add ring[index]
      while index != corners[next]:
        index = (index + 1) mod ring.len
        polygon.add ring[index]
      polygon.add patch[next]
      fills.add polygon
  else:
    for i, point in inner:
      edges[i] = @[point, inner[(i + 1) mod inner.len]]
    fills.add inner
  var
    worn = newSeq[bool](outer.len)
    starts = newSeq[float32](outer.len)
    anyWorn = false
  if hasTrim:
    for i in 0 ..< outer.len:
      worn[i] = rng.rand(1.0).float32 < settings.trimChance and
        settings.trimWidth > 0
      starts[i] = edgeTile.float32 * 0.25'f + TilePadding +
        rng.rand(0.14).float32
      anyWorn = anyWorn or worn[i]
  if not makeDetail and not anyWorn:
    fills = @[outer]
  for polygon in fills:
    geometry.mesh.addFill(
      polygon, origin, axes.u, axes.v, face.normal, shade, subdivisions
    )
  if makeDetail:
    let uvs = [vec2(0, 1), vec2(1, 1), vec2(1, 0), vec2(0, 0)]
    for indices in [[0, 1, 2], [0, 2, 3]]:
      geometry.mesh.addTriangle(
        [patch[indices[0]], patch[indices[1]], patch[indices[2]]],
        [tileUv(info.detailTile, uvs[indices[0]]),
          tileUv(info.detailTile, uvs[indices[1]]),
          tileUv(info.detailTile, uvs[indices[2]])],
        origin, axes.u, axes.v, face.normal, shade, Detail, info.detailTile
      )
    inc geometry.details
  if hasTrim and (makeDetail or anyWorn):
    for i, a in outer:
      let
        next = (i + 1) mod outer.len
        b = outer[next]
        edge = inner[next] - inner[i]
        left = starts[i]
        right = left + 0.08'f
      var
        polygon = @[a, b]
        uvs = @[vec2(left, TrimBottom), vec2(right, TrimBottom)]
      for j in countdown(edges[i].high, 0):
        let amount = dot(edges[i][j] - inner[i], edge) / lengthSq(edge)
        polygon.add edges[i][j]
        uvs.add vec2(mix(left, right, amount), TrimTop)
      for j in 1 ..< polygon.high:
        let
          region = (if worn[i]: Edge else: Fill)
          tile = (if region == Edge: edgeTile else: 4)
          mapped =
            if region == Edge:
              [uvs[0], uvs[j], uvs[j + 1]]
            else:
              [FillUv, FillUv, FillUv]
        geometry.mesh.addTriangle(
          [polygon[0], polygon[j], polygon[j + 1]],
          mapped,
          origin, axes.u, axes.v, face.normal, shade, region, tile,
          subdivisions
        )
  if subdivisions > 0:
    geometry.mesh.relaxFill(firstIndex, face.normal)
  info.indexCount = geometry.mesh.indices.len - firstIndex
  geometry.faces.add info

proc paintValue(x, y, z, seed: int): float32 =
  ## Hashes a lattice point into a deterministic grayscale pigment value.
  var value = cast[uint32](x.int32) * 0x8DA6B343'u32 xor
    cast[uint32](y.int32) * 0xD8163841'u32 xor
    cast[uint32](z.int32) * 0xCB1AB31F'u32 xor seed.uint32
  value = (value xor (value shr 13)) * 0x85EBCA6B'u32
  (value and 0xFFFF'u32).float32 / 65535.0'f

proc paintNoise(point: Vec3, seed: int): float32 =
  ## Interpolates low-frequency pigment without changing face normals.
  let
    cell = vec3(floor(point.x), floor(point.y), floor(point.z))
    local = point - cell
    blend = local * local * (vec3(3) - local * 2)
  for x in 0 .. 1:
    for y in 0 .. 1:
      for z in 0 .. 1:
        let weight =
          (if x == 0: 1.0'f - blend.x else: blend.x) *
          (if y == 0: 1.0'f - blend.y else: blend.y) *
          (if z == 0: 1.0'f - blend.z else: blend.z)
        result += paintValue(
          cell.x.int + x, cell.y.int + y, cell.z.int + z, seed
        ) * weight

proc floorVertex(a, b: RockVertex, height: float32): RockVertex =
  ## Interpolates an edge at the floor while preserving its texture mapping.
  let
    low = (if a.position.y < b.position.y: a else: b)
    high = (if a.position.y < b.position.y: b else: a)
    amount = (height - low.position.y) / (high.position.y - low.position.y)
  result = low
  result.position += (high.position - low.position) * amount
  result.position.y = height
  result.uv += (high.uv - low.uv) * amount
  result.shade += (high.shade - low.shade) * amount

proc aboveFloor(points: seq[RockVertex], height: float32): seq[RockVertex] =
  ## Clips a convex polygon and merges numerically coincident cut corners.
  for i, a in points:
    let b = points[(i + 1) mod points.len]
    if a.position.y >= height:
      result.add a
    if (a.position.y < height and b.position.y > height) or
      (a.position.y > height and b.position.y < height):
        result.add floorVertex(a, b, height)
  var cleaned: seq[RockVertex]
  for vertex in result:
    if cleaned.len > 0 and
      lengthSq(cleaned[^1].position - vertex.position) < 0.000000000001'f:
        if vertex.position.y == height:
          cleaned[^1] = vertex
    else:
      cleaned.add vertex
  if cleaned.len > 1 and
    lengthSq(cleaned[0].position - cleaned[^1].position) < 0.000000000001'f:
      if cleaned[^1].position.y == height:
        cleaned[0] = cleaned[^1]
      cleaned.setLen(cleaned.len - 1)
  result = move(cleaned)

proc cutFloor(geometry: var RockGeometry, height: float32) =
  ## Removes buried triangles and places the open cut at ground height.
  var clipped = RockGeometry(
    minimum: vec3(Inf.float32), maximum: vec3(-Inf.float32)
  )
  for face in geometry.faces:
    var
      outline: seq[RockVertex]
      info = face
      hasDetail = false
    for point in face.points:
      outline.add RockVertex(position: point)
    outline = aboveFloor(outline, height)
    if outline.len < 3:
      continue
    info.points = @[]
    for vertex in outline:
      info.points.add vertex.position - vec3(0, height, 0)
    info.firstIndex = clipped.mesh.indices.len
    for i in countup(face.firstIndex, face.firstIndex + face.indexCount - 1, 3):
      var triangle: seq[RockVertex]
      for j in 0 ..< 3:
        triangle.add geometry.mesh.vertices[geometry.mesh.indices[i + j]]
      let polygon = aboveFloor(triangle, height)
      for j in 1 ..< polygon.high:
        for index in [0, j, j + 1]:
          var vertex = polygon[index]
          vertex.position.y -= height
          clipped.mesh.indices.add clipped.mesh.vertices.len.uint32
          clipped.mesh.vertices.add vertex
          clipped.minimum = min(clipped.minimum, vertex.position)
          clipped.maximum = max(clipped.maximum, vertex.position)
          hasDetail = hasDetail or vertex.region == Detail
    info.indexCount = clipped.mesh.indices.len - info.firstIndex
    if info.indexCount == 0:
      continue
    if hasDetail:
      inc clipped.details
      for point in info.patch.mitems:
        point.y -= height
    else:
      info.detailTile = -1
      info.patch = default(array[4, Vec3])
    clipped.faces.add info
  geometry = move(clipped)

proc generateGeometry*(settings: RockSettings): RockGeometry =
  ## Builds a deterministic rock with an optional open ground-contact base.
  settings.validate()
  var rng = initRand(settings.seed xor 0x5163A)
  result.minimum = vec3(Inf.float32)
  result.maximum = vec3(-Inf.float32)
  for face in silhouette(settings):
    let
      firstVertex = result.mesh.vertices.len
      firstIndex = result.mesh.indices.len
    result.buildFace(face, settings, rng)
    var bottom = face.normal.y < -0.999'f
    for point in face.points:
      result.minimum = min(result.minimum, point)
      result.maximum = max(result.maximum, point)
      bottom = bottom and abs(point.y) < Epsilon
    if settings.removeBottom and bottom:
      # Consume the face's random choices to preserve the other surfaces.
      if result.faces[^1].detailTile >= 0:
        dec result.details
      result.mesh.vertices.setLen(firstVertex)
      result.mesh.indices.setLen(firstIndex)
      result.faces.setLen(result.faces.len - 1)
  for vertex in result.mesh.vertices.mitems:
    let
      point = vertex.position /
        vec3(settings.width, settings.height, settings.depth)
      wash = paintNoise(point * 8, settings.seed)
    vertex.shade *= 1.0'f - settings.mottling * wash
  if settings.floorCut > 0:
    result.cutFloor(settings.height * settings.floorCut)

proc loadMaterials*(): RockMaterials =
  ## Loads the shared atlas for reusable rock and diagnostic materials.
  var atlas: Image
  try:
    atlas = loadTexturePng(RockgenTexture)
  except IOError, PixieError:
    raise newException(RockgenError, "Cannot load rock atlas: " &
      getCurrentExceptionMsg())
  if atlas.width != GeneratorTextureSize or
    atlas.height != GeneratorTextureSize:
      raise newException(RockgenError, "Rock atlas must be 512 by 512")
  let
    sampler = TextureSampler(
      magFilter: LinearMagFilter, minFilter: LinearMinFilter,
      wrapS: ClampToEdgeWrap, wrapT: ClampToEdgeWrap
    )
    white = newImage(1, 1)
  white.fill(color(1, 1, 1, 1))
  result.stone = Material(
    name: "Tintable rock trim", baseColor: atlas,
    baseColorSampler: sampler, baseColorFactor: color(1, 1, 1, 1),
    roughnessFactor: 1, alphaMode: OpaqueAlphaMode
  )
  result.regions = Material(
    name: "Face regions", baseColor: white,
    baseColorSampler: sampler, baseColorFactor: color(1, 1, 1, 1),
    roughnessFactor: 1, alphaMode: OpaqueAlphaMode
  )

proc tint*(materials: RockMaterials, settings: RockSettings) =
  ## Multiplies the gray texture by the selected rock color.
  materials.stone.baseColorFactor = color(
    settings.tint.x, settings.tint.y, settings.tint.z, 1
  )

proc rockNode*(
  geometry: RockGeometry,
  materials: RockMaterials,
  showRegions = false
): Node =
  ## Converts the flat generated mesh into one textured or diagnostic node.
  let primitive = Primitive(
    material: (if showRegions: materials.regions else: materials.stone),
    mode: TrianglesMode, indices32: geometry.mesh.indices
  )
  for vertex in geometry.mesh.vertices:
    primitive.points.add vertex.position
    primitive.normals.add vertex.normal
    primitive.uvs.add vertex.uv
    var shade = vec3(vertex.shade)
    if showRegions:
      case vertex.region
      of Edge:
        shade = vec3(1, 0.62, 0.18)
      of Fill:
        shade = vec3(0.22, 0.68, 0.7)
      of Detail:
        shade = vec3(0.92, 0.28, 0.62)
    primitive.colors.add rgbx(
      (shade.x * 255).uint8, (shade.y * 255).uint8,
      (shade.z * 255).uint8, 255
    )
  result = Node(
    name: "Generated rock", visible: true,
    scale: vec3(1), rot: quat(0, 0, 0, 1),
    mesh: Mesh(name: "Rock", primitives: @[primitive])
  )

proc generate*(settings: RockSettings): Node =
  ## Builds a renderable rock node with its tinted material and trim texture.
  let
    geometry = generateGeometry(settings)
    materials = loadMaterials()
  materials.tint(settings)
  rockNode(geometry, materials)
