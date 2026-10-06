# Sunny sky cloud layer

`sunny-clouds.png` is original cloud artwork generated for Paintbot with OpenAI imagegen on 2026-10-06. It contains sunlit cumulus and transparent gaps, with no blue backdrop or sun baked into it. Source resolution: 1254 × 1254 RGBA.

`sky.nim` embeds the PNG in native and browser builds, decodes it to premultiplied alpha, and uses mipmapped filtering. A periodic four-sample blend makes both tile boundaries continuous even where the source image's edges differ. The cloud layer moves independently of the analytical blue atmosphere and stationary sun.

The F1 Silky panel controls cloud speed and sun layer rotation. Zero speed freezes the clouds; negative speed reverses them. Rotating the sun also updates its reflected direction and the water glints. Save/Load stores both settings with the other shader parameters.
