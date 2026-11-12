-- Skip Loading: ore and herb locations on the world map and minimap.
--
-- SkipLoadingForeverDataSet (saved variable) is the working dataset:
--   DS.ores / DS.herbs = { [uiMapID] = { [coord] = node } }
--   coord = x * 1000000 + y * 100 + slot, x and y in 0.01% of the map
--   node  = a number: a node id imported from the seed, never seen by you
--         = a table:  { id, seen, first, last, build, gap }, a node you gathered yourself
--           (gap = shortest time in seconds between two sightings)
--         = a table with shared = true: a node other players found, merged in from Shared.lua
-- A node you gather replaces the imported points of the same type around it.
local ADDON = ...

local floor, sin, cos, pairs, type, time = math.floor, math.sin, math.cos, pairs, type, time

local SAME_NODE = 15      -- yards: a gather this close to one of your own nodes is that node again
local ABSORB = 25         -- yards: the nearest imported point of the same type this close to your node is dropped
local RECOUNT = 300       -- seconds before the same node counts as seen again (a node takes several hits)
local DEPLETED = 300      -- seconds a node you just gathered is drawn greyed out
local TICK = 0.05         -- seconds between minimap position updates
local MAP_MINE, MAP_SEED = 18, 13          -- world map pin sizes: your nodes, imported nodes
local MINIMAP_MINE, MINIMAP_SEED = 15, 12 -- minimap pin sizes
local RESCAN = 1          -- seconds between searches for the nodes around you

local BUILD = tonumber((select(2, GetBuildInfo()))) or 0

-- node id -> { name, item id used for the icon }; ids match GatherMate2
local NODES = {
  [201] = { "Copper Vein", 2770 },                   [202] = { "Tin Vein", 2771 },
  [203] = { "Iron Deposit", 2772 },                  [204] = { "Silver Vein", 2775 },
  [205] = { "Gold Vein", 2776 },                     [206] = { "Mithril Deposit", 3858 },
  [207] = { "Ooze Covered Mithril Deposit", 3858 },  [208] = { "Truesilver Deposit", 7911 },
  [209] = { "Ooze Covered Silver Vein", 2775 },      [210] = { "Ooze Covered Gold Vein", 2776 },
  [211] = { "Ooze Covered Truesilver Deposit", 7911 }, [212] = { "Ooze Covered Rich Thorium Vein", 10620 },
  [213] = { "Ooze Covered Thorium Vein", 10620 },    [214] = { "Small Thorium Vein", 10620 },
  [215] = { "Rich Thorium Vein", 10620 },            [216] = { "Hakkari Thorium Vein", 10620 },
  [217] = { "Dark Iron Deposit", 11370 },            [218] = { "Lesser Bloodstone Deposit", 4278 },
  [219] = { "Incendicite Mineral Vein", 3340 },      [220] = { "Indurium Mineral Vein", 5833 },

  [401] = { "Peacebloom", 2447 },        [402] = { "Silverleaf", 765 },
  [403] = { "Earthroot", 2449 },         [404] = { "Mageroyal", 785 },
  [405] = { "Briarthorn", 2450 },        [407] = { "Stranglekelp", 3820 },
  [408] = { "Bruiseweed", 2453 },        [409] = { "Wild Steelbloom", 3355 },
  [410] = { "Grave Moss", 3369 },        [411] = { "Kingsblood", 3356 },
  [412] = { "Liferoot", 3357 },          [413] = { "Fadeleaf", 3818 },
  [414] = { "Goldthorn", 3821 },         [415] = { "Khadgar's Whisker", 3358 },
  [416] = { "Wintersbite", 3819 },       [417] = { "Firebloom", 4625 },
  [418] = { "Purple Lotus", 8831 },      [420] = { "Arthas' Tears", 8836 },
  [421] = { "Sungrass", 8838 },          [422] = { "Blindweed", 8839 },
  [423] = { "Ghost Mushroom", 8845 },    [424] = { "Gromsblood", 8846 },
  [425] = { "Golden Sansam", 13464 },    [426] = { "Dreamfoil", 13463 },
  [427] = { "Mountain Silversage", 13465 }, [428] = { "Plaguebloom", 13466 },
  [429] = { "Icecap", 13467 },           [431] = { "Black Lotus", 13468 },
}
-- node id -> skill needed (Classic values; Forever may have changed some)
local REQ = {
  [201] = 1, [202] = 65, [203] = 125, [204] = 75, [205] = 155, [206] = 175, [207] = 175, [208] = 230,
  [209] = 75, [210] = 155, [211] = 230, [212] = 275, [213] = 245, [214] = 245, [215] = 275, [216] = 275,
  [217] = 230, [218] = 75, [219] = 65, [220] = 150,
  [401] = 1, [402] = 1, [403] = 15, [404] = 50, [405] = 70, [407] = 85, [408] = 100, [409] = 115,
  [410] = 120, [411] = 125, [412] = 150, [413] = 160, [414] = 170, [415] = 185, [416] = 195, [417] = 205,
  [418] = 210, [420] = 220, [421] = 230, [422] = 235, [423] = 245, [424] = 250, [425] = 260, [426] = 270,
  [427] = 280, [428] = 285, [429] = 290, [431] = 300,
}
local FALLBACK_ICON ={ ores = "Interface\\Icons\\Trade_Mining", herbs = "Interface\\Icons\\INV_Misc_Flower_02" }
local GATHER_SPELLS = {
  [2575] = "ores", [2576] = "ores", [3564] = "ores", [10248] = "ores",
  [2366] = "herbs", [2368] = "herbs", [3570] = "herbs", [11993] = "herbs",
}

