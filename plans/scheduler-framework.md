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
| settings UI with no pending work (1403), log viewer (1552, 1559), editor with panels (1567-1568) | `updateServices` (and `dispatchDue` for the editor) next to handler work that is unmeasured | **Modal sites.** Scheduler-owned services run through the scheduler on these callbacks; remaining services use the legacy loop. Panels stay legacy until R5. The migrated model task uses the `steady` kind here, so no task-specific legacy update method or second source of truth is needed. Modal panel tasks become explicit kinds at R5 (section 7). |

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
    shared  = nil,           -- { name = cost }, at most two names: charged once per plan to the
                             -- first task planned, paid by the first that does the work
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
- `delay` is a whole number of ticks (10 ms) from 1 to 2^30 (a float with a whole
  value is accepted and stored as an integer; anything else retires the task).
  Due time is `now + delay` from the callback in which the task actually ran, so
  one release is pending per task, there are no catch-up bursts, and 1 means
  "ready at the first callback at least one tick later", not "next callback".
- **Shared costs.** A name has one cost (a second declaration with a different
  cost is refused). The plan charges it once, to the first task it plans; when that
  task is removed by an earlier step, raises or does no work, the next task that
  does the work pays it. The plan total is the same either way, so the plan can
  only over-charge. A task that does no work must not call `ensureLink`.
- `kinds`: a task is planned only in callbacks of those kinds. Services accept
  `steady` and `background`; panel refresh and chart stages accept `steady`
  only. A task with nothing to do is not registered.
- Registration: `s:add{ id, decl, instance, due }` and `s:remove(id)`, at most 128
  tasks. `due` carries the phase offset (section 3). `add` returns `false` and a
  reason, and the host must check it, for: a missing or repeated id, a full list,
  a missing `due` or one that is not a whole number of ticks, a malformed
  declaration (costs above the ceiling included), `kinds`
  naming a kind the host does not have, empty or non-boolean, a shared name with
  two costs, and a stage that could never fit the room of any of its kinds (it
  would be charged every callback and never run). A declaration is read and
  copied at its first add; changing it afterwards has no effect. An add or remove
  during a plan takes effect at the next plan.
- **Time.** `now` is the host's tick counter and wraps like EdgeTX's int32
  `getTime()` (the EdgeTX Lua is built with 32-bit integers and floats, so the
  tests also run on such a Lua). Due times are stored as given and compared only
  by the wrap-safe difference `scheduler.elapsed(a, b)` (`a - b` as a signed
  32-bit number, the identity on 32-bit Lua), which is exact while two ticks are
  less than 2^31 apart: a due is at most 2^30 ahead of the clock, and a task
  starved for more than 2^31 ticks (248 days) would look as if it were in the
  future. `step` receives the host's `now`, not a stored value, and must compare
  ticks with `elapsed` (never `<=` or subtraction of raw ticks across the wrap).
  `due` is required: `now` plus a stagger offset.
- **Not charged.** `add` and `remove` cost instructions the planner does not
  charge (measured on 32-bit Lua with 127 tasks: `add` of a new declaration about
  700, of a known one 180 to 400, `remove` 40 to 400). A step that registers or
  retires tasks declares that margin in its bound.
- `pcall` guards every step. An error or a rule violation retires that task and
  reports it once, as `panelHost.dispatch` and `services.update` do today. The
  report (`addError`, `showErrors`, label creation) is a one-off path outside the
  budget: the framework queues it and the host reports it at the head of the next
  callback, which it treats as consumed (R6 measures it).
- A migrated task never ends the callback itself.

### Service task construction

Migrated services expose named task objects in `service.tasks` and one ordered
`service.schedulerTasks` registration list. Use `services.task(service, name,
{ id, decl, run, want, interval, critical })` to construct both together. A single
task is named `run`; independent work keeps separate names (Control's `critical`,
`normal`, `outputs`; Telemetry's `maintenance` and `source:<index>`).

`run(service, grant, stage, now, task)` does bounded work and returns its next
delay. The shared adapter propagates the scheduler's wrap-safe clock helper,
marks the service failed on an exception, and rethrows for the scheduler's normal
error report. An optional `service:taskFailed()` invalidates domain state; sibling
tasks cannot do work after failure. Services do not recalculate scheduler grants.
`want` belongs to the task. An omitted task interval follows the service interval;
explicit task intervals remain independent. Telemetry and History poll at 10 ticks.
The service API refactor intentionally corrects History's previous 5-tick period
to the requested 10 ticks; partial-release retries still use 1 tick.

### Example: a Telemetry source task (critical)

Telemetry uses one task per source plus a separate maintenance task. A source
poll reads once and synchronously invokes all History observers before returning.
The declaration reflects the number of recordings attached to that source.

```lua
declare = {
   class = "critical",
   stages = { run = { fixed = 480, perUnit = 320, maxUnits = 24 } },
}
```

Unrecorded sources use `0 + 320 x 1`; a single recorder uses `0 + 740 x 1`.
Native measurements and the supported-recorder cap are in section 5.2.

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

`R = ceiling - margin - overhead[kind] - used - F`, `F` the planner's fixed charge.
The planner charges its own cost to the same budget as it plans (section 4): `E`
for every task it examines and `W` for every task it plans or retires, both
subtracted from the room as they are incurred. One pass:

1. **Critical.** Ready (`due <= now`) critical tasks, oldest first, planned while
   the plan stays within `R - normalReserve` (`normalReserve = 2000`, about the
   tick plus one small chart stage). A critical task that does not fit waits and
   is first next callback; it is never dropped.
2. **Normal.** Ready normal tasks, oldest first, against what remains of `R`.
3. Each task examined costs `E`. It is skipped if it is `exclusive` and one is
   already planned, or if its kind is not eligible. Otherwise grant
   `g = min(want, maxUnits, floor((room - W - fixed) / perUnit))`; if `g >= 1`
   plan it and subtract `W + fixed + g * perUnit`, else skip it and try the next
   (work-conserving). A `shared` cost is subtracted the first time a task naming
   it is planned.
4. **Stop** when the room cannot admit another task (below the smallest
   `fixed + perUnit` of any registered stage plus `E + W`) or at the first task
   not yet due. **Run** the plan in order; after each step set `due = now + delay`.

There is no cap on examined or planned tasks. The scan cannot run away because
every step of it is charged: the work it does is at most the amount it charged
provided `F`, `E` and `W` are upper bounds of the measured cost, and a charge that
exhausts the room ends the scan. The list holds at most 128 tasks, which is the
only hard bound (128 refused tasks cost `128 E`, charged). The two lists remain, so
a backlog of normal work is never scanned before critical work and cannot hide it.

| Rule | Why it is needed |
|---|---|
| Critical before normal, with a normal reserve | Telemetry, recording writes and Armed's conditions needed for recording boundaries are never dropped when admitted. History session and expiration maintenance is normal because telemetry records at sample time and the observer path drains flight boundaries while maintenance is deferred. Trims, outputs and global variables are normal display work. The reserve stops critical work from starving the tick, Smart, session reset and every chart and panel. Safety never depends on either (`R` bounds every plan); only latency does. |
| `exclusive` | One chart per callback, as today (a legacy chart has `refreshCost = 6`, the whole cap). Used by chart stages only. |
| Oldest release first | One rule gives fairness and bounded waiting. It replaces aging, deadlines and tolerances. |
| Skip and continue | Uses the leftover budget. Everything due runs together whenever it fits. |
| Grants in units | A divisible task fills what is left instead of reserving its worst case. This is also the "filler". |
| Charging `F`, `E`, `W` | Replaces fixed caps on examined and planned tasks. The planner's own cost is paid from the budget it plans, so it needs no separate reserve and cannot push a plan over the ceiling. |

**Stagger.** Periodic tasks (services, sensors) get an initial `due` offset of
`5 x (index mod ceil(interval / 5))` ticks, `index` being the registration order.
It is a fixed rule, not an allocator, so it costs nothing on the radio and is
reproducible; the peak `P` it gives is reported by the simulator for the mixes in
section 4. Phases drift when callbacks are irregular and do not re-heal after a
late run; safety never depends on them, only the tests (C) and wait do.

**Design-time admission test** (CI, per ownership configuration and kind). Let
`base = ceiling - margin - F - overhead - H - L`, `H` the largest `used` the host
can pass and `L` the legacy cap (section 7). Every release of a task costs its
bound plus the charge `G = E + W`:

- (A) every stage's smallest step `fixed + perUnit + G` is at most `base - P`, so
  the first ready task always runs. Checked on the regular callback; while the
  tick and Smart are legacy, the callback that also runs Smart may delay a larger
  piece by one callback;
- (B) sustained critical load `sum((cost + G) x 5 / interval)` is at most
  `base - normalReserve`; otherwise a backlog grows or normal work stalls;
- (C) the peak `P` of critical load (with `G` per release) due in one callback,
  from the simulator with the stagger rule, is at most `base - normalReserve`;
- (D) every legacy item's declared bound is at most `L`;
- (E) every indivisible piece and every smallest step is at most the maximum task
  size (section 4).

**Layout admission (at load, on the radio).** The tests above use fixed mixes, but
layouts vary. The host sums the declared sustained load of the registered critical
tasks, with `G` per release; if it exceeds `base - normalReserve`, the telemetry
service lengthens every source interval by the same factor (rounded up, never
above 50 ticks, section 5.2) and logs a notice once. Critical work is never shed
and normal work does not stall: rates degrade. For example 16 recorded sources at
10 Hz, two per task, is about 12.8k sustained against 9.6k, a factor of about 1.3
(1.5 with one source per task).

## 4. Budget and feasibility

Facts used, all from the plan: EdgeTX kills a callback past 20000 instructions
and the widget stays dead until reloaded, so safety is planned. `getUsage`
reports only the previous complete callback, in 200-instruction quanta, and
cannot attribute cost between tasks.

- `ceiling = 15000`, `margin = 400` (two quanta, fixed).
- `overhead[kind]` is declared by the host as the audited `base + slope * panels`
  only. The framework adds nothing to it: the planner charges itself. Callbacks
  have kinds `steady` and `background` until the modal kinds of R5.
- **Planning never reads `getUsage`.**
- **Framework cost** is charged, not reserved: `F = 132` per callback, `E = 64`
  per task examined and `W = 224` per task planned or retired (`G = E + W = 288`;
  the planner exposes them as `FIXED_COST`, `EXAMINE_COST` and `RUN_COST`). The
  measured worst cases are an idle callback 117, 52 per examined task and 247 per
  task run (examination included); the charges are above them by at least 5% in
  every one of 3089 measured callbacks (CI asserts 4% on 12 random seeds), so a
  different luac point release or an added instruction does not flip the
  invariant. **Check** (replaces the old fixed 500 term): in every scenario and mix
  measured natively, the measured framework cost of a callback is at most the
  amount it charged (`lastPlan.charged`), at 8, 32 and 128 tasks, including every
  due task refused (too large, shared cost too large, wrong kind, exclusive),
  skipped with one fit at the end, staged with shared costs and `want`, failing
  steps, unknown stages (some and all), and seeded random task sets with up to two
  shared names. The charge is therefore an upper bound and the unaccounted planner
  cost is zero. If a planner change breaks the check, raise the constants and
  recompute these tables. Heap: one declaration record per type and one small
  record per task (seven fields), about 33 KiB at 128 tasks on the native
  simulator (reported from `collectgarbage("count")`); the radio's Lua heap limit
  is not in the plan.

### Worked feasibility (16 panels)

`C = 15000 - 400 - 132 (fixed planner charge) - 1250 audited overhead = 13218`. The
planner's per-task charge `G` = 288 is inside `P` and each piece's room. The Smart change
in the flight migration (5.1) splits today's 3600 flight tick into the tick proper (arm
switch, counting, output; about 1000, estimated) at the current cadence and
Smart (2600) at most once per second. Head `used` while both are legacy: reset
poll 620 plus the tick, so **T** = a callback with the tick (room base 11598)
and **TS** = the callback each second that also runs Smart (room base 8998).
Until R4 legacy Smart keeps its current cadence (about every 10 ticks), so in
R1 to R3 a TS callback comes about every second callback rather than once per
second; the 1 Hz cadence and these figures hold from R4.
Room = base `- L - P`; a piece must also pay its own `G`, so the largest piece
that fits is room `- 288`. These are migration feasibility estimates from the
bounded-share design. The shipped `mixed` host no longer caps legacy work at
`L`: it charges actual declared legacy work as `used`, and defers scheduler
tasks when no room remains.
`P` is the **peak load of critical tasks that fall due in one callback** after
staggering, with `G` per release, not the sum of all of them (all due together
would be 15.3k) and not a group maximum. While telemetry is legacy it is the largest legacy item: the
legacy service runs every 10 ticks, so it must poll `2D` sources per update,
`n_L = ceil(2D) + 1` (mix A: 5, cost `750 + 5 x 1180 = 6650`; mix D: the cap of 8,
10190). That makes **5.2 a precondition of R1**, not R2, with the charts and
panels opted in; without it `L` is 10190 and nothing fits. Declared values from
the contracts; mix A below is the reference, with telemetry in tasks of two
sources (4.2).

