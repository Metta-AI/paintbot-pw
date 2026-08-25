## Bounds of a skinned model in its current pose.
##
## gltf's getAABounds walks raw mesh points through the node chain, which for
## a skinned character means the bind pose no matter what clip is playing.
## That is the wrong measurement twice over: characters authored T-posed have
## an x extent of arm span, and a bind pose that dips below the ground plane
## says nothing about where the model actually stands once posed. Skinning
## each point the way the vertex shader does gives the silhouette that is
## really on screen.

import
  gltf, vmath

proc posedBoundsWeighted*(
    root: Node, jointWanted: seq[bool], minWeight = 0.5'f32
): AABounds =
  ## Bounds of just the vertices a chosen set of joints controls.
  ##
  ## jointWanted is indexed by skin joint index. A vertex counts when the
  ## wanted joints together own at least minWeight of it, which is what makes
  ## "the head" mean the head plus whatever rides it — snout, horns, helmet —
  ## rather than a guess at a box around a bone. Unskinned attachments are
  ## ignored so a held spear cannot swallow the framing.
  var bounds = AABounds(
    min: vec3(float32.high, float32.high, float32.high),
    max: vec3(float32.low, float32.low, float32.low))

  proc visit(node: Node, trs: Mat4) =
    let world = trs * node.trs
    if node.mesh != nil and node.skin != nil and
        node.skin.joints.len == jointWanted.len:
      var skinning: seq[Mat4]
      for i, joint in node.skin.joints:
        let inverseBind =
          if i < node.skin.inverseBindMatrices.len:
            node.skin.inverseBindMatrices[i]
          else:
            mat4()
        skinning.add joint.mat * inverseBind
      for primitive in node.mesh.primitives:
        for i, point in primitive.points:
          if i >= primitive.jointIds.len or i >= primitive.jointWeights.len:
            continue
          let
            ids = primitive.jointIds[i]
            weights = primitive.jointWeights[i]
          var
            posed: Vec3
            total = 0.0'f32
            wanted = 0.0'f32
          for k in 0 .. 3:
            let weight = weights[k]
            if weight > 0 and ids[k].int < skinning.len:
              posed = posed + (skinning[ids[k].int] * point) * weight
              total += weight
              if jointWanted[ids[k].int]:
                wanted += weight
          if total > 0 and wanted >= minWeight:
            bounds.min = min(bounds.min, posed)
            bounds.max = max(bounds.max, posed)
    for child in node.nodes:
      visit(child, world)

  visit(root, mat4())
  bounds

proc posedBoundsAbove*(root: Node, floorY: float32): AABounds =
  ## Bounds of just the posed vertices above a height.
  ##
  ## The last resort for framing something with no nameable face at all: a
  ## vehicle's upper structure still reads better as a portrait than the
  ## whole silhouette does.
  var bounds = AABounds(
    min: vec3(float32.high, float32.high, float32.high),
    max: vec3(float32.low, float32.low, float32.low))

  proc visit(node: Node, trs: Mat4) =
    let world = trs * node.trs
    if node.mesh != nil and node.skin != nil:
      var skinning: seq[Mat4]
      for i, joint in node.skin.joints:
        let inverseBind =
          if i < node.skin.inverseBindMatrices.len:
            node.skin.inverseBindMatrices[i]
          else:
            mat4()
        skinning.add joint.mat * inverseBind
      for primitive in node.mesh.primitives:
        for i, point in primitive.points:
          if i >= primitive.jointIds.len or i >= primitive.jointWeights.len:
            continue
          let
            ids = primitive.jointIds[i]
            weights = primitive.jointWeights[i]
          var
            posed: Vec3
            total = 0.0'f32
          for k in 0 .. 3:
            let weight = weights[k]
            if weight > 0 and ids[k].int < skinning.len:
              posed = posed + (skinning[ids[k].int] * point) * weight
              total += weight
          if total > 0 and posed.y >= floorY:
            bounds.min = min(bounds.min, posed)
            bounds.max = max(bounds.max, posed)
    for child in node.nodes:
      visit(child, world)

  visit(root, mat4())
  bounds

proc posedBounds*(root: Node, visibleOnly = false): AABounds =
  ## Bounds of posed vertices, optionally skipping hidden nodes.
  var bounds = AABounds(
    min: vec3(float32.high, float32.high, float32.high),
    max: vec3(float32.low, float32.low, float32.low))

  proc visit(node: Node, trs: Mat4) =
    if visibleOnly and not node.visible:
      return
    let world = trs * node.trs
    if node.mesh != nil:
      var skinning: seq[Mat4]
      if node.skin != nil:
        for i, joint in node.skin.joints:
          let inverseBind =
            if i < node.skin.inverseBindMatrices.len:
              node.skin.inverseBindMatrices[i]
            else:
              mat4()
          skinning.add joint.mat * inverseBind
      for primitive in node.mesh.primitives:
        for i, point in primitive.points:
          var posed: Vec3
          if skinning.len > 0 and i < primitive.jointIds.len and
              i < primitive.jointWeights.len:
            let
              ids = primitive.jointIds[i]
              weights = primitive.jointWeights[i]
            var total = 0.0'f32
            for k in 0 .. 3:
              let weight = weights[k]
              if weight > 0 and ids[k].int < skinning.len:
                posed = posed + (skinning[ids[k].int] * point) * weight
                total += weight
            if total <= 0:
              posed = world * point
          else:
            posed = world * point
          bounds.min = min(bounds.min, posed)
          bounds.max = max(bounds.max, posed)
    for child in node.nodes:
      visit(child, world)

  visit(root, mat4())
  bounds

proc poseAt*(root: Node, clip: int, seconds: float32) =
  ## Poses a model at a clip time, including the world matrices that
  ## posedBounds reads — updateAnimation alone only writes local TRS.
  root.activeClips = if clip >= 0: @[clip] else: @[]
  root.animTime = 0
  root.updateAnimation(seconds)
  root.updateTransforms()
