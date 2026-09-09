import
  std/math,
  vmath,
  ../examples/heartleaf/democamera

proc advance(cam: var DemoCamera, subjects: openArray[DemoSubject],
    target: var Vec3, seconds: float32, hz = 60) =
  ## Advances the camera using a fixed display frame rate.
  for frame in 0 ..< int(round(seconds * float32(hz))):
    cam.update(subjects, target, 1'f32 / float32(hz), true)

block initialSelection:
  let subjects = [DemoSubject(position: vec3(20, 0, 0)),
    DemoSubject(position: vec3(2, 0, 0), indoors: true),
    DemoSubject(position: vec3(5, 0, 0))]
  var cam = initDemoCamera(subjects.len)
  cam.activate(subjects, vec3(0))
  doAssert cam.subject == 2
  cam.deactivate()
  cam.activate(subjects, vec3(0), preferred = 1)
  doAssert cam.subject == 1

block minimumHoldAndRotation:
  let subjects = [DemoSubject(position: vec3(0), quiet: true),
    DemoSubject(position: vec3(10, 0, 0), quiet: true),
    DemoSubject(position: vec3(-10, 0, 0), quiet: true)]
  var
    cam = initDemoCamera(subjects.len)
    target = vec3(0)
  cam.activate(subjects, target)
  cam.advance(subjects, target, 59)
  doAssert cam.subject == 0
  cam.advance(subjects, target, 2)
  doAssert cam.subject == 1
  cam.advance(subjects, target, 75)
  doAssert cam.subject == 2

block busySubjectAndQuietPeriod:
  var
    subjects = [DemoSubject(position: vec3(0)), DemoSubject(position: vec3(10, 0, 0))]
    cam = initDemoCamera(subjects.len)
    target = vec3(0)
  cam.activate(subjects, target)
  cam.advance(subjects, target, 65)
  doAssert cam.subject == 0
  subjects[0].quiet = true
  cam.advance(subjects, target, 2)
  doAssert cam.subject == 0
  cam.advance(subjects, target, 2)
  doAssert cam.subject == 1

block maximumHold:
  let subjects = [DemoSubject(position: vec3(0)), DemoSubject(position: vec3(10, 0, 0))]
  var
    cam = initDemoCamera(subjects.len)
    target = vec3(0)
  cam.activate(subjects, target)
  cam.advance(subjects, target, 89)
  doAssert cam.subject == 0
  cam.advance(subjects, target, 2)
  doAssert cam.subject == 1

block housesAndNoAlternative:
  var
    subjects = [DemoSubject(position: vec3(0)),
      DemoSubject(position: vec3(10, 0, 0), indoors: true)]
    cam = initDemoCamera(subjects.len)
    target = vec3(0)
  cam.activate(subjects, target)
  subjects[0].indoors = true
  subjects[0].position = vec3(5, 1, 0)
  cam.advance(subjects, target, 100)
  doAssert cam.subject == 0
  doAssert (target - subjects[0].position).length < 0.01
  subjects[1].indoors = false
  cam.advance(subjects, target, 1)
  doAssert cam.subject == 1

block pauseManualAndSeek:
  let subjects = [DemoSubject(position: vec3(30, 0, 0)),
    DemoSubject(position: vec3(-30, 0, 0))]
  var
    cam = initDemoCamera(subjects.len)
    target = vec3(0)
  cam.activate(subjects, target)
  cam.advance(subjects, target, 2)
  let
    pausedPosition = target
    pausedTime = cam.elapsed
  cam.update(subjects, target, 100, false)
  doAssert target == pausedPosition and cam.elapsed == pausedTime
  cam.deactivate()
  cam.advance(subjects, target, 100)
  doAssert target == pausedPosition
  cam.activate(subjects, target, preferred = 1)
  doAssert cam.subject == 1 and target == pausedPosition
  cam.advance(subjects, target, 2)
  let beforeSeek = target
  cam.resetMotion()
  doAssert target == beforeSeek and cam.subject == 1 and cam.elapsed == 0
  cam.update(subjects, target, 1'f32 / 60, true)
  doAssert (target - beforeSeek).length <= 6'f32 / 60 + 0.0001

block boundedTravelAndNoPrematureHold:
  let subjects = [DemoSubject(position: vec3(500, 20, 0), quiet: true),
    DemoSubject(position: vec3(-500, 0, 0), quiet: true)]
  var
    cam = initDemoCamera(subjects.len)
    target = vec3(0)
  cam.activate(subjects, target, preferred = 0)
  for frame in 0 ..< 60 * 70:
    let before = target
    cam.update(subjects, target, 1'f32 / 60, true)
    doAssert (target - before).length <= 6'f32 / 60 + 0.0001
  doAssert cam.subject == 0 and cam.transitioning and cam.elapsed == 0

block frameRateIndependence:
  let subjects = [DemoSubject(position: vec3(30, 4, 12))]
  var endpoints: seq[Vec3]
  for hz in [30, 60, 144]:
    var
      cam = initDemoCamera(subjects.len)
      target = vec3(0)
    cam.activate(subjects, target)
    cam.advance(subjects, target, 5, hz)
    endpoints.add target
  for target in endpoints:
    doAssert (target - endpoints[0]).length < 0.02

block shotTimingAcrossFrameRatesAndSimulationSpeeds:
  for hz in [30, 60, 144]:
    for speed in [1, 2, 4, 16]:
      var
        subjects = [DemoSubject(position: vec3(0), quiet: true),
          DemoSubject(position: vec3(10, 0, 0))]
        cam = initDemoCamera(subjects.len)
        target = vec3(0)
      cam.activate(subjects, target)
      for frame in 0 ..< hz * 59:
        let simulationTime = float32(frame * speed) / float32(hz)
        subjects[1].position.x = 10 + sin(simulationTime) * 5
        subjects[1].quiet = frame mod hz == 0
        cam.update(subjects, target, 1'f32 / float32(hz), true)
      doAssert cam.subject == 0
      cam.advance(subjects, target, 2, hz)
      doAssert cam.subject == 1

block initiallyIndoors:
  let subjects = [DemoSubject(position: vec3(10, 0, 0), indoors: true)]
  var
    cam = initDemoCamera(subjects.len)
    target = vec3(0)
  cam.activate(subjects, target)
  cam.advance(subjects, target, 100)
  doAssert cam.subject == 0
  doAssert (target - subjects[0].position).length < 0.01