| Phase | New-owned | `L` | `P` | Room T | Room TS | Preconditions |
|---|---|---|---|---|---|---|
| R1 | chart stages | 6650 (legacy telemetry, 5.2 in) | 0 | 4948 | 2348 | Section 5.2 merged. Split chart text (7800) under the cap (4.2). Other chart stages fit (900 to 1300; project grant 1 knot = 1030). |
| R2 | + panel refreshes | 6650 | 0 | 4948 | 2348 | Split metric relayout and output apply under the cap. Until R4, TS callbacks come about every second callback, so a piece above 2348 less 288 runs only in the others. |
| R3 | + services as tasks | 0 | 5754 | 5844 | 3244 | Services split as in 4.1; Telemetry and synchronous History observer work are measured and bounded in 5.2. |
| R4 | + tick and Smart as tasks | 0 | 5754 | 6844 | | Section 5.1 contract and loader-callback precondition. The 6844 is shared with the tick (1000) and Smart (2600, once per second), so net capacity equals R3. |
| R5 | modal screens: settings UI, log viewer, editor, menu, fullscreen input, location details, app rebuild, theme showcase | 0 | per kind | per kind | | Each measured natively first and split to fit its kind's room (section 7). Order: smallest handler first. |
| R6 | loader, reflow, page retire and rebuild, session-reset pump, the head work, `configureFlight` | 0 | per kind | per kind | | Already measured in the audit; split where it exceeds the cap (4.2). |

**Telemetry mixes** (historical admission calculation: 8 sources, per-source
intervals from section 5.2, a callback about every 5 ticks, history 650 every 5
rather than its current 10-tick period, critical arm conditions `200 + 100 n`
at most 6 every 20 ticks, link 560 once per callback that polls a source, and
`G` = 288 per release). The normal control entries and outputs are admitted after
critical work and are not included in the critical peak. Recorded sources are
polled two per task; one per task is in brackets. `P` is from the simulator with
the stagger rule; the sustained load is the mean. Both are computed by
`tests/support/scheduler_admission.lua` and asserted in the tests.

These are historical feasibility estimates for the earlier batched-source
proposal; the implemented per-source tasks, consumer intervals, and measured
bounds are in section 5.2.

| Mix | Sustained | Peak `P` | Room T / TS / R4 | Legacy `L` |
|---|---|---|---|---|
| A: 8 recorded, 4 Hz (25 ticks) | 4134 (3794) | 5522 (5234) | 6076 / 3476 / 7076 (6364 / 3764 / 7364) | 6650 |
| B: 8 recorded, 1 Hz (100 ticks, so 50 after the cap) | 2033 (1880) | 4054 (5234) | 7544 / 4944 / 8544 (6364 / 3764 / 7364) | 3110 |
| C: 4 recorded and 4 unrecorded as one batch, 5 Hz (20 ticks) | 3801 (3551) | 4934 (5234) | 6664 / 4064 / 7664 (6364 / 3764 / 7364) | 6650 |
| D: 8 recorded, 10 Hz (today) | 7626 (7050) | 8458 (7882) | 3140 / 540 / 4140 (3716 / 1116 / 4716) | 10190 |

Per-source intervals are what make the numbers work: today's 10 Hz mix D needs
`P` = 8.5k. Mix B is computed at 100 ticks; the 50-tick cap of 5.2 raises its
sustained load to about 3.0k. Two sources per task lower `P` for the busy mixes (A
and D: the charge is paid once per two sources) and raise it for the quiet ones (B
and C: one release is then twice as large beside history and arm conditions), so the
batch is about two, not fixed. Against the earlier table (500 reserved, nothing
charged per task) one source per task loses 496 to 1360 of room (A 784, B 496, C 496,
D 1360) and two per task loses 496 to 1676 (A 496, B 1676, C 1316, D 784); the
charge is now counted where it is spent. Panel builds (3.5k to 11.5k) are not tasks in R1
to R4: they run in their own loader callbacks. The `background` kind has the same
shape with overhead about 1130 (0.41k plus 26 per panel at 16 panels; the
contracts' 0.62k was too low), so about 13.3k before `P`, with only services
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
| telemetry | one task per source plus one maintenance task; each source poll synchronously invokes all History observers | 170 unrecorded; 511 with one recorder; 805-6393 with 2-24; maintenance 286-1175 at 1-128 sources | See the measured declarations in 5.2 | The 24-recorder cap is based on supported chart layouts and native measurements. A poll and all its observers remain atomic. |
| history | one task: advance and boundaries, one entry per update | 0.44k (0.38k advance and boundaries plus 17 per entry) | 0.65k | Recording itself lives in the telemetry poll (observer), not here. Below the minimum size (4.2): the run charge is about a third of it. Kept as one task every 10 ticks; revisit with the measured contract. |
| control | critical switch-condition task (6 entries); normal trim/global-variable/State-switch task (6 entries); normal output task (up to 32 channels, interval 10 when an output panel exists) | critical: 153-553 at grants 1-6; entries: 177-1121 at grants 1-6; outputs: 113-1694 at grants 1-32 (M) | `200 + 100 n` critical, `130 + 240 n` entries, `120 + 60 n` outputs | Native cases cover every grant and partial batches; each task's bounded natural unit is kept together despite being below the minimum useful piece (4.2). |
| model | one task, units = facets (4) | 0.03k fixed, 0.105k per facet (0.41k at 4) | 0.57k (90 + 120 per facet; migrated, section 12) | None. |
| navigation | one normal task, units = GPS subscriptions (cap 2) | 752 at grant 1, 1447 at grant 2 (M; includes first-arm capture diagnostics across 16 navigation panels) | `120 + 770 n` (1.66k at 2) | Measured at every cursor and grant; a partial batch continues after 1 tick, then the next batch is due after 20 ticks. |
| flight tick | tick, and Smart as its own task | tick about 1.0k (E); Smart 2.0k (discovery scans 8 sensors, then 4 reads) | Smart 2.6k | Smart splits per sensor read if needed; the tick's nested `services.update` makes its total measured, not summed. |
| session reset steps | one task, units = items (8) | history 0.07k, navigation 0.01k | 0.2k | None. |
| armed | none | no scheduled update | | None. |

### 4.2 Task size and per-task overhead

**Per-task overhead** is what the framework spends per task outside the task's own
bound, and it is charged (section 4): `E` = 64 to examine a ready task (the
wrapped `record.due` check, eligibility, grant arithmetic and, for a skipped task,
list compaction) and `W` = 224 to plan and run it (the `pcall` and step wrapper with
its result checks, and reinsertion by binary search). A task's own resume cost
stays in its stage's `fixed`. Measured natively (Companion 2.12, the same counts
as the offline counter, and the same on a Lua 5.3 built with 32-bit integers):
idle callback 117, 52 per task examined (with compaction of 127 skipped tasks, a
shared-cost lookup and two shared names included), 247 per task examined and run,
at 8, 32 and 128 tasks. `W` is 224, so the minimum useful size below is about
2.2k.

**Measurement (native).** `python3 tools/audit-scheduler.py --framework` runs
`scheduler:run` in scenarios of stub tasks whose `step` only returns a delay, at
`N` = 8, 32 and 128: idle; `k` = 1, 4, 16 and `N` tasks run, with reinsertion at
the end, the front and the middle of the list; every ready task refused (does
not fit, wrong kind, exclusive after the first); all skipped and the last one
fits (compaction); staged tasks with two shared costs and `want`; failing steps;
unknown stages; and mixes A to D at one and two sources per task over 400
irregular callbacks with a chart and four panels. Every row compares the measured
count with `lastPlan.charged`; the check is that none exceeds it
(`tests/unit/lib/test_scheduler_measure.lua` runs the same rows offline in CI).

**When to split.** Splitting a piece `P` into pieces of size `p` costs
`o_eff = G + resume` per piece and wastes about `p / 2` of room per callback on
packing (a piece of size `p` cannot use a smaller leftover), so total waste is
about `p / 2 + (P / p) * o_eff`, smallest near `p = sqrt(2 * P * o_eff)`. For the
chart text (`P` 7.8k, `o_eff` about 390) that is about 2.5k per piece and a
waste of about 2.5k per frame. Rules:

- Split when a piece exceeds the maximum size `M`. Otherwise split only at a
  natural boundary, and only if each piece stays at or above the minimum useful
  size `max(1000, 10 * W)` = 2240 (the run charge is at most a tenth of the
  piece).
- Never split below the minimum. Batch smaller items that share a release as
  units of one task: telemetry sources of one interval (about two per task, a
  single source at 1.18k is below the minimum, two at 2.36k are not), control entries, model facets.
- A divisible task is not limited by `M`: its grant fills the room. Its smallest
  step (`fixed + perUnit`) must be at most `M`, and a task whose smallest step is
  below the minimum should usually be released with more than one unit.

