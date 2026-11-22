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

## Recommendations, easiest first

Ordered from easiest and least risky to hardest and most risky. Line counts are
production Lua code lines removed (comments, blank lines, and tests excluded; the
widget has 30,979). "est." marks a net estimate where code is replaced by something
smaller. Instruction savings are per flight callback.

### 1. Cleanups with no behavior change

1. **Remove unused functions (127 lines).** No callers (66):
   `layoutStore.loadDefault`, `primitives.setBarMarker`, `primitives.showCompass`,
   `yaml.buildAt`. Called only from tests or tools (61): `navigation.distanceText`,
   `theme.fromRgb565`, `theme.modernDark`, `editor.restoreDefault`,
   `primitives.contentWidth`, `primitives.batteryBackdropRgb`,
   `primitives.arcAngle`, `primitives.signedFraction`,
   `navigationService.formatDistance`. Risk: none; delete their tests too.
2. **Remove the leftover `Armed` widget option code (~25 lines).** `legacyWidgetArmed`
   still reads `widgetOptions.Armed`, which no longer exists, in `main.lua`,
   `flight_service.lua`, and `dashboard_loader.lua`. Risk: none; the option can no
   longer be set.
3. **Drop per-module API versions (~30 lines).** Remove `apiVersion` from every
   panel, the `RUNTIME_API` checks in `loadModule` and `panel_host.lua`, and
   `runtimeApi`/`panelApi` from `package.lua`. The installer replaces the whole
   widget directory, so one package version check is enough. Risk: low; mechanical.
4. **Drop the model-settings backend seam (~10 lines).** `env.backend` exists for an
   EdgeTX 3.0 backend that is not implemented. Risk: low; tests that inject a
   backend need another seam.
5. **Move developer-only panels out of the release (377 lines).** `service-probe`
   (191) and `theme-showcase` (186) move to the development fixture, as do the
   Palette and Diagnostics layouts. Risk: low; saved layouts that use them show the
   panel as unknown, and the layout registry must keep its positions.

### 2. Contained behavior changes

