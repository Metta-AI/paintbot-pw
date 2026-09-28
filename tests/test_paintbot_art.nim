import
  std/math,
  vmath,
  polyworld/[grasses, rockgen, treegen]

proc checkMesh(mesh: TreeMesh) =
  ## Checks finite positions, unit normals, and nondegenerate triangles.
  doAssert mesh.indices.len mod 3 == 0
  for index in mesh.indices:
    doAssert index.int < mesh.vertices.len
  for vertex in mesh.vertices:
    for i in 0 ..< 3:
      doAssert classify(vertex.position[i]) notin {fcNan, fcInf, fcNegInf}
    doAssert abs(length(vertex.normal) - 1) < 0.001
  for i in countup(0, mesh.indices.high, 3):
    let
      a = mesh.vertices[mesh.indices[i]].position
      b = mesh.vertices[mesh.indices[i + 1]].position
      c = mesh.vertices[mesh.indices[i + 2]].position
    doAssert length(cross(b - a, c - a)) > 0.00000001'f

proc testTrees() =
  ## Checks repeatable generated meshes for every tree style we ship.
  for i in 0 ..< 6:
    let
      settings = treegen.preset(i, seed = 42)
      geometry = treegen.generateGeometry(settings)
    doAssert geometry == treegen.generateGeometry(settings)
    geometry.bark.checkMesh()
    geometry.foliage.checkMesh()
    doAssert geometry.cards > 0
    doAssert geometry.maximum.y > geometry.minimum.y

proc testRocks() =
  ## Checks original boulders retain valid indexed geometry after floor cuts.
  for i in [1, 3, 5]:
    var settings = rockgen.preset(i, seed = 923)
    settings.floorCut = 0.3'f
    settings.removeBottom = true
    let geometry = rockgen.generateGeometry(settings)
    doAssert geometry == rockgen.generateGeometry(settings)
    for index in geometry.mesh.indices:
      doAssert index.int < geometry.mesh.vertices.len
    doAssert geometry.maximum.y > geometry.minimum.y

proc testGrass() =
  ## Checks the small original grass bank has valid double-sided blades.
  let nodes = grassNodes().nodes
  doAssert nodes.len == 4
  for node in nodes:
    let mesh = node.mesh.primitives[0]
    doAssert mesh.points.len == 35
    doAssert mesh.indices32.len == 126
    for index in mesh.indices32:
      doAssert index.int < mesh.points.len
    for normal in mesh.normals:
      doAssert abs(normal.length - 1) < 0.001

testTrees()
testRocks()
testGrass()
echo "CC0 procedural art passed"
