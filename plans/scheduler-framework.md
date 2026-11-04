# Scheduler Framework (Phase 1 Specification)

Design only, no code. This is the minimum needed to build the isolated
framework of Phase 1 in [scheduler-utilization.md](scheduler-utilization.md),
using the costs in [scheduler-audit.md](scheduler-audit.md) and the bound rule
in [scheduler-contracts.md](scheduler-contracts.md). Costs are Lua VM
instructions; the figures quoted here are the contracts' declared values and
will move when they do.

## 0. Shape of version 1

- A separate library, `lib/scheduler.lua`, loaded only when the host mode is not
  `legacy`, so `legacy` costs nothing and behaves as today.
- It contains task registration, the planner and a plan record. The near-miss
  tripwire and shadow mode are dev tooling outside it (section 6).
- Two tiers, one ordering rule, one fixed margin. Everything that is tuning is
  out (section 8).

## 1. Where the scheduler runs

Today's scheduling is spread over eight call sites in `main.lua`. The table is
the starting point: a site keeps its existing behavior until it migrates, and
every site migrates before the old scheduler is retired (section 7).

| Site | Today | Version 1 |
|---|---|---|
| `refresh` tail (1614-1615) | `updateServices`, `dispatchDue` | `steady` kind |
| `background` tail (1653-1654) | `updateServices`, `dispatchAll("background")` | `background` kind: services only. Panel `background` hooks are not tasks; they stay in `overhead` (26 each) |
| `pumpFlight`, head of `refresh` and `background` (1388, 1623) | every callback, before all early returns: identity check, reset poll, tick; it consumes the callback on a first document load and when Smart is running during a modal or loading callback | Stays at the head. Its costs are passed to the scheduler as `used` (below). The tick moves into the framework only under the preconditions in section 5 |
| `configureFlight` calling `pumpFlight(host)` (main.lua 604-613; `dashboard_loader.lua` 631; `editor_controller.lua` 193) | a flight document load plus a tick inside the last loader stage or an editor save, unaccounted today | Counted in that stage's declared bound when the loader family moves (R6); an audit item |
| `pumpSessionReset` (1394, 1629) | consumes the callback; runs every service's and panel's `resetSession` | Unchanged. A consumed callback runs no scheduler |
| loader, reflow, app rebuild, page retire and rebuild, menu, editor save, settings UI advance | consume the callback, each bounded by the audit (loader family) or unmeasured (UI) | Unchanged in Phase 1; become kinds in R5 and R6 (section 4) |
| settings UI with no pending work (1403), log viewer (1552, 1559), editor with panels (1567-1568) | `updateServices` (and `dispatchDue` for the editor) next to handler work that is unmeasured | **Modal sites.** Until R5 they keep the legacy loop. The owner is per callback kind: `steady` and `background` follow the owner table, modal kinds stay `legacy`. A split service and its legacy service object share one source of truth (`entry.due`, section 5.2), so a source polled by one is not due for the other and nothing runs twice; a piece that finds its entry not due does no work and returns the remaining delay. Recording in modal callbacks therefore behaves as today. At R5 they become modal kinds (section 7) |

**Consumed callbacks and `used`.** When a head step returns "callback
consumed", the scheduler is not run, exactly as `updateServices` is not today.
When the head work ran and the callback continues, the host calls
`s:run(kind, now, used)` where `used` is the declared cost of what already ran:
the reset poll (when a reset is configured), and the flight tick when it is
still legacy-owned and ran. Recording continues in consumed callbacks no
better or worse than today.

**Widget contexts.** One scheduler per widget context. The flight broker is
shared by contexts (main.lua 534-537), so the shared flight tick and Smart tasks
are registered only by the context that owns the broker (the one `pumpFlight`
runs for today), never twice.

## 2. Tasks

A task is declared once as data and instantiated as a plain table with a
`step` function. The declaration is loadable without the radio API, so the
simulator and CI read the same bounds the widget uses. One declaration table is
shared by all tasks of a type; a task whose bound depends on load-time data (a
telemetry source with `k` recordings) gets its own.

```lua
declare = {
    class   = "critical" | "normal",
    exclusive = false,       -- true for chart stages: at most one exclusive task per callback
    shared  = nil,           -- { name = cost }: charged once per plan, whoever runs first
    kinds   = { steady = true, background = true },   -- default: both
    first   = "run",
    stages  = { run = { fixed = F, perUnit = U, maxUnits = N } },
}
instance.stage, instance.want    -- read at plan time, kept current by the owner
step(instance, grant, stage, now) -> delay
```

- **Cost of a step** at grant `g` (1 <= g <= `maxUnits`) is at most
  `fixed + g * perUnit`. An indivisible task declares
  `fixed = 0, perUnit = bound, maxUnits = 1`. `perUnit` is positive. The bound
  holds whatever the backlog, so accumulating work caps itself at `maxUnits`
  and drains over later releases.
- A **unit** is a count of items (sources polled, knots projected, entries).
  The grant is `min(instance.want or maxUnits, maxUnits, what fits)`.
- **Stages** exist because a chart's next step varies a lot (1.3k begin, 0.83k
  per knot, 7.8k text). `instance.stage` names the stage the next step will run;
  single-stage tasks need nothing.
