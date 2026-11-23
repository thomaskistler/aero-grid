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

Recommendations are grouped into pieces of work that should be tackled together,
ordered from easiest and least risky to hardest and most risky. Line counts are
production Lua code lines removed (comments, blank lines, and tests excluded; the
widget has 30,979). "est." marks a net estimate where code is replaced by something
smaller. Instruction savings are per flight callback. Feature removals are listed
separately below.

### Group 1: Dead code and leftovers (about 190 lines)

Risk: none to low. No behavior change.

- **Remove unused functions (127 lines).** No callers (66):
  `layoutStore.loadDefault`, `primitives.setBarMarker`, `primitives.showCompass`,
  `yaml.buildAt`. Called only from tests or tools (61): `navigation.distanceText`,
  `theme.fromRgb565`, `theme.modernDark`, `editor.restoreDefault`,
  `primitives.contentWidth`, `primitives.batteryBackdropRgb`,
  `primitives.arcAngle`, `primitives.signedFraction`,
  `navigationService.formatDistance`. Delete their tests too.
- **Remove the leftover `Armed` widget option code (~25 lines).**
  `legacyWidgetArmed` still reads `widgetOptions.Armed`, which no longer exists, in
  `main.lua`, `flight_service.lua`, and `dashboard_loader.lua`.
- **Drop per-module API versions (~30 lines).** Remove `apiVersion` from every
  panel, the `RUNTIME_API` checks in `loadModule` and `panel_host.lua`, and
  `runtimeApi`/`panelApi` from `package.lua`. The installer replaces the whole
  widget directory, so one package version check is enough.
- **Drop the model-settings backend seam (~10 lines).** `env.backend` exists for an
  EdgeTX 3.0 backend that is not implemented. Tests that inject a backend need
  another seam.

### Group 2: Release contents (377 lines)

Risk: low.

- **Move developer-only panels out of the release.** `service-probe` (191) and
  `theme-showcase` (186) move to the development fixture, as do the Palette and
  Diagnostics layouts, together with their documentation pages. Saved layouts
  that use them show the panel as unknown, and the layout registry must keep its
  positions.

### Group 3: Panel efficiency (~140 lines est., about 700 instructions)

Risk: low to medium. Each change stays inside one panel.

- **Metric panel: no relayout on a value change (up to 3,500 instructions per
  change).** Any change to a supporting line, such as MAX ALT, triggers a full
  `metric.update` relayout. Size the text areas once and only replace their text.
- **Output panel: paint all rows in one step (~140 lines est.).** It paints one
  channel row per scheduler turn (about 220 instructions, charged a
  2,000-instruction slot), so a refresh needs about 10 turns. Replace
  `output.refresh` and its phase helpers (190 lines; mount, reflow, layout, paint,
  live, idle) with a single paint, keeping the reflow and caption-width rules.
