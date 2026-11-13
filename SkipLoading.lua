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
--         = a table with tracked = true: a node only spotted on the minimap, never gathered
--           (see "spotting"). seen = sightings, err = yards its position may be off
--   spotted = on a gathered or shared node: when you last saw it on the minimap
--   hits, misses, passes, vt, vo = how often the spot paid off (see "checks")
-- DS.checks[key][uiMapID][coord] = the same five fields for an imported point; they move onto the
--   node that takes its place when you gather or spot it
-- A node you record replaces the imported points of the same type around it.
-- SkipLoadingDB (saved variable) holds settings, shared by all characters:
--   [key]    = true when a kind is shown
--   pick     = { [key] = { [id] = true } }: a shown kind draws only these types; no entry = all of them
--   skillups = nil, "on" or "strict": draw only nodes that can raise your skill (see "filters")
--   spot     = false when spotting on the minimap is off
--   reliable = true to hide spots that keep coming up empty (see "checks")
local ADDON, ns = ...

local floor, sin, cos, huge, pairs, ipairs, type, time = math.floor, math.sin, math.cos, math.huge, pairs, ipairs, type, time
local min, max, sqrt = math.min, math.max, math.sqrt

local SAME_NODE = 15      -- yards: a record this close to one of your own nodes is that node again
local ABSORB = 25         -- yards: the nearest imported point of the same type this close to your node is dropped
local RECOUNT = 300       -- seconds before the same node counts as seen again (a node takes several hits)
local DEPLETED = 300      -- seconds a node you just recorded is drawn greyed out
local TICK = 0.05         -- seconds between minimap position updates while something is moving
local IDLE_TICK = 0.25    -- the same once nothing has moved for a second
local SETTINGS = 0.5      -- seconds between re-reads of the minimap's zoom, size and rotation setting
local MAP_SIZES = { 18, 15, 13 }     -- world map pin sizes: gathered nodes, spotted nodes, imported nodes
local MINIMAP_SIZES = { 15, 13, 12 } -- the same on the minimap
local DRIFT = 40          -- yards you can move before the nodes around you are searched for again
local MARGIN = 60         -- yards past the minimap's edge that a search covers; must be more than DRIFT
-- spotting on the minimap
local SPOT_TICK = 0.1     -- seconds between reads of the minimap's tooltip while the cursor is over it
local BLIP = 6            -- half a tracking blip's width, in minimap units: how far the cursor can be off its centre
local SPOT_REACH = 40     -- yards: the most a sighting can be from a known spot of its type and still be that spot
local IMPORTED_ERR = 10   -- yards an imported point is taken to be off, when it is averaged with sightings
local MIN_ERR = 3         -- yards: no position from sightings claims to be better than this
local BACK = 60           -- seconds after you gather a node before seeing it on the minimap means it came back
-- checks: how often a spot pays off
local VISIT = 600         -- seconds: what you learn about one spot this close together is one visit, counted once
local GRACE = 900         -- seconds after you gather a node during which finding it empty says nothing about it
local PROBE_DWELL = 0.5   -- seconds the cursor rests on a spot's pin, with no blip of its type named, to call it empty
local PROBE_SHARE = 0.8   -- the part of a blip's width trusted to name the blip, to be safe
local GATHER_ERR = 4      -- yards a gathered node's position is taken to be off (you stand next to the node)
local PASS_NEAR = 8       -- yards: walking this close to a spot of a type you would gather ...
local PASS_LEAVE = 35     -- ... and leaving this far without gathering or seeing it is a walk-by
local PASS_WEIGHT = 0.25  -- what a walk-by counts for, against 1 for a find or an empty check
local POOR_CHECKS = 3     -- a spot checked at least this often ...
local POOR_RATE = 0.34    -- ... that paid off less often than this is drawn faint (and hidden by /sl reliable)
local RECENT_BLIP = 120   -- seconds: a blip of a kind read this recently proves its tracking is on

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
--   blips        optional: true when a tracking ability shows these things on the minimap as blips
--                 whose tooltip is the thing's name, so they can be spotted there (see "spotting")
--   track         optional: the spell id of that tracking ability, to tell whether it is on, since
--                 a spot can only be checked empty on the minimap while it is (see "checks")
-- Kinds register while the addon's files load, before ADDON_LOADED, and draw in that order.
local KINDS, BY_KEY, BY_WORD = {}, {}, {}
local SPELL_IDS, SPELL_NAMES = {}, {}
local BLIP_NAMES = {} -- lower-case name -> { def, id }, for the kinds with blips
-- other fields of the dataset and of the settings
local RESERVED = { version = true, source = true, sharedStamp = true, pick = true, skillups = true, spot = true,
  checks = true, reliable = true, route = true, routes = true, routeMinutes = true, routeSafe = true,
  routeSpeed = true, routeSlow = true, routeAnywhere = true, routeAvoid = true }
ns.kinds = KINDS

function ns.RegisterKind(def)
  local key = def.key
  assert(type(key) == "string" and not RESERVED[key] and not BY_KEY[key],
    "Skip Loading: kind key missing, reserved or used twice: " .. tostring(key))
  assert(type(def.nodes) == "table", "Skip Loading: kind " .. key .. " has no nodes table")
  -- name -> id, for turning what the game calls a thing into its id
  def.byName = {}
  for id, n in pairs(def.nodes) do
    def.byName[n[1]:lower()] = id
    if def.blips then BLIP_NAMES[n[1]:lower()] = { def, id } end
  end
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