- `want` and `stage` are fields, not step results, so a subscription change or a
  reset between releases cannot leave a stale value: they are read when the plan
  is made. The owner may still be wrong between planning and running (a reset,
  a model change or a geometry change can alter the chart's phase), so the step
  contract is: **`step` runs exactly the planned `stage` with at most `grant`
  units, or does no work and returns 1** (the instance then publishes its real
  stage). A no-work exit costs less than the smallest declared stage. The step
  may set `instance.used` (units consumed) so tests assert `used <= grant`.
- `delay` is an integer number of ticks (10 ms) >= 1. Due time is
  `now + delay` from the callback in which the task actually ran, so one
  release is pending per task, there are no catch-up bursts, and 1 means "ready
  at the first callback at least one tick later", not "next callback".
- `kinds`: a task is planned only in callbacks of those kinds. Services accept
  `steady` and `background`; panel refresh and chart stages accept `steady`
  only. A task with nothing to do is not registered.
- Registration: `s:add{ id, decl, instance, due }` and `s:remove(id)`, at most 128
  tasks. `due` carries the phase offset (section 3). An add or remove during a
  plan takes effect at the next plan.
- `pcall` guards every step. An error or a rule violation retires that task and
  reports it once, as `panelHost.dispatch` and `services.update` do today. The
  report (`addError`, `showErrors`, label creation) is a one-off path outside the
  budget: the framework queues it and the host reports it at the head of the next
  callback, which it treats as consumed (R6 measures it).
- A migrated task never ends the callback itself.

### Example: a service piece (one telemetry sensor, critical)

Services are split into independent tasks (section 4). Each subscription is its
own task, created at load with a declaration for its `k` history recordings
(known then; a poll records into all of them in the same call).

```lua
declare = {                                        -- built per source from k
    class = "critical", shared = { link = 560 },   -- link state, charged once per plan
    stages = { poll = { fixed = 0, perUnit = 420 + 760 * k, maxUnits = 1 } },  -- k = 1 measured
}
function telemetry.step(self, grant, stage, now)    -- one sensor
    local entry = self.entry
    if entry.due > now then return entry.due - now end   -- already polled elsewhere: no work
    self.service:ensureLink(now)                    -- cached per callback
    self.service:poll(entry, now)                   -- poll and record in one call; sets entry.due
    return entry.interval                           -- effective interval, section 5.2
end
```

### Example: a staged chart (normal, exclusive)

```lua
chart.declare = {
    class = "normal", exclusive = true, first = "begin",
    kinds = { steady = true },
    stages = {
        begin   = { fixed = 0,   perUnit = 1300, maxUnits = 1 },
        project = { fixed = 200, perUnit = 830,  maxUnits = 9 },       -- grant = knots
        apply   = { fixed = 0,   perUnit = 1300, maxUnits = 1 },
    },
}
function chart.step(self, grant, stage, now)
    if self.stage ~= stage then
        return 1                                    -- state moved on: no work
    end
    self:runStage(grant)                            -- also sets self.stage and self.want
    return self.frameDone and self.interval or 1
end
```

Today's `chart.refresh` chooses its phase from `framePhase`, `frameExpired` and
`pending`. The migration extracts that choice into a `stageOf` the instance
keeps in `instance.stage`; the 7.8k text stage must also be split before it can
be declared (contracts, Flag rows).

## 3. Planner

State: two arrays of task records, one per class, each sorted by `(due, seq)`,
`seq` being the registration order. Insertion is a binary search; only tasks that
ran are re-inserted and the shifting is done by `table.insert` and
`table.remove`. Only the due prefix of each array is read.

`R = ceiling - margin - overhead[kind] - used`. One pass:

1. **Critical.** Ready (`due <= now`) critical tasks eligible for the kind, oldest
   first, at most `K_c = 10` examined, planned while the plan stays within
   `R - normalReserve` (`normalReserve = 2000`, about the tick plus one small
   chart stage). A critical task that does not fit waits and is first next
   callback; it is never dropped.
2. **Normal.** Ready normal tasks, oldest first, at most `K_n = 6` examined,
   against what remains of `R`.
3. Each task is skipped if it is `exclusive` and one is already planned.
   Otherwise grant `g = min(want, maxUnits, floor((R - fixed) / perUnit))`; if
   `g >= 1` plan it and subtract `fixed + g * perUnit`, else skip it and try the
   next (work-conserving). A `shared` cost is subtracted the first time a task
   naming it is planned.
4. **Stop** after `maxRun = 12` planned tasks or when `R` is below the smallest
   `fixed + perUnit` of any registered stage. **Run** the plan in order; after
   each step set `due = now + delay`.

| Rule | Why it is needed |
|---|---|
| Critical before normal, with a normal reserve | Telemetry, history and control are recording and are never dropped. The reserve stops them from starving the tick, Smart, session reset and every chart and panel. Safety never depends on either (`R` bounds every plan); only latency does. |
| `exclusive` | One chart per callback, as today (a legacy chart has `refreshCost = 6`, the whole cap). Used by chart stages only. |
| Oldest release first | One rule gives fairness and bounded waiting. It replaces aging, deadlines and tolerances. |
| Skip and continue | Uses the leftover budget. Everything due runs together whenever it fits. |
| Grants in units | A divisible task fills what is left instead of reserving its worst case. This is also the "filler". |
| `K_c`, `K_n`, `maxRun` | Bound the planner's own cost; two lists mean a stall of critical work cannot hide normal work. |

**Stagger.** Periodic tasks (services, sensors) get an initial `due` offset of
`5 x (index mod ceil(interval / 5))` ticks, `index` being the registration order.
It is a fixed rule, not an allocator, so it costs nothing on the radio and is
reproducible; the peak `P` it gives is reported by the simulator for the mixes in
section 4 (a hand placement can be a little lower, about 4.3k against 4.9k for
mix A). Phases drift when callbacks are irregular and do not re-heal after a late
run; safety never depends on them, only the tests (C) and wait do.

**Design-time admission test** (CI, per ownership configuration and kind). Let
`base = ceiling - margin - overhead - H - L`, `H` the largest `used` the host
can pass and `L` the legacy cap (section 7):

- (A) every stage's smallest step `fixed + perUnit` is at most `base - P`, so the
  first ready task always runs. Checked on the regular callback; while the tick
  and Smart are legacy, the callback that also runs Smart may delay a larger
  piece by one callback;
- (B) sustained critical load `sum(cost x 5 / interval)` is at most
  `base - normalReserve`; otherwise a backlog grows or normal work stalls;
- (C) the peak `P` of critical load due in one callback, from the simulator with
  the stagger rule, is at most `base - normalReserve`;
- (D) every legacy item's declared bound is at most `L`;
- (E) every indivisible piece and every smallest step is at most the maximum task
  size (section 4).

**Layout admission (at load, on the radio).** The tests above use fixed mixes, but
layouts vary. The host sums the declared sustained load of the registered critical
tasks; if it exceeds `base - normalReserve`, the telemetry service lengthens every
source interval by the same factor (rounded up, never above 50 ticks, section
5.2) and logs a notice once. Critical work is never shed and normal work does not
stall: rates degrade. For example 16 recorded sources at 10 Hz is about 11.3k
sustained against 9.2k, a factor of about 1.25.

## 4. Budget and feasibility

Facts used, all from the plan: EdgeTX kills a callback past 20000 instructions
and the widget stays dead until reloaded, so safety is planned. `getUsage`
reports only the previous complete callback, in 200-instruction quanta, and
cannot attribute cost between tasks.

- `ceiling = 15000`, `margin = 400` (two quanta, fixed).
- `overhead[kind]` is declared by the host as the audited `base + slope * panels`
  plus the framework term below, once. Callbacks have kinds `steady` and
  `background` until the modal kinds of R5.
- **Planning never reads `getUsage`.**
- **Framework cost** per callback is `F0 + (K_c + K_n)*c1 + maxRun*o`: a fixed
  part, `c1` per examined task and `o` per task run (section 4.2). Go/no-go for
  Phase 1: the measured worst case at 32 tasks must be at most **500**, the term
  added to `overhead` (more than that spends the headroom the framework exists to
  recover). Above it, fix the design (lower the `K`s, merge tasks) or recompute the
  tables with the measured value. Heap: one shared declaration per type and one
  small record per task, reported from `collectgarbage("count")` at 128 tasks; the
  threshold is set from that measurement because the radio's Lua heap limit is
  not in the plan.

### Worked feasibility (16 panels)

`C = 15000 - 400 - (1250 audited overhead + 500 framework) = 12850`. The Smart change
in the flight migration (5.1) splits today's 3600 flight tick into the tick proper (arm
switch, counting, output; about 1000, estimated) at the current cadence and
Smart (2600) at most once per second. Head `used` while both are legacy: reset
poll 620 plus the tick, so **T** = a callback with the tick (room base 11230)
and **TS** = the callback each second that also runs Smart (room base 8630).
Until R4 legacy Smart keeps its current cadence (about every 10 ticks), so in
R1 to R3 a TS callback comes about every second callback rather than once per
second; the 1 Hz cadence and these figures hold from R4.
Room = base `- L - P`. `L` is the largest legacy item, one share for
`updateServices` and `dispatchDue` together (services first, panels get the rest).
`P` is the **peak load of critical tasks that fall due in one callback** after
staggering, not the sum of all of them (all due together would be 13.3k) and not a
group maximum. While telemetry is legacy it is the largest legacy item: the
legacy service runs every 10 ticks, so it must poll `2D` sources per update,
`n_L = ceil(2D) + 1` (mix A: 5, cost `750 + 5 x 1180 = 6650`; mix D: the cap of 8,
10190). That makes **5.2 a precondition of R1**, not R2, with the charts and
panels opted in; without it `L` is 10190 and nothing fits. Declared values from
the contracts; mix A below is the reference.

