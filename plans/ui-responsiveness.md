# UI responsiveness plan

Goal: make the chart and channel-output panels show visibly fresher data without
exceeding the EdgeTX callback instruction budget (tests enforce under 15,000 of 20,000).

The metric is the **age of the data on screen** (sample time to painted), not refresh rate.

## Field observation

One dashboard with two chart panels, each plotting two stick inputs, shows about
**2 s** between moving a stick and the trace reflecting it (reported by the pilot;
approximate, not instrumented). The pilot's visual impression is that a redraw about a
second after stick movement still shows the old position, and a later redraw shows the
movement. This is a useful symptom, not evidence that sampling itself takes a second:
the screen alone cannot distinguish source-poll delay, recording delay, or a staged chart
frame displaying an older snapshot.

The chart code makes a display-side delay plausible: each series projects a limited
number of history columns per callback (`PROJECTION_CAP`), applies its trace in bounded
steps, and the staged plot stays hidden until the frame is complete. Same-type chart
panels are serialized by `refreshOwner`. But the live radio path from stick source to
recorded history has not yet been measured, so do not attribute either apparent second
to a particular stage yet.

Field setup: both charts are **growing** and each occupies a **2x2** panel, so about
half the screen width each. The 480px mocked radio gives each a 130px plot area; measure
the actual plot width on the radio. In growing mode the time-to-x mapping is fixed until
the window grows by a minute, and a stick chart quickly reaches stable full-range bounds. So almost every
column already drawn stays correct from one frame to the next, and a full re-projection
every frame is mostly redundant work. This makes incremental drawing in growing mode the
most promising fix, not an optional extra.

This is the highest-priority problem, ahead of the output panel.

## Findings from the current code

- `updateServices` runs one service per callback, so with several services due, outputs
  may refresh every ~300 ms instead of the nominal 100 ms. Unverified until measured.
- During a staged chart frame, `item.feed` is the frame-start snapshot and the legend
  updates only in the "traces" phase, so readouts lag by a full frame.
- `refreshCost = 6` makes every chart turn consume the whole refresh cap, even in cheap stages.
- The output panel compares raw floats, so tiny raw changes repaint rows whose pixels
  and percent text did not change.

## Phase 0: baseline (no behavior change)

Add a test-side harness on `tests/support/widget_fixture.lua`, modeled on the instruction
hook in `tests/integration/widget/test_chart_recording.lua`. Measure both source-change-
to-recorded-sample delay and recorded-sample-to-visible-trace delay. The test-only
baseline implements the two-chart field scenario with 50 ms simulated callbacks, but
its source values change inside the mock before each callback; it does not model or
measure physical-stick-to-radio-source latency.

- Output panel: ticks from a `getOutputValue` change to the bar and percent being set.
- Service rotation: ticks between updates of each service.
- Chart: mock-source-change-to-recorded-sample age, recorded-sample-to-visible-trace age,
  full-frame duration, and callback instruction cost.
- Peak and p95 instructions per callback.

Scenarios: output-only (32 channels), chart-only (1 and 3 series, short and long
history), **two charts with two continuously changing series each (the field
case)**, and mixed (`tests/fixtures/layouts/default-gallery.yaml`). Report callbacks per
frame and per full cycle of both charts, to confirm or refute the hypothesis above.

On the radio, a relative test needs no instrumentation: with the same stick motion, compare
lag for one chart versus two, a chart with one series versus two, a narrower versus wider
panel, and a 30 second versus 10 minute window. Lag that grows with series count or panel
width points to projection cost; lag that grows with the window alone points to the idle
interval. Add temporary timing to the diagnostics log only if that is inconclusive.

Initial simulated field-case baseline (`test_chart_responsiveness.lua`): two 2x2 charts,
two changing series each, 130 plot columns, and 50 ms callbacks. Over 60 simulated
seconds, each chart completed 52 frames. The mock source-change-to-recorded-sample
interval was 50/50/50 ms (p50/p95/max); recorded-sample-to-visible-trace was
550/700/1000 ms; source-change-to-visible-trace was 600/750/1050 ms. Full-frame time was
500/600/900 ms and the worst callback was 8,600 instructions. Source timestamps have only
50 ms granularity here. This is not a hardware measurement; it cannot represent physical
stick-to-radio-source latency or confirm the pilot's apparent two-step sequence.

