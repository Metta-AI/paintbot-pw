## Headless check that a converted character glb loads through the gltf
## reader the way the game will: clips present and named, bind-pose bounds
## sane, and every material's base color image actually resolved — which for
## the mini legion packs means the sidecar png next to the glb was found.
##
## Run from the repo root:
##   nim r tools/check_glb.nim ../polyworld_data/characters/mini_legion/human/footman.glb
##
## Exits non-zero when a model fails, so it can drive a whole-pack sweep.

import
  std/[os, strformat, strutils],
  gltf, vmath,
  posedbounds

const GroundClip = "Idle"  ## prefix of the clip a model is judged standing in

var failures = 0

proc check(path: string) =
  var problems: seq[string]
  let file = readGltfFile(path)
  let
    bounds = file.root.getAABounds()
    height = bounds.max.y - bounds.min.y

  # Static props carry no skin and no clips; only a skinned character with
  # nothing to play is broken.
  let skinned = file.skins.len > 0
  if skinned and file.root.animations.len == 0:
    problems.add "skinned model has no animation clips"
  for clip in file.root.animations:
    if clip.name.len == 0:
      problems.add "an animation clip has no name"
    if clip.duration <= 0:
      problems.add &"clip {clip.name} has duration {clip.duration}"

  var
    materials = 0
    meshNodes = 0
  proc visit(node: Node) =
    if node.mesh != nil:
      inc meshNodes
      for primitive in node.mesh.primitives:
        inc materials
        let material = primitive.material
        if material == nil:
          problems.add "primitive has no material"
        elif material.baseColor == nil:
          problems.add "material has no base color image"
        elif material.baseColor.width <= 1 or material.baseColor.height <= 1:
          problems.add &"base color is a {material.baseColor.width}x" &
            &"{material.baseColor.height} placeholder"
    for child in node.nodes:
      visit(child)
  visit(file.root)
  if materials == 0:
    problems.add "no materials"

  if height <= 0.001:
    problems.add &"degenerate height {height}"

  # Judge the ground plane by the idle pose, not the bind pose: several rigs
  # are authored with limbs below the origin in bind and only stand up once
  # a clip is applied. Flyers hover, so a positive offset is fine; sinking
  # into the ground is not.
  var idle = -1
  for i, animation in file.root.animations:
    if animation.name.startsWith(GroundClip):
      idle = i
      break
  if idle < 0 and file.root.animations.len > 0:
    idle = 0
  var standing = bounds.min.y
  if idle >= 0:
    file.root.poseAt(idle, 0.5'f32)
    standing = posedBounds(file.root).min.y
  # Scaled to the model, since a couple of centimetres of planted foot is
  # authored art on a three-unit-tall figure but a real break on a small one.
  let sinkLimit = max(0.05'f32, height * 0.05'f32)
  if standing < -sinkLimit:
    problems.add &"model sits {-standing} below the ground plane when posed"

  let clips = block:
    var names: seq[string]
    for clip in file.root.animations:
      names.add clip.name
    names.join(" ")
  echo &"{path.lastPathPart:26s} h={height:6.3f} y0={standing:+6.3f} " &
    &"clips={file.root.animations.len:2d}  {clips}"
  for problem in problems:
    echo &"  FAIL {problem}"
    inc failures

let paths = commandLineParams()
if paths.len == 0:
  quit("usage: check_glb <model.glb> [more.glb ...]", 1)
for path in paths:
  check(path)
if failures > 0:
  quit(&"{failures} problem(s)", 1)
echo &"checked {paths.len} model(s), all good"