-- the checks of a spot (see "checks"): a recorded node keeps them itself, an imported point in
-- DS.checks. nil for an imported point never checked, unless `create`
local function Stats(def, mapID, coord, node, create)
  if type(node) == "table" then return node end
  local byMap = DS.checks[def.key]
  if not byMap then
    if not create then return end
    byMap = {}
    DS.checks[def.key] = byMap
  end
  local zone = byMap[mapID]
  if not zone then
    if not create then return end
    zone = {}
    byMap[mapID] = zone
  end
  local s = zone[coord]
  if not s and create then s = {}; zone[coord] = s end
  return s
end

-- how likely the spot is to have its node when you come: finds against empty checks, walk-bys
-- counting a quarter, starting from an even guess so two checks don't make a verdict. Then the
-- finds, empty checks and walk-bys, or nil if it was never checked
local function Reliability(s)
  local h, m, p = s.hits or 0, s.misses or 0, s.passes or 0
  local looks = h + m + p * PASS_WEIGHT
  if looks == 0 then return end
  return (h + 1) / (looks + 2), h, m, p, looks
end

-- checked often enough, and mostly empty
local function Poor(s)
  local rate, _, _, _, looks = Reliability(s)
  return rate ~= nil and looks >= POOR_CHECKS and rate < POOR_RATE
end

-- every node to draw on one map, after the filters, as { x, y, def, node, mapID, coord, poor }
local function BuildList(mapID)
  local list = {}
  for _, def in ipairs(KINDS) do
    local zone = cfg[def.key] and DS[def.key][mapID]
    if zone then
      local pick = cfg.pick[def.key]
      local useful = cfg.skillups and def.Useful and def.Useful(def, cfg.skillups == "strict")
      local checks = DS.checks[def.key] and DS.checks[def.key][mapID]
      for coord, node in pairs(zone) do
        local id = type(node) == "table" and node.id or node
        if (not pick or pick[id]) and (not useful or useful(id)) then
          local stats = type(node) == "table" and node or checks and checks[coord]
          local poor = stats ~= nil and Poor(stats)
          if not (poor and cfg.reliable) then
            local x, y = Decode(coord)
            list[#list + 1] = { x = x, y = y, def = def, node = node, mapID = mapID, coord = coord, poor = poor,
              stats = stats }
          end
        end
      end
    end
  end
  return list
end

-- for Route.lua
ns.BuildList, ns.ZoneSize, ns.PlayerPos = BuildList, ZoneSize, PlayerPos

local function AnyShown()
  for _, def in ipairs(KINDS) do
    if cfg[def.key] then return true end
  end
  return false
end

---------------------------------------------------------------- pins
local function Times(n) return n .. (n == 1 and " time" or " times") end

-- a gathered node seen on the minimap well after you last gathered it: it has come back
local function Back(node)
  return node.spotted and node.spotted > node.last + BACK
end

-- a node you gathered a moment ago and have not seen come back since: drawn greyed out
local function Depleted(node, now)
  return type(node) == "table" and not node.shared and not node.tracked
    and now - node.last < DEPLETED and not Back(node)
end
ns.Depleted = Depleted

-- what the checks say about a spot (see "checks")
local LAST_LOOK = {
  hit = { "Up when you came by %s", 0.25, 1, 0.25 },
  miss = { "Empty when you checked %s", 1, 0.4, 0.3 },
  pass = { "Not gathered when you passed %s", 0.75, 0.75, 0.75 },
}
local function ChecksTooltip(entry)
  local s = Stats(entry.def, entry.mapID, entry.coord, entry.node)
  if not s then return end
  local rate, h, m, p = Reliability(s)
  if rate and h + m > 0 then
    local r, g, b = 1, 1, 0
    if rate >= 0.6 then r, g, b = 0.25, 1, 0.25 elseif rate < POOR_RATE then r, g, b = 1, 0.4, 0.3 end
    GameTooltip:AddLine(("Up %d of %d times you looked"):format(h, h + m), r, g, b)
  end
  if rate and p > 0 then
    GameTooltip:AddLine("Walked past it without finding it " .. Times(p), 0.6, 0.6, 0.6)
  end
  local last = s.vt and time() - s.vt < VISIT and LAST_LOOK[s.vo]
  if last then GameTooltip:AddLine(last[1]:format(Ago(s.vt)), last[2], last[3], last[4]) end
end

local function PinEnter(self)
  local entry = self.entry
  local node = entry and entry.node
  if not node then return end
  local def = entry.def
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  local tooltip = def.Tooltip or DefaultTooltip
  if type(node) == "table" and node.tracked then
    tooltip(def, node.id)
    GameTooltip:AddLine(("%s on the minimap %s, last %s"):format(node.shared and "Spotted by other players" or "Spotted",
      Times(node.seen), Ago(node.last)), 1, 1, 1)
    GameTooltip:AddLine(node.err and ("Not gathered yet, position good to about %d yards"):format(floor(node.err + 0.5))
      or "Not gathered yet", 0.6, 0.6, 0.6)
  elseif type(node) == "table" then
    tooltip(def, node.id)
    GameTooltip:AddLine(("%s %s, last %s"):format(node.shared and "Found by other players" or "Seen",
      Times(node.seen), Ago(node.last)), 1, 1, 1)
    if node.gap and node.gap < 86400 then
      GameTooltip:AddLine("Back within " .. Span(node.gap) .. " at the fastest", 1, 1, 1)
    end
    if node.spotted and (node.shared or Back(node)) then
      GameTooltip:AddLine("Spotted on the minimap " .. Ago(node.spotted), 1, 1, 1)
    end
    if node.build ~= BUILD then
      GameTooltip:AddLine("Not seen since game build " .. node.build, 0.6, 0.6, 0.6)
    end
  else
    tooltip(def, node)
    GameTooltip:AddLine("Imported, not seen by you yet", 0.6, 0.6, 0.6)
  end
  ChecksTooltip(entry)
  GameTooltip:Show()
