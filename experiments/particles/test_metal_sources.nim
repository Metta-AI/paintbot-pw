import
  metal4,
  shaders/sources

proc compileSource(device: MTLDevice, source, label: string) =
  ## Compiles one generated particle shader with the native Metal compiler.
  var error: NSError
  let library = device.newLibraryWithSource(@source, 0.ID, error.addr)
  if not error.isNil:
    echo label
    echo $error
    echo source
  checkNSError(error, label)
  checkNil(library, label & " library was nil")

let device = MTLCreateSystemDefaultDevice()
checkNil(device, "Could not create a Metal device")
device.compileSource(BillboardMetal, "billboard")
device.compileSource(StretchedMetal, "stretched")
device.compileSource(AlphaMetal, "alpha")
device.compileSource(AdditiveMetal, "additive")
echo "Particle Metal sources compiled"
