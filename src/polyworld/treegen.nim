import
  std/[algorithm, math, random],
  chroma, gltf, pixie, vmath,
  naturalassets, images, treegen/trims

const
  Tau = 2.0'f * PI.float32
  Up = vec3(0, 1, 0)
  CapSlices* = 24
  LeafVertices* = 6
  LeafIndices* = 12
  EvergreenAspect = 1.4'f
  PresetNames* = ["Old oak", "Autumn", "Round sapling", "Blue spruce",
    "Tall fir", "Young pine", "Haunted", "Twisted", "Dead sapling", "Stump"]

type
  TreegenError* = object of CatchableError
  TreeKind* = enum
    Leafless, Evergreen, Broadleaf, Stump
  BranchKind* = enum
    Spreading, Angular, Drooping
  BranchLayout* = enum
    Spiral, Paired, Whorled
  LeafTile* = enum
    MixedLeaves, SoftLeaves, LobedLeaves, PointedLeaves
  TreeSettings* = object
    seed*: int
    kind*: TreeKind
    branchKind*: BranchKind
    branchLayout*: BranchLayout
    height*, trunkRadius*, taper*, bend*, twist*: float32
    trunkSegments*, radialSides*, roots*: int
    rootSpread*, rootThickness*, rootClaw*, rootAngle*: float32
    stemClearance*: float32
    branches*, forks*, branchSegments*: int
    branchStart*, branchLength*, branchRadius*, branchLift*: float32
    branchJitter*, branchMinimum*: float32
    crownRadius*, crownHeight*, crownBase*, crownShape*: float32
    crownCoverage*: float32
    capSize*, capSlope*: float32
    rings*, cardsPerRing*, shells*: int
    density*, packing*, ringSpacing*, ringOffset*, irregularity*: float32
    leafSize*, leafWidth*, droop*, curl*, leafJitter*: float32
    leafTile*: LeafTile
    separateLeaves*: bool
    colorVariation*, barkTexture*, barkDensity*: float32
    barkColor*, leafColor*: Vec3
  TreeVertex* = object
    position*, normal*: Vec3
    uv*: Vec2
    shade*: float32
  TreeMesh* = object
    vertices*: seq[TreeVertex]
    indices*: seq[uint32]
  TreeGeometry* = object
    bark*, foliage*, cut*: TreeMesh
    minimum*, maximum*: Vec3
    cards*, limbs*: int
    omittedCards*, shiftedCards*: int
  TreeMaterials* = object
    bark*, foliage*, cut*: Material
  LeafFace = object
    points: seq[Vec3]
    normal: Vec3
    minimum, maximum: Vec2
  LeafPatch = object
    vertexStart, vertexCount, indexStart, indexCount: int
    minimum, maximum: Vec3

proc preset*(index: int, seed = 42): TreeSettings =
  ## Returns a complete recipe with a caller-selected deterministic seed.
  result = TreeSettings(
    seed: seed, kind: Broadleaf, branchKind: Spreading,
    branchLayout: Spiral, height: 5.8, trunkRadius: 0.42, taper: 1.25,
    bend: 0.16, twist: 0.35, trunkSegments: 9, radialSides: 8,
    roots: 7, rootSpread: 1.15, rootThickness: 0.75,
    rootClaw: 0.3, rootAngle: 30, stemClearance: 0.75,
    branches: 9, forks: 1, branchSegments: 4,
    branchStart: 0.36, branchLength: 2.0, branchRadius: 0.6,
    branchLift: 0.65, branchJitter: 0.3, branchMinimum: 0.055,
    crownRadius: 2.4, crownHeight: 3.4, crownBase: 2.7,
    crownShape: 0.5, crownCoverage: 0.75, capSize: 1, capSlope: 20,
    rings: 9, cardsPerRing: 12, shells: 1,
    density: 1, packing: 1.3, ringSpacing: 1, ringOffset: 0.65,
    irregularity: 0.14,
    leafSize: 1.5, leafWidth: 1.5, droop: 0.65, curl: 0.18,
    leafJitter: 0.2, colorVariation: 0, barkTexture: 1,
    separateLeaves: true,
    barkDensity: 0.65,
    barkColor: vec3(0.64, 0.35, 0.14),
    leafColor: vec3(0.5, 0.72, 0.16)
  )
  case clamp(index, 0, PresetNames.high)
  of 1:
    result.leafColor = vec3(1, 0.32, 0.045)
    result.leafTile = LobedLeaves
    result.crownRadius = 2.8
  of 2:
    result.height = 3.4
    result.trunkRadius = 0.2
    result.crownBase = 1.4
    result.crownHeight = 2.3
    result.crownRadius = 1.5
    result.leafSize = 1.15
    result.branchLength = 1.1
    result.rootSpread = 0.65
    result.rings = 7
    result.leafColor = vec3(0.7, 0.87, 0.24)
  of 3 .. 5:
    result.kind = Evergreen
    result.capSlope = 40
    result.height = 7.4
    result.bend = 0.025
    result.trunkRadius = 0.3
    result.crownBase = 2.15
    result.crownHeight = 5.25
    result.crownRadius = 2.4
    result.crownShape = 1.15
    result.rings = 10
    result.cardsPerRing = 8
    result.leafSize = 1.3
    result.leafWidth = 1.4
    result.droop = 0.78
    result.branchLift = -0.1
    result.branchLayout = Whorled
    result.branches = 15
    result.forks = 0
    result.leafColor = vec3(0.18, 0.53, 0.46)
    if index == 4:
      result.height = 9.2
      result.crownHeight = 7.05
      result.crownRadius = 1.85
      result.rings = 13
      result.leafColor = vec3(0.22, 0.48, 0.24)
    elif index == 5:
      result.height = 4.3
      result.trunkRadius = 0.19
      result.crownBase = 1.35
      result.crownHeight = 2.95
      result.crownRadius = 1.65
      result.rings = 7
      result.leafSize = 0.9
      result.rootSpread = 0.65
      result.stemClearance = 0.45
  of 6 .. 8:
    result.kind = Leafless
    result.branchKind = Angular
    result.height = 4.8
    result.trunkRadius = 0.5
    result.taper = 0.8
    result.bend = 0.7
    result.twist = 0.8
    result.trunkSegments = 6
    result.radialSides = 5
    result.branchSegments = 3
    result.branches = 5
    result.forks = 0
    result.branchRadius = 0.9
    result.branchMinimum = 0.075
    result.branchLength = 1.8
    result.branchLift = 0.1
    result.branchJitter = 0.7
    result.branchStart = 0.28
    result.barkColor = vec3(0.27, 0.14, 0.11)
    if index == 7:
      result.bend = 0.75
      result.twist = 1.8
      result.height = 6.4
      result.branches = 9
      result.forks = 2
      result.branchLength = 2.6
    elif index == 8:
      result.height = 2.8
      result.trunkRadius = 0.22
      result.branches = 4
      result.branchLength = 1.2
      result.rootSpread = 0.65
  of 9:
    result.kind = Stump
    result.height = 0.95
    result.trunkRadius = 0.7
    result.taper = 1.1
    result.bend = 0.08
    result.trunkSegments = 4
    result.radialSides = 12
    result.rootSpread = 1.4
    result.rootThickness = 0.85
    result.branches = 0
    result.forks = 0
  else:
    discard

