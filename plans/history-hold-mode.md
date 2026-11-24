# History hold mode: exact readings, stepped debrief charts

## Problem

The debrief shows readings that were never reported. Satellite counts, which are
whole numbers, show `MIN 9.50` and sloped chart lines.

Cause: `history_service.lua` `record()` compresses readings into straight line
segments that may deviate from each reading by up to half the sensor's last
digit (0.5 for whole numbers). It can commit a synthesized endpoint such as
9.5025. `debrief_service.lua` `work()` then samples those lines at every pixel
column, and `accumulate()` takes min/max from the interpolated knots.

The live chart is unaffected: it observes raw readings via `observeSamples`.

## Decision

Telemetry is discrete: a reading holds until the next one. History therefore
stores **only the changes** and every reader treats a value as holding until the
next entry. No interpolation anywhere. This applies to every sensor, not only
precision 0.

Measured on the four logs in `~/Desktop/sd/LOGS` (script `/tmp/hexp/exp.lua`,
all 27 sensors): 38,908 entries with hold against 62,371 with line compression.
A few sensors are slightly larger (RSNR 508 vs 498, TQly 1,187 vs 1,123).

## Scope

In scope: `history_service.lua`, `debrief_service.lua`, `debrief_view.lua`,
removing the chart's smoothing setting (`panels/chart.lua`), tests, docs.

Not in scope: the live chart column path (`chart_columns.lua`,
`chart_columns_renderer.lua`). Only `debrief_service.lua` reads knots through
`history:point`; the chart consumes `observeSamples` and does not change.

## Entry format

Unchanged: `(time, value, broken flag, integer flag)`, 8 bytes per entry. An
entry at time `t` means "this value from `t` until the next entry". The existing
"pending end" mechanism (`entry.lastAt` / `entry.endpoint`, returned by `point()`
for index `last + 1`) carries over: it is the time the held value was last seen
and is published as a final entry without being written until sealed.

## Changes

### 1. `history_service.lua`: record changes only

- `record()` replaces the line-fitting block (`low`/`high` slope window, the
  two-attempt loop) with:
  - broken sample (gap, segment change, time went backwards): `seal()` then
    `write(... broken ...)` as today.
  - same value as `entry.anchor`: only `entry.lastAt = at`.
  - different value: `seal()` (writes the held value's end at `lastAt` if it is
    later than the anchor) then `write` the new value.
- `seal()` writes `entry.anchor` at `lastAt`, not a synthesized endpoint. Remove
  `endpoint`, `low`, `high`, `epsilon`, `ROUNDING` and the `EPSILON` table.
- Equality is exact. Telemetry values are exact decimals, so no tolerance is
  needed.
- `precision` stays in `subscribe` options and in `recordingKey` only if still
  used elsewhere (the debrief passes it for display); otherwise drop it from the
  key so recordings are shared. Verify with a search before removing.
- `state.epsilon` goes away; check consumers first.
- Keep `CAPACITY`, the integer flag (so int32 stays exact), rolling-mode
  expiry and the "keep the knot before the window" rule. They work unchanged
  with hold semantics.

### 2. Remove line smoothing

Smoothing is the only thing that makes recorded values continuous, and it
would fill the history with one entry per sample. It is removed everywhere, so
every recording is raw telemetry and hold mode needs no exception.

- `history_service.lua`: delete `TAU`, `entry.tau`, the exponential filter in
  `sample()`, `entry.filtered`/`sampledAt` (observers and `record()` receive the
  raw `value`), the `smoothing` option, its validation, and its part of
  `recordingKey`. Both `subscribe` and the preview facade's `subscribe` call
  `recordingOptions`, so update both.
- `panels/chart.lua`: delete the **Line smoothing** setting (line 76) and
  `smoothing = ...` in `subscribeHistory` (line 2586).
- Charts are unreleased, so no compatibility handling. Remove `smoothing` from
  `tests/fixtures/layouts/development/review-chart.yaml`.
- Docs: remove the `smoothing` row in `docs/reference-guide/yaml.md` (line 127)
  and the example at line 164, the **Line smoothing** row in
  `docs/panels/chart.md` (line 24) and its paragraph (line 85).
