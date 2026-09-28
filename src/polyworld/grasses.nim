import
  std/math,
  chroma, gltf, vmath

proc grassNodes*(): Node =
  ## Builds four original CC0 grass tufts with bent, double-sided blades.
  result = Node(scale: vec3(1), rot: quat(0, 0, 0, 1))
  for i in 0 ..< 4:
    let
      material = Material(
        baseColorFactor: color(0.36 + i.float32 * 0.025, 0.56, 0.19, 1),
        roughnessFactor: 1, doubleSided: true
      )
      primitive = Primitive(material: material, mode: TrianglesMode)
      node = Node(
        name: "Grass" & $i, scale: vec3(1), rot: quat(0, 0, 0, 1),
        mesh: Mesh(primitives: @[primitive])
      )
    for j in 0 ..< 7:
      let
        angle = j.float32 * 2.399963'f + i.float32 * 0.37'f
        outward = vec3(cos(angle), 0, sin(angle))
        side = vec3(-sin(angle), 0, cos(angle))
        base = outward * (0.03'f + (j mod 3).float32 * 0.06'f)
        height = 0.35'f + ((j * 3 + i) mod 7).float32 * 0.055'f
        width = 0.025'f + (j mod 3).float32 * 0.007'f
        middle = base + vec3(0, height * 0.58'f, 0) + outward * 0.06'f
        tip = base + vec3(0, height, 0) + outward * 0.21'f
        points = [base - side * width, base + side * width,
          middle + side * width * 0.6'f, middle - side * width * 0.6'f,
          tip]
        start = primitive.points.len.uint32
      for point in points:
        primitive.points.add point
        primitive.normals.add normalize(side.cross(tip - base))
      for index in [0'u32, 1, 2, 0, 2, 3, 3, 2, 4,
          2, 1, 0, 3, 2, 0, 4, 2, 3]:
        primitive.indices32.add start + index
    result.nodes.add node