local NAME_TO_ID = { ores = {}, herbs = {} }
for id, n in pairs(NODES) do NAME_TO_ID[id < 400 and "ores" or "herbs"][n[1]:lower()] = id end

local DS, cfg
local function say(msg) print("|cff66ccffSkip Loading:|r " .. msg) end

---------------------------------------------------------------- helpers
local function SpellName(id)
  if C_Spell and C_Spell.GetSpellName then return C_Spell.GetSpellName(id) end
  if GetSpellInfo then return (GetSpellInfo(id)) end
end
local MINING, HERBING = SpellName(2575), SpellName(2366)

local function SpellKind(id)
  if not id then return end
  if GATHER_SPELLS[id] then return GATHER_SPELLS[id] end
  local name = SpellName(id)
  if name and name == MINING then return "ores" end
  if name and name == HERBING then return "herbs" end
end

local function NodeName(id)
  local n = NODES[id]
  return n and n[1] or tostring(id)
end

-- your current skill (with racial and gear bonuses), or nil if you don't have the profession
local SKILL_NAME = { ores = MINING or "Mining", herbs = SpellName(9134) or "Herbalism" }
local SKILL_LINE = { ores = 186, herbs = 182 }
local SKILL_NAMES = {
  ores = { [SKILL_NAME.ores] = true, Mining = true },
  herbs = { [SKILL_NAME.herbs] = true, Herbalism = true, [HERBING or "Herb Gathering"] = true },
}
-- the client offers this in different ways depending on its version, so try each; returns skill, source
local function PlayerSkill(kind)
  local line = SKILL_LINE[kind]
  if C_SkillInfo and C_SkillInfo.GetSkillLineInfoByID then
    local ok, info = pcall(C_SkillInfo.GetSkillLineInfoByID, line)
    if ok and type(info) == "table" and info.rank then return info.rank + (info.modifier or 0), "C_SkillInfo" end
  end
  if C_TradeSkillUI and C_TradeSkillUI.GetProfessionInfoBySkillLineID then
    local ok, info = pcall(C_TradeSkillUI.GetProfessionInfoBySkillLineID, line)
    if ok and type(info) == "table" and (info.skillLevel or 0) > 0 then
      return info.skillLevel + (info.skillModifier or 0), "C_TradeSkillUI"
    end
  end
  if GetNumSkillLines and GetSkillLineInfo then
    for i = 1, GetNumSkillLines() do
      local name, isHeader, _, rank, _, modifier = GetSkillLineInfo(i)
      if not isHeader and SKILL_NAMES[kind][name] then return (rank or 0) + (modifier or 0), "skill list" end
    end
  end
