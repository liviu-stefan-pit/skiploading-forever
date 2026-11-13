-- Farming routes: /sl route draws one loop through the zone you are in, through the nodes the map is
-- showing (so the filters decide what the route is for), and points at the next stop. The maths is
-- in RouteSolver.lua; this file turns the dataset into its input, runs it a few milliseconds per
-- frame, draws the result on the world map and the minimap, and follows you round it.
-- See ROUTES.md for the why.
local _, ns = ...
local floor, sqrt, min, max, huge = math.floor, math.sqrt, math.min, math.max, math.huge
local say = ns.say

local SLICE = 4          -- ms of planning per frame
local BUDGET = 1500      -- ms of planning in all; after that the best loop so far is used
local HANDLE = 5         -- seconds to gather one node
local RUN_SPEED = 7      -- yards a second on foot, until your mount's speed is known
local DEFAULT_TAU = 480  -- seconds a node takes to come back, until your data says otherwise
local TAU_SAMPLES = 5    -- returns needed (per kind and zone) before they are trusted for that
local UCB = 0.5          -- the bonus for little-checked spots, in standard deviations (see ROUTES.md 4.1)
local W_MAX = 0.95       -- no spot is counted as more certain than this
local ARRIVE = 25        -- yards from a stop's centre that count as being there
local REJOIN = 150       -- yards from the next stop beyond which you are taken to have left the loop
local REJOIN_EVERY = 2   -- seconds between checks for that
local FOLLOW_TICK = 0.25 -- seconds between follow checks
local SLOW_FACTOR = 1.6  -- a leg taking this many times its straight-line time ...
local SLOW_EXTRA = 20    -- ... plus this many seconds (gathering, a fight you avoided) ...
local SLOW_TIMES = 2     -- ... this many times is a slow leg: the next plan uses its real time
local BETTER = 1.15      -- a fresh plan this much better per minute is worth a note
local MAX_DOTS = 300     -- minimap route dots at most
local FAR = 90           -- seconds' ride from the nearest stop beyond which a route is not where you are
local ON_LEG = 40        -- yards from the line to the stop after: nearer than this you are on your way there
local AVOID_TIMES = 2    -- a stop skipped this many times without going there is left out of new routes
local AVOID_REACH = 30   -- yards: the spots this near a skipped stop are the ones left out

-- the starting guess for a spot's chance, by where it came from: { finds, empties } it is worth
-- before any check. Yours first, imported last (ROUTES.md 4.1)
local PRIOR = {
  mine = { 3, 1 }, spotted = { 2.5, 1 }, shared = { 2, 1 }, sharedSpot = { 1.5, 1 }, imported = { 1, 2 },
}
local SOURCE_RANK = { mine = 4, spotted = 3, shared = 2, sharedSpot = 2, imported = 1 }

local R = {
  route = nil,  -- the route on show: { mapID, sig, w, h, stops = { { x, y, members } }, next, dir, ... }
  job = nil,    -- the plan being worked out: { co, mapID, sig, kind = "plan"|"better", ... }
  dirty = true, -- the dataset changed: stops' members need matching again
}

local function Cfg() return ns.cfg end
function ns.RouteState() return R end -- for the tests

local function Source(node)
  if type(node) ~= "table" then return "imported" end
  if node.shared then return node.tracked and "sharedSpot" or "shared" end
  return node.tracked and "spotted" or "mine"
end

-- how likely a spot is to pay off: the checks on it, starting from its source's guess; plus a
-- bonus while it has had few checks, so untested spots get tried (unless /sl route safe)
local function Chance(e, safe)
  local s = e.stats or {}
  local prior = PRIOR[Source(e.node)]
  local a = (s.hits or 0) + prior[1]
  local b = (s.misses or 0) + (s.passes or 0) * 0.25 + prior[2]
  local r = a / (a + b)
  if not safe then r = r + UCB * sqrt(a * b / ((a + b) ^ 2 * (a + b + 1))) end
  return min(W_MAX, r)
end