| Phase | New-owned | `L` | `P` | Room T | Room TS | Preconditions |
|---|---|---|---|---|---|---|
| R1 | chart stages | 6650 (legacy telemetry, 5.2 in) | 0 | 4580 | 1980 | Section 5.2 merged. Split chart text (7800) under the cap (4.2). Other chart stages fit (900 to 1300; project grant 1 knot = 1030). |
| R2 | + panel refreshes | 6650 | 0 | 4580 | 1980 | Split metric relayout and output apply under the cap. Until R4, TS callbacks come about every second callback, so a piece above 1980 runs only in the others. |
| R3 | + services as tasks | 0 | 4890 | 6340 | 3740 | Services split as in 4.1; telemetry and history measured (open decision 1, deferred). |
| R4 | + tick and Smart as tasks | 0 | 4890 | 7340 | | Section 5.1 contract and loader-callback precondition. The 7340 is shared with the tick (1000) and Smart (2600, once per second), so net capacity equals R3. |
| R5 | modal screens: settings UI, log viewer, editor, menu, fullscreen input, location details, app rebuild, theme showcase | 0 | per kind | per kind | | Each measured natively first and split to fit its kind's room (section 7). Order: smallest handler first. |
| R6 | loader, reflow, page retire and rebuild, session-reset pump, the head work, `configureFlight` | 0 | per kind | per kind | | Already measured in the audit; split where it exceeds the cap (4.2). |

**Telemetry mixes** (8 sources, per-source intervals from section 5.2, a callback
about every 5 ticks, history 650 every 5, control base 1300 and entries 1320
every 20, link 560 once per callback that polls a source). `P` is from the
simulator with the stagger rule; the sustained load is the mean.

| Mix | Sustained | Peak `P` | Room T / TS / R4 | Legacy `L` |
|---|---|---|---|---|
| A: 8 recorded, 4 Hz (25 ticks) | 3750 | 4890 | 6340 / 3740 / 7340 | 6650 |
| B: 8 recorded, 1 Hz (100 ticks, so 50 after the cap) | 2000 | 3710 | 7520 / 4920 / 8520 | 3110 |
| C: 4 recorded and 4 unrecorded as one batch, 5 Hz (20 ticks) | 3470 | 4070 | 7160 / 4560 / 8160 | 6650 |
| D: 8 recorded, 10 Hz (today) | 6590 | 7250 | 3980 / 1380 / 4980 | 10190 |

