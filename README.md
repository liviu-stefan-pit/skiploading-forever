# Skip Loading

A very light World of Warcraft addon that shows ore and herb locations on the world map and
minimap. Built for **WoW Forever** (interface 16001).

It starts from an imported set of locations, then learns from what you actually gather. Nodes you
found yourself are trusted over the imported ones, and are drawn so you can tell them apart.

There is no settings window and no library dependency: one Lua file, a data file, and a few chat
commands.

> Early version (0.1.0), used on the WoW Forever release (build 1.60.1.70888). Expect some rough
> edges. Bug reports are welcome.

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

| Command | What it does |
| --- | --- |
| `/sl` | Shows the counts and whether ores and herbs are shown |
| `/sl show ores` / `/sl hide ores` | Ore pins on the map and minimap |
| `/sl show herbs` / `/sl hide herbs` | Herb pins on the map and minimap |
| `/sl export` | Reminds you where your saved file is, for sharing your nodes |
| `/sl skill` | Prints the profession skill the addon detected (for troubleshooting) |

`/skiploading` works in place of `/sl`.

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
