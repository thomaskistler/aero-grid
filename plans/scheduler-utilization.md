# Scheduler Utilization Plan

Status: proposal for review. No scheduler code changes are included.

## Problem

The host scheduler (`dispatchDue` and `updateServices` in `main.lua`) leaves most
of the Lua instruction budget unused.

- Services: at most one service updates per callback, regardless of headroom.
- Panels: a fixed `REFRESH_CAP = 6` slots per callback, with each panel's static
  `refreshCost` as a guess. Slots have no fixed relation to instructions.
- Evidence from the chart-mipmap work (native EdgeTX Companion 2.12, TX16S, two
  chart panels, 24 sources): a 35-callback trace averaged about 5.4k
  instructions per callback. That is about 27% of the 20000 firmware limit and
  36% of the 15000 regression ceiling. Callbacks ended because a slot count ran
  out, not because instructions did.

This is unused capacity in that workload. It is not proof that more work is
safe in general. A longer smoke run at higher chart allowances reached 15800.

## Hard constraint

EdgeTX stops a widget callback that passes 20000 VM instructions: the hook
raises `CPU limit` on every later line until the call returns. `refresh` then
sets the widget's error message, and from that point `refresh` only draws the
error while `background` and `update` are skipped, so recording stops. The
widget stays dead until reloaded. An overrun is therefore never recoverable, so
safety must come from planning, not from reacting.

## What can be measured

`getUsage` reports the previous complete callback only, in 200-instruction
quanta, so the upper bound is `(usage + 1) * 200`. It cannot attribute cost
between tasks that ran in the same callback, and Lua cannot read its own count
mid-callback. `getTime()` is too coarse and ignores C++ time.

Consequences:

1. Per-task costs come from offline measurement in the native simulator, not
   from the mock (the mock charges Lua stand-ins for C++ setters).
2. `getUsage` is a total-only guard, not a per-task meter.
3. Every task must have a provable upper bound per grant.

## Design

### Tasks and grants

Services, panel refreshes and chart stages become tasks:

```
task.step(units) -> unitsDone, finished, nextDue
```

- A grant is a number of work **units** (series polled, grid slots, columns),
  never instructions or time.
- Each task declares `worstCostPerUnit`, measured with the every-instruction
  count hook at the largest legal inputs and enforced in CI.
- Units granted = `floor(budget / worstCostPerUnit)`, so a task cannot exceed
  its grant.
- No data-dependent unbounded work. Anything open-ended (string formatting,
  extrema scans, parsing) needs a hard per-call cap or becomes a staged task.

### Task contract

Each task declares static data and returns its next release after each run.

| Field | Meaning |
|---|---|
| Class | `CRITICAL`, `HIGH`, `NORMAL` or `BACKGROUND`: who is cut first under overload |
| Tolerance | Callbacks a release may wait before it is late (starting point: 0, 1, 4, 20) |
| Unit and `worstCostPerUnit` | As above; a task with no divisible work has one unit |
| Next release | Returned by `step`, counted from the callback in which the task actually ran |

- Deadline = release + tolerance. One pending release per task, so waiting
  never stacks up work and there are no catch-up bursts.
- A task with leftover work returns a delay of 1 to run again next callback.
- Classes: `CRITICAL` is telemetry acquisition, recording and shared history.
  `HIGH` is live input and Smart. `NORMAL` is chart completion and panel
  refresh. `BACKGROUND` is diagnostics and decoration.

### Budget

Each callback has a capacity
`C = ceiling - fixedOverhead - margin`, and tasks are admitted against it at
their worst-case cost.

- `ceiling` is 15000 for now. The margin is at least one 200-instruction
  quantum, and is raised by a near-miss (see Runtime feedback).
- Callback kinds (draw, telemetry, grid, metadata) differ in fixed overhead,
  so overhead is declared per kind and measured natively, not as one constant.
  The scheduler's own cost is part of the fixed overhead and must be bounded.
- **Margin cap.** The margin may shed everything except due `CRITICAL` work, so
  a near-miss can never lock out recording.
- **Design-time admission test.** Overhead plus margin floor plus the sum of
  the worst-case costs of every `CRITICAL` task that can fall due together
  must fit under the ceiling. This is checked in CI.
- Admission compares with a small tolerance so rounding cannot drop the last
  critical task.

### Selection: guarded due-first

A work-conserving loop: admit tasks in order while their worst-case cost fits
the remaining capacity, and skip any that do not fit. Unused budget does not
carry over, so skipping never delays a task; it only lets smaller ones use the
leftover.

```
urgent = sum of cost of ready CRITICAL and HIGH tasks
if urgent <= C:   due tasks by (class, deadline), then not-yet-due by (class, deadline)
else:             CRITICAL, then HIGH, by deadline;
                  then due NORMAL/BACKGROUND, then not-yet-due, by (class, deadline)
```

Guaranteed classes lend their slack only when all their ready work fits in one
callback anyway. The simpler orders each have a failure mode under overload:
earliest deadline first lets late low-priority work, which has the earliest
deadlines, push out critical work; strict priority runs high-priority work as
soon as it is released and starves background work; and due-first without the
guard defers high-priority work until it piles up past its deadline.

