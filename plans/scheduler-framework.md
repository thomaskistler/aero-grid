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
| `pumpSessionReset` (1394, 1629) | consumes the callback; runs every service's and panel's `resetSession` | Unchanged. A consumed callback runs no scheduler |
| loader, reflow, app rebuild, page retire and rebuild, menu, editor save, settings UI advance | consume the callback, each bounded by the audit (loader family) or unmeasured (UI) | Unchanged in Phase 1; become kinds in R5 and R6 (section 4) |
| settings UI with no pending work (1403), log viewer (1552, 1559), editor with panels (1567-1568) | `updateServices` (and `dispatchDue` for the editor) next to handler work that is unmeasured | **Modal sites.** Temporarily, while unmeasured, the legacy loop keeps running them for every task whatever its owner (same step code, default grant, then `s:defer(id, due)` so the framework does not re-run it at once), unbudgeted as today. This is a migration state, not the end state: they become modal kinds in R5 (section 7) |

**Consumed callbacks and `used`.** When a head step returns "callback
consumed", the scheduler is not run, exactly as `updateServices` is not today.
When the head work ran and the callback continues, the host calls
`s:run(kind, now, used)` where `used` is the declared cost of what already ran:
the reset poll (when a reset is configured), and the flight tick when it is
still legacy-owned and ran. Recording continues in consumed callbacks no
better or worse than today.

## 2. Tasks

A task is declared once as data and instantiated as a plain table with a
`step` function. The declaration is loadable without the radio API, so the
simulator and CI read the same bounds the widget uses. One declaration table is
shared by all tasks of a type.

```lua
declare = {
    class   = "critical" | "normal",
    group   = nil,           -- at most one task of the group per callback
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
- Registration: `s:add{ id, decl, instance, due }`, `s:remove(id)`, at most 64
  tasks. `due` carries the phase offset. `s:wake(id)` re-releases a task now; it
  is used only when a subscription lowers a source's interval (section 5).
- `pcall` guards every step. An error or a rule violation retires that task and
  reports it once, as `panelHost.dispatch` and `services.update` do today.
- A migrated task never ends the callback itself.

### Example: a service (telemetry, critical, group `service`)

Each subscription is a unit with its own release time (`entry.due`), and the
task's release is the soonest of them (section 5).

```lua
telemetry.declare = {
    class = "critical", group = "service",
    stages = { poll = { fixed = 750, perUnit = 1180, maxUnits = 3 } },   -- n, section 4
}
function telemetry.step(self, grant, stage, now)    -- grant = sources, oldest due first
    self:pollDue(grant, now)                        -- at most `grant` entries with due <= now
    local soonest = self:soonestDue()
    self.want = self:countDueBy(soonest + 5)        -- upper bound; may over-estimate
    return math.max(1, soonest - now)
end
```

### Example: a staged chart (normal, group `chart`)

```lua
chart.declare = {
    class = "normal", group = "chart", first = "begin",
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

State: one array of task records sorted by `(due, seq)`, `seq` being the
registration order. Insertion is a binary search; only tasks that ran are
re-inserted and the shifting is done by `table.insert` and `table.remove`. Only
the due prefix is read each callback.

`R = ceiling - margin - overhead[kind] - used`. Plan in this order:

1. **Critical.** Ready (`due <= now`) critical tasks eligible for the kind, in
   `(due, seq)` order, skipping a task whose group is already planned. Each is
   planned at `min(want, maxUnits)`. **Subtract its cost from `R`** before
   going on. A critical task is never skipped for budget. If `R` goes negative
   the plan still holds it and counts `overCapacity`; the design-time test
   makes this impossible for a valid configuration.
2. **Normal.** Ready normal tasks in `(due, seq)` order (oldest release first).
   Skip a task whose group is planned. Otherwise grant
   `g = min(want, maxUnits, floor((R - fixed) / perUnit))`; if `g >= 1` plan it
   and subtract `fixed + g * perUnit`, else skip it and try the next
   (work-conserving).
3. **Stop** after `K = 12` normal tasks are examined or when `R` is below the
   smallest `fixed + perUnit` of any registered stage.
4. **Run:** critical tasks first, then normal in plan order. After each step set
   `due = now + delay`.

| Rule | Why it is needed |
|---|---|
| Two tiers, critical first | Telemetry, history and control are recording; a budget skip would lose samples. |
| Group exclusivity | One chart per callback, as today (a legacy chart has `refreshCost = 6`, the whole cap). Services use group `service`, which keeps today's one service per callback (`updateServices` serves one) and its rotation: a critical service waits behind an older critical service of its group, at most group size minus 1 callbacks. Lifting it is a data change, see open decision 1. |
| Oldest release first | One rule gives fairness and bounded waiting. It replaces aging, deadlines and tolerances. |
| Skip and continue | Uses the leftover budget. |
| Grants in units | A divisible task fills what is left instead of reserving its worst case. This is also the "filler". |
| `K = 12` | Bounds the planner's own cost. The oldest ready task is examined first, so the cap cannot starve it. |

**Stagger.** The services' intervals are 5 (history), 10 (telemetry, control
output), and 20 ticks (control, armed, flight); today's registration
adds a tick-sized offset that a 50 ms callback cannot see, so the real stagger
is the one-per-callback rotation. The framework keeps that rotation through the
`service` group. `due` offsets only spread initial releases.

