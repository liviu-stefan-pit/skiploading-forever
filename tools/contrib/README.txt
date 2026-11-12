Put the SkipLoading.lua files other players send you in this folder, one per player,
renamed so they don't overwrite each other (anna.lua, bob.lua ...).

They find the file, after logging out, at:
  WTF\Account\<their account>\SavedVariables\SkipLoading.lua

Then run, from the tools folder:
  node merge-found.js

That rebuilds Shared.lua in the addon folder. Don't ship this contrib folder with the addon.
