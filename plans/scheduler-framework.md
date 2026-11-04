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

Today's scheduling is spread over eight call sites in `main.lua`. The framework
is called only where a callback has budget left, and every other path keeps
its existing behavior.

| Site | Today | Version 1 |
|---|---|---|
| `refresh` tail (1614-1615) | `updateServices`, `dispatchDue` | `steady` kind |
| `background` tail (1653-1654) | `updateServices`, `dispatchAll("background")` | `background` kind: services only. Panel `background` hooks are not tasks; they stay in `overhead` (26 each) |
| `pumpFlight`, head of `refresh` and `background` (1388, 1623) | every callback, before all early returns: identity check, reset poll, tick; it consumes the callback on a first document load and when Smart is running during a modal or loading callback | Stays at the head. Its costs are passed to the scheduler as `used` (below). The tick moves into the framework only under the preconditions in section 5 |
| `pumpSessionReset` (1394, 1629) | consumes the callback; runs every service's and panel's `resetSession` | Unchanged. A consumed callback runs no scheduler |
| loader, reflow, app rebuild, page retire and rebuild, menu, editor save, settings UI advance | consume the callback, each bounded by the audit | Unchanged; not framework tasks in version 1 |
| settings UI with no pending work (1403), log viewer (1552, 1559), editor with panels (1567-1568) | `updateServices` (and `dispatchDue` for the editor) next to handler work that is unmeasured | **Modal sites.** See open decision 4. Until it is decided, the legacy loop keeps running these sites for every task whatever its owner (same step code, default grant, then `s:defer(id, due)` so the framework does not re-run it at once). They stay unbudgeted, as today |

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
  tasks. `due` carries the phase offset.
- `pcall` guards every step. An error or a rule violation retires that task and
  reports it once, as `panelHost.dispatch` and `services.update` do today.
- A migrated task never ends the callback itself.

### Example: a service (telemetry, critical, group `service`)

```lua
telemetry.declare = {
    class = "critical", group = "service",
    stages = { poll = { fixed = 750, perUnit = 1180, maxUnits = 8 } },   -- contracts
}
function telemetry.step(self, grant, stage, now)    -- grant = sources to poll
    self.cursor = self.roundRobin(self.entries, self.cursor, grant, self.poll, self, now)
    return self.interval                            -- 10 ticks
end
```

The instance sets `want` to the number of subscribed sources.

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

### Worked feasibility (Smart on, 16 panels)

`C = 15000 - 400 - (1250 overhead + 400 framework) = 12950`. Head `used`: reset
poll 620, plus the legacy flight tick 3600 in the callbacks where it runs
(**T**; otherwise **N**). Room = `C - used - L - S`. Declared values from the
contracts. `L` is the largest legacy item and `S` the telemetry step (Smart on:
750 + 4 x 1180 = 5470).

| Phase | New-owned | `L` | `S` | Room N | Room T | Preconditions |
|---|---|---|---|---|---|---|
| R1 | chart stages | 5700 (output refresh) | 0 | 6630 | 3030 | Split chart text (7800) below 3030. Other chart stages fit (900 to 1300; project grant 1 knot = 1030). |
| R2 | + panel refreshes | 5470 (telemetry) | 0 | 6860 | 3260 | Split metric (4800), output (5700) and navigation (3700) below 3260. |
| R3 | + services (group `service`) | 0 | 5470 | 6860 | 3260 | Telemetry measured at its cap and entries per source (open decisions 2, 3). |
| R4 | + flight tick | 0 | 5470 | 6860 | none | Section 5 preconditions; tick atom 3600 fits. |

Consequences: with all ready critical services allowed together (`S` = 5470 +
650 + 2600 = 8720) room is 3610 (N) and 10 (T): nothing else runs in a callback
with a tick, so services stay in one group (open decision 1). With Smart off and
telemetry at 8 recorded sources (10.0k, estimated), R1 is the best case (room
2330 N, 1330 T), and R2 and later cannot hold a 1.3k to 3k atom: **telemetry's
per-update bound must be capped (about 5.5k or below) before any phase past R1.**
Panel builds (3.5k to 11.5k) are not tasks: they run in their own loader
callbacks and do not use this room.