**Design-time admission test** (CI, per ownership configuration and kind). Let
`S` be the sum, over groups, of the largest critical step in the group (maximum
over stages, at `maxUnits`), `H` the largest `used` the host can pass, and `L`
the legacy cap (section 6):

- (A) `overhead + margin + H + L + S <= ceiling`, so guaranteed work always fits;
- (B) every normal stage's smallest step `fixed + perUnit` is at most
  `ceiling - margin - overhead - H - L - S`, so the oldest ready task can always
  run (this replaces the contracts' fixed 4000 lump limit);
- (C) every legacy item's declared bound is at most `L`.

## 4. Budget and feasibility

Facts used, all from the plan: EdgeTX kills a callback past 20000 instructions
and the widget stays dead until reloaded, so safety is planned. `getUsage`
reports only the previous complete callback, in 200-instruction quanta, and
cannot attribute cost between tasks.

- `ceiling = 15000`, `margin = 400` (two quanta, fixed).
- `overhead[kind]` is declared by the host as `base + slope * panels` and
  includes the framework's cost bound. Callbacks have kinds `steady` and
  `background` only.
- **Planning never reads `getUsage`.**
- **Framework cost.** `run` costs `base + examined * c1 + ran * c2`, with
  `examined <= 12 + critical count` and at most 64 tasks. Go/no-go for Phase 1:
  the measured worst case at 32 tasks must be at most **400** (the margin; more
  than that spends the headroom the framework exists to recover). Above it, fix
  the design (lower `K`, one dispatcher task for panels) before Phase 2.
  Heap: one shared declaration per type and one small record per task, reported
  from `collectgarbage("count")` at 64 tasks; the threshold is set from that
  measurement because the radio's Lua heap limit is not in the plan.

### Worked feasibility (16 panels)

`C = 15000 - 400 - (1250 overhead + 400 framework) = 12950`. The Smart detection
rewrite (section 5) splits today's 3600 flight tick into the tick proper (arm
switch, counting, output; about 1000, estimated) at the current cadence and
Smart (2600) at most once per second. Head `used` while both are legacy: reset
poll 620 plus the tick, so **T** = a callback with the tick (room base 11330)
and **TS** = the callback each second that also runs Smart (room base 8730).
Room = base `- L - S`. `L` is the largest legacy item. `S` is the largest
critical step of the group: telemetry at its per-update cap `n`
(`750 + n x 1180`, worst case all recorded) or control (2600). Declared values
from the contracts. `n` follows from the telemetry mix below; the table uses
mix A (`n = 3`, 4290) and assumes the telemetry change of section 5 is in first.

