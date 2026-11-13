# Contributing

Thanks for helping. There are two ways to contribute: the nodes you found, and code.

## Contributing the nodes you found

This is the most useful thing you can send. The imported locations are Classic-era positions;
nodes players actually gather on Forever are the only verified data there is.

1. Play with the addon and gather as usual.
2. Log out, or type `/reload`, so your data is written to disk.
3. Find the file `World of Warcraft\_forever_\WTF\Account\<your account>\SavedVariables\SkipLoading.lua`.
4. Open an issue titled "Nodes from <a name to credit you by>" and attach the file. GitHub only
   accepts some file types, so zip it first or rename it to `SkipLoading.txt`.

What is in that file: the node locations (imported and found), when you found them, the game build,
and your show/hide settings. It holds no character names, account names or anything else about
you. The account folder name is part of the file's path on your computer, not its contents, so
please send only the file itself.

What happens to it: only the nodes you found yourself are taken, gathered or spotted on the
minimap. They are merged with everyone
else's into `Shared.lua`, which ships with the addon and shows up as silver-ringed pins. Sending a
newer file later replaces your earlier one, so nothing is counted twice.

By sending a file you agree that the locations in it can be published in this repository under the
project's licence, and that you can be listed in [CREDITS.md](CREDITS.md) under the name you gave.
Say so if you would prefer not to be listed.

## Reporting a problem

Open an issue and include:

- What you did, what you expected, and what happened instead.
- The game build (shown on the login screen) and the addon version (in `SkipLoading.toc`).
- Any Lua error text. Turn errors on with `/console scriptErrors 1`.
- For a wrong skill colour or "you don't have it" message: the output of `/sl skill`.
- For a wrong skill requirement: the node, the zone, and the skill the game says it needs.

## Contributing code

The addon is meant to stay very small. Before adding a feature, open an issue to talk about it.
Changes that add a settings window or a library dependency are likely to be declined. A new kind of
thing to show is welcome as its own file in `Kinds` (see below), but talk about it first too.

Layout:

| File | Purpose |
| --- | --- |
| `SkipLoading.lua` | The core: dataset, pins, map, minimap, recording, sharing, commands |
| `Kinds/Gathering.lua` | What the gathering kinds share: skill colours, detection by gathering spell |
| `Kinds/Ores.lua`, `Kinds/Herbs.lua` | One definition per kind: names, icons, skill needed, spells |
| `SkipLoading.toc` | Addon manifest |
| `Seed.lua` | Generated. The imported locations. Do not edit by hand. |
| `Shared.lua` | Generated. Nodes found by other players. Do not edit by hand. |
| `tools/build-seed.js` | Regenerates `Seed.lua` from GatherMate2_Data |
| `tools/merge-found.js` | Rebuilds `Shared.lua` from the files in `tools/contrib` |

Guidelines:

- Keep it light. No work every frame that can be done once a second, and nothing running while
  every kind is hidden.
- The saved dataset is players' data. A change to its format must keep reading existing datasets.
- Never write to another addon's files. The tools only read GatherMate2_Data.
- Test in the game before opening a pull request: log in fresh, gather a node, hover a tracking
  blip on the minimap, check the world map and the minimap, and `/reload` to check the data
  survives.
- Say in the pull request what you tested and on which game build.

### Adding a kind of thing

The core knows nothing about ores or herbs. Each kind is one file in `Kinds` that calls
`ns.RegisterKind` (or `ns.GatheringKind` for a gathering profession), listed in `SkipLoading.toc`
after `SkipLoading.lua`. The fields are described at the top of the "kinds" section of
`SkipLoading.lua`. In short: a `key` (its table in the saved data, never renamed later), the
`words` `/sl show` accepts, the `nodes` it knows with their names and icons, and how it is
detected: `spells` whose cast target is the thing's name, or `events` handlers that call
`ns.Record(key, name)`. A `Tooltip` function is optional. Set `blips = true` if a tracking ability
shows the things on the minimap with their name as the tooltip, so they can be spotted there
(gathering kinds have it on already).

Pins, the minimap, sharing, `/sl` and `tools/merge-found.js` pick a new kind up without changes.

`tools/contrib/` is ignored by git on purpose: it holds other players' raw files and should never
be committed.
