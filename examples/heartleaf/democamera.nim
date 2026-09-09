import
  std/math,
  vmath

type
  DemoSubject* = object
    position*: Vec3
    indoors*, quiet*: bool
    conversation*: int # Zero means no conversation.

  DemoCamera* = object
    active*: bool
    subject*: int
    elapsed*, quietElapsed*: float32
    needsSnap: bool
    visits: seq[int]
    serial: int

const
  DemoDistance* = 40'f32
  MinimumShot = 60'f32
  MaximumShot = 90'f32
  QuietPeriod = 3'f32

proc initDemoCamera*(count: int): DemoCamera =
  ## Creates a viewer-only camera with no selected villager.
  DemoCamera(subject: -1, visits: newSeq[int](count))

proc resetMotion*(cam: var DemoCamera) =
  ## Restarts a shot and requests recentering after a seek or focus change.
  cam.elapsed = 0
  cam.quietElapsed = 0
  cam.needsSnap = true

proc choose(cam: DemoCamera, subjects: openArray[DemoSubject],
    target: Vec3, rotate: bool): int =
  ## Selects an outdoor villager by visit age, distance, then slot.
  result = -1
  var bestDistance = Inf.float32
  for slot, subject in subjects:
    if subject.indoors or (rotate and slot == cam.subject):
      continue
    if rotate and subjects[cam.subject].conversation != 0 and
        subject.conversation == subjects[cam.subject].conversation:
      continue
    let distance = (subject.position.xz - target.xz).lengthSq
    if result < 0 or
        (rotate and cam.visits[slot] < cam.visits[result]) or
        ((not rotate or cam.visits[slot] == cam.visits[result]) and
          distance < bestDistance):
      result = slot
      bestDistance = distance

proc selectSubject(cam: var DemoCamera, slot: int) =
  ## Starts a new visit and requests an immediate focus change.
  cam.subject = slot
  inc cam.serial
  cam.visits[slot] = cam.serial
  cam.resetMotion()

proc snapToSubject*(cam: var DemoCamera, subjects: openArray[DemoSubject],
    target: var Vec3) =
  ## Recentres on the selected subject without changing manual ownership or timing.
  if cam.active and cam.subject >= 0 and cam.subject < subjects.len:
    target = subjects[cam.subject].position
    cam.needsSnap = false

proc activate*(cam: var DemoCamera, subjects: openArray[DemoSubject],
    target: var Vec3, preferred = -1) =
  ## Resumes automatic following from a manual selection or nearby villager.
  if subjects.len == 0:
    return
  cam.active = true
  var slot = preferred
  if slot < 0 or slot >= subjects.len:
    slot = cam.choose(subjects, target, false)
  if slot < 0:
    slot = if cam.subject >= 0: cam.subject else: 0
  cam.selectSubject(slot)
  cam.snapToSubject(subjects, target)

proc deactivate*(cam: var DemoCamera) =
  ## Gives manual camera input ownership of the view.
  cam.active = false

proc update*(cam: var DemoCamera, subjects: openArray[DemoSubject],
    target: var Vec3, dt: float32, playing: bool) =
  ## Tracks interpolated viewer positions without adding camera lag.
  if not cam.active or cam.subject < 0 or cam.subject >= subjects.len:
    return
  if cam.needsSnap:
    cam.snapToSubject(subjects, target)
  if not playing:
    return
  let step = max(dt, 0'f32)
  cam.elapsed += step
  if subjects[cam.subject].quiet or subjects[cam.subject].indoors:
    cam.quietElapsed += step
  else:
    cam.quietElapsed = 0
  if cam.elapsed >= MinimumShot and
      (cam.quietElapsed >= QuietPeriod or cam.elapsed >= MaximumShot):
    let next = cam.choose(subjects, target, true)
    if next >= 0:
      cam.selectSubject(next)
  cam.snapToSubject(subjects, target)
