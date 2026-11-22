# Flight efficiency and simplification

Goal: keep every callback of a regular flight well under 20,000 Lua instructions,
and simplify the runtime so its concepts are fewer, orthogonal, and free of
special cases.

## Measurements

Exact Lua instruction counts from the native EdgeTX 2.12 TX16S simulator with a
per-instruction hook. Model: FMS Ranger with its saved AeroGrid model settings.
Each run flies a scripted 60-second armed flight with synthetic telemetry; the
synthetic input code is excluded from the counts. The widget callback runs
about 19 times per second.

| Layout | Pre-release | Mean | p90 | Max | Callbacks over 20k |
| --- | --- | --- | --- | --- | --- |
| FMS-Ranger-L1 (7 panels) | off | 6,562 | 8,827 | 10,291 | 0 |
| FMS-Ranger-L1 | on | 11,360 | 21,470 | 30,624 | 125 of 1,122 |
| FMS-Ranger-L2 (4 charts) | off | 8,327 | 9,763 | 12,754 | 0 |
| FMS-Ranger-L2 | on | 11,647 | 19,153 | 29,428 | 76 of 1,123 |

With Pre-release on, about 60% of flight callbacks run extra segments. On a
radio, each of those first runs a busy loop until EdgeTX's 20,000-instruction
limit fires, so those callbacks always exceed 20k.

### Where a FMS-Ranger-L1 flight callback goes (Pre-release off)

| Part | Instructions |
| --- | --- |
| Task steps (actual work) | 3,083 |
| Scheduler loop: passes over all tasks, bookkeeping, grants, `pcall` | 1,754 |
| `ready` gates | 433 |
| Re-enrolling every task | 469 |
| Host routing, request pruning, and holds in `runCallback` | about 820 |
| **Total** | **6,562** |

A callback with only about 650 instructions of due work still costs about 3,300.
On FMS-Ranger-L2, `ready` gates alone cost 1,443 per callback.

### What Pre-release buys

Only two rates change: telemetry polls go from 11.8 to 25.8 per second (faster
than the 10 Hz link), and output-panel row turns go from 16 to 56 per second.
Every other task, including charts, runs at the same rate.

## Recommendations

### Flight efficiency

1. **Remove the Pre-release extended segments.** They burn CPU up to the firmware
   limit and add no visible benefit. This also removes `native_budget.lua`, the
   segment and carry-over logic in `scheduler.lua`, and the `liveDangerously` setting.
2. **Fix what a slot costs.** A slot assumes 2,000 instructions. Measured costs per
   charged slot are 200–450 for most fixed-cost tasks, 480–740 for chart steps,
   and about 1,100 for telemetry. The scheduler believes it is out of budget after
   about 4–5k real instructions, which leaves work pending. Keep variable-cost
   grants for charts, but base the unit on measured costs.
3. **Run each task at most once per callback.** A task that asks for another turn
   makes the scheduler pass over every task again. That loop costs 1.6k (off) to
   4.7k (on) per callback. Multi-step work, including chart rescaling, can
   continue on the next callback; at about 19 callbacks per second, charts that
   refresh 4 times per second do not need extra turns in the same callback.
4. **Keep a persistent task list.** Change it only when the dashboard changes,
   instead of re-enrolling every task each callback (400–470 per callback).
5. **Let tasks set their own next due time** instead of evaluating `ready`
   functions on every pass (430–1,900 per callback).
6. **Poll telemetry once per sample in a single step.** Poll every subscribed
   source once at its rate. Drop the two-sources-per-slot round-robin and the
   polling rounds that continue across callbacks. Pass the chart history each
   batch of samples instead of making a protected call per reading.
7. **Share polling with flight detection.** The flight broker runs its own
   Telemetry and Control services next to the dashboard's, so the same sources
   are polled twice. Together with its decision step, this costs about 700
   instructions per callback.
8. **Output panel: paint all rows in one step.** It currently paints one channel
   row per scheduler turn (about 220 instructions, charged a 2,000-instruction
   slot), so one refresh needs about 10 turns. This also removes its six-state
   machine (mount, reflow, layout, paint, live, idle).
9. **Metric panel: no relayout on a value change.** Any change to a supporting
   line, such as MAX ALT, triggers a full `metric.update` relayout costing up to
   3,500 instructions. Size the text areas once and only replace their text.

### Task frequencies

Telemetry arrives at most 10 times per second, and a display needs at most 4–5
updates per second. Rates below are measured on FMS-Ranger-L1 with Pre-release off.

| Task | Now | Instructions per second | Suggested | Reason |
| --- | --- | --- | --- | --- |
| `history` | 14.7/s (5-tick interval) | 4.4k | 5/s, or only on new samples | Runs twice as often as telemetry is polled. |
| `flight` | 16.4/s (every callback) | 4.0k | 5/s | Arm and disarm windows last seconds. |
| `flight.decide` | 15.8/s (every callback) | 3.9k | 5/s, after its polls | Same. |
| `flight.telemetry`, `flight.control` | about 9/s | 4.0k | 2–5/s, or reuse dashboard polls | Detection only. |
| `control` outputs and `output` panel | 12.4/s and 16.4 turns/s | 8.4k | 4–5/s, all rows in one step | Bars do not need 10 Hz. |
| `telemetry` | 11.8/s | 14.8k | 10 Hz for charted or debrief sources, 2–5 Hz otherwise | Most sources only feed 5 Hz or slower panels. |
| `metric` | 4.5/s, about 2,000 each | 9.2k | Main value 5/s, supporting lines 1/s | Maximums change slowly. |
| `rx-battery` | 4.3/s, about 940 each | 4.1k | 2/s | Pack voltage changes slowly. |
| `navigation` service and panel | 4.4/s and 3.6/s | 2.6k | 2/s | GPS updates at 1–5 Hz. |
| `model` | 4.2/s | 1.2k | Flight mode 5/s, TX voltage 1/s | |

Charts only need to refresh when a new pixel column is due: duration divided by
plot width, capped at 4 per second. A 1-minute chart at full width already needs
about 4 per second; longer durations need fewer. On FMS-Ranger-L2, chart work
held telemetry to 7.6 polls per second, below the 10 Hz link rate.

Together these rates cut task work from about 54k to about 25k instructions per
second, roughly 1,500 per callback. Fewer due tasks also reduce scheduler and
`ready` overhead.

Simplification: derive each task's rate from its data source (10 Hz telemetry,
GPS, switches) and its consumers. Hand-picked intervals of 5, 10, 20, 25, 50, and 100
ticks are currently spread across services and panels. Services can also update
only when their inputs have changed rather than on a fixed timer.

### Fewer concepts and less special-casing

1. **One request queue in `main.lua`.** About 15 request types each have their own
   ready, step, and pruning rules: options, session reset, menu, input, model
   settings, editor transition and restore, log, debrief build, open, and pill,
   location, lifecycle, UI, and the empty-layout hint. `servicesHold`,
   `panelsHold`, `lifecycleHold`, and `inputFirst` sit on top of them. A single
   queue for the current overlay or transition would replace them.
2. **Remove chart-only panel hooks.** `finish`, `finishPending`, `finishMinCost`,
   `backgroundMinCost`, and `refreshMinCost` are used only by `chart.lua`. The
   chart can run its phases inside one variable-cost refresh, leaving every
   panel with `create`, `refresh`, `background`, `update`, and `destroy`.