proc validate*(settings: TreeSettings) =
  ## Rejects unsafe recipes before any geometry or allocations are made.
  template requireRange(value, low, high: untyped) =
    ## Checks finite numeric ranges with the offending field in the error.
    if not (value >= typeof(value)(low) and value <= typeof(value)(high)):
      raise newException(TreegenError, astToStr(value) & " is out of range")
  requireRange(settings.seed, 0, 1_000_000_000)
  if settings.kind == Stump:
    requireRange(settings.height, 0.3, 3)
  else:
    requireRange(settings.height, 1, 16)
  requireRange(settings.trunkRadius, 0.06, 1.4)
  requireRange(settings.taper, 0.3, 3)
  requireRange(settings.bend, 0, 1.5)
  requireRange(settings.twist, 0, 3)
  requireRange(settings.trunkSegments, 3, 16)
  requireRange(settings.radialSides, 3, 12)
  requireRange(settings.roots, 0, 12)
  requireRange(settings.rootSpread, 0.1, 3)
  requireRange(settings.rootThickness, 0.1, 1.5)
  requireRange(settings.rootClaw, 0.1, 0.6)
  requireRange(settings.rootAngle, 5, 65)
  requireRange(settings.stemClearance, 0.1, 3)
  requireRange(settings.branches, 0, 24)
  requireRange(settings.forks, 0, 3)
  requireRange(settings.branchSegments, 2, 8)
  requireRange(settings.branchStart, 0.1, 0.85)
  requireRange(settings.branchLength, 0.2, 5)
  requireRange(settings.branchRadius, 0.15, 0.9)
  requireRange(settings.branchLift, -0.7, 1.5)
  requireRange(settings.branchJitter, 0, 1)
  requireRange(settings.branchMinimum, 0.001, 0.3)
  requireRange(settings.crownRadius, 0.3, 5)
  requireRange(settings.crownHeight, 0.5, 12)
  requireRange(settings.crownBase, 0.3, 8)
  requireRange(settings.crownShape, 0.25, 2.5)
  requireRange(settings.crownCoverage, 0.5, 1)
  requireRange(settings.capSize, 0.5, 2)
  requireRange(settings.capSlope, 5, 55)
  requireRange(settings.rings, 2, 24)
  requireRange(settings.cardsPerRing, 3, 32)
  requireRange(settings.shells, 1, 3)
  requireRange(settings.density, 0, 2)
  requireRange(settings.packing, 0.5, 3)
  requireRange(settings.ringSpacing, 0.5, 2)
  requireRange(settings.ringOffset, 0, 1)
  requireRange(settings.irregularity, 0, 0.65)
  requireRange(settings.leafSize, 0.2, 3.5)
  requireRange(settings.leafWidth, 0.3, 2)
  requireRange(settings.droop, 0, 1.5)
  requireRange(settings.curl, -0.5, 0.8)
  requireRange(settings.leafJitter, 0, 0.6)
  requireRange(settings.colorVariation, 0, 0.5)
  requireRange(settings.barkTexture, 0, 1)
  requireRange(settings.barkDensity, 0.1, 3)
  for i in 0 ..< 3:
    requireRange(settings.barkColor[i], 0, 1)
    requireRange(settings.leafColor[i], 0, 1)

