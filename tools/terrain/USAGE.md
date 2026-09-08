# Terrain PNG tools

For the complete image generation and asset authoring process, see
[Making terrain tiles and stamps](../../docs/terrain.md).

These tools use Nim and Pixie. Python is not required. Keep image generation,
inpainting, background removal, and seam repair at the original high resolution.
Only final exports with `cut`, `resize`, or `stamp-height` scale assets to
256x256 pixels.

Working pixel data stays in straight RGBA form, preserving faint alpha and hidden
RGB during crops, offsets, and PNG round trips. Final exports use Pixie's
premultiplied alpha filtering to avoid dark or colored fringes around stamps.

Build from the polyworld root:

```sh
nim c -d:release --out:tmp/terrain tools/terrain/terrain.nim
tmp/terrain --help
```

Terrain command outputs are PNG files. Existing output files are rejected unless
`--force` is supplied. Dimensions must divide the requested grid exactly. Inputs
and outputs are limited to 64M pixels. `cut`, `resize`, and `stamp-height`
default to 256x256 cells;
`--size N` selects another power of two from 4 through 8192. Other processing
commands keep the source resolution. A 3x3 working atlas or repeat preview is not
itself a power-of-two texture; the individual exported assets are.

## Export finished assets

```sh
tmp/terrain cut sheet.png outputDirectory
tmp/terrain cut sheet.png outputDirectory 4 2 ground
tmp/terrain resize finished-stamp.png stamp.rgb.png
tmp/terrain resize finished-tile.png tile.rgb.png --size 256
```

The default 3x3 grid writes `grass-1.rgb.png` through `grass-3.rgb.png`, then
`rocks-1.rgb.png` through `rocks-3.rgb.png`, then `path-1.rgb.png` through
`path-3.rgb.png`. Other grids use `tile-N.rgb.png`, or the supplied prefix such
as `ground-N.rgb.png`. Use `--channel height` to export `.height.png` instead.
The suffix identifies the texture's role; `.rgb.png` stamps retain their alpha.
Every destination is checked before the first cell is written. Cells are cut at
source resolution, then filtered separately to 256x256 so neighboring cells do
not bleed together. Existing matching edges on opaque tiles are restored after
resampling. Transparent stamps keep alpha. Exporting an already 256x256 cell
preserves its pixels exactly. Always export from the high-resolution master.

The 18 assets from the terrain experiment were cut with:

```sh
tmp/terrain cut \
  ../output/terrain-stamps-20260908/terrain-stamps-rgba.png \
  ../polyworld_data/terrain/stamps
tmp/terrain cut \
  ../output/terrain-tiles-20260908/05-terrain-tiles.png \
  ../polyworld_data/terrain/tiles
```

Each exported image is 256x256 pixels, downsampled from its 418x418 master cell.
The stamps retain transparency and antialiased edges. The terrain tiles are
opaque and have matching opposite boundary pixels. The original high-resolution
atlases and inpainting intermediates remain in the `output` directories.

To extract a rectangle for more high-resolution processing, use `crop`. It copies
the requested pixels exactly and does not resize them:

```sh
tmp/terrain crop sheet.png cropped.png 32 64 418 418
```

`resize` also accepts a grid, for example `resize sheet.png export.png 3 3`.
This produces a 768x768 sheet of 256x256 cells. Use `cut` when exporting separate
game textures. Reserve both commands for the final step.

## Remove a flat background

```sh
tmp/terrain background black-sheet.png stamps.png black 10
tmp/terrain background gray-sheet.png stamps.png gray 10
tmp/terrain background white-sheet.png stamps.png white 10
tmp/terrain background colored-sheet.png stamps.png 808080 10
```

The matte defaults to black and the maximum channel tolerance defaults to 10.
Colors may also be six-digit RGB hex values. Quote a leading `#` if using it.
Gray means RGB 128,128,128. Thresholds range from 0 to 254.

The tool removes opaque pixels close to the matte, identifies solid interior
pixels, and estimates nearby foreground colors to recover antialiased edge
colors. Already transparent or partially transparent pixels remain unchanged.
This handles solid-color mattes, including holes within a stamp. It does not
segment arbitrary scene backgrounds or remove baked checkerboards. Use a matte
color absent from the artwork; gray can also match real gray rocks.

## Prepare a tiled atlas for seam repair

```sh
tmp/terrain offset source.png offset.png 3 3
tmp/terrain mask offset.png guide.png api-mask.png 3 3
```