Exit: a table of current numbers and targets derived from it. Proposed: output age
p95 <= 150 ms with typical services active; trace age p95 <= 500 ms in the two-chart
field case.

## Phase 1: low-risk wins (independent changes)

1. **Output quantized painting** (`panels/output.lua`): compare displayed percent text and
   pixel positions, and skip all `set` calls when unchanged.
2. **Service scheduling**, chosen from Phase 0 data (`main.lua`, `lib/services.lua`),
   cheapest first: avoid delaying a service with a live output subscription behind
   slow-moving ones; allow a second service per callback only with measured headroom;
   retune intervals. Keep failure isolation and services-before-panels ordering.

## Phase 2a: shorten chart frames (field case)

- Make projection cheaper per column, and spend measured instruction headroom per callback
  instead of a fixed 7 to 8 columns (`PROJECTION_CAP`). This is the main expected win.
- Skip empty phases (no flights, no resume or arm markers, unchanged axis) in the same
  callback instead of spending one on each.
- Cap the idle interval after a frame while the feed is changing, so it does not rise to
  1 s on long windows.
- Reconsider the `refreshOwner` rule once frames are shorter, or share snapshot and axis
  work across charts on one dashboard.
- Target: the two-chart field dashboard stays under about 500 ms from stick motion to trace.

## Phase 2c: incremental drawing in growing mode (field case)

- Keep the projected and applied columns of a series while the window, geometry, and
  vertical range are unchanged; project only columns after the last drawn one (plus the
  still-changing newest column), and append to the existing line runs.
- Fall back to a full frame when the window grows (each whole minute), the auto range
  changes, geometry changes, flight or resume boundaries are involved, or history expires.
- Must match a full redraw exactly: add a test that compares incremental and full output
  for the same history, including gaps and resumes.
- Rolling mode is excluded: the window shifts every pixel.

## Phase 2b: chart readouts independent of frame building

- Update legend value, unit, extrema, and stale color from the live feed on every due
  callback, including during frame phases.
- Legend width growth bumps `geometryVersion` and restarts a frame, so update text
  immediately but defer relayout to a frame boundary.
- Add a test asserting readout age stays bounded while a frame is in flight.

## Phase 3: chart and output fairness in the host

- Let the chart report a per-turn cost, using Phase 0 stage costs, so cheap stages leave
  room for other panels (`main.lua` `dispatchDue`, `lib/panel_host.lua`).
- Stay backward compatible with a static `refreshCost`; update the developer guide if
  the panel contract changes.
- Worst-callback instructions must stay under 15,000, and multiple charts must stay fair.

## Phase 4: live tail segment (optional prototype)

Draw one line from the last drawn point to the current value so the trace looks live
between full frames. Drop it unless it is correct with gaps and resumes, and still needed
after Phase 2c. It could also cover rolling mode, which Phase 2c excludes.

## Validation (every phase)

- `make test`, `make check`, `make lint`.
- Re-run the Phase 0 harness and compare with the baseline.
- Keep `test_output_memory.lua` and `test_resource_stability.lua` flat.
- Check on a TX16S for phases 1 to 3.

## Order

Phase 0, then 2a and 2c (the field case) and 1a/1b in parallel, then 2b, 3, and optionally 4.
Do 2a first: cheaper projection also speeds the full-frame fallback that 2c relies on.
Phase 1b needs the Phase 0 rotation data; Phases 2a and 3 need the Phase 0 stage costs.

## Risks

- Instruction-budget regressions that mocked tests miss: radio check per phase.
- Panel contract change in Phase 3: keep static `refreshCost` working.
- Legend geometry churn restarting chart frames: defer relayout in Phase 2.

## Open questions

- Is any target hardware needed beyond the TX16S?
- Is extending the panel refresh contract (dynamic cost) acceptable?
- Should timing instrumentation ship in `host-diagnostics` or stay test-only?
