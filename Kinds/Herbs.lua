-- Herbalism nodes. Ids match GatherMate2. Skill needed: Classic values; Forever may have changed some.
local _, ns = ...

ns.GatheringKind({
  key = "herbs",
  words = { "herb", "herbalism" },
  skill = "Herbalism", skillSpell = 9134, skillLine = 182,
  skillNames = { "Herb Gathering" },
  spells = { 2366, 2368, 3570, 11993 },
  fallbackIcon = "Interface\\Icons\\INV_Misc_Flower_02",
  nodes = {
    -- id = { name, icon item, skill needed }
    [401] = { "Peacebloom", 2447, 1 },            [402] = { "Silverleaf", 765, 1 },
    [403] = { "Earthroot", 2449, 15 },            [404] = { "Mageroyal", 785, 50 },
    [405] = { "Briarthorn", 2450, 70 },           [407] = { "Stranglekelp", 3820, 85 },
    [408] = { "Bruiseweed", 2453, 100 },          [409] = { "Wild Steelbloom", 3355, 115 },
    [410] = { "Grave Moss", 3369, 120 },          [411] = { "Kingsblood", 3356, 125 },
    [412] = { "Liferoot", 3357, 150 },            [413] = { "Fadeleaf", 3818, 160 },
    [414] = { "Goldthorn", 3821, 170 },           [415] = { "Khadgar's Whisker", 3358, 185 },
    [416] = { "Wintersbite", 3819, 195 },         [417] = { "Firebloom", 4625, 205 },
    [418] = { "Purple Lotus", 8831, 210 },        [420] = { "Arthas' Tears", 8836, 220 },
    [421] = { "Sungrass", 8838, 230 },            [422] = { "Blindweed", 8839, 235 },
    [423] = { "Ghost Mushroom", 8845, 245 },      [424] = { "Gromsblood", 8846, 250 },
    [425] = { "Golden Sansam", 13464, 260 },      [426] = { "Dreamfoil", 13463, 270 },
    [427] = { "Mountain Silversage", 13465, 280 }, [428] = { "Plaguebloom", 13466, 285 },
    [429] = { "Icecap", 13467, 290 },             [431] = { "Black Lotus", 13468, 300 },
  },
})
