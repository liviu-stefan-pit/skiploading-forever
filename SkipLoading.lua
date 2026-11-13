-- Skip Loading: things in the world (ores, herbs ...) on the world map and minimap.
--
-- This file is the core: dataset, pins, map, minimap, recording, sharing and commands. It knows
-- nothing about any particular kind of thing. Each kind is a short definition in Kinds\ that calls
-- ns.RegisterKind (see "kinds" below for what a definition holds).
--
-- SkipLoadingForeverDataSet (saved variable) is the working dataset:
--   DS[key] = { [uiMapID] = { [coord] = node } }, key = a kind's key ("ores", "herbs" ...)
--   coord = x * 1000000 + y * 100 + slot, x and y in 0.01% of the map
--   node  = a number: a node id imported from the seed, never seen by you
--         = a table:  { id, seen, first, last, build, gap }, a node you recorded yourself
--           (gap = shortest time in seconds between two sightings)
--         = a table with shared = true: a node other players found, merged in from Shared.lua
-- A node you record replaces the imported points of the same type around it.
-- SkipLoadingDB (saved variable) holds settings, shared by all characters:
--   [key]    = true when a kind is shown
--   pick     = { [key] = { [id] = true } }: a shown kind draws only these types; no entry = all of them
--   skillups = nil, "on" or "strict": draw only nodes that can raise your skill (see "filters")
local ADDON, ns = ...

local floor, sin, cos, huge, pairs, ipairs, type, time = math.floor, math.sin, math.cos, math.huge, pairs, ipairs, type, time

local SAME_NODE = 15      -- yards: a record this close to one of your own nodes is that node again
local ABSORB = 25         -- yards: the nearest imported point of the same type this close to your node is dropped
local RECOUNT = 300       -- seconds before the same node counts as seen again (a node takes several hits)
local DEPLETED = 300      -- seconds a node you just recorded is drawn greyed out
local TICK = 0.05         -- seconds between minimap position updates while something is moving
local IDLE_TICK = 0.25    -- the same once nothing has moved for a second
local SETTINGS = 0.5      -- seconds between re-reads of the minimap's zoom, size and rotation setting
local MAP_MINE, MAP_SEED = 18, 13          -- world map pin sizes: your nodes, imported nodes
local MINIMAP_MINE, MINIMAP_SEED = 15, 12 -- minimap pin sizes
local DRIFT = 40          -- yards you can move before the nodes around you are searched for again
local MARGIN = 60         -- yards past the minimap's edge that a search covers; must be more than DRIFT

local BUILD = tonumber((select(2, GetBuildInfo()))) or 0

local DS, cfg
local function say(msg) print("|cff66ccffSkip Loading:|r " .. msg) end
ns.say = say

local function SpellName(id)
  if C_Spell and C_Spell.GetSpellName then return C_Spell.GetSpellName(id) end
  if GetSpellInfo then return (GetSpellInfo(id)) end
end
ns.SpellName = SpellName

---------------------------------------------------------------- kinds
-- A kind is one sort of thing the addon shows. Its definition, the table given to ns.RegisterKind:
--   key           its table in the dataset and its show/hide setting, e.g. "ores". Never rename it:
--                 saved data and Shared.lua files are stored under it.
--   words         what /sl show and /sl hide accept for it besides the key, e.g. { "ore", "mining" }
--   nodes         { [id] = { name, icon, ... } }: icon is an item id or a texture; the fields after
--                 those two are the kind's own (the gathering kinds keep the skill needed there)
--   fallbackIcon  texture for a thing whose id is not in `nodes`, or whose item icon is not loaded
--   shown         optional: false to start hidden for new users (default shown)
--   spells        optional: spell ids whose cast target is the name of a thing of this kind
--   spellNames    optional: spell names that count the same, for ranks the ids above miss
--   Tooltip       optional: function(def, id) adding the first tooltip lines; default is the name
--   Useful        optional: function(def, strict) for the skill-up filter, returning a function(id)
--                 that says whether a thing of that type is worth showing now (strict = only the
--                 ones that pay off often), and a short note on why, e.g. "Mining 140". Called once
--                 each time the pins are rebuilt. Kinds without it are not touched by the filter.
--   events       optional: { EVENT = function(def, ...) } for kinds detected some other way;
--                 they call ns.Record(def.key, name) to record a thing where the player stands
-- Kinds register while the addon's files load, before ADDON_LOADED, and draw in that order.
local KINDS, BY_KEY, BY_WORD = {}, {}, {}
local SPELL_IDS, SPELL_NAMES = {}, {}
-- other fields of the dataset and of the settings
local RESERVED = { version = true, source = true, sharedStamp = true, pick = true, skillups = true }
ns.kinds = KINDS

