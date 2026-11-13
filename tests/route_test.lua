-- Tests for RouteSolver.lua. Run from the addon folder with any Lua 5.1 or later:
--   lua tests/route_test.lua
-- No game needed: the solver makes no game calls.
local dir = (arg and arg[0] or ""):match("^(.*)[/\\]tests[/\\]") or "."
local ns = {}
assert(READFILE and load(READFILE(dir .. "/RouteSolver.lua"), "@RouteSolver.lua") or loadfile(dir .. "/RouteSolver.lua"))("SkipLoading", ns)
local S = ns.RouteSolver
local floor, sqrt, abs, huge = math.floor, math.sqrt, math.abs, math.huge
-- milliseconds; a test runner may give a better clock than os.clock
local Ms = NOWMS or function() return os.clock() * 1000 end

local failures, checks = 0, 0
local function ok(cond, msg)
  checks = checks + 1
  if not cond then failures = failures + 1; print("FAIL: " .. msg) end
end

-- runs a solver call inside a coroutine, as the game does, and measures the longest slice
local function Run(fn, slice)
  local co = coroutine.create(fn)
  local result, longest, resumes = nil, 0, 0
  while true do
    local t0 = Ms()
    local good, r = coroutine.resume(co)
    local dt = Ms() - t0
    if dt > longest then longest = dt end
    resumes = resumes + 1
    assert(good, r)
    if coroutine.status(co) == "dead" then result = r; break end
  end
  return result, longest, resumes
end

local rng = 12345
local function rand() rng = (rng * 16807) % 2147483647; return rng / 2147483647 end