| Phase | New-owned | `L` | `S` | Room T | Room TS | Preconditions |
|---|---|---|---|---|---|---|
| R1 | chart stages | 5700 (output refresh) | 0 | 5630 | 3030 | Split chart text (7800) below 3030. Other chart stages fit (900 to 1300; project grant 1 knot = 1030). |
| R2 | + panel refreshes | 4290 (telemetry) | 0 | 7040 | 4440 | Split metric (4800) and output (5700) below 4440; navigation (3700) fits. |
| R3 | + services (group `service`) | 0 | 4290 | 7040 | 4440 | Telemetry measured at `n` and entries per source (open decision 3). |
| R4 | + tick and Smart as tasks | 0 | 4290 | 8040 | | Section 5 preconditions; no head cost remains, only the reset poll. Atoms: tick 1000, Smart 2600. |
| R5 | modal screens: settings UI, log viewer, editor, menu, fullscreen input, app rebuild, theme showcase | 0 | per kind | per kind | | Each measured natively first and split to fit its kind's room (section 7). Order: smallest handler first. |
| R6 | loader, reflow, page retire and rebuild, session-reset pump, the head work | 0 | per kind | per kind | | Already measured in the audit; split where it exceeds the room (panel builds 3.5k to 11.5k, theme read 10.0k). |

**Telemetry mixes.** Each source is due every `interval` ticks; with a callback
about every 5 ticks (the 50 ms menu period) the sustained demand is
`D = sum(5 / interval)` sources per callback, and `n = ceil(D) + 1` leaves one
unit of slack to drain a late source. Sources are staggered, so a step polls
about `D` of them, not all eight at once.

| Mix (8 sources) | `D` | `n` | `S` | Average per callback | Room T / TS / R4 | `S` all together | Room T / TS / R4 |
|---|---|---|---|---|---|---|---|
| A: recorded, 4 Hz (25 ticks) | 1.6 | 3 | 4290 | 2640 | 7040 / 4440 / 8040 | 7540 | 3790 / 1190 / 4790 |
| B: recorded, 1 Hz (100 ticks) | 0.4 | 2 | 3110 | 770 | 8220 / 5620 / 9220 | 6360 | 4970 / 2370 / 5970 |
| C: metric panels, 5 Hz (20 ticks), 4 recorded | 2.0 | 3 | 4290 | 2350 | 7040 / 4440 / 8040 | 7540 | 3790 / 1190 / 4790 |
| D: recorded, 10 Hz (today) | 4.0 | 5 | 6650 | 5470 | 4680 / 2080 / 5680 | 9900 | 1430 / breach / 2430 |

("All together" adds history 650 and control 2600; "breach" = guaranteed work no
longer fits the ceiling. Today's single step of 8 sources costs 10.0k, estimated;
spreading the same 10 Hz over the callbacks already lowers the peak to 6.65k.)
The always-run critical sum is the telemetry step plus, if services run
together, history and control. With per-source intervals it falls from 8.7k to
3.1k to 4.3k (one service per callback), but only because a source is no longer
polled faster than something can show it. While Smart is still legacy, a
telemetry step in the TS callback must fit beside it.
Panel builds (3.5k to 11.5k) are not tasks: they run in their own loader
callbacks and do not use this room.

## 5. Prerequisite changes (separate, reviewed first)

Two service changes are made and reviewed on their own, not inside the
framework.

### 5.1 Flight tick and Smart

The flight tick (arm switch, counting, output) and Smart detection are two
`normal` tasks with **no deadline**: a late run only means a flight start or end
is detected later. They fit the R4 room (tick about 1000, Smart 2600, against
6860) and oldest-first bounds how long they wait.

**Precondition 1: Smart detection rewrite merged first.** Today
`flight_service.lua` (655-667) discards detection progress when
`now - lastTick > 100` ticks (`groundAt`, `altitudeSince`, `speedSince`,
`wasArmed` and `altitudeReference` cleared; `starting` returns to `ground`,
`ending` to `active`), and lines 655-657 skip a tick closer than 20 ticks.
The rewrite, a separate change off `main` and not part of this framework, makes
Smart detection run at most once per second and tolerant to delay: no reset on a
late run, with continuity judged from reading timestamps. Its scope is Smart
only; arm-switch handling, counting and output stay at the current tick cadence.
Risk: a gap is no longer evidence that conditions held continuously, so the
debounce windows must be evaluated from reading timestamps. Parity tests for
these tasks must cover delayed runs (gaps of different lengths, a gap spanning a
start, an end and a threshold crossing). Smart then becomes its own task
(delay of at least 100 ticks, atom 2600, splittable per sensor read) instead of
part of the tick.

