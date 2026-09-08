import
  std/os,
  pixie,
  textures

const AssetDirectory* = currentSourcePath.parentDir / "textures/generated"

type
  WaterError* = object of CatchableError
  TextureSource* = enum
    Generated, Procedural
  TextureKind* = enum
    SeaLattice, Warp, ShoreLace, Crest, Band, ContactFoam, Coverage
  WaterImages* = array[TextureKind, Image]

proc readAsset(name: string): Image {.raises: [WaterError].} =
  ## Loads one generated mask and reports its path on failure.
  let path = AssetDirectory / name & ".png"
  try:
    result = readImage(path)
  except IOError, OSError, PixieError:
    raise newException(
      WaterError,
      "Cannot load " & path & ": " & getCurrentExceptionMsg()
    )
  if result.width < 64 or result.height < 64:
    raise newException(WaterError, "Water texture is too small: " & path)

proc loadImages*(source: TextureSource): WaterImages =
  ## Loads imagegen artwork or the original procedural comparison set.
  case source
  of Generated:
    result[SeaLattice] = readAsset("foam_lattice_thick")
    result[Warp] = readAsset("warp_map")
    result[ShoreLace] = readAsset("shore_lattice")
    result[Crest] = readAsset("crest_foam")
    result[Band] = readAsset("band_foam")
    result[ContactFoam] = readAsset("shore_foam")
  of Procedural:
    result[SeaLattice] = foamLattice()
    result[Warp] = warpMap()
    result[ShoreLace] = shoreLattice()
    result[Crest] = crestFoam()
    result[Band] = bandFoam()
    result[ContactFoam] = shoreFoam()
  result[Coverage] = shoreMask()
