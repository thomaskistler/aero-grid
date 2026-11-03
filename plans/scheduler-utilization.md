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

### Budget

Each callback admits tasks while
`fixedOverhead + sum(worstCost of grants) <= ceiling - margin`.

- `ceiling` is 15000 for now. Margin covers at least one 200-instruction
  quantum.
- Fixed overhead (callback entry, drawing, bookkeeping) is measured and
  declared like any task.

### Selection

A work-conserving loop: keep admitting the most urgent task that fits until
nothing does.

- Priority classes, highest first: telemetry acquisition and recording, live
  input and Smart, chart completion, everything else.
- Aging by `(now - due) / interval` prevents starvation.
- Several services may run per callback.

### Invariants kept

- Telemetry acquisition, recording and shared history are never skipped.
- Staged-chart ownership, at most one chart per callback, and the telemetry
  early-yield are constraints on the loop.
- Exact extrema, gaps, Smart/reset and ordinary append/scroll are unchanged.
- Default behavior is unchanged until the scheduler is enabled.

### Runtime feedback

At callback start, compare `getUsage` with the planned total.

- Observed above planned plus one quantum means the cost table is wrong:
  reduce the budget for a window and log the task mix.
- Sustained low usage never raises grants beyond what the proven bounds allow.

An optional isolation probe runs one task alone so the next `getUsage` read is
a clean per-task check on real hardware.

### Fallback

If `getUsage` is unavailable, or under a mock, use the current static caps. Tests
inject a synthetic meter so mock counts do not affect decisions.

## Limits of the approach

- Reclaimable budget is the gap between a task's worst case and its typical
  cost. Coarse stages with a wide spread force a large reserved margin, which
  is the same waste as today. Units must be fine-grained and low-variance.
- One-callback lag in `getUsage` means a cheap callback can be followed by a
  spike. Planning uses worst-case bounds, not averages, for that reason.
- 200-instruction quantization limits how finely drift can be detected.

## Phases

0. **Audit.** For every current task, record its unit, measured worst cost per
   unit, and whether it is bounded. Chart stages are closest to ready; telemetry,
   flight and history services need the most work.
1. **Shadow mode.** Compute grants and log them without applying them.
2. **Services.** Run several per callback within budget.
3. **Chart grants.** Replace fixed allowance constants with grants.
4. **Feedback.** Enable the total-only guard and back-off.

Each phase is validated on the matched native harness: callbacks and time to
first complete paint, worst callback usage at or below 15000, and zero pixel
mismatch against the reference.

## Open questions

- Is 15000 the right ceiling, or should the target move toward 20000 with a
  larger margin once costs are proven?
- Should the scheduler live in `main.lua` or a new `lib/scheduler.lua`?
- Are isolation probes worth the lost utilization?
