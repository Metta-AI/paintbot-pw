## Current-frame HUD rectangles, composed from fixed rows and columns.

import
  vmath,
  polyworld/[gameuis, stackpanels]

const
  PanelScore* = vec2(298, 104)
  PanelHeroes* = vec2(1051, 145)
  PanelClock* = vec2(128, 86)
  PanelMinimap* = vec2(256, 256)
  PanelDetails* = vec2(859, 242)
  PanelInventory* = vec2(252, 243)
  HeroCardSize = vec2(78, 122)
  HeroGap = 17.0'f
  HeroTeamWidth = HeroCardSize.x * 5 + HeroGap * 4

type
  ClockPanels* = object
    icon*, caption*, time*: GameUiPanel

  HeroPanels* = object
    portrait*, hp*, mana*: GameUiPanel

  DetailsPanels* = object
    portrait*, name*, class*, stats*: GameUiPanel
    hp*, mana*, xp*: GameUiPanel
    abilities*: array[6, GameUiPanel]

  InventoryPanels* = object
    title*, contents*, gold*: GameUiPanel
    slots*: array[6, GameUiPanel]

proc clockPanels*(panel: GameUiPanel): ClockPanels =
  ## Stacks the clock's icon and caption above its centered time.
  var rows = panel.stack(TopToBottom, vec2(4, 12))
  var heading = rows.takeRow(20, 7).stack(LeftToRight)
  heading.gap(12)
  result.icon = heading.take(vec2(22, 20), 4)
  result.caption = heading.take(vec2(72, 20))
  result.time = rows.takeRow(40)

proc heroPanels*(panel: GameUiPanel): array[10, HeroPanels] =
  ## Stacks two teams of five cards, each with a portrait and two meters.
  var teams = panel.stack(LeftToRight, vec2(21, 10))
  for team in 0 ..< 2:
    var cards = teams.takeColumn(HeroTeamWidth, 91).stack(LeftToRight)
    for slot in 0 ..< 5:
      var card = cards.take(HeroCardSize, HeroGap).stack(TopToBottom)
      let i = team * 5 + slot
      result[i].portrait = card.takeRow(80, 9)
      card.indent = 7
      result[i].hp = card.take(vec2(64, 12), 9)
      result[i].mana = card.take(vec2(64, 12))

proc detailsPanels*(panel: GameUiPanel): DetailsPanels =
  ## Gives the portrait, identity, meters, and ability groups their own stacks.
  var rows = panel.stack(TopToBottom, vec2(32, 20))
  rows.gap(12)
  var columns = rows.takeRest().stack(LeftToRight)
  result.portrait = columns.take(vec2(150), 12)
  var identity = columns.takeColumn(96, 10).stack(TopToBottom)
  identity.gap(4)
  result.name = identity.takeRow(28)
  result.class = identity.takeRow(20, 2)
  result.stats = identity.takeRow(54)
  var meters = columns.takeColumn(526).stack(TopToBottom)
  meters.gap(4)
  result.hp = meters.takeRow(28, 10)
  result.mana = meters.takeRow(28, 10)
  result.xp = meters.takeRow(28, 10)
  var groups = meters.takeRow(72).stack(LeftToRight)
  var abilities = groups.takeColumn(72 * 4 + 18 * 3, 22).stack(LeftToRight)
  for i in 0 ..< 4:
    result.abilities[i] = abilities.take(vec2(72), 18)
  var items = groups.takeRest().stack(LeftToRight)
  for i in 4 ..< 6:
    result.abilities[i] = items.take(vec2(72), 18)

proc inventoryPanels*(panel: GameUiPanel): InventoryPanels =
  ## Stacks the clickable title, two inventory rows, and currency footer.
  var rows = panel.stack(TopToBottom, vec2(14, 10))
  result.title = rows.takeRow(28, 12)
  result.contents = rows.takeRow(72 * 2 + 5, 1)
  result.gold = rows.takeRow(31)
  stackGrid(result.contents, vec2(72), 3, vec2(4, 5), result.slots)
