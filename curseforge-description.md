# NextMob

**One button that targets whatever your current quests want you to kill.**

Bind it to a key, or click the small movable button. It reads your quest log and
points you at the right mob — including the mobs that *drop* quest items, which
objective text never names.

## Why it is accurate

- **It matches on creature id, not text.** NextMob reads the creature id out of
  each nearby unit and compares it to the ids your quests want, then takes the
  name straight off the unit. Localised client? Objective says "Defias bandits"
  but the mobs are called *Defias Smuggler*? Both work.
- **QuestieDB support (optional).** Install QuestieDB and NextMob asks it which
  NPCs a quest wants and which NPCs drop each quest item. Nothing is bundled,
  and NextMob works without it.
- **It learns.** When an objective ticks up, the NPC responsible is remembered
  against that objective — across all your characters. Drop quests credit the
  corpse in the loot window, not whatever you targeted next.
- **It knows when to stop.** A finished objective stops being targeted, per
  objective, so a quest wanting boars *and* gnolls drops the boars at 5/5.
- **It skips corpses**, so a click never leaves you holding a dead mob.

## Commands

| Command | |
|---|---|
| `/nm` | list every command |
| `/nm list` | what it would target right now, best first |
| `/nm db` | what QuestieDB resolved for your quests |
| `/nm test` | diagnostics, if nothing gets targeted |
| `/nm mode` | how a click targets: macro, macrotext or unit |
| `/nm dead` | skip corpses (on by default) |

## Clients

Forever, retail, Mists Classic and Classic Era.

Source and issues: https://github.com/martinwinther/NextMob
