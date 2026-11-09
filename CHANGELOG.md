# Changelog

## 1.0

First release. One button, or one keybind, that targets whatever your current
quests want you to kill.

**How it picks a target**

- Reads your whole quest log and ranks every candidate mob, with anything
  standing near you winning over a theoretically better name that is nowhere in
  sight.
- **Creature-id matching.** Reads the creature id out of each nearby unit's
  GUID and matches it against the ids your quests want, then takes the name off
  the unit itself. Immune to localisation, plurals, and objective text that
  names something other than the mob.
- **QuestieDB support**, optional. When QuestieDB is installed, NextMob asks it
  which NPCs a quest wants and which NPCs drop a quest item, instead of
  inferring either. Nothing is bundled and nothing breaks without it.
- **Learns on its own.** When a quest objective ticks up, the NPC responsible is
  recorded against that objective, so quests whose text does not name the mob
  work from then on. Shared across all your characters.
- **Drop quests.** Credits the corpse in the loot window rather than whatever
  you targeted next, and for a first encounter will guess a nearby mob that
  shares an identifying word with the quest item.
- **Finished objectives drop out**, per objective rather than per quest, so a
  quest that wants boars and gnolls stops offering boars at 5/5.
- **Skips corpses.** The macro drops the target after any attempt that lands on
  a dead mob, so a click never leaves you holding one.

**Clients**

- Forever (16001), retail (120105), Mists Classic (50500) and Classic Era
  (11509).
- Handles the Midnight-era addon restrictions: never asks for the combat log on
  clients that forbid it, type-checks every value that a unit API might return
  as a Secret, and keeps the macro body inside the 255-character limit.

**Commands**

`/nm` lists them. `/nm test` is the one to reach for if nothing gets targeted;
`/nm db` shows what QuestieDB resolved; `/nm mode` switches how a click targets.

**Upgrading from QuestTarget**

This addon used to be called QuestTarget. Its learned database carries over
automatically on first login. The old `QuestTarget` macro is left behind unused
and can be deleted.
