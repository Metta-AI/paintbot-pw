# Gnomewick concept and local implementation

Artist reference: `art/gnomewick-level-concept.png` (generated for this level).

The local scene follows the reference's moss/earth palette, wooded interior cover,
raised banks, sunken route, causeway, organic structures and planted patches.
Production is still 0.1.8; this is the ongoing local art review.

## Object library

- Moss cottage: broad irregular grass roof, stone chimney, circular windows.
- Mushroom shelter: broad spotted cap, pale curved walls.
- Stump house: bark ribs and a low moss crown.
- Spiral shelter: curled roof tip and round windows.
- Six distinct broadleaf tree meshes, each with an understory arrangement.
- Four bush/flowering-thicket meshes and three flower-patch meshes.
- Rounded vegetable beds, three rock-bank meshes and trailing ivy.

All structures are doorless. Interior foliage occupies the same round cover
footprints used for collisions and visibility. Small flowers are walkable dressing.

## Terrain and playback

A ground QuadLayer contains a 1.5 m sunken lane. A slab QuadLayer carries two
2.5 m terraces, with two ramp approaches each. A central causeway crosses the low
lane. Trenches are lowered into the textured terrain instead of drawn as panels.
Height changes govern traversal and sight, and BASIC terrainHeight(x,y) and WASM
terrain evaluation use the same centimetre values. Cogs, equipment and overlays
follow elevation. Shot visuals use colored moving spheres; event toasts default off.

Validation: symmetric heights, cliff/ramp travel, bank occlusion, and flood-fill
access to all pickups and both hearts. Nim/Python terrain calculations matched
3,825 sampled coordinates. A full BASIC episode and a 480-tick mixed BASIC/WASM
smoke completed; both have replay artifacts. Browser replay verification passed.

Verified artifacts: BASIC 7,200 ticks / hash `4095840138`; mixed BASIC/WASM
480 ticks / hash `1905507749`; prior v8 replay / hash `555899652`. The sampled
height parity check covers 3,825 coordinates. Vet review was unavailable because
its API credentials were not configured.

Preview: http://localhost:8766/tmp/concept-viewer/index.html?replay=http%3A%2F%2Flocalhost%3A8766%2Ftmp%2Flayered-village-demo.replay