- Tests that reference smoothing (remove or rewrite): `test_history_service.lua`
  (6), `test_history_flight.lua`, `test_chart.lua`, `test_editor.lua`,
  `test_editor_ui.lua`, `test_chart_recording.lua`,
  `test_dashboard_validation.lua` (the "only a smoothed chart needs its own
  track" case becomes: all charts share one recording), and
  `tests/support/chart_recorder.lua`.
- Chart and debrief recordings with the same window, mode and precision now
  share one history entry, which lowers memory use.

### 3. `debrief_service.lua`: read steps

- `work()`: drop `interpolate()`, `series.target`, `series.targetValue` and the
  per-column loop. For each knot read in order:
  - Flight start: the first knot at or before `job.start` supplies the value
    held at the flight start (clip with that knot's value, not a line).
  - Each knot inside the flight: `sample(job, series, at, value, connected)`.
    The store already draws a step: the data column carries `from` = previous
    value (vertical span) and `put()` adds `hold` columns for skipped columns.
  - Flight end: one `sample` at `job.finish` with the value held there.
  - Broken knots: unchanged (`connected = false`, `store:breakAt`).
- Remove `series.column` and the `store:bucketOf(series.lastAt, 0) + 1`
  bookkeeping. Check `columns:sample` still receives non-decreasing times.
- `accumulate()`:
  - `min`/`max` take real values only: the held value at flight start, every
    in-flight knot, and nothing synthesized.
  - `avg` becomes duration-weighted by hold: the previous value counts for the
    span until the next knot (replace `knotMean * 0.5 + value * 0.5`).
  - `delta`/last statistic: unchanged (still the last value minus the first).
- Level thresholds (`job.level`) still evaluate each emitted value.
- Binary search for the start knot (`series.high`) stays: it still finds the
  last knot at or before `job.start`.
- Capture cost: fewer knots and no per-column interpolation. Re-check
  `UNITS_PER_SLOT` accounting and the scheduler tests that assert unit counts.

### 4. `debrief_view.lua`: display

- `valueText` currently shows 2 decimals for values below 10 when precision is
  automatic. Format by the series' declared or sensor precision so `MIN 9`
  shows `9`, not `9.00`. Check the legend and axis labels use the same path.

### 5. Tests (ASCII only, int32-safe, run `make test-lua32`)

`tests/unit/lib/test_history_service.lua`:
- Constant value for a long time writes one entry plus the pending end.
- A change writes the end of the old value and the new value.
- Integer readings stay integers; no entry is ever fractional.
- Broken/resumed knots, rolling expiry (knot before the window kept), ring full.
- Remove or rewrite the tests that assert line-fit endpoints and epsilon.

`tests/unit/lib/test_debrief_service.lua`:
- Regression: readings 11, 10, 10, 10 (ticks 0, 100, 299, 310) give MIN 10 and
  columns that are steps (11 then 10), never 9.5.
- Min/max/avg on a hold series; avg weighted by duration.
- Flight starting and ending in the middle of a hold; flight with a break.
- Existing precision-2 series still pass (values unchanged).

`tests/unit/` view test: `valueText` precision for whole-number sensors.

Run: `make test`, `make test-lua32`, `make lint`, and `make format` (CI runs
`stylua --check src/WIDGETS tests`).

### 6. Verification with real data

- Re-run `/tmp/hexp/exp.lua`, adapted to call the real `history_service`, over
  the four logs. Check per flight: peak entries per sensor stays well below
  `CAPACITY` (6,144); today the worst, TRSS, needs about 3,140.
- Replay one log through the native TX16S simulator tooling (`make` targets
  under `tools/`) and compare the Satellites debrief against the log: min must
  equal the smallest logged value, lines must be steps.

### 7. Docs

One sentence in `docs/user-guide/customize-debrief.md`: debrief charts show
each reading until the next one, so counts like satellites appear as steps. No
mention of history internals.

## Order

1. Remove smoothing (history, chart setting, docs, tests).
2. `history_service.lua` hold recording plus its tests.
3. `debrief_service.lua` step capture and statistics plus its tests.
4. `debrief_view.lua` display plus tests.
5. Real-data verification, docs, format/lint.

Each step leaves the suite green, so they can be separate commits.

## Risks

- Sensors that change almost every sample (noisy RSSI) approach one entry per
  sample. Mitigated by the capacity check in step 6.
- `avg` results change slightly for existing precision-2 series (hold weighting
  instead of trapezoids). Expected and more faithful to the telemetry.
