## Flattens the Sketchfab low-poly tree pack node hierarchy.
##
## The exported file nests every model as
## Sketchfab_Scene > Sketchfab_model > ...fbx > RootNode > _N_tree > mesh,
## with transforms spread across the levels. This tool bakes each mesh's
## accumulated world transform into a single node, renames the nodes to
## tree1, tree2, ... rock1, keeps the original world positions (so the
## models don't pile up on each other), and writes the result back as a
## flat root > tree1..treeN, rock1 hierarchy.
##
## Usage (from the repo root):
##   nim r tools/flatten_trees.nim [input.glb] [output.glb] [kind]
## Defaults to rewriting ../polyworld_data/terrain/low_poly_trees.glb in place. The
## optional kind (tree/grass/rock/prop) forces every node to that name,
## for packs whose node names carry no useful keyword (e.g. "Icosphere").
## The special kind "keep" keeps each node's own cleaned source name:
## "Tower_Square_Tall.001_0" becomes tower_square_tall1, tower_square_tall2...

import std/[os, strutils, algorithm, tables], gltf, vmath

let
  params = commandLineParams()
  inputPath = if params.len > 0: params[0] else: "../polyworld_data/terrain/low_poly_trees.glb"
  outputPath = if params.len > 1: params[1] else: inputPath
  kindOverride = if params.len > 2: params[2] else: ""

let file = readGltfFile(inputPath)

proc localMatrix(node: Node): Mat4 =
  translate(node.pos) * node.rot.mat4 * scale(node.scale)

proc firstNumber(raw: string): int =
  ## The first run of digits — leaf names repeat, e.g. "_1_tree__1_tree_0".
  var digits = ""
  for ch in raw:
    if ch.isDigit:
      digits.add ch
    elif digits.len > 0:
      break
  if digits.len > 0: digits.parseInt else: 0

proc keywordBase(raw: string): string =
  ## Maps a node name onto a known kind keyword.
  let lower = raw.toLowerAscii
  if "tree" in lower: "tree"
  elif "grass" in lower: "grass"
  elif "rock" in lower: "rock"
  else: "prop"

proc stripDigitSuffix(name: var string, separator: char): int =
  ## Removes a trailing "<separator><digits>" and returns the digits, or 0.
  let cut = name.rfind(separator)
  if cut < 0 or cut >= name.len - 1:
    return 0
  for ch in name[cut + 1 .. ^1]:
    if not ch.isDigit:
      return 0
  result = name[cut + 1 .. ^1].parseInt
  name.setLen(cut)

proc sourceBase(raw: string): (string, int) =
  ## Cleans a source name, keeping its meaning: mesh leaves append "_<n>",
  ## duplicates carry ".NNN", and some names end in bare digits, so
  ## "Tower_Square_Tall.001_0" -> ("tower_square_tall", 1) and
  ## "carrot1" -> ("carrot", 1).
  var name = raw
  let meshIndex = name.stripDigitSuffix('_')
  let duplicate = name.stripDigitSuffix('.')
  var cut = name.len
  while cut > 0 and name[cut - 1].isDigit:
    dec cut
  var bare = 0
  if cut < name.len and cut > 0:
    bare = name[cut .. ^1].parseInt
    name.setLen(cut)
  let number =
    if duplicate > 0: duplicate
    elif bare > 0: bare
    else: meshIndex
  (name.toLowerAscii, number)

proc meaningful(name: string): bool =
  ## Filters exporter wrapper names that carry no meaning.
  if name.len == 0:
    return false
  if name in ["Root", "RootNode", "Sketchfab_model", "Sketchfab_Scene"]:
    return false
  if name.endsWith(".fbx"):
    return false
  if name.startsWith("Object_"):
    var digits = name.len > 7
    for ch in name[7 .. ^1]:
      if not ch.isDigit:
        digits = false
        break
    if digits:
      return false
  true

var flattened: seq[tuple[order: (string, int), node: Node]]

proc walk(node: Node, parent: Mat4, ancestorName: string) =
  ## Group names like "_1_tree" or "barrel" live above the mesh leaves
  ## (whose own names often carry material junk), so carry the nearest
  ## meaningful ancestor name down to the mesh node.
  let
    world = parent * node.localMatrix
    name = if node.name.len > 0: node.name else: ancestorName
  if node.mesh != nil:
    let order =
      if kindOverride == "keep":
        sourceBase(if meaningful(ancestorName): ancestorName else: name)
      elif kindOverride.len > 0:
        (kindOverride, firstNumber(name))
      else:
        (keywordBase(name), firstNumber(name))
    let
      sx = vec3(world[0, 0], world[0, 1], world[0, 2]).length
      sy = vec3(world[1, 0], world[1, 1], world[1, 2]).length
      sz = vec3(world[2, 0], world[2, 1], world[2, 2]).length
    var rotation = world.rotationOnly
    if sx != 0: rotation[0, 0] /= sx; rotation[0, 1] /= sx; rotation[0, 2] /= sx
    if sy != 0: rotation[1, 0] /= sy; rotation[1, 1] /= sy; rotation[1, 2] /= sy
    if sz != 0: rotation[2, 0] /= sz; rotation[2, 1] /= sz; rotation[2, 2] /= sz
    flattened.add((order, Node(
      visible: true,
      pos: world.pos,
      rot: rotation.quat,
      scale: vec3(sx, sy, sz),
      mesh: node.mesh
    )))
  for child in node.nodes:
    walk(child, world, if meaningful(node.name): node.name else: ancestorName)

walk(file.root, mat4(), "")
flattened.sort(proc(a, b: auto): int = cmp(a.order, b.order))

# Renumber sequentially within each base name (source numbering can be
# sparse, e.g. Blender's Wall.002), so names come out wall1..wallN.
var baseCounters = initTable[string, int]()
for entry in flattened.mitems:
  let count = baseCounters.getOrDefault(entry.order[0], 0) + 1
  baseCounters[entry.order[0]] = count
  entry.node.name = entry.order[0] & $count

let root = Node(
  name: "root",
  visible: true,
  pos: vec3(0, 0, 0),
  rot: quat(0, 0, 0, 1),
  scale: vec3(1, 1, 1)
)
for entry in flattened:
  root.nodes.add(entry.node)
  echo entry.node.name, " scale=", entry.node.scale

writeGLB(root, outputPath)
echo "Wrote ", root.nodes.len, " nodes to ", outputPath
