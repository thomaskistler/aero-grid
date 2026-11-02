# Chart mipmap implementation plan

## Status

The opt-in prototype updates extrema directly from incoming chart readings and
has a dedicated fixed-level scroll path. The two-series, 240-column native
fixture meets its workload limits; larger stress cases still exceed the
original turn targets. **Production integration is not yet approved.**
The production renderer remains unchanged; the history service
has an optional sample-observer hook used only by the experiment.

This checkout did not contain the parent worktree's uncommitted responsiveness
changes or one-parent visual cache. Nothing has been implicitly merged.

## Agreed behavior

- Preserve original chart recording, its 6,144-knot capacity, recording accuracy,
  HISTORY FULL behavior, and existing rolling-history retention.
- Draw disconnected minimum/maximum vertical spans. A gap is hidden and has
  equal endpoints; do not generate connected four-point paths.
- Maintain eleven levels with spans `60 * (4/3)^level` seconds, ending at
  approximately 1,065 seconds. At 600 columns of coverage, coarser levels cover
  approximately 450, 338, and geometrically fewer columns.
- Expansion selects a prepared coarser level without rebucketing: existing data
  occupies the left three-quarters. At level 10, scroll by one-quarter when full.
- Retire fine summary levels only after publication and once no consumer needs
  them. Never discard original recording to save summary memory.
- Reproject selected extrema when geometry or vertical scale changes. Native
  objects still need bounded coordinate application; selection is not rendering.

## Revised data flow

Each filtered chart reading goes to two independent consumers:

1. The existing recorder compresses and retains history for replay/detail.
2. The mipmap extends the active column's min/max in every retained level.

The history service's optional `observeSamples` hook supplies the same filtered
value, cumulative recording timestamp and break information used by recording.
It does not poll telemetry again or move chart scale policy into the service.
Missing input marks a gap, disarmed input does not advance recording, reset
resets summaries, and HISTORY FULL freezes them while live readouts continue.

Each event touches at most eleven columns per series, regardless of elapsed
time. There is no mutable recorder segment to compose, retract or spread into
summary buckets when finalized. Min/max preserves actual observed extrema,
which can differ from extrema reconstructed from the compressed line.
**Unsampled columns stay empty:** this is intentionally not interpolation.
A break inside an occupied column keeps it hidden until the next column.

Each level has a bounded ring of at most the initial plot's column count, with
absolute bucket tags to prevent stale data appearing after wraparound. Because
4:3 boundaries do not align, all retained levels consume the same reading
directly rather than approximating three coarse buckets from four fine ones.
Selection only chooses a level/origin; it does not scan recording or summaries.

The adapter remains a **single-consumer growing-chart experiment**. Shared
ownership/unsubscription, late attachment and reconstruction, previews, zoom,
rolling charts and actual layout resizing remain unwired. Production fallback
replay must define how compressed-line reconstruction differs from observed
extrema; the two are no longer asserted identical. The experiment redraws one
native pool in place, not an atomic staged replacement.

For a fixed-level quarter-scroll, retained spans receive only an x-coordinate
update: their y/height is reused, not reprojected. Updated or entering columns
receive full geometry; expired/gap columns are hidden as their slots are
recycled into the newly exposed area. Coordinates are computed from absolute
buckets to avoid accumulating rounding error. Level changes still use a full
redraw. Scroll preserves the last published vertical scale and horizontal
geometry, including after resizing.

## Acceptance gate

Include services, recording, synchronous summary updates, projection, native
application, dispatch waits, other charts and confirmed visible completion.

| Requirement | Limit |
| --- | --- |
| Every complete callback | Strictly below 15,000 counted Lua instructions |
| Incremental update, including quarter-scroll | Strictly below 500 ms |
| Rescale or resize | At most 1,000 ms |
| Single-series append | At most one chart turn |
| Multi-series append or quarter-scroll | At most two chart turns |
| Any rescale or resize | At most five chart turns |

These are the original experiment targets. The user has clarified that seven
redraw callbacks in the 800-column, three-series stress case are not a current
priority; the representative panel is two series and about 240 pixels wide.
Keep the strict 15k callback ceiling and report stress results separately,
rather than presenting that seven-callback redraw as the main blocker.

## Current measurements

Native runs use the existing host service/dispatch path. Times end at setter
submission, **not confirmed per-operation painting**.

| Operation | 240 columns, two series: turns / time | 800 columns, three series: turns / time |
| --- | --- | --- |
| Append | 1 / <10 ms | 1 / <10 ms |
| Horizontal expansion | 3 / 110 ms | 7 / 340 ms |
| Vertical rescale | 3 / 120 ms | 7 / 340 ms |
| Populated fixed-level quarter-scroll | 2 / 60 ms | 7 / 310 ms |
| Resize of the scrolled view | 4 / 160 ms | 10 / 480 ms |

