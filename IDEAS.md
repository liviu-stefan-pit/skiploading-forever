# Ideas for Skip Loading

Thirty ideas, ranked by how much value I think each adds for the work it takes. The direction is
the one you named: grow from "ores and herbs" into a general-purpose world-knowledge addon, without
losing what makes it good now (small, fast, your own data trusted first).

Effort: **S** = an evening, **M** = a few days, **L** = a week or more.

Everything here stays inside what the addon API allows. Nothing reads memory, automates gameplay,
or needs a server.

## The short version

| # | Idea | Effort | Why it ranks here |
| --- | --- | --- | --- |
| 1 | Things as modules | M | Everything general-purpose depends on it |
| 2 | Filter by skill and node type | S | Cuts the clutter you complained about first |
| 3 | Farming routes | M | Turns a map of dots into something you follow |
| 4 | Record from minimap tracking | M | Multiplies how fast the dataset becomes real |
| 5 | Guild and party sync | L | Verified Forever data for everyone, automatically |
| 6 | NPC and service recorder | M | The first step beyond gathering |
| 7 | Seed and dataset updates | S | Without it, improvements never reach existing users |
| 8 | Reliability score | M | Ranks spots by how often they pay off |
| 9 | Treasure chests and fishing pools | S | Data and code path already exist |
| 10 | Nearest-node arrow | S | Useful every minute you gather |
| 11–30 | See below | | |

---

## Tier 1: the foundation and the biggest wins

### 1. Things as modules (M)
Today "ores" and "herbs" are wired into the code. Split the addon into a small core (dataset,
pins, map, minimap, recording, sharing) and one short definition per kind of thing: its name,
icons, how it is detected, and what its tooltip says. Adding chests, fishing pools, vendors or
rares then becomes one small file each. This is the step that makes "whole-purpose" possible, and
it is cheapest to do now while there are only two kinds.

### 2. Filter by skill and by node type (S) — done
Built as `/sl only|show|hide <kinds or node names>` plus `/sl skillups [strict]`; see the README.

`/sl only skillups` hides nodes that are grey or red for your skill. `/sl only iron, gold` shows
just the types you name. The addon already knows each node's requirement and your skill, so this
is mostly a filter in one function. It is the most direct answer to "hundreds of points and only a
few matter".

### 3. Farming routes (M–L) — done
Built as `/sl route [on|off|new|auto|<minutes>|safe|reverse|skip]`; see the README, and ROUTES.md
for the method and what changed while building it.
`/sl route` draws one loop through the current zone, built only from the nodes the map shows (so
`/sl only copper` gives a copper route), and points at the next stop. Spots weigh by where they came
from (yours first, imported last) and by their checks. Solved as a probabilistic orienteering problem:
Dinkelbach's method picks the loop with the most nodes per minute, an iterated local search (2-opt,
Or-opt, drop/add/swap) builds each loop, and a probabilistic-TSP pass makes skipping empty stops cheap.
This is what people install the Routes addon for.

### 4. Record nodes from minimap tracking (M) — done
Built as "spotting": blue-ringed pins, `/sl spot [on|off]`; see the README.

With Find Minerals or Find Herbs on, hovering a blip on the minimap shows the node's name. The
addon can read that tooltip and work out the node's position from where the cursor is on the
minimap. That records nodes you ride past without gathering, including ones your skill is too low
for. Mark them as "seen" so they rank between imported and gathered. This could grow your verified
data many times faster than gathering alone.

### 5. Guild and party sync (L)
Addons can send hidden messages to guild and party members running the same addon. Found nodes
would spread while people play, with no files to send. It needs care: version checks, rate limits,
and never letting received data overwrite your own. Big payoff, and the easiest idea here to get
wrong, so it comes after the dataset format has settled (see 7).

### 6. NPC and service recorder (M)
Record every vendor, repairer, trainer, flight master, innkeeper, mailbox and banker you interact
with, then answer `/sl find repair` with the nearest one and a pin. All of it comes from events
the game already fires when you open those windows. This is the natural first non-gathering
module, and it is useful to every player, not only gatherers.

