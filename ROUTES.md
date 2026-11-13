# Farming routes: the plan

This expands idea 3 in IDEAS.md. The goal: `/sl route` draws one loop through the current zone that
you can follow round and round. The loop favours spots you found yourself and spots that keep paying
off. It is built only from the nodes the map is showing you, so the filters you already have decide
what the route is for.

**Built:** `RouteSolver.lua` (the maths) and `Route.lua` (the game side), with tests in `tests\`.
Building it changed a few things in this plan, each for a reason found by testing on real data;
sections 13 and 14 list them. Where the sections below differ from those, they are what the code does.

---

## 1. Which nodes the route uses

Exactly the nodes drawn on the map, nothing else. The route is built from `BuildList(mapID)`, the
same list the world map and minimap pins come from, so every filter applies to it:

| You have | The route goes through |
| --- | --- |
| Ores and herbs shown | Ores and herbs |
| `/sl hide herbs` | Ores only |
| `/sl only copper` | Copper only |
| `/sl only copper, tin, peacebloom` | Those three |
| `/sl xp` | Only nodes that can still raise your skill |
| `/sl reliable` | Not the spots that keep coming up empty |

Changing a filter while the route is on plans a new route straight away, for the nodes now shown.
With fewer than 3 stops shown (or everything hidden) there is no loop, and the addon says so. A kind
that is hidden is never part of a route, even if it lies right on the way.

## 2. What problem this really is

A farming loop is not the textbook travelling salesman problem (visit every point once, shortest
loop). Four things make it different, and each one has a name and a body of research behind it:

1. **Not every dot is worth a stop.** Choosing which points to visit within a time budget, for the
   most value, is the **orienteering problem** (also called the selective TSP or the TSP with
   profits; Feillet, Dejax and Gendreau's survey covers the family).
2. **A node is there only with some probability, and you skip it when it is not.** With tracking on,
   you see from far away whether a spot's node is up, and ride past if it is not. A fixed loop
   whose stops are skipped when absent is an **a priori tour**: the **probabilistic TSP** (Jaillet
   1985; Bertsimas), and with prizes the **probabilistic orienteering problem** (Angelelli, Archetti,
   Filippi and Vindigni 2017). The right loop for this is *not* the shortest loop through all stops:
   it is the one whose expected length, after skipping the empty stops, is shortest.
3. **Nodes come back.** How much a loop collects depends on how long it takes: come back too soon
   and nothing has respawned. This is a **patrolling** problem; the value of a stop grows with the
   time since your last visit.
4. **You want the most nodes per minute, not the most nodes.** That is a ratio, value ÷ time, a
   **fractional programme**, which **Dinkelbach's method** (1967) turns into a short series of
   ordinary problems.

The plan combines these: a probabilistic orienteering problem with regeneration, maximising expected
nodes per minute, solved with Dinkelbach's method around an iterated local search.

## 3. The methods considered

### Ordering the stops

| Method | Quality (above the best loop) | Cost | Verdict |
| --- | --- | --- | --- |
| Nearest neighbour | 20 to 25% longer, crossing lines | Tiny | Only inside other methods |
| Cheapest insertion | 10 to 20% | Small | **Starting loop** |
| Christofides | Guaranteed within 50%, about 10% in practice | Needs minimum-weight matching | No: beaten by local search, hard in Lua |
| 2-opt + Or-opt local search | About 5% | Close to linear with neighbour lists | **Yes, the core** |
| Iterated local search (local search + double-bridge kicks) | 1 to 3% | Stops any time | **Yes, around the core** |
| Lin-Kernighan-Helsgaun (LKH) | Under 1% | Thousands of lines | No: the data's own error is larger than the gain |
| Ant colony (what the Routes addon uses) | Usually worse than 2-opt for the same time | Many passes, random | No |
| Simulated annealing, genetic algorithms | Like ILS at best | Slow, needs tuning | No |
| Exact (Held-Karp, Concorde, branch-and-cut) | Optimal | Exponential or a C solver | Tests only: Held-Karp checks the heuristic on small cases |

### Choosing the stops and handling the probabilities

| Method | What it gives | Verdict |
| --- | --- | --- |
| Fixed time budget, drop/add/swap moves (Golden-Levy-Vohra, GRASP, Vansteenwegen's ILS) | Most value within B minutes | **Yes**, for `/sl route 15` |
| Try several budgets, keep the best per minute | Rough answer to "how long should the loop be" | Replaced by Dinkelbach |
| **Dinkelbach's method** on value ÷ time | The loop with the most value per minute, with no budget to guess | **Yes, the outer loop** |
| **Probabilistic TSP expected length**, with the 2-p-opt and 1-shift moves (Bertsimas; corrected by Bianchi, Knowles and Bowler 2005; unequal probabilities by Bianchi and Campbell 2007) | A loop that is short *after* skipping empty stops | **Yes, the final polish**, with truncated sums so it stays fast |
| Monte Carlo sampling of which nodes are up (sample average approximation) | Same as above, noisier, slower | No: the closed form is exact and cheaper here |
| Branch-and-cut for the POP | Optimal | No: minutes of CPU for 100 nodes, a C solver |
| Markov decision process (re-plan after every observation) | In theory the best policy | No: the route would change under you. The "next stop" skip does the useful part |
| Close-enough TSP (pass within r of each point) | Shorter loops when touching a circle is enough | No: you must stand at a node to gather it. The part that needs only a look (seeing a spot is empty) is already covered by the probabilistic model |
| Generalised TSP (visit one of each group) | Handles alternative spawn spots exactly | Approximated by grouping nearby spots into one stop (3.3), the usual reduction for small groups |

**The choice:** Dinkelbach's method for the loop length, an iterated local search (2-opt, Or-opt,
drop/add/swap, double-bridge kicks) for each step of it, and a final polish with the probabilistic
TSP's expected length. All of it is plain loops over arrays, it can stop at any moment with a usable
loop (needed at a few milliseconds per frame), and with a fixed random seed the same data gives the
same route.

## 4. The pipeline

```
BuildList(mapID)            what the map shows now, after every filter
  -> value of each spot      chance it is up, how much you want it, a small bonus for the unknown
  -> group into stops        spots of one spawn become one stop
  -> starting loop           cheapest insertion, 2-opt, Or-opt, kicks
  -> Dinkelbach              repeat: choose stops for the current rate, update the rate
  -> expected-length polish  2-p-opt and 1-shift with the stops' up-chances
  -> draw and follow
