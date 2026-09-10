import std/os
import "../../src/polyworld/emscripten.nims"
setupEmscripten(thisDir())

when defined(emscripten):
  switch("passL", "--preload-file " & thisDir() / "../../tmp/paintbot-cover.glb" & "@/paintbot-cover.glb")