## 5. Flight tick

The flight tick is `normal` and has **no deadline**: a late tick only means a
flight start or end is detected later. It fits the R4 room (3600 declared, Smart
on, against 6860) and oldest-first bounds how long it waits. Smart off needs
the telemetry cap of section 4.

**Precondition 1: delay-tolerant detection, as its own change.** Today
`flight_service.lua` (655-667) discards detection progress when
`now - lastTick > 100` ticks (`groundAt`, `altitudeSince`, `speedSince`,
`wasArmed` and `altitudeReference` cleared; `starting` returns to `ground`,
`ending` to `active`), and lines 655-657 skip a tick closer than 20 ticks.
Before the tick moves, detection must be made tolerant to delay: a gap must not
discard progress, and continuity is judged from reading freshness and
timestamps, not tick spacing. This is a small behavior change with its own
tests, done and reviewed separately, not as part of the scheduler framework.
Risk: a gap is no longer evidence that conditions held continuously, so the
debounce windows must be evaluated from reading timestamps. The parity tests for
this task must cover delayed ticks (gaps of different lengths, a gap spanning a
start, an end and a threshold crossing).

**Precondition 2: loader callbacks.** At the head it runs in every callback,
including loader and reflow callbacks, so a long load never lets it wait. As a
task it would stop during exclusive callbacks. So the loader family must first
call `s:run("steady", now, used)` with `used` = that step's declared bound
before the tick can move. The tick's declaration is its **measured total**
(including the nested `services.update` of its private and Smart runtimes, all
co-due), for Smart on and off, not a sum of parts.

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
  registered in `mixed` or `new`. This blocks critical tasks: telemetry at 8
  recorded sources and navigation at 2 are estimates, so they wait until measured at their declared `maxUnits`, which in turn needs the
  entries-per-source decision (open decision 3).
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
are the one documented exception (section 1, open decision 4). Flipping a task is a
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
- Cross-callback group ownership, a wake-up API, and callback kinds other than
  `steady` and `background`.
- Loader, reflow, editor, menus, log viewer and other modal paths as tasks; and
  the unmeasured UI tasks.
- Retiring the legacy scheduler (Phase 5).

## 9. Decisions needed

Decided by the user:

- The flight tick and session reset are `normal`; the tick has no deadline and
  its migration needs delay-tolerant detection first (section 5). The extrema
  service is being removed in a separate change and is not in the task list,
  migration order or admission arithmetic.
- `mixed` is **not shipped in releases**: development and test only until the
  critical and chart tasks have migrated.
- The legacy share `L` varies per migration phase and is derived from the
  feasibility table in section 4 (the smallest value test C allows: 5700, then
  5470, then 0), not a fixed ratio. Half of capacity is not feasible.
- The 15000 ceiling, the contracts' margin factors and `margin = 400` stay until
  hardware shows zero near-misses.

Open:

1. **Services per callback.** Keep today's one per callback through group
   `service` (recommended: room 6860 N, 3260 T), or run all ready critical
   services together (room 3610 N, 10 T).
2. **Telemetry per-update bound.** Cap sources per update (about 4) and tie it
   to Smart: today's cap of 4 applies only in callbacks where the tick ran. A
   static cap changes the sample rate, so the telemetry contract must keep
   recorded samples per source at least today's. Needed before any phase past
   R1 (contracts decision 1).
3. **Entries per source per call.** Cap telemetry recording at one history entry
   per source per call, or measure and declare a higher cap (contracts decision
   6); needed to declare telemetry's bound.
4. **Unmeasured modal paths** (contracts decision 5). Keep the legacy loop
   running them for every task, unbudgeted as today (the exception in section
   1), or measure the handlers and budget them as kinds (`service`, `editor`),
   which needs fullscreen and touch in the native harness.
