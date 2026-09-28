import
  chroma, gltf, vmath,
  polyworld/[common, naturalassets, pathing, quadterrain, rockgen, treegen]

const
  TreeNames* = ["Oak", "Sapling", "Autumn", "Spruce", "Fir", "Pine"]
  BushNames* = ["Bush", "RoundBush", "GoldenBush", "MeadowBush"]
  FlowerNames* = ["flowers_white", "flowers_gold", "flowers_blue"]
  RockNames* = ["Boulder", "RiverStone", "Fieldstone"]
  HouseNames* = [
    "round-cottage", "mushroom-house", "stump-house", "spiral-house"
  ]

type
  Scenery* = object
    homes*, plants*, rocks*, details*, well*: PropPack

proc material(source: Material, tint: Vec3): Material =
  ## Shares an image while retaining independent colors for each variant.
  new(result)
  result[] = source[]
  result.baseColorFactor = color(tint.x, tint.y, tint.z, 1)

proc loadWholeModel(path, name: string): Node =
  ## Combines a CC0 model's parts with their original relative transforms.
  result = Node(name: name, scale: vec3(1), rot: quat(0, 0, 0, 1),
    mesh: Mesh(name: name))
  let mesh = result.mesh
  proc gather(node: Node, parent: Mat4) =
    ## Bakes each part into the single prop's local coordinates.
    let
      matrix = parent * translate(node.pos) * node.rot.mat4 * scale(node.scale)
      normals = matrix.inverse.transpose
    if node.mesh != nil:
      for source in node.mesh.primitives:
        let primitive = Primitive(
          material: source.material, mode: source.mode,
          indices32: source.indices32, indices16: source.indices16,
          uvs: source.uvs, colors: source.colors
        )
        for point in source.points:
          primitive.points.add matrix * point
        for normal in source.normals:
          let transformed = normals * vec4(normal.x, normal.y, normal.z, 0)
          primitive.normals.add normalize(vec3(
            transformed.x, transformed.y, transformed.z
          ))
        mesh.primitives.add primitive
    for child in node.nodes:
      gather(child, matrix)
  gather(readGltfFile(path).root, mat4())

proc createScenery*(): Scenery =
  ## Builds a reusable bank of CC0 trees, bushes, rocks, and village props.
  let
    treeMaterials = treegen.loadMaterials(1)
    rockMaterials = rockgen.loadMaterials()
  var treeNodes, rockNodes: seq[Node]
  for i in 0 ..< TreeNames.len + BushNames.len:
    var settings = treegen.preset(
      if i < TreeNames.len: [0, 2, 1, 3, 4, 5][i] else: 2,
      seed = 417 + i * 997
    )
    settings.radialSides = 5
    settings.trunkSegments = 6
    settings.branchSegments = 3
    settings.branches = 4
    settings.forks = 0
    settings.rings = 6
    settings.cardsPerRing = 7
    settings.density = 0.8'f
    settings.shells = 1
    settings.leafColor = [
      vec3(0.42, 0.62, 0.21), vec3(0.52, 0.68, 0.25),
      vec3(0.71, 0.66, 0.23), vec3(0.30, 0.51, 0.29)
    ][i mod 4]
    let
      materials = TreeMaterials(
        bark: material(treeMaterials.bark, settings.barkColor),
        foliage: material(treeMaterials.foliage, settings.leafColor),
        cut: treeMaterials.cut
      )
      node = treegen.treeNode(treegen.generateGeometry(settings), materials)
    if i < TreeNames.len:
      node.name = TreeNames[i]
    else:
      node.name = BushNames[i - TreeNames.len]
      node.scale = vec3(1.1, 0.48, 1.1)
    treeNodes.add node
  for i, name in RockNames:
    var settings = rockgen.preset([1, 3, 5][i], seed = 923 + i)
    settings.floorCut = 0.3'f
    settings.removeBottom = true
    settings.tint = vec3(0.72, 0.75, 0.67)
    let node = rockgen.rockNode(
      rockgen.generateGeometry(settings),
      RockMaterials(stone: material(rockMaterials.stone, settings.tint))
    )
    node.name = name
    rockNodes.add node
  result.well = createPropPack(@[loadWholeModel(
    DataRoot & "/terrain/blender_village/models/well.glb", "Well"
  )])
  result.plants = createPropPack(treeNodes, repeatTexture = true)
  result.rocks = createPropPack(rockNodes, mipmaps = false)
  result.homes = loadPropPack(
    DataRoot & "/paintbot/models/round-village.glb", unitHeight = false
  )
  result.details = loadPropPack(
    DataRoot & "/terrain/heartleaf/models/village_details.glb",
    textured = true, maxTextureSize = GeneratorTextureSize,
    only = @["flowers_white", "flowers_gold", "flowers_blue", "lupins",
      "market", "beehive", "bucket_planter", "bench", "eave_clover"]
  )

proc placeForest*(scenery: Scenery) =
  ## Replaces the boundary's tree tiles without changing their walkability.
  if layers.len == 0:
    return
  let ground = layers[0]
  for z in 0 ..< ground.depth:
    for x in 0 ..< ground.width:
      let tile = ground.tiles[z * ground.width + x]
      if not tile.exists or tile.kind != TreeTile:
        continue
      let
        heights = tile.tops.unpack
        i = (x * 17 + z * 31) mod TreeNames.len
        position = vec3(
          (ground.originX + x).float32 - HalfGrid + 0.5,
          (heights[0] + heights[1] + heights[2] + heights[3]) / 4,
          (ground.originZ + z).float32 - HalfGrid + 0.5
        )
      scenery.plants.placeProp(
        TreeNames[i], position, i.float32 * 0.7, 5.0 + i.float32 * 0.2
      )