```

### 4.1 The chance a spot is up

The existing score is (finds + 1) / (checks + 2), which starts every spot at an even guess. For the
route the starting guess depends on where the spot came from. That is the "my finds first" rule,
built into the same Bayesian formula (a Beta prior), so evidence takes over as it comes in:

| Source | Starting guess (a finds, b empties) | Before any check |
| --- | --- | --- |
| Gathered by you | 3, 1 | 0.75 |
| Spotted by you on the minimap | 2.5, 1 | 0.71 |
| Gathered by another player | 2, 1 | 0.67 |
| Spotted by another player | 1.5, 1 | 0.60 |
| Imported (GatherMate2) | 1, 2 | 0.33 |

r = (finds + a) / (finds + empties + ¼·walk-bys + a + b)

The starting counts are worth about three checks. An imported spot that paid off 5 times out of 5
scores 0.75, as good as an untested one of your own; one of your own spots that was empty 6 times
scores 0.3. `Reliability` stays as it is for tooltips and `/sl reliable`; the route uses this one.

**Learning about untested spots.** A route that only trusts what it already knows never tests the
imported spots, so it never finds the good ones. This is the explore-or-exploit question from
multi-armed bandits. The answer used here is an upper confidence bound: a spot with few checks gets
a small bonus, r + 0.5 × the standard deviation of its Beta estimate, which shrinks as checks come
in. A fixed bonus (rather than random sampling) keeps the route stable. `/sl route safe` turns it off.

**How much you want it.** 1 by default. With `/sl xp` on: orange 1, yellow 0.8, green 0.4. Idea 25
(auction prices) can plug in here later.

### 4.2 Respawn

The chance a node is up when you arrive also depends on how long ago the loop last passed:

  up(T) = r × (1 − e^(−T / τ))

T is the loop's time and τ how long that node type takes to come back. The addon already records
each gathered node's fastest return (`node.gap`); τ is the median of those for the zone and kind once
there are 5 or more, otherwise **8 minutes**. (The fastest return is a lower bound, so the estimate
leans towards loops a little short. It improves as the data does.)

### 4.3 Stops

Imported data often has several points a few yards apart: one spawn recorded by different people, or
alternative spawn spots of which one is up at a time. Routing to each would zig-zag; counting each
as full value would overrate the spot.

1. Sort spots by value, highest first.
2. Take the first spot not yet in a stop; every spot within **30 yards** joins it. Your own nodes
   become the centres of stops and imported points near them join them.
3. The stop's position is the value-weighted average of its spots.
4. Within one kind, the stop's chance is 1 − (1 − p₁)(1 − p₂)…: at least one of its spots is up.
   Different kinds (an ore and a herb) add up, since they spawn independently.
5. Stops worth less than 0.05 are dropped.

A grid of 60-yard cells makes the grouping and the neighbour lists linear. The largest zone in the
current data, The Barrens, has about 650 ore and 450 herb points: a few hundred stops after grouping.

### 4.4 Travel time

- Distance: straight line in yards, from `ZoneSize`. There is no pathing in the addon API; section 8
  covers walls and cliffs.
- Time: distance ÷ speed, plus 5 seconds per node actually gathered. Speed is the fastest you have
  moved in the zone recently (`GetUnitSpeed`), 7 yards a second until known. Speed only rescales
  minutes, never the shape of the loop.
- No distance matrix (500 stops would mean 250,000 entries): distances are computed when needed, and
  each stop keeps its 10 nearest stops.

### 4.5 Starting loop

1. Cheapest insertion, starting from the three stops farthest apart.
2. 2-opt over each stop's 10 neighbours, until nothing improves.
3. Or-opt: move runs of 1 to 3 stops to a better place near a neighbour, either direction.
4. Don't-look bits: stops whose surroundings did not change are skipped, keeping passes near linear.
5. Kicks: a double bridge (cut in four nearby places, reconnect the other way), re-tidy with 2 to 4,
   keep if shorter. Fixed seed per zone.

### 4.6 Dinkelbach: the loop with the most nodes per minute

The goal is the loop S with the highest rate V(S) ÷ T(S): expected nodes collected over expected
loop time. Dinkelbach's method reaches it by solving, a few times, the easier problem

  maximise  V(S) − λ·T(S)

for a fixed λ, and then setting λ to the rate of the loop found. The rate goes up every round and it
settles in 3 to 6 rounds. The inner problem is a prize-collecting tour: a stop belongs in the loop
exactly when the nodes it brings are worth more than λ times the time it adds, so far-off thin
stops drop out and the loop closes round the good areas. λ means "nodes per minute you would
otherwise get", which is easy to show the player.

Each round's inner problem uses the moves of the orienteering heuristics:

- **drop** the stop with the lowest value against the time it saves,
- **add** the outside stop with the best value against the time it costs,
- **swap** one in, one out,
- tidy with 2-opt and Or-opt; a few kicks.

The inner problem starts from two places and keeps the better: the whole-zone loop trimmed down, and
loops grown from the 5 best seeds (most value within 200 yards). Trimming alone can leave a long
corridor between two good areas; growing from a seed cannot.

Respawn ties value to time (V depends on T through up(T)), which makes the problem non-linear. Each
round fixes the respawn factor from the previous round's loop time, the usual fixed-point treatment;
the rounds stop when both λ and T change by under 2%.

With `/sl route 15` the outer loop is skipped: the inner problem is solved with a 15-minute budget
instead (the classic orienteering problem).

### 4.7 Polish for skipped stops

Up to here, the loop was judged by its full length. But you skip stops whose node is not up, so the
length that matters is the expected length after skipping. For a loop with stops 1…n, each up with
chance pᵢ:

  E[length] = Σᵢ Σⱼ pᵢ · pⱼ · d(i, j) · Π (1 − pₖ) for the stops k between i and j

(Jaillet's formula). It prefers loops where the unreliable stops lie on the way between reliable ones,
so skipping them costs nothing, over loops that make detours to them. The final pass runs 2-opt and
Or-opt again using this measure: the 2-p-opt and 1-shift moves, with the corrected formulas of Bianchi,
Knowles and Bowler and the unequal-chance version of Bianchi and Campbell. To keep it fast, each sum
stops once the product of the (1 − pₖ) falls under 1%. With typical chances that is about 8 stops,
so a move costs a few dozen operations instead of a pass over the whole loop.

### 4.8 Running inside the game

The solver runs as a coroutine, resumed from the existing driver for at most **4 ms per frame**. The
starting loop is drawn as soon as it exists, usually within the first second. Dinkelbach rounds and
the polish follow, for at most 3 seconds of game time, and the route is redrawn once when done. Above
600 stops, the lowest-value ones are left out first; no zone in the current data gets near that.

## 5. Commands

Same style as the rest: a bare verb toggles, `on` and `off` say what they mean.

| Command | What it does |
| --- | --- |
| `/sl route` | Route on or off in this zone. On: plans (or reuses) the loop, draws it, says what it is |
| `/sl route on` / `off` | The same, explicitly |
| `/sl route new` | Plans again from the current data |
| `/sl route 15` | A loop of about 15 minutes; `/sl route auto` goes back to the best per minute |
| `/sl route safe` | No bonus for untested spots: only what is already known. Again to turn it back |
| `/sl route reverse` | Same loop, the other way round |
| `/sl route skip` | Not worth it; point at the stop after |

On, it says in one line what it built, for the nodes shown:

> Route in The Barrens (copper, tin): 38 stops (14 found by you, 9 spotted, 15 imported), 4.1 km,
> about 11 min a loop on your mount, about 17 nodes a loop (1.5 a minute).

Settings: `cfg.route`, `cfg.routeMinutes` (nil = auto), `cfg.routeSafe`, and the saved routes in
`cfg.routes[mapID]`. All go into `RESERVED`. `/sl reset` turns the route off and keeps saved loops.

## 6. Drawing and following

**World map.** One line between consecutive stops (the client's `Line` object, `canvas:CreateLine()`,
`SetStartPoint`, `SetEndPoint`, `SetThickness`; check the Forever client has it first, and fall back
to rotated textures if not). Stops on the loop get a thin ring around their pin, the next stop a
bright one. Lines sit under the pins.

**Minimap.** Lines cannot be clipped to the round minimap, so the route is drawn as small dots every
few yards along each segment, only where they fall inside the edge. This reuses the pin placement
maths (rotation, zoom) and the nearby-pins search.

**Next stop.** The next stop in the route's direction, skipping greyed-out ones (recently gathered).
It moves on when you gather or spot there, probe it empty or walk past (all already detected), come
within 25 yards of it, or type `/sl route skip`. Leave the loop and come back elsewhere, and it picks
the nearest stop ahead. If the client has `C_Map.SetUserWaypoint`, the next stop becomes a waypoint
(idea 10's arrow for free). Flight paths, being dead and combat pause it.

## 7. Keeping the route stable

- **Saved per zone**, with a signature of the filters (shown kinds, picked nodes, `/sl xp`,
  `/sl reliable`, safe mode). Same zone and filters: same route back. Filters changed: a new route
  at once (section 1).
- **Never replanned while you follow it.** New finds and checks change values, not the drawn loop.
- **A better route:** after each full loop, the addon plans again in the background. If the new loop
  collects at least 15% more per minute, it says so once: "A better route is ready: /sl route new".
- **Spots that moved** (merged, absorbed by your own node) are matched to the nearest spot of the
  same type within 30 yards, so saved stops keep their data.

## 8. Walls and cliffs

The solver cannot see terrain. Stops come from where people stood and most legs are short, so most
lines are walkable; long legs are the risk. While you follow the route, each leg is timed. If one
takes more than 1.6 times its straight-line time, twice, outside combat, its real time replaces the
straight-line one and the next plan avoids it. Stored per zone as a short list of slow legs.

## 9. Code layout

- **`RouteSolver.lua`**: pure Lua, no game calls. Input: stops `{ x, y, p, value }` in yards, speed,
  τ, and a budget or "auto". Output: the ordered stops and the expected rate. Grouping, neighbour
  lists, local search, Dinkelbach, the expected-length polish, as a step function the caller runs
  for as long as it likes. Being pure, it runs in the test suite (idea 28) under plain `lua`.
- **`Route.lua`**: the game side. Builds the stops from `BuildList` (exposed on `ns`, with `Decode`,
  `ZoneSize`, `PlayerPos` and the stats), runs the solver from the driver, draws, follows, saves,
  and registers `/sl route` through `ns.RegisterCommand`. It also hooks the filter commands so a
  change replans (section 1).
- **TOC:** both after `SkipLoading.lua`, before `Kinds\`.

## 10. Tests

- Known shapes (circle, grid) where the best loop is obvious.
- Random cases of 10 to 12 stops against an exact Held-Karp solver in the test script: match in
  nearly all cases, never over 2% worse.
- Larger random cases against the Held-Karp lower bound (1-trees with subgradient steps), to report
  how far from the best possible the full loop can be.
- The expected-length formula against brute-force enumeration of which stops are up, for small loops.
- Dinkelbach: the rate never goes down between rounds, and a short τ gives a shorter loop than a
  long one.
- Filters: hiding herbs removes every herb stop; `/sl only copper` gives a copper-only route.
- Same data and seed, same route. The Barrens with both kinds: no step over 4 ms on plain Lua.

## 11. Build order

1. **Whole-zone loop (S to M).** Values, grouping, starting loop, world map lines,
   `/sl route [on|off|new]`, replanning on filter changes. Already useful with `/sl only` and `/sl xp`.
2. **The best loop per minute (M).** Dinkelbach, drop/add/swap, grown loops, respawn model,
   `/sl route 15|auto|safe`.
3. **Following (S to M).** Minimap dots, next-stop ring, advancing, `skip`, `reverse`, waypoint.
4. **Polish and stability (S to M).** The expected-length polish, saved routes, the "better route"
   note, slow legs.

## 12. Left out on purpose

- **Routes across zones.** Needs world coordinates (idea 18) first.
- **Exact respawn timers.** The server does not share them; section 4.2 is the honest estimate.
- **Re-planning after every sighting.** Better in theory, unusable in practice: the loop would move
  under you. The next-stop skip gives most of the benefit.
- **A route editor.** It is what makes the Routes addon big. Filters and `skip` cover most needs.
- **Reading anything beyond what the game shows you.** Same rule as everywhere else.

## 13. As built: what changed, and why

Measured on the real data for The Barrens (1,097 imported ore and herb points), mount speed.

1. **Auto mode keeps loops to 30 minutes.** As planned, Dinkelbach's method chose a loop round the
   whole zone: 715 stops, 103 minutes, 3.70 nodes a minute. Mathematically right (where nodes are
   spread evenly, the rate hardly depends on the loop's size), but nobody farms a 103-minute loop.
   Auto mode now finds the best loop of at most 30 minutes first (solver parameter `maxMinutes`),
   then runs the Dinkelbach rounds from that loop's rate, keeping a better loop only if it also
   fits. Result: 163 stops, about 20 minutes, **4.37 nodes a minute**, better than the whole-zone
   loop, because the shorter loop keeps to the dense areas and skipping empty stops is cheap there.
   `/sl route 60` still allows longer loops.
2. **The fixed-length solve does not bisect a cost per yard.** That method (the Lagrangian
   relaxation of the time limit) failed on real data: as the cost per yard crosses the best rate,
   the best loop jumps from the whole zone to a handful of stops (a duality gap), so bisection never
   finds the loops in between; it returned 37 stops in 4 minutes for a 30-minute budget. It is
   replaced by the construction most orienteering heuristics use: insert the stop with the most
   value per added minute while the loop fits, starting from the whole loop trimmed to fit and from
   each seed; tidy with 2-opt and Or-opt, grow into the time that frees, keep the best.
3. **Order of work.** The capped loop is found first (about 0.35 s of work in The Barrens); the
   Dinkelbach rounds after it only improve it. So when the time budget runs out, the route is
   still a good one. Before this change, the 1.5 s budget cut the result to 2.58 nodes a minute;
   now the budget is not reached (1.1 s of work in all) and nothing is lost.
4. **Cheaper drop and add moves.** Dropping removes every stop not worth its length in one sweep
   round the loop (repeated until none), not the single worst stop each time, which was quadratic.
   Adding looks only at stops in the neighbour lists of stops on the loop, so loops grow outwards.
5. **Kicks accept equal loops.** Kicks that give a loop exactly as good are kept, so the search can
   move across loops of equal length. Grids are still the worst case for 2-opt: an 8 by 8 grid
   needs about 1,000 kicks to reach the best loop. Real data is far from a grid, and small random
   cases are solved exactly in 29 or 30 of 30 runs, never more than 0.6% above the best.
6. **The polish uses the 2-p-opt move only.** 1-shift (moving one stop) would need a second set of
   delta formulas; Or-opt already moves single stops in the earlier phase. The expected-length sums
   are checked against brute force (every combination of stops up or empty) in the tests.
7. **The fixed length is the time with every node up.** `/sl route 5` gives a loop of at most 5
   minutes when every stop has a node; with empty stops skipped it takes less, and the message
   gives both numbers.
8. **Combat does not pause the pointer**, only the timing of the leg you are on (a fight is not a
   slow leg). Flight paths and being dead pause both.

Tests (`tests\route_test.lua`, `tests\route_game_test.lua`): 77 solver checks and 40 game checks,
including the circle and grid cases, Held-Karp on small cases, expected length against brute force,
Dinkelbach and respawn behaviour, fixed lengths, determinism, the copper-only and tin-only routes,
replanning on a filter change, following, reversing, saving and reusing. On a Lua compiled to
WebAssembly (close to native speed), no slice of planning ran longer than about 5 ms.

**Not yet checked in the game itself:** the line objects on the world map (`CreateLine`; a dotted
fallback is used if the client has none), the minimap dots' look, and the waypoint. These are the
first things to look at on the Forever client.

## 14. Where you are, and the ground: what changed after playing with it

The first version planned the best loop of the zone and nothing else. Measured on The Barrens from
five places: the same loop from all of them, up to 4.5 minutes' ride away; and with ores only, one
loop round the whole zone (y from 0.11 to 0.86 of the map) with a leg of 1,100 yards.

1. **The route is planned from the player.** The solver takes the player's position. Loops are
   grown from two seeds of theirs (the richest of the 8 stops nearest to them, and the richest stop
   within a 2-minute ride) as well as from the richest areas of the zone, and every loop found is
   weighed as what it collects × (1 − ride to its nearest stop ÷ 10 minutes). A loop 3 minutes off
   has to collect over 40% more to win. When one that collects 15% more was passed over, the result
   says so and the addon tells the player; `/sl route anywhere` is the old behaviour.
2. **Auto mode compares loops of several lengths.** The best loops of 10, 5 and 20 minutes are built
   first, then the Dinkelbach rounds start from the one chosen. The cap is 20 minutes, not 30, and a
   loop as long as the cap must collect 15% more a minute than a very short one. Without this, where
   nodes are thin and even (ores in The Barrens) the whole-zone loop won by a few percent on the
   respawn guess alone. Farming guides agree: several short loops beat one round the zone.
3. **Long legs ride longer than drawn.** A leg of d yards counts as d × (1 + 0.5 × d ÷ (d + 400)):
   100 yards as 110, 400 as 500, 1,100 as 1,500. There is no terrain in the addon API; this is the
   usual allowance for the way round things, and it makes a long jump cost more than the same way
   through stops in between, which are places somebody stood. Lengths shown stay as drawn.
4. **Slow legs spread.** A leg timed as slow also slows every leg from a stop within 60 yards of
   its one end to a stop within 60 yards of its other. Before, only that exact pair of stops was
   slowed, and the next plan crossed the same cliff one stop along.
5. **Skipped stops.** `/sl route skip` from more than 25 yards away counts against the stop; at two,
   the spots within 30 yards of it are left out of new routes. `/sl route forget` clears this and
   the slow legs for the zone.
6. **The polish may not untidy the loop.** Where most stops are likely empty the expected-length
   polish reordered small loops into zig-zags (shortest if you skip nearly everything, which takes
   seeing each stop is empty, from near it). It is now kept only if the loop as ridden grows by at
   most 3%.
7. **Saved routes know where they were planned.** A saved route more than 90 seconds' ride from the
   player (and not planned from about where they stand) is planned again on turning the route on or
   entering the zone. While following, the route is still never replanned; far from it, the player
   is told once.
8. **The first stop** is the nearest one, or the one after it only when the player is already on the
   line to it (within 40 yards of the leg, past the nearest stop). Before, a nearby stop was passed
   over whenever the one after it was nearer than the leg between them was long.
9. **Neighbour lists use a grid**: 7 ms in place of 140 ms for The Barrens.

Same five places after the change: the route's nearest stop is within a minute's ride in all of
them, loops are 8 to 17 minutes, and the ore loop covers a third of the zone.

**Popular routes from guides** were looked at as a source. They are published as pictures of a map,
not as coordinates, and the route-sharing addons (Routes, PathMaker) exchange strings in their own
formats, so there is nothing to import yet. What the guides say in words is in items 2 and 3.

**Still a guess:** the time and rate announced assume empty stops are skipped at no cost, which
flatters loops where most stops are empty. Choosing between loops does not use those numbers.

## References

- Feillet, Dejax, Gendreau (2005), Traveling Salesman Problems with Profits, Transportation Science.
- Jaillet (1985/1988), the probabilistic TSP and the expected length of an a priori tour.
- Bertsimas and Howell (1993); Bianchi, Knowles, Bowler (2005), correction to the 2-p-opt and 1-shift
  algorithms, EJOR 162(1); Bianchi and Campbell (2007), the heterogeneous probabilistic TSP, EJOR.
- Angelelli, Archetti, Filippi, Vindigni (2017), The probabilistic orienteering problem, Computers &
  Operations Research 81.
- Dinkelbach (1967), On nonlinear fractional programming, Management Science.
- Vansteenwegen, Souffriau, Van Oudheusden (2011), The orienteering problem: a survey; Gunawan, Lau,
  Lu (2015), iterated local search for the orienteering problem with time windows.
- Mennell (2009) and later work on the close-enough TSP (considered, not used).