**Precondition 2: loader callbacks.** At the head it runs in every callback,
including loader and reflow callbacks, so a long load never lets it wait. As a
task it would stop during exclusive callbacks. So the loader family must first
call `s:run("steady", now, used)` with `used` = that step's declared bound
before the tick can move. The tick's declaration is its **measured total**
after the rewrite (including the nested `services.update` of its private
runtime, all co-due), not a sum of parts; the 1000 above is an estimate (E), so
the tick cannot be registered until it is measured. Smart is measured the same
way as its own task.

### 5.2 Telemetry update intervals

A telemetry-service change, done and reviewed **before** the telemetry
migration (and before R2), in the legacy service. It is safer first because it
changes sample rates, which the parity method (section 7) cannot separate from a
scheduling change; it works under the legacy loop; and it lowers the legacy
telemetry bound `L`. Today `INTERVAL = 10` ticks and `POLL_CAP = 8` apply to
everything.

**API.** `subscribe(name, linkEvidence, interval)`: `interval` is the slowest
acceptable poll period in ticks (10 to 100); omitted means 10, today's rate, so
a subscriber that says nothing pins the source at 10 Hz and migrates later.
Requests: a chart asks per recorded source for the per-pixel part of
`chart.intervalFor` (`window / pixels` clamped to 20..100; not its division by
the series count, which is the redraw rate): 60 s over 240 px is 25 ticks (4 Hz),
4 minutes or more reaches 100 (1 Hz). A metric panel asks for its refresh
interval (20). The requested interval of a source is the **minimum over its
subscribers**.

**Per-source release.** Each entry has its own `due`; a poll sets
`due = now + interval` (no catch-up). First releases are staggered by ordinal so
sources spread over callbacks. The service computes its own next release (the
soonest `due`), and the same semantics serve the legacy loop and the framework.
Subscribing can only lower a source's interval (there is no unsubscribe; a layout
reload rebuilds the registry); when it does, the entry's `due` moves earlier and
the service is woken (`s:wake`, or its own `due` in the legacy loop).

**Cap.** At most `n` sources are polled per update (the grant). At load the
service checks the sustained demand `D = sum(5 / interval)` against `n - 1`; if
it is exceeded it scales all effective intervals up by `D / (n - 1)` and logs
once, so a crowded layout loses rate gracefully instead of building unbounded
lateness.

**Source update rate (never poll faster than a sensor updates).** The effective
interval is `min(100, max(requested, sourceInterval))`. It only lowers the
polling rate: it is never below the subscribers' request, so it can never raise a
rate, and it is never above 100 ticks, so a real update is never read later than
the freshness window, however slow the sensor.

- *Where `sourceInterval` comes from:* a **hint**, not an estimate. A model-level
  setting (one value for the telemetry sources of the model, from its ELRS packet
  rate and telemetry ratio) with an optional per-source override. It applies only
  to sources the service already marks `state.telemetry`; timers, trims,
  transmitter voltage and globals are not packet-limited and keep the request.
  Absent a hint, nothing is lowered. Nothing in the service reads the packet rate
  or telemetry ratio today.
- *Why not estimate it:* `getValue` cannot tell an unchanged value from no new
  packet, so a steady sensor (a voltage at rest) would look slow and be polled
  slowly, then show its next real change up to 100 ticks late. What exists today
  does not help: `fresh` and `updatedAt` record the last **poll** that returned a
  live value, not the last packet, and `revision` counts changes only, so it is a
  lower bound on the rate for sensors that are moving. Only the optional
  `getSourceValue` API (per-sensor receipt and freshness flags, already required
  by Smart) can see a packet; an estimator built on it may be added later, only
  where that API exists, only lowering the rate and never past the cap above.
  A dev log of observed change intervals can help choose the hint.
- *Hint direction.* A hint at or below a sensor's true period costs only extra
  polls; a hint above it delays real updates. Choose the fastest rate the link
  can reach, since the ELRS packet rate can change in flight; the 100-tick cap
  bounds the damage either way.
- *Gaps.* Staleness and gap marking are decided at a poll (a nil or ambiguous
  zero), and the sample time is the poll time. With a longer interval a dropout is
  seen at the next poll, up to one effective interval late, and a dropout shorter
  than that can be missed, which is no worse than the sensor itself reporting at
  that rate. The 100-tick cap bounds it at 1 s.