Per-source intervals are what make the numbers work: today's 10 Hz mix D needs
`P` = 7.3k. Mix B is computed at 100 ticks; the 50-tick cap of 5.2 raises its
sustained load to about 2.7k. Panel builds (3.5k to 11.5k) are not tasks in R1
to R4: they run in their own loader callbacks. The `background` kind has the same
shape with overhead about 1130 (0.41k plus 26 per panel at 16 panels; the
contracts' 0.62k was too low), so about 12.4k before `P`, with only services
eligible; its callback rate is unverified (section 8).

### 4.1 Service split granularity

Every service becomes independent tasks, each with its own declared bound, and
all that are due run together when they fit. Costs are audited (M) or estimated
(E) per the audit; declared values follow the contracts' rule. A service whose
work is not small, predictable and bounded cannot be registered until split.
Pieces below the minimum useful size (4.2) stay as units of one task, not as
separate tasks.

| Service | Tasks | Audited cost | Declared | Flag |
|---|---|---|---|---|
| telemetry | one per recorded source (`k` recordings), one batch task for unrecorded sources sharing an interval, a precision scan queued as work of the next release, not a new task | recorded 0.94k at `k` = 1 (poll 0.12 + record 0.73 + loop 0.09); unrecorded 0.33k; link state 0.17 to 0.37k, once per plan; scan 0.15k | `420 + 760 k` per source (1.18k at `k` = 1), 0.42k unrecorded, link 0.56k shared | The bound is per instance and `k` > 1 is unmeasured (open decision 1, deferred). A poll records into all `k` recordings in the same call (`history` needs `updatedAt == now`), so a recording can never be deferred. |
| history | one task: advance and boundaries, one entry per update | 0.44k (0.38k advance and boundaries plus 17 per entry) | 0.65k | Recording itself lives in the telemetry poll (observer), not here. |
| control | outputs task (units = outputs, up to 32, interval 10 when an output panel exists), base task, entries task (6 entries) | fixed 0.97k and 0.21k per entry measured; the cost per output is not itemised | base 1.3k, entries 1.32k (2.6k total), outputs unmeasured | **Flag.** `update` reads every output each call (`control_service.lua` 616-619): split it into its own units task and measure it; the mixes assume no output panel and are re-run with one. |
| model | one task, units = facets (4) | 0.06k fixed, 0.1k per facet | 0.54k | None. |
| navigation | one task, units = entries (2) | 0.04k fixed, 0.28k per entry | 0.71k at 2 | 2 entries is estimated (E). |
| flight tick | tick, and Smart as its own task | tick about 1.0k (E); Smart 2.0k (discovery scans 8 sensors, then 4 reads) | Smart 2.6k | Smart splits per sensor read if needed; the tick's nested `services.update` makes its total measured, not summed. |
| session reset steps | one task, units = items (8) | history 0.07k, navigation 0.01k | 0.2k | None. |
| armed | none | no scheduled update | | None. |

### 4.2 Task size and per-task overhead

**Per-task overhead `o`** is what the framework spends per task run outside the
task's own bound: planner examine and admit, the `pcall` and step wrapper with
its result checks, and release bookkeeping (binary-search reinsertion). A task's
own resume cost stays in its stage's `fixed`. Also measured: the heap of a task
record, `c1` per examined but skipped task, and the fixed part `F0`.

**Measurement (native, Phase 1).** The harness runs `N` stub tasks whose `step`
only returns a delay, at `N` = 8, 32 and 128, running `k` = 1, 4, 8 and 16 per
callback. Count versus `k` gives `o` (slope) and `F0` (intercept); a callback
with many ready but unfitting tasks gives `c1`. Go/no-go is the 500 rule of
section 4 (`F0 + (K_c + K_n)*c1 + 12*o <= 500` at `N` = 32); the targets that
satisfy it are about `F0` 40, `c1` 6 and `o` 30, all unmeasured. If `o` is higher, the tables
and the minimum size below are recomputed with the measured value.

**When to split.** Splitting a piece `P` into pieces of size `p` costs
`o_eff = o + resume` per piece and wastes about `p / 2` of room per callback on
packing (a piece of size `p` cannot use a smaller leftover), so total waste is
about `p / 2 + (P / p) * o_eff`, smallest near `p = sqrt(2 * P * o_eff)`. For the
chart text (`P` 7.8k, `o_eff` about 130) that is about 1.4k. Rules:

- Split when a piece exceeds the maximum size `M`. Otherwise split only at a
  natural boundary, and only if each piece stays at or above the minimum useful
  size `max(1000, 10 * o)` (overhead at most 10% of the piece).
- Never split below the minimum. Batch smaller items that share a release as
  units of one task (unrecorded sensors, control entries, model facets).
- A divisible task is not limited by `M`: its grant fills the room. Its smallest
  step (`fixed + perUnit`) must be at most `M`.

**Recommended maximum task size `M = 4000` declared**, for every indivisible
piece and every smallest step. Against the room left after the peak critical load
in a regular callback (table above): 6340 (A), 7520 (B), 7160 (C) and **3980 for
today's 10 Hz mix D**, the heaviest and effectively at the cap. 4000 is the round
cap closest to D; 5000 does not fit it, and 4000 fits A 1.6 times. The callback
that also runs Smart while it is legacy has 3740 (A) and 1380 (D): a piece above
that waits one callback, and only until R4. The audited tasks above the cap, with
declared values:

| Task | Declared | Over 5k | Over 4k | Split and its cost |
|---|---|---|---|---|
| chart reading text and legend | 7.8k | yes | yes | Per series (3) plus geometry: 4 steps, about 4 x `o_eff` per frame; geometry alone may need a second split |
| output apply (refresh 5.7k) | 5.7k | yes | yes | Per row, 2 to 3 rows per piece: about 4 pieces |
| header finalize | 5.1k | yes | yes | Per field |
| theme read | 10.0k | yes | yes | Chunk the parse like `tokenizeChunk`: about 3 pieces |
| panel builds: state 11.5k, chart 11.4k, navigation 9.3k, rx-battery 7.7k, link-status 7.5k, metric 7.0k, flight-timer 6.5k, trim 6.3k, flight-counter 5.9k, flight-mode 5.7k, tx-battery 5.6k | 5.6k to 11.5k | 11 types | 11 types | Skeleton, then children from `refresh`; each extra piece adds one load callback (about 50 ms); state and chart need 3 |
| metric relayout | 4.1k | no | yes | By region: 2 pieces |
| model-identity build 4.7k, output build 4.5k | 4.5k to 4.7k | no | yes | 2 pieces each, one extra load callback |

Under 4k and not split: navigation refresh and reflow 3.7k, panel item parse,
header and navigation 3.6k, flight first tick 3.1k, Smart 2.6k; chart project
(1030 per knot, scaled by room). So 5k needs 4 splits plus the 11 builds, and 4k
adds only three (metric relayout and two builds). The extra cost of 4k is small
and it fits D, so **4000** is the recommendation; revisit 5000 only if hardware
shows zero near-misses and the heaviest real mix leaves 5000 of room.

**Required in migration.** Each task's contract records the **measured per-task
overhead `o` and its share of the piece**, and the **chosen split size** (pieces
and unit). CI checks `piece <= M` and the share at most 10%; section 7 makes it a
checklist step.

## 5. Flight tick, Smart and telemetry changes

Section 5.1 is part of the flight tick and Smart migration (R4). Section 5.2 is a
separate telemetry-service change, made and reviewed on its own before the
telemetry migration.

### 5.1 Flight tick and Smart (migration R4)

The flight tick (arm switch, counting, output) and Smart detection become two
`normal` tasks with **no deadline**: a late run only means a flight start or end
is detected later. They fit the R4 room (tick about 1000, Smart 2600, against
7460) and oldest-first bounds how long they wait. The tick keeps its current
cadence. There is no separate rewrite first: the Smart change is part of
this migration, with the usual strip-to-minimal-work and measurement steps.

**Smart task contract (behaviour changes on purpose).**

- Runs at most once per second (`delay >= 100`), atom 2600, split per sensor read
  if needed (discovery scans 8 sensors, then 4 reads). Its cost at this cadence
  is the 2.6k in the tables.
- Tolerant to delay. Today `flight_service.lua` (655-667) discards detection
  progress when `now - lastTick > 100` ticks (`groundAt`, `altitudeSince`,
  `speedSince`, `wasArmed` and `altitudeReference` cleared; `starting` returns to
  `ground`, `ending` to `active`), and lines 655-657 skip a tick closer than 20
  ticks. The task must not reset on a late run: continuity is judged from reading
  timestamps, not tick spacing. Arm-switch handling, counting and output stay at
  the tick's cadence and are not changed.
- Risk: a gap is no longer evidence that conditions held continuously, so the
  debounce windows must be evaluated from reading timestamps, and a stale or
  missing reading must break a window.

**Parity for this task is expected-behaviour tests, written first**, not an
old-versus-new comparison, because behaviour changes for delayed runs. Golden
cases: start and end detection at the normal cadence (unchanged result), delayed
runs of different lengths, a gap over 100 ticks, a gap spanning a start, an end
and a threshold crossing, and no false start or end after a gap (including a gap
with stale readings). The rest of the parity method applies to the tick.

**Precondition: loader callbacks.** At the head it runs in every callback,
including loader and reflow callbacks, so a long load never lets it wait. As a
task it would stop during exclusive callbacks. So the loader family must first
call `s:run("steady", now, used)` with `used` = that step's declared bound
before the tick can move. The tick's declaration is its **measured total**
(including the nested `services.update` of its private
runtime, all co-due), not a sum of parts; the 1000 above is an estimate (E), so
the tick cannot be registered until it is measured. Smart is measured the same
way as its own task.

### 5.2 Telemetry update intervals

A telemetry-service change, made and reviewed on its own **before R1** (the legacy
service needs it for its bound, section 4). It changes sample rates, which the
parity method cannot separate from a scheduling change. Today `INTERVAL = 10`
ticks and `POLL_CAP = 8` apply to everything.

**API.** `subscribe(name, linkEvidence, interval)`: `interval` is the wanted period
in ticks, 10 to 50; omitted means 10 (today), so a subscriber that says nothing
pins the source at 10 Hz and opts in later. The request travels through
`history:subscribe` as well (`chart.lua` 1877, `history_service.lua` 547). A chart
asks, per recorded source, for the per-pixel part of `chart.intervalFor`
(`window / pixels`, not its division by the series count, which is the redraw
rate): 60 s over 240 px is 25 ticks (4 Hz). A metric panel asks for its refresh
interval (20). A source's effective interval is the **minimum over its
subscribers**, **never above 50**: `flight_service` and `armed_service` treat a
reading older than 100 ticks as unreliable (`flight_service.lua` 19-21 and 155,
`armed_service.lua` 97-100), so a source polled every 100 would flap under any
jitter.

**Per-source release.** Each source is its own task (4.1), and its `entry.due` is
the one source of truth, shared with the legacy service object. A poll sets
`due = now + interval` (no catch-up); first releases follow the stagger rule
(section 3). Subscribing can only lower an interval (there is no unsubscribe; a
layout reload rebuilds the registry), by `due = min(due, lastPoll + interval)`;
the task notices at its next release, late by at most the old interval once, and
layouts subscribe before steady callbacks. While telemetry is legacy it updates
every 10 ticks and polls the due entries up to `n_L` (section 4). If a layout's
sustained load is too high, layout admission (section 3) lengthens intervals up
to the 50-tick cap.

**Preserved:** the sample time travels with the reading into history (a poll
records into all of the source's recordings in the same call); history's
recording rules (knot spacing, slope-corridor compression, gap marking on stale or
unavailable) apply unchanged to the samples it receives; link inference and the
precision scan are unchanged; minimum and maximum read from EdgeTX's own `<name>-`
and `<name>+` sensors stay exact at any poll rate.
**Changes:** chart traces hold fewer samples (about one per pixel); the chart
legend's minimum and maximum come from the sampled history state
(`history_service.lua` 670-672, `chart.lua` 1359), so a peak shorter than the
effective interval can be missed there; a reading can be up to one interval older
than today; a dropout is seen at the next poll, up to 50 ticks late.

**Link order.** `poll` judges a zero with `linkLive`, which `update` sets at its
top. Each source piece therefore calls `ensureLink(now)` first (cached per
callback, declared as the `shared` link cost), so a zero at link loss is never
stored as a genuine 0.

**Not in version 1: a source update-rate hint** (a model-level setting so that a
source is polled no faster than its sensor updates, for example from the ELRS
packet rate). It is in none of the mixes and needs a settings schema; it is
deferred with open decision 1. Its rules when it comes: it only lowers a rate, is
never applied to a source pinned by a subscriber that stated nothing, and never
exceeds the 50-tick cap. Estimating the rate from observed values is unsafe
(`getValue` cannot tell an unchanged value from no new packet, and `fresh` and
`updatedAt` record the last poll, not the last packet).

**Tests (own change).** A fixed-10 Hz golden against per-subscription intervals
on recorded traces: samples per source match the interval, timestamps are poll
times, a dropout is marked within one interval, minimum and maximum sensors are
exact, a zero at link loss is not recorded, mixes A to D of section 4 pass the
sustained and peak tests, a lowered interval takes effect within one old
interval, and no interval is above 50 or below the request.

## 6. Simulator, measurement and dev tooling

A task is defined once (`declare` plus `step`) and consumed by three paths that
never duplicate a number.

**Offline simulator** (lupa, deterministic). Runs the real planner with a
virtual clock and a scripted callback sequence. Tasks are stubs built from the
real `declare`: a stub `step` charges a virtual cost, may set `want` and
`stage`, and returns a scripted `delay`. Per callback it reports `U`, spent
cost, the plan and per-task wait. It checks ordering, admission, overload,
ownership, determinism, critical wait under callback jitter (3 to 15 ticks), and fault injection (cost steps, spikes and
bursts up to `ceiling + (20000 - ceiling)`, which must stay under 20000). The
recorded native traces replay through it: every traced `(task, units, cost)`
must satisfy `cost <= fixed + units * perUnit`.

**Native per-task measurement** (macOS Companion, the existing every-instruction
counter). Each task id has a case file that supplies only stimulus:

```lua
cases = { { grant = 1, setup = <build the instance in the worst legal state> },
          { grant = N, setup = ... } }          -- plus the contracts' fault set
```

The harness calls the real `step(instance, grant, stage, now)` inside one
counter window and records the count (audit probe cost subtracted), over at
least 5 clock phases or seeds, for every stage and every grant measured.

- **Fit.** `perUnit = max over g >= 2 of (worst(g) - worst(1)) / (g - 1)` and
  `fixed = max(0, max over g of (worst(g) - g * perUnit))`. This holds at every
  measured point by construction (a two-point slope can under-bound). The
  contracts' margin factors then give the declared numbers.
- Warn above 90% of a declared bound (re-declare) or below 60% (loose).
- A declaration made from an estimate (E) or unmeasured (U) row cannot be
  registered in `mixed` or `new`. This blocks critical tasks: telemetry at
  its cap `n` and navigation at 2 are estimates until measured at their declared
  `maxUnits`, which in turn needs the entries-per-source decision (open decision
  3).
- The framework's own `run` is measured at 8, 32 and 128 tasks and the largest
  ready count; its worst case must fit inside `overhead[kind]`.
- Case files are test files and cost no radio memory.

**Dev tooling** (`lib/scheduler_probe.lua`, loaded only by a probe flag; not in
version 1's runtime library). The library exposes only `lastPlan = {kind, U}`.

- *Tripwire.* The probe records, per callback, `U` or "no plan" for callbacks
  that skipped the scheduler (those still produce a `getUsage` reading). When it
  reads `usage` it compares with the previous callback's record and flags
  `usage > floor(U / 200)`. It cannot false-alarm unless the record is missing,
  and it is a **gross-error tripwire** only: `U` is a sum of padded bounds, so it
  is blind to a bound that is wrong by less than its padding. Per-task
  correctness comes from native measurement. It is armed only after the native
  simulator confirms which callback `getUsage` reports when `refresh` and
  `background` interleave (an open item in the plan). It changes no behavior.
- *Shadow mode.* Legacy keeps full control. The legacy sites report each task
  they ran; the probe sums their declared costs plus `overhead` and compares
  with `getUsage` (the declared table must not be below hardware) and logs where
  the planner would have chosen differently.

## 7. Coexistence, parity and invariants

**Host mode**, a constant in `main.lua` (overridable by tests), default
`legacy`: `legacy` (library not loaded), `mixed` (development and test only, never
shipped in a release until the critical and chart tasks have migrated), `new`
(allowed only when every steady-state task has a declaration).

**One owner per task.** One table maps each task id to `legacy` or `new`; it is
checked at load (a missing id fails the load). Every legacy site skips tasks
the table gives to `new`, and the framework registers only its own. Modal kinds stay
`legacy` until R5 (section 1), so ownership is per callback kind. Flipping a task is a
one-line change; rollback is its revert.

**Capped legacy share.** In `mixed` the legacy loop runs first and gets `L`
instructions for `updateServices` and `dispatchDue` together (services first, then
panels), the framework gets the rest through `used`. What changes in the
legacy loop, and nothing else:

- `dispatchDue` charges each panel its **declared refresh bound** (the
  contracts' declared values, which include the margin, not observed maxima)
  instead of `refreshCost`, against `L` instead of `REFRESH_CAP`. It keeps its
  `break` when an item does not fit, and its cursor, so it stays the old
  scheduler rather than becoming a third one. A panel with `refreshCost = 6`
  (the chart) is charged all of `L`: one per callback and nothing else from
  legacy, as today.
- `updateServices` still serves one due legacy-owned service per callback and
  skips `new`-owned ones; it serves it only if its declared bound fits `L`.
- Because `L` is at least the largest legacy bound (admission test D), the item at the
  cursor always eventually fits, so nothing is starved.
- A legacy item above `L`, or without a declared bound, is a **load error**: the
  host logs `scheduler: <id> exceeds the legacy share` once, falls back to
  `legacy` mode, and CI fails on the same condition.
- Unconditional head costs and the consumed-callback paths are not part of `L`;
  they reach the scheduler as `used` (section 1). One-time paths (metric
  relayout, reload) run in `update`, reload or loader callbacks, not in
  `refresh`.

**Parity test for migrating one task**, in this order:

1. **Golden.** Record the task's outputs and state from the pre-migration code
   on the recorded input trace (a checked-in fixture).
2. **Extraction.** In `legacy` mode the legacy loop calls the **same extracted
   `step`** the new scheduler will call (the stripped or split version), so the
   `legacy` run executes new code under the old loop. It must match the golden
   run exactly. This is what proves that stripping or splitting kept behavior.
3. **Ownership flip by replay.** The legacy run's schedule (which task ran in
   which callback, with what grant) is recorded and replayed into the new `step`
   entry points at the same callbacks. Outputs and state must match. This isolates
   the task from the planner; the two schedulers differ (the legacy loop runs at
   most one service per callback and serializes charts across callbacks), so a
   call-by-call comparison of the planners is not meaningful. The planner is
   tested by the simulator and by step 4.
4. **Budgeted.** The same trace under the real budget. Timing may differ but
   not unboundedly: no check is allowed to wait for "drain until idle" alone.
   Assert throughout the run: lateness of every task against the legacy run's
   lateness, time to first complete paint, recorded samples per
   source at least the legacy count with a gap no longer than legacy's worst,
   history exact where no sample was late.
5. **Native gate.** Pixel mismatch zero and worst callback at or below 15000
   on the matched native harness. This needs macOS and Companion, so it is a
   release gate run by hand, **not** a CI gate. Steps 1 to 4 run in CI.
6. **Review checklist** (not a test): the task does only the minimal work it
   needs, its bound is measured, **its per-task overhead is measured and its split
   size chosen under the rules of 4.2**, and its one-line contract (class, unit,
   stages, bound, exclusive flag, why this tier, measured overhead, split size) is written.

**Modal screens (end state, R5).** Each modal screen (settings UI, log viewer,
editor, menu, fullscreen input, app rebuild, theme showcase) becomes a callback
**kind** with its own `overhead` (the screen's fixed work) and its own tasks.
Services are eligible in every modal kind, so recording continues exactly as in
`steady`; panels are eligible only where the screen shows them (the editor
preview). The admission test runs per kind: the sustained and
peak critical tests run per kind, so a modal kind carries the services' pieces
and the `input` task. Cost depends on the
user, so it is bounded structurally:

- **One input event per callback, with reserved room.** EdgeTX hands `refresh` a
  single event and touch state and never redelivers it, so a task queue is the
  wrong place for it: the handler's declared worst case per event is part of the
  kind's `overhead`, run before the planner. A handler that cannot meet its bound
  is cut: it changes state cheaply and queues redraw work as tasks.
- **Redraw is staged.** Anything a screen paints, rebuilds or parses (a settings
  page, a log index, an editor preview, a menu grid) is a `normal` task with
  stages and unit grants (rows, lines, panels), as the audit already does for
  `output` rows and `prepareIndex`. A screen must be safe to draw half finished.
- **Worst cases are measured with scripted input**: each screen's case file
  drives the counter harness with recorded touch and key sequences at the largest
  legal content (longest list, full log, largest layout) and records the worst
  step per stage. These are the audit's unmeasured rows, so no modal task is
  registered, and no modal kind enabled, before its numbers exist. Needs
  fullscreen and touch in the native harness.
- A step above its kind's room is split before migration (the contracts' Flag
  rule), the same precondition as for panels.

**Retiring the old scheduler** (Phase 5) requires: every task has an owner `new`
and a declaration; no call to `dispatchDue`, `updateServices`, `pumpFlight` or
`pumpSessionReset` remains outside the framework (their work is tasks, `used`
head costs or kinds, and the file-level call sites in section 1 are gone);
`mixed`, the owner table and the legacy share `L` are deleted; and
the matched native harness passes in `new` with zero near-misses recorded by the
dev tripwire.

**Invariants and tests.**

| # | Invariant | Test |
|---|---|---|
| 1 | `U <= ceiling - margin` for every plan, always: a plan is built only by admission. | Simulator, random task sets and callback jitter over many seeds. |
| 2 | A ready critical task is never dropped: it is ordered before normal work and waits only behind older critical work. When the admission test (B, C) passes, its wait is bounded. | Simulator overload, burst and jitter; wait asserted. Negative cases must fail the admission test. |
| 3 | The first ready task in plan order whose smallest step fits `R` runs in that callback; with admission (A) the first ready task always runs. | Simulator under constant overload. |
| 4 | One owner per callback kind: every task runs only under its kind's owner, exactly once per release, and is not skipped by both; a source is never polled twice (`entry.due`). | Per-callback trace over a `mixed` mock run, plus a liveness count. The owner table is checked at load. |
| 5 | One pending release per task; no stacking. | Simulator with long skips. |
| 6 | At most one `exclusive` task per callback (charts); kind eligibility holds. | Simulator with several charts and a `background` kind. |
| 7 | Deterministic: the same inputs give the same plan log. | Run each scenario and replayed trace twice and compare. No clock or randomness in the library. |
| 8 | A step costs at most its declared bound; the units consumed are at most the grant. | Native measurement, trace replay, and `instance.used <= grant` in mock tests. |
| 9 | A step runs exactly its planned stage or does no work. | Mock test: change state (reset, model, geometry) between plan and run. |
| 10 | A failing or malformed task retires alone. | Simulator: raise, bad `delay`, bad stage. |
| 11 | Under injected cost spikes the total stays under 20000. | Simulator fault injection. |
| 12 | The framework's cost is within the 500 term of `overhead` and `o` is measured. | Native measurement at the extremes (4.2). |
| 13 | `legacy` mode is unchanged and the legacy loop never exceeds `L` in `mixed`. | Existing suites in `legacy`; mixed mock runs sum declared bounds per callback. |
| 14 | Every declared piece and smallest step is at most `M` = 4000, and per-task overhead is at most 10% of a piece. | CI check of the bounds table and the measured `o`. |

## 8. Deliberately left out of version 1

- Classes `HIGH` and `BACKGROUND`, declared tolerances and deadlines. Replaced by
  two tiers and oldest-first (the flight tick and session reset are `normal`; the extrema service is being removed separately
  and is not covered).
- Aging, a minimum budget share, guarded due-first, earliest-deadline-first and
  strict priority; margin growth, decay and adaptation.
- Isolation probes, learned bounds, `getUsage`-driven grants; a runtime guard
  (the tripwire and shadow mode are dev tooling).
- A separate filler; a source update-rate hint; a runtime stagger allocator;
  `s:wake` and `s:defer`; groups as a general feature (only `exclusive`).
- Cross-callback group ownership. Callback kinds beyond `steady` and
  `background` are added with their phases (R5, R6), not in Phase 1.
- Building the loader, reflow and modal kinds (R5, R6) in Phase 1: the library
  supports them, but they are migrated after the critical, chart and panel
  tasks, each only once measured.
- Retiring the legacy scheduler (Phase 5).
- Estimating a sensor's update rate from observed values; version 1 uses a hint.

### Untested risks

Background callback rate (only `refresh` is documented as 50 ms); the real
per-task overhead `o`; `getUsage` attribution when `refresh` and `background`
interleave; behavior with several widget contexts and the shared flight broker;
the native cost of 8 recorded sources and of `k` > 1 recordings per source in one
call; control's output read; the error and retire path.

## 9. Decisions needed

Decided by the user:

- The settings UI, log viewer, editor, menu, fullscreen input, app rebuild and
  theme showcase move to the new scheduler as modal kinds (R5); the legacy loop
  keeps them only temporarily, during migration.
- The flight tick, Smart and session reset are `normal`, with no deadline. The
  Smart rewrite (1 Hz, delay tolerant) is part of their migration, not a prior
  change (section 5.1). The extrema service is being removed in a separate change
  and is not in the task list, migration order or admission arithmetic.
- `mixed` is **not shipped in releases**: development and test only until the
  critical and chart tasks have migrated.
- The legacy share `L` varies per migration phase and is derived from the
  feasibility table in section 4 (the smallest value admission test D allows: 6650,
  6650, then 0), not a fixed ratio. Half of capacity is not feasible.
- The 15000 ceiling, the contracts' margin factors and `margin = 400` stay until
  hardware shows zero near-misses.

Also decided by the user: every service is split into independent tasks, and all
due tasks run together whenever they fit, oldest first with skip and continue (no
service group, no one-per-callback rule); telemetry polls each source at the
fastest rate any subscriber needs (section 5.2; the no-faster-than-the-sensor hint
is deferred). The spec puts that change **before R1**, as its own reviewed change.

No decision is open now except those deferred to the telemetry service migration
(the user will answer then; section 5.2 stands as the proposal):

1. **Telemetry defaults and recordings.** Whether subscribers that state no
   interval keep 10 ticks and opt in later (recommended), the scope of the
   source update-rate hint (one model-level value, or also per source), and the
   maximum number of history recordings per source, since a poll must record into
   all of them in one call (a deferred recording would be marked a gap).

## 10. Implementation notes (Phase 2)

Built as specified: `lib/scheduler.lua` (not called by the widget), with its
offline simulator, admission test, trace replay and measurement path in
`tests/support/scheduler_*.lua` and `tests/unit/lib/test_scheduler*.lua`. The
native measurement is `python3 tools/audit-scheduler.py --framework` (macOS,
Companion 2.12 x86_64); case files live in `tests/fixtures/scheduler-cases/`.
Choices where the specification was silent or inconsistent:

- **API.** `scheduler.new(overhead)`, `s:add{ id, decl, instance, due }` (returns
  `true` or `false, reason`; `due` is an absolute tick), `s:remove(id)`,
  `s:run(kind, now, used)`, `s:takeErrors()` and `s.lastPlan = { kind, U }` with
  `U = overhead + used + planned`. `scheduler.stagger(index, interval)` takes the
  registration index from 0. Declarations hold integer costs.
- **Remove during a plan.** A task removed before its step runs is skipped, not
  run once more; an add takes effect at the next plan, as specified.
- **Examination limits.** Every ready task looked at counts toward `K_c` and
  `K_n`, including ones refused by kind or `exclusive`, so the planner's cost
  stays bounded. Consequence for Phase 3: six ready steady-only normal tasks at
  the front of the list hide the normal tasks behind them from a `background`
  callback.
- **Reserve.** The normal reserve is applied literally: when `R` is below it,
  critical work waits and normal work uses `R`. Admission test A keeps `R` far
  above it.
- **Malformed input.** A `want` that is not a number plans the stage's
  `maxUnits`; below 1 it plans 1; a fraction is rounded down. A step that returns
  anything but a whole number of ticks >= 1, raises, or names an unknown stage
  retires that task (reported once through `takeErrors`). `instance.used` is
  asserted by tests only, not at runtime, to keep `o` small.
- **Measurement.** The `k` of 4.2 stops at 12, the `maxRun` cap (16 cannot run).
  The go/no-go figure is the specification's `F0 + 16 c1 + 12 o`, which counts
  the examination of the twelve tasks that run twice; the harness also measures
  the worst real callback directly (ten critical tasks run, four normal tasks
  examined and refused, two normal tasks run). The margin rule applies the
  per-call constant `A` to an indivisible stage and to `fixed` only of a
  divisible one; a hand declaration (for example telemetry per source) may
  differ.
- **Fault injection.** An injected excess of at most `20000 - ceiling` per
  callback (cost steps, spikes, bursts) is added on top of the plan; since a plan
  is at most `ceiling - margin`, the total must stay under 20000, and the
  simulator counts an overrun otherwise.
- **Left for later phases.** The near-miss tripwire and shadow mode
  (`lib/scheduler_probe.lua`, section 6), layout admission and the host mode.
  Admission tests A to E are test support, not radio code.
- **Bounds table.** `tests/fixtures/scheduler-bounds.lua` holds the contracts'
  declared bounds at the audit's labels (legacy granularity) for the trace
  replay and the `M` check; labels without a contract bound are listed there.

### Measured framework cost (native, 32 tasks, instructions)

| Callback | Cost |
|---|---|
| nothing ready (`F0`) | 75 |
| 1, 4, 8, 12 tasks run | 241, 671, 1239, 1816 |
| 16 ready tasks examined, none fits | 597 (`c1` 33) |
| worst real callback (12 run, 4 refused) | 1936 |
| per task run `o` | 166 at one task, 145 at twelve |

The specification's figure is 2589 against 500: **no-go**. The targets of 4.2
(`F0` 40, `c1` 6, `o` 30) are below the cost of a `pcall`, the result checks and
the list reinsertion in Lua (about 58 instructions to plan and 47 to run and put
back one task). Heap: about 32 KiB for 128 registered tasks on the native
simulator (43 KiB in the desktop Lua used by the tests); the library itself is
about 12 KiB on the SD card. The 12 cap is the lever: with `K_c`/`K_n`/`maxRun`
of 6/4/8, 4/3/6, 3/2/4 and 2/2/3 the worst real callback is about 1060, 750, 580
and 440. The decision (keep 12 and raise the term to about 2000, which the
margin rule makes 2520, lowering the room `C` of section 4 by about 2000; or
lower the caps; or merge tasks) is the user's.

