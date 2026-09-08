# Imagegen texture prompts

Generated with the built-in imagegen tool on 2026-09-08.
The PNGs in this directory are the original, unmodified tool outputs.
Black is empty and white is foam coverage; the warp uses grayscale values.
The renderer uses mirrored repeat for generated masks to avoid edge jumps.

The current ocean texture is the thicker variant documented in
[foam_lattice_thick_prompt.md](foam_lattice_thick_prompt.md).

## foam_lattice.png

```text
Use case: stylized-concept
Asset type: original game shader grayscale texture, single square 1024x1024 image.
Style: clean graphic cel-shaded Wind Waker-inspired water material. This is a flat technical texture, NOT a scene or rendered water. No text, no labels, no border, no lighting, no perspective, no shadows, no paper texture, no noise grain. Opaque black background and white mask shapes, crisp anti-aliased edges. Primary request: seamlessly tileable ocean foam lattice mask. Sparse delicate white gently curved interconnected lines form irregular large rounded polygon cells, about 5 cells across and 5 down, a loose organic water caustic web. Lines occupy only about 10 percent of total image area, remaining 90 percent is solid black. Thin lines of slightly varying thickness, several tapered gaps and tiny black triangular holes where three lines meet. Smooth graceful curved cell walls, avoid straight Voronoi polygons and avoid thick white bands. Uniform pattern scale across entire canvas, perfectly tileable on both horizontal and vertical axes, lines must continue through every edge. Black cell interiors completely flat.
```

## warp_map.png

```text
Use case: stylized-concept
Asset type: original game shader grayscale texture, single square 1024x1024 image.
Style: clean graphic cel-shaded Wind Waker-inspired water material. This is a flat technical texture, NOT a scene or rendered water. No text, no labels, no border, no lighting, no perspective, no shadows, no paper texture, no noise grain. Opaque black background and white mask shapes, crisp anti-aliased edges. Primary request: seamless grayscale UV displacement map. Override black/white mask instruction: use smooth grayscale gradients from black through middle gray to white. Broad soft horizontal zigzag chevron waves, 3 wave periods vertically, 2 broad zigzags horizontally. Smooth continuous low-frequency values, softly rounded transitions, no sharp seams. The pattern fills entire image and must tile on both axes. This is a smooth wave-field used to bend texture coordinates, not foam, not a normal map, no blue.
```

## crest_foam.png

```text
Use case: stylized-concept
Asset type: original game shader grayscale texture, single square 1024x1024 image.
Style: clean graphic cel-shaded Wind Waker-inspired water material. This is a flat technical texture, NOT a scene or rendered water. No text, no labels, no border, no lighting, no perspective, no shadows, no paper texture, no noise grain. Opaque black background and white mask shapes, crisp anti-aliased edges. Primary request: horizontally tileable breaking wave crest mask. One single continuous white irregular horizontal ribbon spans left to right. Top half contains band: upper boundary at roughly 18 percent image height with soft pointed crest fingers and small scallops, lower boundary around 42 percent. About 8 irregular black oval or teardrop cutouts just behind the leading edge in this ribbon, aligned mostly horizontally. Bottom 50 percent of canvas entirely black and top 10 percent entirely black. Bold simple silhouette, hand-drawn smooth flowing shapes. Matching left and right edge cross sections for seamless horizontal repeating; does not repeat vertically.
```

## band_foam.png

```text
Use case: stylized-concept
Asset type: original game shader grayscale texture, single square 1024x1024 image.
Style: clean graphic cel-shaded Wind Waker-inspired water material. This is a flat technical texture, NOT a scene or rendered water. No text, no labels, no border, no lighting, no perspective, no shadows, no paper texture, no noise grain. Opaque black background and white mask shapes, crisp anti-aliased edges. Primary request: horizontally tileable lapping shore foam band mask. One single thick white horizontal ribbon spans left to right, between 18 percent and 56 percent image height. Smooth asymmetrically undulating top and bottom edges. Two staggered rows of about 7 generously sized organic horizontally stretched rounded black holes pierce the white ribbon, varied sizes, no tiny dots. Some holes open onto lower trailing edge. Top 10 percent and bottom 35 percent entirely black. Matching left and right edge cross sections for seamless horizontal repeat; no vertical repeat.
```

## shore_foam.png

```text
Use case: stylized-concept
Asset type: original game shader grayscale texture, single square 1024x1024 image.
Style: clean graphic cel-shaded Wind Waker-inspired water material. This is a flat technical texture, NOT a scene or rendered water. No text, no labels, no border, no lighting, no perspective, no shadows, no paper texture, no noise grain. Opaque black background and white mask shapes, crisp anti-aliased edges. Primary request: horizontally tileable thin sand contact foam strip mask. One single narrow wavy white ribbon across image left to right, upper edge about 10 percent down, lower edge about 31 percent down. Leading upper edge smooth undulation, trailing lower edge scalloped with 6-10 open black rounded notches and a few black horizontal oval holes. Thin graceful graphic shape with slightly irregular thickness. Entire bottom 60 percent black; entire top 5 percent black. Left and right edges match for seamless horizontal repeat; no vertical repeat.
```

## shore_lattice.png

```text
Use case: stylized-concept
Asset type: original game shader grayscale texture, single square 1024x1024 image.
Style: clean graphic cel-shaded Wind Waker-inspired water material. This is a flat technical texture, NOT a scene or rendered water. No text, no labels, no border, no lighting, no perspective, no shadows, no paper texture, no noise grain. Opaque black background and white mask shapes, crisp anti-aliased edges. Primary request: horizontally tileable near-shore lace foam mask. Top 25 percent completely black. A narrow undulating white horizontal crest runs left to right around 30 percent down, below it hangs a sparse delicate connected lace network of elongated irregular rounded black cells bounded by thin white curved lines, about 7 cells across and 2 cells down. The network breaks up into a few isolated curved fragments toward 65 percent height. Bottom 25 percent solid black. Graphic flowing smooth shapes, no photographic detail. White occupies only around 15 percent of image area. Left/right edges match for seamless horizontal repeat, no vertical repeat.
```