Each cell wraps by half its own width and height. Cells must have even dimensions.
Running `offset` twice restores the original pixels. The mask covers both center
strips, their intersection, and the endpoints where they meet the cell edges.
White in the guide means edit, black means preserve, and gray feathers the blend.
The API mask uses transparent alpha for editable pixels.

Generative inpainting still needs an image generator. Pixie prepares the masks
and composites the returned repair; it does not generate new terrain artwork.
Supply the offset atlas and guide to the image generator, asking it to repair all
nine center crosses together while preserving the grid, palette, scale, lighting,
and corner content. Request exactly the input dimensions and save `repaired.png`.

```sh
tmp/terrain blend offset.png repaired.png guide.png blended.png
tmp/terrain tile blended.png final.png 3 3 24
tmp/terrain cut final.png outputDirectory
```

The blend preserves pixels outside the guide exactly and blends alpha correctly.
Source, repair, and mask must have identical dimensions. The `tile` repair step
smoothly corrects a narrow band inside each edge and matches opposite boundary
colors, independently per cell. The default band is 24 pixels, capped at half the
shorter cell dimension. Cells must be opaque and at least 4x4 pixels.
This edge correction can change pixels outside the center repair mask.
All those repair operations keep the high-resolution cell dimensions. Only the
last `cut` step exports 256x256 assets and maintains the matching edges after
downsampling. `--size` is rejected on processing commands to prevent accidental
early resizing.

## Inspect and preview

```sh
tmp/terrain inspect stamps.png 3 3
tmp/terrain check outputDirectory/grass-1.rgb.png
tmp/terrain repeat outputDirectory/grass-1.rgb.png grass-repeat.png 3 3
```

`inspect` prints alpha counts and the number of mismatched opposite-edge pixels.
`check` requires 256x256 cells, full opacity, and matching boundaries. Use
`--size N` when checking a different power-of-two export. Use `inspect` for
high-resolution working sheets or transparent stamps.
`repeat` produces an unfiltered repetition of one texture for visual inspection.
Matching boundary colors alone does not guarantee natural shape continuation or
hide recognizable repeated motifs. Each tile repeats with itself; arbitrary
different variants are not guaranteed to join seamlessly.

## Height maps and material blending

Generate a grayscale height map from the finished high-resolution color atlas,
preserving every feature's position and the exact cell layout. White means raised
features; black means low ground and recesses. This is an inferred surface-height
mask for blending, not a camera-depth image or a normal map. The image generator
can shift or reinterpret details, so inspect alignment against the color source.

```sh
tmp/terrain height generated-height.png height-master.png 3 3 8
tmp/terrain cut height-master.png tileDirectory --channel height
```

`height` enforces opaque grayscale and matching edges at source resolution.
It does not infer height from color by itself; supply the AI-generated height
image. The final `cut` applies the same cell resampling as color exports. Avoid
offsetting or independently inpainting only the height atlas after this point,
because that would break alignment with the finished color texture.

The generated library stores color and height together in
`polyworld_data/terrain/tiles`, such as `dirt-1.rgb.png` and
`dirt-1.height.png`. Stamps in `polyworld_data/terrain/stamps` use the same
paired suffixes. Every exported asset is 256x256.
Sample height as linear data using the red channel with the same UVs as
the color texture. Do not normalize each tile independently: flat sand should
retain lower relief than rocks. Generation prompts and masters are saved under
`output/terrain-heights-20260908`.

`heightAmount` in `heights.nim` adjusts a two-material paint mask. Its scores are
`(1 - amount) + heightA * strength` and `amount + heightB * strength`. Subtract
the larger score minus `depth`, clamp negative weights to zero, and normalize.
The helper explicitly preserves completely unpainted and fully painted regions.
This lets raised leaves or stones survive into a transition while lower areas
reveal the other material. Smaller `depth` makes the transition sharper.

```sh
nim check tools/terrain/gen_blends.nim
nim r -d:release --out:tmp/gen_blends tools/terrain/gen_blends.nim
tmp/gen_blends tmp/terrain-samples/height-blend-soft 1.2 0.25
```

The comparison uses identical UVs and coverage on both sides: ordinary color
blending on the left, height-based blending on the right. It saves four material
pairs and the settings under `polyworld/tmp/terrain-samples/height-blend`.

The existing `quadterrain.nim` renderer already implements a related height
blend and packs height into texture alpha after building separate color and
height mip chains. That alpha is data, not transparency: do not premultiply the
color by height. Its current texture array expects 1024x1024 assets. These new
256x256 maps and the CPU preview do not change the active runtime materials;
runtime integration must also agree on the texture-array dimensions.

## Stamp height maps

