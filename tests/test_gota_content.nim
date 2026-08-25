## Gods of the Arena must keep ten distinct deterministic hero identities.

import ../examples/gods_of_the_arena/content

echo "Testing the GoTA roster contains every hero class once"
block:
  var seen: set[HeroClass]
  for class in RedHeroClasses:
    doAssert class notin seen, "red roster repeats " & $class
    seen.incl class
  for class in BlueHeroClasses:
    doAssert class notin seen, "blue roster repeats " & $class
    seen.incl class
  doAssert seen == {HeroClass.low .. HeroClass.high}
  doAssert HeroClassCount == 10

echo "Testing every hero class has viable and distinct tuning"
block:
  var
    tuning: seq[array[6, int32]]
    used: set[Ability]
  for class in HeroClass:
    let spec = class.heroSpec
    doAssert spec.name.len > 0
    doAssert spec.role.len > 0
    doAssert spec.baseHitPoints > 0
    doAssert spec.baseDamage > 0
    doAssert spec.baseMovePerTick > 0
    doAssert spec.attackRange > 0
    doAssert spec.attackTicks > 0
    let values = [
      spec.baseHitPoints,
      spec.baseMana,
      spec.baseDamage,
      spec.baseMovePerTick,
      spec.attackRange,
      spec.attackTicks
    ]
    doAssert values notin tuning, "two classes have identical tuning"
    tuning.add values
    for slot in HeroAbilitySlot:
      let ability = spec.abilities[slot]
      doAssert ability notin used, "ability is assigned twice"
      used.incl ability

echo "Testing every kit ability has a distinct usable spec"
block:
  var
    names: seq[string]
    icons: seq[string]
  for ability in Ability:
    let spec = ability.abilitySpec
    doAssert spec.name.len > 0
    doAssert spec.icon.len > 0
    doAssert spec.cooldownTicks > 0
    doAssert spec.name notin names, "ability name is assigned twice"
    doAssert spec.icon notin icons, "ability icon is assigned twice"
    names.add spec.name
    icons.add spec.icon
    case spec.kind
    of Strike:
      doAssert spec.damage > 0, $ability & " strike has no damage"
      doAssert spec.range > 0, $ability & " strike has no range"
    of Heal:
      doAssert spec.heal > 0, $ability & " heal has no heal"
    of Restore:
      doAssert spec.restore > 0, $ability & " restore has no restore"
  doAssert names.len == 40

echo "Testing class stat curves use only the selected class and level"
block:
  for class in HeroClass:
    doAssert heroMaxHp(class, 2) > heroMaxHp(class, 1)
    doAssert heroMaxMana(class, 2) >= heroMaxMana(class, 1)
    doAssert heroDamage(class, 2) > heroDamage(class, 1)
    doAssert heroMovePerTick(class, 2) > heroMovePerTick(class, 1)
    doAssert heroAttackRange(class) == class.heroSpec.attackRange
    doAssert heroAttackTicks(class) == class.heroSpec.attackTicks
    doAssert heroAbility(class, PrimaryAbility) ==
      class.heroSpec.abilities[PrimaryAbility]
    doAssert abilityIconKey(heroAbility(class, PassiveAbility)).len > 8

echo "Testing the shop catalog has distinct usable items"
block:
  var
    names: seq[string]
    icons: seq[string]
  doAssert ItemSpecs[NoItem].cost == 0
  for item in Item:
    if item == NoItem:
      continue
    let spec = item.itemSpec
    doAssert spec.name.len > 0
    doAssert spec.icon.len > 0
    doAssert spec.cost > 0
    doAssert spec.name notin names, "item name is assigned twice"
    doAssert spec.icon notin icons, "item icon is assigned twice"
    names.add spec.name
    icons.add spec.icon
    case spec.kind
    of Consumable:
      doAssert spec.heal > 0 or spec.restore > 0 or spec.strike > 0
    of Equipment:
      doAssert spec.maxHp > 0 or spec.maxMana > 0 or
        spec.damage > 0 or spec.movePerTick > 0
    doAssert itemIconKey(item).len > 5
  doAssert names.len == 20
  doAssert itemFromId(0) == NoItem
  doAssert itemFromId(int32(LeatherGauntlets.ord)) == LeatherGauntlets

echo "test_gota_content: all checks passed"