end
local function PinLeave() GameTooltip:Hide() end

-- hoverable = false for minimap pins: they must let the mouse through to the tracking blips under
-- them, or the game never shows the blip's tooltip. Their own tooltip is shown by the hover check
-- in "spotting" instead.
local function NewPin(parent, hoverable)
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
  if hoverable == false then
    pin:EnableMouse(false)
  else
    pin:SetScript("OnEnter", PinEnter)
    pin:SetScript("OnLeave", PinLeave)
    pin:EnableMouse(true)
    if pin.SetMouseClickEnabled then pin:SetMouseClickEnabled(false) end -- hover only, clicks go to the map
  end
  return pin
end

-- ring colours: nodes you gathered, nodes other players found, nodes you only spotted on the minimap
local RING_MINE, RING_SHARED, RING_SPOT = { 1, 0.82, 0 }, { 0.8, 0.8, 0.85 }, { 0.35, 0.7, 1 }

-- a pin's size from a sizes list { gathered, spotted, imported }
local function PinSize(node, sizes)
  if type(node) ~= "table" then return sizes[3] end
  return node.tracked and sizes[2] or sizes[1]
end

-- gathered nodes: biggest, solid, on top, gold ring (silver if other players gathered them);
-- spotted on the minimap only: a little smaller, blue ring; imported ones: small and faint.
-- Spots that keep coming up empty are drawn much fainter on top of that.
local POOR_ALPHA = 0.4
local function StylePin(pin, entry, sizes, seedAlpha, level)
  local node = entry.node
  local size = PinSize(node, sizes)
  local fade = entry.poor and POOR_ALPHA or 1
  pin.entry = entry
  pin:SetSize(size, size)
  if type(node) == "table" then
    pin.tex:SetTexture(NodeIcon(entry.def, node.id))
    pin.tex:SetDesaturated(Depleted(node, time()))
    local ring = node.shared and RING_SHARED or node.tracked and RING_SPOT or RING_MINE
    pin.ring:SetColorTexture(ring[1], ring[2], ring[3])
    pin.ring:Show()
    pin:SetAlpha((node.build == BUILD and 1 or 0.8) * fade)
    pin:SetFrameLevel(level + (entry.poor and 0 or node.tracked and 1 or node.shared and 2 or 3))
  else
    pin.tex:SetTexture(NodeIcon(entry.def, node))
    pin.tex:SetDesaturated(false)
    pin.ring:Hide()
    pin:SetAlpha(seedAlpha * fade)
    pin:SetFrameLevel(level)
  end
end

-- when the soonest greyed-out node gets its colour back: `soonest`, or this node's time if earlier
local function GreyUntil(node, now, soonest)
  if Depleted(node, now) then
    local t = node.last + DEPLETED
    if t < soonest then return t end
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
  if ns.RouteMinimap then ns.RouteMinimap() end -- no arguments: hide the route
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
        if not pin then pin = NewPin(Minimap, false); pins[n] = pin end
        if restyle or pin.entry ~= e then StylePin(pin, e, MINIMAP_SIZES, 0.5, level) end
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
      -- the offset is kept for finding the pin under the cursor (see "spotting")
      pin.ox, pin.oy = (dx * c + dy * s) * scale, (dy * c - dx * s) * scale
      pin:SetPoint("CENTER", Minimap, "CENTER", pin.ox, pin.oy)
      pin:Show()
    end
  end
  if ns.RouteMinimap then ns.RouteMinimap(mapID, px, py, w, h, s, c, scale, radius, edge) end
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

-- draw the minimap again on its next update, even if you have not moved
function ns.RedrawMinimap()
  mm.lastX = nil
  Wake()
end

---------------------------------------------------------------- world map
local wm = { pins = {}, shown = 0, dirty = true, expire = huge }

-- pin sizes for the world map's current zoom
local function MapSizes(unit)
  return { MAP_SIZES[1] * unit, MAP_SIZES[2] * unit, MAP_SIZES[3] * unit }
end

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
      local sizes = MapSizes(unit)
      for i = 1, wm.shown do
        local size = PinSize(pins[i].entry.node, sizes)
        pins[i]:SetSize(size, size)
      end
      if ns.RouteWorld then ns.RouteWorld(canvas, mapID, cw, ch, unit, wm.level) end
    end
    return
  end

  local list = {}
  if mapID then list = (mapID == mm.mapID and not mm.dirty) and mm.list or BuildList(mapID) end
  local expire = huge
  local ok, level = pcall(function()
    return WorldMapFrame:GetPinFrameLevelsManager():GetValidFrameLevel("PIN_FRAME_LEVEL_AREA_POI")
  end)
  if not ok or type(level) ~= "number" then level = canvas:GetFrameLevel() + 200 end
  wm.level = level
  if #list > 0 then
    local sizes = MapSizes(unit)
    for i = 1, #list do
      local e, pin = list[i], pins[i]
      if not pin then pin = NewPin(canvas); pins[i] = pin end
      StylePin(pin, e, sizes, 0.85, level)
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
  if ns.RouteWorld then ns.RouteWorld(canvas, mapID, cw, ch, unit, level) end
end

-- draw the world map again (the route changed)
function ns.RedrawMap()
  wm.dirty = true
  UpdateWorldMap()
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
  if ns.RouteRefresh then ns.RouteRefresh() end -- the filters or the data changed
end