end

-- the game's own difficulty colours: red can't, orange always skills up, yellow often, green rarely, grey never
local function Difficulty(req, skill)
  if not skill or skill < req then return 1, 0.13, 0.13 end
  if skill < req + 25 then return 1, 0.5, 0.25 end
  if skill < req + 50 then return 1, 1, 0 end
  if skill < req + 100 then return 0.25, 0.75, 0.25 end
  return 0.5, 0.5, 0.5
end

local function AddSkillLines(id, kind)
  local req, skill = REQ[id], PlayerSkill(kind)
  local r, g, b = 1, 0.82, 0
  if req then r, g, b = Difficulty(req, skill) end
  GameTooltip:AddLine(NodeName(id), r, g, b)
  if not req then return end
  if skill then
    GameTooltip:AddLine(("Needs %s %d (yours: %d)"):format(SKILL_NAME[kind], req, skill), r, g, b)
  else
    GameTooltip:AddLine(("Needs %s %d (you don't have it)"):format(SKILL_NAME[kind], req), r, g, b)
  end
end

local GetIcon =(C_Item and C_Item.GetItemIconByID) or GetItemIcon
local function NodeIcon(id, kind)
  local n = NODES[id]
  return (n and GetIcon and GetIcon(n[2])) or FALLBACK_ICON[kind]
end

-- "Wilted Peacebloom" is a Peacebloom: drop leading words until the name is a known node.
-- A node nobody knows yet is stored under its own name.
local function ResolveNode(kind, name)
  local names, l = NAME_TO_ID[kind], name:lower()
  while l do
    if names[l] then return names[l] end
    l = l:match("^%S+%s+(.+)$")
  end
  return name
end

local function Decode(coord)
  return floor(coord / 1e6) / 1e4, floor(coord % 1e6 / 100) / 1e4
end
local function Encode(x, y)
  return floor(x * 1e4 + 0.5) * 1e6 + floor(y * 1e4 + 0.5) * 100
end

-- width and height of a map in yards
local zoneSize = {}
local function ZoneSize(mapID)
  local s = zoneSize[mapID]
  if s == nil then
    s = false
    local _, a = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(0, 0))
    local _, b = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(0.5, 0.5))
    if a and b then
      local top, left = a:GetXY()
      local bottom, right = b:GetXY()
      local w, h = math.abs(left - right) * 2, math.abs(top - bottom) * 2
      if w > 0 and h > 0 then s = { w, h } end
    end
    zoneSize[mapID] = s
  end
  if s then return s[1], s[2] end
end

local function PlayerPos()
  local mapID = C_Map.GetBestMapForUnit("player")
  local pos = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
  if not pos then return end
  local x, y = pos:GetXY()
  if not x or (x == 0 and y == 0) then return end
  return mapID, x, y
end

local function Span(s)
  if s < 5400 then return floor(s / 60 + 0.5) .. " min" end
  if s < 129600 then return floor(s / 3600 + 0.5) .. " h" end
  return floor(s / 86400 + 0.5) .. " days"
end
local function Ago(t)
  local s = time() - t
  if s < 90 then return "just now" end
  return Span(s) .. " ago"
end