-- how long nodes of each kind take to come back here: the median of the fastest returns you saw
local function Taus(list)
  local gaps = {}
  for _, e in ipairs(list) do
    local node = e.node
    if type(node) == "table" and not node.shared and node.gap and node.gap < 86400 then
      local g = gaps[e.def] or {}
      gaps[e.def] = g
      g[#g + 1] = node.gap
    end
  end
  local taus = {}
  for def, g in pairs(gaps) do
    if #g >= TAU_SAMPLES then
      table.sort(g)
      taus[def] = max(60, min(3600, g[floor((#g + 1) / 2)]))
    end
  end
  return taus
end

local function Speed() return Cfg().routeSpeed or RUN_SPEED end

-- what the route is planned from: kinds shown, node types picked, the filters and route settings.
-- When it changes, the route is planned again.
local function Signature()
  local cfg, parts = Cfg(), {}
  for _, def in ipairs(ns.kinds) do
    local p = def.key .. "=" .. (cfg[def.key] and "1" or "0")
    local pick = cfg.pick[def.key]
    if cfg[def.key] and pick then
      local ids = {}
      for id in pairs(pick) do ids[#ids + 1] = tostring(id) end
      table.sort(ids)
      p = p .. ":" .. table.concat(ids, ",")
    end
    parts[#parts + 1] = p
  end
  parts[#parts + 1] = "xp=" .. tostring(cfg.skillups)
  parts[#parts + 1] = "rel=" .. tostring(cfg.reliable)
  parts[#parts + 1] = "safe=" .. tostring(cfg.routeSafe)
  parts[#parts + 1] = "min=" .. tostring(cfg.routeMinutes)
  parts[#parts + 1] = "any=" .. tostring(cfg.routeAnywhere)
  return table.concat(parts, ";")
end

-- what the filters show, for messages: "copper, tin" or "all ores, all herbs"
local function WhatText()
  local cfg, parts = Cfg(), {}
  for _, def in ipairs(ns.kinds) do
    if cfg[def.key] then
      local pick = cfg.pick[def.key]
      if pick then
        local names = {}
        for id in pairs(pick) do
          local n = def.nodes[id]
          names[#names + 1] = (n and n[1] or tostring(id)):lower()
        end
        table.sort(names)
        if #names > 4 then names = { names[1], names[2], names[3], (#names - 3) .. " more" } end
        parts[#parts + 1] = table.concat(names, ", ")
      else
        parts[#parts + 1] = def.key
      end
    end
  end
  return table.concat(parts, ", ")
end

local function ZoneName(mapID)
  local info = C_Map.GetMapInfo and C_Map.GetMapInfo(mapID)
  return info and info.name or ("map " .. mapID)
end

---------------------------------------------------------------- slow legs
local function LegKey(a, b)
  local function P(s) return floor(s.x * 1000 + 0.5) .. "," .. floor(s.y * 1000 + 0.5) end
  local ka, kb = P(a), P(b)
  if ka > kb then ka, kb = kb, ka end
  return ka .. ">" .. kb
end

-- the slow legs of a zone, in yards, for the solver
local function SlowLegs(mapID, w, h)
  local legs, out = Cfg().routeSlow and Cfg().routeSlow[mapID], {}
  for _, leg in pairs(legs or {}) do
    if leg.n >= SLOW_TIMES then out[#out + 1] = { leg.x1 * w, leg.y1 * h, leg.x2 * w, leg.y2 * h, leg.f } end
  end
  return out
end

local function NoteLeg(route, a, b, took)
  local d = sqrt(((a.x - b.x) * route.w) ^ 2 + ((a.y - b.y) * route.h) ^ 2)
  local expect = d / Speed()
  if took <= expect * SLOW_FACTOR + SLOW_EXTRA then return end
  local cfg = Cfg()
  cfg.routeSlow = cfg.routeSlow or {}
  local zone = cfg.routeSlow[route.mapID] or {}
  cfg.routeSlow[route.mapID] = zone
  local key = LegKey(a, b)
  local leg = zone[key] or { x1 = a.x, y1 = a.y, x2 = b.x, y2 = b.y, n = 0, f = 1 }
  zone[key] = leg
  leg.n = leg.n + 1
  leg.f = max(leg.f, min(10, took / max(expect, 1)))
end

---------------------------------------------------------------- the solver's input
-- the spots on the map now, in yards, with their value; and the entries they came from
local function Spots(mapID, w, h)
  local cfg = Cfg()
  local list = ns.BuildList(mapID)
  local taus = Taus(list)
  local worth = {}
  if cfg.skillups then
    for _, def in ipairs(ns.kinds) do worth[def] = def.Worth and def.Worth(def) end
  end
  -- stops you skipped without going there, more than once: somewhere you cannot or will not go
  local avoid = {}
  for _, a in pairs(cfg.routeAvoid and cfg.routeAvoid[mapID] or {}) do
    if a.n >= AVOID_TIMES then avoid[#avoid + 1] = a end
  end
  local function Avoided(e)
    for _, a in ipairs(avoid) do
      if ((a.x - e.x) * w) ^ 2 + ((a.y - e.y) * h) ^ 2 <= AVOID_REACH * AVOID_REACH then return true end
    end
    return false
  end
  local spots, entries = {}, {}
  for _, e in ipairs(list) do
    local id = type(e.node) == "table" and e.node.id or e.node
    local want = worth[e.def] and worth[e.def](id) or 1
    if want > 0 and not Avoided(e) then
      spots[#spots + 1] = { x = e.x * w, y = e.y * h, w = Chance(e, cfg.routeSafe) * want, g = e.def.key,
        tau = taus[e.def] or DEFAULT_TAU }
      entries[#spots] = e
    end
  end
  return spots, entries
end

---------------------------------------------------------------- drawing: world map
local wmd = { lines = {}, dots = {} }

local function Circle(parent, layer)
  local tex = parent:CreateTexture(nil, layer or "ARTWORK")
  local mask = parent:CreateMaskTexture()
  mask:SetAllPoints(tex)
  mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
  tex:AddMaskTexture(mask)
  return tex
end

local LINE = { 0.35, 0.85, 1, 0.8 }      -- the loop
local LINE_NEXT = { 1, 0.85, 0.2, 0.95 } -- the leg to the next stop

local function Color(t, c) t:SetColorTexture(c[1], c[2], c[3], c[4]) end

function ns.RouteWorld(canvas, mapID, cw, ch, unit, level)
  local route = Cfg() and Cfg().route and R.route
  local nLines, nDots = 0, 0
  if route and route.mapID == mapID and #route.stops >= 2 then
    local f = wmd.frame
    if not f then
      f = CreateFrame("Frame", nil, canvas)
      wmd.frame = f
    end
    f:SetParent(canvas)
    f:SetAllPoints(canvas)
    f:SetFrameLevel(max(1, (level or canvas:GetFrameLevel() + 200) - 1))
    f:Show()
    local stops, n = route.stops, #route.stops
    local prev = route.next and ((route.next - route.dir - 1) % n + 1)
    for i = 1, n do
      local a, b = stops[i], stops[i % n + 1]
      -- the leg into the next stop, in the direction you go
      local lead = route.next and ((route.dir == 1 and i == prev) or (route.dir == -1 and i == route.next))
      local color = lead and LINE_NEXT or LINE
      if f.CreateLine then
        nLines = nLines + 1
        local line = wmd.lines[nLines]
        if not line then line = f:CreateLine(nil, "ARTWORK"); wmd.lines[nLines] = line end
        line:SetThickness((lead and 4 or 3) * unit)
        Color(line, color)
        line:SetStartPoint("TOPLEFT", canvas, a.x * cw, -a.y * ch)
        line:SetEndPoint("TOPLEFT", canvas, b.x * cw, -b.y * ch)
        line:Show()
      else
        -- no line objects in this client: dots along the leg
        local len = sqrt(((b.x - a.x) * cw) ^ 2 + ((b.y - a.y) * ch) ^ 2)
        local step = 8 * unit
        for k = 0, floor(len / step) do
          if nDots >= 2000 then break end
          local t = len > 0 and k * step / len or 0
          nDots = nDots + 1
          local dot = wmd.dots[nDots]
          if not dot then dot = f:CreateTexture(nil, "ARTWORK"); wmd.dots[nDots] = dot end
          Color(dot, color)
          dot:SetSize(3 * unit, 3 * unit)
          dot:SetPoint("CENTER", canvas, "TOPLEFT", (a.x + (b.x - a.x) * t) * cw, -(a.y + (b.y - a.y) * t) * ch)
          dot:Show()
        end
      end
    end
    -- a halo behind the next stop's pin
    local st = route.next and stops[route.next]
    if st then
      wmd.halo = wmd.halo or Circle(f, "BACKGROUND")
      Color(wmd.halo, { 1, 0.85, 0.2, 0.7 })
      wmd.halo:SetSize(30 * unit, 30 * unit)
      wmd.halo:SetPoint("CENTER", canvas, "TOPLEFT", st.x * cw, -st.y * ch)
      wmd.halo:Show()
    elseif wmd.halo then
      wmd.halo:Hide()
    end
  elseif wmd.frame then
    wmd.frame:Hide()
  end
  for i = nLines + 1, #wmd.lines do wmd.lines[i]:Hide() end
  for i = nDots + 1, #wmd.dots do wmd.dots[i]:Hide() end
end

---------------------------------------------------------------- drawing: minimap
-- the route as dots every few yards along each leg near you, only inside the minimap's edge (a
-- round minimap cannot clip lines). Called by the minimap update with the same numbers it uses for
-- the pins; with no arguments, hides everything.
local mmd = { dots = {} }

function ns.RouteMinimap(mapID, px, py, w, h, s, c, scale, radius, edge)
  local route = mapID and Cfg().route and R.route
  local n = 0
  if route and route.mapID == mapID and #route.stops >= 2 then
    local f = mmd.frame
    if not f then
      f = CreateFrame("Frame", nil, Minimap)
      f:SetAllPoints(Minimap)
      mmd.frame = f
    end
    f:SetFrameLevel(Minimap:GetFrameLevel() + 4) -- under the pins
    f:Show()
    local stops, count = route.stops, #route.stops
    local step = radius / 14
    local reach = radius + step
    local prev = route.next and ((route.next - route.dir - 1) % count + 1)
    local function Place(dx, dy, color, size)
      if dx * dx + dy * dy > edge or n >= MAX_DOTS then return end
      n = n + 1
      local dot = mmd.dots[n]
      if not dot then dot = Circle(f, "OVERLAY"); mmd.dots[n] = dot end
      Color(dot, color)
      dot:SetSize(size, size)
      dot:SetPoint("CENTER", Minimap, "CENTER", (dx * c + dy * s) * scale, (dy * c - dx * s) * scale)
      dot:Show()
    end
    for i = 1, count do
      local a, b = stops[i], stops[i % count + 1]
      -- yards east and north of you
      local ax, ay = (a.x - px) * w, (py - a.y) * h
      local bx, by = (b.x - px) * w, (py - b.y) * h
      local vx, vy = bx - ax, by - ay
      local len2 = vx * vx + vy * vy
      -- the nearest point of the leg to you: skip legs that never come near the minimap
      local t = len2 > 0 and max(0, min(1, -(ax * vx + ay * vy) / len2)) or 0
      local cx, cy = ax + vx * t, ay + vy * t
      if cx * cx + cy * cy <= reach * reach then
        local lead = route.next and ((route.dir == 1 and i == prev) or (route.dir == -1 and i == route.next))
        local len = sqrt(len2)
        -- only the part of the leg within reach of you
        local half = sqrt(max(0, reach * reach - (cx * cx + cy * cy)))
        local from, to = 0, len
        if len > 0 then
          local mid = t * len
          from, to = max(0, mid - half), min(len, mid + half)
        end
        local k = math.ceil(from / step)
        while k * step <= to do
          local u = len > 0 and k * step / len or 0
          Place(ax + vx * u, ay + vy * u, lead and LINE_NEXT or LINE, lead and 4 or 3)
          k = k + 1
        end
      end
    end
    -- the next stop: a bigger dot
    local st = route.next and stops[route.next]
    if st then Place((st.x - px) * w, (py - st.y) * h, LINE_NEXT, 9) end
  elseif mmd.frame then
    mmd.frame:Hide()
  end
  for i = n + 1, #mmd.dots do mmd.dots[i]:Hide() end
end

local function Redraw()
  if ns.RedrawMap then ns.RedrawMap() end
  if ns.RedrawMinimap then ns.RedrawMinimap() end
end

---------------------------------------------------------------- waypoint
local function Waypoint(route)
  if not (C_Map and C_Map.SetUserWaypoint and UiMapPoint and UiMapPoint.CreateFromCoordinates) then return end
  local st = route and route.next and route.stops[route.next]
  if not st then return end
  if C_Map.CanSetUserWaypointOnMap and not C_Map.CanSetUserWaypointOnMap(route.mapID) then return end
  local ok = pcall(C_Map.SetUserWaypoint, UiMapPoint.CreateFromCoordinates(route.mapID, st.x, st.y))
  if ok then
    R.waypoint = true
    if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
      pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
    end
  end
end

local function ClearWaypoint()
  if R.waypoint and C_Map and C_Map.ClearUserWaypoint then pcall(C_Map.ClearUserWaypoint) end
  R.waypoint = nil
end

---------------------------------------------------------------- routes
local function Count(route)
  local c = { mine = 0, spotted = 0, shared = 0, imported = 0 }
  for _, st in ipairs(route.stops) do
    local best, rank = "imported", 0
    for _, e in ipairs(st.members or {}) do
      local src = Source(e.node)
      if SOURCE_RANK[src] > rank then best, rank = src, SOURCE_RANK[src] end
    end
    if best == "sharedSpot" then best = "shared" end
    c[best] = c[best] + 1
  end
  return c
end

local function Announce(route, how)
  if route.few then
    say(("route: only %d %s in %s, not enough for a loop. Show more with |cffffffff/sl show|r.")
      :format(route.spots or 0, (route.spots or 0) == 1 and "spot is shown" or "spots are shown", ZoneName(route.mapID)))
    return
  end
  local c = Count(route)
  local parts = {}
  if c.mine > 0 then parts[#parts + 1] = c.mine .. " found by you" end
  if c.spotted > 0 then parts[#parts + 1] = c.spotted .. " spotted" end
  if c.shared > 0 then parts[#parts + 1] = c.shared .. " by other players" end
  if c.imported > 0 then parts[#parts + 1] = c.imported .. " imported" end
  local aim = Cfg().routeMinutes and (", aiming for " .. Cfg().routeMinutes .. " min") or ""
  -- the time with every node up, when skipping the empty stops saves a good part of it
  local full = route.length / Speed() + HANDLE * route.nodes
  local upTo = full > route.seconds * 1.2 and (" (%.0f if every node is up)"):format(full / 60) or ""
  say(("%s in %s (%s%s): %d stops (%s), %d yards, about %.0f min a loop%s at %.0f yards a second, about %.0f nodes a loop (%.1f a minute).")
    :format(how, ZoneName(route.mapID), WhatText(), aim, #route.stops, table.concat(parts, ", "),
      floor(route.length + 0.5), route.seconds / 60, upTo, Speed(), route.nodes, route.rate))
  -- the loop was chosen for being near you; say so when a richer one further off was passed over
  local e = route.elsewhere
  if e then
    route.elsewhere = nil
    say(("this is the best loop near you. One about %.0f min away collects about %d%% more: |cffffffff/sl route anywhere|r for the best of the zone wherever it is.")
      :format(max(1, e.approach / Speed() / 60), floor((e.gain - 1) * 100 + 0.5)))
  end
end

-- match the spots on the map to the route's stops: each spot joins the nearest stop within 30
-- yards. Done when a route is made or loaded, and again whenever the dataset changes, so a stop
-- knows when a node there was just gathered.
local function Rematch(route)
  for _, st in ipairs(route.stops) do st.members = {} end
  if #route.stops == 0 then return end
  local list = ns.BuildList(route.mapID)
  local w, h = route.w, route.h
  for _, e in ipairs(list) do
    local best, bd = nil, 30 * 30
    for i, st in ipairs(route.stops) do
      local d = ((st.x - e.x) * w) ^ 2 + ((st.y - e.y) * h) ^ 2
      if d <= bd then best, bd = i, d end
    end
    if best then local m = route.stops[best].members; m[#m + 1] = e end
  end
end

local function Save(route)
  if route.few then return end
  local cfg = Cfg()
  cfg.routes = cfg.routes or {}
  local pts = {}
  for _, st in ipairs(route.stops) do
    pts[#pts + 1] = floor(st.x * 1e4 + 0.5) / 1e4
    pts[#pts + 1] = floor(st.y * 1e4 + 0.5) / 1e4
  end
  cfg.routes[route.mapID] = { sig = route.sig, pts = pts, length = route.length, seconds = route.seconds,
    nodes = route.nodes, rate = route.rate, dir = route.dir, made = route.made, px = route.px, py = route.py }
end

-- yards from a point of the map to the route's nearest stop
local function YardsToRoute(route, px, py)
  local best = huge
  for _, st in ipairs(route.stops) do
    local d = ((st.x - px) * route.w) ^ 2 + ((st.y - py) * route.h) ^ 2
    if d < best then best = d end
  end
  return sqrt(best)
end

-- the route is not where you are: more than FAR seconds' ride from its nearest stop. Unless it was
-- planned from about here, when it is the best there is from here and planning again gives it back.
local function Far(route, px, py)
  if not px or Cfg().routeAnywhere or not route.w or #route.stops == 0 then return false end
  local reach = FAR * Speed()
  if YardsToRoute(route, px, py) <= reach then return false end
  if route.px and ((route.px - px) * route.w) ^ 2 + ((route.py - py) * route.h) ^ 2 <= reach * reach then return false end
  return true
end

local function Load(mapID, sig, w, h)
  local saved = Cfg().routes and Cfg().routes[mapID]
  if not saved or saved.sig ~= sig or type(saved.pts) ~= "table" then return end
  local stops = {}
  for i = 1, #saved.pts - 1, 2 do stops[#stops + 1] = { x = saved.pts[i], y = saved.pts[i + 1], members = {} } end
  if #stops < 3 then return end
  local route = { mapID = mapID, sig = sig, w = w, h = h, stops = stops, dir = saved.dir == -1 and -1 or 1,
    length = saved.length or 0, seconds = saved.seconds or 0, nodes = saved.nodes or 0, rate = saved.rate or 0,
    made = saved.made, arrivals = 0, px = saved.px, py = saved.py }
  Rematch(route)
  return route
end

-- a solver result becomes the route on show
local function Install(res, job, provisional)
  local w, h = job.w, job.h
  local stops = {}
  for i, st in ipairs(res.stops) do
    local members = {}
    for _, j in ipairs(st.members) do members[#members + 1] = job.entries[j] end
    stops[i] = { x = st.x / w, y = st.y / h, members = members }
  end
  local old = R.route
  local route = { mapID = job.mapID, sig = job.sig, w = w, h = h, stops = stops, length = res.length,
    seconds = res.seconds, nodes = res.nodes, rate = res.rate, dir = 1, made = time(), arrivals = 0,
    provisional = provisional, few = res.few, spots = #job.spots, px = job.px, py = job.py,
    elsewhere = not provisional and res.elsewhere or nil }
  if old and old.mapID == job.mapID and old.dir then route.dir = old.dir end
  R.route = route
  R.dirty = false
  if not provisional then Save(route) end
  Redraw()
  return route
end

local runner = CreateFrame("Frame")
runner:Hide()

-- start planning for the zone you are in. kind: "plan" (shown when done) or "better" (only compared)
local function StartJob(mapID, sig, kind, how)
  local S = ns.RouteSolver
  if not (S and S.Plan) then
    say("the route solver (RouteSolver.lua) did not load. If you just installed this version, restart the game: a /reload does not load new files.")
    return
  end
  local w, h = ns.ZoneSize(mapID)
  if not w then
    R.route = { mapID = mapID, sig = sig, stops = {}, few = true, spots = 0, dir = 1 }
    return
  end
  local spots, entries = Spots(mapID, w, h)
  local job = { mapID = mapID, sig = sig, kind = kind, how = how, w = w, h = h, spots = spots, entries = entries }
  local params = { speed = Speed(), handle = HANDLE, minutes = Cfg().routeMinutes, seed = mapID,
    clock = debugprofilestop, slice = SLICE, budget = BUDGET, slow = SlowLegs(mapID, w, h),
    anywhere = Cfg().routeAnywhere }
  -- where you are: the route is planned from here
  local pmap, px, py = ns.PlayerPos()
  if pmap == mapID then
    job.px, job.py = px, py
    params.px, params.py = px * w, py * h
  end
  if kind == "plan" then
    params.progress = function(res) job.first = res end
  end
  local current = kind == "better" and R.route
  job.co = coroutine.create(function()
    local res = S.Plan(spots, params)
    if current then
      local pts = {}
      for i, st in ipairs(current.stops) do pts[i] = { x = st.x * w, y = st.y * h } end
      job.current = S.Evaluate(spots, pts, params)
    end
    return res
  end)
  R.job = job
  runner:Show()
end

local function Finish(job, res)
  if job.kind == "plan" then
    local route = Install(res, job, false)
    Announce(route, job.how or "route")
    Waypoint(route)
  else
    local route, cur = R.route, job.current
    if route and route.mapID == job.mapID and route.sig == job.sig and not route.toldBetter and cur
      and not res.few and res.rate >= cur.rate * BETTER then
      route.toldBetter = true
      say(("a better route is ready here: about %.1f nodes a minute against %.1f now. |cffffffff/sl route new|r to use it.")
        :format(res.rate, cur.rate))
    end
  end
end

runner:SetScript("OnUpdate", function(self)
  local job = R.job
  if not job then self:Hide(); return end
  local ok, res = coroutine.resume(job.co)
  if not ok then
    R.job = nil
    self:Hide()
    say("could not plan the route: " .. tostring(res))
    return
  end
  if job.first then
    -- the first full loop: show it while the better one is worked out
    local first = job.first
    job.first = nil
    if not first.few and #first.stops >= 3 then Install(first, job, true) end
  end
  if coroutine.status(job.co) == "dead" then
    R.job = nil
    self:Hide()
    Finish(job, res)
  end
end)

local function StopAll()
  R.job = nil
  runner:Hide()
  ClearWaypoint()
  Redraw()
end

-- the zone, the filters or the data changed (called from Refresh, and by the follow check)
function ns.RouteRefresh()
  R.dirty = true
  local cfg = Cfg()
  if not cfg then return end
  if not cfg.route then
    -- turned off some other way (/sl reset): stop planning, let go of the waypoint
    if R.job or R.waypoint then
      R.job = nil
      runner:Hide()
      ClearWaypoint()
    end
    return
  end
  local mapID = ns.PlayerPos()
  if not mapID then return end
  local sig = Signature()
  local route, job = R.route, R.job
  if job and job.kind == "plan" and job.mapID == mapID and job.sig == sig then return end
  if route and route.mapID == mapID and route.sig == sig and not route.provisional then return end
  -- a new zone, or other filters: a saved route if it fits, otherwise plan one now
  local w, h = ns.ZoneSize(mapID)
  local saved = w and Load(mapID, sig, w, h)
  -- a saved route on the other side of the zone is no use from here
  local _, px, py = ns.PlayerPos()
  if saved and Far(saved, px, py) then saved = nil end
  if saved then
    R.job = nil
    R.route = saved
    Announce(saved, "route")
    Waypoint(saved)
    Redraw()
  else
    StartJob(mapID, sig, "plan", route and route.mapID == mapID and "new route" or "route")
  end
end

---------------------------------------------------------------- following
local follow = { acc = 0, rejoin = 0 }

local function YardsTo(route, st, px, py)
  return sqrt(((st.x - px) * route.w) ^ 2 + ((st.y - py) * route.h) ^ 2)
end

local function Wrap(route, k) return (k - 1) % #route.stops + 1 end

-- a node at the stop was just gathered (by you): nothing to come back for yet
local function Spent(st, now)
  for _, e in ipairs(st.members or {}) do
    if ns.Depleted(e.node, now) then return true end
  end
  return false
end

-- from stop k on, the first one worth going to
local function NextFrom(route, k, now)
  for _ = 1, #route.stops do
    if not Spent(route.stops[k], now) then return k end
    k = Wrap(route, k + route.dir)
  end
  return k
end

-- the stop to head for from where you are: the nearest one; or the one after it, if you are already
-- past it on the way there (close to the line between the two, beyond the nearest)
local function NearestAhead(route, px, py, now)
  local best, bd = nil, huge
  for i, st in ipairs(route.stops) do
    local d = YardsTo(route, st, px, py)
    if d < bd then best, bd = i, d end
  end
  if not best then return end
  local nxt = Wrap(route, best + route.dir)
  local a, b = route.stops[best], route.stops[nxt]
  local ax, ay = (px - a.x) * route.w, (py - a.y) * route.h
  local bx, by = (b.x - a.x) * route.w, (b.y - a.y) * route.h
  local ab = sqrt(bx * bx + by * by)
  if ab > 0 and bd > ARRIVE then
    local along = (ax * bx + ay * by) / ab
    local off = math.abs(ax * by - ay * bx) / ab
    if along > ARRIVE and off <= ON_LEG then best = nxt end
  end
  return NextFrom(route, best, now)
end

local function SetNext(route, k)
  if route.next == k then return end
  route.next = k
  Waypoint(route)
  Redraw()
end

local function Arrive(route, k, now)
  -- the leg you just rode, timed: for finding legs that are slower than they look
  if route.last and route.lastAt and Wrap(route, route.last + route.dir) == k and not route.spoiled then
    NoteLeg(route, route.stops[route.last], route.stops[k], now - route.lastAt)
  end
  route.last, route.lastAt, route.spoiled = k, now, false
  route.arrivals = (route.arrivals or 0) + 1
  if route.arrivals >= #route.stops then
    -- a whole loop: plan again in the background and say if it would be clearly better
    route.arrivals = 0
    if not R.job and not route.toldBetter then StartJob(route.mapID, route.sig, "better") end
  end
end

local function Follow()
  local cfg = Cfg()
  if not cfg or not cfg.route then return end
  local mapID, px, py = ns.PlayerPos()
  if not mapID then return end
  local route = R.route
  if (not route or route.mapID ~= mapID) and not (R.job and R.job.mapID == mapID) then
    ns.RouteRefresh()
    return
  end
  if not route or route.mapID ~= mapID or route.few or #route.stops < 3 then return end

  -- your mount's speed, for how long a loop takes
  if IsMounted and IsMounted() and not (UnitOnTaxi and UnitOnTaxi("player")) then
    local speed = GetUnitSpeed("player")
    if speed and speed > (cfg.routeSpeed or RUN_SPEED) and speed <= 40 then cfg.routeSpeed = speed end
  end
  if (UnitOnTaxi and UnitOnTaxi("player")) or UnitIsDeadOrGhost("player") then
    route.spoiled = true
    return
  end
  if UnitAffectingCombat("player") then route.spoiled = true end
  if R.dirty then
    Rematch(route)
    R.dirty = false
  end

  local now = time()
  if not route.next then
    SetNext(route, NearestAhead(route, px, py, now))
    return
  end
  local st = route.stops[route.next]
  local d = YardsTo(route, st, px, py)
  if d <= ARRIVE then
    Arrive(route, route.next, now)
    SetNext(route, NextFrom(route, Wrap(route, route.next + route.dir), now))
    return
  end
  -- the next stop was gathered from where you stand, or by someone: skip it
  if Spent(st, now) then
    SetNext(route, NextFrom(route, route.next, now))
    return
  end
  -- left the loop: head for the nearest stop ahead instead
  follow.rejoin = follow.rejoin - FOLLOW_TICK
  if d > REJOIN and follow.rejoin <= 0 then
    follow.rejoin = REJOIN_EVERY
    -- a long way from all of it: the route is not replanned under you, but say once that it can be
    if not Far(route, px, py) then
      route.toldFar = nil
    elseif not route.toldFar and not R.job then
      route.toldFar = true
      say(("you are about %.0f min from the route. |cffffffff/sl route new|r plans one from where you are.")
        :format(max(1, YardsToRoute(route, px, py) / Speed() / 60)))
    end
    local k = NearestAhead(route, px, py, now)
    if k and k ~= route.next and YardsTo(route, route.stops[k], px, py) * 2 < d then
      route.last, route.lastAt = nil, nil
      SetNext(route, k)
    end
  end
end

local follower = CreateFrame("Frame")
follower:SetScript("OnUpdate", function(_, elapsed)
  follow.acc = follow.acc + elapsed
  if follow.acc < FOLLOW_TICK then return end
  follow.acc = 0
  Follow()
end)

---------------------------------------------------------------- /sl route
local HELP = "|cffffffff/sl route|r [on|off|new|auto|<minutes>|anywhere|safe|reverse|skip|forget]"

local function TurnOn()
  local cfg = Cfg()
  cfg.route = true
  local mapID = ns.PlayerPos()
  if not mapID then
    say("route on; it will be drawn once you are somewhere with a map.")
    return
  end
  local before = R.route
  ns.RouteRefresh()
  if R.job and R.job.kind == "plan" then
    say("planning a route for " .. WhatText() .. " in " .. ZoneName(mapID) .. "...")
  elseif R.route and R.route == before and R.route.mapID == mapID and Far(R.route, select(2, ns.PlayerPos())) then
    -- the route you had is a long way from here: plan one from where you are
    StartJob(mapID, Signature(), "plan", "new route")
    say("planning a route for " .. WhatText() .. " in " .. ZoneName(mapID) .. " from where you are...")
  elseif R.route and R.route == before and R.route.mapID == mapID then
    -- the route you had is still right: show it again
    Announce(R.route, "route")
    Waypoint(R.route)
    Redraw()
  end
end

local function TurnOff()
  Cfg().route = nil
  StopAll()
  say("route off.")
end

local function Replan()
  local cfg = Cfg()
  cfg.route = true
  local mapID = ns.PlayerPos()
  if not mapID then return end
  if cfg.routes then cfg.routes[mapID] = nil end
  R.route = nil
  StartJob(mapID, Signature(), "plan", "new route")
  say("planning a new route for " .. WhatText() .. " in " .. ZoneName(mapID) .. "...")
  Redraw()
end

ns.RegisterCommand("route", function(what)
  local cfg = Cfg()
  if what == "" then
    if cfg.route then TurnOff() else TurnOn() end
  elseif what == "on" then
    TurnOn()
  elseif what == "off" then
    TurnOff()
  elseif what == "new" then
    Replan()
  elseif what == "auto" then
    cfg.routeMinutes = nil
    say("route: the loop with the most nodes a minute.")
    TurnOn()
  elseif tonumber(what) then
    local m = floor(tonumber(what) + 0.5)
    if m < 2 or m > 120 then say("route length: 2 to 120 minutes.") return end
    cfg.routeMinutes = m
    say(("route: aiming for a loop of about %d minutes. |cffffffff/sl route auto|r for the best per minute."):format(m))
    TurnOn()
  elseif what == "safe" then
    cfg.routeSafe = not cfg.routeSafe or nil
    say(cfg.routeSafe and "route: only what is known, no detours to try untested spots."
      or "route: untested spots get a small bonus again, so the route learns which ones pay off.")
    TurnOn()
  elseif what == "reverse" then
    local route = R.route
    if not (cfg.route and route and #route.stops >= 3) then say("no route to turn round.") return end
    route.dir = -route.dir
    route.last, route.lastAt, route.arrivals = nil, nil, 0
    Save(route)
    local _, px, py = ns.PlayerPos()
    if px then route.next = nil; SetNext(route, NearestAhead(route, px, py, time())) end
    say("route: the other way round.")
  elseif what == "anywhere" then
    cfg.routeAnywhere = not cfg.routeAnywhere or nil
    say(cfg.routeAnywhere and "route: the best loop of the zone, wherever it is."
      or "route: the best loop near where you are.")
    TurnOn()
  elseif what == "forget" then
    local mapID = ns.PlayerPos()
    if not mapID then return end
    if cfg.routeSlow then cfg.routeSlow[mapID] = nil end
    if cfg.routeAvoid then cfg.routeAvoid[mapID] = nil end
    say("route: the slow legs and skipped stops learned in " .. ZoneName(mapID) .. " are forgotten.")
    if cfg.route then Replan() end
  elseif what == "skip" then
    local route = R.route
    if not (cfg.route and route and route.next) then say("no next stop to skip.") return end
    -- skipped without going there: a place you cannot reach or do not want. Twice, and new routes
    -- leave it out
    local st = route.stops[route.next]
    local _, px, py = ns.PlayerPos()
    if px and route.w and YardsTo(route, st, px, py) > ARRIVE then
      cfg.routeAvoid = cfg.routeAvoid or {}
      local zone = cfg.routeAvoid[route.mapID] or {}
      cfg.routeAvoid[route.mapID] = zone
      local key = floor(st.x * 1000 + 0.5) .. "," .. floor(st.y * 1000 + 0.5)
      local a = zone[key] or { x = st.x, y = st.y, n = 0 }
      zone[key] = a
      a.n = a.n + 1
      if a.n == AVOID_TIMES then
        say("route: that stop was skipped " .. AVOID_TIMES .. " times, so new routes here will leave it out (|cffffffff/sl route forget|r undoes this).")
      end
    end
    route.last, route.lastAt = nil, nil
    SetNext(route, NextFrom(route, Wrap(route, route.next + route.dir), time()))
  else
    say(HELP)
  end
end, HELP)