function ns.RegisterKind(def)
  local key = def.key
  assert(type(key) == "string" and not RESERVED[key] and not BY_KEY[key],
    "Skip Loading: kind key missing, reserved or used twice: " .. tostring(key))
  assert(type(def.nodes) == "table", "Skip Loading: kind " .. key .. " has no nodes table")
  -- name -> id, for turning what the game calls a thing into its id
  def.byName = {}
  for id, n in pairs(def.nodes) do def.byName[n[1]:lower()] = id end
  for _, word in ipairs({ key, unpack(def.words or {}) }) do
    assert(not BY_WORD[word] or BY_WORD[word] == def, "Skip Loading: word '" .. word .. "' used by two kinds")
    BY_WORD[word] = def
  end
  for _, id in ipairs(def.spells or {}) do SPELL_IDS[id] = def end
  for _, name in pairs(def.spellNames or {}) do SPELL_NAMES[name] = def end
  KINDS[#KINDS + 1], BY_KEY[key] = def, def
  return def
end

-- extra /sl verbs from kind files: run(rest of the line); help is shown under /sl when given
local COMMANDS, COMMAND_HELP = {}, {}
function ns.RegisterCommand(verb, run, help)
  COMMANDS[verb] = run
  if help then COMMAND_HELP[#COMMAND_HELP + 1] = help end
end

---------------------------------------------------------------- helpers
-- asked for every spell you cast, so the answer is kept per spell id (false = no kind's spell)
local spellKind = {}
local function SpellKind(id)
  if not id then return end
  local def = spellKind[id]
  if def == nil then
    def = SPELL_IDS[id] or false
    local name = not def and SpellName(id)
    if name then def = SPELL_NAMES[name] or false end
    if def or name then spellKind[id] = def end
  end
  return def or nil
end

local function NodeName(def, id)
  local n = def.nodes[id]
  return n and n[1] or tostring(id)
end

local GetIcon = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
local function NodeIcon(def, id)
  local n = def.nodes[id]
  local icon = n and n[2]
  if type(icon) == "number" then icon = GetIcon and GetIcon(icon) end
  return icon or def.fallbackIcon
end

local function DefaultTooltip(def, id)
  GameTooltip:AddLine(NodeName(def, id), 1, 0.82, 0)
end

-- "Wilted Peacebloom" is a Peacebloom: drop leading words until the name is a known node.
-- A node nobody knows yet is stored under its own name.
local function ResolveNode(def, name)
  local names, l = def.byName, name:lower()
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

-- every node to draw on one map, after the filters, as { x, y, def, node }
local function BuildList(mapID)
  local list = {}
  for _, def in ipairs(KINDS) do
    local zone = cfg[def.key] and DS[def.key][mapID]
    if zone then
      local pick = cfg.pick[def.key]
      local useful = cfg.skillups and def.Useful and def.Useful(def, cfg.skillups == "strict")
      for coord, node in pairs(zone) do
        local id = type(node) == "table" and node.id or node
        if (not pick or pick[id]) and (not useful or useful(id)) then
          local x, y = Decode(coord)
          list[#list + 1] = { x = x, y = y, def = def, node = node }
        end
      end
    end
  end
  return list
end

local function AnyShown()
  for _, def in ipairs(KINDS) do
    if cfg[def.key] then return true end
  end
  return false
end

---------------------------------------------------------------- pins
local function PinEnter(self)
  local entry = self.entry
  local node = entry and entry.node
  if not node then return end
  local def = entry.def
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  local tooltip = def.Tooltip or DefaultTooltip
  if type(node) == "table" then
    tooltip(def, node.id)
    GameTooltip:AddLine(("%s %d time%s, last %s"):format(node.shared and "Found by other players" or "Seen",
      node.seen, node.seen == 1 and "" or "s", Ago(node.last)), 1, 1, 1)
    if node.gap and node.gap < 86400 then
      GameTooltip:AddLine("Back within " .. Span(node.gap) .. " at the fastest", 1, 1, 1)
    end
    if node.build ~= BUILD then
      GameTooltip:AddLine("Not seen since game build " .. node.build, 0.6, 0.6, 0.6)
    end
  else
    tooltip(def, node)
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
    pin.tex:SetTexture(NodeIcon(entry.def, node.id))
    pin.tex:SetDesaturated(not node.shared and time() - node.last < DEPLETED)
    if node.shared then pin.ring:SetColorTexture(0.8, 0.8, 0.85) else pin.ring:SetColorTexture(1, 0.82, 0) end
    pin.ring:Show()
    pin:SetSize(mineSize, mineSize)
    pin:SetAlpha(node.build == BUILD and 1 or 0.8)
    pin:SetFrameLevel(level + (node.shared and 1 or 2))
  else
    pin.tex:SetTexture(NodeIcon(entry.def, node))
    pin.tex:SetDesaturated(false)
    pin.ring:Hide()
    pin:SetSize(seedSize, seedSize)
    pin:SetAlpha(seedAlpha)
    pin:SetFrameLevel(level)
  end
end

-- when the soonest greyed-out node gets its colour back: `soonest`, or this node's time if earlier
local function GreyUntil(node, now, soonest)
  if type(node) == "table" and not node.shared then
    local t = node.last + DEPLETED
    if t > now and t < soonest then return t end
  end
  return soonest
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

local mm = { pins = {}, near = {}, list = {}, dirty = true, settings = 0, expire = huge }

local function HideMinimapPins()
  for i = 1, #mm.pins do mm.pins[i]:Hide() end
  mm.lastX = nil
end

-- returns true if anything was redrawn
local function UpdateMinimap(elapsed)
  local mapID, px, py = PlayerPos()
  local w, h
  if mapID then w, h = ZoneSize(mapID) end
  if not w then
    if mm.lastX then HideMinimapPins() end
    return
  end

  -- these rarely change: read them now and then, and at once when the minimap is zoomed
  mm.settings = mm.settings - elapsed
  if mm.settings <= 0 then
    mm.settings = SETTINGS
    mm.zoomRadius, mm.rotate, mm.half = MinimapRadius(), GetCVar("rotateMinimap") == "1", Minimap:GetWidth() / 2
  end
  local radius, now = mm.zoomRadius, time()

  if mm.dirty or mapID ~= mm.mapID then
    mm.list, mm.mapID, mm.dirty = BuildList(mapID), mapID, false
    mm.scanX = nil
  end

  -- search for the nodes around you only after you moved, zoomed, or a greyed-out node is due back
  local near, pins = mm.near, mm.pins
  local restyle = now >= mm.expire
  if not mm.scanX or restyle or radius ~= mm.radius
    or ((px - mm.scanX) * w) ^ 2 + ((py - mm.scanY) * h) ^ 2 > DRIFT * DRIFT then
    mm.scanX, mm.scanY, mm.radius = px, py, radius
    local reach = (radius + MARGIN) ^ 2
    local list, n, level, expire = mm.list, 0, Minimap:GetFrameLevel() + 5, huge
    for i = 1, #list do
      local e = list[i]
      local dx, dy = (e.x - px) * w, (e.y - py) * h
      if dx * dx + dy * dy < reach then
        n = n + 1
        near[n] = e
        local pin = pins[n]
        if not pin then pin = NewPin(Minimap); pins[n] = pin end
        if restyle or pin.entry ~= e then StylePin(pin, e, MINIMAP_MINE, MINIMAP_SEED, 0.5, level) end
        expire = GreyUntil(e.node, now, expire)
      end
    end
    for i = n + 1, #near do near[i] = nil end
    for i = n + 1, #pins do pins[i]:Hide() end
    mm.expire = expire
    mm.lastX = nil
  end

  local facing = mm.rotate and GetPlayerFacing() or 0
  local half = mm.half
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
  return true
end

-- updates run every TICK while something changes, and every IDLE_TICK once nothing has for a second
local driver = CreateFrame("Frame")
driver:Hide()
local acc, interval, still = 0, TICK, 0
driver:SetScript("OnUpdate", function(_, elapsed)
  acc = acc + elapsed
  if acc < interval then return end
  if UpdateMinimap(acc) then
    interval, still = TICK, 0
  else
    still = still + acc
    if still >= 1 then interval = IDLE_TICK end
  end
  acc = 0
end)

-- back to full speed at once: you started moving or turning, or the minimap was zoomed
local function Wake()
  mm.settings, interval, still = 0, TICK, 0
end
hooksecurefunc(Minimap, "SetZoom", Wake)

---------------------------------------------------------------- world map
local wm = { pins = {}, shown = 0, dirty = true, expire = huge }

local function UpdateWorldMap()
  if not WorldMapFrame or not WorldMapFrame:IsShown() then return end
  local canvas = WorldMapFrame:GetCanvas()
  local mapID = WorldMapFrame:GetMapID()
  local cw, ch = canvas:GetSize()
  -- the canvas is scaled to fit the window: size pins so they stay the same size on screen
  local unit = UIParent:GetEffectiveScale() / canvas:GetEffectiveScale()
  local pins, now = wm.pins, time()

  -- same map and same nodes as last time: at most the zoom changed, so only the pin sizes need it
  if not wm.dirty and mapID == wm.mapID and cw == wm.cw and ch == wm.ch and now < wm.expire then
    if unit ~= wm.unit then
      wm.unit = unit
      local mine, seed = MAP_MINE * unit, MAP_SEED * unit
      for i = 1, wm.shown do
        local size = type(pins[i].entry.node) == "table" and mine or seed
        pins[i]:SetSize(size, size)
      end
    end
    return
  end

  local list = {}
  if mapID then list = (mapID == mm.mapID and not mm.dirty) and mm.list or BuildList(mapID) end
  local expire = huge
  if #list > 0 then
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
      expire = GreyUntil(e.node, now, expire)
    end
  end
  for i = #list + 1, #pins do
    pins[i].entry = nil
    pins[i]:Hide()
  end
  wm.mapID, wm.cw, wm.ch, wm.unit, wm.shown, wm.expire, wm.dirty = mapID, cw, ch, unit, #list, expire, false
end

local function HookWorldMap()
  if not WorldMapFrame or wm.hooked then return end
  wm.hooked = true
  WorldMapFrame:HookScript("OnShow", UpdateWorldMap)
  if WorldMapFrame.OnMapChanged then hooksecurefunc(WorldMapFrame, "OnMapChanged", UpdateWorldMap) end
  if WorldMapFrame.OnCanvasScaleChanged then hooksecurefunc(WorldMapFrame, "OnCanvasScaleChanged", UpdateWorldMap) end
end

local function Refresh()
  mm.dirty, wm.dirty = true, true
  Wake()
  local on = AnyShown()
  if not on then HideMinimapPins() end
  driver:SetShown(on)
  UpdateWorldMap()
end

-- for kinds whose Useful answer just changed (your skill went up): redraw if the filter is on
function ns.UsefulChanged()
  if cfg and cfg.skillups then Refresh() end
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

local function Zone(def, mapID)
  local zone = DS[def.key][mapID]
  if not zone then zone = {}; DS[def.key][mapID] = zone end
  local w, h = ZoneSize(mapID)
  if not w then w, h = 4000, 4000 end
  return zone, w, h
end

local function Record(def, name)
  local mapID, x, y = PlayerPos()
  if not mapID then return end
  local id = ResolveNode(def, name)
  local zone, w, h = Zone(def, mapID)
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

-- for kinds detected by their own events: records the thing called `name` where you stand
function ns.Record(key, name)
  local def = BY_KEY[key]
  if def and DS and type(name) == "string" and name ~= "" then Record(def, name) end
end

-- Shared.lua holds nodes other players found (built by tools/merge-found.js). Each new version of
-- it is merged into the dataset once. Your own nodes always win over it. Kinds this version of the
-- addon does not have are left out.
local function ApplyShared()
  local shared = SkipLoadingShared
  SkipLoadingShared = nil
  if type(shared) ~= "table" or not shared.stamp or shared.stamp == DS.sharedStamp then return end
  local added = 0
  for _, def in ipairs(KINDS) do
    for mapID, nodes in pairs(shared[def.key] or {}) do
      local zone, w, h = Zone(def, mapID)
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

---------------------------------------------------------------- filters
-- /sl show, hide and only take kinds and node types in any mix: "herbs", "iron", "iron, gold, herbs".
-- A kind word means the whole kind. Any other word is matched against node names: whole words
-- first ("silver" is Silver Vein, not Silverleaf), then the start of a word ("peace" is Peacebloom).

-- the types one term names, as a list of { def, id }; id nil = the whole kind. nil if nothing matched
local function Match(term)
  local def = BY_WORD[term]
  if def then return { { def } } end
  for pass = 1, 2 do
    local hits, find = {}, (pass == 1) and (" " .. term .. " ") or (" " .. term)
    for _, d in ipairs(KINDS) do
      for id, n in pairs(d.nodes) do
        if (" " .. n[1]:lower() .. " "):find(find, 1, true) then hits[#hits + 1] = { d, id } end
      end
    end
    if #hits > 0 then return hits end
  end
end

-- "iron, gold" or "iron gold" -> { [def] = true (the whole kind) or { [id] = true } }, unknown terms
local function Resolve(what)
  local found, unknown = {}, {}
  local function add(hits)
    for _, h in ipairs(hits) do
      local def, id = h[1], h[2]
      if id == nil then found[def] = true
      elseif found[def] ~= true then
        found[def] = found[def] or {}
        found[def][id] = true
      end
    end
  end
  for term in what:gmatch("[^,]+") do
    term = term:match("^%s*(.-)%s*$")
    if term ~= "" then
      local hits = Match(term)
      if hits then
        add(hits)
      else
        -- no commas: "iron gold herbs" is three terms if each of them is known
        local each = {}
        for word in term:gmatch("%S+") do
          each[#each + 1] = Match(word)
          if not each[#each] then each = nil; break end
        end
        if each and #each > 1 then
          for _, hits in ipairs(each) do add(hits) end
        else
          unknown[#unknown + 1] = term
        end
      end
    end
  end
  return found, unknown
end

local function Copy(t)
  local c = {}
  for k, v in pairs(t) do c[k] = v end
  return c
end

-- only: exactly what was named, everything else hidden
local function FilterOnly(found)
  for _, def in ipairs(KINDS) do
    local f = found[def]
    cfg[def.key] = f and true or false
    cfg.pick[def.key] = type(f) == "table" and Copy(f) or nil
  end
end

-- show: add what was named to what is drawn
local function FilterShow(found)
  for def, f in pairs(found) do
    local key, pick = def.key, cfg.pick[def.key]
    if f == true then
      cfg[key], cfg.pick[key] = true, nil
    elseif not cfg[key] then
      cfg[key], cfg.pick[key] = true, Copy(f)
    elseif pick then
      for id in pairs(f) do pick[id] = true end
    end -- else the whole kind is already drawn
  end
end

-- hide: take what was named away from what is drawn
local function FilterHide(found)
  for def, f in pairs(found) do
    local key = def.key
    if f == true then
      cfg[key], cfg.pick[key] = false, nil
    elseif cfg[key] then
      local pick = cfg.pick[key]
      if not pick then
        -- the whole kind was drawn: keep every type except these
        pick = {}
        for id in pairs(def.nodes) do pick[id] = true end
      end
      for id in pairs(f) do pick[id] = nil end
      if next(pick) then cfg.pick[key] = pick else cfg[key], cfg.pick[key] = false, nil end
    end
  end
end

local function ShowAll(on)
  for _, def in ipairs(KINDS) do cfg[def.key], cfg.pick[def.key] = on, nil end
end

-- one line saying what is drawn now, and how many pins that makes in the zone you are in
local function Summary()
  local parts = {}
  for _, def in ipairs(KINDS) do
    if cfg[def.key] then
      local pick = cfg.pick[def.key]
      if pick then
        -- name the shorter list: the types drawn, or the ones left out
        local names, left = {}, {}
        for id in pairs(pick) do names[#names + 1] = NodeName(def, id) end
        for id in pairs(def.nodes) do
          if not pick[id] then left[#left + 1] = NodeName(def, id) end
        end
        if #left < #names then
          table.sort(left)
          parts[#parts + 1] = "|cffffffffall " .. def.key .. " except " .. table.concat(left, ", ") .. "|r"
        else
          table.sort(names)
          parts[#parts + 1] = "|cffffffff" .. table.concat(names, ", ") .. "|r"
        end
      else
        parts[#parts + 1] = "|cffffffffall " .. def.key .. "|r"
      end
    end
  end
  if #parts == 0 then
    say("showing nothing. |cffffffff/sl show all|r or |cffffffff/sl reset|r to bring pins back.")
    return
  end
  local line = "showing " .. table.concat(parts, " + ")
  if cfg.skillups then
    local notes = {}
    for _, def in ipairs(KINDS) do
      if cfg[def.key] and def.Useful then
        local _, note = def.Useful(def, cfg.skillups == "strict")
        if note then notes[#notes + 1] = note end
      end
    end
    line = line .. (cfg.skillups == "strict" and ", only orange and yellow" or ", only skill-ups")
      .. (#notes > 0 and " (" .. table.concat(notes, ", ") .. ")" or "")
  end
  local mapID = PlayerPos()
  if mapID then line = line .. ". " .. #BuildList(mapID) .. " in this zone." end
  say(line)
end

---------------------------------------------------------------- commands
local function Count(def)
  local mine, seed, shared = 0, 0, 0
  for _, zone in pairs(DS[def.key]) do
    for _, node in pairs(zone) do
      if type(node) ~= "table" then seed = seed + 1
      elseif node.shared then shared = shared + 1
      else mine = mine + 1 end
    end
  end
  return mine, seed, shared
end

local function KindList()
  local keys = {}
  for i, def in ipairs(KINDS) do keys[i] = "|cffffffff" .. def.key .. "|r" end
  return table.concat(keys, ", ")
end

SLASH_SKIPLOADING1, SLASH_SKIPLOADING2 = "/sl", "/skiploading"
SlashCmdList.SKIPLOADING = function(msg)
  local verb, what = (msg or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
  if verb == "show" or verb == "hide" or verb == "only" then
    if what == "" or what == "all" then
      ShowAll(verb ~= "hide")
    else
      local found, unknown = Resolve(what)
      if #unknown > 0 then
        say("I don't know '" .. table.concat(unknown, "', '") .. "'. Use a kind (" .. KindList()
          .. ") or part of a node name, e.g. |cffffffff/sl only iron, gold|r.")
        if not next(found) then return end
      end
      if verb == "only" then FilterOnly(found)
      elseif verb == "show" then FilterShow(found)
      else FilterHide(found) end
    end
    Refresh()
    Summary()
    return
  end
  if verb == "skillups" or verb == "skillup" or verb == "xp" then
    -- "/sl xp mining" or "/sl xp strict iron": only those, and the filter on
    local strict, rest = what:match("^(strict)%s*(.*)$")
    if strict then what = rest end
    if what == "on" or (strict and what == "") then cfg.skillups = strict and "strict" or "on"
    elseif what == "off" then cfg.skillups = nil
    elseif what == "" then cfg.skillups = not cfg.skillups and "on" or nil
    else
      local found, unknown = Resolve(what)
      if #unknown > 0 then
        say("I don't know '" .. table.concat(unknown, "', '") .. "'. Try |cffffffff/sl xp mining|r, "
          .. "|cffffffff/sl xp herbs|r or |cffffffff/sl xp strict|r.")
        if not next(found) then return end
      end
      FilterOnly(found)
      cfg.skillups = strict and "strict" or "on"
    end
    Refresh()
    Summary()
    return
  end
  if verb == "reset" then
    ShowAll(true)
    cfg.skillups = nil
    Refresh()
    Summary()
    return
  end
  if verb == "export" then
    say("to share the nodes you found: log out (or /reload) so they are saved, then send this file:")
    say("|cffffffffWTF\\Account\\<your account>\\SavedVariables\\SkipLoading.lua|r")
    return
  end
  if COMMANDS[verb] then
    COMMANDS[verb](what)
    return
  end
  for _, def in ipairs(KINDS) do
    local mine, seed, shared = Count(def)
    say(("%s %s: %d found by you, %d by other players, %d imported"):format(def.key,
      cfg[def.key] and "|cff00ff00shown|r" or "|cffff5555hidden|r", mine, shared, seed))
  end
  Summary()
  local help = { "/sl only|show|hide <kinds or nodes>  (" .. KindList() .. ", all, or names: iron, gold ...)",
    "/sl xp [strict] [mining, herbs, iron ...]", "/sl reset", "/sl export" }
  for _, h in ipairs(COMMAND_HELP) do help[#help + 1] = h end
  say(table.concat(help, "  |  "))
end

---------------------------------------------------------------- events
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("UNIT_SPELLCAST_SENT")
-- these only bring the minimap back to full speed sooner; a client without them still works
local WAKE = { PLAYER_STARTED_MOVING = true, PLAYER_STARTED_TURNING = true, MINIMAP_UPDATE_ZOOM = true }
for event in pairs(WAKE) do pcall(events.RegisterEvent, events, event) end
-- event -> list of { def, handler } from the kinds' `events`
local kindEvents = {}

local function Init()
  SkipLoadingDB = SkipLoadingDB or {}
  cfg = SkipLoadingDB
  cfg.pick = type(cfg.pick) == "table" and cfg.pick or {}
  local imported = type(SkipLoadingForeverDataSet) ~= "table"
  if imported then SkipLoadingForeverDataSet = SkipLoadingSeed() end
  SkipLoadingSeed = nil
  DS = SkipLoadingForeverDataSet
  for _, def in ipairs(KINDS) do
    DS[def.key] = DS[def.key] or {}
    if cfg[def.key] == nil then cfg[def.key] = (def.shown ~= false) end
    for event, handler in pairs(def.events or {}) do
      if not kindEvents[event] then
        kindEvents[event] = {}
        pcall(events.RegisterEvent, events, event)
      end
      table.insert(kindEvents[event], { def, handler })
    end
  end
  if imported then
    local counts, total = {}, 0
    for _, def in ipairs(KINDS) do
      local _, seed = Count(def)
      if seed > 0 then counts[#counts + 1] = seed .. " " .. def.key end
      total = total + seed
    end
    say(("created SkipLoadingForeverDataSet with %d locations (%s). Type /sl for options.")
      :format(total, table.concat(counts, ", ")))
  end
end

events:SetScript("OnEvent", function(_, event, ...)
  if event == "ADDON_LOADED" then
    if ... ~= ADDON then
      if cfg then HookWorldMap() end -- in case the world map loads after us
      if wm.hooked then events:UnregisterEvent("ADDON_LOADED") end
      return
    end
    Init()
  elseif event == "PLAYER_LOGIN" then
    ApplyShared()
    HookWorldMap()
    if wm.hooked then events:UnregisterEvent("ADDON_LOADED") end
    Refresh()
  elseif event == "UNIT_SPELLCAST_SENT" then
    -- (unit, target, castGUID, spellID): for a gathering cast the target is the node's name
    local unit, target, _, spellID = ...
    if unit == "player" and DS and type(target) == "string" and target ~= "" then
      local def = SpellKind(spellID)
      if def then Record(def, target) end
    end
  end
  if WAKE[event] then Wake() end
  local handlers = DS and kindEvents[event]
  if handlers then
    for _, h in ipairs(handlers) do h[2](h[1], ...) end
  end
end)