Several services may run per callback. A leftover-budget **filler** (chart
columns, grid slots) is planned last and sized in units to the remaining
capacity.

### Accumulating work

A task whose cost grows with how long it waited (queues, logs, history
compaction) must:

1. cap the work per run and declare its bound at the cap;
2. always be planned at that bound;
3. drain with a delay of 1 while backlog remains;
4. apply the cap from its first run.

### Invariants kept

- Telemetry acquisition, recording and shared history are never skipped.
- Staged-chart ownership, at most one chart per callback, and the telemetry
  early-yield are constraints on the loop.
- Exact extrema, gaps, Smart/reset and ordinary append/scroll are unchanged.
- Default behavior is unchanged until the scheduler is enabled.

### Runtime feedback

The plan records its upper bound `U` for each callback. When `getUsage` reports
the previous callback, it is looked up against that callback's plan, because
the report lags by one.

- **Near-miss** (observed above `U`): at least one bound is wrong. Raise the
  margin to cover the excess (for example `max(M, Mmin + 2 * excess)`), subject
  to the margin cap, then decay it slowly. Log the task mix.
- Observed usage never raises grants beyond what the proven bounds allow.
- With static bounds a near-miss is a cost-table bug to fix, not a signal to
  learn from.
- Because of the 200-instruction quantum and the one-callback lag, `Mmin`
  should be at least one quantum plus slack. 1% of the ceiling is about one
  quantum here and is not enough on its own.

An optional isolation probe runs one task alone so the next `getUsage` read is
a clean per-task check on real hardware.

### Fallback

If `getUsage` is unavailable, or under a mock, use the current static caps. Tests
inject a synthetic meter so mock counts do not affect decisions.

### Learned bounds (later, optional)

An alternative is to learn each task's bound (a mean plus an allowance for
spread) from the callback totals. Not used initially:

- An overrun here kills the widget and stops recording, so a learned bound that
  misses a rare spike is not acceptable for `CRITICAL` or `HIGH` work.
- It needs about 20 attributed solo runs per task, but chart stages run 5-12
  times in a whole first paint, and tasks that always run together cannot be
  separated.
- Its learner runs in Lua and is charged to the budget.

If measured native traces later show tight static bounds still waste too much,
learned bounds could apply to `NORMAL` and `BACKGROUND` tasks only, capped at
the declared bound and validated by replaying recorded native traces.

## Limits of the approach

- Reclaimable budget is the gap between a task's worst case and its typical
  cost. Coarse stages with a wide spread force a large reserved margin, which
  is the same waste as today. Units must be fine-grained and low-variance.
- One-callback lag in `getUsage` means a cheap callback can be followed by a
  spike. Planning uses worst-case bounds, not averages, for that reason.
- 200-instruction quantization limits how finely drift can be detected.

- **Starvation.** Under severe sustained overload, background work can wait
  many callbacks. If that matters, add a minimum budget share or aging for the
  best-effort classes.
- **Bound tightness.** Utilization depends on how close each declared bound is
  to the task's true worst case. Loose bounds waste budget, so bounds must be
  measured, not guessed.
- **Callback attribution.** Confirm on the native simulator which callback
  `getUsage` reports when `refresh` and `background` callbacks interleave.

## Phases

0. **Audit.** For every current task, record its class, unit, measured worst
   cost per unit, fixed overhead per callback kind, and whether it is bounded.
   Also record whether it can be split into smaller pieces. Finer pieces let
   the scheduler pack the budget tightly and keep each worst case close to the
   typical cost, so for every task that is coarse or has a wide cost spread the
   audit notes where a split would go and what it would cost to resume. Chart
   stages are closest to ready; telemetry, flight and history services need the
   most work. Record native traces for replay. Result: [scheduler-audit.md](scheduler-audit.md).
   The margin rule and per-task contracts built on it are in
   [scheduler-contracts.md](scheduler-contracts.md).
1. **Simulator.** Build an offline scheduler simulation from the audited costs
   and replay recorded native traces through it. Fault-inject cost steps,
   spikes and overload bursts and require zero overruns.
2. **Shadow mode.** Compute plans and grants and log them without applying them.
3. **Services.** Run several per callback within budget, behind the
   `CRITICAL` admission test.
4. **Chart grants.** Replace fixed allowance constants with grants.
5. **Near-miss guard.** Enable `getUsage` verification and margin back-off.
6. **Learned bounds.** Only if the measured gap still justifies it (see above).

Each phase is validated on the matched native harness: callbacks and time to
first complete paint, worst callback usage at or below 15000, and zero pixel
mismatch against the reference.

## Open questions

- Is 15000 the right ceiling, or should the target move toward 20000 with a
  larger margin once costs are proven?
- Should the scheduler live in `main.lua` or a new `lib/scheduler.lua`?
- Are isolation probes worth the lost utilization?
- Which services are `CRITICAL` rather than `HIGH`, and are the default
  tolerances right for them?
- How does a measured maximum become a declared bound? Measured costs are
  observed worst cases under a stimulus, not proofs. The plan needs a rule for
  the margin added on top, and fault-injection runs (worst-case inputs, gaps,
  resets, largest layouts) to justify it.