**Maximum task size `M = 4000` declared (decided)**, for every indivisible
piece and every smallest step. Against the room left after the peak critical load
in a regular callback (table above, less the charge `G` = 288 a piece pays), the
largest piece is 5268 to 6736 for mixes A to C in R3 (T) and 6268 to 7736 in R4 at
one source per task, 5556 and 6556 at two, so 4000 fits A to C 1.3 times. Mix D
(today's 10 Hz, the heaviest) leaves 2908 in R3 (T) and 3908 in R4 at two sources
per task (2332 and 3332 at one): **mix D is below 4000 in R3 and, by about 90,
in R4**. This is accepted: each task is reviewed, split and optimized in its own
migration, so D does not decide `M`. The callback that also runs Smart while it
is legacy has pieces of 2956 (A, two per task) and 308 (D): a piece above that
waits one callback, and only until R4. The combinations below 4000, listed and
asserted by `test_scheduler_simulation.lua` (pieces at one and two sources per
task): A/TS 2668 and 2956, B/TS 2956 (two), C/TS 3776 (one) and 2956 (two), D/T
2332 and 2908, D/TS -268 and 308, D/R4 3332 and 3908. The audited tasks above
the cap, with declared values:

| Task | Declared | Over 5k | Over 4k | Split and its cost |
|---|---|---|---|---|
| chart reading text and legend | 7.8k | yes | yes | Per series (3) plus geometry: 4 steps, about 4 x `o_eff` per frame; geometry alone may need a second split |
| output apply (refresh 5.7k) | 5.7k | yes | yes | Per row, 2 to 3 rows per piece: about 4 pieces |
| header finalize | 5.1k | yes | yes | Per field |
| theme read | 10.0k | yes | yes | Chunk the parse like `tokenizeChunk`: about 3 pieces |
| panel builds: state 11.5k, chart 11.4k, navigation 9.3k, rx-battery 7.7k, link-status 7.5k, metric 7.0k, flight-timer 6.5k, trim 6.3k, flight-counter 5.9k, flight-mode 5.7k, tx-battery 5.6k | 5.6k to 11.5k | 11 types | 11 types | Skeleton, then children from `refresh`; each extra piece adds one load callback (about 50 ms); state and chart need 3 |
| metric relayout | 4.1k | no | yes | By region: 2 pieces |
| model-identity build 4.7k, output build 4.5k | 4.5k to 4.7k | no | yes | 2 pieces each, one extra load callback |

Under 4k and not split: navigation refresh varies from 0.8k at minimum span to
3.35k at maximum span (3.7k declared), panel item parse, header and navigation
3.6k, flight first tick 3.1k, Smart 2.6k; chart project (1030 per knot, scaled
by room). Six navigation panels can defer the NORMAL navigation service when
there is no room. Its compass-tape refresh remains atomic; deterministic panel
slicing is a separate follow-up. So 5k needs 4 splits plus the 11 builds, and
4k adds only three (metric relayout and two builds). The extra cost of 4k is
small and it fits A to C, so **4000** is the recommendation; each migration
reviews its own task's size. Revisit 5000 only if hardware
shows zero near-misses and the heaviest real mix leaves 5000 of room.

**Required in migration.** Each task's contract records the **charge `G` and its
share of the piece**, and the **chosen split size** (pieces and unit). CI checks
`piece <= M` on the bounds table; the share (at most 10%, a piece of 2240 or more)
is reported by the admission test for every indivisible stage below it and is a
checklist step in section 7. Natural exceptions are listed with their share, for
example history (650, a third).

## 5. Flight tick, Smart and telemetry changes

Section 5.1 is part of the flight tick and Smart migration (R4). Section 5.2 is a
separate telemetry-service change, made and reviewed on its own before the
telemetry migration.

### 5.1 Flight tick and Smart (migration R4)

The flight tick (arm switch, counting, output) and Smart detection become two
`normal` tasks with **no deadline**: a late run only means a flight start or end
is detected later. They fit the R4 room (tick about 1000, Smart 2600, against
7036) and oldest-first bounds how long they wait. The tick keeps its current
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

Telemetry is scheduler-owned and is split into one task per source plus one
maintenance task. `subscribe(name, linkEvidence, interval)` accepts a positive
whole-number period in 10 ms ticks. An omitted interval remains 10 ticks for
compatibility. A shared source uses the fastest requested interval; subscribing
with a faster interval updates the source task, and a layout reload rebuilds all
subscriptions. There is no global 50-tick ceiling or model/source update-rate
hint.

**Consumer requests.** Metric, RX Battery, and Link Status request 20 ticks;
Navigation's satellite-count display requests 25. These rates are used only when
they are the fastest requests for a source. They can make a sole-consumer reading
up to 200 ms old (250 ms for satellite counts), compared with the 100 ms
default, and brief changes or dropouts can be observed later. Other consumers
keep the default: History/chart recordings, Navigation GPS, and Flight motor
inputs request 10 ticks; external callers that omit `interval` also retain 10.
Thus a chart/history reader sharing a source pins that source at 10 ticks even
when a panel requests 20 or 25. These panel rates avoid spending scheduler
capacity on polling faster than their displayed refresh cadence while preserving
the default for unspecified and recording callers.

**Per-source tasks and intervals.** A subscribed source has one scheduler task
and uses the minimum requested interval across all its consumers. The
maintenance task follows the fastest service interval. A layout reload rebuilds
the subscription registry; changing a source interval or its History observer
count updates its task declaration before the next release. Tasks can be deferred
when the scheduler has no room, but an incomplete release never partially polls
or records a source.

**Atomic recorded-source work.** A poll synchronously sends its reading to all
active History recordings for that source at the poll timestamp. It is not split
or queued across releases. Each source task requests one unit per History
recording, or one unit for an unrecorded source; an insufficient grant does no
polling and invokes no History observer, then retries on a later release. The
task declaration is selected by recorder multiplicity: unrecorded, one recorder,
or multiple recorders. The maximum is 24 distinct recordings per source, based
on eight minimum-width charts fitting a 4x4 layout with three series each.
Identical recording configurations share one History track. At the maximum
supported multiplicity, native measurement is 6,393 instructions against an
8,160-instruction declared bound (fixed 480 plus 320 per recorder); two to
24 observers measure 805 to 6,393. One observer measures 511 against 740;
unrecorded polling measures 170 against 320. A 25th distinct track for the same
source is rejected rather than creating work without a supported declaration.

The maintenance task publishes link state and advances at most one bounded
precision scan per release. It reserves one unit per subscribed source for its
rotation search and does no work if the grant cannot cover that search. Its
declaration is `450 + 10 n`, with up to 128 units matching the host's task limit;
measured costs range from 286 to 1,175 instructions for 1-128 sources, including
an eight-sensor scan after inspecting the preceding sources. A source poll checks link state before interpreting
zero, preserving the rule that a zero at link loss is stale/unavailable rather
than a genuine reading. History's existing knot spacing, compression, stale and
unavailable gap behavior, and synchronous observer timing remain unchanged.
Minimum and maximum values read from EdgeTX's own `<name>-` and `<name>+`
sensors remain independent source subscriptions.

**Native measurement and tests.** The checked-in task cases measure recorded
sources from 1 through 24 observers, plus one-observer, unrecorded, and
maintenance cases. Scheduler tests assert task declarations, source atomicity
under an insufficient grant, and legacy/task parity. Mixed and legacy audits
must still verify that unrelated legacy service and chart scheduling are
unchanged; no-room callbacks defer scheduled work without partially recording a
source.

Known limitation: both 8-chart/24-source stress variants fail to advance live
chart draw revisions under full layout load, while History plot revisions
advance. Polling remains at the agreed 10-tick rate; resolving this is deferred
with chart scheduling out of scope. The full sequential Lua run passes 100
suites and fails only `test_chart_recording.lua` and
`test_chart_independent_arming.lua`, both at the live-drawing assertion in
`test_chart_recording.lua:192`. These failures are deferred and unresolved;
publication of the Telemetry changes does not imply a passing full suite.

Native callback ceilings are not globally clean: the current mixed audit
measures 24,081 instructions for `metric-16` and 20,862 for `stress`, above
15,000. The legacy baseline also exceeds that ceiling (21,034 and 20,345,
respectively). Audit command success does not enforce the callback ceiling;
the hook counter agrees with firmware `getUsage`. These observations remain
open rather than being treated as passing callback-ceiling checks.

## 6. Simulator, measurement and dev tooling

A task is defined once (`declare` plus `step`) and consumed by three paths that
never duplicate a number.

**Offline simulator** (lupa, deterministic). Runs the real planner with a
virtual clock and a scripted callback sequence. Tasks are stubs built from the
real `declare`: a stub `step` charges a virtual cost, may set `want` and
`stage`, and returns a scripted `delay`. Per callback it reports `U`, spent
cost, the plan and per-task wait; the planner's own cost enters as its charge,
which the framework measurement below proves is an upper bound. It checks ordering, admission, overload,
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
  registered in `mixed` or `new`. Navigation is measured at its declared
  two-entry cap; telemetry at its cap `n` remains unmeasured until its
  entries-per-source decision is resolved.
- The framework's own `run` is measured at 8, 32 and 128 tasks in the scenarios
  and mixes of 4.2 (`audit-scheduler.py --framework`); every measured callback
  must cost at most what it charged (`lastPlan.charged`), and a failing row names
  the scenario.
- Case files are test files and cost no radio memory.

**Dev tooling** (`lib/scheduler_probe.lua`, loaded only by a probe flag; not in
version 1's runtime library). The library exposes only `lastPlan` (`kind`, `U`,
and for the framework check `charged`, `examined`, `ran`).

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
  they ran; the probe sums their declared costs plus `overhead` and the charge and compares
  with `getUsage` (the declared table must not be below hardware) and logs where
  the planner would have chosen differently.

## 7. Coexistence, parity and invariants

**Host mode**, a constant in `main.lua` (overridable by tests), default
`mixed`: migrated tasks run in the framework and remaining tasks keep their
existing legacy cadence and limits. `new` is allowed only when every
steady-state task has a declaration.

**One owner per task.** One table maps each task id to `legacy` or `new`; it is
checked at load (a missing id fails the load). Every legacy site skips tasks
the table gives to `new`, and the framework registers only its own. Scheduler-owned
services also run through the framework on modal callbacks; panel modal kinds are
added at R5 (section 1). Flipping a task is a one-line change; rollback is its revert.

**Mixed-mode accounting.** Legacy services and panels keep their existing
cadence and limits; they are not capped by a shared legacy share. Their declared
bounds, plus head work, are passed to the scheduler as `used`. If that leaves
negative room, the scheduler simply runs no tasks in that callback; this is not
a task error. Missing owners or bounds remain load errors, because the host
cannot account for that legacy work safely. `L` is retained only in the
feasibility tables as a planning estimate, not as a runtime admission limit.
Unconditional head work and consumed-callback paths are not part of `L`; they
reach the scheduler as `used` (section 1). One-time paths (metric relayout,
reload) run in `update`, reload or loader callbacks, not in `refresh`.

**Parity test for migrating one task**, in this order:

1. **Golden.** Record the task's outputs and state from the pre-migration code
   on the recorded input trace (a checked-in fixture).
2. **Extraction.** A test-only adapter runs the extracted work on the legacy
   schedule and must match the golden run exactly. When ownership flips, remove
   the migrated task's production legacy entry point; no parallel legacy work
   remains for that task.
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
| 1 | Scheduler-planned work never exceeds the remaining budget. If prior work leaves negative room, no task runs and no error is raised; `U` may exceed the ceiling because it includes that already-run work. | Simulator, random task sets and callback jitter over many seeds; negative-room unit test. |
| 2 | A ready critical task is never dropped: it is ordered before normal work and waits only behind older critical work. When the admission test (B, C) passes, its wait is bounded. | Simulator overload, burst and jitter; wait asserted. Negative cases must fail the admission test. |
| 3 | The first ready task in plan order whose smallest step plus `G` fits `R` runs in that callback; with admission (A) the first ready task always runs. | Simulator under constant overload. |
| 4 | One owner per callback kind: every task runs only under its kind's owner, exactly once per release, and is not skipped by both; a source is never polled twice (`entry.due`). | Per-callback trace over a `mixed` mock run, plus a liveness count. The owner table is checked at load. |
| 5 | One pending release per task; no stacking. | Simulator with long skips. |
| 6 | At most one `exclusive` task per callback (charts); kind eligibility holds. | Simulator with several charts and a `background` kind. |
| 7 | Deterministic: the same inputs give the same plan log. | Run each scenario and replayed trace twice and compare. No clock or randomness in the library. |
| 8 | A step costs at most its declared bound; the units consumed are at most the grant. | Native measurement, trace replay, and `instance.used <= grant` in mock tests. |
| 9 | A step runs exactly its planned stage or does no work. | Mock test: change state (reset, model, geometry) between plan and run. |
| 10 | A failing or malformed task retires alone. | Simulator: raise, bad `delay`, bad stage. |
| 11 | Under injected cost spikes the total stays under 20000. | Simulator fault injection. |
| 12 | The planner's measured cost in a callback is at most what it charged (`F + E` per task examined `+ W` per task run), so the unaccounted framework cost is zero; a scan of every ready task is bounded by the 128-task list. | Native measurement at 8, 32 and 128 tasks in the scenarios and mixes of 4.2, and the same rows offline in CI. |
| 13 | Migrated tasks have no production legacy entry point; remaining legacy-owned work keeps its cadence in `mixed`, with declared cost charged before planning. | Migration ownership and no-legacy-entry-point tests; mixed golden and host accounting tests. |
| 14 | Every declared piece and smallest step is at most `M` = 4000, and the run charge is at most 10% of a piece (a piece of 2240 or more). | CI check of the bounds table for `M`; the admission test reports indivisible stages below the minimum; the largest piece per mix and phase is tested against `M`, listing the known gaps (4.2). |
| 15 | Time wraps: plans depend only on differences of ticks, so the same run from any start on the int32 clock (above 2^15, 2^20, around 2^29 and 2^31) gives the same plans; `step` receives the host tick; `elapsed` is exact across the wrap. | Simulator from ten start ticks, long gaps with many wraps, a step that records `now`, on 64-bit Lua and on a Lua 5.3 built with `LUA_32BITS` (`make test-lua32`, in CI). |
| 16 | What a task or declaration supplies is validated where it enters: `due`, delays, declarations (types, costs up to the ceiling), kinds, shared names, stages that can never fit. A bad one is refused by `add` or retires its task; a declaration is copied, so later changes cannot break the planner. `run` raises only for a call the host got wrong (unknown kind, `now` or `used` not a number). | Unit tests of `add`, `run` and step results, including a declaration changed after `add`. |

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

Background callback rate (only `refresh` is documented as 50 ms); `getUsage`
attribution when `refresh` and `background` interleave; behavior with several
widget contexts and the shared flight broker; control's output read; the error
and retire path. Telemetry's native source cost, including 1-24 synchronous
History observers, is measured in section 5.2.

Also untested: real radio instruction counts against the native simulator's, and
the opcode counts of another luac point release (the charges keep 5% headroom,
section 4); a task starved for more than 2^31 ticks (it would look as if it were
in the future); callbacks more than 2^30 ticks apart; a re-entrant `run` from a
step; a shared-cost payer removed mid-plan (arithmetic-safe, simulator-tested
only); the Phase 3 step code on the wrapped clock (it must use `elapsed`).

## 9. Decisions needed

Decided by the user:

- The settings UI, log viewer, editor, menu, fullscreen input, app rebuild and
  theme showcase move to the new scheduler as modal kinds (R5); the legacy loop
  keeps them only temporarily, during migration.
- The flight tick, Smart and session reset are `normal`, with no deadline. The
  Smart rewrite (1 Hz, delay tolerant) is part of their migration, not a prior
  change (section 5.1). The extrema service is being removed in a separate change
  and is not in the task list, migration order or admission arithmetic.
- `mixed` is enabled in releases: migrated tasks run in the framework; all other
  tasks remain on their existing legacy paths until individually migrated. Their
  declared costs are charged to the scheduler; negative remaining room simply
  defers tasks. `new` remains development-only until every task has moved.
- The legacy-work estimate `L` in section 4 varies by migration phase and is used
  for feasibility comparisons, not enforced as a runtime cap. Half of capacity
  is not feasible for the original bounded-share model.
- The 15000 ceiling, the contracts' margin factors and `margin = 400` stay until
  hardware shows zero near-misses.

Also decided by the user: every service is split into independent tasks, and all
due tasks run together whenever they fit, oldest first with skip and continue (no
service group, no one-per-callback rule); telemetry polls each source at the
fastest rate any subscriber needs (section 5.2; the no-faster-than-the-sensor hint
is deferred). The spec puts that change **before R1**, as its own reviewed change.

Telemetry migration policy is resolved in section 5.2: omitted subscriptions
retain the 10-tick interval, each source uses its fastest requested interval, and
all History observers run synchronously. Optional model/source update-rate hints
remain out of scope.

## 10. Implementation notes (Phase 2)

Built as specified: `lib/scheduler.lua` (not called by the widget), with its
offline simulator, admission test, trace replay and measurement path in
`tests/support/scheduler_*.lua` and `tests/unit/lib/test_scheduler*.lua`. The
native measurement is `python3 tools/audit-scheduler.py --framework` (macOS,
Companion 2.12 x86_64); case files live in `tests/fixtures/scheduler-cases/`.
`make test-lua32` runs the scheduler tests on a Lua 5.3.6 built from lua.org with
`-DLUA_32BITS` (checksum-verified, in `build/lua32`), as EdgeTX builds it; CI runs
it, because the rest of the suite runs on 64-bit Lua. Choices where the
specification was silent or inconsistent:

- **API.** `scheduler.new(overhead)`, `s:add{ id, decl, instance, due }` (returns
  `true` or `false, reason`; `due` is a tick of the host's clock), `s:remove(id)`,
  `s:run(kind, now, used)`, `s:takeErrors()`, `s:dueOf(id)` and
  `s.lastPlan = { kind, U, charged, examined, ran }` with
  `U = overhead + used + F + the plan` (task bounds and charges) and
  `charged = F + E * examined + W * ran`. `scheduler.stagger(index, interval)`
  takes the registration index from 0 and accepts any interval. Declarations hold
  integer costs, at most two `shared` names. `add` refuses at 128 tasks by
  returning `false`: a host that ignores the result loses the task, so it checks.
- **Charged cost, no caps.** The first build capped examined and planned tasks
  (10, 6, 12) and reserved a fixed term; its measured cost was 2589 against the
  500 limit. By decision of the user it charges `F`, `E` and `W` as the plan is
  built, and the caps are gone. The only hard bound is the 128-task list: 128
  refused tasks cost 5060 measured and 8260 charged, paid from the budget. `ran`
  counts retired tasks as well. The scan stops when the room cannot admit the
  smallest registered step plus `E + W`; a list of 128 tasks that all fit costs
  about 130 per task measured against 288 charged, so a dense callback charges
  about twice its cost (the single-task case is the tight one, 15%).
- **int32 time (critique 1).** EdgeTX Lua has 32-bit integers and floats. The
  first build packed `due * 2^20 + seq` into one sort key, which overflowed at
  2048 ticks and hid ready tasks. Lists are now sorted by the pair `(due, seq)`,
  due compared by the wrapped difference `elapsed` (sign extension of the low 32
  bits, the identity on 32-bit Lua); a delay is limited to 2^30 and stored as an
  integer; `due` and `now` are validated. An epoch design (offsets from a moving
  epoch, a rebase every 2^29 ticks, a clamp, three constants and a charge spike of
  up to 2.2k every 62 days) was built first and replaced after review by absolute
  due times: it removed the epoch, the rebase, the clamp and the rebase charge with
  its constants, and made `dueOf` return a host tick; it costs about 7 more
  instructions per task examined and 45 per task run (the wrapped compares in the
  ready check and in reinsertion), which is in the `E` and `W` of section 4. Kept because it is smaller and simpler and
  the differential fuzz over start ticks up to the wrap gives identical plans on
  64-bit and 32-bit Lua. Cost of that choice: a task starved for more than 2^31
  ticks (248 days) looks as if it were in the future. The tests could not see any
  of this on 64-bit Lua, which is why they also run on 32-bit Lua and from start
  ticks around 2^15, 2^20, 2^29 and 2^31 (invariant 15).
- **Shared costs (critique 2 and 3).** The shared lookup is skipped for a task that
  does not fit without it, the per-plan "charged" mark is a stamp (nothing to
  clear), and a name has one cost, checked at `add`. Skipped tasks with one or two
  distinct shared names, and seeded random task sets, are in the measurement. A
  shared cost is billed to the first task planned and paid by the first that does
  the work; the plan total is unchanged when that task is removed, raises or does
  nothing, and the simulator charges whoever does the work, so it shows the case
  (tested).
- **Validation.** `kinds` must name kinds the host has and allow one; a stage that
  could never fit its room (including the charge, the shared costs and, for
  critical tasks, the reserve) is refused at `add`; costs above the ceiling and a
  non-table `shared` are refused; `due` is required (a missing one meant tick 0,
  which is wrong after the clock wraps: API change, stricter). A declaration is
  copied at its first add. Shared names are reference-counted and freed with
  their last task. `scheduler.elapsed(a, b)` is new public API (wrap-safe
  difference, for steps). `add` and `remove` are not charged (section 2).
- **Record size.** One record per task holds seven fields; everything per
  declaration (kinds, stages, shared names) lives in one table per declaration,
  which halves the heap at 128 tasks (33 KiB native).
- **Remove during a plan.** A task removed before its step runs is skipped, not
  run once more; an add takes effect at the next plan, as specified.
- **Refused tasks.** A ready task refused for its kind or `exclusive` is examined
  and charged `E`, and does not hide the tasks behind it (a background callback
  runs a service behind twenty steady-only charts). It really costs about 15, so
  steady-only panels tax background callbacks by about 50 each; a lower charge or
  per-kind lists would remove that and was not done (not simple enough to prove).
- **Reserve.** The normal reserve is applied literally: when `R` is below it,
  critical work waits and normal work uses `R`. Admission test A keeps `R` far
  above it.
- **Malformed input.** A `want` that is not a number plans the stage's
  `maxUnits`; below 1 it plans 1; a fraction is rounded down. A step that returns
  anything but a whole number of ticks from 1 to 2^30, raises, or names an unknown
  stage retires that task (reported once through `takeErrors`). `instance.used` is
  asserted by tests only, not at runtime, to keep `W` small.
- **Margin rule.** It applies the per-call constant `A` to an indivisible stage
  and to `fixed` only of a divisible one; a hand declaration (for example
  telemetry per batch) may differ.
- **What the simulator tests do and do not show.** The simulator measures the
  planner's own cost in each callback where it has a counter (the stubs' work is
  excluded), so `actual <= U` is a real check; the mix runs under jitter at the
  R4 head (620) and the R3 heads (tick 1000, plus Smart 2600 in every second
  callback) assert a wait bound and at least 85% (mix D 70%) of the runs an
  unlimited budget allows, for the combinations the admission test admits; mix D
  in R3 is not admitted and only its safety is asserted. The reference planner
  mirrors the library's formulas, so the random runs also check properties that do
  not (critical before normal, oldest first within a class, one exclusive task, a
  plan within the limit). The fault-injection limit of 20000 is arithmetic (a plan
  is at most the limit, the injected excess at most what is left); what the run
  shows is that plans really fill the budget. The jitter wait bound is measured
  (29 ticks at most in R3, 26 in R4), not derived.
- **Fault injection.** An injected excess of at most `20000 - ceiling` per
  callback (cost steps, spikes, bursts) is added on top of the plan; the
  simulator counts an overrun otherwise.
- **Left for later phases.** Layout admission (the host mode, tripwire and shadow
  mode are Phase 3, section 11). Admission tests A to E are test support, not
  radio code.
- **Bounds table.** `tests/fixtures/scheduler-bounds.lua` holds the contracts'
  declared bounds at the audit's labels (legacy granularity) for the trace
  replay and the `M` check; labels without a contract bound are listed there.
- **Mixes.** `tests/support/scheduler_mixes.lua` holds the declarations and
  releases of mixes A to D, shared by the simulator tests, the admission test
  and the native measurement. The tables of section 4 are asserted by the tests.
- **`M` = 4000 is decided** (user); mix D at 10 Hz is admitted for such pieces only
  from R4 (4.2), and the test lists the combinations below 4000.

### Measured framework cost (native, instructions)

Charged: `F` = 132, `E` = 64 per task examined, `W` = 224 per task run. Every
scenario (101 rows at 8, 32 and 128 tasks, mixes A to D, twelve random seeds) is
within its charge; the least slack is 15 (the idle callback) and the least
headroom 1.107 (a 3089-callback fuzz: 1.057).

| Callback (128 tasks unless noted) | Measured | Charged |
|---|---|---|
| nothing ready | 117 | 132 |
| 1 task run (end, front, middle reinsertion) | 262 to 364 | 420 |
| 4 / 16 tasks run | 1069 / 3837 | 1284 / 4740 |
| every ready task run until the room ends (48) | 6253 | 13956 |
| 127 ready tasks refused (too large / wrong kind) | 5060 / 2647 | 8260 |
| 127 skipped, the last runs (compaction) | 6029 | 8484 |
| 127 skipped for a shared cost, the last runs (two names) | 7667 | 8484 |
| staged, two shared costs, `want` (40 examined, 33 run) | 5162 | 10084 |
| failing steps / unknown stages / all retired (48 to 50 run) | 6685 / 5933 / 4211 | 13956 / 13956 / 14532 |
| mixes A to D: the tightest callback of 400 | 301 to 504 | 420 to 708 |

Per part: idle 117, 52 per task examined, 247 per task examined and run when one
runs. The 247 is dominated by `pcall`, the result checks and reinsertion; the
earlier targets of 4.2 (`F0` 40, `c1` 6, `o` 30) were below what these cost in
Lua. Heap: about 33 KiB for 128 registered tasks on the native simulator (44 KiB
in the desktop Lua used by the tests); the library itself is about 20 KiB on the
SD card.

## 11. Implementation notes (Phase 3)

Built: the host mode, the owner table, legacy-work accounting, call-site
handling, shadow mode and the tripwire, and the parity harness. The model service
is the first migrated task; `mixed` is the release mode.

**Where things are.** `main.lua` enables `SCHEDULER_MODE = "mixed"` and
`SCHEDULER_PROBE = false`. Release packaging enforces these settings and rejects
`new` mode. `lib/scheduler_host.lua` owns task registration, legacy cost
accounting and load checks. Modal callbacks run scheduler-owned services as
well. `tests/support/scheduler_host_fixture.lua` overrides the mode for tests;
`scheduler_parity.lua` is the task parity harness.

**Verification of mixed mode.** `tests/integration/test_scheduler_mixed.lua`
runs eight existing integration scenarios and hashes service updates and panel
dispatches to guard the remaining legacy-owned work and mixed coexistence. Native
legacy-vs-mixed measurements are recorded per callback kind; migrated-task parity
is covered by `test_scheduler_model.lua` and the model golden. Native traces are
phase dependent, so they were compared per callback by kind,
tasks and overhead, not byte for byte. `mixed` has not been run natively.

**Choices where the specification was silent.**

- **Owner table.** Keys are `service:<id>` (each service of the registry) and
  `panel:<type>` (a panel's refresh, the chart's stages included). A key is
  checked when the layout or registry changes: every loaded item needs an owner;
  a `legacy` one needs a declared bound for accounting; a `new` one needs a task
  registered under its key. A failure is logged as `has no owner`, `has no
  declared bound`, `is owned by the scheduler but has no task`, or `is not owned
  by the scheduler`. `new` needs every loaded task owned by the framework and
  skips the legacy loop; panel `background` hooks still run. The head work is
  not in the table: it stays at the head until R4 and R6.
- **Declared legacy bounds** are in `lib/scheduler_host.lua`: the panels' and
  services' values of the contracts; telemetry's is `750 + 1180 x min(sources,
  poll cap)`, so it follows the layout; `flight` and `armed` have no scheduled
  work (0); `theme-showcase` has no refresh work and is charged 0.
- **Legacy accounting.** The previous `LEGACY_SHARE` cap is removed. `used`
  contains the head work and declared costs for legacy services and panels that
  actually ran. If `used` leaves no room, the scheduler plans no task and raises
  no error. Missing bounds still block scheduler work because they cannot be
  accounted safely.
- **Modal callbacks** keep legacy panel handling until R5. They run legacy-owned
  services without a share cap, then run scheduler-owned tasks through the same
  framework. A migrated task has no legacy update method.
- **Overhead** is the contracts' declared value at 16 panels (steady 1250,
  background 1130), whatever the panel count.