-- every node to draw on one map, as { x, y, kind, node }
local function BuildList(mapID)
  local list = {}
  for kind in pairs(NAME_TO_ID) do
    local zone = cfg[kind] and DS[kind][mapID]
    if zone then
      for coord, node in pairs(zone) do
        local x, y = Decode(coord)
        list[#list + 1] = { x = x, y = y, kind = kind, node = node }
      end
    end
  end
  return list
end

---------------------------------------------------------------- pins
local function PinEnter(self)
  local node = self.entry and self.entry.node
  if not node then return end
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  if type(node) == "table" then
    AddSkillLines(node.id, self.entry.kind)
    GameTooltip:AddLine(("%s %d time%s, last %s"):format(node.shared and "Found by other players" or "Seen",
      node.seen, node.seen == 1 and "" or "s", Ago(node.last)), 1, 1, 1)
    if node.gap and node.gap < 86400 then
      GameTooltip:AddLine("Back within " .. Span(node.gap) .. " at the fastest", 1, 1, 1)
    end
    if node.build ~= BUILD then
      GameTooltip:AddLine("Not seen since game build " .. node.build, 0.6, 0.6, 0.6)
    end
  else
    AddSkillLines(node, self.entry.kind)
    GameTooltip:AddLine("Imported, not seen by you yet", 0.6, 0.6, 0.6)
  end
  GameTooltip:Show()
end
local function PinLeave() GameTooltip:Hide() end

local function NewPin(parent)
  local pin = CreateFrame("Frame", nil, parent)
  pin.tex = pin:CreateTexture(nil, "ARTWORK")
  pin.tex:SetAllPoints()
  pin.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  local mask = pin:CreateMaskTexture()
  mask:SetAllPoints()
  mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
  pin.tex:AddMaskTexture(mask)
  -- ring: gold around nodes you found yourself, silver around nodes other players found
  pin.ring = pin:CreateTexture(nil, "BACKGROUND")
  pin.ring:SetPoint("TOPLEFT", -2, 2)
  pin.ring:SetPoint("BOTTOMRIGHT", 2, -2)
  pin.ring:SetColorTexture(1, 0.82, 0)
  local ringMask = pin:CreateMaskTexture()
  ringMask:SetAllPoints(pin.ring)
  ringMask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
  pin.ring:AddMaskTexture(ringMask)
  pin:SetScript("OnEnter", PinEnter)
  pin:SetScript("OnLeave", PinLeave)
  pin:EnableMouse(true)
  if pin.SetMouseClickEnabled then pin:SetMouseClickEnabled(false) end -- hover only, clicks go to the map
  return pin
end

-- your own nodes: bigger, solid, on top, gold ring; other players: the same with a silver ring;
-- imported ones: small and faint
local function StylePin(pin, entry, mineSize, seedSize, seedAlpha, level)
  local node = entry.node
  pin.entry = entry
  if type(node) == "table" then
    pin.tex:SetTexture(NodeIcon(node.id, entry.kind))
    pin.tex:SetDesaturated(not node.shared and time() - node.last < DEPLETED)
    if node.shared then pin.ring:SetColorTexture(0.8, 0.8, 0.85) else pin.ring:SetColorTexture(1, 0.82, 0) end
    pin.ring:Show()
    pin:SetSize(mineSize, mineSize)
    pin:SetAlpha(node.build == BUILD and 1 or 0.8)
    pin:SetFrameLevel(level + (node.shared and 1 or 2))
  else
    pin.tex:SetTexture(NodeIcon(node, entry.kind))
    pin.tex:SetDesaturated(false)
    pin.ring:Hide()
    pin:SetSize(seedSize, seedSize)
    pin:SetAlpha(seedAlpha)
    pin:SetFrameLevel(level)
  end
end

---------------------------------------------------------------- minimap
-- yards from the centre of the minimap to its edge, by zoom level
local RADIUS_OUT = { [0] = 233.33, 200, 166.67, 133.33, 100, 66.67 }
local RADIUS_IN = { [0] = 150, 120, 90, 60, 40, 25 }

local function MinimapRadius()
  local zoom = Minimap:GetZoom()
  local outZoom, inZoom = tonumber(GetCVar("minimapZoom")), tonumber(GetCVar("minimapInsideZoom"))
  local indoors
  if outZoom and inZoom and outZoom ~= inZoom then indoors = (zoom == inZoom) else indoors = IsIndoors() end
  return (indoors and RADIUS_IN or RADIUS_OUT)[zoom] or 233.33
end

local mm = { pins = {}, near = {}, list = {}, dirty = true, sinceScan = 0 }

local function HideMinimapPins()
  for i = 1, #mm.pins do mm.pins[i]:Hide() end
  mm.lastX = nil
end

local function UpdateMinimap(elapsed)
  local mapID, px, py = PlayerPos()
  local w, h
  if mapID then w, h = ZoneSize(mapID) end
  if not w then
    if mm.lastX then HideMinimapPins() end
    return
  end

  local radius = MinimapRadius()
  local rescan = mm.dirty or mapID ~= mm.mapID or radius ~= mm.radius
  if mm.dirty or mapID ~= mm.mapID then
    mm.list, mm.mapID, mm.dirty = BuildList(mapID), mapID, false
  end
  mm.sinceScan = mm.sinceScan + elapsed

  local near, pins = mm.near, mm.pins
  if rescan or mm.sinceScan >= RESCAN then
    mm.sinceScan, mm.radius = 0, radius
    local reach = (radius + 60) ^ 2 -- margin for the ground covered until the next scan
    local n, level = 0, Minimap:GetFrameLevel() + 5
    for i = 1, #mm.list do
      local e = mm.list[i]
      local dx, dy = (e.x - px) * w, (e.y - py) * h
      if dx * dx + dy * dy < reach then
        n = n + 1
        near[n] = e
        local pin = pins[n]
        if not pin then pin = NewPin(Minimap); pins[n] = pin end
        StylePin(pin, e, MINIMAP_MINE, MINIMAP_SEED, 0.5, level)
      end
    end
    for i = n + 1, #near do near[i] = nil end
    for i = n + 1, #pins do pins[i]:Hide() end
    mm.lastX = nil
  end

  local facing = GetCVar("rotateMinimap") == "1" and GetPlayerFacing() or 0
  local half = Minimap:GetWidth() / 2
  if px == mm.lastX and py == mm.lastY and facing == mm.lastFacing and half == mm.lastHalf then return end
  mm.lastX, mm.lastY, mm.lastFacing, mm.lastHalf = px, py, facing, half

  local s, c = sin(facing), cos(facing)
  local scale, edge = half / radius, (radius * 0.94) ^ 2
  for i = 1, #near do
    local e, pin = near[i], pins[i]
    local dx, dy = (e.x - px) * w, (py - e.y) * h -- yards east, yards north
    if dx * dx + dy * dy > edge then
      pin:Hide()
    else
      pin:SetPoint("CENTER", Minimap, "CENTER", (dx * c + dy * s) * scale, (dy * c - dx * s) * scale)
      pin:Show()
    end
  end
end

local driver = CreateFrame("Frame")
driver:Hide()
local acc = 0
driver:SetScript("OnUpdate", function(_, elapsed)
  acc = acc + elapsed
  if acc < TICK then return end
  UpdateMinimap(acc)
  acc = 0
end)

---------------------------------------------------------------- world map
local wm = { pins = {} }

local function UpdateWorldMap()
  if not WorldMapFrame or not WorldMapFrame:IsShown() then return end
  local canvas = WorldMapFrame:GetCanvas()
  local mapID = WorldMapFrame:GetMapID()
  local list = mapID and BuildList(mapID) or {}
  local pins = wm.pins

  if #list > 0 then
    local cw, ch = canvas:GetSize()
    -- the canvas is scaled to fit the window: size pins so they stay the same size on screen
    local unit = UIParent:GetEffectiveScale() / canvas:GetEffectiveScale()
    local ok, level = pcall(function()
      return WorldMapFrame:GetPinFrameLevelsManager():GetValidFrameLevel("PIN_FRAME_LEVEL_AREA_POI")
    end)
    if not ok or type(level) ~= "number" then level = canvas:GetFrameLevel() + 200 end
    for i = 1, #list do
      local e, pin = list[i], pins[i]
      if not pin then pin = NewPin(canvas); pins[i] = pin end
      StylePin(pin, e, MAP_MINE * unit, MAP_SEED * unit, 0.85, level)
      pin:SetPoint("CENTER", canvas, "TOPLEFT", e.x * cw, -e.y * ch)
      pin:Show()
    end
  end
  for i = #list + 1, #pins do
    pins[i].entry = nil
    pins[i]:Hide()
  end
end

local function HookWorldMap()
  if not WorldMapFrame or wm.hooked then return end
  wm.hooked = true
  WorldMapFrame:HookScript("OnShow", UpdateWorldMap)
  if WorldMapFrame.OnMapChanged then hooksecurefunc(WorldMapFrame, "OnMapChanged", UpdateWorldMap) end
  if WorldMapFrame.OnCanvasScaleChanged then hooksecurefunc(WorldMapFrame, "OnCanvasScaleChanged", UpdateWorldMap) end
end

local function Refresh()
  mm.dirty = true
  local on = cfg.ores or cfg.herbs
  if not on then HideMinimapPins() end
  driver:SetShown(on)
  UpdateWorldMap()
end

---------------------------------------------------------------- recording
-- nearest node of one type within `radius` yards of a spot: among the records (yours and other
-- players') or among the imported points. Returns its coord key.
local function Nearest(zone, id, x, y, w, h, records, radius)
  local best, bestDist = nil, radius ^ 2
  for coord, node in pairs(zone) do
    local match
    if records then match = type(node) == "table" and node.id == id else match = (node == id) end
    if match then
      local nx, ny = Decode(coord)
      local d = ((nx - x) * w) ^ 2 + ((ny - y) * h) ^ 2
      if d <= bestDist then best, bestDist = coord, d end
    end
  end
  return best
end

-- adds a record at a spot; it takes the place of the nearest imported point of the same type only,
-- since another one close by may be a real second node
local function AddRecord(zone, x, y, w, h, record)
  local old = Nearest(zone, record.id, x, y, w, h, false, ABSORB)
  if old then zone[old] = nil end
  local key = Encode(x, y)
  while zone[key] do key = key + 1 end
  zone[key] = record
end

local function Zone(kind, mapID)
  local zone = DS[kind][mapID]
  if not zone then zone = {}; DS[kind][mapID] = zone end
  local w, h = ZoneSize(mapID)
  if not w then w, h = 4000, 4000 end
  return zone, w, h
end

local function Record(kind, name)
  local mapID, x, y = PlayerPos()
  if not mapID then return end
  local id = ResolveNode(kind, name)
  local zone, w, h = Zone(kind, mapID)
  local now = time()

  local key = Nearest(zone, id, x, y, w, h, true, SAME_NODE)
  local mine = key and zone[key]
  if mine and mine.shared then
    -- someone else found it first; now you have seen it yourself, so it becomes yours
    mine.shared, mine.seen, mine.first, mine.last, mine.build, mine.gap = nil, 1, now, now, BUILD, nil
  elseif mine then
    local gap = now - mine.last
    if gap > RECOUNT then
      mine.seen = mine.seen + 1
      if not mine.gap or gap < mine.gap then mine.gap = gap end
    end
    mine.last, mine.build = now, BUILD
  else
    AddRecord(zone, x, y, w, h, { id = id, seen = 1, first = now, last = now, build = BUILD })
  end
  Refresh()
end

-- Shared.lua holds nodes other players found (built by tools/merge-found.js). Each new version of
-- it is merged into the dataset once. Your own nodes always win over it.
local function ApplyShared()
  local shared = SkipLoadingShared
  SkipLoadingShared = nil
  if type(shared) ~= "table" or not shared.stamp or shared.stamp == DS.sharedStamp then return end
  local added = 0
  for kind in pairs(NAME_TO_ID) do
    for mapID, nodes in pairs(shared[kind] or {}) do
      local zone, w, h = Zone(kind, mapID)
      for coord, s in pairs(nodes) do
        local x, y = Decode(coord)
        local key = Nearest(zone, s.id, x, y, w, h, true, SAME_NODE)
        local known = key and zone[key]
        if not known then
          AddRecord(zone, x, y, w, h, { id = s.id, seen = s.seen, last = s.last, build = s.build, shared = true })
          added = added + 1
        elseif known.shared then
          known.seen, known.last, known.build = s.seen, s.last, s.build
        end
      end
    end
  end
  DS.sharedStamp = shared.stamp
  if added > 0 then say(added .. " new locations found by other players were added.") end
end

---------------------------------------------------------------- commands
local function Count(kind)
  local mine, seed, shared = 0, 0, 0
  for _, zone in pairs(DS[kind]) do
    for _, node in pairs(zone) do
      if type(node) ~= "table" then seed = seed + 1
      elseif node.shared then shared = shared + 1
      else mine = mine + 1 end
    end
  end
  return mine, seed, shared
end

local KIND_WORDS = { ores = "ores", ore = "ores", mining = "ores", herbs = "herbs", herb = "herbs" }

SLASH_SKIPLOADING1, SLASH_SKIPLOADING2 = "/sl", "/skiploading"
SlashCmdList.SKIPLOADING = function(msg)
  local verb, what = (msg or ""):lower():match("^%s*(%S*)%s*(%S*)")
  if verb == "show" or verb == "hide" then
    local kind = KIND_WORDS[what]
    if what ~= "" and what ~= "all" and not kind then
      say("I know |cffffffffores|r and |cffffffffherbs|r, not '" .. what .. "'.")
      return
    end
    for k in pairs(NAME_TO_ID) do
      if not kind or kind == k then
        cfg[k] = (verb == "show")
        say(k .. (cfg[k] and " shown." or " hidden."))
      end
    end
    Refresh()
    return
  end
  if verb == "export" then
    say("to share the nodes you found: log out (or /reload) so they are saved, then send this file:")
    say("|cffffffffWTF\\Account\\<your account>\\SavedVariables\\SkipLoading.lua|r")
    return
  end
  if verb == "skill" then
    for _, k in ipairs({ "ores", "herbs" }) do
      local skill, how = PlayerSkill(k)
      say(SKILL_NAME[k] .. ": " .. (skill and (skill .. " (read from " .. how .. ")") or "not found"))
    end
    local n = GetNumSkillLines and GetNumSkillLines()
    say("skill list entries: " .. tostring(n))
    for i = 1, n or 0 do
      local name, isHeader, isExpanded, rank = GetSkillLineInfo(i)
      say(("  %s%s %s"):format(tostring(name), isHeader and (isExpanded and " [header]" or " [header, collapsed]") or "", isHeader and "" or tostring(rank)))
    end
    return
  end
  for _, k in ipairs({ "ores", "herbs" }) do
    local mine, seed, shared = Count(k)
    say(("%s %s: %d found by you, %d by other players, %d imported"):format(k,
      cfg[k] and "|cff00ff00shown|r" or "|cffff5555hidden|r", mine, shared, seed))
  end
  say("/sl show ores  |  /sl hide ores  |  /sl show herbs  |  /sl hide herbs  |  /sl export")
end

---------------------------------------------------------------- events
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("UNIT_SPELLCAST_SENT")
events:SetScript("OnEvent", function(_, event, a1, a2, _, a4)
  if event == "ADDON_LOADED" then
    if a1 ~= ADDON then
      if cfg then HookWorldMap() end -- in case the world map loads after us
      return
    end
    SkipLoadingDB = SkipLoadingDB or {}
    cfg = SkipLoadingDB
    if cfg.ores == nil then cfg.ores = true end
    if cfg.herbs == nil then cfg.herbs = true end
    local imported = type(SkipLoadingForeverDataSet) ~= "table"
    if imported then SkipLoadingForeverDataSet = SkipLoadingSeed() end
    SkipLoadingSeed = nil
    DS = SkipLoadingForeverDataSet
    DS.ores, DS.herbs = DS.ores or {}, DS.herbs or {}
    if imported then
      local _, ores = Count("ores")
      local _, herbs = Count("herbs")
      say(("created SkipLoadingForeverDataSet with %d ore and %d herb locations. Type /sl for options."):format(ores, herbs))
    end
  elseif event == "PLAYER_LOGIN" then
    ApplyShared()
    HookWorldMap()
    Refresh()
  elseif event == "UNIT_SPELLCAST_SENT" then
    -- (unit, target, castGUID, spellID): for a gathering cast the target is the node's name
    if a1 == "player" and DS and type(a2) == "string" and a2 ~= "" then
      local kind = SpellKind(a4)
      if kind then Record(kind, a2) end
    end
  end
end)
