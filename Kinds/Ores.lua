-- Mining nodes. Ids match GatherMate2. Skill needed: Classic values; Forever may have changed some.
local _, ns = ...

ns.GatheringKind({
  key = "ores",
  words = { "ore", "mining" },
  skill = "Mining", skillSpell = 2575, skillLine = 186,
  spells = { 2575, 2576, 3564, 10248 },
  track = 2580, -- Find Minerals
  fallbackIcon = "Interface\\Icons\\Trade_Mining",
  nodes = {
    -- id = { name, icon item, skill needed }
    [201] = { "Copper Vein", 2770, 1 },                      [202] = { "Tin Vein", 2771, 65 },
    [203] = { "Iron Deposit", 2772, 125 },                   [204] = { "Silver Vein", 2775, 75 },
    [205] = { "Gold Vein", 2776, 155 },                      [206] = { "Mithril Deposit", 3858, 175 },
    [207] = { "Ooze Covered Mithril Deposit", 3858, 175 },   [208] = { "Truesilver Deposit", 7911, 230 },
    [209] = { "Ooze Covered Silver Vein", 2775, 75 },        [210] = { "Ooze Covered Gold Vein", 2776, 155 },
    [211] = { "Ooze Covered Truesilver Deposit", 7911, 230 }, [212] = { "Ooze Covered Rich Thorium Vein", 10620, 275 },
    [213] = { "Ooze Covered Thorium Vein", 10620, 245 },     [214] = { "Small Thorium Vein", 10620, 245 },
    [215] = { "Rich Thorium Vein", 10620, 275 },             [216] = { "Hakkari Thorium Vein", 10620, 275 },
    [217] = { "Dark Iron Deposit", 11370, 230 },             [218] = { "Lesser Bloodstone Deposit", 4278, 75 },
    [219] = { "Incendicite Mineral Vein", 3340, 65 },        [220] = { "Indurium Mineral Vein", 5833, 150 },
  },
})
