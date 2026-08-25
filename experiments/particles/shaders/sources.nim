## Shady-generated particle shader sources for every supported backend target.

import
  shady,
  billboards, fragments

const
  BillboardDesktop* = toShader(
    billboardVertex,
    glsl4Desktop,
    shaderVertex
  )
  StretchedDesktop* = toShader(
    stretchedVertex,
    glsl4Desktop,
    shaderVertex
  )
  AlphaDesktop* = toShader(
    softAlphaFragment,
    glsl4Desktop,
    shaderFragment
  )
  AdditiveDesktop* = toShader(
    softAdditiveFragment,
    glsl4Desktop,
    shaderFragment
  )
  BillboardWeb* = toShader(
    billboardVertex,
    glsl3WebGL,
    shaderVertex
  )
  StretchedWeb* = toShader(
    stretchedVertex,
    glsl3WebGL,
    shaderVertex
  )
  AlphaWeb* = toShader(
    softAlphaFragment,
    glsl3WebGL,
    shaderFragment
  )
  AdditiveWeb* = toShader(
    softAdditiveFragment,
    glsl3WebGL,
    shaderFragment
  )
  BillboardVulkan* = toShader(
    billboardVertex,
    vulkanGlsl450,
    shaderVertex
  )
  StretchedVulkan* = toShader(
    stretchedVertex,
    vulkanGlsl450,
    shaderVertex
  )
  AlphaVulkan* = toShader(
    softAlphaFragment,
    vulkanGlsl450,
    shaderFragment
  )
  AdditiveVulkan* = toShader(
    softAdditiveFragment,
    vulkanGlsl450,
    shaderFragment
  )
  BillboardHlsl* = toHLSL(billboardVertex, shaderVertex)
  StretchedHlsl* = toHLSL(stretchedVertex, shaderVertex)
  AlphaHlsl* = toHLSL(softAlphaFragment, shaderFragment)
  AdditiveHlsl* = toHLSL(softAdditiveFragment, shaderFragment)
  BillboardMetal* = toMSL(billboardVertex, shaderVertex)
  StretchedMetal* = toMSL(stretchedVertex, shaderVertex)
  AlphaMetal* = toMSL(softAlphaFragment, shaderFragment)
  AdditiveMetal* = toMSL(softAdditiveFragment, shaderFragment)
