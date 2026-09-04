--path:"src"
switch("path", getEnv("SILKY_PATH", "../silky/src"))
--path:"../shady/src"
--path:"../noisy/src"
--path:"../windy/src"
--path:"../gltf/src"
--path:"../vmath/src"

--define:nimTypeNames
--define:flatty64

when not defined(debug):
  --define:release
  --define:noAutoGLerrorCheck