proc jitter(rng: var Rand, amount: float32): float32 =
  ## Samples a symmetric range from a local seeded stream.
  (rng.rand(2.0).float32 - 1.0'f) * amount

proc vertex(mesh: var TreeMesh, position, normal: Vec3, uv: Vec2,
    shade = 1.0'f): uint32 =
  ## Appends a fully specified vertex and returns its index.
  result = mesh.vertices.len.uint32
  mesh.vertices.add TreeVertex(
    position: position, normal: normal, uv: uv, shade: shade)

proc quad(mesh: var TreeMesh, a, b, c, d: uint32) =
  ## Adds an outward-wound quad as two indexed triangles.
  mesh.indices.add [a, b, c, a, c, d]

proc taperedRadius(radius, fraction, taper: float32): float32 =
  ## Shares the exact tube radius rule with branch attachment sizing.
  max(min(radius, 0.008'f), radius * pow(1.0'f - fraction, taper))

proc tube(mesh: var TreeMesh, points: openArray[Vec3],
    radius, taper: float32, sides: int, phase, density: float32,
    endFraction = 1.0'f, openTop = false) =
  ## Maps bark by surface distance, optionally leaving a level stump cut.
  let start = mesh.vertices.len.uint32
  var right, previous: Vec3
  for i, point in points:
    let
      t = i.float32 / (points.len - 1).float32
      direction =
        if openTop:
          Up
        else:
          normalize(points[min(i + 1, points.high)] -
            points[max(i - 1, 0)])
      width = taperedRadius(radius, t * endFraction, taper)
      perimeter = 2.0'f * sides.float32 * width *
        sin(PI.float32 / sides.float32)
    if i == 0 or dot(previous, direction) < -0.999'f:
      let reference =
        if abs(direction.y) > 0.95'f:
          vec3(1, 0, 0)
        else:
          Up
      right = normalize(cross(direction, reference))
    else:
      # Parallel transport avoids texture flips when a limb bends upward.
      let turn = cross(previous, direction)
      right += cross(turn, right) + cross(turn, cross(turn, right)) /
        (1.0'f + dot(previous, direction))
      right = normalize(right - direction * dot(right, direction))
    let forward = normalize(cross(direction, right))
    previous = direction
    for j in 0 .. sides:
      let
        u = j.float32 / sides.float32
        angle = u * Tau + phase
        normal = right * cos(angle) + forward * sin(angle)
        position = point + normal * width
      var distance = 0.0'f
      if i > 0:
        let below = mesh.vertices[start.int + (i - 1) * (sides + 1) + j]
        distance = -below.uv.y + length(position - below.position) * density
      let uv = vec2((u - 0.5'f) * perimeter * density, -distance)
      discard mesh.vertex(position, normal, uv)
    if i > 0:
      for j in 0 ..< sides:
        let
          a = start + ((i - 1) * (sides + 1) + j).uint32
          b = a + (sides + 1).uint32
        mesh.quad(a, a + 1, b + 1, b)
  for edge in [0, points.high]:
    if openTop and edge == points.high:
      continue
    let
      normal =
        if openTop:
          -Up
        elif edge == 0:
          normalize(points[0] - points[1])
        else:
          normalize(points[^1] - points[^2])
      ring = start + (edge * (sides + 1)).uint32
      across = normalize(mesh.vertices[ring].position - points[edge])
      along = normalize(cross(normal, across))
      center = mesh.vertex(points[edge], normal, vec2(0))
      cap = mesh.vertices.len.uint32
    for j in 0 ..< sides:
      let
        position = mesh.vertices[ring + j.uint32].position
        offset = position - points[edge]
        uv = vec2(dot(offset, across), dot(offset, along)) * density
      discard mesh.vertex(position, normal, uv)
    for j in 0 ..< sides:
      let
        a = cap + j.uint32
        b = cap + ((j + 1) mod sides).uint32
      if edge == 0:
        mesh.indices.add [center, b, a]
      else:
        mesh.indices.add [center, a, b]

proc stumpCap(mesh: var TreeMesh, bark: TreeMesh, center: Vec3,
    ring, sides: int) =
  ## Maps the sealed cut at a fixed scale around the painted rings' center.
  const
    RingCenter = vec2(0.61, 0.5)
    RingScale = 0.24'f
  let start = mesh.vertex(center, Up, RingCenter)
  for j in 0 ..< sides:
    let
      position = bark.vertices[ring + j].position
      offset = position - center
      # Fixed ring spacing keeps even the widest stump inside opaque wood.
      uv = RingCenter + vec2(offset.x, -offset.z) * RingScale
    discard mesh.vertex(position, Up, uv)
  for j in 0 ..< sides:
    mesh.indices.add [start, start + 1 + j.uint32,
      start + 1 + ((j + 1) mod sides).uint32]

proc trunkPoint(points: openArray[Vec3], fraction: float32): Vec3 =
  ## Interpolates a branch attachment along the trunk's actual centerline.
  let
    at = clamp(fraction, 0.0'f, 0.9999'f) * (points.len - 1).float32
    index = at.int
  mix(points[index], points[index + 1], at - index.float32)

proc limb(geometry: var TreeGeometry, settings: TreeSettings,
    rng: var Rand, origin: Vec3, angle, length, radius: float32,
    depth: int) =
  ## Grows a bounded fork tree with explicit branch style and taper.
  let clearance = min(settings.stemClearance, settings.height * 0.6'f)
  if radius <= settings.branchMinimum * 1.15'f or
    origin.y < clearance + radius:
      return
  var
    points = @[origin]
    heading = angle
  let
    endFraction = 1.0'f - pow(settings.branchMinimum / radius,
      1.0'f / settings.taper)
    step = length * endFraction / settings.branchSegments.float32
  for i in 1 .. settings.branchSegments:
    let t = i.float32 / settings.branchSegments.float32
    heading += rng.jitter(settings.branchJitter * 0.5'f)
    var lift = settings.branchLift
    case settings.branchKind
    of Angular:
      lift += (if i mod 2 == 0: 1.1'f else: -0.25'f)
      heading += rng.jitter(0.4'f)
    of Drooping:
      lift -= t * 1.5'f
    of Spreading:
      lift += t * 0.3'f
    let direction = vec3(cos(heading), lift, sin(heading))
    var point = points[^1] + direction * step
    point.y = max(clearance + radius, point.y)
    points.add point
  geometry.bark.tube(
    points,
    radius,
    settings.taper,
    settings.radialSides,
    angle,
    settings.barkDensity,
    endFraction
  )
  inc geometry.limbs
  if depth > 0:
    let
      attachment = max(1, points.high - 1)
      fraction = attachment.float32 / points.high.float32 * endFraction
      parentRadius = taperedRadius(radius, fraction, settings.taper)
    for sign in [-1.0'f, 1.0'f]:
      geometry.limb(
        settings,
        rng,
        points[attachment],
        heading + sign * (0.55'f + rng.jitter(0.2'f)),
        length * 0.53'f,
        parentRadius * 0.65'f,
        depth - 1
      )

proc leafCard(mesh: var TreeMesh, anchor, radial: Vec3,
    length, width, droop, curl, roll, radius: float32, tile: int,
    shade, clearance: float32) =
  ## Builds two joined panels with a crease that follows the ring curvature.
  let
    tangent = normalize(cross(Up, radial))
    across = tangent * cos(roll) + Up * sin(roll)
    fold = arctan2(width * 0.5'f, max(radius, length * 0.5'f))
    start = mesh.vertices.len.uint32
    column = tile mod 4
    row = tile div 4
  var lowest = Inf.float32
  for i in 0 .. 1:
    let
      t = i.float32
      center = anchor + radial * length * t -
        Up * length * (droop * t + curl * t * t)
    for j in 0 .. 2:
      let
        u = j.float32 * 0.5'f
        side = (u - 0.5'f) * width
        position = center + across * (side * cos(fold)) -
          radial * (abs(side) * sin(fold))
        normal = normalize(radial * 0.8'f + Up * 0.85'f +
          tangent * ((u - 0.5'f) * sin(fold)))
        uv = vec2(
          (column.float32 + 0.01'f + u * 0.98'f) * 0.25'f,
          (row.float32 + 0.01'f + t * 0.98'f) * 0.25'f
        )
      discard mesh.vertex(position, normal, uv, shade)
      lowest = min(lowest, position.y)
    if i > 0:
      for j in 0 .. 1:
        let a = start + j.uint32
        mesh.quad(a, a + 3, a + 4, a + 1)
  if lowest < clearance:
    for i in start.int ..< mesh.vertices.len:
      mesh.vertices[i].position.y += clearance - lowest

proc evergreenRadius(settings: TreeSettings, height: float32): float32 =
  ## Returns the evergreen envelope radius at an absolute height.
  let depth = max(0.0001'f,
    (settings.crownBase + settings.crownHeight - height) / settings.crownHeight)
  settings.crownRadius * pow(depth, settings.crownShape)

proc evergreenCard(mesh: var TreeMesh, settings: TreeSettings,
    center: Vec3, height, angle, size, width, shellScale, relief: float32,
    tile: int, shade, clearance: float32) =
  ## Wraps a four-triangle spray around the cone with a fixed center length.
  let
    apex = settings.crownBase + settings.crownHeight
    cardLength = size * EvergreenAspect
    top = max(clearance + cardLength, min(height, apex - 0.01'f))
    rootRadius = settings.evergreenRadius(top) * shellScale
  var
    low = 0.0'f
    high = cardLength
  # Find the vertical drop whose sloping centerline has the requested length.
  for i in 0 ..< 20:
    let
      drop = (low + high) * 0.5'f
      tipRadius = settings.evergreenRadius(top - drop) * shellScale
      distance = length(vec2(tipRadius - rootRadius, drop))
    if distance < cardLength:
      low = drop
    else:
      high = drop
  let
    drop = (low + high) * 0.5'f
    start = mesh.vertices.len.uint32
    column = tile mod 4
    row = tile div 4
  for i in 0 .. 1:
    let
      y = top - drop * i.float32
      radius = settings.evergreenRadius(y) * shellScale
      halfAngle = min(PI.float32 / 3.0'f,
        2.0'f * arcsin(min(1.0'f, width * 0.25'f / radius)))
      depth = max(0.0001'f, (apex - y) / settings.crownHeight)
      slope = settings.crownRadius / settings.crownHeight *
        settings.crownShape * pow(depth, settings.crownShape - 1.0'f) *
        shellScale
    for j in 0 .. 2:
      let
        u = j.float32 * 0.5'f
        heading = angle + (u - 0.5'f) * 2.0'f * halfAngle
        radial = vec3(cos(heading), 0, sin(heading))
        position = vec3(center.x, y, center.z) +
          radial * max(0.001'f, radius + relief)
        normal = normalize(radial + Up * slope)
        uv = vec2(
          (column.float32 + 0.01'f + u * 0.98'f) * 0.25'f,
          (row.float32 + 0.01'f + i.float32 * 0.98'f) * 0.25'f
        )
      discard mesh.vertex(position, normal, uv, shade)
  for j in 0 .. 1:
    let index = start + j.uint32
    mesh.quad(index, index + 3, index + 4, index + 1)

proc projected(point: Vec3): Vec2 =
  ## Projects a foliage vertex onto the horizontal plane.
  vec2(point.x, point.z)

proc cross2(a, b: Vec2): float32 =
  ## Returns the signed area spanned by two planar vectors.
  a.x * b.y - a.y * b.x

proc clipPolygon(polygon: seq[Vec2], origin, direction: Vec2,
    orientation = 1.0'f): seq[Vec2] =
  ## Clips a convex polygon against one directed edge.
  if polygon.len == 0:
    return
  var
    previous = polygon[^1]
    previousSide = cross2(direction, previous - origin) * orientation
  for current in polygon:
    let side = cross2(direction, current - origin) * orientation
    if (side >= 0) != (previousSide >= 0):
      result.add mix(previous, current,
        previousSide / (previousSide - side))
    if side >= 0:
      result.add current
    previous = current
    previousSide = side

proc visibleFace(mesh: TreeMesh, index: int): LeafFace =
  ## Restricts a triangle's collision footprint to its opaque trim outline.
  let
    a = mesh.vertices[mesh.indices[index]]
    b = mesh.vertices[mesh.indices[index + 1]]
    c = mesh.vertices[mesh.indices[index + 2]]
    column = (a.uv.x * 4).int
    row = (a.uv.y * 4).int
    tile = row * 4 + column
  result.normal = cross(b.position - a.position, c.position - a.position)
  let
    origin = vec2(column.float32, row.float32)
    uvA = a.uv * 4.0'f - origin
    uvB = b.uv * 4.0'f - origin
    uvC = c.uv * 4.0'f - origin
    hull = TrimHulls[tile]
    determinant = cross2(uvB - uvA, uvC - uvA)
  var polygon = @[uvA, uvB, uvC]
  for i in 0 ..< hull.len:
    polygon = clipPolygon(polygon, hull[i],
      hull[(i + 1) mod hull.len] - hull[i])
  for point in polygon:
    let
      u = cross2(point - uvA, uvC - uvA) / determinant
      v = cross2(uvB - uvA, point - uvA) / determinant
    result.points.add a.position +
      (b.position - a.position) * u + (c.position - a.position) * v

proc blockedRange(a, b: LeafFace, gap: float32): Vec2 =
  ## Finds vertical translations that make two visible foliage faces cross.
  result = vec2(Inf.float32, -Inf.float32)
  if a.points.len < 3 or b.points.len < 3 or
    abs(a.normal.y) < 0.00000001'f or abs(b.normal.y) < 0.00000001'f:
      return
  if a.maximum.x < b.minimum.x or a.minimum.x > b.maximum.x or
    a.maximum.y < b.minimum.y or a.minimum.y > b.maximum.y:
      return
  let orientation =
    if b.normal.y > 0:
      -1.0'f
    else:
      1.0'f
  var
    polygon, clipped: array[128, Vec2]
    count = a.points.len
  for i, point in a.points:
    polygon[i] = projected(point)
  for i in 0 ..< b.points.len:
    let
      origin = projected(b.points[i])
      direction = projected(b.points[(i + 1) mod b.points.len]) - origin
    # Clipping can repeat a corner; its tiny edge has no stable half-plane.
    if dot(direction, direction) < 0.000000000001'f:
      continue
    var
      output = 0
      previous = polygon[count - 1]
      previousSide = cross2(direction, previous - origin) * orientation
    for j in 0 ..< count:
      let
        current = polygon[j]
        side = cross2(direction, current - origin) * orientation
      if (side >= 0) != (previousSide >= 0):
        clipped[output] = mix(previous, current,
          previousSide / (previousSide - side))
        inc output
      if side >= 0:
        clipped[output] = current
        inc output
      previous = current
      previousSide = side
    if output < 3:
      return
    for j in 0 ..< output:
      polygon[j] = clipped[j]
    count = output
  var area = 0.0'f
  for i in 1 ..< count - 1:
    area += cross2(polygon[i] - polygon[0], polygon[i + 1] - polygon[0])
  if abs(area) < 0.00000001'f:
    return
  for i in 0 ..< count:
    let
      point = polygon[i]
      heightA = a.points[0].y -
        (a.normal.x * (point.x - a.points[0].x) +
        a.normal.z * (point.y - a.points[0].z)) / a.normal.y
      heightB = b.points[0].y -
        (b.normal.x * (point.x - b.points[0].x) +
        b.normal.z * (point.y - b.points[0].z)) / b.normal.y
      difference = heightB - heightA
    result.x = min(result.x, difference - gap)
    result.y = max(result.y, difference + gap)

proc compareRanges(a, b: Vec2): int =
  ## Orders blocked translation intervals by their lower endpoint.
  cmp(a.x, b.x)

proc separateFoliage(geometry: var TreeGeometry, settings: TreeSettings) =
  ## Separates folded cards once at generation time using a spatial grid.
  if geometry.cards == 0:
    return
  let
    capIndex = geometry.cards
    clearance = min(settings.stemClearance, settings.height * 0.6'f)
    cellSize = max(0.2'f, settings.leafSize)
    movement = settings.leafSize * 0.45'f
    gap = max(0.002'f, settings.leafSize * 0.006'f)
    epsilon = 0.00005'f
  var
    faces: seq[LeafFace]
    patches = newSeq[LeafPatch](geometry.cards + 1)
    minimum = vec3(Inf.float32)
    maximum = vec3(-Inf.float32)
  for i in countup(0, geometry.foliage.indices.high, 3):
    var face = geometry.foliage.visibleFace(i)
    face.minimum = vec2(Inf.float32)
    face.maximum = vec2(-Inf.float32)
    for point in face.points:
      face.minimum = min(face.minimum, projected(point))
      face.maximum = max(face.maximum, projected(point))
    faces.add face
  for i in 0 .. capIndex:
    var patch = LeafPatch(
      vertexStart: i * LeafVertices, vertexCount: LeafVertices,
      indexStart: i * LeafIndices, indexCount: LeafIndices,
      minimum: vec3(Inf.float32), maximum: vec3(-Inf.float32))
    if i == capIndex:
      patch.vertexCount = CapSlices + 1
      patch.indexCount = CapSlices * 3
    for j in patch.vertexStart ..< patch.vertexStart + patch.vertexCount:
      let position = geometry.foliage.vertices[j].position
      patch.minimum = min(patch.minimum, position)
      patch.maximum = max(patch.maximum, position)
    patches[i] = patch
    minimum = min(minimum, patch.minimum)
    maximum = max(maximum, patch.maximum)
  let
    columns = ceil((maximum.x - minimum.x) / cellSize).int + 1
    rows = ceil((maximum.z - minimum.z) / cellSize).int + 1
  var
    grid = newSeq[seq[int]](columns * rows)
    visited = newSeq[int](patches.len)
    kept = newSeq[bool](patches.len)
    ranges: seq[Vec2]
  # Keep the crown first, then work downward through the foliage rings.
  for i in countdown(capIndex, 0):
    let
      patch = patches[i]
      x0 = clamp(((patch.minimum.x - minimum.x) / cellSize).int, 0, columns - 1)
      x1 = clamp(((patch.maximum.x - minimum.x) / cellSize).int, 0, columns - 1)
      z0 = clamp(((patch.minimum.z - minimum.z) / cellSize).int, 0, rows - 1)
      z1 = clamp(((patch.maximum.z - minimum.z) / cellSize).int, 0, rows - 1)
    ranges.setLen(0)
    if i != capIndex:
      for z in z0 .. z1:
        for x in x0 .. x1:
          for other in grid[z * columns + x]:
            if visited[other] == i + 1:
              continue
            visited[other] = i + 1
            let obstacle = patches[other]
            if patch.maximum.x < obstacle.minimum.x or
              patch.minimum.x > obstacle.maximum.x or
              patch.maximum.z < obstacle.minimum.z or
              patch.minimum.z > obstacle.maximum.z or
              patch.maximum.y + movement + gap < obstacle.minimum.y or
              (other != capIndex and
              patch.minimum.y - movement - gap > obstacle.maximum.y):
                continue
            for a in countup(patch.indexStart,
              patch.indexStart + patch.indexCount - 1, 3):
                for b in countup(obstacle.indexStart,
                  obstacle.indexStart + obstacle.indexCount - 1, 3):
                    var interval = blockedRange(
                      faces[a div 3],
                      faces[b div 3],
                      gap
                    )
                    if interval.x <= interval.y:
                      if other == capIndex:
                        # Cards under the crown stay below its surface.
                        interval.y = Inf.float32
                      ranges.add interval
      ranges.sort(compareRanges)
      var up, down: float32
      for interval in ranges:
        if up >= interval.x and up <= interval.y:
          up = interval.y + epsilon
      for j in countdown(ranges.high, 0):
        let interval = ranges[j]
        if down >= interval.x and down <= interval.y:
          down = interval.x - epsilon
      let
        lower = max(-movement, clearance - patch.minimum.y)
        upper = min(movement, patches[capIndex].maximum.y - patch.maximum.y)
        canLower = down >= lower and down <= upper
        canRaise = up >= lower and up <= upper
      if not canLower and not canRaise:
        inc geometry.omittedCards
        continue
      let shift =
        if canLower and (not canRaise or abs(down) <= abs(up)):
          down
        else:
          up
      if abs(shift) > epsilon:
        inc geometry.shiftedCards
      for j in patch.vertexStart ..< patch.vertexStart + patch.vertexCount:
        geometry.foliage.vertices[j].position.y += shift
      for j in countup(patch.indexStart,
        patch.indexStart + patch.indexCount - 1, 3):
          for point in faces[j div 3].points.mitems:
            point.y += shift
      patches[i].minimum.y += shift
      patches[i].maximum.y += shift
    kept[i] = true
    for z in z0 .. z1:
      for x in x0 .. x1:
        grid[z * columns + x].add i
  var separated: TreeMesh
  for i, patch in patches:
    if not kept[i]:
      continue
    let start = separated.vertices.len.uint32
    for j in patch.vertexStart ..< patch.vertexStart + patch.vertexCount:
      separated.vertices.add geometry.foliage.vertices[j]
    for j in patch.indexStart ..< patch.indexStart + patch.indexCount:
      separated.indices.add geometry.foliage.indices[j] -
        patch.vertexStart.uint32 + start
  geometry.cards -= geometry.omittedCards
  geometry.foliage = separated

proc leafTile(settings: TreeSettings, rng: var Rand): int =
  ## Selects one trim from the current foliage family and leaf style.
  if settings.kind == Evergreen:
    return 12 + rng.rand(3)
  case settings.leafTile
  of MixedLeaves:
    4 + rng.rand(7)
  of SoftLeaves:
    [4, 5, 8][rng.rand(2)]
  of LobedLeaves:
    [6, 9, 10][rng.rand(2)]
  of PointedLeaves:
    [7, 11][rng.rand(1)]

proc cap(geometry: var TreeGeometry, settings: TreeSettings,
    center: Vec3, size, clearance: float32) =
  ## Maps one complete cap tile onto a raised center and shared circular rim.
  const UvRadius = 0.49'f
  var rng = initRand(settings.seed.int64 + 93_137)
  let
    tile =
      if settings.kind == Evergreen:
        0
      else:
        1 + rng.rand(2)
    phase = rng.rand(Tau.float64).float32
    shade = 1.0'f - rng.rand(settings.colorVariation.float64).float32
    radius = size * settings.capSize
    slope = tan(settings.capSlope * PI.float32 / 180.0'f)
    rise =
      if settings.kind == Evergreen:
        settings.crownHeight *
          pow(radius / settings.crownRadius, 1.0'f / settings.crownShape)
      else:
        radius * slope
    apex = vec3(center.x,
      max(center.y + 0.02'f, clearance + rise), center.z)
    uvCenter = vec2((tile.float32 + 0.5'f) * 0.25'f, 0.125'f)
    start = geometry.foliage.vertex(apex, Up, uvCenter, shade)
  for i in 0 ..< CapSlices:
    let
      angle = Tau * i.float32 / CapSlices.float32
      radial = vec3(cos(angle + phase), 0, sin(angle + phase))
      position = apex + radial * radius - Up * rise
      normal = normalize(Up + radial * (rise / radius))
      uv = uvCenter + vec2(cos(angle), sin(angle)) * UvRadius * 0.25'f
    discard geometry.foliage.vertex(position, normal, uv, shade)
  for i in 0 ..< CapSlices:
    geometry.foliage.indices.add [
      start,
      start + 1 + ((i + 1) mod CapSlices).uint32,
      start + 1 + i.uint32
    ]

proc canopy(geometry: var TreeGeometry, settings: TreeSettings,
    trunk: openArray[Vec3]) =
  ## Places offset, irregular radial rings on a cone or rounded envelope.
  if settings.kind in {Leafless, Stump} or settings.density == 0:
    return
  var
    rng = initRand(settings.seed.int64 + 71_921)
    crownCenter: Vec3
    crownSize: float32
  let
    clearance = min(settings.stemClearance, settings.height * 0.6'f)
    cardDensity =
      if settings.kind == Evergreen:
        settings.density * 1.5'f
      else:
        settings.density
    trimWidth =
      if settings.kind == Evergreen:
        0.45'f
      else:
        0.65'f
    coveredHeight =
      if settings.kind == Evergreen:
        settings.leafSize * 0.75'f
      else:
        max(0.15'f, settings.leafSize *
          (settings.droop + max(0.0'f, settings.curl)) * 0.75'f)
    packedRings = min(64, ceil(settings.crownHeight /
      coveredHeight * settings.packing).int + 1)
    ringCount = max(settings.rings, packedRings)
    # The last leaf ring sits just below the cap, even on sparse tall trees.
    leafTop = 1.0'f - min(0.12'f,
      settings.leafSize * 0.12'f / settings.crownHeight)
  for ring in 0 ..< ringCount:
    let
      t =
        if ring == ringCount - 1:
          1.0'f
        else:
          pow(ring.float32 / max(1, ringCount - 2).float32,
            settings.ringSpacing) * leafTop
      visible = settings.kind != Broadleaf or
        t >= 1.0'f - settings.crownCoverage
      tipFade = min(1.0'f, (1.0'f - t) * settings.crownHeight /
        settings.leafSize)
      irregularity = settings.irregularity * tipFade
      height = settings.crownBase + t * settings.crownHeight
      profile =
        if settings.kind == Evergreen:
          pow(1.0'f - t, settings.crownShape)
        else:
          pow(max(0.0'f, 1.0'f - pow((t - 0.5'f) / 0.53'f, 2.0'f)),
            settings.crownShape)
      radius = settings.crownRadius * max(0.035'f, profile)
      cardSize =
        if settings.kind == Evergreen:
          settings.leafSize
        else:
          settings.leafSize *
            (0.45'f + 0.55'f * sqrt(max(0.0'f, profile)))
      phase = ring.float32 * 2.399963'f * settings.ringOffset
      center = trunk.trunkPoint(height / settings.height)
      offset = vec3(rng.jitter(irregularity), 0,
        rng.jitter(irregularity)) * settings.crownRadius * 0.4'f
    if ring == ringCount - 1:
      crownCenter = vec3(center.x, height, center.z)
      crownSize =
        if settings.kind == Evergreen:
          settings.evergreenRadius(height -
            min(settings.crownHeight * 0.85'f, cardSize * 1.1'f))
        else:
          1.5'f * max(radius, cardSize)
      # The cap replaces the final ring instead of overlapping its planes.
      continue
    for shell in 0 ..< settings.shells:
      let
        shellScale = 1.0'f - shell.float32 * 0.3'f
        coveredWidth = settings.leafSize * settings.leafWidth * trimWidth
        packingRadius =
          if settings.kind == Evergreen:
            settings.evergreenRadius(height - cardSize * EvergreenAspect *
              0.5'f) * shellScale
          else:
            radius * shellScale
        packedCards = ceil(Tau * packingRadius / coveredWidth *
          settings.packing).int
        count = clamp(round(max(settings.cardsPerRing, packedCards).float32 *
          cardDensity).int, 1, 128)
      for i in 0 ..< count:
        let
          angleJitter =
            if settings.kind == Evergreen:
              min(irregularity, Tau / count.float32 * 0.1'f)
            else:
              irregularity
          angle = Tau * i.float32 / count.float32 + phase +
            shell.float32 * 0.7'f + rng.jitter(angleJitter)
          radial = vec3(cos(angle), 0, sin(angle))
          extent = radius * shellScale *
            (1.0'f + rng.jitter(irregularity))
          size = cardSize * (1.0'f + rng.jitter(settings.leafJitter))
          inner = max(0.0'f, extent - size * 0.55'f)
          anchor = vec3(center.x, height, center.z) + offset +
            radial * inner + Up * rng.jitter(irregularity * size)
          shade = 1.0'f - rng.rand(settings.colorVariation.float64).float32
          tile = settings.leafTile(rng)
          roll = rng.jitter(settings.leafJitter * tipFade)
        # Advance the stream for omitted rings to preserve the upper canopy.
        if not visible:
          continue
        if settings.kind == Evergreen:
          geometry.foliage.evergreenCard(
            settings,
            center + offset * 0.2'f,
            anchor.y,
            angle + roll * 0.02'f,
            size,
            size * settings.leafWidth,
            shellScale,
            (extent - radius * shellScale) * 0.2'f,
            tile,
            shade,
            clearance
          )
        else:
          geometry.foliage.leafCard(
            anchor,
            radial,
            size,
            size * settings.leafWidth,
            settings.droop,
            settings.curl,
            roll,
            max(inner + size * 0.5'f, size * 0.5'f),
            tile,
            shade,
            clearance
          )
        inc geometry.cards
  geometry.cap(
    settings,
    crownCenter,
    crownSize,
    clearance
  )
  if settings.separateLeaves:
    geometry.separateFoliage(settings)

proc generateGeometry*(settings: TreeSettings): TreeGeometry =
  ## Builds deterministic bark and foliage without touching GPU state.
  settings.validate()
  var
    rng = initRand(settings.seed.int64)
    trunk: seq[Vec3]
  let phase = rng.rand(Tau.float64).float32
  for i in 0 .. settings.trunkSegments:
    let
      t = i.float32 / settings.trunkSegments.float32
      angle = phase + t * settings.twist * Tau
      bend = settings.bend * t * settings.height * 0.18'f
      zigzag = rng.jitter(settings.bend * 0.22'f) * t
    trunk.add vec3(
      sin(angle) * bend + zigzag,
      t * settings.height,
      cos(angle) * bend - zigzag
    )
  result.bark.tube(
    trunk,
    settings.trunkRadius,
    settings.taper,
    settings.radialSides,
    phase,
    settings.barkDensity,
    endFraction = (if settings.kind == Stump: 0.22'f else: 1.0'f),
    openTop = settings.kind == Stump
  )
  if settings.kind == Stump:
    result.cut.stumpCap(
      result.bark,
      trunk[^1],
      settings.trunkSegments * (settings.radialSides + 1),
      settings.radialSides
    )
  for i in 0 ..< settings.roots:
    let
      angle = phase + Tau * i.float32 / settings.roots.float32
      direction = vec3(cos(angle), 0, sin(angle))
      length = settings.rootSpread * (1.0'f + rng.jitter(0.25'f))
      claw = length * settings.rootClaw
      drop = claw * tan(settings.rootAngle * PI.float32 / 180.0'f)
      knee = min(0.1'f, drop * 0.35'f)
      rootHeight =
        if settings.kind == Stump:
          min(settings.trunkRadius * 0.75'f, settings.height * 0.3'f)
        else:
          settings.trunkRadius * 0.75'f
      rootRadius =
        if settings.kind == Stump:
          min(settings.trunkRadius * settings.rootThickness,
            settings.height * 0.45'f)
        else:
          settings.trunkRadius * settings.rootThickness
      points = [
        Up * rootHeight,
        direction * (length - claw) * 0.5'f + Up * (knee + 0.06'f),
        direction * (length - claw) + Up * knee,
        direction * length + Up * (knee - drop)
      ]
    result.bark.tube(
      points,
      rootRadius,
      1.1'f,
      settings.radialSides,
      angle,
      settings.barkDensity
    )
  for i in 0 ..< settings.branches:
    if settings.kind == Stump:
      break
    let
      clearance = min(settings.stemClearance, settings.height * 0.6'f)
      bottom = max(settings.branchStart,
        min(0.85'f, (clearance + settings.trunkRadius) / settings.height))
      top = (if settings.kind == Broadleaf: 0.76'f else: 0.92'f)
      t = bottom + (max(top, bottom) - bottom) *
        i.float32 / max(1, settings.branches - 1).float32
      origin = trunk.trunkPoint(t)
      radius = taperedRadius(settings.trunkRadius, t, settings.taper) *
        settings.branchRadius
    var
      angle = phase
      length = settings.branchLength * (1.15'f - t * 0.6'f)
    case settings.branchLayout
    of Spiral:
      angle += i.float32 * 2.399963'f
    of Paired:
      angle += (i mod 2).float32 * PI.float32 +
        (i div 2).float32 * 0.5'f
    of Whorled:
      angle += (i mod 5).float32 * Tau / 5.0'f +
        (i div 5).float32 * 0.65'f
    angle += rng.jitter(settings.branchJitter)
    if settings.kind == Evergreen:
      length *= 1.0'f - t * 0.65'f
    length *= 1.0'f + rng.jitter(settings.branchJitter * 0.4'f)
    result.limb(settings, rng, origin, angle, length,
      radius, settings.forks)
  result.canopy(settings, trunk)
  result.minimum = vec3(Inf.float32)
  result.maximum = vec3(-Inf.float32)
  for vertex in result.bark.vertices:
    result.minimum = min(result.minimum, vertex.position)
    result.maximum = max(result.maximum, vertex.position)
  for vertex in result.foliage.vertices:
    result.minimum = min(result.minimum, vertex.position)
    result.maximum = max(result.maximum, vertex.position)
  for vertex in result.cut.vertices:
    result.minimum = min(result.minimum, vertex.position)
    result.maximum = max(result.maximum, vertex.position)

proc loadMaterials*(textureStrength: float32): TreeMaterials =
  ## Loads leaf, repeating bark, and cut-wood textures for the tree materials.
  var atlas, bark, rings: Image
  try:
    atlas = loadTexturePng(TreegenTextures[0])
  except IOError, PixieError:
    raise newException(TreegenError, "Cannot load tree atlas: " &
      getCurrentExceptionMsg())
  if atlas.width != GeneratorTextureSize or
    atlas.height != GeneratorTextureSize:
      raise newException(TreegenError, "Tree atlas must be 512 by 512")
  try:
    bark = loadTexturePng(TreegenTextures[1])
  except IOError, PixieError:
    raise newException(TreegenError, "Cannot load bark texture: " &
      getCurrentExceptionMsg())
  if bark.width != GeneratorTextureSize or
    bark.height != GeneratorTextureSize:
      raise newException(TreegenError, "Bark texture must be 512 by 512")
  try:
    rings = loadTexturePng(TreegenTextures[2])
  except IOError, PixieError:
    raise newException(TreegenError, "Cannot load stump texture: " &
      getCurrentExceptionMsg())
  if rings.width != GeneratorTextureSize or
    rings.height != GeneratorTextureSize:
      raise newException(TreegenError, "Stump texture must be 512 by 512")
  for pixel in bark.data.mitems:
    let
      luminance = min(1.0'f, (pixel.r.float32 * 0.2126'f +
        pixel.g.float32 * 0.7152'f + pixel.b.float32 * 0.0722'f) / 170.0'f)
      value = ((1.0'f - textureStrength +
        luminance * textureStrength) * 255.0'f).uint8
    pixel = rgbx(value, value, value, 255)
  let
    barkSampler = TextureSampler(
      magFilter: LinearMagFilter, minFilter: LinearMipmapLinearMinFilter,
      wrapS: RepeatWrap, wrapT: RepeatWrap)
    leafSampler = TextureSampler(
      magFilter: LinearMagFilter, minFilter: LinearMipmapLinearMinFilter,
      wrapS: ClampToEdgeWrap, wrapT: ClampToEdgeWrap)
  result.bark = Material(
    name: "Tintable bark", baseColor: bark, baseColorSampler: barkSampler,
    baseColorFactor: color(1, 1, 1, 1), roughnessFactor: 1,
    alphaMode: OpaqueAlphaMode)
  result.foliage = Material(
    name: "White foliage", baseColor: atlas, baseColorSampler: leafSampler,
    baseColorFactor: color(1, 1, 1, 1), roughnessFactor: 1,
    alphaMode: MaskAlphaMode, alphaCutoff: 0.45, doubleSided: true)
  result.cut = Material(
    name: "Stump rings", baseColor: rings, baseColorSampler: leafSampler,
    baseColorFactor: color(1, 1, 1, 1), roughnessFactor: 1,
    alphaMode: OpaqueAlphaMode)

proc tint*(materials: TreeMaterials, settings: TreeSettings) =
  ## Updates material factors without rebuilding tree geometry.
  materials.bark.baseColorFactor = color(
    settings.barkColor.x, settings.barkColor.y, settings.barkColor.z, 1)
  materials.foliage.baseColorFactor = color(
    settings.leafColor.x, settings.leafColor.y, settings.leafColor.z, 1)

proc primitive(mesh: TreeMesh, material: Material): Primitive =
  ## Converts flat generator data into the shared toon renderer's format.
  result = Primitive(material: material, mode: TrianglesMode,
    indices32: mesh.indices)
  for vertex in mesh.vertices:
    result.points.add vertex.position
    result.normals.add vertex.normal
    result.uvs.add vertex.uv
    let value = (vertex.shade * 255.0'f).uint8
    result.colors.add rgbx(value, value, value, 255)

proc treeNode*(geometry: TreeGeometry, materials: TreeMaterials): Node =
  ## Makes one node with opaque bark, optional cut wood, and cutout leaves.
  result = Node(name: "Generated tree", visible: true,
    scale: vec3(1), rot: quat(0, 0, 0, 1), mesh: Mesh(name: "Tree"))
  result.mesh.primitives.add geometry.bark.primitive(materials.bark)
  if geometry.foliage.vertices.len > 0:
    result.mesh.primitives.add geometry.foliage.primitive(materials.foliage)
  if geometry.cut.vertices.len > 0:
    result.mesh.primitives.add geometry.cut.primitive(materials.cut)

proc generate*(settings: TreeSettings): Node =
  ## Builds a renderable tree node with its tinted materials and textures.
  let
    geometry = generateGeometry(settings)
    materials = loadMaterials(settings.barkTexture)
  materials.tint(settings)
  treeNode(geometry, materials)
