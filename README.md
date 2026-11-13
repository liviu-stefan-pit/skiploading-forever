# Skip Loading

A very light World of Warcraft addon that shows ore and herb locations on the world map and
minimap. Built for **WoW Forever** (interface 16001).

It starts from an imported set of locations, then learns from what you actually gather. Nodes you
found yourself are trusted over the imported ones, and are drawn so you can tell them apart.

There is no settings window and no library dependency: a small core, one short file per kind of
thing it shows, a data file, and a few chat commands.

## Install

1. Download this repository (Code > Download ZIP) or clone it.
2. Put the folder in `World of Warcraft\_forever_\Interface\AddOns\` and name it exactly
   `SkipLoading`. The name matters: the game ignores the addon if the folder is called anything
   else, such as `skiploading-forever-main`.
3. Restart the game. A `/reload` does not pick up a new addon.

With git:

```
cd "World of Warcraft\_forever_\Interface\AddOns"
git clone https://github.com/liviu-stefan-pit/skiploading-forever.git SkipLoading
```

On first login you should see a chat line saying the dataset was created.

## Commands

This is every command the addon has. `/skiploading` works in place of `/sl` in all of them, and
upper or lower case does not matter.

| Command | What it does |
| --- | --- |
| `/sl` | For each kind (ores, herbs): whether it is shown, and how many locations you found, spotted on the minimap, other players found, and were imported. Then what is shown right now and a short list of the commands. Any word the addon does not know does the same. |
| `/sl only <what>` | Shows exactly what you name and hides everything else. |
| `/sl show <what>` | Adds what you name to what is shown. |
| `/sl hide <what>` | Takes what you name away from what is shown. |
| `/sl show all` | Shows every node of every kind. `/sl show` on its own does the same. |
| `/sl hide all` | Hides everything. `/sl hide` on its own does the same. With everything hidden the addon does no work at all. |
| `/sl skillups` | Turns the skill-up filter on or off: only nodes that can still raise your skill (orange, yellow and green) are shown. Red and grey nodes are hidden, and so is a whole kind whose profession you don't have. `/sl xp` does the same. |
| `/sl skillups strict` | The same, but only orange and yellow nodes, the ones that skill up most of the time. Also `/sl skillups on` and `/sl skillups off`. |
| `/sl xp <what>` | Shortcut for `/sl only <what>` plus the skill-up filter on: `/sl xp mining` shows only the ores that can raise your Mining. `/sl xp strict mining` keeps only orange and yellow. |
| `/sl reliable` | Turns hiding of spots that keep coming up empty on or off (see [How reliable a spot is](#how-reliable-a-spot-is)). Also `/sl reliable on` and `/sl reliable off`. |
| `/sl route` | Turns the farming route on or off in the zone you are in (see [Farming routes](#farming-routes)). Also `/sl route on` and `/sl route off`. |
| `/sl route new` | Plans the route again from what you know now. |
| `/sl route 15` | Aims for a loop of about 15 minutes (2 to 120). `/sl route auto` goes back to the loop with the most nodes a minute (the default). |
| `/sl route anywhere` | The best loop of the whole zone, wherever it is, instead of the best one near you; again to turn it back. |
| `/sl route forget` | Forgets the slow legs and skipped stops learned in this zone. |
| `/sl route safe` | Turns off the small bonus that sends the route past untested spots; again to turn it back on. |
| `/sl route reverse` | The same loop, the other way round. |
| `/sl route skip` | Points at the stop after the next one. A stop skipped twice without going there is left out of new routes. |
| `/sl reset` | Everything shown, skill-up filter, `/sl reliable` and the route off. |
| `/sl spot` | Whether spotting on the minimap is on, what it recorded this session (sightings, spots found empty, walk-bys), whether your tracking reads as on, and the last tooltip it read over the minimap (see [Spotting](#spotting-nodes-on-the-minimap)). |
| `/sl spot on`, `/sl spot off` | Turns spotting on the minimap on (the default) or off. |
| `/sl export` | Tells you where your saved file is, for sharing the nodes you found (see [Sharing](#sharing-nodes)). |
| `/sl skill` | Troubleshooting: prints the Mining and Herbalism skill the addon read and where it read it from, then your whole skill list. Use it when a pin's colour or "you don't have it" looks wrong. |

`<what>` can be a kind (`ores`, `herbs`, also `ore`, `mining`, `herb`, `herbalism`), a node name
or part of one, or several of these separated by commas or spaces. A word matches whole words in
node names first, so `silver` is Silver Vein and not Silverleaf; if nothing matches it tries the
start of a word, so `peace` finds Peacebloom.

| Example | Shows |
| --- | --- |
| `/sl only herbs` | Herbs only. |
| `/sl show ores` | Ores as well. |
| `/sl only iron, gold` | Iron Deposit, Dark Iron Deposit, Gold Vein and Ooze Covered Gold Vein, nothing else. |
| `/sl show kingsblood` | The same plus Kingsblood. |
| `/sl hide copper` | Every ore except Copper Vein. |
| `/sl xp mining` | Only the ore veins that can still raise your Mining skill. No herbs. |

After each change the addon says in one line what is shown and how many pins that makes in your
zone, e.g. *showing all ores except Copper Vein + all herbs, only skill-ups (Mining 140,
Herbalism 60). 23 in this zone.* The type filter and the skill-up filter work together and are
switched separately, so `/sl skillups` off brings back exactly what you had picked before.

The skill-up filter follows your skill: when it goes up, the pins update by themselves. These
settings are remembered across sessions and shared by all your characters; the skill-up filter
always uses the skill of the character you are playing.

## What the pins mean

| Pin | Meaning |
| --- | --- |
| Gold ring, large | A node **you** gathered. Greyed out for 5 minutes after you gather it, unless you see it back on the minimap sooner. |
| Blue ring, medium | A node you **spotted on the minimap** but have not gathered yet. Its position is close, not exact. |
| Silver ring | A node **other players** found on Forever (see [Sharing nodes](#sharing-nodes)). Medium if they only spotted it. |
| No ring, small and faint | An **imported** location nobody has confirmed yet. |

Hovering a pin shows:

- The node name, coloured the way the game colours gathering difficulty: red (you can't gather
  it), orange, yellow, green, grey (no skill-up).
- The skill it needs and your current skill.
- For your own nodes: how many times you have seen it, when you last saw it, and the shortest
  time you have seen it come back in.
- For spotted nodes: how many times you spotted it, when, and how many yards its position may be
  off.

Pins on the minimap let the mouse through to the tracking blips underneath, so the game can still
show a blip's name. Their own tooltip appears when no blip is under the cursor.

Skill requirements are the Classic values. Forever may have changed some; please report any that
are wrong.

## How the data works

**The imported set.** `Seed.lua` holds about 9,100 ore and 11,000 herb locations. They come from
GatherMate2_Data, with points of the same node type that sit next to each other merged into one.
See [Credits](#credits). These locations are Classic-era positions and have not been verified
against the Forever world, which is why they are drawn faint.

**Your dataset.** The first time the addon loads it copies the imported set into its own saved
dataset, `SkipLoadingForeverDataSet`. From then on it only works on that copy. It lives in
`WTF\Account\<your account>\SavedVariables\SkipLoading.lua` and is shared by all your characters.
The game writes that file only on logout, exit or `/reload`.

**Recording.** When you start mining a vein or picking a herb, the addon saves your position, the
node type, how many times you have seen it, the first and last time, and the game build. Several
hits on the same vein count once.

**Your nodes win.** A node you found replaces the nearest imported point of the same type within
25 yards. Only the nearest one, so a real second node close by is kept.

## Spotting nodes on the minimap

With **Find Minerals** or **Find Herbs** on, the minimap shows a blip for each node near you, and
holding the cursor over a blip makes the game show its name. Skip Loading reads that name and works
out where the blip is from where your cursor sits on the minimap. That records nodes you only ride
past, including ones your skill is too low for. It reads only what the game shows you.

- **You have to hover.** The game names a blip only while the cursor is over it, so nothing is
  recorded until you do. Sweeping the cursor over the blips now and then while you travel is
  enough.
- **Close, not exact.** The cursor can be anywhere on the blip, so a sighting is good to about the
  blip's width: around 20 yards zoomed all the way out, 5 zoomed all the way in. Zoom in for better
  positions. Each new sighting of the same spot is averaged in, and the tooltip says how close the
  position is.
- **It confirms imported points.** A sighting near an imported location of the same type turns
  that location into a spotted node, a blue-ringed pin, between the faint imported pins and the
  ones you gathered.
- **Gathering it makes it exact.** When you gather a spotted node it becomes an ordinary gathered
  node at the spot where you stood.
- **It shows when nodes come back.** Seeing one of your gathered nodes on the minimap again shows
  it has respawned. Its pin gets its colour back, and the time counts towards "back within".

If nothing is recorded, hover a blip and type `/sl spot`. It shows the last tooltip it read over the
minimap and which frame showed it. Please include that line in a bug report.

## How reliable a spot is

The server keeps only some spawn points active at a time, so a pin can be empty. The addon keeps
count of how often each spot paid off when you came by:

- **Up**: you gathered it, or its blip was named on the minimap.
- **Empty**: with Find Minerals or Find Herbs on, you held the cursor still on the middle of its
  pin on the minimap for half a second, and the game named no blip of that type there. If the node
  were up, its blip would be under the cursor. The pin's tooltip appears once this is decided and
  says the result. It works best zoomed out. Zoomed in, only spots you gathered are exact enough.
- **Walked past**: you walked right past a spot you would gather (shown, and still a skill-up) and
  left without gathering or seeing it. This counts only a quarter, and not on flight paths or in
  combat.

Everything within 10 minutes is one visit and counts once, and a find beats an empty check. For 15
minutes after you gather a node, finding it empty does not count against it, since you took it.

The pin's tooltip shows *Up 6 of 9 times you looked* and the result of your last visit. A spot
checked at least 3 times that paid off less than a third of the time is drawn very faint, and
`/sl reliable` hides it. This works for imported points too, so imported locations that are never
there fade away as you play.

**Why a pin can be empty.** The server keeps only some spawn points active at a time, and decides
which. No addon can know which are up right now, and exact respawn timers are not available to
addons. The addon shows where nodes *can* be, and how reliable each spot has been for you.

## Farming routes

`/sl route` draws one loop through the zone you are in and points at the next stop. It is built
only from the nodes the map is showing, so the filters decide what it is for:

| You type | The route goes through |
| --- | --- |
| `/sl only copper` then `/sl route` | Copper only |
| `/sl hide herbs` | Ores only |
| `/sl xp mining` | Only ores that can still raise your Mining |
| `/sl reliable` | Not the spots that keep coming up empty |

Change a filter while the route is on and a new route is planned at once. Planning runs a few
milliseconds per frame, so the game does not stutter; the first loop shows within a second and the
finished one a moment later, with one line saying what it is:

*route in The Barrens (copper vein): 70 stops (12 found by you, 58 imported), 10359 yards, about
21 min a loop at 14 yards a second, about 31 nodes a loop (1.5 a minute).*

**What it favours.** Every spot has a chance of paying off: where it came from sets the starting
guess (nodes you gathered first, then ones you spotted, then other players', imported last), and
your checks of it (see [How reliable a spot is](#how-reliable-a-spot-is)) take over from there. A
spot checked only a few times gets a small bonus, so the route keeps testing untried spots and
learns which pay off; `/sl route safe` turns that off. With the skill-up filter on, orange nodes
count fully, yellow less, green little.

**How long the loop is.** By default, the loop that collects the most nodes a minute, of at most
20 minutes, with a small preference for the shorter of two loops that collect about the same. Too
short a loop comes back before nodes respawn; too long a one rides through thin areas. How fast nodes respawn is taken from the returns you have seen (8 minutes until there are
enough). `/sl route 15` asks for about 15 minutes instead. The time shown is what a loop takes when
you skip the stops you can see are empty; when every node is up it takes longer, and the line says
how much.

**Following it.** On the world map the loop is a blue line and the leg to your next stop is
gold, with a gold halo on that stop. On the minimap it is a dotted line. When you reach a stop (25
yards), the next one lights up. A stop where you just gathered is skipped. If you leave the loop,
it points at the nearest stop ahead. If the client allows map waypoints, the next stop is also set
as your waypoint. Flight paths and being dead pause it.

**It stays put.** A route is saved per zone with the filters it was made for, and comes back when
you return. It is never changed under you while you follow it. After each full loop the addon
plans again in the background and, if the new loop would collect at least 15% more a minute, says
once that `/sl route new` will use it. Each leg is timed as you ride it; a leg that takes much
longer than its length (a cliff, a river, a cave) twice is planned round next time.

**It starts where you are.** The route is planned from your position: loops are grown from the nodes
round you, and a loop further off has to be better by more than the ride to it costs. When a richer
loop elsewhere was passed over, the addon says how far it is and how much more it collects;
`/sl route anywhere` takes it. A saved route more than a minute and a half's ride away is planned
again from where you are when you turn the route on or enter the zone. Ride far from the route
while it is on and you are told once that `/sl route new` will plan one from there.

**It cannot see the ground.** The game gives addons no terrain, so a leg is a straight line. Long
lines are counted as up to half longer than drawn, which keeps loops to short hops between nodes;
a leg that took much longer than it should slows the legs next to it too in later plans; and a stop
you skip twice without going there (a cave, a cliff top, a camp you avoid) is left out.

How the route is worked out, and why that way, is in [ROUTES.md](ROUTES.md).

## Sharing nodes

Nothing is ever sent automatically. An addon has no internet access; sharing is a file you choose
to send.

**To share what you found:** log out or `/reload`, then send your
`WTF\Account\<your account>\SavedVariables\SkipLoading.lua` to whoever maintains your copy of the
addon. For this repository, see [CONTRIBUTING.md](CONTRIBUTING.md).

**To merge files you were sent** (needs [Node.js](https://nodejs.org)):

1. Put each player's file in `tools\contrib\`, renamed one per player (`anna.lua`, `bob.lua`).
2. From the `tools` folder run `node merge-found.js`.
3. That rebuilds `Shared.lua`. Everyone who gets the addon with the new `Shared.lua` has those
   nodes merged into their dataset on their next login, shown with a silver ring.

Only nodes a player found themselves are taken from a file: gathered, or spotted on the minimap.
Spotted ones stay marked as spotted, and give way to a gathered node of the same type nearby.
Running the merge again is safe:
`Shared.lua` is rebuilt from scratch each time.

## Rebuilding the imported set

`tools\build-seed.js` regenerates `Seed.lua` from a GatherMate2_Data folder installed next to this
addon. Run `node build-seed.js` from the `tools` folder. It only reads the GatherMate2_Data files.

A new `Seed.lua` only affects fresh installs. An existing dataset is not re-imported.

## Known limits

- The minimap shows nodes from the zone you are in, so nodes just across a zone border appear once
  you cross it.
- Minimap distances assume a round minimap and the standard Classic zoom ranges.
- Two nodes of the same type less than about 15 yards apart are treated as one. For nodes spotted
  on the minimap while zoomed out this grows to about 35 yards.
- Spotting assumes the game names tracking blips in a tooltip owned by the minimap. If your client
  does it differently, `/sl spot` shows what it saw.
- A node with a name the addon does not know is stored under that name with a generic icon.
- Only English clients have been tested.
- Routes stay inside one zone, and are planned in straight lines: the addon cannot see terrain, so
  a leg can cross a cliff until you have ridden it twice and it is planned round.

## Tests

`tests\route_test.lua` checks the route solver (against exact answers on small cases, and on the
real Barrens data for speed); `tests\route_game_test.lua` loads the whole addon against a stubbed
game and drives `/sl route`. Both run with any Lua 5.1 or later from the addon folder, e.g.
`lua tests/route_test.lua`.

## Credits

- **Imported locations:** derived from
  [GatherMate2_Data](https://www.wowace.com/projects/gathermate2_data) (authors kagaro, Xinhuan,
  Spinx, Marrtin; GatherMate2 is maintained by Nevcairiel), which is in turn collected from
  [Wowhead](https://www.wowhead.com). Skip Loading also uses GatherMate2's node ids.
- **Icons** are the game's own item icons, loaded from the game client. World of Warcraft is a
  trademark of Blizzard Entertainment. This project is not affiliated with or endorsed by Blizzard,
  Wowhead, or the GatherMate2 authors.
- **Shared nodes:** everyone who sends in what they found. See [CREDITS.md](CREDITS.md).

## Licence

The addon's code is released under the [MIT Licence](LICENSE).

The location data in `Seed.lua` is not covered by that licence. It is derived from third-party data
as described above and is included with credit. If you hold rights in that data and want it
changed or removed, please open an issue.
