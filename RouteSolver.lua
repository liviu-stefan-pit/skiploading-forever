-- The route solver: pure Lua, no game calls, so the test script can run it as it is. ROUTES.md
-- explains the method; in short:
--   spots -> stops      spots close together become one stop (Group)
--   starting loop       random insertion, then 2-opt and Or-opt with neighbour lists, then kicks
--   where you are       loops are grown from the stops by the player as well as from the richest
--                       areas, and a loop is worth less the longer the ride to it
--   Dinkelbach          the loop with the most expected nodes per minute: repeatedly solve
--                       "value - rate * time" (a prize-collecting tour) and update the rate
--   polish              2-opt again, on the expected length of the loop when empty stops are skipped
--                       (the probabilistic TSP's a priori tour, Jaillet's formula)
-- Everything that can take long calls Tick(), which yields the running coroutine once the frame's
-- time slice is used up, so the caller decides how many milliseconds it gets per frame.
local _, ns = ...
local floor, sqrt, exp, abs, min, max, huge = math.floor, math.sqrt, math.exp, math.abs, math.min, math.max, math.huge
local yield = coroutine.yield

local S = {}

local GROUP = 30       -- yards: spots this close to a stop's first spot join that stop
local NEIGHBOURS = 10  -- how many nearest stops each stop looks at for moves
local MIN_VALUE = 0.05 -- stops worth less than this (nodes, at full respawn) are left out
local EPS = 1e-7
local CHAIN = 12       -- the expected-length sums look at most this many stops ahead ...
local CHAIN_EPS = 0.01 -- ... and stop once the chance that all stops in between are empty is below this
local KICK_SPAN = 30   -- the double bridge cuts the loop within this many stops of its first cut
local SEEDS = 3        -- loops grown from this many seed stops in each Dinkelbach round
local SEED_REACH = 200 -- yards: a seed is the stop with the most value within this distance
local ROUNDS = 8       -- at most this many Dinkelbach rounds ...
local SETTLE = 0.02    -- ... stopping once the rate and the loop time change by less than this
local DETOUR = 0.5       -- a long leg rides up to this much longer than its straight line (there is no
local DETOUR_REACH = 400 -- terrain to look at, and long lines cross more of it); half of it at this many yards
local SLOW_REACH = 60    -- yards: a slow leg also slows the legs between stops this near its two ends
local HORIZON = 600      -- seconds: the ride to a loop is weighed against this much farming on it
local SHORTER = 0.15     -- a loop as long as the cap must be this much better a minute than a very short one
local POLISH_SLACK = 1.03 -- the polish for skipped stops may lengthen the loop as ridden by this much
local ELSEWHERE = 1.15   -- a loop further off this much better a minute than the one chosen is reported
local NEAR_STOPS = 8     -- the seed by the player is the richest of this many stops nearest to them
local NEAR_RIDE = 120    -- seconds: a second seed is the richest stop within this long a ride

---------------------------------------------------------------- time slicing
-- milliseconds. The game has debugprofilestop and may have no os library at all, so nothing here
-- may touch os while the file loads
local function DefaultClock()
  if debugprofilestop then return debugprofilestop() end
  if os and os.clock then return os.clock() * 1000 end
  return 0
end
local clock, slice, budget, sliceStart, used, ops = DefaultClock, 4, huge, 0, 0, 0
local function Now() return clock() end

-- called often from the inner loops; yields when the slice is used up
local function Tick()
  ops = ops + 1
  if ops < 16 then return end
  ops = 0
  local t = Now()
  if t - sliceStart >= slice then
    used = used + (t - sliceStart)
    yield()
    sliceStart = Now()
  end
end

-- true once the whole job has used its CPU budget: optional work (kicks, more rounds) stops
local function OverBudget() return used + (Now() - sliceStart) >= budget end

---------------------------------------------------------------- random numbers
-- a small fixed generator, so the same data and seed always give the same route
local rngState = 1
local function Seed(n) rngState = (floor(abs(n or 1)) % 2147483646) + 1 end
local function Random(n) -- 1..n
  rngState = (rngState * 16807) % 2147483647
  return (rngState % n) + 1
end

