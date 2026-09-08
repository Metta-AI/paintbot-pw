# Exports the original procedural comparison textures for inspection.
# Imagegen artwork is stored separately in textures/generated.
# Run with nim r experiments/windwaker_water/gen_textures.nim.

import std/os, pixie, textures

const Directory = "experiments/windwaker_water/textures"

proc main() =
  ## Saves the procedural masks without touching the imagegen artwork.
  createDir(Directory)
  let sheet = [
    ("foam_lattice", foamLattice()),
    ("sea_preview", seaPreview()),
    ("warp_map", warpMap()),
    ("shore_foam", shoreFoam()),
    ("shore_mask", shoreMask()),
    ("crest_foam", crestFoam()),
    ("band_foam", bandFoam()),
    ("shore_lattice", shoreLattice())
  ]
  for (name, image) in sheet:
    let path = Directory / name & ".png"
    image.writeFile(path)
    echo "wrote ", path

main()
