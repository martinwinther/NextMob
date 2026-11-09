# NextMob

One button that targets whatever your active quests want you to kill — the Zygor
targeting button, without Zygor, for any quest in the game.

## Install

Install it from your addon manager (CurseForge), or by hand:

1. Download the latest zip from the
   [releases page](https://github.com/martinwinther/NextMob/releases) and
   extract the `NextMob` folder into your AddOns directory:
   - **WoW Forever:** `World of Warcraft/_forever_/Interface/AddOns/`
     (the path your addon manager points at — the hierarchy is
     `WoW Forever → Interface → AddOns`)
   - Retail: `World of Warcraft/_retail_/Interface/AddOns/`
   - Classic Era: `World of Warcraft/_classic_era_/Interface/AddOns/`
   - Mists Classic: `World of Warcraft/_classic_/Interface/AddOns/`
2. Fully restart the game (or `/reload` if it was already running).

### Recommended companion: QuestieDB

QuestieDB gives NextMob exact NPC names per quest, including which mobs drop
quest items. Install it from your addon manager (it is on CurseForge), or grab
`QuestieDB-Forever.zip` from
<https://github.com/Questie/QuestieDB/releases/latest> and extract the
`QuestieDB` folder next to `NextMob`.

You do **not** need the full Questie addon — NextMob only reads QuestieDB.
Having Questie as well is harmless.

Run `/nm db` to confirm it was picked up. NextMob works without it, just
with more guessing; `## OptionalDeps` only affects load order, so nothing breaks
or nags when it is absent.

### If it says "incompatible"

Forever uses its own interface number (`16001`, game version 1.60.1) which is
*lower* than retail's, so an addon built only for retail is rejected outright.
`NextMob.toc` declares every supported client on one line — `16001` for Forever,
`120105` for retail, `50500` for Mists Classic and `11509` for Classic Era — so
it should be picked up automatically.

If a patch bumps the number, check what your client actually wants:

```
/run print((select(4, GetBuildInfo())))
```

Then add that number to the `## Interface:` line of `NextMob.toc` and
`/reload`.

## Using it

- **Click the button** — targets the first quest mob it can find near you.
  Click again to cycle to the next candidate.
- **Keybind it** — Esc → Key Bindings → **NextMob** → *Target quest mob*.
  This is the nicer way to use it; bind it to something like `` ` `` or a mouse button.
- **Put it on an action bar** — the addon already maintains a real macro named
  `NextMob`, so just drag it onto a bar from Esc → Macros and bind it there.
  That is the same mechanism the button itself uses.

### Commands

| Command | What it does |
|---|---|
| `/nm list` | Prints exactly what it would target right now, best first |
| `/nm hide` / `/nm show` | Toggle the floating button |
| `/nm lock` | Lock/unlock dragging |
| `/nm reset` | Put the button back in the middle of the screen |
| `/nm test` | Diagnostics — start here if nothing gets targeted |
| `/nm mode` | How a click targets: `macro`, `macrotext` or `unit` |
| `/nm macro` | Switch to macro mode and say which macro slot it is in |
| `/nm cycle` | Clear your current target on every click instead of only when it's dead/friendly |
| `/nm status` | Which data sources are active, and how much it has learned |
| `/nm db` | What QuestieDB resolved for each quest in your log |
| `/nm forget` | Wipe the learned NPC database |

## How it figures out what to target

There is no API that says "this quest wants you to kill creature #1234", so the
addon builds the list from three sources and ranks them:

1. **Creature-id matches** (best). Every quest objective ultimately refers to a
   creature *id* — a number that is identical on every realm and in every
   language. The addon collects the ids your quests want (from QuestieDB, and
   from ids it has learned itself), then reads the id out of each nearby unit's
   GUID. When one matches, it takes that unit's name straight off the unit.

   This is what removes the last of the guesswork. A German client showing
   *Murloc-Orakel* for the creature QuestieDB calls *Murloc Oracle* matches
   anyway, because 1234 == 1234. Plurals, localisation and objective text that
   names something other than the mob all stop mattering. Shown as `id-match`
   in `/nm list`.
2. **QuestieDB** (if installed). QuestieDB is a separate addon shipping a
   real quest/NPC/item database for Classic Era, TBC, Wrath, Cata, Mists and
   **Forever**. When it is present NextMob stops guessing entirely: it asks
   which NPCs the quest wants, and for collect objectives it asks which NPCs
   drop the item. That is the whole Murloc Poachers problem solved outright —
   no first manual kill, no name-overlap heuristic. Shown as `questiedb` and
   `questiedb-drop` in `/nm list`; `/nm db` prints what it resolved for every
   quest in your log.

   It is an **optional** dependency. Nothing here is copied from QuestieDB —
   NextMob reads its public `LibQuestieDB` API at runtime and does nothing
   if it is absent, so everything below still applies on its own.
3. **Learned NPCs.** When a quest objective ticks up, the addon records
   which NPC was responsible against that objective in your SavedVariables.
   This is what makes it work for quests whose objective text doesn't name the
   mob — "Kill 12 Defias bandits" where the mobs are actually called *Defias
   Smuggler*. It gets smarter the more you play, and the data is shared across
   all your characters.

   How it identifies the culprit depends on the client, and `/nm status` tells
   you which is in use:
   - **Retail / Classic:** the combat log — something you personally damaged
     died within a few seconds of the objective ticking up. Precise.
   - **Loot (all clients):** a drop objective ticks when you *loot*, not when
     the mob dies, so the corpse in the loot window is the best evidence there
     is. On `LOOT_OPENED` the addon reads the loot source's GUID, looks up the
     name it cached when you targeted that mob, and credits it — which stays
     correct even if the fight ran long or you already tabbed to the next
     murloc.
   - **WoW Forever / Midnight:** addons are no longer allowed to register
     `COMBAT_LOG_EVENT_UNFILTERED` at all (it raises an error), so it falls back
     to **target history**: the most recent hostile thing you deliberately
     targeted or moused over, within 25 seconds. Slightly less precise — if you
     tab around a lot mid-fight it can occasionally learn the wrong name — but
     `/nm forget` resets it, and the count-weighted ranking means one bad guess
     gets outvoted by correct ones.
4. **Nearby units.** Hostile nameplates, your target and your mouseover are
   remembered for 45 seconds. If one of those names loosely matches an objective,
   the addon uses the nameplate's exact spelling and ranks it first, because that
   mob is demonstrably standing in front of you. Enable enemy nameplates (`V` by
   default) to get the most out of this.
5. **Drop-quest guesses.** A collect objective names an *item*, never a mob —
   "Murloc Fin: 0/10" tells you nothing to target. But quest items are very
   often named after the family that drops them, so a **nearby** mob sharing an
   identifying word with the item is offered as a guess: *Murloc Fin* →
   the *Murloc Oracle* in front of you. Whole words only, and stopwords never
   count, so "Bolt of Linen Cloth" matches nothing and "Ring of Shadow" does
   not match "Shadowmage". Restricted to nearby mobs on purpose: a wrong guess
   costs one inert macro line and nothing else. Shown as `drop-guess` in
   `/nm list`.
6. **Objective text.** `"Kobold Vermin slain: 3/8"` → `Kobold Vermin`. It builds
   the parsing pattern from the game's own localized `QUEST_MONSTERS_KILLED`
   string, so this works in any client language. It also adds a de-pluralized
   variant, since `/target` does prefix matching.

### How candidates are ranked

Every candidate name gets a score, highest first:

| Source | Score |
|---|---|
| Creature-id match on a visible unit | 90 |
| Creature-id match seen earlier this session | 88 |
| QuestieDB (kill objective, then drop source) | 80 |
| Learned from watching an objective tick up | 60 |
| Nameplate name matched to objective text | 40 |
| Drop guess from a shared word in the item name | 35 |
| Objective text, then its de-pluralised form | 20 / 15 |

Plus **+100** if that name is currently nearby, and **+10** if the quest is in
your objective tracker. The nearby bonus deliberately dominates: a mob standing
in front of you beats a theoretically better name that is nowhere near.

The result becomes an ordinary macro body on a secure button:

```
/cleartarget [dead][help]
/target [noexists] Defias Bandit
/target [noexists] Kobold Vermin
...
```

Each `/target` only fires if the previous one found nothing, so one click walks
down the list until something is actually in range.

Candidates are ranked by: nearby > learned > objective text, and quests in your
objective tracker outrank quests that aren't being watched. Completed quests and
finished objectives are dropped.

### How a click actually targets (`/nm mode`)

Targeting is a protected action, so a click has to go through a secure button.
There are three mechanisms, and which ones a client permits has changed over
time — Midnight-era clients restricted this area heavily. If targeting does
nothing, this is the knob.

| Mode | What the button does | Notes |
|---|---|---|
| `macro` | Runs the real saved macro named `NextMob` | **Default.** The most compatible mechanism: identical to you clicking a macro on your action bar. The addon creates and updates the macro for you. |
| `macrotext` | Runs an inline macro body | The older mechanism. Simpler, but the `macrotext` attribute is restricted on some clients, in which case clicks do nothing at all. |
| `unit` | Points straight at a matched nameplate unit | Most exact, and needs no names. But secure attributes cannot be rewritten in combat, so if the locked mob dies mid-fight the click goes inert until combat ends. |

Only one is ever armed at a time — the unused attributes are explicitly cleared,
because leaving both `macro` and `macrotext` set makes which one wins undefined.

`/nm unit` is a shortcut that toggles between `unit` and `macro`.

### Objectives you have already finished

Anything whose count is full stops being offered, at four levels:

- **A finished objective** contributes no names. "Done" means the game's
  `finished` flag, *or* `numFulfilled >= numRequired`, *or* the `8/8` in the
  objective text — whichever the client gives us.
- **A quest with every objective filled** contributes nothing at all, even when
  the game has not yet flagged the quest itself as complete because you still
  have to walk back and hand it in.
- **QuestieDB rows are matched to live objectives** by their label. So on a
  quest that wants 5 boars *and* 7 gnolls, finishing the boars drops the boars
  from the list while the gnolls stay. A row QuestieDB gives no label for is
  kept rather than discarded, since it cannot be attributed either way.
- **Creature ids are untracked with their objective**, so an id-verified name
  cannot sneak a finished objective back into the list.

A mob needed by two quests stays on the list as long as *either* objective is
still open, and gets attributed to the quest that still needs it.

The one gap is timing: secure buttons cannot be rewritten in combat, so if you
hit the count mid-fight the finished mob stays in the list until you drop out of
combat, at which point the list rebuilds immediately.

### Corpses

`/target` matches by name and will happily land on a corpse. A macro
conditional cannot inspect a candidate *before* targeting it — but it can
inspect the result. So after every attempt the macro drops the target if it
turned out to be dead, which lets the next attempt have its turn:

```
/cleartarget [dead][help]
/target [noexists] Murloc Oracle
/cleartarget [dead]
/target [noexists] Murloc Netter
/cleartarget [dead]
```

The trailing guard means a click never leaves you holding a corpse. Attempts and
guards are always added as a pair, so a body truncated by the 255-character
limit can never end on an unguarded attempt.

The cost is 19 characters per name, so roughly 4 names fit instead of 7. The
ranking makes that a fair trade — the names that survive the cut are the ones
worth trying. `/nm dead` turns it off if you would rather have the longer list,
and `/nm status` shows how much of the budget is in use.

### An error on login?

Run `/nm test`. It reports **blocked actions attributed to this addon**, so you
can tell whether a popup was caused by NextMob or by something else loading
at the same time.

The known cause was the combat log. Midnight-era clients forbid addons from
registering `COMBAT_LOG_EVENT_UNFILTERED`, and a refusal can arrive as a
blocked-action popup rather than a catchable Lua error — so wrapping the call
was not enough, and NextMob now does not ask for it at all on clients that
look like that generation (detected via `C_RestrictedActions`). Nothing is lost:
learning already falls back to target history and loot sources there, which is
what your client was using anyway. `/nm status` names the active source.

If an error still appears, capture the text with:

```
/console scriptErrors 1
```

Then `/reload` and send the message it shows.

### Nothing gets targeted?

Run `/nm test`. It prints your client build and interface number, the click
mode, the button's live attributes, the saved macro and its body, and a **count
of clicks the button has received**. That count is the thing to look at:

- **It stays at 0 after you click** — the click is not reaching the button.
  Check the button is not behind another frame, and that `/nm list` shows
  candidates at all.
- **It counts up but nothing is targeted** — the click arrives and the
  targeting mechanism is being refused. Try `/nm mode unit`, then
  `/nm mode macrotext`, and see which works.

A useful control: make a macro by hand containing `/target <some mob you can
see>` and click it. If that does not target either, the client is restricting
name-based targeting itself rather than anything in this addon, and `/nm mode
unit` is the route.

## Known limits

These are inherent to what addons are allowed to do, not bugs:

- **The list can't change during combat.** Blizzard blocks rewriting a secure
  button's macro while you're in combat, so the list is frozen at whatever it was
  when combat started, and any update is applied the moment you leave combat. In
  practice this is fine — the names you need are already in there. It does mean
  click-to-cycle doesn't advance mid-fight.
- **`/target` only finds units already loaded near you.** It can't point you at a
  mob across the zone; it's a targeting button, not a waypoint arrow.
- **Drop quests lean on a guess for the first kill.** If the item shares a word
  with the mob ("Murloc Fin" / "Murloc Oracle") it works immediately. If it
  doesn't — "Large Candle" from kobolds, "Okra" from gnolls — nothing can be
  derived from the text, so you kill the first one yourself and the loot pass
  learns it permanently.
- **Nothing can point at a mob you've never met.** Both the drop guess and the
  nearby bonus need the mob loaded in front of you. There is no API for "what
  drops this item", so the first encounter of an oddly-worded quest is always
  manual.
- **Macro bodies are capped at 255 characters** — both real macros and the
  secure button's `macrotext`, since patch 11.0.2. That works out to roughly
  7-8 names per click. The ranking is what makes this fine: nearby mobs and
  learned NPCs sort to the top, so the names that survive the cut are the ones
  actually worth trying. `/nm status` shows how much of the budget is in use.
- **One macro slot is used.** Macro mode needs a real saved macro, so the addon
  keeps an account macro named `NextMob` up to date. If your macro list is
  full it says so and falls back to inline `macrotext` automatically.

## Verified how far?

The quest parsing, ranking, macro building, learning pass and the restriction
handling are covered by 150 offline tests run against seven stubbed client
profiles — one with the combat log available, one shaped like Forever (combat
log registration raising, Secret values coming back from unit APIs), one
exercising drop/collect quests end to end, and one driving the QuestieDB
adapter including the cases where QuestieDB is absent, half-installed,
version-gated, or throwing, and one covering creature-id matching, malformed
and vehicle GUIDs, and every click mode including the fallback when the macro
list is full, and one covering partially-complete quests: per-objective
completion by flag, by `8/8` text and by `numFulfilled`, quests finished but not
handed in, and mobs shared between a finished and an unfinished quest; and one
covering corpse guards (including that truncation keeps attempts and guards
paired) and blocked-action attribution.

Two caveats specific to the QuestieDB route, both from its own docs:

- QuestieDB lists Forever as a real flavour, but says client acceptance is
  still *pending*. If it does not load for you, NextMob silently falls back
  to its heuristics.
- QuestieDB's published API documents `QuestDB.Get(id, key)` and friends, but
  **not** the row layout of a quest's `objectives` field. Rather than hard-code
  a layout from guesswork, the adapter walks the structure and keeps only
  integers that resolve to a real NPC name through `NpcDB` — a wrong guess
  can't survive, because there is no name for it. The reputation group is
  skipped outright, since a faction id can collide with a valid NPC id. If
  `/nm db` ever shows a name that looks wrong for a quest, that is where to
  look. What those
tests cannot cover is whether Forever permits `macrotext` on a secure button at
all; Blizzard has not documented it either way, which is why the real-macro
fallback above exists.

## Files

- `Core.lua` — quest scanning, name parsing, the learning pass, macro building
- `QuestieDB.lua` — the optional QuestieDB adapter
- `Button.lua` — the movable secure button
- `Bindings.xml`, `Locale.lua` — keybinding
- `NextMob.toc` — the file list and every supported client version
- `tools/run-tests.lua`, `tools/tests/` — the offline test suites, run by CI
