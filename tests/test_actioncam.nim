import
  vmath,
  polyworld/actioncam

echo "Testing heavier isolated events win"
block:
  var cam = initActionCam(
    minDistance = 20,
    maxDistance = 200,
    tight = 0.4,
    holdSeconds = 2.5
  )
  cam.beginFrame(0)
  cam.noteInterest(1, vec3(0, 0, 0), 20, 4, 0, 24)
  cam.noteInterest(2, vec3(180, 0, 0), 80, 4, 0, 24)
  cam.chooseShot(0)
  doAssert cam.locked
  doAssert cam.lockId == 2
  doAssert abs(cam.lockTarget.x - 180) < 8

echo "Testing nearby events frame the subject not the midpoint"
block:
  var cam = initActionCam(
    minDistance = 20,
    maxDistance = 200,
    tight = 0.4,
    holdSeconds = 2.5
  )
  cam.beginFrame(0)
  cam.noteInterest(1, vec3(0, 1, 0), 40, 3, 0, 24)
  cam.noteInterest(2, vec3(6, 1, 0), 80, 3, 0, 24)
  cam.chooseShot(0)
  doAssert cam.lockId == 2
  doAssert abs(cam.lockTarget.x - 6) < 2

echo "Testing hold ignores a far fight until time is up"
block:
  var cam = initActionCam(
    minDistance = 20,
    maxDistance = 200,
    tight = 0.4,
    holdSeconds = 2.5
  )
  cam.beginFrame(0)
  cam.noteInterest(1, vec3(0, 0, 0), 50, 4, 0, 24)
  cam.chooseShot(0, 2)
  doAssert cam.lockId == 1
  cam.beginFrame(1)
  cam.noteInterest(1, vec3(0, 0, 0), 50, 4, 1, 24)
  cam.noteInterest(2, vec3(180, 0, 0), 90, 4, 1, 24)
  cam.chooseShot(1 / 60, 2)
  doAssert cam.lockId == 1
  cam.chooseShot(2.5, 2)
  doAssert cam.lockId == 2

echo "Testing a huge score cuts before hold expires"
block:
  var cam = initActionCam(holdSeconds = 2.5)
  cam.beginFrame(0)
  cam.noteInterest(1, vec3(0, 0, 0), 50, 4, 0, 24)
  cam.chooseShot(0)
  doAssert cam.lockId == 1
  cam.beginFrame(1)
  cam.noteInterest(1, vec3(0, 0, 0), 50, 4, 1, 24)
  cam.noteInterest(2, vec3(180, 0, 0), 160, 4, 1, 24)
  cam.chooseShot(1 / 60)
  doAssert cam.lockId == 2

echo "Testing interest lasts its tick lifetime"
block:
  var cam = initActionCam(holdSeconds = 2.5)
  cam.beginFrame(0)
  cam.noteInterest(7, vec3(10, 0, 0), 80, 4, 0, 8)
  cam.chooseShot(0)
  doAssert cam.lockId == 7
  cam.beginFrame(8)
  doAssert cam.interestCount == 1
  cam.beginFrame(9)
  doAssert cam.interestCount == 0

echo "Testing same place upgrades without a cut"
block:
  var cam = initActionCam(holdSeconds = 2.5)
  cam.beginFrame(0)
  cam.noteInterest(1, vec3(0, 0, 0), 50, 4, 0, 24)
  cam.chooseShot(0)
  doAssert cam.lockId == 1
  cam.beginFrame(1)
  cam.noteInterest(1, vec3(0, 0, 0), 50, 4, 1, 24)
  cam.noteInterest(2, vec3(3, 0, 0), 80, 4, 1, 24)
  cam.chooseShot(1 / 60)
  doAssert cam.lockId == 2
  doAssert abs(cam.lockTarget.x - 3) < 2

echo "Testing tight zoom is closer than a wide shot"
block:
  var
    wide = initActionCam(
      minDistance = 20,
      maxDistance = 200,
      tight = 0
    )
    close = initActionCam(
      minDistance = 20,
      maxDistance = 200,
      tight = 1
    )
  wide.beginFrame(0)
  close.beginFrame(0)
  wide.noteInterest(1, vec3(0, 0, 0), 80, 4, 0, 24)
  wide.noteInterest(2, vec3(10, 0, 0), 40, 4, 0, 24)
  close.noteInterest(1, vec3(0, 0, 0), 80, 4, 0, 24)
  close.noteInterest(2, vec3(10, 0, 0), 40, 4, 0, 24)
  wide.chooseShot(0)
  close.chooseShot(0)
  doAssert close.lockDistance < wide.lockDistance

