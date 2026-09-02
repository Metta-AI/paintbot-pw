## FX mesh builder tests that do not need a GPU context.

import
  polyworld/clickmarks,
  polyworld/fxmeshes

echo "Testing fx life"
doAssert fxLife(0, 1, false) == 0
doAssert fxLife(1, 1, false) == 1
doAssert fxLife(0.5'f32, 1, false) > 0
doAssert fxLife(0.5'f32, 1, false) < 1
doAssert fxLife(1.25'f32, 1, true) > 0
doAssert fxLife(1.25'f32, 1, true) < 1

echo "Testing click cylinder mesh"
let
  settings = clickMarkSettings()
  mesh = buildFxMesh(settings)
doAssert settings.shape == CylinderShape
doAssert settings.expandStart == ClickMarkStartScale
doAssert settings.expandEnd == ClickMarkEndScale
doAssert mesh.vertices.len > 0
doAssert mesh.indices.len > 0
doAssert mesh.vertices.len mod 12 == 0
doAssert mesh.indices.len mod 3 == 0
