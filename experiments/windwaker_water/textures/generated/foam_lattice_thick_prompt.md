# Thicker ocean foam

Edited with the built-in imagegen tool on 2026-09-08.

Input: the original foam_lattice.png, supplied again in the conversation.
Output: foam_lattice_thick.png. The experiment uses this version by default.
The original thin texture is preserved.

## Exact edit prompt

```text
Use case: precise-object-edit
Asset type: grayscale ocean foam mask for a game shader.
Input image: edit target, the supplied black-and-white foam lattice texture.
Primary request: make the white lines clearly thicker. Increase the widths of the thin connecting white curved lines to about THREE TIMES their current width, so the wispy hairlines become bold readable continuous ribbons. Increase the already broad junction widths only moderately. Preserve the existing cell layout, the exact curving paths, the number and position of the large black cells, and the tiny black triangular holes at three-way junctions. Preserve those holes as open black shapes by expanding their surrounding white junctions outward rather than filling the holes. Target approximately 18-22 percent white area overall.
Constraints: change only line thickness. Same square framing and pattern scale, same pure opaque black background and pure white lines with crisp smooth antialiasing. Maintain smooth natural variation in line width. No new cells, no new pattern, no colors, no lighting, no grain, no text, no border. Preserve how the pattern crosses the image edges. Return only the edited flat texture.
```
