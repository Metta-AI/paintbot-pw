# Organic village preview — not published

Local viewer: http://localhost:8766/tmp/round-viewer/index.html?replay=http%3A%2F%2Flocalhost%3A8766%2Ftmp%2Fround-village-demo.replay

Round, hand-shaped cottage shells with layered moss roofs, circular door/window details, winding paths, and curved clusters of planted beds. New v8 cover uses h=0 to encode circular obstacles; w is diameter and x/z bound the circle. Physics, vision, WASM walkability, and minimap respect the circle. Earlier replay versions retain their existing shapes.

Two circle-collision tests and five runtime tests pass. The 720-tick local preview verifies hash 555899652; the historical v7 mixed match still verifies 35166491. The browser displays HASH VERIFIED. Vet was unavailable because API credentials were not configured.

This is a local visual review checkpoint. Production remains 0.1.8.
