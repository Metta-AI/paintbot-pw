## Checks HUD bounds, spacing, hit rectangles, and current-frame placement.

import
  vmath,
  polyworld/[gameuis, player, stackpanels],
  ../examples/gods_of_the_arena/layouts as gota,
  ../examples/light_vs_dark/layouts as lvd,
  ../examples/call_to_adventure/layouts as cta

proc checkPanels(parent: GameUiPanel, children: openArray[GameUiPanel]) =
  ## Checks that non-overlapping children draw and hit inside their parent.
  for child in children:
    let local = GameUiPanel(
      origin: child.origin - parent.origin,
      size: child.size
    )
    doAssert local.inside(parent.size), $local & " outside " & $parent
    doAssert child.contains(child.origin + child.size * 0.5'f)
    doAssert not child.contains(child.origin + child.size)
    doAssert child.origin.x == child.origin.x.int.float32
    doAssert child.origin.y == child.origin.y.int.float32
  doAssert not panelsOverlap(children)

echo "Testing HUD stacks at different screen origins"
for origin in [vec2(0), vec2(123, 57), vec2(2200, 1100)]:
  block:
    let
      panel = GameUiPanel(origin: origin, size: gota.PanelScore)
      score = panel.scorePanels()
    checkPanels(panel, score.headers)
    for values in score.values:
      checkPanels(panel, values)
    for i in 1 ..< score.headers.len:
      doAssert score.headers[i].origin.x - score.headers[i - 1].origin.x ==
        score.values[0][i].origin.x - score.values[0][i - 1].origin.x
  block:
    let
      panel = GameUiPanel(origin: origin, size: gota.PanelClock)
      clock = panel.clockPanels()
    checkPanels(panel, [clock.icon, clock.caption, clock.time])
  block:
    let
      panel = GameUiPanel(origin: origin, size: gota.PanelHeroes)
      cards = panel.heroPanels()
    for card in cards:
      checkPanels(panel, [card.portrait, card.hp, card.mana])
      doAssert card.hp.origin.x == card.mana.origin.x
      doAssert card.hp.size == card.mana.size
    for team in 0 ..< 2:
      for i in 1 ..< 5:
        let
          previous = cards[team * 5 + i - 1].portrait
          current = cards[team * 5 + i].portrait
        doAssert current.origin.x - previous.origin.x == 95
  block:
    let
      panel = GameUiPanel(origin: origin, size: gota.PanelDetails)
      details = panel.detailsPanels()
    checkPanels(panel, [
      details.portrait, details.name, details.class, details.stats,
      details.hp, details.mana, details.xp
    ])
    checkPanels(panel, details.abilities)
    doAssert details.abilities[0].origin.x == details.hp.origin.x
    doAssert details.abilities[^1].origin.x + details.abilities[^1].size.x ==
      details.hp.origin.x + details.hp.size.x
    doAssert details.abilities[0].origin.y >=
      details.xp.origin.y + details.xp.size.y
  block:
    let
      panel = GameUiPanel(origin: origin, size: gota.PanelInventory)
      inventory = gota.inventoryPanels(panel)
    checkPanels(panel, [inventory.title, inventory.contents, inventory.gold])
    checkPanels(inventory.contents, inventory.slots)
    var shop: array[20, GameUiPanel]
    stackGrid(inventory.contents, vec2(36), 5, vec2(8, 1), shop)
    checkPanels(inventory.contents, shop)
  block:
    let
      panel = GameUiPanel(origin: origin, size: lvd.PanelMinimap)
      minimap = panel.minimapPanels()
    checkPanels(panel, [minimap.map, minimap.sun, minimap.clock])
    checkPanels(panel, minimap.views)
    doAssert minimap.map.origin.x - panel.origin.x ==
      panel.origin.x + panel.size.x - minimap.map.origin.x - minimap.map.size.x
  block:
    let
      panel = GameUiPanel(origin: origin, size: lvd.PanelResources)
      cells = panel.resourcePanels()
    checkPanels(panel, cells)
  block:
    let
      panel = GameUiPanel(origin: origin, size: lvd.PanelSelection)
      selection = panel.selectionPanels()
    checkPanels(panel, [selection.portrait, selection.hp, selection.name])
    checkPanels(panel, selection.units)
    doAssert selection.units[0].origin.x >=
      selection.portrait.origin.x + selection.portrait.size.x
  block:
    let
      panel = GameUiPanel(origin: origin, size: lvd.PanelBuild)
      build = panel.buildPanels()
    checkPanels(panel, build.tabs)
    checkPanels(build.contents, build.slots)
    doAssert build.slots[0].origin.y >=
      build.tabs[0].origin.y + build.tabs[0].size.y
  block:
    let
      panel = GameUiPanel(origin: origin, size: cta.PanelParty)
      party = panel.partyPanels()
    for i, hero in party:
      checkPanels(panel, [hero.card])
      checkPanels(hero.card, [hero.portrait, hero.name, hero.hp, hero.mana])
      if i > 0:
        doAssert hero.card.origin.y - party[i - 1].card.origin.y ==
          hero.card.size.y + cta.PartyGap
  block:
    let
      panel = GameUiPanel(origin: origin, size: cta.PanelChat)
      chat = panel.chatPanels()
    checkPanels(panel, [chat.general, chat.combat, chat.body])
  block:
    let
      panel = GameUiPanel(origin: origin, size: cta.PanelQuest)
      quest = panel.questPanels()
    checkPanels(panel, [
      quest.theme, quest.heading, quest.title, quest.clock, quest.enemies
    ])
  block:
    let
      panel = GameUiPanel(origin: origin, size: cta.PanelAbilities)
      abilities = panel.abilityPanels()
    checkPanels(panel, abilities.slots)
    checkPanels(panel, [abilities.divider, abilities.xp])
    doAssert abilities.slots[3].origin.x + abilities.slots[3].size.x <
      abilities.divider.origin.x
    doAssert abilities.divider.origin.x < abilities.slots[4].origin.x
  block:
    let
      panel = GameUiPanel(origin: origin, size: cta.PanelInventory)
      inventory = cta.inventoryPanels(panel)
    checkPanels(panel, inventory.slots)
    checkPanels(panel, inventory.counters)
    checkPanels(panel, [inventory.title])
    doAssert inventory.counters[0].origin.y >=
      inventory.slots[^1].origin.y + inventory.slots[^1].size.y

echo "Testing variable-width replay transport"
for width in [TransportMinWidth, 1280.0'f, 1920, 3840]:
  let
    panel = GameUiPanel(origin: vec2(17, 900), size: vec2(width, 80))
    transport = panel.transportPanels()
  checkPanels(panel, transport.controls)
  checkPanels(panel, transport.speeds)
  checkPanels(panel, [
    transport.loop, transport.scrub, transport.recorded,
    transport.camera, transport.tick
  ])
  doAssert transport.scrub.size.x >= 80
  doAssert transport.scrub.origin.x >=
    transport.speeds[^1].origin.x + transport.speeds[^1].size.x
  doAssert transport.scrubHit.contains(
    transport.scrub.origin + transport.scrub.size * 0.5'f
  )

echo "Testing fixed siblings and fill respond in the same frame"
for firstWidth in [20.0'f, 70, 10]:
  let panel = GameUiPanel(size: vec2(100, 30))
  var row = panel.stack(LeftToRight)
  let
    first = row.takeColumn(firstWidth, 5)
    rest = row.takeRest()
  checkPanels(panel, [first, rest])
  doAssert rest.origin.x == firstWidth + 5
  doAssert rest.size.x == 100 - firstWidth - 5

echo "HUD layout tests passed"
