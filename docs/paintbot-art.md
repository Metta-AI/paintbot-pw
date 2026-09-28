# Paintbot CC0 art

Paintbot loads its art from the public `Metta-AI/polyworld_art` repository.
`coworld/assets.json` pins the exact art commit. Native builds use the sibling
`../polyworld_art` directory, or `POLYWORLD_ART` at compile time. Browser builds
use `POLYWORLD_ART` for their source and mount the selected files at
`/polyworld_art`. Git LFS must be installed when checking out the artwork.

| Former artwork | Replacement |
| --- | --- |
| Handpainted Trees and Toon Enchanted Meadow trees | Runtime TreeGen oaks, saplings, spruce, fir and pine |
| Toon Enchanted Meadow bushes | Runtime TreeGen broadleaf bushes |
| Toon Enchanted Meadow rocks | Runtime RockGen boulders and river stones |
| Low Poly Grass | Four original procedural grass tufts |
| Toon flower patches and ivy | CC0 Heartleaf flowers and clover |
| Toon Golden Valley houses | Original Paintbot round cottages |
| Toon carts, crates and planters | CC0 Heartleaf market, beehive and planter |
| Toon Golden Valley well | CC0 Polyworld village well |
| Legacy water normal images | Original periodic procedural normal maps |

The original Paintbot robots, cover, round cottages and concept images now
live under `polyworld_art/paintbot`. Their authoring scripts and provenance
travel with them. Models and textures are CC0-1.0. The existing Rubik fonts
retain OFL-1.1; source code retains its original license. The viewer includes
the full CC0 dedication and font notices in `licenses/`.

`coworld/paintbot/tools/verify_art.py` checks every bundled art file against
its reviewed license, source notice, size and SHA-256 digest. It follows
external GLB dependencies, rejects unknown or changed artwork, and reports
missing Git LFS contents. Only the two named Rubik font files may use OFL;
all other selected artwork must be CC0. The browser build runs this check
before compilation. CI checks out the public art with LFS and needs no
private art deploy key.

The generators build a small reusable model bank at scene creation. Terrain
placements reuse its meshes and textures. Grass is simple original blade
geometry and requires no downloaded model. Village replacements preserve
recorded cover footprints; simulation, collision, observation and replay
hash rules are unchanged. Historical Paintbot village layouts use the same
public replacements.

The other inherited Polyworld example games and Unity conversion utilities
are outside this Paintbot art migration. Their legacy pack selectors do not
form part of the Paintbot bundle. Do not export Unity packs into the public
art repository.

Validate locally:

```sh
python3 coworld/paintbot/tools/verify_art.py ../polyworld_art
nim check examples/paintbot/paintbot.nim
nim r tests/test_paintbot_art.nim
python3 tests/test_paintbot_art.py
coworld/paintbot/tools/build_replay_viewer.sh "$PWD/tmp/cc0-viewer"
```

Use the pinned dependencies from `coworld/tools/sync_dependencies.py` and set
`POLYWORLD_DEPS` to their directory when sibling development libraries have
different APIs.