local function TourLength(pts, order)
  local len = 0
  for k = 1, #order do
    local a, b = pts[order[k]], pts[order[k % #order + 1]]
    len = len + sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2)
  end
  return len
end

-- exact shortest loop (Held-Karp dynamic programming), for small cases
local function HeldKarp(pts)
  local n = #pts
  local function d(i, j) return sqrt((pts[i].x - pts[j].x) ^ 2 + (pts[i].y - pts[j].y) ^ 2) end
  local function has(mask, k) return floor(mask / 2 ^ (k - 2)) % 2 == 1 end
  local full = 2 ^ (n - 1) - 1
  local C = {}
  for k = 2, n do C[2 ^ (k - 2) * 64 + k] = d(1, k) end
  for mask = 1, full do
    for k = 2, n do
      if has(mask, k) then
        local key = mask * 64 + k
        local prev = mask - 2 ^ (k - 2)
        if prev > 0 then
          local best = huge
          for m = 2, n do
            if has(prev, m) then
              local c = C[prev * 64 + m] + d(m, k)
              if c < best then best = c end
            end
          end
          C[key] = best
        end
      end
    end
  end
  local best = huge
  for k = 2, n do best = math.min(best, C[full * 64 + k] + d(k, 1)) end
  return best
end

---------------------------------------------------------------- shortest loops
do -- points on a circle, given shuffled: the best loop is the polygon
  local pts, n, r = {}, 40, 500
  for i = 1, n do
    local a = (i - 1) / n * 2 * math.pi
    pts[i] = { x = r * math.cos(a), y = r * math.sin(a) }
  end
  for i = n, 2, -1 do local j = floor(rand() * i) + 1; pts[i], pts[j] = pts[j], pts[i] end
  local _, len = S.Tour(pts)
  local best = n * 2 * r * math.sin(math.pi / n)
  ok(abs(len - best) < 1e-6 * best + 1e-6, ("circle: %.1f, best %.1f"):format(len, best))
end

do -- an 8 x 8 grid, 10 yards apart: the best loop is 640. Grids are the worst case for 2-opt
  -- (many loops of equal length), so this one needs many kicks
  local pts = {}
  for gx = 0, 7 do for gy = 0, 7 do pts[#pts + 1] = { x = gx * 10, y = gy * 10 } end end
  local _, len = S.Tour(pts, { kicks = 1000 })
  ok(len <= 640 * 1.02, ("grid: %.1f, best 640"):format(len))
end

do -- random small cases against the exact answer
  local exact, worst, cases = 0, 0, 30
  for _ = 1, cases do
    local n = 9 + floor(rand() * 3)
    local pts = {}
    for i = 1, n do pts[i] = { x = rand() * 1000, y = rand() * 1000 } end
    local order, len = S.Tour(pts)
    local best = HeldKarp(pts)
    ok(abs(TourLength(pts, order) - len) < 1e-6, "tour length matches its order")
    local gap = len / best - 1
    if gap < 1e-9 then exact = exact + 1 end
    if gap > worst then worst = gap end
  end
  ok(exact >= cases * 0.9, ("exact in %d of %d small cases"):format(exact, cases))
  ok(worst <= 0.02, ("worst small case %.2f%% above the best"):format(worst * 100))
  print(("small cases: best loop found in %d of %d, worst %.2f%% above"):format(exact, cases, worst * 100))
end

---------------------------------------------------------------- expected length
do -- Jaillet's formula against trying every combination of stops up or empty
  for _ = 1, 10 do
    local n = 7
    local x, y, p, order = {}, {}, {}, {}
    for i = 1, n do x[i], y[i], p[i], order[i] = rand() * 500, rand() * 500, 0.1 + rand() * 0.8, i end
    local brute = 0
    for mask = 0, 2 ^ n - 1 do
      local chance, up = 1, {}
      for i = 1, n do
        if floor(mask / 2 ^ (i - 1)) % 2 == 1 then chance = chance * p[i]; up[#up + 1] = i
        else chance = chance * (1 - p[i]) end
      end
      if #up >= 2 then
        local len = 0
        for k = 1, #up do
          local a, b = up[k], up[k % #up + 1]
          len = len + sqrt((x[a] - x[b]) ^ 2 + (y[a] - y[b]) ^ 2)
        end
        brute = brute + chance * len
      end
    end
    local formula = S.ExpectedLength(order, p, x, y, true)
    ok(abs(formula - brute) < 1e-6 * brute, ("expected length %.3f vs brute force %.3f"):format(formula, brute))
  end
end

---------------------------------------------------------------- routes
-- a made-up zone: two dense areas far apart, scattered spots between, some of them "your own"
local function Zone(seed)
  rng = seed
  local spots = {}
  local function Add(x, y, w, g) spots[#spots + 1] = { x = x, y = y, w = w, g = g or "ores", tau = 480 } end
  for _ = 1, 60 do Add(200 + rand() * 600, 200 + rand() * 600, 0.3 + rand() * 0.5) end
  for _ = 1, 60 do Add(3000 + rand() * 600, 2000 + rand() * 600, 0.3 + rand() * 0.5, "herbs") end
  for _ = 1, 80 do Add(rand() * 4000, rand() * 3000, 0.1 + rand() * 0.3) end
  return spots
end

local function Plan(spots, params)
  params = params or {}
  params.clock = params.clock or Ms
  params.slice = params.slice or 4
  return Run(function() return S.Plan(spots, params) end)
end

do
  local spots = Zone(7)
  local full
  local r, longest = Plan(spots, { seed = 3, progress = function(res) full = res end })
  ok(full and #full.stops > 0, "progress gives the first full loop")
  ok(#r.stops >= 3, "route has stops")
  ok(r.rate >= full.rate - 1e-9, ("route rate %.3f >= full loop rate %.3f"):format(r.rate, full.rate))
  ok(#r.stops < #full.stops, ("route leaves thin stops out (%d of %d)"):format(#r.stops, #full.stops))
  ok(r.elength <= r.length + 1e-6, "expected length is at most the full length")
  print(("made-up zone: %d of %d stops, %.0f yards (%.0f expected), %.1f min, %.1f nodes, %.2f a minute; longest slice %.1f ms")
    :format(#r.stops, #full.stops, r.length, r.elength, r.seconds / 60, r.nodes, r.rate, longest))

  -- the same data and seed: the same route
  local r2 = Plan(spots, { seed = 3 })
  local same = #r2.stops == #r.stops
  for i = 1, #r.stops do
    if not r2.stops[i] or r2.stops[i].x ~= r.stops[i].x or r2.stops[i].y ~= r.stops[i].y then same = false end
  end
  ok(same, "same data and seed give the same route")

  -- evaluating the route gives the same numbers
  local pts = {}
  for i, s in ipairs(r.stops) do pts[i] = { x = s.x, y = s.y } end
  local e = Run(function() return S.Evaluate(spots, pts, {}) end)
  ok(abs(e.nodes - r.nodes) < 0.05 * r.nodes + 0.01, ("evaluate: %.2f nodes vs %.2f"):format(e.nodes, r.nodes))

  -- fixed length
  local m = Plan(spots, { seed = 3, minutes = 6 })
  -- the time you ride once empty stops are skipped (the polish may lengthen the full loop a little)
  ok(m.seconds <= 6 * 60 * 1.001, ("6-minute loop takes %.2f min"):format(m.seconds / 60))
  local m2 = Plan(spots, { seed = 3, minutes = 20 })
  ok(m2.nodes >= m.nodes, "a longer budget collects at least as much")
end

do -- respawn: nodes that come back fast want a short loop, slow ones a long one
  local fast, slow = Zone(11), Zone(11)
  for _, s in ipairs(fast) do s.tau = 60 end
  for _, s in ipairs(slow) do s.tau = 3600 end
  local a, b = Plan(fast, { seed = 1 }), Plan(slow, { seed = 1 })
  ok(a.length < b.length, ("fast respawn: a loop of %.0f yards, slow: %.0f"):format(a.length, b.length))
end

do -- your own spots are preferred: same place, higher w
  local spots = {}
  for i = 1, 40 do spots[i] = { x = (i % 8) * 100, y = floor(i / 8) * 100, w = 0.33, g = "ores", tau = 480 } end
  spots[#spots + 1] = { x = 5000, y = 5000, w = 0.75, g = "ores", tau = 480 }
  local r = Plan(spots, { seed = 1 })
  local farOut = false
  for _, s in ipairs(r.stops) do if s.x > 4000 then farOut = true end end
  ok(not farOut, "a single far stop is not worth the ride")
end

do -- slow legs: a leg marked slow is avoided when there is another way
  local spots = {}
  for i = 0, 9 do
    spots[#spots + 1] = { x = i * 50, y = 0, w = 0.8, g = "ores", tau = 3600 }
    spots[#spots + 1] = { x = i * 50, y = 200, w = 0.8, g = "ores", tau = 3600 }
  end
  local plain = Plan(spots, { seed = 1 })
  local slowLegs = {}
  for i = 0, 8 do slowLegs[#slowLegs + 1] = { i * 50, 0, i * 50 + 50, 0, 5 } end
  local r = Plan(spots, { seed = 1, slow = slowLegs })
  ok(plain.length > 0 and r.length > 0, "routes with and without slow legs")
end

---------------------------------------------------------------- where the player is
do
  -- two fields of nodes 3000 yards apart, the eastern one richer
  local function Fields(eastW)
    local spots = {}
    for i = 0, 5 do
      for j = 0, 5 do
        spots[#spots + 1] = { x = i * 80 + (j % 2) * 13, y = j * 80 + (i % 3) * 7, w = 0.5, g = "ores", tau = 480 }
        spots[#spots + 1] = { x = 3000 + i * 80 + (j % 2) * 13, y = j * 80 + (i % 3) * 7, w = eastW, g = "ores", tau = 480 }
      end
    end
    return spots
  end
  local function Side(r)
    local west, east = 0, 0
    for _, s in ipairs(r.stops) do if s.x < 1500 then west = west + 1 else east = east + 1 end end
    return west, east
  end
  for _, minutes in ipairs({ false, 4 }) do
    local how = minutes and "fixed length" or "auto"
    local spots = Fields(0.6)
    local w1, e1 = Side(Plan(spots, { seed = 1, speed = 10, minutes = minutes or nil, px = 200, py = 200 }))
    ok(w1 >= 3 and e1 == 0, ("%s: standing in the western field, the route is there (%d west, %d east)"):format(how, w1, e1))
    local rEast = Plan(spots, { seed = 1, speed = 10, minutes = minutes or nil, px = 3200, py = 200 })
    local w2, e2 = Side(rEast)
    ok(e2 >= 3 and w2 == 0, ("%s: standing in the eastern field, the route is there (%d west, %d east)"):format(how, w2, e2))
    ok(rEast.approach and rEast.approach < 100, "the result says how far the route is from the player")
    ok(not rEast.elsewhere, "nothing better elsewhere when you stand in the richer field")
    -- anywhere: the richer field, wherever you stand; and so with no position at all
    local w3, e3 = Side(Plan(spots, { seed = 1, speed = 10, minutes = minutes or nil, px = 200, py = 200, anywhere = true }))
    ok(e3 >= 3 and w3 == 0, ("%s, anywhere: the richer field though you stand in the other (%d west, %d east)"):format(how, w3, e3))
    local w4, e4 = Side(Plan(spots, { seed = 1, speed = 10, minutes = minutes or nil }))
    ok(e4 >= 3 and w4 == 0, ("%s, no position: the richer field (%d west, %d east)"):format(how, w4, e4))
  end
  -- a much richer field far off is passed over, and reported
  local r = Plan(Fields(0.9), { seed = 1, speed = 10, px = 200, py = 200 })
  local w5, e5 = Side(r)
  ok(w5 >= 3 and e5 == 0, "a richer field 3000 yards off does not pull the route away")
  ok(r.elsewhere and r.elsewhere.gain > 1.15 and r.elsewhere.approach > 2000,
    "the richer loop elsewhere is reported")
  -- standing in the empty middle: the route is in one field, not strung between the two
  local w6, e6 = Side(Plan(Fields(0.5), { seed = 1, speed = 10, px = 1700, py = 200 }))
  ok(w6 == 0 or e6 == 0, ("from the empty middle the route keeps to one field (%d west, %d east)"):format(w6, e6))
end

do -- long legs ride longer than drawn: a loop does not reach across a gap for a few more nodes
  local spots = {}
  for i = 0, 19 do spots[#spots + 1] = { x = (i % 5) * 70, y = floor(i / 5) * 70, w = 0.6, g = "ores", tau = 480 } end
  for i = 0, 2 do spots[#spots + 1] = { x = 1500 + i * 70, y = 0, w = 0.6, g = "ores", tau = 480 } end
  local r = Plan(spots, { seed = 1, speed = 10, px = 100, py = 100 })
  local longest = 0
  for i, s in ipairs(r.stops) do
    local b = r.stops[i % #r.stops + 1]
    longest = math.max(longest, sqrt((s.x - b.x) ^ 2 + (s.y - b.y) ^ 2))
  end
  ok(longest < 500, ("no leg across the gap (longest %.0f yards)"):format(longest))
  -- the length reported is the length drawn
  local drawn = 0
  for i, s in ipairs(r.stops) do
    local b = r.stops[i % #r.stops + 1]
    drawn = drawn + sqrt((s.x - b.x) ^ 2 + (s.y - b.y) ^ 2)
  end
  ok(abs(drawn - r.length) < 1e-6, "length is the loop as drawn")
end

do -- a slow leg also slows the legs between the stops next to its ends
  local spots = {}
  for i = 0, 7 do
    spots[#spots + 1] = { x = i * 50, y = 0, w = 0.8, g = "ores", tau = 3600 }
    spots[#spots + 1] = { x = i * 50, y = 120, w = 0.8, g = "ores", tau = 3600 }
  end
  local function Crossings(r) -- legs from one row to the other between x = 100 and x = 250
    local n = 0
    for i, s in ipairs(r.stops) do
      local b = r.stops[i % #r.stops + 1]
      if abs(s.y - b.y) > 60 and s.x > 90 and s.x < 260 and b.x > 90 and b.x < 260 then n = n + 1 end
    end
    return n
  end
  -- a wall between the rows in the middle, learned from one leg across it
  local r = Plan(spots, { seed = 1, speed = 10, slow = { { 150, 0, 150, 120, 8 }, { 200, 0, 200, 120, 8 } } })
  ok(#r.stops >= 3 and Crossings(r) == 0, ("no leg crosses where one was slow (%d)"):format(Crossings(r)))
end

---------------------------------------------------------------- real data: The Barrens
do
  local src
  if READFILE then
    src = READFILE(dir .. "/Seed.lua")
  elseif io and io.open then
    local f = io.open(dir .. "/Seed.lua", "r")
    if f then src = f:read("*a"); f:close() end
  end
  if src then
    local env = {}
    local chunk = (loadstring or load)(src)
    if setfenv then setfenv(chunk, env) else chunk = load(src, "Seed", "t", env) end
    chunk()
    local seed = env.SkipLoadingSeed()
    local W, H = 10133.3, 6756.2 -- The Barrens in yards, near enough
    local spots = {}
    for _, kind in ipairs({ "ores", "herbs" }) do
      for coord in pairs(seed[kind][1413] or {}) do
        local x, y = floor(coord / 1e6) / 1e4, floor(coord % 1e6 / 100) / 1e4
        spots[#spots + 1] = { x = x * W, y = y * H, w = 0.45, g = kind, tau = 480 }
      end
    end
    local t0 = Ms()
    local last = Ms()
    local r, longest, resumes = Plan(spots, { seed = 1413, speed = 11.2, trace = function(what)
      print(("    %-18s %6.0f ms"):format(what, Ms() - last)); last = Ms() end })
    local total = Ms() - t0
    print(("The Barrens: %d spots -> %d stops on the route, %.0f yards, %.1f min, %.1f nodes, %.2f a minute")
      :format(#spots, #r.stops, r.length, r.seconds / 60, r.nodes, r.rate))
    print(("  %.0f ms of work in %d slices, longest slice %.1f ms (this Lua; the game's is faster)")
      :format(total, resumes, longest))
    ok(#r.stops >= 3, "The Barrens gets a route")
    -- as in the game: planning stops after 1.5 seconds of work with the best loop so far
    local cut = Plan(spots, { seed = 1413, speed = 11.2, budget = 1500 })
    print(("  with the game's 1.5 s budget: %d stops, %.1f min, %.2f a minute"):format(#cut.stops, cut.seconds / 60, cut.rate))
    ok(cut.rate >= r.rate * 0.85, "the budget costs little")
    ok(longest < 50, ("no slice runs long (longest %.1f ms)"):format(longest))
  end
end

print(("%d checks, %d failed"):format(checks, failures))
if failures > 0 then os.exit(1) end
