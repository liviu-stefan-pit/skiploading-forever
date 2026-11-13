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
| `/sl` | For each kind (ores, herbs): whether it is shown, and how many locations you found, other players found, and were imported. Then what is shown right now and a short list of the commands. Any word the addon does not know does the same. |
| `/sl only <what>` | Shows exactly what you name and hides everything else. |
| `/sl show <what>` | Adds what you name to what is shown. |
| `/sl hide <what>` | Takes what you name away from what is shown. |
| `/sl show all` | Shows every node of every kind. `/sl show` on its own does the same. |
| `/sl hide all` | Hides everything. `/sl hide` on its own does the same. With everything hidden the addon does no work at all. |
| `/sl skillups` | Turns the skill-up filter on or off: only nodes that can still raise your skill (orange, yellow and green) are shown. Red and grey nodes are hidden, and so is a whole kind whose profession you don't have. `/sl xp` does the same. |
| `/sl skillups strict` | The same, but only orange and yellow nodes, the ones that skill up most of the time. Also `/sl skillups on` and `/sl skillups off`. |
| `/sl xp <what>` | Shortcut for `/sl only <what>` plus the skill-up filter on: `/sl xp mining` shows only the ores that can raise your Mining. `/sl xp strict mining` keeps only orange and yellow. |
| `/sl reset` | Everything shown, skill-up filter off. |
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
| Gold ring, large | A node **you** gathered. Greyed out for 5 minutes after you gather it. |
| Silver ring, large | A node **other players** found on Forever (see [Sharing nodes](#sharing-nodes)). |
| No ring, small and faint | An **imported** location nobody has confirmed yet. |

Hovering a pin shows:

- The node name, coloured the way the game colours gathering difficulty: red (you can't gather
  it), orange, yellow, green, grey (no skill-up).
- The skill it needs and your current skill.
- For your own nodes: how many times you have seen it, when you last saw it, and the shortest
  time you have seen it come back in.

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

**Why a pin can be empty.** The server keeps only some spawn points active at a time, and decides
which. No addon can know which are up right now, and exact respawn timers are not available to
addons. The addon shows where nodes *can* be, and how reliable each spot has been for you.

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

Only nodes a player gathered themselves are taken from a file. Running the merge again is safe:
`Shared.lua` is rebuilt from scratch each time.

## Rebuilding the imported set

`tools\build-seed.js` regenerates `Seed.lua` from a GatherMate2_Data folder installed next to this
addon. Run `node build-seed.js` from the `tools` folder. It only reads the GatherMate2_Data files.

A new `Seed.lua` only affects fresh installs. An existing dataset is not re-imported.

## Known limits

- The minimap shows nodes from the zone you are in, so nodes just across a zone border appear once
  you cross it.
- Minimap distances assume a round minimap and the standard Classic zoom ranges.
- Two nodes of the same type less than about 15 yards apart are treated as one.
- A node with a name the addon does not know is stored under that name with a generic icon.
- Only English clients have been tested.

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