- **Shadow mode** runs in `legacy` mode with the probe on: before the loop, a
  fresh planner is given the ready items (services and panels, due ticks, declared
  bounds, steady-only panels, the chart exclusive) and its choice is compared
  with what the legacy loop ran; the differences are kept in `probe.differences`
  and the first eight logged. The tripwire is not armed (`probe.armed`) until the
  native simulator has confirmed which callback `getUsage` reports when `refresh`
  and `background` interleave; the probe's own cost shows in `getUsage`.
- **Starvation risk of services first.** A due panel at the cursor that does not
  fit what the services left of the share waits for a callback where it does. With
  callbacks exactly five ticks apart (every fourth one background) the metric
  panel was never refreshed in a test run; with irregular callbacks (the radio's)
  it was. If hardware shows it, the remedy is the order (panels first) or a
  panel reserve inside the share, not a larger share.
- **Parity harness.** `golden`, `extraction`, `replay` and `budgeted` run an
  adapter over a trace (steps 1 to 4 of section 7; the native gate is by hand).
  The legacy loop is the real `services.update`; the planner is the real one; the
  budgeted run asserts the plan stays under the budget, and `timing` gives the
  lateness against the legacy run and the longest gaps. A migration writes an
  adapter and its trace; `test_scheduler_parity.lua` shows it on the stand-in.

## 12. Implementation notes (first migration: the model service)

`service:model` is owned by the new scheduler in `mixed` mode, which is enabled
in releases. At the user's direction, the model interval is 100 ticks and the
production service no longer has a parallel legacy `update()` path.

**Contract.** `service:model`, `normal` (nothing is recorded, so a late read only
shows a value later; a critical task would also take the normal reserve), one stage
`run`, unit = facet, not exclusive, `steady` and `background`, `want` = the facets
subscribed to (at most 7 reach it: identity, flight mode, TX voltage, battery range
and timers 0 to 2; an update reads up to `maxUnits` = 4, round robin), bound
`90 + 120 x facets` (210 at one, 570 at four), next release 100 ticks after the one
that ran (identity re-reads every 500 inside the facet), no split (the whole task is
0.57k, far below `M`, and a split would add `G` per piece to pieces already below the
minimum useful size). Declared in `model_service.lua` (`modelService.decl`), measured
by `tests/fixtures/scheduler-cases/model.lua` at every cursor start and grant, with
every facet on its most expensive path and on the opposite one.

| | |
|---|---|
| Measured step (native = offline, 32-bit Lua) | 141, 246, 351, 412 for 1 to 4 facets; fit 36 + 105 per facet |
| Declared (margin rule, normal) | 90 + 120 per facet: 67% to 78% of the bound at the measured grants |
| Framework cost of one release | 243 native (245 offline), against 420 charged (`G` = 288 inside it) |
| Share of the piece | `G` is 50% of the 570 at four facets (137% of the 210 at one): the task is divisible and below the minimum useful size 2240, a natural exception like history |
| Shared `read` work | 34 instructions cheaper than the pre-migration update (464 to 430 at four facets, offline); production service has no `update` method |
| Matched native run (`model-panels`: identity, flight mode, timer, TX battery; five facets) | At the one-second cadence, the current mixed run has 25 model releases (mean/max 248/294 instructions); legacy mode has none because the production `update()` path is removed. The pre-removal one-second legacy baseline measured 25 releases at mean/max 228/274. Current legacy-to-mixed callback mean/max: refresh 704/1626 to 1011/2783, background 550/550 to 768/1199, and refresh-at-load 1474/9168 to 1495/9189. The mixed worst callback is 9189 instructions. |

**What changed in the service.** `step(grant, stage, now)` is the production entry
point; `read(grant, now)` holds the bounded round robin over facets, which no longer
goes through `services.roundRobin` and its per-facet callback (34 instructions less
than the pre-migration update at four facets, 7%). The production service has no
`update()` method, and the registry skips scheduler-only services. The parity harness
supplies a test-only `update` adapter to compare the extracted work against the old
legacy golden. `step` advances `due` and the revision itself. It returns the remaining
delay when `due` is in the future; modal callbacks also run this task through the
scheduler, so no task-specific legacy path is needed. Ticks are compared by the
wrapped difference.
`step` calls the scheduler's shared `elapsed` helper; the planner keeps its
measured inline comparisons on its hot path. The helper adds 4 measured
instructions to a model release; the declared task bound is unchanged.

**Mixed-mode budget consequence.** When declared legacy work leaves negative room, the model task remains due and
eligible for a later callback with room; the scheduler reports no task error.
If no callback leaves room, it can remain overdue indefinitely. The shipped
gallery fixture leaves no room across its 80 callbacks, so model-dependent
values such as the flight timer remain unavailable there. Preserving those
values in this overloaded layout would require deferring legacy work, which the
user chose not to do.

**What was looked at and left.** A skip of the timer derivation and text when the
timer is unchanged saves 45 instructions of an unchanged timer read (123 to 78) but
costs about 10 on the changed read, which is the one that is declared; the planner
charges the worst case, so the declared bound would rise 8% to save instructions it
does not plan on: not done. `formatTime` with integer division saves 6 instructions per
timer: not worth a change to a shared helper. Findings that change what is
published or when, **for the user to decide**:

- **Applied per user direction:** read model facets at most once a second.
  `INTERVAL` is 100 ticks; flight mode and TX voltage may therefore be up to one
  second old, while the timer still refreshes every 100 ticks and identity every 500.
  Service bounds and work are unchanged. The parity trace uses the new cadence;
  mixed integration hashes cover the coexistence path.

Other candidate changes that were **not applied**:

- The battery range is read at the service interval: the firmware builds a table for it on
  every call (its cost is not in the instruction count). It changes only when the pilot
  edits radio settings, so it could be read at the identity rate (500 ticks), showing a
  change up to 5 s later.

**Host.** The host registers the task of every service the owner table gives to `new`
(`host:enroll`) from the service's own declaration, staggered by its registry position,
and only once it has subscribers (a service nothing reads has no task, as specified; a
panel the editor adds later registers it at the next callback). A new layout or service
registry drops the old tasks and registers again (`host:resync`). A retired task marks its
service `failed`, so the legacy loop of a modal callback does not run it either, as a
failed service is retired in `legacy`. The one cost of the registration check is a
table test per callback. `SERVICE_BOUNDS.model` is read from the declaration (one
number, and flipping the owner back to `legacy` keeps a bound). A task owned by `new`
with subscribers but no `step` is a load error naming it.

**Spec gaps found.**

- The fit rule (steepest slope from one unit, largest offset) bounds four facets at 570
  against 408 measured (140%): the three expensive units are the timers, the fourth
  is cheaper, and a line cannot say that. Accepted rather than adding a per-grant table.
- The 90% re-declaration warning sits below 1 / 1.10 = 91%, so a per-unit bound at
  the normal margin and no fixed part warns "high" at the measured point. This task's
  fixed part keeps it at 65% to 77%.
- Case files are now a table or a function of `load(relative)`, so a case can build the
  real widget module (`measure.open`); the native harness and the offline tests each
  supply a loader. `measure.planner` measures the framework's cost of one release of
  the real task, and `test_scheduler_cases.lua` enforces in CI (offline counts equal the
  native counts) that every case file's measured cost is within its declaration and not
  above 90% of it, and that the planner's cost is within the charge. The native report
  printed grants 1 to n as a JSON array that the report could not read (fixed).
- The native audit takes `--mode mixed` (results in `<scenario>-mixed`, left out of
  `--report` and the traces) and a `model-panels` scenario; the probe wraps `step`
  for tasks the scheduler runs.
- Not run: the native pixel comparison (step 5 of section 7) for `mixed`.

## 13. Implementation notes (control and Armed services)

The shared dashboard `service:control` is scheduler-owned in `mixed`; the flight
broker's private control runtime keeps its legacy `update()` path. The Phase 2
`lib/scheduler.lua`, flight detection and Smart implementation were not changed.

**Reader map and split.** `armed:state()` is read by the flight counter,
navigation first-arm capture, history sessions, and the shared flight
registration path; charts reach the same arm state through history. Those
switches remain critical. State panels subscribe through
`control:displaySwitch()` and are normal display work. If an Armed reader uses
the same condition, its shared entry is transferred from Control's normal task
and polled once by Armed. Trims, outputs, and global variables also remain
normal display data. Flight detection and reset still use the broker's private
control runtime. The shared services now have a critical Armed task, Control's
critical task for any remaining critical switch readers, a normal
trim/global-variable/display-switch task, and a normal channel-output task.

**Contracts.** All are non-exclusive `run` stages eligible in `steady` and
`background`; the declaration lives on the service and the host registers only
tasks with subscribers. Every task has a round-robin cursor, reads only its
grant, and returns delay 1 while a partial release remains. Output polling
retains its 10-tick interval when an output panel exists.

| Task | Tier and unit | Declared bound | Native measured steps | Split size and reason |
|---|---|---|---|---|
| `service:armed` | CRITICAL, switch condition, max 6 | `180 + 120 n` (900 max) | 150, 239, 328, 417, 506, 595 | Arm and boundary readers are split from direct Control conditions |
| `service:control` | CRITICAL, remaining direct critical switch condition, max 6 | `200 + 100 n` (800 max) | 153, 233, 313, 393, 473, 553 (baseline) | A shared condition claimed by Armed is transferred, never polled twice |
| `service:control-normal` | NORMAL, trim/global-variable/display-switch entry, max 6 | `130 + 240 n` (1570 max) | 282, 493, 704, 915, 1018, 1121 | Keep each natural entry atomic; the complete task is below 2240 |
| `service:control-outputs` | NORMAL, channel output, max 32 | `120 + 60 n` (2040 max) | 113 at 1, then +51 per unit through 1694 at 32 | Keep each natural channel read atomic; the complete task is below 2240 |

`tests/fixtures/scheduler-cases/armed.lua` and
`control-{critical,normal,outputs}.lua` measure all grants and cursor starts
with the expensive paths enabled; parity tests also exercise delayed and
partial grants. The two normal tasks are documented
exceptions to the 2240 minimum useful size: their natural unit is indivisible,
and merging their different work/cadences would make grants less useful. The
critical task is smaller still, but only contains the small set of conditions
needed before display work.

| Measurement | Result |
|---|---|
| Framework cost per release | 243 native instructions against 420 charged (`G` = 288 inside the charge) |
| Default gallery (9 panels), native legacy / mixed worst callback | 12684 / 14789 instructions; mixed Armed and Control-normal tasks each ran 125 times over 469 refresh callbacks (worst steps 174 / 384) |
| Light control layout (2 panels), native legacy / mixed worst callback | 9168 / 9189 instructions including load; display-only State switches run on Control-normal (125 calls, max 643) |
| Output maximum (1 panel), native legacy / mixed worst callback | 9168 / 9189 including load; steady refresh maximum 1183 / 7369; output / normal task steps max 999 / 1110 |
| Flight-smart (2 panels), native legacy / mixed worst callback | 9860 / 9906 instructions; mixed Armed ran 225 times, max step 163 |
| Session-reset (2 panels), native legacy / mixed worst callback | 10095 / 10780 instructions; mixed Armed ran 219 times, max step 163 |

The mixed audit confirms that the critical Armed task runs before normal work
whenever room remains. Default's overloaded callback may have no room: Armed
and Control revisions stay unchanged there, and normal trims, outputs, State
conditions, and global-variable displays can remain stale until a later
callback admits them. Native Default admits both tasks in some callbacks; the
no-room behavior is per callback, not a permanent shutdown. The light layout
has room for both classes. No scheduler policy changed: negative room still
defers every task without an error, and the 6650 legacy-share estimate remains
unchanged.

The `flight-smart` feed end indices also differ between the matched runs
(`[436, 438, 438]` legacy; `[447, 448, 448]` mixed), as do `session-reset`
indices (`[0, 0, 0]`; `[73, 73, 73]`). These scenario-level differences include
all mixed service owners and are not attributable to Armed alone; their cause
remains unresolved despite passing arm-state parity and no-room checks.

The resource-stability `review-chart` case can also leave chart buffers
incomplete after 500 callbacks while the critical Armed task cannot fit; the
chart task then has no opportunity to mount them. Its memory check now
distinguishes a deferred mount from a reflow allocation, while the separate
chart tests continue to verify completed rendering when the task has room. No
chart code changed.

**Behavior and parity.** The shared dashboard no longer performs all control
reads in one legacy update. Only Armed boundary conditions retain critical
priority; State conditions, trims, outputs, and global variables can lag under
scheduler pressure. Completed reads preserve the published values, revisions,
and error handling. The private flight runtime is unchanged. The native control
case creates all 32 output subscriptions, matching the output panel's maximum
read set, and measures every
grant; the separate `output-max` audit exercises actual panel rendering. The
remaining native mixed/legacy findings are recorded above.

## 16. Panel registration bridge (migration prerequisite only)

The host can register one task per panel placement through
`panel_host.task(entry)`. A migrated module supplies `decl` and `step`; the
bridge retains the existing numeric refresh-interval contract and isolates
panel errors through the scheduler's deferred report path. An unfinished step
requests another release after one tick. Task ids use placement ids, while
ownership remains keyed by panel type.

Surviving placements retain their pending releases when services are
re-registered. Layout replacement, editor insertion/removal, and App-mode
rebuilds invalidate panel registration; removed entries are retired before
replacement tasks with the same placement ids are added. Declarations remain
responsible for callback-kind eligibility and the exclusive chart constraint.

**This is infrastructure, not an ownership flip.** All production panel owners
remain legacy. Staged chart publication, bounded refresh extraction, measured
declarations, and explicit modal eligibility/accounting are still required
before enabling panel tasks. Flight/Smart and loader/modal migration are also
outstanding. In particular, changing the editor to the ordinary steady
dispatcher before its accounting is measured changes service capacity and
can starve post-reset recording; this bridge leaves those callback paths
unchanged.

`test_scheduler_panels.lua` covers independent same-type placements, pending
release preservation, replacement and retirement, exclusive and background
eligibility, unfinished refresh intervals, and isolated/deferred failures.
The host integration suite covers automatic placement enrollment in `new`
mode with stand-in tasks.

Validation on this layer: the panel lifecycle, scheduler-host and scheduler
library suites pass; isolated Output review remains at 20000 mock instructions
and session reset at 14300. Broader runs are not clean: mixed trace integration
fails Output review at 20200 and editor UI fails its 15000 regression check at
15200. Both failures also reproduce on the unchanged `bf2ae93` refactor
baseline. The deferred chart-recording stress failures and 10-tick
History/Telemetry policy are unchanged; no full-migration or native-release
gate is claimed.

## 17. Bounded Output extraction (R2, ownership still legacy)

Output exposes separate task stages for preparation, render capture/comparison,
and row application. Preparation creates or mounts at most one row, and caption
measurement advances at most eight rows per step. Capture does not run in that
step: the earlier combined preparation/capture measured 4610 native instructions,
and even preparation alone measured 4256 before caption scanning was split.
Neither failure was addressed by raising the 4000 atom cap.

| Output stage | Native worst instructions | Declared charge |
|---|---:|---:|
| Prepare, including final caption slice and row mounting | 1622 | 1840 |
| Capture, including unchanged-snapshot comparison | 2946 | 3300 |
| Apply, one row | 756 | 890 |
| Apply, two rows | 1142 | 1320 |
| Framework release | 247 | 420 |

`output-panel.lua` measures real Output, Control subscriptions, theme and
primitive Lua work with constant-cost native API stand-ins. It exercises five
seeds, availability changes, initial/final caption slices, row construction,
fresh/stable capture, every row cursor and both grants, plus an empty panel.
The stand-ins conservatively add Lua instructions rather than using the heavy
widget mock's instruction charges. The matched native `output-min` and
`output-max` mixed scenarios both remain at 9189 instructions for their worst
callback; those callbacks still use the legacy Output owner.

Preparation and row application are explicit exceptions to the 2240 useful-work
target: the bounded one-row mount/eight-caption slice and at most two painted
rows trade additional releases for shorter pieces. A final one-row or empty
presentation piece still consumes one unit. No grant exceeds the declared atom
cap. Unfinished work requests a one-tick release without overwriting Output's
base ten-tick interval.

The bridge publishes the panel's stage, requested units and actual units used.
The retained application snapshot cannot change between partial grants; caption
names come from the scan that established their column geometry. Reflow discards
partial preparation and capture/application work, and a stale plan does no work.
The step-level suite covers these invariants, availability, missing/empty names,
finite mounting, zero-row presentation, and completed legacy parity.

Targeted suites pass through the repository's Lua 5.3 `tests/run.py` runner:
Output task/review/memory, scheduler cases, and panel lifecycle/host. The Output
memory run completes 100 measured cycles (87330 callbacks), retains 333 live
objects, and peaks at 0.305 KiB growth. Standalone system Lua 5.5 instead fails
the memory threshold at 1.188 KiB after two cycles on both this tree and unchanged
`bf2ae93`; the supported runner is the relevant result.
The scheduler suite also passes `make test-lua32`, including the Output bounds
case. Its missing runtime was built from checksum-verified official Lua 5.3.6
source; the initial `www.lua.org` download failed, but `lua.org` succeeded.

**No panel owner changes in this extraction.** Production still uses synchronous
Output refresh/update, so modal eligibility, callback accounting and retirement
remain gates before enabling its task. R1 chart stages, other R2 panels,
R4 Flight/Smart, and R5/R6 modal/lifecycle/loader work remain open. The ten-tick
History/Telemetry policy and deferred chart-recording stress failures are unchanged.

## 18. Chart reading/legend split (R1 subpipeline only)

The chart's synchronous renderer and new reading subpipeline share the same
formatting, width, font-selection, geometry and positioning helpers. The staged
path captures all three feeds before changing the first series, then advances
one series or font candidate per unit. Geometry setup/application and width
measurement are separate stages. Final positioning publishes the geometry
revision and refreshes the header only after all series are positioned.

An intermediate layout stage measured 3980 native instructions, which would
require a 4430 declaration after margin. Font selection was therefore split
into one candidate per step, not granted an exception to the 4000 cap.

| Reading/legend stage | Native worst instructions | Declared charge |
|---|---:|---:|
| Feed capture / one series' text | 615 | 730 |
| Width measurement | 575 | 690 |
| Geometry setup or application | 868 | 1010 |
| One font candidate | 1045 | 1200 |
| One series' position, including final header publication | 2668 | 2990 |
| Framework release | 242 | 420 |

`chart-readings.lua` measures zero/one/three series, missing feeds, stale
readings, precisions zero through three, top/side and narrow legends, unchanged
and growing geometry, every series/font cursor, both layout phases, and captions
and headings up to 4100 characters. Smaller series/font/geometry pieces are
natural-stage exceptions to the 2240 useful-work target. Declarations cover the
measured cases; this is not a new claim about arbitrary configuration sizes or
complete callback-kind eligibility.

The staged reading suite compares completed text, coordinates, extrema,
symbols, visibility and font selection with the synchronous renderer. It
changes live feeds after capture, verifies one-series grants, stable-frame
termination, reflow invalidation during every noninitial stage, and session
reset invalidation. Existing chart unit/flight/preview/reset suites, scheduler
bounds and `make test-lua32` pass. Native `chart-full` in mixed mode remains
within the callback limit (11071 worst instructions). Matched mixed native
`chart-min`, `chart-max` and `default-gallery` callbacks peak at 10515, 11571
and 11845 instructions respectively.

The deferred recording stress test still fails at its live-drawing assertion
(`test_chart_recording.lua:192`, Q1 `drawn=nil`, baseline revision 8, current 98).
The identical assertion and state reproduce on pre-extraction `7a994ed`.
No stress assertion, recording policy, or production ownership was changed.

**This is not a complete chart scheduler task.** `readingDecl` is deliberately
not the module's production `decl`: frame capture, axis/grid work, grant-sized
projection/application, markers and double-buffer publication still need their
full stage adapter and measurements. Modal eligibility/accounting and the
other R1/R2/R4/R5/R6 gates remain open before any owner flip.

## 19. Chart trace grants and coordinate retirement (R1 subpipeline)

The trace subpipeline separately selects/prepares a series, projects one or
two source knots, and applies one run/marker unit. It shares the legacy
projection, coalescing, point pools, resumed connectors and marker code.

Projection's old `finishRun` also cleared every unused coordinate in a reused
point array. A one-knot limit did not bound that cleanup. Bounded projection
now leaves that tail for application, which retires at most 128 coordinates
per step before sending the line to LVGL. Pooled point objects are retained,
and no stale tail reaches a native line. The synchronous renderer retains its
original complete-tail retirement.

| Trace stage | Native worst instructions | Declared charge |
|---|---:|---:|
| Select/prepare (third series) | 325 | 410 |
| Project one source knot | 1252 | 1440 |
| Project two source knots | 2299 | 2600 |
| Apply / bounded tail retirement | 638 | 760 |
| Framework release | 242 | 420 |

`chart-traces.lua` uses the real History service's packed point/block decoders,
not mock decoder costs. Cases include rolling seek, axis breaks, expiry,
coalesced/extrema projection at 32 consecutive cursors, end-of-run arrays of
4096 coordinates, final/partial cleanup, connectors and markers. The shared
API stand-ins are loaded from test support by both native and offline runners.
Smaller selection/application steps remain natural-stage exceptions to the
2240 useful-work target; the normal two-knot grant is above it.

The trace integration test compares completed runs, coordinate lists, dotted
connectors and active markers with the legacy frame for both one- and two-knot
grants. It asserts the 128-coordinate cap, prohibits line publication during
partial cleanup, and covers expired history and stale plans after reset.

`traceDecl` is another subpipeline, not the production `decl`. The enclosing
frame owner must bind frozen feeds/session, handle expiry/rollback and drive
axis/grid/session markers and final double-buffer publication. These parts
and measured modal/lifecycle accounting still gate the full adapter and owner
changes. No production owner, recording cadence or deferred stress assertion
has changed.

Verification: trace/reading parity, existing chart unit/flight/preview/reset
suites, all measured scheduler cases, Lua32 and the 20 audit-tool tests pass.
Matched native mixed `chart-max` / `default-gallery` callbacks peak at
11600 / 11845 instructions. The deferred recording stress failure still
reproduces at the same line 192 and state recorded in section 18.

## 20. Complete chart frame adapter (R1, ownership still legacy)

`chart.step` now composes frame capture, frozen readings/legend work, axis,
grid/range preparation, grant-sized traces, flight bands, resume/arm markers
and explicit double-buffer publication. The synchronous renderer shares the
same helpers and keeps its original quotas. Task axis work scans at most eight
boundaries, grid preparation changes one pool slot, and session-marker work
scans or applies one boundary/marker per release. The previous root remains
visible until the publication stage. Expired history rolls back the incomplete
buffer; reset and reflow invalidate a previously planned stage.

| Complete adapter stage | Native worst instructions | Declared charge |
|---|---:|---:|
| Frame capture, including cold buffers / cached comparison | 1318 | 1500 |
| Axis, grants 1 through 8 | 335, 386, 405, 456, 507, 558, 650, 650 | `370 + 60 n` (850 max) |
| Plot/header/ranges and one grid slot | 1775 | 2010 |
| Flight-band update | 530 | 640 |
| Resume marker scan/application | 374 | 470 |
| Arm marker scan/application | 380 | 470 |
| Explicit plot-root publication | 205 | 280 |
| Frozen reading capture / one series | 720 | 850 |
| Reading width measurement | 656 | 780 |
| Geometry setup/application | 953 | 1100 |
| One font candidate | 1130 | 1300 |
| One position / final header | 2740 | 3070 |
| Trace selection | 354 | 440 |
| Projection, grants 1 / 2 in the enclosing-frame cases | 828 / 1215 | 1560 / 2840 |
| Trace application / bounded coordinate retirement | 661 | 780 |
| Framework release | 242 | 420 |

The reading and trace declarations share their stage tables with the complete
adapter and now include its binding margin; these charges supersede sections
18/19. Projection deliberately retains the heavier subpipeline coverage
(1252 / 2299 instructions), rather than tightening its bound to the cheaper
enclosing-frame cases. The native report flags those enclosing projection
cases as loose. Smaller frame/marker/grid pieces are natural-stage exceptions
to the 2240 useful-work target. The 4000 atom cap is unchanged.

`chart-frame.lua` drives actual steps to every declared stage, including axis
finalization at all grants, both layout phases, series/font/projection cursors,
cold/cached capture, header invalidation, marker creation/finalization, expiry,
and 4096-coordinate retirement. Its shared fixture uses real packed History
data and asserts that resume/arm boundaries and a closed flight were recorded.
Native framework images restore the uninstrumented chart source: otherwise
the new enclosing dispatcher reaches production probe calls that do not exist
in the framework image. A Python regression test checks that isolation and
the shared fixture's packaging.

The integration suite compares complete axis/grid geometry, flight bands,
resume/arm markers, header/status, traces and root publication with legacy
output under both projection grants. It also covers cold/cached frames, frozen
readings/session time, reflow during pending stages, reset before publication,
expiry rollback, and unavailable History. Chart unit, reading/trace, preview,
flight-recording and session-reset suites pass, as do Output task, panel
lifecycle/host, Lua32 and all 21 audit-tool tests.

Verification commands:

```sh
python3 tools/audit-scheduler.py --framework chart-frame chart-traces chart-readings --timeout 180
build/lua32/lua tests/unit/lib/test_scheduler_cases.lua "$PWD"
python3 tools/audit-scheduler.py chart-min chart-max chart-full default-gallery --timeout 180
python3 -m unittest discover -s tools -p test_scheduler_audit.py
make test-lua32
```

Matched native mixed callbacks peak at 10638 / 11694 / 11173 / 11845 instructions
for chart-min / chart-max / chart-full / default-gallery, respectively. These
still exercise legacy production owners, not scheduler-owned chart execution.

**Eligibility and loader gates remain open.** The recording and independent-arm
stress suites are not passing: in this tree they can fail earlier at their strict
loading-callback assertion (`test_chart_recording.lua:93`, callback 30, 15000
mock instructions). The archived `c280232` baseline reaches the deferred
live-drawing assertion at line 192 instead. The extra module initialization
therefore remains an explicit loader-budget gate, not evidence that the old
stress failure was repaired or reproduced identically. Sharing declarations
removed an additional initial construction loop; flight-recording passes,
but that does not close the other loading/stress gates.

No ownership, modal dispatcher, History/Telemetry ten-tick policy, or stress
assertion has changed. Measured modal/lifecycle/loader accounting, hidden/editor
preview eligibility and full scheduler-owned callback checks are still required
before enabling the adapter or claiming the migration complete.

## 21. Separate panel preparation from construction (R6 prerequisite)

The staged loader now prepares a panel module, validates its contract/span and
resolves settings in `panel-prepare`, then constructs it in `panel-build`.
This adds one callback per accepted placement. Rejected preparation reports its
error without constructing a container; failed construction retains the existing
clear/hide/report behavior. A replacement load discards prepared state.
Construction recomputes the rectangle against the current zone, so a resize
between the two callbacks cannot mount stale geometry. Synchronous editor and
preview callers retain the original one-call `buildPanel` interface.

This closes the **new initial loading-budget failure from section 20**, without
weakening its threshold or changing the deferred live-drawing assertion.
Recording and independent-arm stress again reach line 192: Q1 `drawn=nil`,
baseline/current revisions 7/98 and 1/43 respectively. Those revisions differ
from the archived baseline because loading now spans additional callbacks.
The existing deferred progress failure remains; it has not been repaired.
Flight-recording still passes.

| Native mixed scenario | Preparation maximum | Construction maximum | Whole-callback maximum |
|---|---:|---:|---:|
| chart-min | 1799 | 8882 | 9189 |
| chart-max | 1823 | 9911 | 10155 |
| chart-full | 1760 | 9455 | 10801 |
| default-gallery | 1580 | 4845 | 11845 |

These are the latest real native callback spans, measured with:

```sh
python3 tools/audit-scheduler.py chart-min chart-max chart-full default-gallery --timeout 180
```

The production probe now labels preparation by panel type. Legacy trace bounds
for chart/flight-counter/metric preparation are 2100/1200/1340 respectively;
these are not new scheduler task declarations. **Construction still exceeds
4000**, notably chart construction at 9911: this split is not sufficient to make
the loader scheduler-owned. Further constructor/lifecycle splits and modal/
callback-kind accounting remain gates. No owner or scheduler eligibility changed.

`test_panel_loading.lua` verifies separate preparation/construction, exact reuse
of prepared module/settings, current-zone geometry, both failure paths and
replacement-load invalidation. All-panel spans, builder matrix, background
initialization, panel reflow/schema, shared module code, session reset and the
chart parity/preview/flight/reset suites pass. Shared-module retained growth is
0.1 KiB; session reset remains at 14300 mock instructions and still reports its
existing first-arm mixed-load XFAIL. The 21 audit-tool tests pass.

## 22. Staged chart construction (R6, ownership unchanged)

Panels may optionally expose `construct(instance, rect)`. The ordinary loader
sets `services.staged` only for that validated callback: `create` returns a
partial instance, and each following callback performs one construction step.
The host requires a boolean result, keeps the container hidden and the instance
outside the live registry until completion, and reports/clears failed or malformed
steps. Reload and page retirement discard unfinished instances before their
native objects can be reused. Editor/preview and other synchronous callers still
receive a complete instance from `create`.

Chart construction now has a shell, one History subscription/series per step,
controls, geometry setup, one font candidate, geometry application and one series'
position per step. The final position publishes initial geometry/status. It
shares the synchronous helpers rather than maintaining a second implementation.
Construction receives current local geometry; resizing while a geometry pass is
unfinished restarts that pass, without publishing the partial panel.

| Construction body | Native worst instructions | Fixture cost declaration |
|---|---:|---:|
| Shell / initial session | 784 | 920 |
| One series and History subscription | 833 | 970 |
| Plot/header controls | 414 | 510 |
| Geometry setup/application | 792 | 930 |
| One font candidate | 971 | 1120 |
| One position / final header and status | 2628 | 2950 |
| Framework release | 242 | 420 |

`chart-construction.lua` measures cold/warm History, zero/one/three series,
all series/font cursors, both geometry phases, top/side/narrow layouts, long
headings/captions and resize invalidation. The fixture isolates construction
bodies; its `steady` kind is only the measurement runner's admission context,
not new runtime eligibility. Production still drives construction through its
legacy loading callback. The real loader also includes rectangle/container,
dispatch and registration work; its largest observed chart shell/series/control/
layout/font/position spans are approximately 1567/1279/533/1270/1165/1506
instructions. Those complete legacy spans remain separately labeled for future
host accounting, not silently equated with the fixture's body declarations.

Commands:

```sh
python3 tools/audit-scheduler.py --framework chart-construction chart-frame chart-readings chart-traces --timeout 180
python3 tools/audit-scheduler.py chart-min chart-max chart-full default-gallery --timeout 180
make test-lua32
```

Latest native mixed whole-callback maxima are 9189/9398/10612/11845 for
chart-min/chart-max/chart-full/default-gallery. No chart construction phase now
requires the prior 9911-instruction atom. The historical trace bounds retain
their old construction bound until traces are regenerated; new construction
labels remain explicit host-accounting gates.

The loader integration suite now also checks hidden/unregistered partial state,
enrollment only after completion, resize during positioning, construction
exceptions/non-boolean results, cancellation and retirement across native
cleanup. Chart unit/reading/trace/preview/flight/reset, all-panel spans, builder
matrix, background initialization, reflow, panel contract, shared-module code,
Output task, Lua32 and 21 audit-tool tests pass. Retained shared-module growth
remains 0.1 KiB; session reset remains at 14300 mock instructions with its existing
first-arm XFAIL.

The deferred recording suites still fail at the line-192 live-drawing assertion,
not the initial budget check. Longer staged initialization changes which source
is first stalled: the ordinary case reports Q7, revisions 2/93, and independent
arms Q1, revisions 0/42 in this run. No drawing-progress assertion was weakened
and no telemetry scheduling policy was changed.

This closes chart construction's oversized-body gate, not R6 as a whole.
Other constructors, theme/header loading, reflow, input/modal accounting and
callback-kind eligibility still require their own splits and complete callback
checks. Flight/Smart and all production panel owners remain legacy.

## 23. Native editor/modal callback inventory (R5/R6, gates open)

The native runner can now enter fullscreen through the same real long-press
input used by the screenshot harness. Editor scenarios wait for native
`lvgl.isFullScreen()` and a completed dashboard before progressing; they assert
successful editor entry, completed UI construction, and clean exit. No fake
fullscreen API or replacement editor implementation is used.

Audit actions now execute inside instruction-counted callback windows rather
than outside the measurement. Capture rejects a result that omits an action's
timed sample. Per-phase and per-editor-build-stage callback rows distinguish
stable preview from the ten UI-building callbacks. Controller entry/advance/
restore bodies have their own calibrated spans.

```sh
python3 tools/audit-scheduler.py editor-preview-metric editor-preview-chart metric-16 --timeout 180
python3 -m unittest discover -s tools -p test_scheduler_audit.py
```

Both commands exit 0; the latter has 23 passing tests. The native command is
an inventory capture, **not an admission pass**: it deliberately measures
oversized callbacks without the firmware instruction-limit hook terminating
them. Current mixed-owner measurements:

| Surface | 16 metric placements | One maximum-span chart |
|---|---:|---:|
| Editor entry body | 18868 | 1943 |
| Timed entry action, including audit wrapper | 18909 | 1984 |
| Largest editor-building controller body | 6680 | 1622 |
| Largest actual UI-building callback | 7105 | 2573 |
| Stable editor-preview callback | 21763 | 12034 |
| Clean exit/preview restoration action | 702 | 162 |
| Largest callback across the scenario | 24543 | 12034 |

Entry actions measure the actual controller but do not include the enclosing
production input callback's Flight/head work; their totals are not full-input
callback bounds. In particular, the 18868 entry body already fails both the
4000 atom and 15000 whole-callback gates before that extra work. UI construction
stage 10 accounts for the 6680 body and also needs a split.

The 16-metric preview callback invokes six legacy metric refreshes after modal
service work without reserving them first. The matched ordinary `metric-16`
scenario independently reaches 24528 instructions (24236 in its steady phase).
Its worst samples likewise contain six metric refreshes of approximately
3136-4239 instructions each. This is measured production legacy work, not new
scheduler-owned dispatch. Merely adding a modal kind would not fix the atom,
legacy preview accounting or whole-callback budget.

Next gates are bounded session copying/entry and final editor UI construction,
legacy preview admission before scheduler allocation, and explicit service-only
modal/preview eligibility without starving History. The chart editor's observed
whole-callback pass does not establish those gates for all placements. No
production dispatch, owner, callback kind, deferred stress assertion or ten-tick
History/Telemetry policy changed in this measurement slice.

## 24. Bounded initial editor rendering (R6, ownership unchanged)

The former final UI-construction callback ran preview synchronization, geometry
and visibility for all 16 slots, add-panel placement and status publication at
once. These now use the same helpers as ordinary rendering but run in separate
construction callbacks: synchronization, four groups of four preview slots, then
add-panel/status finalization. The screen remains hidden until the last callback.
Initial change detection survives all groups; resumed-preview scheduling and
error reporting still occur at the same publication boundary. Ordinary input
rendering retains its existing synchronous behavior and remains a separate gate.

Matched native cases use all 16 metric placements and the maximum-span chart:

| Construction surface | 16 metrics | One chart |
|---|---:|---:|
| Largest controller construction body, all stages | 1350 | 1079 |
| Synchronize initial preview, whole callback | 1154 | 1065 |
| Largest four-slot geometry/visibility callback | 1775 | 1200 |
| Add-panel/status publication, whole callback | 1280 | 1199 |
| Largest whole callback across all construction stages | 1932 | 2459 |

This removes the observed 6680-instruction final construction body. Every
UI-construction callback in these native cases is below 4000, including its
actual Flight/head work. This is measured construction coverage, not a complete
modal declaration or proof for unmeasured drawers/input callbacks. Entry still
takes 18871 instructions for the 16-metric document; stable preview still reaches
21751. Whole-scenario maxima are 24543/10329. These remaining gates prevent an
ownership or eligibility change.

```sh
python3 tools/audit-scheduler.py editor-preview-metric editor-preview-chart --timeout 180
python3 -m unittest discover -s tools -p test_scheduler_audit.py
```

Both exit 0; all native construction-stage rows were additionally checked against
4000. The new targeted `tests/unit/lib/test_editor_ui.lua` and existing
`tests/unit/lib/test_editor.lua` pass through `tests.run.run_test` with Lua 5.3.
The new suite checks zero/one/16 placements, existing/new preview slots, exact
geometry and visibility, hidden-until-complete publication, retained change
detection, resumed drafts, preview errors and cancellation after every unfinished
construction stage.

The full editor integration suite was also run against archived `a8cfcce` and
the current source, not skipped or weakened. Both reach the identical existing
15200-instruction drawer failure: assertion line 109, `settleDrawer` line 165,
caller line 1816, `stage=nil`. That remains an open input/drawer gate rather than
a passing suite. The 23 audit-tool tests pass.

## 25. Bounded editor entry and service-only construction callbacks (R5/R6)

Production entry now requests an incremental editor session instead of cloning
both documents synchronously. Each advance visits at most 16 graph entries or
finished-table frames; table keys, cycles and shared references are preserved.
The original is copied first and the independent draft is copied from that
completed snapshot. The synchronous `editor.new` API remains unchanged for
other callers. Cancellation releases the unfinished job and is idempotent.
Input and UI construction remain blocked until both copies complete.

Longer construction must not suspend recording. These callbacks now reserve
3000 instructions for their bounded controller work and run service tasks under
the explicit `editor-build` kind, with 2400 declared fixed host overhead and the
existing separately charged Flight/reset head. The host extends only enrolled
service declarations, through a cached host-local copy: services eligible in
steady callbacks can run here, background-only services cannot, and panel
declarations acquire no eligibility. Shared declarations and standalone scheduler
fixtures remain unchanged. Other modal/preview paths retain their existing
behavior and remain migration gates.

| Surface | Native worst instructions |
|---|---:|
| Copy body, every cursor in plain/deep/table-key/cyclic fixtures | 798 |
| Copy fixture declaration | 1000 |
| 16-metric entry controller (previously 18871) | 715 |
| Maximum-span chart entry controller | 610 |
| Largest controller construction/copy body in real cases | 1353 |
| Complete 16-metric copying callback | 3320 |
| Complete chart copying callback | 5708 |
| Complete 16-metric UI-building callback, including services | 4023 |
| Complete chart UI-building callback, including services | 5719 |

The last four rows are whole callbacks containing independently bounded service
work as well as editor work; they use the 15000 callback ceiling, not the 4000
atom ceiling. Native surface rows preserve their child spans and were checked
for absence of panel/chart work. Actual History samples are present during both
copy phases and UI construction. The new real-widget integration test also
requires History progress through a long copy and through UI construction,
unchanged History/Telemetry intervals of 10, and zero hidden-panel refreshes.

Commands:

```sh
python3 tools/audit-scheduler.py --framework editor-initialization chart-construction chart-frame chart-readings chart-traces --timeout 180
python3 tools/audit-scheduler.py editor-preview-metric editor-preview-chart --timeout 180
python3 tools/audit-scheduler.py chart-min chart-max default-gallery --timeout 180
python3 -m unittest discover -s tools -p test_scheduler_audit.py
make test-lua32
build/lua32/lua tests/unit/lib/test_editor.lua "$PWD"
build/lua32/lua tests/unit/lib/test_editor_ui.lua "$PWD"
```

All exit 0. Targeted Lua 5.3 suites additionally pass for editor initialization,
host eligibility, panel loading, shared-module code, session reset and chart
session reset. The host test explicitly admits a service but rejects a hidden
panel and a background-only service in `editor-build`, then verifies their
ordinary kinds and unchanged shared declarations. Shared-module retained growth
remains 0.1 KiB; session reset remains 14300 mock instructions and retains its
existing first-arm XFAILs. The full editor integration suite still reaches the
identical baseline 15200-instruction drawer failure at caller line 1816.

Latest ordinary native chart-min/chart-max/default-gallery maxima are
9189/9601/12411. The new host-local service declaration setup is included in these
actual callbacks. The 16-metric legacy scenario still exceeds the callback
ceiling (24751 across its editor scenario); stable preview admission, ordinary
input/drawers, other modal kinds, Flight/Smart, and the remaining panel tasks
are still gates. No production panel or Flight/Smart owner changed, and no
deferred chart-recording assertion was relaxed.

## 26. Prepared preview rebuilding and bounded chart preview construction (R5/R6)

Preview replacement now separates retirement, incremental placement cloning,
settings preparation and construction. Cloning reuses the bounded session graph
traversal rather than copying an arbitrarily large placement in one callback.
The loader's existing preparation and construction helpers are shared with the
editor. Panels without `construct` still build synchronously in their own
separate callback; chart previews now opt into the same hidden, staged creation
used by ordinary loading.

Partial previews stay outside the panel registry until completion. Construction
uses current geometry, checks boolean results, and publishes only on success.
Preview failures clear/pool their container and report through the editor, not
the committed layout's rejected/error lists. Cancellation follows the same
page-retirement path that discards partial loading state.

Bounded placement-copy and staged-construction callbacks reserve 4000 for their
work before admitting services under `editor-build`. Legacy preparation and
synchronous constructors are deliberately not given an unmeasured concurrent
service allowance. Their atoms remain gates even when the complete callback
passes. Native controller spans now include per-copy/preview/construction-stage
rows as well as the existing aggregate, so a cheap whole-callback sample cannot
hide a more expensive body in another sample.

```sh
python3 tools/audit-scheduler.py editor-rebuild-navigation editor-rebuild-metric editor-rebuild-chart --timeout 180
python3 -m unittest discover -s tools -p test_scheduler_audit.py
```

Both exit 0; there are 24 passing audit-tool tests. The native cases change an
actual setting through the editor, rebuild its preview, verify the resulting
resolved setting, then discard the draft and reload. Actions themselves remain
timed; rows marked `@load` are retained while a retired placement is absent from
the live registry.

| Preview controller body | Navigation | Metric | Chart |
|---|---:|---:|---:|
| Retire | 140 | 140 | 140 |
| Largest bounded placement-copy step | 712 | 742 | 756 |
| Prepare | 1262 | 1259 | 1887 |
| Create shell / synchronous constructor | 4295 | 3995 | 1283 |
| One series subscription | N/A | N/A | 897 |
| Controls | N/A | N/A | 580 |
| Geometry setup/application | N/A | N/A | 1138 |
| One font candidate | N/A | N/A | 1212 |
| One position / final publication | N/A | N/A | 1553 |
| Final editor render | 930 | 930 | 930 |

Every measured chart-preview body is below 4000. The independent heavier chart
construction fixture and its existing declarations remain unchanged; these
cheaper preview samples do not shrink those bounds. Complete native scenario
maxima are 9513/9347/10109 for navigation/metric/chart. The chart's former
8472-instruction synchronous preview-construction body is no longer one callback.

**The full editor integration suite now passes**, with a worst mock callback of
15000, rather than its unchanged archived 15200 navigation-preview failure.
No assertion or callback ceiling was relaxed. The real-widget editor test also
checks long preview-copy/construct recording progress, zero hidden refreshes,
hidden/unregistered partials, malformed constructor results isolated to the
editor, and cancellation before page retirement. Panel loading still passes
against the extracted shared helper.

Navigation construction remains above 4000; metric construction at 3995 has no
safe declaration margin and needs its own split. Multi-placement stable legacy
preview accounting and the other modal/lifecycle/loader gates also remain open.
No owner or ten-tick recording policy changed, and the deferred chart-recording
stress assertions were not repaired or weakened.

## 27. Bounded navigation construction and preview rebuilding (R5/R6)

Navigation now implements the shared optional construction contract. The initial
shell and subscriptions, controls (including satellite icons), tape allocation,
geometry reflow and final rendering/publication are separate callbacks. Direct
callers without `services.staged` drive the same stages synchronously. Ordinary
loading and editor previews keep partial instances hidden and unregistered.

Geometry is checked again before publication; a changed rectangle returns to
reflow rather than publishing an obsolete frame. Construction also initializes
the unit's new font after a resize even when its reading has not arrived yet.
The new per-stage resize parity cases caught that mismatch before publication.
Temporary service/style references and geometry snapshots are released on
completion, and repeated completion calls are idempotent.

| Construction body | Native fixture worst | Declared charge |
|---|---:|---:|
| Shell / cold subscriptions / fitted header | 3048 | 3410 |
| Controls / optional satellite icon | 483 | 590 |
| Complete tape object pool | 3481 | 3880 |
| Reflow / unit font initialization | 2513 | 2820 |
| Render / publication | 3172 | 3540 |
| Framework release | 242 | 420 |

`navigation-construction.lua` measures every stage with real Navigation and
Telemetry subscription implementations. Cases cover cold/warm subscriptions,
all tape/coordinate/satellite combinations, square/wide/tall/tiny geometry,
degrees/quadrant bearings, valid/stale/no-fix/critical readings, long headings
and geometry changes before publication. Native API and successful file checks
use constant-cost stand-ins; real loading tests cover constructor failures and
retirement. These are construction-fixture declarations, not a production panel
refresh declaration or an ownership change.

The existing native navigation preview scenario turns the tape off. A second
`editor-rebuild-navigation-tape` scenario starts without a tape and turns it on,
so allocation is measured rather than skipped. Actual preview controller bodies
peak at shell 2459, controls 703, tape 3559, reflow 2118 and publication 1888.
Preparation remains 1273, placement copying 712, retirement 140 and final editor
render 930. Every measured body is below the unchanged 4000 atom cap.

```sh
python3 tools/audit-scheduler.py --framework navigation-construction chart-construction --timeout 180
python3 tools/audit-scheduler.py navigation-min navigation-max editor-rebuild-navigation editor-rebuild-navigation-tape default-gallery --timeout 180
python3 -m unittest discover -s tools -p test_scheduler_audit.py
make test-lua32
```

All exit 0. Complete native callbacks peak at 9189/9189 for ordinary
navigation-min/max, 9522/9347 for tape-off/on preview reconstruction, and 12411
for default-gallery. The 24 audit-tool tests and Lua32 scheduler bounds pass.
Supported Lua 5.3 targeted suites also pass for navigation unit/review,
panel loading, editor UI/initialization, builder matrix, all panel spans and
panel reflow. The loading lifecycle suite now exercises both chart and
navigation, including hidden enrollment, resize, malformed/failed constructors,
reload cancellation and page retirement. Editor UI remains at 15000 mock
instructions without changing its ceiling.

Completed staged/synchronous visible-tree parity is checked at every pending
resize stage and after the first refresh. An additional comparison against the
actual pre-extraction `c86af63` source passed 80 initial/first-refresh cases
across both themes, five geometries and all feature combinations. Hidden pools
are intentionally excluded from pixel comparisons because the shared primitives
position them lazily when revealed.

Metric construction still lacks safe declaration margin, stable multi-panel
editor preview accounting remains open, and ordinary loading/reflow/modal
eligibility still gates Flight/Smart and panel-owner changes. All owners,
ten-tick recording policy and deferred chart-recording failures remain unchanged.

## 28. Bounded metric construction (R5/R6, refresh still legacy)

Metric now uses the same optional construction lifecycle. Validation and real
Telemetry subscriptions, fitted frame/header creation, and controls with initial
publication are separate atoms. A first split still measured 4237 instructions
for cold subscriptions plus frame creation: the final split separates those
bodies rather than raising the cap. A normal metric completes after two
`construct` calls; controls and publication share a measured stage so a full grid
still fits the existing test helper's 200-callback startup guard.

A partial metric may not yet own a panel root. Its parent and style references
are discarded after frame/control creation, and the loader keeps it hidden and
outside the live registry throughout. A changed rectangle queues reflow before
publication, with another publication step if needed. Reflow initializes the
unit font even when a value has not arrived yet, as in navigation construction.
Unchanged geometry does not pay for a redundant reflow or change the old initial
rendering behavior.

| Construction body | Native fixture worst | Declared charge |
|---|---:|---:|
| Validation / cold subscriptions | 1348 | 1540 |
| Fitted geometry / frame / header | 2946 | 3300 |
| Controls / supporting readings / ordinary publication | 1232 | 1410 |
| Pending resize reflow | 3015 | 3370 |
| Separate publication after reflow | 760 | 890 |
| Framework release | 242 | 420 |

`metric-construction.lua` measures every stage across zero/one/three readings,
all three visual modes, square/wide/tall/tiny geometry, cold/warm Telemetry
subscriptions, precisions zero through three, long labels, explicit/suppressed
units, absent Telemetry and pending resizes. Construction declarations remain
fixtures, not production refresh declarations. The 4000 atom cap is unchanged.

```sh
python3 tools/audit-scheduler.py --framework metric-construction navigation-construction chart-construction --timeout 180
python3 tools/audit-scheduler.py metric-min metric-max editor-rebuild-metric default-gallery --timeout 180
python3 -m unittest discover -s tools -p test_scheduler_audit.py
make test-lua32
```

All exit 0. Real metric-preview controller bodies peak at validation/subscriptions
1287, frame 2408, controls/publication 1081, preparation 1270, placement copy 757,
retirement 140 and final editor render 930. Complete scenario maxima are
9641/9189 for metric-min/max, 9347 for metric preview reconstruction and 12411 for
default-gallery. The former 3995-instruction synchronous preview body is gone.

The new metric construction integration suite checks synchronous/staged
visible-tree parity and first refresh across both themes, three spans, all
visuals and zero/one/three readings. It resizes at every pending stage, verifies
the final geometry/unit font and reference cleanup, and checks idempotent
completion. Navigation shares its visible-tree comparison helper. The loading
lifecycle suite now exercises metric as well as chart/navigation, including
failure/malformed results, hidden enrollment, resize, reload and page retirement.
All targeted metric/navigation, editor UI/initialization, loading, builder,
all-spans and reflow suites pass under the supported Lua 5.3 runner. Full editor
UI remains at 15000 mock instructions; neither that ceiling nor the startup
guard was relaxed. Lua32 scheduler bounds and all 24 audit-tool tests pass.
An additional comparison against actual pre-extraction `b4d92a0` passed 90
initial/first-refresh visible-tree cases across both themes and five geometries.

Metric refresh still has its oversized legacy bound and needs its own task
adapter. Other panel tasks, stable multi-panel preview accounting, measured
loader/modal/reflow eligibility and Flight/Smart admission remain open. No
production owner, ten-tick recording policy or deferred chart-recording
assertion changed.

Additional shared-module, scheduler-host, session-reset, chart-reset and chart
flight-recording suites pass. Shared retained growth remains 0.1 KiB; session
reset peaks at 14300 mock instructions and retains its two existing first-arm
XFAILs. Both deferred chart-recording stress modes were rerun without edits:
they still fail at line 192, ordinary Q7 revisions 2/93 and independent-arms Q1
revisions 0/42, matching the prior checkpoint rather than failing during loading.

## 29. Bounded metric refresh and placement enrollment (R1/R5/R6, owners unchanged)

Metric's optional task adapter freezes scalar fields from all three readings
before preparing precision, supporting text and unit metadata. It shares the
legacy preparation, geometry and paint helpers; synchronous refresh retains its
original precision-reflow then supporting-reflow ordering. Task execution
coalesces those geometry requests, then advances through separate geometry,
placement, render and apply stages. Stable frames skip painting. External reflow,
forced readings and legacy refresh invalidate pending work, including a render
cache that was prepared but not yet painted. A stale plan reports `used=0`,
republishes the current stage and resumes after one tick.

The original task layout stage measured 3684 instructions with real LVGL fonts,
despite a much smaller API-stand-in result. Raising its declaration would not
leave the required margin below 4000. Geometry resolution and LVGL placement
are now separate atoms, measured through both the fixture's real panel task
bridge and the native callback's complete task bridge:

| Refresh stage | Native fixture worst | Real native bridge worst | Declaration |
|---|---:|---:|---:|
| Prepare / freeze | 500 | 413 | 600 |
| Geometry resolution | 1821 | 3329 | 3720 |
| Geometry application | 1125 | 1016 | 1290 |
| Render | 708 | 606 | 830 |
| Apply | 882 | 729 | 1030 |

The geometry fixture's loose-bound warning is intentional: actual font fitting
determines admission, not the stand-in's smaller count. No atom exceeds 4000.
Metric construction's shared reflow now measures 3032, with a 3390 fixture
declaration; controls/publication and separate publication measure 1233/761.

An isolated native owner override exposed another real gate: enrolling sixteen
placements at once produced a 25006-instruction callback. The host now enrolls
at most one placement per callback and reserves 4000 before planning tasks.
Surviving placements retain their scheduler records and due ticks. Pending
placements are explicitly tracked rather than treated as missing tasks; service
resynchronization is not repeated merely to continue panel enrollment. A
sixteen-placement test checks one enrollment per callback, stable service task
identity and uninterrupted ten-tick service releases. Retired and failed
placements retain their existing handling.

Native metric enrollment itself peaks at 1199; complete readiness, including
cold service enrollment, peaks at 3909 in the sixteen-metric case. That
scenario's complete callback maximum falls to 10543. One small/large metric
peaks at 9189 each, and production-owner default-gallery at 12533, all below
15000. Other panel families and mass retirement still need their own complete
callback gates before ownership changes; this is not a blanket readiness bound
for every layout or modal callback.

Verification commands:

```sh
python3 tools/audit-scheduler.py --framework metric-panel metric-construction --timeout 180
python3 tools/audit-scheduler.py metric-tasks-min metric-tasks-max metric-tasks-16 default-gallery --timeout 180
python3 -m unittest discover -s tools -p test_scheduler_audit.py
make test-lua32
```

The native cases override only `panel:metric` in their isolated SD images.
Production ownership is unchanged. The metric integration suite checks both
themes, four geometries, three visual modes and eight data cycles, including
frozen readings/metadata, completed-frame legacy parity, every stale stage,
stable frames, forced values, absent feeds and restoration of subscriptions
before propagating stage errors. Host regression stand-ins explicitly remove
the real metric adapter when testing missing steps or a replacement `run` stage.
The same completed-frame suite also passes against actual pre-extraction
`f6a8207` metric source, not only the extracted legacy helpers. Targeted metric,
host, loading, reflow, full editor UI, shared-module, session-reset and chart
recording/reset suites pass under the supported Lua 5.3 runner. Editor UI
remains at 15000 mock instructions and session reset at 14300, retaining its
two existing first-arm XFAILs. Lua32 task bounds and all 26 audit-tool tests pass.

The remaining panel adapters, multi-panel editor preview accounting,
loader/modal/reflow eligibility and Flight/Smart admission remain open.
Telemetry/History keep their ten-tick policy. Deferred chart-recording stress
assertions and production owners are untouched.