-- for kinds whose Useful answer just changed (your skill went up): redraw if the filter is on
function ns.UsefulChanged()
  if cfg and cfg.skillups then Refresh() end
end

---------------------------------------------------------------- checks
-- How often a spot pays off. Each time you learn whether a spot's node is there, that is a check:
--   hit   you gathered it, or saw its blip on the minimap. Certain.
--   miss  you rested the cursor on its pin on the minimap, with tracking on, and the game named no
--         blip of its type there (see "probing" under spotting). As certain as a sighting, since
--         it reads the same tooltip; only taken where the spot's position is exact enough that its
--         blip would have been under the cursor.
--   pass  you walked right past it, it was a type you would gather, and you left without gathering
--         or seeing it. Weak (you may have been in a hurry), so it counts a quarter.
-- What you learn about one spot within VISIT seconds is one visit and counts once: the strongest
-- result wins (a hit undoes a miss or pass of the same visit, a miss undoes a pass). Fields on the
-- spot's stats: hits, misses, passes, vt = when the visit began, vo = its result so far.
-- A spot you gathered less than GRACE seconds ago is empty because you took it, so misses and passes
-- then say nothing and are not counted, unless the minimap has shown it back since.
local RANK = { pass = 1, miss = 2, hit = 3 }
local FIELD = { pass = "passes", miss = "misses", hit = "hits" }

-- counts one check of a spot; returns true if it changed anything
local function Check(s, outcome, now)
  if outcome ~= "hit" and s.last and not s.tracked and not s.shared and now - s.last < GRACE and not Back(s) then
    return false
  end
  local old = s.vt and now - s.vt < VISIT and s.vo
  if old then
    if RANK[outcome] <= RANK[old] then return false end
    local f = FIELD[old]
    s[f] = (s[f] or 1) - 1
    if s[f] <= 0 then s[f] = nil end
  else
    s.vt = now
  end
  s.vo = outcome
  local f = FIELD[outcome]
  s[f] = (s[f] or 0) + 1
  return true
end

-- an imported point is giving way to `node`: its checks go with it
local function TakeChecks(def, mapID, coord, node)
  local s = Stats(def, mapID, coord, coord) -- coord as the node: any number means an imported point
  if not s then return end
  DS.checks[def.key][mapID][coord] = nil
  for _, f in pairs(FIELD) do
    if s[f] then node[f] = (node[f] or 0) + s[f] end
  end
  if s.vt and (not node.vt or s.vt > node.vt) then node.vt, node.vo = s.vt, s.vo end
end

---------------------------------------------------------------- recording
-- which nodes of type `id` a search looks at
local function Imported(node, id) return node == id end -- imported points
local function Solid(node, id) -- gathered, by you or other players
  return type(node) == "table" and node.id == id and not node.tracked
end
local function Tracked(node, id) -- only spotted on the minimap, by you or other players
  return type(node) == "table" and node.id == id and node.tracked
end

-- nearest node of type `id` that `match` accepts, within `radius` yards of a spot.
-- Returns its coord key and the distance in yards.
local function Nearest(zone, id, x, y, w, h, match, radius)
  local best, bestDist = nil, radius ^ 2
  for coord, node in pairs(zone) do
    if match(node, id) then
      local nx, ny = Decode(coord)
      local d = ((nx - x) * w) ^ 2 + ((ny - y) * h) ^ 2
      if d <= bestDist then best, bestDist = coord, d end
    end
  end
  if best then return best, sqrt(bestDist) end
end

-- puts a node at a spot, in the next free slot there
local function Place(zone, x, y, node)
  local key = Encode(x, y)
  while zone[key] do key = key + 1 end
  zone[key] = node
end

-- adds a record at a spot; it takes the place of the nearest imported point of the same type only,
-- since another one close by may be a real second node
local function AddRecord(def, mapID, zone, x, y, w, h, record)
  local old = Nearest(zone, record.id, x, y, w, h, Imported, ABSORB)
  if old then
    zone[old] = nil
    TakeChecks(def, mapID, old, record)
  end
  Place(zone, x, y, record)
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

  local key = Nearest(zone, id, x, y, w, h, Solid, SAME_NODE)
  local mine = key and zone[key]
  if not mine then
    -- a node only spotted on the minimap so far: now you stand at it, so it moves to where you are.
    -- Its position may have been off by its err, so it is looked for that much further away.
    local spotted, dist = Nearest(zone, id, x, y, w, h, Tracked, SPOT_REACH)
    local node = spotted and zone[spotted]
    if node and dist <= max(ABSORB, (node.err or IMPORTED_ERR) * 2) then
      zone[spotted] = nil
      Check(node, "hit", now)
      node.tracked, node.err, node.shared, node.gap = nil, nil, nil, nil
      node.seen, node.first, node.last, node.build = 1, node.first or now, now, BUILD
      Place(zone, x, y, node)
      Refresh()
      return
    end
  end
  if mine then Check(mine, "hit", now) end
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
    local node = { id = id, seen = 1, first = now, last = now, build = BUILD }
    AddRecord(def, mapID, zone, x, y, w, h, node)
    Check(node, "hit", now)
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
        -- a node only spotted on the minimap (by you or them) is less exact, so it matches further out
        local key = Nearest(zone, s.id, x, y, w, h, Solid, s.tracked and ABSORB or SAME_NODE)
          or Nearest(zone, s.id, x, y, w, h, Tracked, ABSORB)
        local known = key and zone[key]
        local tracked = s.tracked and true or nil
        if not known then
          AddRecord(def, mapID, zone, x, y, w, h,
            { id = s.id, seen = s.seen, last = s.last, build = s.build, shared = true, tracked = tracked })
          added = added + 1
        elseif known.shared and (known.tracked or not tracked) then -- a gathered one never goes back to spotted
          known.seen, known.last, known.build, known.tracked = s.seen, s.last, s.build, tracked
        end
      end
    end
  end
  DS.sharedStamp = shared.stamp
  if added > 0 then say(added .. " new locations found by other players were added.") end
