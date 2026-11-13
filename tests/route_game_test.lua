-- Loads the whole addon against a stubbed game and drives /sl route: planning, filters, following.
-- Run from the addon folder with any Lua 5.1 or later:  lua tests/route_game_test.lua
-- The stubs only answer what the addon asks; anything else is a do-nothing object.
local dir = (arg and arg[0] or ""):match("^(.*)[/\\]tests[/\\]") or "."

local realPrint = print
local failures, checks = 0, 0
local function ok(cond, msg)
  checks = checks + 1
  if not cond then failures = failures + 1; realPrint("FAIL: " .. msg) end
end

---------------------------------------------------------------- the stubbed game
local said = {}
print = (function(p) return function(...)
  local t = {}
  for i = 1, select("#", ...) do t[#t + 1] = tostring((select(i, ...))) end
  said[#said + 1] = table.concat(t, " ")
end end)(print)

-- a do-nothing object: any method returns nothing, any field is another do-nothing object
local Dummy
Dummy = setmetatable({}, { __index = function() return function() end end, __call = function() end })

local frames, lines = {}, {}
local function NewObject(kind)
  local o = { kind = kind, scripts = {}, shown = kind ~= "Frame", points = {} }
  return setmetatable(o, { __index = function(t, k)
    local m = ({
      SetScript = function(self, name, fn) self.scripts[name] = fn end,
      HookScript = function(self, name, fn) self.scripts[name] = fn end,
      GetScript = function(self, name) return self.scripts[name] end,
      Show = function(self) self.shown = true end,
      Hide = function(self) self.shown = false end,
      SetShown = function(self, v) self.shown = not not v end,
      IsShown = function(self) return self.shown end,
      CreateTexture = function() return NewObject("Texture") end,
      CreateMaskTexture = function() return NewObject("Texture") end,
      CreateLine = function() local l = NewObject("Line"); lines[#lines + 1] = l; return l end,
      GetFrameLevel = function() return 5 end,
      GetWidth = function() return 140 end,
      GetHeight = function() return 140 end,
      GetSize = function() return 1000, 700 end,
      GetZoom = function() return 0 end,
      GetEffectiveScale = function() return 1 end,
      RegisterEvent = function(self, e) local ev = rawget(self, "events") or {}; rawset(self, "events", ev); ev[e] = true end,
      SetPoint = function(self, ...) self.points[#self.points + 1] = { ... } end,
      SetStartPoint = function(self, ...) self.start = { ... } end,
      SetEndPoint = function(self, ...) self.stop = { ... } end,
    })[k]
    return m or function() end
  end })
end

CreateFrame = function(kind)
  local f = NewObject("Frame")
  f.shown = true
  frames[#frames + 1] = f
  return f
end
Minimap = NewObject("Frame")
UIParent = NewObject("Frame")
GameTooltip = NewObject("Frame")
local canvas = NewObject("Frame")
WorldMapFrame = NewObject("Frame")
WorldMapFrame.shown = true
WorldMapFrame.GetCanvas = function() return canvas end
WorldMapFrame.GetMapID = function() return 1413 end
hooksecurefunc = function() end
GetBuildInfo = function() return "1.16.1", "60000" end
GetCVar = function() return "0" end
IsIndoors = function() return false end
GetPlayerFacing = function() return 0 end
UnitOnTaxi = function() return false end
UnitIsDeadOrGhost = function() return false end
UnitAffectingCombat = function() return false end
IsMounted = function() return true end
GetUnitSpeed = function() return 14 end
GetItemIcon = function() return 134708 end
GetSpellInfo = function() return nil end
SlashCmdList = {}
local osClock = os.clock
debugprofilestop = NOWMS or function() return osClock() * 1000 end
time = os.time
-- the game may have no os library: the addon must not need one
local realOs = os
os = nil
unpack = unpack or table.unpack
GetNumSkillLines = function() return 0 end

local player = { mapID = 1413, x = 0.5, y = 0.5 }
CreateVector2D = function(x, y) return { x = x, y = y, GetXY = function(v) return v.x, v.y end } end
C_Map = {
  GetBestMapForUnit = function() return player.mapID end,
  GetPlayerMapPosition = function() return CreateVector2D(player.x, player.y) end,
  GetWorldPosFromMapPos = function(_, v)
    -- The Barrens: about 10133 by 6756 yards
    return 1, CreateVector2D(-v.y * 6756, -v.x * 10133)
  end,
  GetMapInfo = function(id) return { name = "The Barrens" } end,
}

---------------------------------------------------------------- the addon
local files = { "Seed.lua", "Shared.lua", "SkipLoading.lua", "RouteSolver.lua", "Route.lua",
  "Kinds/Gathering.lua", "Kinds/Ores.lua", "Kinds/Herbs.lua" }
local ns = {}
local function ReadAll(path)
  if READFILE then return READFILE(path) end
  if io and io.open then
    local f = assert(io.open(path, "r"))
    local s = f:read("*a")
    f:close()
    return s
  end
  return READFILE(path)
end
for _, file in ipairs(files) do
  local chunk = assert((loadstring or load)(ReadAll(dir .. "/" .. file), "@" .. file))
  chunk("SkipLoading", ns)
end

-- the events frame is the one listening for ADDON_LOADED
local events
for _, f in ipairs(frames) do local ev = rawget(f, "events"); if ev and ev.ADDON_LOADED then events = f end end
assert(events, "events frame")
events.scripts.OnEvent(events, "ADDON_LOADED", "SkipLoading")
events.scripts.OnEvent(events, "PLAYER_LOGIN")
local cfg = SkipLoadingDB

local function Frames(seconds)
  local steps = math.floor(seconds / 0.05 + 0.5)
  for _ = 1, steps do
    for _, f in ipairs(frames) do
      local fn = f.shown and f.scripts.OnUpdate
      if fn then fn(f, 0.05) end
    end
  end
end

local function Said(pattern)
  for _, line in ipairs(said) do if line:find(pattern) then return line end end
end

---------------------------------------------------------------- tests
SlashCmdList.SKIPLOADING("only copper")
said = {}
SlashCmdList.SKIPLOADING("route")
ok(cfg.route == true, "/sl route turns the route on")
ok(Said("planning a route for copper"), "says it is planning, for copper only")
Frames(30)
local line = Said("route in The Barrens")
ok(line ~= nil, "announces the route")
realPrint(line or table.concat(said, "\n"))
ok(cfg.routes and cfg.routes[1413], "route saved for the zone")
local saved = cfg.routes and cfg.routes[1413]
ok(saved and #saved.pts >= 6, "saved route has stops")

-- every stop of the copper route is near a copper spot only
local copperOnly = true
for _, e in ipairs(ns.BuildList(1413)) do
  local id = type(e.node) == "table" and e.node.id or e.node
  if e.def.key ~= "ores" or id ~= 2055 and e.def.nodes[id] and e.def.nodes[id][1] ~= "Copper Vein" then copperOnly = false end
end
ok(copperOnly, "the map list (and so the route) holds copper only")

-- the world map draws one line per leg, between the stops
do
  local route = ns.RouteState().route
  ns.RedrawMap()
  local shownLines = 0
  for _, l in ipairs(lines) do if l.shown and l.start and l.stop then shownLines = shownLines + 1 end end
  ok(shownLines == #route.stops, ("world map: %d lines for %d stops"):format(shownLines, #route.stops))
  local l = lines[1]
  ok(l.start[2] == canvas and math.abs(l.start[3] - route.stops[1].x * 1000) < 1e-6, "a line starts at its stop")
end

-- following: the pointer picks a stop, and moves on when you stand there
said = {}
Frames(1)
local route = ns.RouteState().route
ok(route and route.next, "a next stop is chosen")
local visited = 0
for _ = 1, 5 do
  local k = route.next
  local st = route.stops[k]
  player.x, player.y = st.x, st.y
  Frames(0.5)
  if route.next ~= k then visited = visited + 1 end
end
ok(visited == 5, ("the pointer moved on at each of 5 stops (%d)"):format(visited))
ok((route.arrivals or 0) >= 5, "arrivals counted")
-- reverse: the pointer now goes the other way
local before = route.next
SlashCmdList.SKIPLOADING("route reverse")
ok(route.dir == -1, "reversed")
Frames(0.5)
local k = route.next
player.x, player.y = route.stops[k].x, route.stops[k].y
Frames(0.5)
ok(route.next == (k - 2) % #route.stops + 1, "after reversing, the next stop is the one before")
SlashCmdList.SKIPLOADING("route reverse")
ok(not Said("could not plan"), "no planning errors")

-- changing the filter plans a new route at once
said = {}
SlashCmdList.SKIPLOADING("only tin")
ok(Said("planning") == nil, "no extra message needed for the filter change")
Frames(30)
ok(Said("new route in The Barrens %(tin"), "a filter change plans a new route for tin")
realPrint(Said("new route") or table.concat(said, "\n"))

-- a fixed length
said = {}
SlashCmdList.SKIPLOADING("route 5")
Frames(30)
local fixed = Said("aiming for 5 min")
ok(fixed ~= nil, "a 5-minute route")
realPrint(fixed or table.concat(said, "\n"))

-- reverse, skip, safe
said = {}
SlashCmdList.SKIPLOADING("route reverse")
ok(Said("other way round"), "reverse")
SlashCmdList.SKIPLOADING("route skip")
SlashCmdList.SKIPLOADING("route safe")
ok(cfg.routeSafe == true, "safe on")
Frames(30)
ok(not Said("could not plan"), "no planning errors after safe")

-- off
said = {}
SlashCmdList.SKIPLOADING("route off")
ok(cfg.route == nil and Said("route off"), "route off")

-- back in the zone with the same filters: the saved route comes back without planning
SlashCmdList.SKIPLOADING("route auto")
Frames(30)
said = {}
SlashCmdList.SKIPLOADING("route off")
SlashCmdList.SKIPLOADING("route on")
ok(Said("route in The Barrens") and not Said("planning"), "saved route reused")

-- the route is planned from where you are
do
  local function Nearest(route)
    local best = math.huge
    for _, st in ipairs(route.stops) do
      best = math.min(best, math.sqrt(((st.x - player.x) * 10133) ^ 2 + ((st.y - player.y) * 6756) ^ 2))
    end
    return best
  end
  SlashCmdList.SKIPLOADING("only copper")
  for _, at in ipairs({ { 0.45, 0.15 }, { 0.48, 0.8 }, { 0.62, 0.4 } }) do
    player.x, player.y = at[1], at[2]
    SlashCmdList.SKIPLOADING("route new")
    Frames(30)
    local route = ns.RouteState().route
    ok(route and #route.stops >= 3 and Nearest(route) < 600,
      ("at %.2f, %.2f the route starts near you (%.0f yards)"):format(at[1], at[2], route and Nearest(route) or -1))
  end
  -- the first stop pointed at is the nearest one
  Frames(1)
  local route = ns.RouteState().route
  local st = route.stops[route.next]
  local d = math.sqrt(((st.x - player.x) * 10133) ^ 2 + ((st.y - player.y) * 6756) ^ 2)
  ok(d <= Nearest(route) + 400, ("the pointer starts at a stop near you (%.0f yards, nearest %.0f)"):format(d, Nearest(route)))

  -- far from the route: told once, not replanned
  local stops = route.stops
  said = {}
  player.x, player.y = 0.45, 0.9
  Frames(6)
  ok(Said("min from the route"), "far from the route: says a new one can be planned")
  ok(ns.RouteState().route.stops == stops, "the route is not replanned under you")
  said = {}
  Frames(6)
  ok(not Said("min from the route"), "and says it only once")

  -- off and on again far from the saved route: planned from where you are now
  said = {}
  SlashCmdList.SKIPLOADING("route off")
  SlashCmdList.SKIPLOADING("route on")
  ok(Said("from where you are"), "a route far from here is planned again when turned on")
  Frames(30)
  route = ns.RouteState().route
  ok(Nearest(route) < 600, ("the new route is near you (%.0f yards)"):format(Nearest(route)))
  -- and coming back to it later from the same place: reused
  said = {}
  SlashCmdList.SKIPLOADING("route off")
  SlashCmdList.SKIPLOADING("route on")
  ok(not Said("planning"), "a route near you is reused")

  -- anywhere: the best of the zone, the same wherever you stand
  SlashCmdList.SKIPLOADING("route anywhere")
  ok(cfg.routeAnywhere == true, "anywhere on")
  Frames(30)
  local a = ns.RouteState().route
  player.x, player.y = 0.45, 0.15
  SlashCmdList.SKIPLOADING("route new")
  Frames(30)
  local b = ns.RouteState().route
  ok(#a.stops == #b.stops and math.abs(a.stops[1].x - b.stops[1].x) < 1e-9, "anywhere: the same route from both ends of the zone")
  SlashCmdList.SKIPLOADING("route anywhere")
  ok(cfg.routeAnywhere == nil, "anywhere off")
  Frames(30)

  -- a stop skipped twice without going there is left out of the next route
  route = ns.RouteState().route
  Frames(1)
  local skipped = route.stops[route.next]
  player.x, player.y = skipped.x + 0.02, skipped.y
  said = {}
  SlashCmdList.SKIPLOADING("route skip")
  route.next = nil
  for i, s in ipairs(route.stops) do if s == skipped then route.next = i end end
  SlashCmdList.SKIPLOADING("route skip")
  ok(Said("skipped 2 times"), "skipping a stop twice is noted")
  SlashCmdList.SKIPLOADING("route new")
  Frames(30)
  local near = false
  for _, s in ipairs(ns.RouteState().route.stops) do
    if ((s.x - skipped.x) * 10133) ^ 2 + ((s.y - skipped.y) * 6756) ^ 2 < 20 * 20 then near = true end
  end
  ok(not near, "the skipped stop is not on the new route")
  SlashCmdList.SKIPLOADING("route forget")
  ok(cfg.routeAvoid[1413] == nil, "forget clears the skipped stops")
  Frames(30)
  ok(not Said("could not plan"), "no planning errors")
end

-- reset turns it off
SlashCmdList.SKIPLOADING("reset")
ok(cfg.route == nil, "reset turns the route off")

realPrint(("%d checks, %d failed"):format(checks, failures))
if failures > 0 then realOs.exit(1) end
