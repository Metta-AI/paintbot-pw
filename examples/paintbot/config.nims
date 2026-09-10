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