end

---------------------------------------------------------------- spotting
-- With a tracking ability on (Find Minerals, Find Herbs), the minimap shows a blip for each node in
-- range, and with the cursor over a blip the game shows the node's name in a tooltip owned by the
-- minimap. While the cursor is over the minimap the addon reads that tooltip; each name of a known
-- thing is a sighting, placed where the cursor is. That records nodes you only ride past, including
-- ones your skill is too low for. Nothing is read that the game does not show you.
--
-- The cursor can be anywhere on the blip, so a sighting is only as exact as the blip is wide in
-- yards: about 20 zoomed all the way out, 5 zoomed in. The samples taken while one blip stays under
-- the cursor are averaged into one sighting, and the sightings of one spot over time are averaged
-- again, each weighted by how exact it was. A sighting near an imported point of the same type
-- confirms it: the two are averaged into one spotted node.
--
-- Minimap pins let the mouse through (or they would hide the blips under them), so their tooltips
-- are shown from here too: the same check finds the pin under the cursor.

-- the weighted average of two positions, each good to `err` yards, and how good the result is
local function Combine(ax, ay, aerr, bx, by, berr)
  local wa, wb = 1 / aerr ^ 2, 1 / berr ^ 2
  local s = wa + wb
  return (ax * wa + bx * wb) / s, (ay * wa + by * wb) / s, max(MIN_ERR, 1 / sqrt(s))
end

-- one sighting of a thing of type `id` at x, y, good to `err` yards. Returns what it was:
-- "known" (a gathered node), "again" (a spotted one), "confirmed" (an imported point) or "new"
local function Spot(def, id, mapID, x, y, err)
  local zone, w, h = Zone(def, mapID)
  local now = time()
  local reach = max(SAME_NODE, min(SPOT_REACH, err * 1.5 + 5))

  -- a gathered node: its position is exact already, but it is up right now. Seen after you last
  -- gathered it, it has come back, which says how fast it respawns.
  local key = Nearest(zone, id, x, y, w, h, Solid, reach)
  if key then
    local node = zone[key]
    if not node.shared and now - node.last > BACK and not Back(node) then
      local gap = now - node.last
      if not node.gap or gap < node.gap then node.gap = gap end
    end
    node.spotted = now
    Check(node, "hit", now)
    return "known"
  end

  -- spotted before: average the two
  key = Nearest(zone, id, x, y, w, h, Tracked, reach)
  local node = key and zone[key]
  if node then
    zone[key] = nil
    if node.shared then
      -- other players spotted it; now you have too, so it becomes yours
      node.shared, node.seen, node.first, node.last = nil, 0, now, 0
    end
    if now - node.last > RECOUNT then node.seen = node.seen + 1 end
    local nx, ny = Decode(key)
    x, y, node.err = Combine(nx, ny, node.err or IMPORTED_ERR, x, y, err)
    node.last, node.build = now, BUILD
    Check(node, "hit", now)
    Place(zone, x, y, node)
    return "again"
  end

  node = { id = id, seen = 1, first = now, last = now, build = BUILD, tracked = true, err = err }
  key = Nearest(zone, id, x, y, w, h, Imported, reach)
  if key then
    zone[key] = nil
    TakeChecks(def, mapID, key, node)
    Check(node, "hit", now)
    local ix, iy = Decode(key)
    x, y, node.err = Combine(ix, iy, IMPORTED_ERR, x, y, err)
    Place(zone, x, y, node)
    return "confirmed"
  end
  Check(node, "hit", now)
  Place(zone, x, y, node)
  return "new"
end

local spot = {
  pending = {},   -- "key:id" -> samples of one blip under the cursor, not yet a sighting
  tick = 0,       -- counts reads, to tell which blips were under the cursor in the last one
  counts = { known = 0, again = 0, confirmed = 0, new = 0, -- sightings this session, by result
    empty = 0, passed = 0 },                                -- and checks that found nothing (see "checks")
  lastBlip = {},  -- kind key -> GetTime() a blip of that kind was last read
}

-- the cursor's offset from the minimap's centre, in the units pins are placed in
local function CursorOffset()
  local x, y = GetCursorPosition()
  local s = Minimap:GetEffectiveScale()
  local cx, cy = Minimap:GetCenter()
  return x / s - cx, y / s - cy
end

-- the shown minimap pin under the cursor, if any
local function PinUnderCursor(cx, cy)
  local best, bestDist
  for i = 1, #mm.pins do
    local pin = mm.pins[i]
    if pin.ox and pin:IsShown() then
      local r = pin:GetWidth() / 2 + 1
      local d = (pin.ox - cx) ^ 2 + (pin.oy - cy) ^ 2
      if d <= r * r and (not bestDist or d < bestDist) then best, bestDist = pin, d end
    end
  end
  return best
end

