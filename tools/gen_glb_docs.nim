## Generates factual Markdown sidecars for binary glTF assets.
##
## Run from the repository root:
##   nim r tools/gen_glb_docs.nim --write ../polyworld_data/characters/model.glb
##   nim r tools/gen_glb_docs.nim --depth=3 ../polyworld_data/terrain/pack.glb

import
  std/[os, strformat, strutils],
  gltf

const DefaultDepth = 2

type
  GlbDocsError = object of CatchableError

  Options = object
    depth: int
    force: bool
    write: bool
    paths: seq[string]

  Stats = object
    meshes: int
    nodes: int
    textures: seq[string]

proc displayName(path: string): string =
  ## Converts a GLB file name into a readable Markdown title.
  for word in path.splitFile.name.split('_'):
    if word.len > 0:
      if result.len > 0:
        result.add ' '
      result.add word[0].toUpperAscii()
      if word.len > 1:
        result.add word[1 .. ^1]

proc addUnique(values: var seq[string], value: string) =
  ## Adds a nonempty string only when it is not already present.
  if value.len > 0 and value notin values:
    values.add value

proc inspect(node: Node, stats: var Stats) =
  ## Collects node, mesh, and texture facts from one node subtree.
  inc stats.nodes
  if node.mesh != nil:
    inc stats.meshes
    for primitive in node.mesh.primitives:
      if primitive.material != nil:
        stats.textures.addUnique primitive.material.baseColorName
  for child in node.nodes:
    inspect(child, stats)

proc nodeLabel(node: Node): string =
  ## Returns a concise node label with its render role when applicable.
  result =
    if node.name.len > 0:
      node.name
    else:
      "unnamed node"
  if node.mesh != nil:
    if node.skin != nil:
      result.add " (skinned mesh)"
    else:
      result.add " (mesh)"

proc appendNode(
  lines: var seq[string],
  node: Node,
  prefix: string,
  isLast: bool,
  isRoot: bool,
  depth: int,
  maxDepth: int
) =
  ## Appends an abridged monospace tree for one node subtree.
  let connector =
    if isRoot:
      ""
    elif isLast:
      "└── "
    else:
      "├── "
  lines.add prefix & connector & node.nodeLabel()
  if node.nodes.len == 0:
    return
  let childPrefix =
    if isRoot:
      prefix
    elif isLast:
      prefix & "    "
    else:
      prefix & "│   "
  if depth >= maxDepth:
    lines.add childPrefix & "└── ..."
    return
  for i, child in node.nodes:
    lines.appendNode(
      child,
      childPrefix,
      i == node.nodes.high,
      false,
      depth + 1,
      maxDepth
    )

proc nodeChart(root: Node, maxDepth: int): seq[string] =
  ## Builds a compact chart from the selected scene's root nodes.
  if root.nodes.len == 1:
    result.appendNode(root.nodes[0], "", true, true, 0, maxDepth)
  else:
    result.add "Scene"
    for i, node in root.nodes:
      result.appendNode(
        node,
        "",
        i == root.nodes.high,
        false,
        0,
        maxDepth
      )

proc quantity(value: int, singular: string, plural: string): string =
  ## Formats a number with the correct singular or plural noun.
  if value == 1:
    &"1 {singular}"
  else:
    &"{value} {plural}"

proc contents(file: GltfFile, stats: Stats): string =
  ## Summarizes the model structure in one factual sentence.
  let meshes = stats.meshes.quantity("mesh", "meshes")
  if file.skins.len > 0:
    let
      skins = file.skins.len.quantity("skin", "skins")
      clips = file.root.animations.len.quantity("animation", "animations")
    &"One rigged model with {meshes}, {skins}, and {clips}."
  else:
    &"One static model with {meshes} and no animations."

proc markdown(path: string, depth: int): string =
  ## Generates the Markdown sidecar text for one GLB file.
  let file = readGltfFile(path)
  var stats: Stats
  for node in file.root.nodes:
    inspect(node, stats)
  var lines = @[
    "# " & path.displayName(),
    "",
    "- **Asset:** TODO: Describe the model's appearance and identity.",
    "- **Format:** Binary glTF 2.0.",
    "- **Contents:** " & file.contents(stats),
  ]
  if stats.textures.len > 0:
    let names = stats.textures.join("`, `")
    lines.add "- **Material textures:** `" & names & "`"
  lines.add "- **Useful for:** TODO: Describe likely game roles or uses."
  lines.add ""
  lines.add "## Node chart"
  lines.add ""
  lines.add "The chart is abridged after depth " & $depth & "."
  lines.add ""
  lines.add "```text"
  lines.add file.root.nodeChart(depth)
  lines.add "```"
  lines.add ""
  lines.add "## Animations available"
  lines.add ""
  if file.root.animations.len == 0:
    lines.add "- None. This model is static."
  else:
    for animation in file.root.animations:
      lines.add "- `" & animation.name & "`"
  result = lines.join("\n") & "\n"

proc parseDepth(value: string): int =
  ## Parses and validates a nonnegative hierarchy depth.
  try:
    result = value.parseInt()
  except ValueError as error:
    raise newException(
      GlbDocsError,
      &"invalid hierarchy depth {value.escape()}: {error.msg}"
    )
  if result < 0:
    raise newException(
      GlbDocsError,
      &"hierarchy depth must be nonnegative, got {result}"
    )

proc parseOptions(params: seq[string]): Options =
  ## Parses command-line options and input GLB paths.
  result.depth = DefaultDepth
  for param in params:
    case param
    of "--force":
      result.force = true
    of "--write":
      result.write = true
    else:
      if param.startsWith("--depth="):
        result.depth = param["--depth=".len .. ^1].parseDepth()
      elif param.startsWith("-"):
        raise newException(GlbDocsError, "unknown option " & param)
      elif param.splitFile.ext.toLowerAscii() != ".glb":
        raise newException(GlbDocsError, "expected a .glb file: " & param)
      else:
        result.paths.add param
  if result.paths.len == 0:
    raise newException(
      GlbDocsError,
      "usage: gen_glb_docs [--write] [--force] [--depth=N] <model.glb> ..."
    )

proc generate(options: Options) =
  ## Prints or writes Markdown for every requested GLB file.
  for i, path in options.paths:
    let text = path.markdown(options.depth)
    if options.write:
      let output = path.changeFileExt("md")
      if output.fileExists() and not options.force:
        raise newException(
          GlbDocsError,
          "refusing to overwrite existing sidecar: " & output
        )
      output.writeFile(text)
      echo "wrote " & output
    else:
      if i > 0:
        echo ""
      stdout.write text

proc main() =
  ## Parses the command line and generates all requested sidecars.
  commandLineParams().parseOptions().generate()

main()
