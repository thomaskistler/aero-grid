# Scheduler Framework (Phase 1 Specification)

Design only, no code. This is the minimum needed to build the isolated
framework of Phase 1 in [scheduler-utilization.md](scheduler-utilization.md),
using the costs in [scheduler-audit.md](scheduler-audit.md) and the bound rule
in [scheduler-contracts.md](scheduler-contracts.md). Costs are Lua VM
instructions. Every number below marked "example" is illustrative; real values
come from the contracts.

## 0. Shape of version 1

- A separate library, `lib/scheduler.lua`, loaded only when the host mode is not
  `legacy`, so `legacy` costs nothing and behaves as today.
- Everything the plan needs for safety stays: provable per-grant bounds, an
  admission test against a ceiling, a never-dropped critical tier, one owner per
  task, and a total-only `getUsage` check.
- Everything that is tuning is out (section 7). The framework has **two tiers**,
  **one ordering rule** and **one fixed margin**.
- Scope: the steady-state tail of `refresh` and `background` (today
  `updateServices`, `dispatchDue`, `pumpFlight`). Callbacks that return before
  reaching it (loader, reflow, editor, menus, log viewer) keep doing so and are
  not framework work in version 1.

## 1. Tasks

A task is declared once as data, and instantiated as a plain table with a
`step` function. The declaration is loadable without the radio API, so the
simulator and the CI checks read the same bounds the widget uses.

```lua
declare = {
    class  = "critical" | "normal",
    group  = nil,                 -- optional: at most one task per group per callback
    first  = "run",               -- initial stage (default: the only stage)
    stages = { run = { fixed = F, perUnit = U, maxUnits = N } },
}
step(instance, grant, now) -> delay, want, nextStage
```

- **Cost of a step** with grant `g` (1 <= g <= `maxUnits`) is at most
  `fixed + g * perUnit`. A task whose work is not divisible declares
  `fixed = 0, perUnit = bound, maxUnits = 1`. `perUnit` must be positive.
- A **unit** is a count of items (sources polled, knots projected, entries),
  never time or instructions. The bound must hold whatever the backlog is, so
  an accumulating task caps its work at `maxUnits` and drains over later
  releases.
- **Stages** exist because a chart's next step varies a lot (1.3k begin, 0.83k
  per knot, 7.8k text). A task has one cost descriptor per stage and the planner
  uses the stage the task named last. Single-stage tasks need nothing more.
- `step` returns:
  - `delay`: ticks (10 ms) until the next release, an integer >= 1. Due time is
    `now + delay`, counted from the callback in which the task actually ran, so
    one release is pending per task, missed deadlines never stack, and there are
    no catch-up bursts. 1 means "next callback".
  - `want` (optional, default `maxUnits`): units the next step can use. It stops
    the plan from reserving budget the task cannot spend.
  - `nextStage` (optional, default unchanged).
- A task with nothing to do is not registered (as services with no
  subscriptions are idle today). Delay is the only way a registered task waits.
- Registration: `s:add{ id, decl, instance, due }` and `s:remove(id)`. At most
  64 tasks, so the planner's own cost is bounded.
- A step runs under `pcall`. An error, or a return that breaks the rules above,
  retires that task and reports once, exactly as `panelHost.dispatch` and
  `services.update` do today. Other tasks are unaffected.
- A migrated task never ends the callback early. Today's `pumpFlight` return
  value is replaced by the budget.

### Example: a service (telemetry, critical)

```lua
telemetry.declare = {
    class = "critical",
    stages = { poll = { fixed = 750, perUnit = 1180, maxUnits = 8 } },  -- example
}
function telemetry.step(self, grant, now)          -- grant = sources to poll
    self.cursor = self.roundRobin(self.entries, self.cursor, grant, self.poll, self, now)
    return self.interval, self.pollCap             -- Smart sets pollCap to 4
end
```

### Example: a staged chart (normal, group `chart`)

```lua
chart.declare = {
    class = "normal", group = "chart", first = "begin",
    stages = {
        begin   = { fixed = 0,   perUnit = 1300, maxUnits = 1 },
        project = { fixed = 200, perUnit = 830,  maxUnits = 9 },        -- grant = knots
        apply   = { fixed = 0,   perUnit = 1300, maxUnits = 1 },
    },
}
function chart.step(self, grant, now)
    self:runStage(grant)                            -- one stage, `grant` units
    if self.frameDone then
        return self.interval, 1, "begin"            -- idle until the next frame
    end
    return 1, self.remaining, self.nextStage        -- continue next callback
end
```

