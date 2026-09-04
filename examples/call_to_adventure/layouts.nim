## Current-frame HUD rectangles, composed from fixed rows and columns.

import
  vmath,
  polyworld/[gameuis, stackpanels]

const
  PanelPartyCard* = vec2(293, 92)
  PartyGap* = 9.0'f
  PanelParty* = vec2(PanelPartyCard.x, PanelPartyCard.y * 4 + PartyGap * 3)
  PanelMinimap* = vec2(252, 252)
  PanelQuest* = vec2(448, 132)
  PanelChat* = vec2(337, 177)
  PanelAbilities* = vec2(453, 115)
  PanelInventory* = vec2(236, 314)

type
  PartyPanels* = object
    card*, portrait*, name*, hp*, mana*: GameUiPanel

  ChatPanels* = object
    general*, combat*, body*: GameUiPanel

  QuestPanels* = object
    theme*, heading*, title*, clock*, enemies*: GameUiPanel

  AbilityPanels* = object
    divider*, xp*: GameUiPanel
    slots*: array[6, GameUiPanel]

  InventoryPanels* = object
    title*: GameUiPanel
    slots*: array[9, GameUiPanel]
    counters*: array[2, GameUiPanel]

proc partyPanels*(panel: GameUiPanel): array[4, PartyPanels] =
  ## Stacks party cards, then a portrait beside each card's text and meters.
  var cards = panel.stack(TopToBottom)
  for card in result.mitems:
    card.card = cards.take(PanelPartyCard, PartyGap)
    var columns = card.card.stack(LeftToRight, vec2(10))
    card.portrait = columns.take(vec2(72), 8)
    var info = columns.takeRest().stack(TopToBottom)
    info.gap(4)
    card.name = info.takeRow(20, 2)
    card.hp = info.takeRow(20, 2)
    card.mana = info.takeRow(20)

proc chatPanels*(panel: GameUiPanel): ChatPanels =
  ## Stacks the two chat tabs above the log's content region.
  var rows = panel.stack(TopToBottom, vec2(8, 4))
  var tabs = rows.takeRow(28, 8).stack(LeftToRight)
  result.general = tabs.take(vec2(72, 28), 8)
  result.combat = tabs.take(vec2(128, 28))
  rows.indent = 4
  result.body = rows.take(vec2(panel.size.x - 24, 124))

proc questPanels*(panel: GameUiPanel): QuestPanels =
  ## Stacks the floor name, quest heading, objective, clock, and enemy count.
  var rows = panel.stack(TopToBottom, vec2(18, 10))
  result.theme = rows.takeRow(22)
  result.heading = rows.takeRow(22, 2)
  result.title = rows.takeRow(22, 2)
  result.clock = rows.takeRow(20, 2)
  result.enemies = rows.takeRow(18)

proc abilityPanels*(panel: GameUiPanel): AbilityPanels =
  ## Stacks ability and item groups above a full-width experience bar.
  var rows = panel.stack(TopToBottom, vec2(10))
  var groups = rows.takeRow(64, 11).stack(LeftToRight)
  var abilities = groups.takeColumn(64 * 4 + 8 * 3, 8).stack(LeftToRight)
  for i in 0 ..< 4:
    result.slots[i] = abilities.take(vec2(64), 8)
  result.divider = groups.take(vec2(1, 64), 8)
  var items = groups.takeRest().stack(LeftToRight)
  for i in 4 ..< 6:
    result.slots[i] = items.take(vec2(64), 8)
  result.xp = rows.takeRow(20)

proc inventoryPanels*(panel: GameUiPanel): InventoryPanels =
  ## Stacks the bag title, three rows of slots, and two currency counters.
  var rows = panel.stack(TopToBottom, vec2(10))
  result.title = rows.takeRow(28, 13)
  let grid = rows.takeRow(64 * 3 + 14 * 2, 13)
  stackGrid(grid, vec2(64), 3, vec2(12, 14), result.slots)
  var counters = rows.takeRow(20).stack(LeftToRight)
  for counter in result.counters.mitems:
    counter = counters.take(vec2(76, 20), 18)
