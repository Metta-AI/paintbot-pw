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
  var
    cam = initDemoCamera(subjects.len)
    target = vec3(0)
  cam.activate(subjects, target)
  doAssert cam.subject == 2 and target == subjects[2].position
  cam.deactivate()
  cam.activate(subjects, target, preferred = 1)
  doAssert cam.subject == 1 and target == subjects[1].position

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
  doAssert cam.subject == 1 and target == subjects[1].position
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
  var
    subjects = [DemoSubject(position: vec3(30, 0, 0)),
      DemoSubject(position: vec3(-30, 0, 0))]
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
  target = vec3(100)
  cam.advance(subjects, target, 100)
  doAssert target == vec3(100)
  cam.activate(subjects, target, preferred = 1)
  doAssert cam.subject == 1 and target == subjects[1].position
  subjects[1].position = vec3(-80, 2, 20)
  cam.resetMotion()
  cam.update(subjects, target, 0, false)
  doAssert target == subjects[1].position and cam.elapsed == 0

block speedControlRecentresWithoutChangingShotOrOwnership:
  let subjects = [DemoSubject(position: vec3(5, 1, 9)),
    DemoSubject(position: vec3(40, 1, 20))]
  var
    cam = initDemoCamera(subjects.len)
    target = vec3(0)
  cam.activate(subjects, target)
  cam.advance(subjects, target, 20)
  let elapsed = cam.elapsed
  for speed in [1, 2, 4, 16]:
    target = vec3(100)
    cam.snapToSubject(subjects, target)
    doAssert target == subjects[0].position
    doAssert cam.active and cam.subject == 0 and cam.elapsed == elapsed
  cam.deactivate()
  target = vec3(100)
  cam.snapToSubject(subjects, target)
  doAssert target == vec3(100)
  doAssert not cam.active and cam.elapsed == elapsed

block distantFocusChangeSnapsEvenWhilePaused:
  let subjects = [DemoSubject(position: vec3(500, 20, 0)),
    DemoSubject(position: vec3(-500, 0, 0))]
  var
    cam = initDemoCamera(subjects.len)
    target = vec3(0)
  cam.activate(subjects, target, preferred = 0)
  doAssert target == subjects[0].position
  cam.activate(subjects, target, preferred = 1)
  cam.update(subjects, target, 0, false)
  doAssert target == subjects[1].position

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
        subjects[0].position = vec3(simulationTime * 4, 0.85, sin(simulationTime))
        subjects[1].position.x = 10 + sin(simulationTime) * 5
        subjects[1].quiet = frame mod hz == 0
        cam.update(subjects, target, 1'f32 / float32(hz), true)
        doAssert target == subjects[0].position
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

block conversationIsOneShot:
  var
    subjects = [DemoSubject(position: vec3(0), quiet: true, conversation: 1),
      DemoSubject(position: vec3(2, 0, 0), quiet: true, conversation: 1),
      DemoSubject(position: vec3(20, 0, 0), quiet: true, conversation: 3)]
    cam = initDemoCamera(subjects.len)
    target = vec3(0)
  cam.activate(subjects, target)
  cam.advance(subjects, target, 61)
  doAssert cam.subject == 2, "the camera switched within the same huddle"
  subjects[2].conversation = 1
  cam.advance(subjects, target, 100)
  doAssert cam.subject == 2, "the camera cut within the only conversation"
  subjects[0].conversation = 0
  cam.advance(subjects, target, 1)
  doAssert cam.subject == 0, "a departing villager never became eligible"