6. **Lower task frequencies** for `history`, `flight`, `flight.decide`, `control`
   outputs, `rx-battery`, `navigation`, and `model` (see
   [Task rates](#reference-task-rates)). Mostly interval constants. Together with
   item 18, saves about 1,500 instructions. Risk: low; check arm/disarm feel and
   alarm latency on a radio.
7. **Metric panel: no relayout on a value change (up to 3,500 instructions per
   change).** Any change to a supporting line, such as MAX ALT, triggers a full
   `metric.update` relayout. Size the text areas once and only replace their
   text. Risk: low; one panel.
8. **Output panel: paint all rows in one step (~140 lines est.).** It paints one
   channel row per scheduler turn (about 220 instructions, charged a
   2,000-instruction slot), so a refresh needs about 10 turns. Replace `output.refresh`
   and its phase helpers (190 lines; mount, reflow, layout, paint, live, idle)
   with a single paint. Risk: low to medium; one panel, but reflow and caption
   width rules must be kept.
9. **Drop layout fixes for formats that were never released (~30 lines).**
    Released layouts are versions 1 to 3 (v0.1.0 to v0.4.0), so steps 1 to 3 stay.
    Remove the chart duration conversion (charts were never released), the
    unreleased rx-battery `sourceType` and threshold renames, and the 4 to 5 step,
    which only exists for legacy flight counters. Risk: medium for developer-build
    users, whose version 4 layouts would no longer load.

### 3. Feature removals (product decisions)

Each is user-visible. Ordered by how contained the removal is.

10. **VCel sensor publishing (~150 lines).** `telemetry_publisher.lua` (116) plus
    loader and rx-battery code. Depends on EdgeTX's "Discover new sensors" quirks.
11. **Location QR code (~195 lines).** `location_details.lua` (134), location tasks
    in `main.lua` (37), and navigation hooks.
12. **Host diagnostics scheduler graph, sources report, and shared log (~500
    lines).** Scheduler section (117), sources (28), log (12), `diagnostics_log.lua`
    (81), `log_viewer.lua` (209), the log-open task in `main.lua` (24), and
    references. The identity, theme, and panels reports stay. Developer tooling,
    not for pilots.
13. **Smart detection (~330 lines).** `smart_flight.lua` (286) plus broker and
    settings paths. Off by default and off on your models. Touches flight detection.
14. **Glass theme (~490 lines).** `glass.lua` and `background_cache.lua` (390), the
    loader stage (54), `theme.glassOpacity` (29), and opacity hooks across
    rendering. The Theme option keeps its choice positions.
15. **Background work on hidden dashboards (~80 lines).** `background` hooks in
    chart, link-status, rx-battery, flight-counter, and navigation, plus host
    plumbing. Flight detection already runs in the shared flight tracking. Risk:
    confirm that navigation home capture and chart recording do not depend on it.

### 4. Scheduler and service structure

16. **Keep a persistent task list (400–470 instructions).** Change it only when the
    dashboard changes instead of re-enrolling every task each callback. Risk:
    medium; every dashboard change must update the list.
17. **Let tasks set their own next due time (430–1,900 instructions).** Replace the
    `ready` functions evaluated on every pass. Risk: medium; each gate's condition
    becomes a due-time update at its source.
18. **Poll telemetry once per sample in a single step.** Poll every subscribed
    source once at its own rate: 10 Hz for charted or debrief sources, 2–5 Hz
    otherwise. Drop the two-sources-per-slot round-robin and polling rounds that
    continue across callbacks; pass the chart history each batch of samples
    instead of a protected call per reading. Risk: medium; charts and debrief
    statistics depend on every sample.
19. **Fix what a slot costs.** A slot assumes 2,000 instructions; measured costs per
    charged slot are 200–450 for most fixed-cost tasks, 480–740 for chart steps,
    and about 1,100 for telemetry. The scheduler believes it is out of budget after
    about 4–5k real instructions. Keep variable-cost grants for charts, but base
    the unit on measured costs. Risk: medium to high; changes every grant, so
    re-measure every layout.
20. **Remove the Pre-release extended segments (107 lines).** `native_budget.lua`
    (34), segment and carry-over logic in `scheduler.lua` (42), `liveDangerously`
    in `main.lua` (22), `flight_config.lua`, and the Model settings row (9). Removes
    every callback over 20k in the measured flights. Depends on the slot-cost fix:
    the extra segments give charts room for horizontal and vertical rescaling,
    which the steady-flight measurements above do not cover. Measure rescale
    latency with the corrected slot cost and no extra segments before removing
    them. Risk: high; rescaling may become much slower.
21. **Run each task at most once per callback (1,600–4,700 instructions).** A task
    that asks for another turn makes the scheduler pass over every task again.
    Multi-step work, including chart rescaling, continues on the next callback;
    at about 19 callbacks per second, charts that refresh 4 times per second do
    not need extra turns. Risk: high; changes chart and loader pacing.
22. **Move chart-only panel hooks into the chart (~70 lines est.).** `finish`,
    `finishPending`, `finishMinCost`, `backgroundMinCost`, and `refreshMinCost`
    exist only for `chart.lua` (88 lines of host plumbing). The chart runs its
    phases inside one variable-cost refresh, leaving every panel with `create`,
    `refresh`, `background`, `update`, and `destroy`. Risk: high; the chart is the
    most complex panel.

### 5. Cross-cutting redesigns

23. **One arm condition (~300 lines).** The Model settings arm condition coexists
    with per-panel arm switches on `chart`, `navigation`, and `flight-counter`,
    and the flight counter keeps its own detection settings. Removed:
    `flight_registration.lua` and its hook (55), `rebindArming` in `main.lua` and
    three panels (94), the broker's per-layout proposal and conflict resolution
    (65), flight-counter legacy settings (23), chart and navigation arm settings
    (12), editor filters and migration guard (20), `flight_count.lua` legacy import
    (12), history fallback (8), and `modelArmed` plumbing into validation (15).
    Risk: high; old panel settings must convert once on load, and it touches
    flight detection, recording, and home capture.
24. **Share polling with flight detection (~80 lines est., about 700
    instructions).** The flight broker runs its own reset, detection, and Smart
    runtimes (83 lines), polling the same sources as the dashboard. Risk: high;
    the broker is shared across widgets, while dashboard services belong to one
    widget.
25. **One request queue in `main.lua` (~400 lines est.).** About 15 request types
    (options, session reset, menu, input, model settings, editor transition and
    restore, log, debrief build, open, and pill, location, lifecycle, UI, and the
    empty-layout hint) each have their own ready, step, and pruning rules, with
    `servicesHold`, `panelsHold`, `lifecycleHold`, and `inputFirst` on top. They
    total 824 lines. A single queue for the current overlay or transition would
    replace about half. Risk: highest; touches every overlay, editor, and input
    flow.

Altogether about 3,450 lines, or 11% of the widget's code. Items 1–9 alone remove
about 740 lines. Every callback over 20k comes from the Pre-release extended segments
(item 20), which can only go once charts rescale fast enough without them.

## Reference: task rates

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
