import std/os
import "../../src/polyworld/emscripten.nims"
setupEmscripten(thisDir())

when defined(emscripten):
  switch("passL", "--preload-file " & thisDir() / "../../tmp/paintbot-cover.glb" & "@/paintbot-cover.glb")

when defined(emscripten):
  for team in ["red", "blue"]:
    switch("passL", "--preload-file " & thisDir() / ("../../tmp/paintbot-cog-" & team & ".glb") & "@/paintbot-cog-" & team & ".glb")

when defined(emscripten):
  switch("passL", "--preload-file " & thisDir() / "../../tmp/round-village.glb" & "@/round-village.glb")

when defined(emscripten):
  # The expanded woodland can exceed the default 2 GiB while baking foliage.
  # Memory grows on demand; this is a ceiling, not a startup allocation.
  switch("passL", "-s MAXIMUM_MEMORY=4GB")
  # Reuse freed foliage buffers through Emscripten malloc rather than
  # exhausting the WASM address space with Nim allocator fragmentation.
  switch("define", "useMalloc")
  switch("undef", "nimTypeNames")
