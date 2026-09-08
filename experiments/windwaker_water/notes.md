# Wind Waker water experiment

An ocean and shoreline study based on
[Dooge's water material breakdown](https://www.youtube.com/watch?v=8NL9Cc05CYk).
Continues the original procedural experiment with six original textures made
using the built-in imagegen tool.

## Run

From the polyworld repository:

```sh
nim r experiments/windwaker_water/windwaker_water.nim
```

The generated artwork loads by default. The window title identifies the active
texture source. Both sets are loaded once so comparisons switch immediately.

| Control | Action |
| --- | --- |
| G | Switch between imagegen and procedural textures |
| 1 | Toggle broad dark ocean cells |
| 2 | Toggle white ocean foam |
| 3 | Toggle an extra fine foam layer, initially off |
| 4 | Toggle scrolling UV displacement |
| 5 | Toggle shoreline lace |
| 6 | Toggle breaking crests |
| 7 | Toggle lapping bands |
| 8 | Toggle receding contact foam |
| H | Toggle gentle vertex heave |
| T | Show the texture inspector |
| Space | Pause or resume animation |
| Drag | Orbit the island |
| Wheel | Zoom |
| Escape | Close |

Use `--procedural` to start with the original masks. This compares the texture
sets under the same updated shader and scene settings.

## Textures

The six unmodified imagegen PNGs and their exact prompts are in
[textures/generated](textures/generated/prompts.md): ocean lattice, displacement,
shore lace, crest, lapping band, and contact foam. The existing procedural mask
still controls the shoreline's overall coverage.

The active ocean mask is `foam_lattice_thick.png`, an imagegen edit with thicker
white lines. `foam_lattice.png` preserves the initial thin version.

The shader reads the red channel as a linear scalar. Foam images use black for
empty water and white for coverage. The grayscale warp is sampled at two offsets
to displace both UV axes.

Generated maps use mirrored repeat across the sea, and mirrored repeat horizontally
with vertical clamping for shoreline strips. This makes edge sampling continuous
even where imagegen's opposite edges differ. It introduces reflected motifs every
other tile. Shore UVs close on whole mirrored periods, including the warp.

The texture inspector reads left to right, top to bottom: colored lattice, lattice
mask, displacement, shore lace, crest, band, contact foam, coverage mask.

## Material behavior

The ocean combines a blue base, larger dark cells, and smaller white foam.
Scrolling displacement bends the patterns. The optional third foam sample is a
variation for comparison. Mipmapped filtering and continuous mask values reduce
aliasing. Explicit distance fades approximate the video's darkened mip levels.

Shore crests and bands combine opposing scrolls with maximum blending. Contact
foam uses minimum blending and moves back and forth with the ebb. The ring fades
toward open water, and ocean foam recedes near the beach. The island summit omits
degenerate faces, its slopes use three lighting bands, and distant water fades
to the sky color so the sea plane's edge disappears.

This experiment focuses on the Great Sea and a simplified beach treatment.
The video's rivers, waterfalls, radial splash ripples, and full nine-layer beach
material are future extensions.

## Capture

```sh
nim c -d:takeScreenshot -o:/tmp/windwaker_water \
  experiments/windwaker_water/windwaker_water.nim
/tmp/windwaker_water --frames=120
```

Capture builds advance by exactly 1/60 second per frame. The default image is
`windwaker_water_generated.png` beside the source. `SCREENSHOT_PATH` changes the
output path. `CAM_YAW`, `CAM_PITCH`, and `CAM_DIST` set the orbit camera, and
`OVERLAY=1` enables the texture inspector. Angles use radians.

```sh
OVERLAY=1 SCREENSHOT_PATH=/tmp/water_textures.png \
  /tmp/windwaker_water --frames=120
CAM_PITCH=0.9 CAM_DIST=40 SCREENSHOT_PATH=/tmp/water_shore.png \
  /tmp/windwaker_water --frames=240
```

Shader and asset failures raise `WaterError` with the relevant compiler log or
file path. GPU objects and window callbacks are released on exit.