echo "Testing closer scale zooms in"
block:
  var
    wide = initActionCam(minDistance = 40, maxDistance = 240)
    close = initActionCam(
      minDistance = 40,
      maxDistance = 240,
      closeScale = 0.5
    )
  wide.beginFrame(0)
  close.beginFrame(0)
  wide.noteInterest(1, vec3(0, 0, 0), 80, 4, 0, 24)
  close.noteInterest(1, vec3(0, 0, 0), 80, 4, 0, 24)
  wide.chooseShot(0)
  close.chooseShot(0)
  doAssert abs(close.lockDistance - wide.lockDistance * 0.75'f32) < 1

echo "Testing follow halves remaining distance each second"
block:
  var
    cam = initActionCam(
      followRate = 1.0,
      zoomRate = 1.0,
      mapSpan = 2000
    )
    target = vec3(0, 0, 0)
    distance = 80.0'f32
  cam.enabled = true
  cam.beginFrame(0)
  cam.noteInterest(1, vec3(100, 0, 0), 50, 4, 0, 24)
  cam.chooseShot(0)
  cam.follow(target, distance, 1)
  doAssert abs(target.x - 50) < 0.5
  doAssert abs(distance - (80 + cam.lockDistance) * 0.5'f32) < 1

echo "Testing a far shot jumps instead of easing"
block:
  var
    cam = initActionCam(mapSpan = 128)
    target = vec3(0, 0, 0)
    distance = 80.0'f32
  cam.enabled = true
  cam.beginFrame(0)
  cam.noteInterest(1, vec3(80, 0, 0), 50, 4, 0, 24)
  cam.chooseShot(0)
  cam.follow(target, distance, 1 / 60)
  doAssert abs(target.x - cam.lockTarget.x) < 1

echo "Testing a nearby shot after a jump eases"
block:
  var
    cam = initActionCam(followRate = 1.0, mapSpan = 128)
    target = vec3(0, 0, 0)
    distance = 80.0'f32
  cam.enabled = true
  cam.beginFrame(0)
  cam.noteInterest(1, vec3(80, 0, 0), 50, 4, 0, 24)
  cam.chooseShot(0)
  cam.follow(target, distance, 1 / 60)
  doAssert abs(target.x - 80) < 1
  cam.beginFrame(1)
  cam.noteInterest(1, vec3(86, 0, 0), 50, 4, 1, 24)
  cam.chooseShot(1 / 60)
  cam.follow(target, distance, 1 / 60)
  doAssert target.x > 80
  doAssert target.x < 85

echo "Testing ignore bubble swallows high value after it grows"
block:
  var
    cam = initActionCam(mapSpan = 128, holdSeconds = 2.5)
    target = vec3(0, 0, 0)
    distance = 80.0'f32
  cam.enabled = true
  cam.beginFrame(0)
  cam.noteInterest(1, vec3(80, 0, 0), 50, 4, 0, 24)
  cam.chooseShot(0)
  cam.follow(target, distance, 1 / 60)
  cam.beginFrame(1)
  cam.noteInterest(1, vec3(80, 0, 0), 50, 4, 1, 24)
  cam.chooseShot(5)
  cam.noteInterest(2, vec3(120, 0, 0), 160, 4, 1, 24)
  cam.chooseShot(1 / 60)
  doAssert cam.lockId == 1

echo "Testing ignore bubble uses wall-clock seconds"
block:
  var
    cam = initActionCam(mapSpan = 128, holdSeconds = 2.5)
    target = vec3(0, 0, 0)
    distance = 80.0'f32
  cam.enabled = true
  cam.beginFrame(0)
  cam.noteInterest(1, vec3(80, 0, 0), 50, 4, 0, 24)
  cam.chooseShot(0)
  cam.follow(target, distance, 1 / 60)
  cam.beginFrame(1)
  cam.noteInterest(1, vec3(80, 0, 0), 50, 4, 1, 24)
  cam.chooseShot(0.2, 16)
  cam.noteInterest(2, vec3(160, 0, 0), 160, 4, 1, 24)
  cam.chooseShot(1 / 60, 16)
  doAssert cam.lockId == 2

echo "Testing follow eases toward the lock"
block:
  var
    cam = initActionCam(
      followRate = 1000,
      zoomRate = 1000,
      mapSpan = 2000
    )
    target = vec3(0, 0, 0)
    distance = 100.0'f32
  cam.enabled = true
  cam.beginFrame(0)
  cam.noteInterest(1, vec3(40, 2, 10), 50, 4, 0, 24)
  cam.chooseShot(0)
  cam.follow(target, distance, 1)
  doAssert abs(target.x - cam.lockTarget.x) < 1
  doAssert abs(distance - cam.lockDistance) < 1

echo "Testing follow does not overshoot the shot"
block:
  var
    cam = initActionCam(
      followRate = 1.0,
      zoomRate = 1.0,
      mapSpan = 2000
    )
    target = vec3(0, 0, 0)
    distance = 80.0'f32
  cam.enabled = true
  cam.beginFrame(0)
  cam.noteInterest(1, vec3(100, 0, 0), 50, 4, 0, 24)
  cam.chooseShot(0)
  var previous = target.x
  for i in 0 ..< 240:
    cam.follow(target, distance, 1 / 60)
    doAssert target.x >= previous - 0.001'f32
    doAssert target.x <= cam.lockTarget.x + 0.05'f32
    previous = target.x
  doAssert target.x > 30

echo "Testing toggle drops selection follow"
block:
  var
    cam = initActionCam()
    followSelection = true
  doAssert cam.enabled
  cam.toggle(followSelection)
  doAssert not cam.enabled
  followSelection = true
  cam.toggle(followSelection)
  doAssert cam.enabled
  doAssert not followSelection

echo "Testing a far living shot cuts after hold even when weaker"
block:
  var cam = initActionCam(holdSeconds = 1.0)
  cam.beginFrame(0)
  cam.noteInterest(1, vec3(0, 0, 0), 50, 4, 0, 24)
  cam.chooseShot(0, 2)
  doAssert cam.lockId == 1
  cam.beginFrame(1)
  cam.noteInterest(1, vec3(0, 0, 0), 50, 4, 1, 24)
  cam.noteInterest(2, vec3(180, 0, 0), 64, 4, 1, 24)
  cam.chooseShot(1 / 60, 2)
  doAssert cam.lockId == 1, "hold must still keep the current room"
  cam.chooseShot(1.0, 2)
  doAssert cam.lockId == 2, "after hold, follow the living shot elsewhere"

echo "Action cam tests passed"
