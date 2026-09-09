import
  std/math,
  vmath

type
  DemoSubject* = object
    position*: Vec3
    indoors*, quiet*: bool

  DemoCamera* = object
    active*: bool
    subject*: int
    elapsed*, quietElapsed*: float32
    transitioning*: bool
    velocity: Vec3
    visits: seq[int]
    serial: int

const
  DemoDistance* = 40'f32
  MinimumShot = 60'f32
  MaximumShot = 90'f32
  QuietPeriod = 3'f32
  SmoothTime = 1.5'f32
  MaximumSpeed = 6'f32
  ArrivalDistance = 2'f32
  MaximumStep = 1'f32 / 120

proc initDemoCamera*(count: int): DemoCamera =
  ## Creates a viewer-only camera with no selected villager.
  DemoCamera(subject: -1, visits: newSeq[int](count))

proc resetMotion*(cam: var DemoCamera) =
  ## Restarts a shot after a seek or manual camera movement.
  cam.elapsed = 0
  cam.quietElapsed = 0
  cam.velocity = vec3(0)
  cam.transitioning = true

proc choose(cam: DemoCamera, subjects: openArray[DemoSubject],
    target: Vec3, rotate: bool): int =
  ## Selects an outdoor villager by visit age, distance, then slot.
  result = -1
  var bestDistance = Inf.float32
  for slot, subject in subjects:
    if subject.indoors or (rotate and slot == cam.subject):
      continue
    let distance = (subject.position.xz - target.xz).lengthSq
    if result < 0 or
        (rotate and cam.visits[slot] < cam.visits[result]) or
        ((not rotate or cam.visits[slot] == cam.visits[result]) and
          distance < bestDistance):
      result = slot
      bestDistance = distance

proc selectSubject(cam: var DemoCamera, slot: int) =
  ## Starts a new visit without changing the current camera position.
  cam.subject = slot
  inc cam.serial
  cam.visits[slot] = cam.serial
  cam.resetMotion()

proc activate*(cam: var DemoCamera, subjects: openArray[DemoSubject],
    target: Vec3, preferred = -1) =
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

proc deactivate*(cam: var DemoCamera) =
  ## Gives manual camera input ownership of the view.
  cam.active = false
  cam.velocity = vec3(0)

proc approach(cam: var DemoCamera, target: var Vec3, dest: Vec3, dt: float32) =
  ## Critically damped following with a bounded world-space travel speed.
  let omega = 2'f32 / SmoothTime
  var change = target - dest
  let limit = MaximumSpeed * SmoothTime
  if change.length > limit:
    change = change.normalize * limit
  let
    adjusted = target - change
    decay = exp(-omega * dt)
    temp = (cam.velocity + change * omega) * dt
  cam.velocity = (cam.velocity - temp * omega) * decay
  var next = adjusted + (change + temp) * decay
  if dot(dest - target, next - dest) > 0:
    next = dest
    cam.velocity = vec3(0)
  let movement = next - target
  if movement.length > MaximumSpeed * dt:
    next = target + movement.normalize * MaximumSpeed * dt
  target = next

proc update*(cam: var DemoCamera, subjects: openArray[DemoSubject],
    target: var Vec3, dt: float32, playing: bool) =
  ## Follows a persistent subject, using real time rather than simulation ticks.
  if not cam.active or not playing or cam.subject < 0 or cam.subject >= subjects.len:
    return
  var remaining = max(dt, 0'f32)
  while remaining > 0:
    let
      step = min(remaining, MaximumStep)
      subject = subjects[cam.subject]
    remaining -= step
    cam.approach(target, subject.position, step)
    if cam.transitioning:
      if (target.xz - subject.position.xz).length <= ArrivalDistance:
        cam.transitioning = false
      continue
    cam.elapsed += step
    if subject.quiet or subject.indoors:
      cam.quietElapsed += step
    else:
      cam.quietElapsed = 0
    if cam.elapsed >= MinimumShot and
        (cam.quietElapsed >= QuietPeriod or cam.elapsed >= MaximumShot):
      let next = cam.choose(subjects, target, true)
      if next >= 0:
        cam.selectSubject(next)
