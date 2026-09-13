# Included by the public WASM baseline builder after the upstream imports/types.
# Sprite coordinates are legacy pixels: five Paintbot centimetres per pixel.
proc territoryGoal(client: ProtocolClient, me: Vec, team: Team):
    tuple[active: bool, target: Vec] =
  var best = 1e30
  for (o, label) in client.spriteObjectsWithLabelPrefix("control heart "):
    let parts = label.splitWhitespace()
    if parts.len != 5 or parts[3] != "owner":
      continue
    try:
      let owner = parseInt(parts[4])
      let p = client.mapPos(o)
      # Owned hearts remain a useful hold destination if every heart is ours.
      # Ownership changes retarget on the next frame; never chase CTF pedestals.
      let cost = dist(me, p) + (if owner == ord(team): 100000.0 else: 0.0)
      if cost < best:
        best = cost
        result = (true, p)
    except ValueError:
      discard