-- the tooltip's text as plain lines: colours, icons and atlas markup taken out
local function TooltipLines()
  local lines = {}
  for i = 1, GameTooltip:NumLines() do
    local region = _G["GameTooltipTextLeft" .. i]
    local text = region and region:GetText()
    if text then
      text = text:gsub("|T.-|t", ""):gsub("|A.-|a", ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
      for part in text:gmatch("[^\n]+") do
        part = part:match("^%s*(.-)%s*$")
        if part ~= "" then lines[#lines + 1] = part end
      end
    end
  end
  return lines
end

-- turns the samples of one blip into a sighting
local function Commit(k)
  local p = spot.pending[k]
  spot.pending[k] = nil
  local result = Spot(p.def, p.id, p.mapID, p.sx / p.n, p.sy / p.n, p.err)
  spot.counts[result] = spot.counts[result] + 1
end

-- one sample: a blip named like a thing of type `id` is under the cursor at x, y
local function Sample(def, id, mapID, x, y, err, w, h)
  local k = def.key .. ":" .. id
  local p = spot.pending[k]
  -- the cursor moved on to another blip of the same type without leaving the first one's name
  if p and (p.mapID ~= mapID
    or ((p.sx / p.n - x) * w) ^ 2 + ((p.sy / p.n - y) * h) ^ 2 > (2 * max(p.err, err)) ^ 2) then
    Commit(k)
    p = nil
  end
  if not p then
    p = { def = def, id = id, mapID = mapID, sx = 0, sy = 0, n = 0, err = err }
    spot.pending[k] = p
  end
  spot.lastBlip[def.key] = GetTime()
  p.sx, p.sy, p.n, p.err, p.tick = p.sx + x, p.sy + y, p.n + 1, min(p.err, err), spot.tick
end

-- Probing: the same tooltip also tells when a spot is empty. With the cursor resting on a spot's
-- pin and that kind's tracking on, the game would name the spot's blip if its node were up. If it
-- names no blip of that type for PROBE_DWELL seconds, the spot is checked empty (see "checks").
-- That is only sound where the spot's position is close enough that its blip, if up, must lie under
-- the cursor: the cursor must be within (blip half-width - the spot's error) of the pin's centre.
-- Zoomed out a blip covers more yards, so most spots can be probed there; zoomed in only exact ones.
-- While a pin is being probed its own tooltip waits, so that it never hides the blip's.

-- whether a kind's tracking ability is on, and how that was told. A blip of the kind read just now
-- proves it; otherwise the tracking menu or the tracking icon is asked. Kept for a second.
local function ReadTracking(def)
  if spot.lastBlip[def.key] and GetTime() - spot.lastBlip[def.key] < RECENT_BLIP then
    return true, "a blip read just now"
  end
  local spellID = def.track
  if not spellID then return false, "no tracking spell known for " .. def.key end
  local name = SpellName(spellID)
  if C_Minimap and C_Minimap.GetNumTrackingTypes and C_Minimap.GetTrackingInfo then
    local ok, n = pcall(C_Minimap.GetNumTrackingTypes)
    if ok and type(n) == "number" and n > 0 then
      for i = 1, n do
        local ok2, a, _, c, _, _, sid = pcall(C_Minimap.GetTrackingInfo, i)
        if ok2 and a then
          local tname, active = a, c
          if type(a) == "table" then tname, active, sid = a.name, a.active, a.spellID end
          if sid == spellID or (name and tname == name) then return active and true or false, "the tracking menu" end
        end
      end
      return false, "the tracking menu (not in it)"
    end
  end
  if GetTrackingTexture then
    local tex = GetTrackingTexture()
    if not tex then return false, "the tracking icon (none)" end
    local want = (C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(spellID))
      or (GetSpellTexture and GetSpellTexture(spellID))
    if want and type(want) == type(tex) then return tex == want, "the tracking icon" end
  end
  return false, "nothing that answers (no blip read lately)"
end

local tracking = {} -- def -> { on, how, at }
local function TrackingOn(def)
  local t, now = tracking[def], GetTime()
  if not t or now - t.at > 1 then
    t = t or {}
    t.on, t.how = ReadTracking(def)
    t.at = now
    tracking[def] = t
  end
  return t.on, t.how
end

-- yards a spot's position may be off
local function EntryErr(e)
  local node = e.node
  if type(node) ~= "table" then return IMPORTED_ERR end
  return node.tracked and (node.err or IMPORTED_ERR) or GATHER_ERR
end

-- the shown minimap pin the cursor is close enough to for its spot to be probed; ypu = yards per
-- minimap unit
local function ProbeTarget(cx, cy, ypu)
  local best, bestD
  for i = 1, #mm.pins do
    local pin = mm.pins[i]
    local e = pin.entry
    if e and pin.ox and pin:IsShown() and e.def.blips and e.coord then
      local slack = BLIP * PROBE_SHARE - EntryErr(e) / ypu
      local d = sqrt((pin.ox - cx) ^ 2 + (pin.oy - cy) ^ 2)
      if d <= slack and (not bestD or d < bestD) then best, bestD = e, d end
    end
  end
  if best and TrackingOn(best.def) then return best end
end

-- the spot being probed: mapID, coord and node say which; dwell = seconds without its blip named;
-- done = decided, or found up
local probe = {}

-- one probe was decided empty: count it. Returns true if it counted
local function Empty(e, now)
  local zone = DS[e.def.key][e.mapID]
  if not zone or zone[e.coord] ~= e.node then return end -- it moved or went since the pins were built
  if Check(Stats(e.def, e.mapID, e.coord, e.node, true), "miss", now) then
    spot.counts.empty = spot.counts.empty + 1
    return true
  end
end

-- one read of the probe on spot `e` (nil: none). lines = the blips' tooltip if it is up; clean = no
-- other tooltip is up that could keep a blip from being named. Returns true if a miss was counted
local function ProbeTick(e, lines, clean, dt)
  if not e then
    probe.coord = nil
    return
  end
  if probe.coord ~= e.coord or probe.mapID ~= e.mapID or probe.node ~= e.node then
    probe.coord, probe.mapID, probe.node, probe.dwell, probe.done = e.coord, e.mapID, e.node, 0, false
  end
  if probe.done then return end
  local id = type(e.node) == "table" and e.node.id or e.node
  for _, line in ipairs(lines or {}) do
    local thing = BLIP_NAMES[line:lower()]
    if thing and thing[1] == e.def and thing[2] == id then
      probe.done = true -- it is up: spotting counts that when the cursor leaves the blip
      return
    end
  end
  if not clean then return end
  probe.dwell = probe.dwell + dt
  if probe.dwell >= PROBE_DWELL then
    probe.done = true
    return Empty(e, time())
  end
end

local function Probing(e)
  return e and not probe.done and probe.coord == e.coord and probe.mapID == e.mapID and probe.node == e.node
end

local hover = CreateFrame("Frame")
hover:Hide()
local hoverAcc, tipPin = 0, nil

local function HoverTick(dt)
  local over = cfg and Minimap:IsVisible() and Minimap:IsMouseOver()
  local names, cx, cy, half, probed
  if over then
    cx, cy = CursorOffset()
    half = Minimap:GetWidth() / 2
    local inside = cx * cx + cy * cy <= (half * 0.94) ^ 2
    local shown = GameTooltip:IsShown()
    local owner = shown and GameTooltip:GetOwner()
    if owner and owner == tipPin then owner = nil end
    local blipTip = owner == Minimap or (shown and not owner and not tipPin)
    local lines
    if blipTip then
      lines = TooltipLines()
      spot.lastText = table.concat(lines, " / ")
      spot.lastOwner = owner and "the minimap" or "no owner"
    end
    -- probe the spot under the cursor first: its pin's tooltip waits until that is decided
    if cfg.spot ~= false and inside then
      local target = ProbeTarget(cx, cy, MinimapRadius() / half)
      -- any tooltip but the blips' might keep them from being named, our own pins' included
      probed = ProbeTick(target, lines, blipTip or not shown, dt)
      if target and Probing(target) and tipPin then
        if GameTooltip:GetOwner() == tipPin then GameTooltip:Hide() end
        tipPin = nil
      end
    else
      ProbeTick(nil)
    end
    if blipTip then
      -- the game's tooltip for the blips under the cursor
      tipPin = nil
      if cfg.spot ~= false and cx * cx + cy * cy <= half * half then names = lines end
    else
      if owner and shown then
        -- someone else's tooltip while over the minimap: kept for /sl spot, in case it is the blips'
        spot.lastText = table.concat(TooltipLines(), " / ")
        spot.lastOwner = (owner.GetName and owner:GetName()) or "an unnamed frame"
      end
      local pin = PinUnderCursor(cx, cy)
      if pin and Probing(pin.entry) then pin = nil end
      if pin ~= tipPin then
        if tipPin and GameTooltip:GetOwner() == tipPin then GameTooltip:Hide() end
        tipPin = pin
        if pin then PinEnter(pin) end
      elseif pin and not GameTooltip:IsShown() then
        PinEnter(pin) -- still on the pin, but something closed its tooltip
      end
    end
  else
    ProbeTick(nil)
    if tipPin then
      if GameTooltip:GetOwner() == tipPin then GameTooltip:Hide() end
      tipPin = nil
    end
  end

  spot.tick = spot.tick + 1
  if names then
    local mapID, px, py = PlayerPos()
    local w, h
    if mapID then w, h = ZoneSize(mapID) end
    if w then
      local yards = MinimapRadius() / half -- yards per minimap unit
      local facing = GetCVar("rotateMinimap") == "1" and GetPlayerFacing() or 0
      local s, c = sin(facing), cos(facing)
      -- undo the rotation the pins get: back to yards east and north of you
      local u, v = cx * yards, cy * yards
      local dx, dy = u * c - v * s, u * s + v * c
      local x, y, err = px + dx / w, py - dy / h, max(MIN_ERR, BLIP * yards)
      for _, name in ipairs(names) do
        local thing = BLIP_NAMES[name:lower()]
        if thing then Sample(thing[1], thing[2], mapID, x, y, err, w, h) end
      end
    end
  end
  -- a blip whose name has gone from the tooltip: the cursor has left it
  local committed = false
  for k, p in pairs(spot.pending) do
    if p.tick ~= spot.tick then
      Commit(k)
      committed = true
    end
  end
  if committed or probed then
    -- a spot checked empty may now be drawn fainter, or be hidden by /sl reliable
    Refresh()
    if tipPin and GameTooltip:GetOwner() == tipPin then PinEnter(tipPin) end -- its node may have just changed
  end
  if not over then hover:Hide() end
end

---------------------------------------------------------------- walk-bys
-- A weak check (see "checks"): you walked within PASS_NEAR yards of a spot whose position is exact
-- (gathered, or spotted closely), of a type you would gather (shown by your filters and able to
-- raise your skill), and left PASS_LEAVE yards away without gathering it or seeing it on the
-- minimap. Walks spent on a flight path, dead or in combat say nothing and are dropped.
-- Only spots near enough to be on the minimap are looked at, from the list it already keeps.
local WALK_TICK = 0.5
local walk = { on = {}, useful = {}, acc = 0 }

local function WalkTick()
  local now = time()
  local mapID, px, py = PlayerPos()
  local w, h
  if mapID then w, h = ZoneSize(mapID) end
  local busy = not w or (UnitOnTaxi and UnitOnTaxi("player")) or UnitIsDeadOrGhost("player")
    or UnitAffectingCombat("player")
  for node, p in pairs(walk.on) do
    if busy then p.spoiled = true end
    if not w or p.mapID ~= mapID or ((p.x - px) * w) ^ 2 + ((p.y - py) * h) ^ 2 > PASS_LEAVE * PASS_LEAVE then
      walk.on[node] = nil
      if not p.spoiled and Check(node, "pass", now) then
        spot.counts.passed = spot.counts.passed + 1
        Refresh()
      end
    end
  end
  if busy or mapID ~= mm.mapID then return end
  -- which types you would gather, worked out again whenever the pins are rebuilt
  if walk.list ~= mm.list then
    walk.list = mm.list
    for _, def in ipairs(KINDS) do walk.useful[def] = def.Useful and def.Useful(def, false) or nil end
  end
  local near = mm.near
  for i = 1, #near do
    local e = near[i]
    local node = e.node
    if type(node) == "table" and not walk.on[node] and (not node.tracked or (node.err or IMPORTED_ERR) <= PASS_NEAR)
      and ((e.x - px) * w) ^ 2 + ((e.y - py) * h) ^ 2 <= PASS_NEAR * PASS_NEAR then
      local useful = walk.useful[e.def]
      if useful and useful(node.id) then walk.on[node] = { x = e.x, y = e.y, mapID = mapID } end
    end
  end
end

local walker = CreateFrame("Frame")
walker:SetScript("OnUpdate", function(_, elapsed)
  walk.acc = walk.acc + elapsed
  if walk.acc < WALK_TICK then return end
  walk.acc = 0
  if DS then WalkTick() end
end)

hover:SetScript("OnUpdate", function(_, elapsed)
  hoverAcc = hoverAcc + elapsed
  if hoverAcc < SPOT_TICK then return end
  local dt = hoverAcc
  hoverAcc = 0
  HoverTick(dt)
end)
Minimap:HookScript("OnEnter", function() hover:Show() end)

local function SpotStatus()
  local c = spot.counts
  say(("spotting on the minimap is %s. This session: %d new, %d imported points confirmed, %d spotted again, "
    .. "%d gathered nodes seen up.")
    :format(cfg.spot == false and "|cffff5555off|r" or "|cff00ff00on|r", c.new, c.confirmed, c.again, c.known))
  say(("checks this session: %d spots found empty under the cursor, %d walked past empty."):format(c.empty, c.passed))
  for _, def in ipairs(KINDS) do
    if def.blips then
      local on, how = TrackingOn(def)
      say(("  tracking for %s: %s (from %s)"):format(def.key, on and "|cff00ff00on|r" or "|cffff5555off|r", how))
    end
  end
  if spot.lastText then
    say(("last tooltip over the minimap: '%s' (from %s)"):format(spot.lastText, spot.lastOwner))
  elseif cfg.spot ~= false then
    say("nothing read yet: turn on Find Minerals or Find Herbs and hold the cursor over a blip on the minimap.")
  end
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
  if cfg.reliable then line = line .. ", without spots that keep coming up empty" end
  local mapID = PlayerPos()
  if mapID then line = line .. ". " .. #BuildList(mapID) .. " in this zone." end
  say(line)
end

---------------------------------------------------------------- commands
-- gathered by you, imported, found by other players (gathered or spotted), spotted by you
local function Count(def)
  local mine, seed, shared, spotted = 0, 0, 0, 0
  for _, zone in pairs(DS[def.key]) do
    for _, node in pairs(zone) do
      if type(node) ~= "table" then seed = seed + 1
      elseif node.shared then shared = shared + 1
      elseif node.tracked then spotted = spotted + 1
      else mine = mine + 1 end
    end
  end
  return mine, seed, shared, spotted
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
  if verb == "reliable" then
    if what == "on" then cfg.reliable = true
    elseif what == "off" then cfg.reliable = nil
    elseif what == "" then cfg.reliable = not cfg.reliable or nil
    else
      say("|cffffffff/sl reliable|r, |cffffffff/sl reliable on|r or |cffffffff/sl reliable off|r.")
      return
    end
    Refresh()
    Summary()
    return
  end
  if verb == "reset" then
    ShowAll(true)
    cfg.skillups, cfg.reliable, cfg.route = nil, nil, nil
    Refresh()
    Summary()
    return
  end
  if verb == "spot" or verb == "spotting" then
    if what == "on" then cfg.spot = nil
    elseif what == "off" then cfg.spot = false
    elseif what ~= "" then
      say("|cffffffff/sl spot|r, |cffffffff/sl spot on|r or |cffffffff/sl spot off|r.")
      return
    end
    SpotStatus()
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
    local mine, seed, shared, spotted = Count(def)
    say(("%s %s: %d found by you, %d spotted on the minimap, %d by other players, %d imported"):format(def.key,
      cfg[def.key] and "|cff00ff00shown|r" or "|cffff5555hidden|r", mine, spotted, shared, seed))
  end
  Summary()
  local help = { "/sl only|show|hide <kinds or nodes>  (" .. KindList() .. ", all, or names: iron, gold ...)",
    "/sl xp [strict] [mining, herbs, iron ...]", "/sl reliable [on|off]", "/sl reset", "/sl spot [on|off]",
    "/sl export" }
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
  ns.cfg = cfg
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
  if type(DS.checks) ~= "table" then
    -- first load with checks: every time you gathered or spotted a node so far was a time it was up
    DS.checks = {}
    for _, def in ipairs(KINDS) do
      for _, zone in pairs(DS[def.key]) do
        for _, node in pairs(zone) do
          if type(node) == "table" and not node.shared and node.seen and not node.hits then node.hits = node.seen end
        end
      end
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