Generate height from the original high-resolution stamp atlas, keeping its
feature locations and footprint. The source color alpha remains authoritative.
Use this final export command instead of the periodic tile-height preparation:

```sh
tmp/terrain stamp-height generated.height.png stamps-master.rgb.png \
  stamps-256.height.png 3 3
tmp/terrain cut stamps-256.height.png stampDirectory --channel height
```

`stamp-height` uses the original color alpha while filtering each cell. It then
exports opaque grayscale height, with zero outside the final stamp footprint.
This prevents the black background from lowering height at transparent edges.
It does not wrap, offset, normalize, or repair stamp edges. `--size N` selects
another power-of-two final size. Neither input file is changed.

Each `.rgb.png` keeps its original alpha. Its matching `.height.png` stores
linear height in the red channel, with white higher and black lower. These
generated maps are approximate relief masks, especially around fine foliage.
The prompts, source-resolution masters, paired previews, and exporter for all
eighteen stamps are under `output/terrain-stamp-heights-20260908`.

`stamps.nim` provides an opaque color canvas plus a floating-point height buffer.
Use `stampStencil` to attach the color footprint to a height map before filtering
or transforming it with Pixie. Apply the same transform to both images, then pass
the transformed images and per-pixel paint amounts to `compositeStamp`.
The helper uses height to adjust coverage, limits the result to the original
alpha footprint, and updates both color and height. Later stamps therefore see
the previously painted surface. Zero paint and transparent pixels do nothing;
full paint completely replaces fully opaque brush pixels. `AlphaStamp` provides
ordinary compositing for comparison. `HeightStamp` is the default.

```sh
nim check tools/terrain/gen_stamp_blends.nim
nim r -d:release --out:tmp/gen_stamp_blends tools/terrain/gen_stamp_blends.nim
```

The labeled comparison of all nine current stamps is saved in
`polyworld/tmp/terrain-samples/stamp-blends`. Both columns use identical
placement, scale, rotation, backgrounds, and paint amount (0.62). The height
column uses strength 1.2 and transition depth 0.12. Small transition depth gives
crisper boundaries. Stamp heights add work during baking; the baked color output
still renders as a single texture.

## Generate a sample map

```sh
nim check tools/terrain/gen_sample.nim
nim r -d:release --out:tmp/gen_terrain_sample tools/terrain/gen_sample.nim
```

This generates a 1024x1024 terrain texture from a 64x64 layout, with each terrain
cell occupying 16x16 pixels. It loads grass, dirt road, cobblestone, and gravel
tile/stamp pairs from the sibling `polyworld_data/terrain` directory. The
three rocky slots reuse cobblestone and gravel. The stages are:

1. Assign terrain weights for a winding path, grass, and rocky patches.
2. Blend the ground color and height using identical material weights.
3. Match stamp colors to their tiles and vary stamp size, rotation, and opacity.
4. Bake the same path, rock, and grass stamps with alpha and height blending.

Terrain masks keep the road open while allowing grass to soften its edges.
The default output directory is
`polyworld/tmp/terrain-samples/path-64-stamp-height`:

- `terrain.rgb.png` and `terrain.height.png`: the final 1024x1024 sample bake.
- `01-tiles.rgb.png`: the unblended tile layout.
- `02-ground.rgb.png` and `02-ground.height.png`: the ground before stamping.
- `03-alpha-stamps.rgb.png`: the same layout using ordinary stamp alpha.
- `comparison.png`: alpha stamps on the left, height stamps on the right.
- `recipe.json`: the seed, dimensions, and every stamp placement.

The sample generator replaces its generated files when rerun. An output directory
and seed can be supplied to keep another variation:

```sh
tmp/gen_terrain_sample tmp/terrain-samples/path-64-height-42 42
```

The map is deterministic for a given seed and source assets. The default seed is
20260908. At this scale, stamps supply larger details over the fine tile texture.

## Tests

```sh
nim check tools/terrain/terrain.nim
nim check tests/test_terrains.nim
nim r tests/test_terrains.nim
```

The terrain tests also run through `tests/tests.nim`. They cover straight RGBA
round trips, exact cuts, invalid input and overwrite handling, wrapped offsets,
black/gray/white matte recovery, mask protection, alpha blending, and periodic
edges with preserved interiors. Export tests cover power-of-two validation,
alpha filtering without color fringes, isolated cell resampling, and matching
tile edges after downsampling from 418x418 to 256x256.
Stamp checks cover filtering at transparent edges, alpha footprint limits,
paint endpoints, accumulated heights, clipping, and malformed blend inputs.