The chart module must expose its stage and a unit-limited call. `project`
already takes a `limit` and keeps its job between callbacks. The 7.8k text stage
must be split before it can be declared (see the contracts' Flag rows).

## 2. Planner

State: one array of task records sorted by `(due, seq)`, where `seq` is the
registration order. Insertion is a binary search. Only tasks that ran are
re-inserted, and the shifting is done by `table.insert` and `table.remove`.
Only the due prefix of the array is read each callback.

Capacity of a callback: `R = ceiling - margin - overhead[kind] - legacyShare`
(section 3). Plan, in this order:

1. **Critical.** Every ready (`due <= now`) critical task is planned, in
   `(due, seq)` order, at grant `min(want, maxUnits)`. Critical work is never
   skipped. If the critical sum exceeds `R` the plan still includes it and
   counts an `overCapacity` event; the design-time test (below) makes this
   impossible for a valid configuration.
2. **Normal.** Ready normal tasks in `(due, seq)` order, i.e. oldest release
   first. For each: skip it if its group is already planned. Otherwise grant
   `g = min(want, maxUnits, floor((R - fixed) / perUnit))`. If `g >= 1`, plan it
   at `g` and subtract `fixed + g * perUnit`. If not, skip it and try the next
   (work-conserving; leftover budget never carries over).
3. **Stop** after `K = 12` normal tasks have been examined or when `R` is below
   the smallest `fixed + perUnit` of any registered stage. This keeps the
   planner's own cost bounded however many tasks are ready.
4. **Run** the plan: critical first, then normal in plan order. After each step
   set `due = now + delay`, `want`, and the stage.

Rules in version 1, and why each stays:

| Rule | Why it is needed |
|---|---|
| Two tiers, critical first | Telemetry, history and control must never be dropped (the plan's hard invariant). Everything else can wait. |
| Oldest release first for normal | One rule gives fairness and bounded waiting: the oldest ready task is always examined first, so it is never starved. This replaces aging, deadlines, tolerances and the plan's guarded due-first. |
| Skip and continue | Uses leftover budget; a task that does not fit never blocks smaller ones. |
| Grant by units | Lets a divisible task (project knots) fill what is left instead of reserving its worst case. This is also the "filler": no separate mechanism. |
| One task per group | The existing "at most one chart per callback". Cross-callback chart ownership (`refreshOwner`) is not kept: the budget replaces that throttle. The parity test confirms the result is unchanged. |
| Examination cap `K` | Bounds the planner's own cost. Oldest-first means the cap cannot starve a task. |

**Design-time admission test** (CI, per ownership configuration and callback
kind, using the declared values). Let `S` be the sum of each critical task's cost
at `maxUnits` (assumed all ready together):

- `overhead + margin + legacyShare + S <= ceiling`, so critical work always fits.
- Every normal stage's smallest step, `fixed + perUnit`, is at most
  `ceiling - margin - overhead - legacyShare - S`, so the oldest ready task can
  always run. This replaces the contracts' fixed 4000 lump limit with the exact
  remaining room.

The second condition fails today for Smart off with 8 recorded sources (10.0k of
telemetry leaves about nothing). That is the telemetry-rate choice in the
contracts, surfaced by the test rather than hidden by a rule.

## 3. Budget and measurement at runtime

Facts used, all from the plan: EdgeTX kills a callback that passes 20000
instructions, and the widget stays dead until reloaded, so safety is planned,
not reacted to. `getUsage` reports only the previous complete callback, in
200-instruction quanta, and cannot attribute cost between tasks.

- `ceiling` = 15000. `margin` = 400 (two quanta, fixed; never adapted).
  `overhead[kind]` for `refresh` and `background` is declared by the host as
  `base + slope * panels` and **includes the framework's own cost bound**
  (measured natively, section 4). No other callback kinds.
- **Planning never reads `getUsage`.** Grants depend only on declared bounds,
  `now` and task state, so behavior is the same under the mock, on hardware and
  when `getUsage` is missing.
- **Guard (detect and count only).** The scheduler keeps the last plan's upper
  bound `U = overhead + sum of planned costs (+ charge)`. When the next callback
  reads `usage`, a **near-miss** is `usage > floor(U / 200)`: the quantum is
  already above anything the plan allows. It cannot false-alarm. Effects:
  `stats.nearMiss += 1` and the planned stage mix of that callback is kept for
  one log line. Grants and margin do not change, because a near-miss means a
  declared bound is wrong and must be fixed in the cost table. The check is
  armed only after the native simulator confirms which callback `getUsage`
  reports when `refresh` and `background` interleave (an open item in the plan);
  until then it is off.
- `s:charge(n)` adds the declared cost the legacy side used this callback
  (section 5) so `U` covers the whole callback.
- Counters kept: `callbacks`, `maxU`, `overCapacity`, `nearMiss`, `retired`.
  Lateness is a simulator metric, not a runtime one.

The framework's own Lua cost per callback is
`base + (ready tasks examined) * c1 + (tasks run) * c2`, with examined <= 12 + the
critical count and the array at most 64 entries. The real numbers are measured
(section 4) and added to `overhead`. A cost above the budget set for it (starting
target: 0.5k at 32 tasks) is a design bug to fix before Phase 2.

## 4. Simulator and per-task measurement

A task is defined once, in its module: `declare` plus `step`. Two paths consume
that single definition and never duplicate a number.

**Offline simulator** (lupa, deterministic, no radio). Runs the real framework
with a virtual clock and a scripted callback sequence (`refresh` and `background`
kinds, `getUsage` injected). Tasks are stubs built from the real `declare`:
a stub `step` charges a virtual cost and returns scripted `delay` and `want`.
It reports, per callback: planned `U`, spent cost, tasks run and grants, and, per
task, lateness. It answers the planner questions: ordering, admission, overload,
starvation, ownership, determinism, and fault injection (cost steps, spikes and
bursts at up to `ceiling + (20000 - ceiling)`, which must stay under 20000).
The recorded native traces replay the same way: each traced `(task, units, cost)`
must satisfy `cost <= fixed + units * perUnit` for that task.

**Native per-task measurement** (macOS Companion, the existing every-instruction
counter). For each task id, a measurement case file supplies only stimulus:

```lua
cases = { { grant = 1, setup = <build the instance in the worst legal state> },
          { grant = N, setup = ... } }          -- plus the contracts' fault set
```

The harness calls the real `step(instance, grant, now)` inside one counter
window per case and records the instruction count (the audit's per-window probe
cost subtracted). Output is `{id, stage, grant, worst}` over at least 5 clock
phases or seeds. The checks compare with the declaration:

- `worst(g) <= fixed + g * perUnit` for every measured grant `g`. A declared
  `perUnit` comes from the measured slope between `g = 1` and `g = maxUnits`,
  and `fixed` from the residual; the margin factors in the contracts turn the
  measured maximum into the declared number.
- Warn above 90% of the declared bound (re-declare) or below 60% (loose).
- The framework's own `run` is measured the same way at 8, 32 and 64 tasks and
  at the largest ready count, and its worst case must fit inside
  `overhead[kind]`.
- A task without a measured bound cannot be registered in `mixed` or `new` mode.
  Measurement cases are test files, so they cost no memory on the radio.

## 5. Coexistence and migration

**Host mode**, a constant in `main.lua` (overridable by tests), default `legacy`:

- `legacy`: the new library is not loaded. Dispatch is as today.
- `mixed`: both schedulers run in each callback.
- `new`: only the new one runs. Allowed only when every steady-state task has a
  declaration.

**One owner per task.** A single table maps each task id to `legacy` or `new`.
Every dispatch site (`dispatchDue`, `updateServices`, `pumpFlight`) skips tasks
the table gives to `new`, and the new scheduler only registers tasks it owns.
Flipping a task is one line in this table, so rollback is a one-line revert.
A task missing from the table fails the load.

**Capped legacy share.** In `mixed`, the legacy side gets `legacyShare`
instructions per callback, the new scheduler gets the rest (`R` above). The
legacy side cannot be bounded by its own slot count, so in `mixed` it admits each
item by its declared bound against the share, with the same skip-and-continue
rule and its existing rotation order, instead of `REFRESH_CAP` slots. It reports
the total through `s:charge`. A legacy item whose declared bound exceeds
`legacyShare`, or that has no declared bound, fails the load: so it cannot sit
there never running. The share shrinks as tasks migrate and is a configuration
value changed in the same commit that flips a task. The design-time test runs
for each configuration of the table and share.

**Shadow mode** (`shadow = true`, development only). Legacy keeps full control.
The legacy dispatch sites report each task they ran. The framework adds up their
declared costs plus `overhead`, and:

- compares that total with `getUsage` (the declared table must be at or above
  what real hardware reported);
- logs where its planner would have differed (tasks it would have run or
  skipped).

It changes no behavior and is the first use of the mode switch. Its own cost is
measured, then included in `overhead` for later phases.

**Parity test for migrating one task** (run in `mixed`, the task owned by `legacy`
and then by `new`, same recorded input trace, same virtual clock):

1. Play the trace and drain until both runs are idle.
2. At the trace's checkpoints compare: the task's published state; **data**
   (history rings, extrema, counters, recorded samples with their timestamps)
   exactly; and **pixels** with zero mismatch on the native harness. Timing may
   differ between the runs. Data and pixels at the checkpoints may not.
3. Run the matched native harness: worst callback <= 15000, zero near-misses,
   callbacks and time to first complete paint no worse than before.
4. Review before flipping: the task does only the minimal work it needs, its
   declared bound is measured, and a one-line contract (class, unit, stages,
   bound, why it is critical or normal) is written.

## 6. Invariants and tests

| # | Invariant | Test |
|---|---|---|
| 1 | The plan never exceeds the ceiling: for a configuration that passes the admission test, `U <= ceiling - margin` for every callback. | Simulator, random task sets and ready patterns over many seeds, `U` checked on every plan. Admission test negative cases must fail. |
| 2 | A ready critical task is in every plan at `min(want, maxUnits)` grant, regardless of load. | Simulator overload, bursts, skipped normal tasks; assert presence every callback. |
| 3 | No starvation: the oldest ready normal task whose smallest step fits the room after critical work runs in that callback. | Simulator with constant overload and long-waiting large tasks; assert bounded wait. |
| 4 | One owner: every task runs only under its owner, exactly once per release, never skipped by both. | `mixed` mock run over a trace with every task traced; per-callback check of the owner; liveness check over the trace. Every owner table is also checked at load. |
| 5 | One pending release per task; no stacking or catch-up. After skipping for k callbacks, a task runs once with a grant of at most `maxUnits`. | Simulator with long skip runs. |
| 6 | At most one task per group per callback. | Simulator with several chart tasks. |
| 7 | Deterministic: the same inputs give the same plans. | Run each simulator scenario and each replayed trace twice, compare the full plan log. No clocks or randomness inside the library. |
| 8 | A step's cost is at most its declared bound. | Native measurement and trace replay (section 4). A breach fails the build. |
| 9 | A failing or malformed task retires alone. | Simulator: raise, bad `delay`, bad `want`, bad stage. |
| 10 | Under injected cost spikes the actual total stays under 20000 and the guard counts a near-miss when `U` is broken. | Simulator fault injection. |
| 11 | The framework's own cost is bounded and inside `overhead`. | Native measurement at the extremes of task and ready counts. |
| 12 | `legacy` mode is unchanged. | Existing suites run in `legacy`; the new library is not loaded. Legacy share never exceeds the share in `mixed`. |

## 7. Deliberately left out of version 1

- Classes `HIGH` and `BACKGROUND`, and any declared tolerance or deadline. Two
  tiers plus oldest-first covers every guarantee in the invariants. Lateness is
  checked in the simulator for the tasks that care.
- Aging and a minimum budget share: oldest-first already prevents starvation.
- Guarded due-first, earliest-deadline-first and strict priority.
- Margin growth, decay and any adaptive margin; a near-miss changes nothing but a
  counter.
- Isolation probes, learned bounds, and `getUsage`-driven grants.
- A separate filler: a divisible task with a large `maxUnits` is one.
- Callback kinds other than `refresh` and `background`; per-kind overheads beyond
  the declared `base + slope * panels`.
- Cross-callback group ownership, a wake-up API, task priorities within a tier and
  hardware calibration.
- Loader, reflow, editor, menus, log viewer and other modal paths, and the
  unmeasured UI tasks. They stay outside the framework.
- Retiring the legacy scheduler (Phase 5).

## 8. Decisions needed

1. **High-priority tasks (flight tick, extrema, session reset).** Recommend
   `normal` in version 1 (oldest-first gives them a bounded wait). Making them
   `critical` guarantees them but the admission test then fails for Smart off.
   Related: the telemetry rate decision in the contracts (poll each source every
   second callback, lower the cap, or accept).
2. **Mixed mode in releases.** Recommend development and test only, with release
   builds keeping `legacy` until the critical and chart tasks have migrated, then
   shipping `mixed` while the rest move. Or ship `mixed` from the start.
3. **Starting legacy share.** Recommend half of `R` at the start of Phase 2,
   shrinking as tasks move. It slows legacy panel refreshes while mixed.
4. **Inherited and still open in the contracts:** keep the 15000 ceiling, and the
   margin factors. This specification uses `margin = 400` unchanged.