**Preserved:** sample time travels with the reading into history; history's
recording rules (knot spacing, slope-corridor compression, gap marking on stale
or unavailable) apply unchanged to the samples it receives; link inference and
the precision scan are unchanged; minimum and maximum values read from EdgeTX's
own `<name>-` and `<name>+` sensors stay exact at any poll rate.
**Changes:** chart traces hold fewer samples (about one per pixel, by
construction), so a peak shorter than the effective interval can be missed by a
trace; a reading can be up to one interval older than today.

**Tests (own change).** A fixed-10 Hz golden against per-subscription intervals
on recorded traces: samples per source match the interval, timestamps are poll
times, a dropout is marked within one interval, minimum and maximum sensors are
exact, mixes A to D of section 4 stay within `n` per update, a lowered interval
takes effect within 10 ticks, and the hint never produces an interval above 100
or below the request.

## 6. Simulator, measurement and dev tooling

A task is defined once (`declare` plus `step`) and consumed by three paths that
never duplicate a number.

**Offline simulator** (lupa, deterministic). Runs the real planner with a
virtual clock and a scripted callback sequence. Tasks are stubs built from the
real `declare`: a stub `step` charges a virtual cost, may set `want` and
`stage`, and returns a scripted `delay`. Per callback it reports `U`, spent
cost, the plan and per-task wait. It checks ordering, admission, overload,
ownership, determinism, and fault injection (cost steps, spikes and
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
- The framework's own `run` is measured at 8, 32 and 64 tasks and the largest
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
the table gives to `new`, and the framework registers only its own. Modal sites
are the one documented exception (section 1, a temporary migration state). Flipping a task is a
one-line change; rollback is its revert.

**Capped legacy share.** In `mixed` the legacy loop runs first and gets `L`
instructions, the framework gets the rest through `used`. What changes in the
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
- Because `L` is at least the largest legacy bound (test C), the item at the
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
3. **Ownership flip, unlimited budget.** `mixed`, owner `legacy` against owner
   `new` with no cap and the same virtual clock and grants. Outputs and state
   must match call by call, which isolates the planner from the task.
4. **Budgeted.** The same trace under the real budget. Timing may differ but
   not unboundedly: no check is allowed to wait for "drain until idle" alone.
   Assert throughout the run: lateness of every task against the legacy run's
   lateness, time to first complete paint, recorded samples per
   source at least the legacy count with a gap no longer than legacy's worst,
   history exact where no sample was late, and zero `overCapacity`.
5. **Native gate.** Pixel mismatch zero and worst callback at or below 15000
   on the matched native harness. This needs macOS and Companion, so it is a
   release gate run by hand, **not** a CI gate. Steps 1 to 4 run in CI.
6. **Review checklist** (not a test): the task does only the minimal work it
   needs, its bound is measured, and its one-line contract (class, unit, stages,
   bound, group, why this tier) is written.

**Modal screens (end state, R5).** Each modal screen (settings UI, log viewer,
editor, menu, fullscreen input, app rebuild, theme showcase) becomes a callback
**kind** with its own `overhead` (the screen's fixed work) and its own tasks.
Services are eligible in every modal kind, so recording continues exactly as in
`steady`; panels are eligible only where the screen shows them (the editor
preview). The admission test runs per kind: `S` is the sum over groups, so a
modal kind with `service` and `input` groups carries both. Cost depends on the
user, so it is bounded structurally:

- **One input event per callback.** EdgeTX hands `refresh` a single event and
  touch state, so input handling is a critical task (group `input`) that handles
  one event with a declared worst case, `maxUnits = 1`. A handler that cannot
  meet its bound is cut: it changes state cheaply and queues redraw work.
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
`mixed`, `s:defer`, the owner table and the legacy share `L` are deleted; and
the matched native harness passes in `new` with zero near-misses recorded by the
dev tripwire.

**Invariants and tests.**

| # | Invariant | Test |
|---|---|---|
| 1 | `U <= ceiling - margin` for every plan when the admission test passes. | Simulator, random task sets over many seeds. Negative cases must fail the admission test. |
| 2 | A ready critical task is never skipped for budget; it waits only for an older critical task of its group. | Simulator overload and burst; wait bounded by group size. |
| 3 | The oldest ready normal task whose smallest step fits the room after critical work runs in that callback. | Simulator under constant overload. |
| 4 | One owner: every task runs only under its owner, exactly once per release, and is not skipped by both. | Per-callback trace over a `mixed` mock run, plus a liveness count. The owner table is checked at load. |
| 5 | One pending release per task; no stacking. | Simulator with long skips. |
| 6 | At most one task per group per callback; kind eligibility holds. | Simulator with several charts and a `background` kind. |
| 7 | Deterministic: the same inputs give the same plan log. | Run each scenario and replayed trace twice and compare. No clock or randomness in the library. |
| 8 | A step costs at most its declared bound; the units consumed are at most the grant. | Native measurement, trace replay, and `instance.used <= grant` in mock tests. |
| 9 | A step runs exactly its planned stage or does no work. | Mock test: change state (reset, model, geometry) between plan and run. |
| 10 | A failing or malformed task retires alone. | Simulator: raise, bad `delay`, bad stage. |
| 11 | Under injected cost spikes the total stays under 20000. | Simulator fault injection. |
| 12 | The framework's cost is within `overhead` and the go/no-go threshold. | Native measurement at the extremes. |
| 13 | `legacy` mode is unchanged and the legacy loop never exceeds `L` in `mixed`. | Existing suites in `legacy`; mixed mock runs sum declared bounds per callback. |

## 8. Deliberately left out of version 1

- Classes `HIGH` and `BACKGROUND`, declared tolerances and deadlines. Replaced by
  two tiers and oldest-first (the flight tick and session reset are `normal`; the extrema service is being removed separately
  and is not covered).
- Aging, a minimum budget share, guarded due-first, earliest-deadline-first and
  strict priority; margin growth, decay and adaptation.
- Isolation probes, learned bounds, `getUsage`-driven grants; a runtime guard
  (the tripwire and shadow mode are dev tooling).
- A separate filler. More than one service per callback.
- Cross-callback group ownership. Callback kinds beyond `steady` and
  `background` are added with their phases (R5, R6), not in Phase 1.
- Building the loader, reflow and modal kinds (R5, R6) in Phase 1: the library
  supports them, but they are migrated after the critical, chart and panel
  tasks, each only once measured.
- Retiring the legacy scheduler (Phase 5).
- Estimating a sensor's update rate from observed values; version 1 uses a hint.

## 9. Decisions needed

Decided by the user:

- The settings UI, log viewer, editor, menu, fullscreen input, app rebuild and
  theme showcase move to the new scheduler as modal kinds (R5); the legacy loop
  keeps them only temporarily, during migration.
- The flight tick, Smart and session reset are `normal`, with no deadline. Their
  migration needs the Smart detection rewrite (1 Hz, delay tolerant) merged
  first (section 5). The extrema service is being removed in a separate change
  and is not in the task list, migration order or admission arithmetic.
- `mixed` is **not shipped in releases**: development and test only until the
  critical and chart tasks have migrated.
- The legacy share `L` varies per migration phase and is derived from the
  feasibility table in section 4 (the smallest value test C allows: 5700, then
  5470, then 0), not a fixed ratio. Half of capacity is not feasible.
- The 15000 ceiling, the contracts' margin factors and `margin = 400` stay until
  hardware shows zero near-misses.

Also decided by the user: telemetry polls each source at the fastest rate any
subscriber needs, and no faster than the sensor updates (section 5.2). The spec
puts that change **before** the telemetry migration, as its own reviewed change.

Open:

1. **Services per callback.** Keep today's one per callback through group
   `service` (recommended), or run all ready critical services together. The
   latter fits only a slow telemetry mix (B: room 2370 in a Smart callback); at
   4 Hz recorded (A) it leaves 1190, too little for any panel or chart step.
2. **Telemetry intervals (section 5.2).** *Deferred to the telemetry service
   migration; the user will answer then. Section 5.2 stands as the proposal.*
   Subscribers that state no interval (flight motor source, link status,
   navigation, service probe) keep 10 ticks and opt in later (recommended), or
   default to a slower rate. And the source update rate: one model-level hint
   (recommended; applied only to telemetry sources), or also a per-source
   override.
3. **Entries per source per call.** Cap telemetry recording at one history entry
   per source per call, or measure and declare a higher cap (contracts decision
   6); needed to declare telemetry's bound.