### 7. Seed and dataset updates (S)
Right now a new `Seed.lua` only affects fresh installs. Give the dataset a version and a small
migration step, so new imported points, corrected skill requirements and format changes reach
people who already have data. Low glamour, but every later idea that changes data depends on it.

### 8. Reliability score (M) — done
Built as "checks": `/sl reliable [on|off]`, tooltip lines, faint pins; see the README.

The first idea was to count a miss whenever you pass near a spot without gathering it. That is
weak evidence: you may not have wanted it, or not looked. The built version leans on a stronger
signal the addon already reads.

**The plan as built.**

1. **Three kinds of check, each with its own strength.**
   - *Hit*: you gather the node, or its blip is named on the minimap. Certain.
   - *Miss (probe)*: you rest the cursor on a spot's minimap pin with that kind's tracking on, and
     for half a second the game names no blip of that type there. If the node were up, its blip
     would be under the cursor and the game would name it. This reads the same tooltip spotting
     reads, so a miss is as certain as a sighting. It is only taken where the spot's position is
     exact enough: the cursor must be within (blip half-width minus the spot's position error) of
     the pin's centre. That works best zoomed out, where a blip covers more yards.
   - *Pass (walk-by)*: you walk within 8 yards of a spot whose position is exact, of a type you
     would gather (it passes your filters and can still raise your skill), and leave 35 yards away
     without gathering or seeing it. Counts a quarter. Flight paths, combat and being dead void it.
2. **Visits, not events.** Everything learned about one spot within 10 minutes is one visit and
   counts once. The strongest result wins: a hit undoes a miss or pass of the same visit.
3. **Your own gathering is not a miss.** For 15 minutes after you gather a node, finding it empty
   says nothing (you took it), unless the minimap has already shown it back.
4. **Tracking must be on**, read from the tracking menu or icon, or proven by a blip of that kind
   read in the last 2 minutes. `/sl spot` says what it found and where it read it.
5. **Score.** (finds + 1) / (finds + empty + ¼ walk-bys + 2): an even prior, so two checks never
   decide a spot. Checked 3+ times and under 34% means poor: drawn at 40% opacity, hidden by
   `/sl reliable`.
6. **Storage.** Recorded nodes keep `hits`, `misses`, `passes`, `vt`, `vo` on themselves. Imported
   points are bare numbers, so their checks live in `DS.checks[kind][map][coord]` and move onto the
   node that replaces them when you gather or spot it. On first load, earlier finds (`seen`)
   become hits.
7. **Probe waits for the pin tooltip.** While a pin is being probed its own tooltip is held back,
   so it can never hide the blip's tooltip and cause a false miss. When it appears it says the
   result ("Empty when you checked just now").

**Left for later.** Checks are not in the shared files yet (that is 27). Routes (3) can now weight
stops by the score. Mousing over the node itself in the world names it too, and could become
another hit source, but the object's distance from you is unknown.

### 9. Treasure chests and fishing pools (S)
The GatherMate2 data you already have includes chests; pools can be recorded the same way nodes
are. With modules in place (1) each is a small definition plus a seed import.

### 10. Nearest-node arrow (S)
A small arrow and distance to the nearest node that passes your filters, preferring ones not
gathered recently. The client has a built-in map waypoint the addon can set, so the simplest
version needs no new art.

## Tier 2: strong additions

### 11. Zone summary on the world map (S)
When you open a zone: "14 Iron, 6 Gold, 9 Kingsblood here; 11 give you skill-ups". On the
continent map, tint each zone by how useful it is for your current skill.

### 12. Where to level next (S)
`/sl next` names the best zone for your current Mining or Herbalism skill, judged by how many
orange and yellow nodes it has and how reliable they have been. Falls out of 2 and 11.

### 13. Rare mob sightings (M)
Record rares when you target or mouse over them, with the time. Show their spots and when you last
saw each. Optional sound when one is in view. Shares the same pins, tooltips and sharing as nodes.

### 14. Session stats (S)
Nodes per hour, what you gathered this session, time since the last skill-up. One chat line on
`/sl session`, no window needed.

### 15. Recently gathered list (S)
`/sl recent` lists the nodes you gathered in the last half hour with the time since, and how fast
each has come back before. It makes the "fastest return" data usable while you loop a zone.

### 16. Dataset clean-up tools (S)
`/sl clean` merges near-duplicates and reports what it did. Alt-click a pin to delete it. Nodes
not confirmed for several game builds fade further. This keeps a long-lived dataset trustworthy.

### 17. Cave and building hints (S)
When you record a node, save the subzone name and whether you were indoors. The tooltip can then
say "inside Jasperlode Mine", which saves riding to a pin that is really underground.

### 18. Nodes across zone borders (M)
The minimap only knows the zone you are in. Converting to world coordinates would show nodes just
over a border, and fixes pins vanishing near edges. It is also needed for routes that cross zones.

### 19. Skinning spots (M)
Record where you skin, by creature and level. Over time it shows where the beasts for your skill
are densest. It needs a different detector (loot from a skinned corpse) but reuses everything else.

### 20. A small settings page (M)
Pin sizes, opacity and the show/hide switches in the game's own Settings screen. Chat commands
stay. Worth doing once there are enough options that typing them gets old, not before.

## Tier 3: reach and polish

### 21. Other languages (M)
Node names are matched in English. Resolve them from the client's own item and spell names, so the
addon works on any language without translation files.

### 22. Forever-only content (M)
Forever adds zones the imported data barely covers, renamed starter herbs, and new gathering
systems. Give these first-class support: track them as their own node types where they differ, and
make new-zone data the top request in CONTRIBUTING, since nobody else has it.

### 23. Alts (S)
Remember each character's gathering skills. The tooltip can then say "your alt can mine this", and
filters can run against any character.

### 24. Custom pins and notes (S)
Shift-click the map to drop your own pin with a note, and attach notes to any existing pin. This is
the general-purpose escape hatch: anything the addon does not know about, you can still mark.

### 25. Value of a route (M)
If an auction-price addon is installed, show the value of what a node type yields and rank routes
by expected gold per hour instead of node count. Optional, and the addon must work fine without it.

### 26. Heat map when zoomed out (M)
On continent and world views, replace individual pins with a density glow per node type. It keeps
the map readable and answers "which zone" at a glance.

### 27. Shared respawn knowledge (M)
Include the fastest-return figure in what players share, and combine it per node type and zone.
One player's guess becomes a decent estimate once enough people contribute.

## Tier 4: the project around the addon

### 28. Automated tests in the repository (S)
The stubbed-game test script used while building the addon is not in the repo yet. Add it and run
it on every push. It already covers recording, merging, sharing, the minimap maths and the
commands, and it will matter more with every module added.

### 29. Packaged releases (S)
A GitHub Action that builds a zip with the folder correctly named `SkipLoading` on every tagged
version, and publishes it to CurseForge and Wago. It removes the "rename the folder" step that
trips up new users, and gets the addon in front of people.

### 30. A web map of shared nodes (L)
A static page on GitHub Pages showing everything players have contributed, by zone and type, with
a count of contributors. It makes the project's real asset visible (verified Forever data), gives
people a reason to send their files, and is useful even to players who never install the addon.

---

## Suggested order

1. **7, then 1.** Dataset versioning first, then modules. Both are groundwork, and both get more
   expensive the longer they wait.
2. **2, 10, 9.** Three small, visible wins on the new structure.
3. **4 and 8.** Better data in, better ranking out.
4. **3.** Routes, once the data can support them.
5. **6 and 13.** The first modules that are not about gathering.
6. **28 and 29** alongside any of the above, since they protect and distribute everything else.
7. **5** when the dataset format has stopped changing.

## What I would not build

- **Exact respawn timers.** The server does not share them. Idea 15 and 27 are the honest version.
- **Anything that reads nodes beyond what the game shows you.** That is cheat territory and risks
  accounts.
- **A big settings window early.** It is the usual way a light addon stops being light.