Scroll callback instruction upper bounds are **10,000** at 240 columns and
**12,200** at 800 columns. The worst bound across all five operations is
10,000 and 13,800 respectively. Bounds use the next callback's
`getUsage()` for the preceding complete refresh, plus one 200-instruction
quantum (EdgeTX v2.12.0).

Scroll preparation now fills and publishes the maximum level before timing,
then admits the reading that crosses its next quarter-window boundary. It
does not combine a level change with scrolling. The 240-column run shifts
358 retained spans using x-only setters; the 800-column run shifts 1,797.
The preceding warm-up uses 50 ms readings; maximum-level preparation uses
roughly one reading per bucket. This is deterministic long-duration input,
not continuous live sampling during a redraw.

The old sparse, mixed level-change/scroll result of ten callbacks is not
directly comparable with this populated fixture. There is still no deferred
recorder-segment distribution: incoming readings update at most eleven
columns per series, decreasing as fine levels retire.

The instrumented dense mock attributes about **3,000 instructions per admission**
to recording plus synchronous hierarchy updates across three series. There is
no separate deferred-maintenance cost; `work=0` does not mean summary updates
are free. Mock setter bodies run in Lua, unlike native C++ setters, so mock
instruction failures are not native drawing counts.

General redraws admit up to 130 columns per series with unchanged x, 90 with
changed x, and 24 on admission. X-only scrolls use a chart-wide ceiling of 400
columns, 300 on admission, additionally bounded by the per-series batch limit.
These are measured fixture operating points, not a production scheduler.

## Remaining work before integration

Measure continuous input during redraws, heavy 24-source/Smart services,
multiple charts and actual layout resizing. The two-series 240-column native
workload passes; the 800-column stress case still exceeds the original
scroll/redraw turn targets.
Confirm painted completion, firmware heap use and MK3 display/hardware behavior.
The current native simulator is 480 pixels wide. The 240-column run uses a
supported half-width 2x2 panel (about 240 pixels wide, with a narrower inner
plot); the 800-column workload is compressed into the full-width plot.
Warm allocations and input preparation are excluded from operation timing.

Correctness coverage compares all levels with independent incoming-reading
extrema, including non-aligned boundaries, partial buckets, gaps/resumes,
smoothing, long timestamp jumps, wraparound, reset, full recording and
retirement. Recording with/without an observer must retain identical knots.
The renderer checks final native-object visibility/geometry against summaries.
Repeated quarter-scroll tests at 240 and 226 columns cover gaps, fractional
origins, ring-slot recycling and preservation of resized geometry.

## Files and reproduction

| File | Purpose |
| --- | --- |
| `src/WIDGETS/AeroGrid/lib/history_service.lua` | Optional filtered-sample/reset observer |
| `src/WIDGETS/AeroGrid/lib/chart_mipmap.lua` | Bounded incoming-reading hierarchy; not enabled by production chart |
| `tests/support/mipmap_recorder.lua` | Deterministic input through real recording |
| `tests/support/chart_mipmap_prototype.lua` | Opt-in sample-to-native adapter |
| `tests/unit/lib/test_chart_mipmap.lua` | Extrema, gaps, resets, lifetime and unchanged-recording checks |
| `tests/integration/widget/test_chart_mipmap_prototype.lua` | Dense native-object geometry checks |
| `tests/experiments/run_chart_feasibility.py` | Mock/native reports preserving failing gates |

Use fresh output directories:

```sh
python3 tests/experiments/run_chart_feasibility.py --recorded --sample-ticks 5 --output build/mipmap-direct-mock-new
python3 tests/experiments/run_chart_feasibility.py --recorded --profile --sample-ticks 5 --output build/mipmap-direct-profile-new
python3 tests/experiments/run_chart_feasibility.py --native --recorded --columns 800 --sample-ticks 5 --output build/mipmap-direct-native-new
python3 tests/experiments/run_chart_feasibility.py --native --recorded --columns 240 --series 2 --sample-ticks 5 --output build/mipmap-scroll-small-new
```

Nonzero exit status is expected while workload limits fail. `--sample-ticks`
controls warm-up reading spacing in 10 ms ticks, not native dispatch cadence.
`--profile` includes diagnostic instrumentation overhead; omit it for normal
mock counts. `--batch N` lowers per-series batch limits for comparison.
Without `--recorded`, the runner retains drawing-only and isolated mapping/
setter lower bounds, which cannot demonstrate a full performance-gate pass.