- **Lower panel refresh rates** (see [Task rates](#reference-task-rates)): output
  bars to 4–5 per second, metric supporting lines to once per second,
  `rx-battery` and `navigation` to twice per second.

### Group 4: Service rates (about 650 instructions)

Risk: low to medium. Mostly interval constants; check arm/disarm feel and alarm
latency on a radio.

- **Lower service update rates** (see [Task rates](#reference-task-rates)):
  `history` to 5 per second or only on new samples, `flight` and `flight.decide`
  to 5 per second, `control` outputs to 4–5 per second, `navigation` to twice per
  second, and `model` TX voltage to once per second.

### Group 5: Scheduler bookkeeping (900–2,400 instructions)

Risk: medium. Removes per-callback bookkeeping without changing how work is
paced.

- **Keep a persistent task list (400–470 instructions).** Change it only when the
  dashboard changes instead of re-enrolling every task each callback. Every
  dashboard change must update the list.
- **Let tasks set their own next due time (430–1,900 instructions).** Replace the
  `ready` functions evaluated on every pass; each gate's condition becomes a
  due-time update at its source.
- **Keep the tasks ordered by due time.** The scheduler runs tasks from the front
  and stops at the first one that is not due, so idle tasks cost nothing. A task
  that asks for another step stays at the front. A finished task is re-inserted
  at its next due time. A source that makes a task due early moves it forward. A
  task that does not fit keeps its due time, so it stays ahead of later work; ties
  go to the task that ran least recently. This replaces the ring cursor and
  deferred-turn tracking. With 20–40 tasks, a sorted array is enough.

### Group 6: Telemetry polling (about 400 instructions)

Risk: medium. Charts and debrief statistics depend on every sample.

- **Poll telemetry once per sample in a single step.** Poll every subscribed
  source once at its own rate: 10 Hz for charted or debrief sources, 2–5 Hz
  otherwise. Drop the two-sources-per-slot round-robin and polling rounds that
  continue across callbacks.
- **Pass the chart history each batch of samples** instead of a protected call per
  reading.

### Group 7: Chart budget and Pre-release (about 110 lines)

Risk: high. Changes how much work charts and loaders get per callback; the
extra segments currently give charts room for horizontal and vertical rescaling,
which the steady-flight measurements above do not cover. Measure rescale latency
at each step.

Groups 5 and 6 already moved chart finishing into refresh and removed the
ring rescans, so the remaining work is slot costs and Pre-release.

- **Fix what a slot costs.** A slot assumes 2,000 instructions, but real costs
  differ widely: most fixed-cost tasks use 200–450 per charged slot, while a
  telemetry step (8 sources per slot) uses 2,200–2,700. Re-measure on the current
  code and base the unit on measured costs. Keep variable-cost grants for charts
  (`refreshMinCost`, `backgroundMinCost`). Check two effects left over from
  Group 6: at takeoff the third of three rescaling charts finishes 5–32 ticks
  later, and FMS-Ranger-L2 with Pre-release on has more callbacks over 20k.
- **Remove the Pre-release extended segments (107 lines), last.**
  `native_budget.lua` (34), segment and carry-over logic in `scheduler.lua` (42),
  `liveDangerously` in `main.lua` (22), `flight_config.lua`, and the Model
  settings row (9). Every measured callback over 20k comes from these segments.
  Remove them only once charts rescale fast enough without them.

### Group 8: Arming and flight detection (~410 lines est., about 700 instructions)

Risk: high. Touches flight detection, recording, home capture, and saved layouts.

- **One arm condition (~300 lines).** The Model settings arm condition coexists
  with per-panel arm switches on `chart`, `navigation`, and `flight-counter`, and
  the flight counter keeps its own detection settings. Removed:
  `flight_registration.lua` and its hook (55), `rebindArming` in `main.lua` and
  three panels (94), the broker's per-layout proposal and conflict resolution
  (65), flight-counter legacy settings (23), chart and navigation arm settings
  (12), editor filters and migration guard (20), `flight_count.lua` legacy import
  (12), history fallback (8), and `modelArmed` plumbing into validation (15). Old
  panel settings convert once on load.
- **Drop layout fixes for formats that were never released (~30 lines).**
  Released layouts are versions 1 to 3 (v0.1.0 to v0.4.0), so steps 1 to 3 stay.
  Remove the chart duration conversion (charts were never released), the
  unreleased rx-battery `sourceType` and threshold renames, and the 4 to 5 step,
  which only exists for legacy flight counters. Developer-build layouts at
  version 4 would no longer load.
- **Share polling with flight detection (~80 lines est., about 700
  instructions).** The flight broker runs its own reset, detection, and Smart
  runtimes (83 lines), polling the same sources as the dashboard. The broker is
  shared across widgets, while dashboard services belong to one widget.

### Group 9: Host request queue (~400 lines est.)

Risk: highest. Touches every overlay, editor, and input flow.

- **One request queue in `main.lua`.** About 15 request types (options, session
  reset, menu, input, model settings, editor transition and restore, log, debrief
  build, open, and pill, location, lifecycle, UI, and the empty-layout hint) each
  have their own ready, step, and pruning rules, with `servicesHold`,
  `panelsHold`, `lifecycleHold`, and `inputFirst` on top. They total 824 lines. A
  single queue for the current overlay or transition would replace about half.

Together with the feature removals below, about 3,450 lines, or 11% of the
widget's code. Groups 1–3 alone remove about 710 lines.

## Feature removals (product decisions)

Each removes a user-visible feature, so it needs a product decision. Ordered by
how contained the removal is.

1. **VCel sensor publishing (~150 lines).** `telemetry_publisher.lua` (116) plus
    loader and rx-battery code. Depends on EdgeTX's "Discover new sensors" quirks.
2. **Location QR code (~195 lines).** `location_details.lua` (134), location tasks
    in `main.lua` (37), and navigation hooks.
3. **Host diagnostics scheduler graph, sources report, and shared log (~500
    lines).** Scheduler section (117), sources (28), log (12), `diagnostics_log.lua`
    (81), `log_viewer.lua` (209), the log-open task in `main.lua` (24), and
    references. The identity, theme, and panels reports stay. Developer tooling,
    not for pilots.
4. **Smart detection (~330 lines).** `smart_flight.lua` (286) plus broker and
    settings paths. Off by default and off on your models. Touches flight detection.
5. **Glass theme (~490 lines).** `glass.lua` and `background_cache.lua` (390), the
    loader stage (54), `theme.glassOpacity` (29), and opacity hooks across
    rendering. The Theme option keeps its choice positions.
6. **Background work on hidden dashboards (~80 lines).** `background` hooks in
    chart, link-status, rx-battery, flight-counter, and navigation, plus host
    plumbing. Flight detection already runs in the shared flight tracking. Risk:
    confirm that navigation home capture and chart recording do not depend on it.

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