---------------------------------------------------------------- stops
-- spots: { x, y (yards), w (chance it pays off times how much it is wanted, 0..1), g (its kind),
-- tau (seconds it takes to come back) }. Returns stops { x, y, members = { spot index ... } }.
-- Highest value first, so a stop is centred on its best spot (your own nodes before imported ones).
local function Group(spots, radius)
  radius = radius or GROUP
  local order = {}
  for i = 1, #spots do order[i] = i end
  table.sort(order, function(a, b)
    if spots[a].w ~= spots[b].w then return spots[a].w > spots[b].w end
    return a < b
  end)
  local grid, cell = {}, radius
  local function Key(cx, cy) return cx * 100000 + cy end
  for i = 1, #spots do
    local s = spots[i]
    local k = Key(floor(s.x / cell), floor(s.y / cell))
    local list = grid[k]
    if not list then list = {}; grid[k] = list end
    list[#list + 1] = i
  end
  local taken, stops, r2 = {}, {}, radius * radius
  for _, lead in ipairs(order) do
    if not taken[lead] then
      local s = spots[lead]
      local members = { lead }
      taken[lead] = true
      local cx, cy = floor(s.x / cell), floor(s.y / cell)
      for gx = cx - 1, cx + 1 do
        for gy = cy - 1, cy + 1 do
          local list = grid[Key(gx, gy)]
          if list then
            for _, j in ipairs(list) do
              if not taken[j] then
                local o = spots[j]
                if (o.x - s.x) ^ 2 + (o.y - s.y) ^ 2 <= r2 then
                  taken[j] = true
                  members[#members + 1] = j
                end
              end
            end
          end
        end
      end
      -- the stop sits at the value-weighted middle of its spots
      local sx, sy, sw = 0, 0, 0
      for _, j in ipairs(members) do
        local o = spots[j]
        local w = o.w + 0.01
        sx, sy, sw = sx + o.x * w, sy + o.y * w, sw + w
      end
      stops[#stops + 1] = { x = sx / sw, y = sy / sw, members = members }
    end
  end
  return stops
end
S.Group = Group

-- a stop's expected nodes and the chance anything is up there, for a loop of T seconds (nil:
-- everything has had time to come back). Within one kind, nearby spots are alternatives: at least
-- one of them is up. Different kinds spawn independently and add up.
local function StopValue(spots, stop, T)
  local none, groups = 1, {}
  for _, j in ipairs(stop.members) do
    local s = spots[j]
    local f = T and (1 - exp(-T / s.tau)) or 1
    local p = s.w * f
    none = none * (1 - p)
    groups[s.g] = (groups[s.g] or 1) * (1 - p)
  end
  local v = 0
  for _, left in pairs(groups) do v = v + (1 - left) end
  return v, 1 - none
end

---------------------------------------------------------------- the problem being solved
-- X, Y: stop positions; V, P: value and chance up at the current loop time; PI: profit in the
-- prize-collecting step; NB: neighbour lists; PEN: slow legs (pair key -> factor); DET: how much
-- longer than its straight line a long leg rides (nil: straight lines)
local X, Y, V, P, PI, NB, PEN, N, DET

-- the yards a straight line of d yards is taken to ride: short hops between neighbouring nodes
-- nearly as drawn, long legs up to DET longer. It also makes one long leg cost more than the same
-- way through stops in between, which are places somebody is known to have stood.
local function Ride(d)
  if DET then return d * (1 + DET * d / (d + DETOUR_REACH)) end
  return d
end

local function D(i, j)
  local d = sqrt((X[i] - X[j]) ^ 2 + (Y[i] - Y[j]) ^ 2)
  if DET then d = d * (1 + DET * d / (d + DETOUR_REACH)) end
  if PEN then
    local f = PEN[i * 65536 + j]
    if f then d = d * f end
  end
  return d
end

-- each stop's NEIGHBOURS nearest stops, nearest first. A grid of cells holding about two stops
-- each: a stop looks at its own cell, then ring after ring of cells round it, until it has its
-- neighbours and the next ring is too far off to hold a nearer one.
local function BuildNeighbours()
  NB = {}
  local k = min(NEIGHBOURS, N - 1)
  local x0, x1, y0, y1 = huge, -huge, huge, -huge
  for i = 1, N do
    x0, x1, y0, y1 = min(x0, X[i]), max(x1, X[i]), min(y0, Y[i]), max(y1, Y[i])
  end
  local w, h = x1 - x0, y1 - y0
  local cell = sqrt(w * h / N * 2)
  if cell < 1 then cell = max(1, max(w, h) / N * 2) end
  local nx, ny = floor(w / cell) + 1, floor(h / cell) + 1
  local grid, CX, CY = {}, {}, {}
  for i = 1, N do
    local cx, cy = floor((X[i] - x0) / cell), floor((Y[i] - y0) / cell)
    CX[i], CY[i] = cx, cy
    local key = cx + cy * nx
    local list = grid[key]
    if not list then list = {}; grid[key] = list end
    list[#list + 1] = i
  end
  local rings = max(nx, ny)
  for i = 1, N do
    local best, bd = {}, {}
    local xi, yi, cx, cy = X[i], Y[i], CX[i], CY[i]
    local function Cell(gx, gy)
      if gx < 0 or gy < 0 or gx >= nx or gy >= ny then return end
      local list = grid[gx + gy * nx]
      if not list then return end
      for n = 1, #list do
        local j = list[n]
        if j ~= i then
          local d = (xi - X[j]) ^ 2 + (yi - Y[j]) ^ 2
          local m = #best
          -- equal distances: the lower stop first, so the order does not depend on the grid
          if m < k or d < bd[m] or (d == bd[m] and j < best[m]) then
            local p = m < k and m + 1 or m
            while p > 1 and (bd[p - 1] > d or (bd[p - 1] == d and best[p - 1] > j)) do
              best[p], bd[p] = best[p - 1], bd[p - 1]
              p = p - 1
            end
            best[p], bd[p] = j, d
          end
        end
      end
    end
    for r = 0, rings do
      if r == 0 then
        Cell(cx, cy)
      else
        for g = -r, r do
          Cell(cx + g, cy - r); Cell(cx + g, cy + r)
        end
        for g = -r + 1, r - 1 do
          Cell(cx - r, cy + g); Cell(cx + r, cy + g)
        end
      end
      Tick()
      -- anything in the next ring is at least r cells away
      if #best >= k and bd[k] <= (r * cell) ^ 2 then break end
    end
    NB[i] = best
  end
end

---------------------------------------------------------------- loops
-- a loop is { t = { stop ... }, pos = { [stop] = index } }; cyclic, any length >= 1
local function NewLoop(list)
  local L = { t = {}, pos = {} }
  for i, s in ipairs(list) do L.t[i], L.pos[s] = s, i end
  return L
end
local function CopyLoop(L) Tick(); return NewLoop(L.t) end
local function Succ(L, i) local m = #L.t; return L.t[L.pos[i] % m + 1] end
local function Pred(L, i) local m = #L.t; return L.t[(L.pos[i] - 2) % m + 1] end

local function Length(L)
  local t, m, len = L.t, #L.t, 0
  if m < 2 then return 0 end
  for k = 1, m do len = len + D(t[k], t[k % m + 1]); Tick() end
  return len
end

-- the loop as drawn: straight lines, in plain yards
local function DrawnLength(L)
  local t, m, len = L.t, #L.t, 0
  if m < 2 then return 0 end
  for k = 1, m do
    local i, j = t[k], t[k % m + 1]
    len = len + sqrt((X[i] - X[j]) ^ 2 + (Y[i] - Y[j]) ^ 2)
  end
  return len
end

-- reverses the stops from index a to index b, going forward (cyclic); reverses the shorter side,
-- which gives the same loop
local function Reverse(L, a, b)
  local t, pos, m = L.t, L.pos, #L.t
  local len = (b - a) % m + 1
  if len * 2 > m then
    a, b = b % m + 1, (a - 2) % m + 1
    len = m - len
  end
  for _ = 1, floor(len / 2) do
    local x, y = t[a], t[b]
    t[a], t[b] = y, x
    pos[y], pos[x] = a, b
    a, b = a % m + 1, (b - 2) % m + 1
  end
end

local function Rebuild(L, list)
  local t, pos = L.t, L.pos
  for k in pairs(pos) do pos[k] = nil end
  for k = #t, 1, -1 do t[k] = nil end
  for i, s in ipairs(list) do t[i], pos[s] = s, i; Tick() end
end

local function Remove(L, s)
  local list, n = {}, 0
  for _, x in ipairs(L.t) do
    if x ~= s then n = n + 1; list[n] = x end
  end
  Rebuild(L, list)
end

local function InsertAfter(L, u, s)
  local list, n = {}, 0
  for _, x in ipairs(L.t) do
    n = n + 1; list[n] = x
    if x == u then n = n + 1; list[n] = s end
  end
  Rebuild(L, list)
end

-- the cheapest place to put stop k: between one of its neighbours in the loop and that one's
-- successor or predecessor; all edges when no neighbour is on the loop and `anywhere`.
-- Returns the stop to put it after and the added length.
local function BestInsert(L, k, anywhere)
  local m = #L.t
  if m == 0 then return nil, 0 end
  if m == 1 then return L.t[1], 2 * D(L.t[1], k) end
  local bestU, bestC
  local function Try(u, v)
    local c = D(u, k) + D(k, v) - D(u, v)
    if not bestC or c < bestC then bestU, bestC = u, c end
  end
  for _, u in ipairs(NB[k]) do
    if L.pos[u] then
      Try(u, Succ(L, u))
      Try(Pred(L, u), u)
    end
  end
  if not bestU and anywhere then
    for i = 1, m do Try(L.t[i], L.t[i % m + 1]) end
  end
  return bestU, bestC
end

---------------------------------------------------------------- local search
-- moves that only make the loop shorter: 2-opt and Or-opt over neighbour lists, with a queue of
-- stops to look at (the "don't-look bits": a stop whose surroundings did not change is skipped)
local function TwoOptAt(L, a)
  local m = #L.t
  if m < 4 then return false end
  for dir = 1, 2 do
    local b = dir == 1 and Succ(L, a) or Pred(L, a)
    local dab = D(a, b)
    for _, c in ipairs(NB[a]) do
      Tick()
      if L.pos[c] and c ~= b then
        local d = dir == 1 and Succ(L, c) or Pred(L, c)
        if d ~= a then
          local delta = D(a, c) + D(b, d) - dab - D(c, d)
          if delta < -EPS then
            if dir == 1 then Reverse(L, L.pos[b], L.pos[c]) -- a b ... c d  ->  a c ... b d
            else Reverse(L, L.pos[c], L.pos[b]) end          -- d c ... b a  ->  d b ... c a
            return true, b, c, d
          end
        end
      end
    end
  end
  return false
end

-- moves a run of 1 to 3 stops starting at `a` to a better place, either way round
local function OrOptAt(L, a)
  local m = #L.t
  for len = 1, 3 do
    if m < len + 3 then return false end
    local seg, inSeg = {}, {}
    local s = a
    for k = 1, len do seg[k] = s; inSeg[s] = true; s = Succ(L, s) end
    local first, last = seg[1], seg[len]
    local p, nx = Pred(L, first), Succ(L, last)
    local removeGain = D(p, first) + D(last, nx) - D(p, nx)
    if removeGain > EPS then
      local bestGain, bestU, bestRev = EPS, nil, false
      local function Try(u, v)
        if inSeg[u] or inSeg[v] then return end
        if (u == p and v == nx) then return end
        local duv = D(u, v)
        local g1 = removeGain - (D(u, first) + D(last, v) - duv)
        local g2 = removeGain - (D(u, last) + D(first, v) - duv)
        if g1 > bestGain then bestGain, bestU, bestRev = g1, u, false end
        if g2 > bestGain then bestGain, bestU, bestRev = g2, u, true end
      end
      for e = 1, 2 do
        local from = e == 1 and first or last
        for _, c in ipairs(NB[from]) do
          Tick()
          if L.pos[c] and not inSeg[c] then
            Try(c, Succ(L, c))
            Try(Pred(L, c), c)
          end
        end
      end
      if bestU then
        local list, n = {}, 0
        for _, x in ipairs(L.t) do
          if not inSeg[x] then
            n = n + 1; list[n] = x
            if x == bestU then
              for k = 1, len do
                n = n + 1
                list[n] = bestRev and seg[len - k + 1] or seg[k]
              end
            end
          end
        end
        Rebuild(L, list)
        return true, p, nx, bestU, first, last
      end
    end
  end
  return false
end

-- 2-opt and Or-opt until neither finds anything; `queue` = the stops to look at first (nil: all)
local function Improve(L, queue)
  local inQ, q, head = {}, {}, 1
  local function Push(s) if s and L.pos[s] and not inQ[s] then inQ[s] = true; q[#q + 1] = s end end
  if queue then for _, s in ipairs(queue) do Push(s) end else for _, s in ipairs(L.t) do Push(s) end end
  while head <= #q do
    local a = q[head]
    q[head] = nil
    head = head + 1
    inQ[a] = nil
    if L.pos[a] then
      local moved, s1, s2, s3, s4, s5 = TwoOptAt(L, a)
      if not moved then moved, s1, s2, s3, s4, s5 = OrOptAt(L, a) end
      if moved then
        Push(a); Push(s1); Push(s2); Push(s3); Push(s4); Push(s5)
        for _, n in ipairs(NB[a]) do Push(n) end
      end
    end
  end
end

---------------------------------------------------------------- the prize-collecting step
-- objective of a loop: profit of its stops minus cost per yard times its length
local function Objective(L, perYard)
  local sum = 0
  for _, s in ipairs(L.t) do sum = sum + PI[s]; Tick() end
  return sum - perYard * Length(L)
end

-- drop stops that cost more (in length) than their profit; keeps at least 3
-- One sweep round the loop drops every stop whose profit is less than the length it costs, judged
-- against the stops kept so far; sweeps repeat until none is dropped. Linear per sweep, where
-- dropping the single worst stop each time would be quadratic.
local function DropPass(L, perYard)
  local any = false
  for _ = 1, 50 do
    local t = L.t
    local m = #t
    if m <= 3 then break end
    local kept, n, dropped = {}, 0, 0
    local prev = t[m]
    for k = 1, m do
      Tick()
      local s, nx = t[k], t[k % m + 1]
      if k == m and n > 0 then nx = kept[1] end
      local g = perYard * (D(prev, s) + D(s, nx) - D(prev, nx)) - PI[s]
      if g > EPS and m - dropped > 3 then
        dropped = dropped + 1
      else
        n = n + 1
        kept[n] = s
        prev = s
      end
    end
    if dropped == 0 then break end
    Rebuild(L, kept)
    any = true
  end
  return any
end

-- add stops next to the loop whose profit beats what they add to the length, best profit first.
-- Only stops in the neighbour lists of stops on the loop are looked at, so a loop grows outwards
-- from where it is.
local function AddPass(L, perYard, byProfit)
  local any = false
  for _ = 1, 200 do
    local cand
    if #L.t < 3 then
      cand = byProfit
    else
      cand = {}
      local seen = {}
      for _, s in ipairs(L.t) do
        for _, k in ipairs(NB[s]) do
          if not L.pos[k] and not seen[k] and PI[k] > 0 then
            seen[k] = true
            cand[#cand + 1] = k
          end
        end
        Tick()
      end
      table.sort(cand, function(a, b) if PI[a] ~= PI[b] then return PI[a] > PI[b] end return a < b end)
    end
    local added = false
    for _, k in ipairs(cand) do
      Tick()
      if not L.pos[k] and PI[k] > 0 then
        local u, c = BestInsert(L, k, #L.t < 3)
        if u and PI[k] - perYard * c > EPS then
          InsertAfter(L, u, k)
          added, any = true, true
        end
      end
    end
    if not added then break end
  end
  return any
end

-- replace a stop on the loop by a better one near it, in the same place
local function SwapPass(L, perYard)
  local any = false
  for idx = 1, #L.t do
    local s = L.t[idx]
    if s then
      local p, nx = Pred(L, s), Succ(L, s)
      local base = PI[s] - perYard * (D(p, s) + D(s, nx))
      local bestK, bestG = nil, EPS
      for _, k in ipairs(NB[s]) do
        Tick()
        if not L.pos[k] then
          local g = PI[k] - perYard * (D(p, k) + D(k, nx)) - base
          if g > bestG then bestK, bestG = k, g end
        end
      end
      if bestK then
        L.t[idx], L.pos[s], L.pos[bestK] = bestK, nil, idx
        any = true
      end
    end
  end
  return any
end

local function SearchPC(L, perYard, byProfit, select)
  Improve(L)
  if not select then return end
  for _ = 1, 10 do
    local a = DropPass(L, perYard)
    local b = AddPass(L, perYard, byProfit)
    local c = SwapPass(L, perYard)
    if not (a or b or c) then break end
    Improve(L)
  end
end

-- the double bridge: cut the loop in four places close together and join the pieces the other way
-- (A B C D -> A C B D), then repair with local search. Kept only if the objective improved.
local function Kick(L)
  local m = #L.t
  local span = min(KICK_SPAN, floor(m / 4))
  local p1 = Random(m)
  local l1, l2, l3 = Random(span), Random(span), Random(span)
  local t, list = L.t, {}
  local function At(k) return t[(k - 1) % m + 1] end
  local p2, p3, p4 = p1 + l1, p1 + l1 + l2, p1 + l1 + l2 + l3
  for k = p4 + 1, p1 + m do list[#list + 1] = At(k) end -- A
  for k = p2 + 1, p3 do list[#list + 1] = At(k) end     -- C
  for k = p1 + 1, p2 do list[#list + 1] = At(k) end     -- B
  for k = p3 + 1, p4 do list[#list + 1] = At(k) end     -- D
  local ends = { At(p1), At(p1 + 1), At(p2), At(p2 + 1), At(p3), At(p3 + 1), At(p4), At(p4 + 1) }
  Rebuild(L, list)
  return ends
end

local function Iterate(L, perYard, byProfit, select, kicks)
  if #L.t < 8 then return L end
  local best = Objective(L, perYard)
  for _ = 1, kicks do
    if OverBudget() or #L.t < 8 then break end
    local keep = CopyLoop(L)
    local ends = Kick(L)
    Improve(L, ends)
    if select then SearchPC(L, perYard, byProfit, true) end
    local now = Objective(L, perYard)
    -- equal counts as better: it lets the search drift across loops of the same length
    if now >= best - EPS then best = now else L = keep end
  end
  return L
end

---------------------------------------------------------------- expected length (polish)
-- Jaillet: E[length] = sum over ordered pairs i -> j of P(i) P(j) d(i, j) times the chance every
-- stop between them is empty. Each sum is cut after CHAIN stops or once that chance is under
-- CHAIN_EPS; the cut is symmetric, so reversing part of the loop leaves the pairs inside it alone.
local function ChainFrom(at, m, k, pairOk)
  local i = at(k)
  local pi = P[i]
  if pi <= 0 then return 0 end
  local sum, empty = 0, 1
  for step = 1, min(CHAIN, m - 1) do
    local j = at(k + step)
    if not pairOk or pairOk(k, k + step) then sum = sum + pi * P[j] * D(i, j) * empty end
    empty = empty * (1 - P[j])
    if empty < CHAIN_EPS then break end
  end
  return sum
end

local function ExpectedLength(L)
  local t, m = L.t, #L.t
  if m < 2 then return 0 end
  local function at(k) return t[(k - 1) % m + 1] end
  local sum = 0
  for k = 1, m do sum = sum + ChainFrom(at, m, k); Tick() end
  return sum
end
-- for the tests; exact = true for the whole sum, without the cut
S.ExpectedLength = function(order, p, x, y, exact)
  X, Y, P, PEN, DET = x, y, p, nil, nil
  local chain, eps = CHAIN, CHAIN_EPS
  if exact then CHAIN, CHAIN_EPS = #order, 0 end
  local e = ExpectedLength(NewLoop(order))
  CHAIN, CHAIN_EPS = chain, eps
  return e
end

-- the part of the expected length that changes when indexes a..b (forward) are reversed: the pairs
-- with exactly one end inside. `at` maps an index to a stop, before or after the reversal.
local function CrossCost(at, m, a, b)
  local len = (b - a) % m + 1
  local function Inside(k) return (k - a) % m < len end
  local function PairOk(k1, k2) return Inside(k1) ~= Inside(k2) end
  local sum, seen = 0, {}
  local function From(k)
    local key = (k - 1) % m + 1
    if seen[key] then return end
    seen[key] = true
    sum = sum + ChainFrom(at, m, k, PairOk)
  end
  for k = a - CHAIN, a - 1 do From(k) end
  for k = b - CHAIN, b do From(k) end
  return sum
end

-- 2-opt on the expected length (the 2-p-opt move): the loop that is shortest once you skip the stops
-- that turn out empty
local function Polish(L)
  local m = #L.t
  if m < 2 * CHAIN + 4 then
    -- small loop: work the whole sum out for every move
    local best = ExpectedLength(L)
    local improved = true
    while improved do
      improved = false
      for a = 1, m - 1 do
        for b = a + 1, m do
          Tick()
          if b - a < m - 1 then
            Reverse(L, a, b)
            local e = ExpectedLength(L)
            if e < best - EPS then best, improved = e, true else Reverse(L, a, b) end
          end
        end
      end
    end
    return
  end
  local t = L.t
  local improved, rounds = true, 0
  while improved and rounds < 20 and (rounds == 0 or not OverBudget()) do
    improved, rounds = false, rounds + 1
    for idx = 1, m do
      local a = t[idx]
      for _, c in ipairs(NB[a]) do
        Tick()
        local pa, pc = L.pos[a], L.pos[c]
        if pc then
          -- reversing from a's successor to c joins a to c (as in plain 2-opt)
          local s, e = pa % m + 1, pc
          local len = (e - s) % m + 1
          if len >= 2 and len <= m - CHAIN - 2 then
            local function before(k) return t[(k - 1) % m + 1] end
            local function after(k)
              local r = (k - s) % m
              if r < len then return t[(e - r - 1) % m + 1] end
              return t[(k - 1) % m + 1]
            end
            local old = CrossCost(before, m, s, e)
            local new = CrossCost(after, m, s, e)
            if new < old - EPS then
              Reverse(L, s, e)
              t = L.t
              improved = true
            end
          end
        end
      end
    end
  end
end

---------------------------------------------------------------- setting up
-- detour: how much longer than drawn a long leg rides (nil or 0: straight lines)
local function Setup(spots, stops, params, detour)
  N = #stops
  X, Y, V, P, PI = {}, {}, {}, {}, {}
  for i, s in ipairs(stops) do X[i], Y[i] = s.x, s.y end
  DET = detour and detour > 0 and detour or nil
  PEN = nil
  local slow = params.slow
  if slow and #slow > 0 then
    -- a slow leg slows every leg between a stop near its one end and a stop near its other: what
    -- was in the way there (a cliff, a river, a camp) is in the way of the stops next to it too
    local r2 = SLOW_REACH * SLOW_REACH
    local function Near(x, y)
      local list = {}
      for i = 1, N do
        if (X[i] - x) ^ 2 + (Y[i] - y) ^ 2 <= r2 then list[#list + 1] = i end
      end
      return list
    end
    for _, leg in ipairs(slow) do
      local as, bs = Near(leg[1], leg[2]), Near(leg[3], leg[4])
      for _, a in ipairs(as) do
        for _, b in ipairs(bs) do
          if a ~= b then
            PEN = PEN or {}
            local f = max(leg[5], PEN[a * 65536 + b] or 1)
            PEN[a * 65536 + b], PEN[b * 65536 + a] = f, f
          end
        end
      end
    end
  end
end

-- values at loop time T (seconds; nil = full respawn)
local function SetValues(spots, stops, T)
  for i, s in ipairs(stops) do V[i], P[i] = StopValue(spots, s, T); Tick() end
end

-- the loop's time: riding plus gathering, where what you gather depends on the loop's time.
-- A few rounds of fixed-point iteration settle it.
local function LoopTime(spots, stops, L, len, speed, handle)
  local T = len / speed
  for _ = 1, 6 do
    local nodes = 0
    for _, i in ipairs(L.t) do nodes = nodes + (StopValue(spots, stops[i], T)); Tick() end
    T = len / speed + handle * nodes
  end
  local nodes = 0
  for _, i in ipairs(L.t) do nodes = nodes + (StopValue(spots, stops[i], T)) end
  return T, nodes
end

-- the starting loop over every stop: random insertion, then local search and kicks
local function FullLoop(kicks)
  local order = {}
  for i = 1, N do order[i] = i end
  for i = N, 2, -1 do
    local j = Random(i)
    order[i], order[j] = order[j], order[i]
  end
  local L = NewLoop({ order[1] })
  for k = 2, N do
    local u = BestInsert(L, order[k], true)
    InsertAfter(L, u, order[k])
    Tick()
  end
  for i = 1, N do PI[i] = 0 end
  Improve(L)
  return Iterate(L, 1, nil, false, kicks)
end

-- the seed stops, the places loops are grown from. Round the player (px, py; ride = the yards of
-- NEAR_RIDE): the richest of the few stops nearest to them, then the richest within that ride.
-- Then the richest of the whole zone. Rich = most value within SEED_REACH yards; no two seeds are
-- within that reach of each other. seeds.near = how many of them are the player's.
local function Seeds(count, px, py, ride)
  local score = {}
  local r2 = SEED_REACH * SEED_REACH
  for i = 1, N do
    local s = 0
    for j = 1, N do
      if (X[i] - X[j]) ^ 2 + (Y[i] - Y[j]) ^ 2 <= r2 then s = s + V[j] end
    end
    score[i] = s
    Tick()
  end
  local seeds = { near = 0 }
  local function Far(i)
    for _, s in ipairs(seeds) do
      if (X[i] - X[s]) ^ 2 + (Y[i] - Y[s]) ^ 2 <= r2 then return false end
    end
    return true
  end
  local function Richer(a, b) if score[a] ~= score[b] then return score[a] > score[b] end return a < b end
  if px then
    local dist, order = {}, {}
    for i = 1, N do dist[i], order[i] = (X[i] - px) ^ 2 + (Y[i] - py) ^ 2, i end
    table.sort(order, function(a, b) if dist[a] ~= dist[b] then return dist[a] < dist[b] end return a < b end)
    local best
    for k = 1, min(NEAR_STOPS, N) do
      if not best or Richer(order[k], best) then best = order[k] end
    end
    seeds[1] = best
    best = nil
    for k = 1, N do
      local i = order[k]
      if dist[i] > ride * ride then break end
      if Far(i) and (not best or Richer(i, best)) then best = i end
    end
    seeds[2] = best
    seeds.near = #seeds
  end
  local order = {}
  for i = 1, N do order[i] = i end
  table.sort(order, Richer)
  for _, i in ipairs(order) do
    if #seeds - seeds.near >= count then break end
    if Far(i) then seeds[#seeds + 1] = i end
  end
  return seeds
end

-- one prize-collecting solve for rate `lambda` (nodes per second): profit of stop i is
-- V[i] * (1 - lambda * handle), each yard costs lambda / speed. Tries the warm loop, the full loop
-- trimmed, and loops grown from seeds; returns them all, for the caller to pick from.
local function SolvePC(full, warm, seeds, lambda, speed, handle, kicks)
  local perYard = lambda / speed
  local byProfit = {}
  for i = 1, N do
    PI[i] = V[i] * (1 - lambda * handle)
    byProfit[i] = i
  end
  table.sort(byProfit, function(a, b) if PI[a] ~= PI[b] then return PI[a] > PI[b] end return a < b end)
  local starts = {}
  if warm then starts[#starts + 1] = CopyLoop(warm) end
  if full then starts[#starts + 1] = CopyLoop(full) end
  for _, s in ipairs(seeds) do starts[#starts + 1] = NewLoop({ s }) end
  local found = {}
  for _, L in ipairs(starts) do
    if #L.t < 3 then AddPass(L, perYard, byProfit) end
    if #L.t >= 3 then
      SearchPC(L, perYard, byProfit, true)
      found[#found + 1] = Iterate(L, perYard, byProfit, true, kicks)
    end
    if OverBudget() and #found > 0 then break end
  end
  return found
end

---------------------------------------------------------------- the whole job
-- spots: see Group. params:
--   speed     yards a second (default 7)
--   handle    seconds spent gathering one node (default 5)
--   minutes   aim for a loop this long; nil = the most nodes per minute (Dinkelbach)
--   maxMinutes in that case, loops longer than this (default 20) give way to the best of this length
--   seed      for the random kicks (same data and seed: same route)
--   clock     a function returning milliseconds; slice: ms per resume; budget: ms in all
--   slow      { { x1, y1, x2, y2, factor } ... } legs that take longer than their length says
--   px, py    where the player is (yards): loops are grown from there too, and a loop is worth less
--             the longer the ride to it. anywhere = true: the best loop of the zone, wherever it is
--   horizon   seconds of farming the ride to the loop is weighed against (default 600)
--   detour    how much longer than drawn a long leg rides (default 0.5; 0 = straight lines)
--   progress  optional function(result) called once with the first full loop
-- Must run inside a coroutine (it yields between slices). Returns a result:
--   stops     { { x, y, members = { spot index ... } } ... } in loop order
--   length    yards as drawn; elength: expected yards ridden once empty stops are skipped
--   approach  yards from the player to the nearest stop (nil without px, py)
--   elsewhere nil, or { gain, approach }: a loop further from the player was passed over though it
--             collects `gain` times as much (a minute, or a loop when the length is fixed)
--   seconds   expected time of one loop; nodes: expected nodes a loop; rate: nodes a minute
--   tau       the respawn time used (median of the spots' tau)
function S.Plan(spots, params)
  params = params or {}
  clock = params.clock or DefaultClock
  slice, budget = params.slice or 4, params.budget or huge
  used, ops, sliceStart = 0, 0, Now()
  Seed(params.seed or 1)
  local speed, handle = params.speed or 7, params.handle or 5
  local trace = params.trace or function() end

  local all = Group(spots, params.group)
  -- leave out stops not worth a detour even at full respawn
  local stops = {}
  for _, s in ipairs(all) do
    local v = StopValue(spots, s, nil)
    if v >= MIN_VALUE then stops[#stops + 1] = s end
  end
  if #stops < 3 then return { stops = stops, length = 0, elength = 0, seconds = 0, nodes = 0, rate = 0, few = true } end
  trace("group")
  Setup(spots, stops, params, params.detour or DETOUR)
  BuildNeighbours()
  trace("neighbours")
  SetValues(spots, stops, nil)

  -- where the player is. A loop is judged as a session of `horizon` seconds: the ride to its
  -- nearest stop comes off the time spent farming it.
  local px, py = params.px, params.py
  local function Approach(L)
    local best = huge
    for _, i in ipairs(L.t) do
      local d = (X[i] - px) ^ 2 + (Y[i] - py) ^ 2
      if d < best then best = d end
    end
    return sqrt(best)
  end
  local anchored = px and py and not params.anywhere
  local horizon = params.horizon or HORIZON
  local function Anchor(L)
    if not anchored then return 1 end
    return max(0.05, 1 - Ride(Approach(L)) / speed / horizon)
  end

  local kicks = params.kicks or max(20, min(200, floor(20000 / N)))
  local full = FullLoop(kicks)
  local function Result(L)
    local list = {}
    for k, i in ipairs(L.t) do list[k] = stops[i] end
    local len = Length(L)
    local T, nodes = LoopTime(spots, stops, L, len, speed, handle)
    return { stops = list, length = DrawnLength(L), seconds = T, nodes = nodes, rate = T > 0 and nodes / T * 60 or 0,
      loop = L, approach = px and py and Approach(L) or nil }
  end
  trace("full loop")
  if params.progress then params.progress(Result(full)) end

  local seeds

  -- Choosing between loops. Each loop found is weighed by what it collects (a minute; or a loop,
  -- when the length is fixed), less for the ride from the player to it, and a little less the
  -- longer it is: where nodes are spread evenly a loop round the whole zone collects as much a
  -- minute as a short one, and the short one near you is the one you want. `top` is the loop that
  -- collects most wherever it is, to tell the player about when it is not the one chosen.
  local limit = (params.minutes or params.maxMinutes or 20) * 60
  local best, bestScore, bestGain, top, topGain
  local function Consider(L)
    if not L or #L.t < 3 then return end
    local T, nodes = LoopTime(spots, stops, L, Length(L), speed, handle)
    if T <= 0 or T > limit * 1.001 then return end
    local rate = nodes / T
    local gain = params.minutes and nodes or rate * (1 - SHORTER * T / limit)
    local score = gain * Anchor(L)
    if not bestScore or score > bestScore then best, bestScore, bestGain = L, score, gain end
    if not topGain or gain > topGain then top, topGain = L, gain end
    return rate, T, score
  end

  -- a fixed length: the classic orienteering problem. (Bisecting a cost per yard, the Lagrangian
  -- relaxation, does not work here: as the cost crosses the best rate the loop jumps from the whole
  -- zone to a handful of stops, a duality gap, and nothing in between is ever found.) Instead, the
  -- standard construction for the problem: insert the stop with the most value per added minute
  -- while the loop fits; from the whole loop trimmed to fit, and from each seed; tidy with 2-opt and
  -- Or-opt, grow again into the time that frees. Every loop that fits goes to Consider.
  -- whole = false leaves the trimmed whole loop out: it is the slowest start, and the one that
  -- wanders over the zone.
  local function SolveBudget(B, whole)
    SetValues(spots, stops, B)
    if anchored then seeds = Seeds(SEEDS, px, py, speed * NEAR_RIDE) else seeds = Seeds(SEEDS) end
    local function Value(L)
      local v = 0
      for _, s in ipairs(L.t) do v = v + V[s] end
      return v
    end
    local function Time(L) return Length(L) / speed + handle * Value(L) end
    if Time(full) <= B then
      if not whole then return end
      -- everything fits: the whole loop is one choice, the loops grown from the seeds the others
      Consider(full)
      whole = false
    end

    local function Grow(L)
      local len, val = Length(L), Value(L)
      for _ = 1, 1000 do
        local cand, seen = {}, {}
        if #L.t < 3 then
          for i = 1, N do if not L.pos[i] then cand[#cand + 1] = i end end
        else
          for _, s in ipairs(L.t) do
            for _, k in ipairs(NB[s]) do
              if not L.pos[k] and not seen[k] then seen[k] = true; cand[#cand + 1] = k end
            end
          end
        end
        local ratio = {}
        for _, k in ipairs(cand) do
          local _, c = BestInsert(L, k, #L.t < 3)
          ratio[k] = c and V[k] / max(c / speed + handle * V[k], EPS) or -1
          Tick()
        end
        table.sort(cand, function(a, b) if ratio[a] ~= ratio[b] then return ratio[a] > ratio[b] end return a < b end)
        local added = false
        for _, k in ipairs(cand) do
          local u, c = BestInsert(L, k, #L.t < 3)
          if u and (len + c) / speed + handle * (val + V[k]) <= B then
            InsertAfter(L, u, k)
            len, val, added = len + c, val + V[k], true
          end
          Tick()
        end
        if not added then break end
      end
    end

    -- drops the stops worth least for the time they save, a tenth at a time, until it fits
    local function Trim(L)
      while #L.t > 3 and Time(L) > B do
        local ratio, order = {}, {}
        for k, s in ipairs(L.t) do
          local p, nx = Pred(L, s), Succ(L, s)
          local save = (D(p, s) + D(s, nx) - D(p, nx)) / speed + handle * V[s]
          ratio[s], order[k] = V[s] / max(save, EPS), s
          Tick()
        end
        table.sort(order, function(a, b) if ratio[a] ~= ratio[b] then return ratio[a] < ratio[b] end return a < b end)
        local drop = {}
        for k = 1, max(1, min(#order - 3, floor(#order / 10))) do drop[order[k]] = true end
        local kept = {}
        for _, s in ipairs(L.t) do if not drop[s] then kept[#kept + 1] = s end end
        Rebuild(L, kept)
        Improve(L)
      end
    end

    -- the player's seeds first: should the time run out, the loops by them are the ones there are
    local starts = {}
    for k = 1, seeds.near do starts[#starts + 1] = NewLoop({ seeds[k] }) end
    if whole then starts[#starts + 1] = CopyLoop(full) end
    for k = seeds.near + 1, #seeds do starts[#starts + 1] = NewLoop({ seeds[k] }) end
    for _, L in ipairs(starts) do
      Trim(L)
      for _ = 1, 3 do
        Grow(L)
        Improve(L)
        Trim(L)
      end
      if Time(L) <= B then Consider(L) end
      trace("budget start")
      if OverBudget() and best then break end
    end
  end

  if params.minutes then
    SolveBudget(limit, true)
  else
    -- The loop with the most nodes per minute, no longer than maxMinutes (where nodes are spread
    -- evenly the best rate can need a loop round the whole zone, though a much shorter one collects
    -- nearly as much a minute). First the best loops of half that length, a quarter and all of it,
    -- which is quick and already good; then Dinkelbach rounds from the one chosen, each finding the
    -- loops best for "value - rate * time" and taking the rate of the best. With respawn the value
    -- depends on the time, so each round uses the previous round's loop time.
    for _, part in ipairs({ 0.5, 0.25, 1 }) do
      SolveBudget(limit * part, part == 1)
      if OverBudget() and best then break end
    end
    trace("best within the cap")
    if best then
      local T, nodes = LoopTime(spots, stops, best, Length(best), speed, handle)
      local lambda = nodes / T
      local warm = best
      -- the whole loop is a useful start only when it fits the cap
      local fullStart = LoopTime(spots, stops, full, Length(full), speed, handle) <= limit and full or nil
      for _ = 1, ROUNDS do
        if OverBudget() then break end
        SetValues(spots, stops, T)
        local L, rate, T2, score
        for _, c in ipairs(SolvePC(fullStart, warm, seeds, lambda, speed, handle, floor(kicks / 2))) do
          local r, Tc, sc = Consider(c)
          if sc and (not score or sc > score) then L, rate, T2, score = c, r, Tc, sc end
        end
        trace("dinkelbach round")
        if not L then break end
        warm = L
        local settled = abs(rate - lambda) <= SETTLE * lambda and abs(T2 - T) <= SETTLE * T
        lambda, T = max(rate, lambda), T2
        if settled then break end
      end
    end
  end
  if not best then
    -- nothing fitted (a length too short for three stops): the three stops nearest the player, or
    -- the whole loop's first three
    local order = {}
    for i = 1, N do order[i] = i end
    if px and py then
      table.sort(order, function(a, b)
        local da, db = (X[a] - px) ^ 2 + (Y[a] - py) ^ 2, (X[b] - px) ^ 2 + (Y[b] - py) ^ 2
        if da ~= db then return da < db end
        return a < b
      end)
    else
      order = full.t
    end
    best = NewLoop({ order[1], order[2], order[3] })
    top = best
  end
  local elsewhere
  if anchored and top ~= best and topGain and bestGain and topGain >= bestGain * ELSEWHERE then
    elsewhere = { gain = topGain / bestGain, approach = Approach(top) }
  end

  -- polish for skipped stops, with the chance each stop is up at this loop's time
  local len = Length(best)
  local T = LoopTime(spots, stops, best, len, speed, handle)
  SetValues(spots, stops, T)
  -- Kept only while the loop as ridden stays about as short. Skipping a stop takes seeing that it
  -- is empty, which you can only do from near it; where most stops are likely empty the polish
  -- would otherwise trade the tidy loop for one that zig-zags between the few likely ones.
  local tidy = CopyLoop(best)
  Polish(best)
  if Length(best) > len * POLISH_SLACK then best = tidy end

  local result = Result(best)
  result.elength = ExpectedLength(best)
  -- what one loop really takes: riding the expected length, gathering what is up
  local Te = result.elength / speed + handle * result.nodes
  result.seconds, result.rate = Te, Te > 0 and result.nodes / Te * 60 or 0
  result.loop = nil
  result.elsewhere = elsewhere
  return result
end

-- the same numbers for a loop you already have: stops at `points` ({ x, y } in loop order), each
-- taking the spots within GROUP yards (nearest stop wins). For saved routes and for comparing.
function S.Evaluate(spots, points, params)
  params = params or {}
  clock = params.clock or DefaultClock
  slice, budget = params.slice or 4, params.budget or huge
  used, ops, sliceStart = 0, 0, Now()
  local speed, handle = params.speed or 7, params.handle or 5
  local stops = {}
  for i, p in ipairs(points) do stops[i] = { x = p.x, y = p.y, members = {} } end
  local r2 = (params.group or GROUP) ^ 2
  for j, s in ipairs(spots) do
    local best, bd = nil, r2
    for i, st in ipairs(stops) do
      local d = (st.x - s.x) ^ 2 + (st.y - s.y) ^ 2
      if d <= bd then best, bd = i, d end
    end
    if best then local m = stops[best].members; m[#m + 1] = j end
    Tick()
  end
  if #stops < 2 then return { stops = stops, length = 0, elength = 0, seconds = 0, nodes = 0, rate = 0 } end
  Setup(spots, stops, params, params.detour or DETOUR)
  local order = {}
  for i = 1, #stops do order[i] = i end
  local L = NewLoop(order)
  local len = Length(L)
  local T, nodes = LoopTime(spots, stops, L, len, speed, handle)
  SetValues(spots, stops, T)
  local el = ExpectedLength(L)
  local Te = el / speed + handle * nodes
  return { stops = stops, length = DrawnLength(L), elength = el, seconds = Te, nodes = nodes,
    rate = Te > 0 and nodes / Te * 60 or 0 }
end

-- for the tests: a plain shortest loop through points { x, y } (no values, no respawn)
function S.Tour(points, params)
  params = params or {}
  clock = params.clock or DefaultClock
  slice, budget = huge, params.budget or huge
  used, ops, sliceStart = 0, 0, Now()
  Seed(params.seed or 1)
  local stops = {}
  for i, p in ipairs(points) do stops[i] = { x = p.x, y = p.y, members = {} } end
  Setup({}, stops, params, params.detour)
  BuildNeighbours()
  local L = FullLoop(params.kicks or 100)
  return L.t, Length(L)
end

-- published last: if anything above failed to load, Route.lua finds no solver and says so
ns.RouteSolver = S
