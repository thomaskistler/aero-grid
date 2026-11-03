# Chart mipmap implementation plan

## Current contract

The opt-in prototype renders **one min/max envelope per series per actual
drawable pixel column**. Its output width is `floor(chart.area.w)`, not the
historical experiment's 800 temporal slots. Multiple readings in one column
extend that column's observed extrema; incidental separated strokes from
colliding old prototype buckets are not part of the output contract.

Production remains unchanged and PR #192 remains draft. Current work is
uncommitted. Only currently supported firmware APIs are in scope; no firmware
changes or reliance on unmerged EdgeTX functionality.

Physical dashboard resize is configuration-time work. It may discard and
recreate only the affected chart's presentation at the new geometry. Do not
clear shared telemetry/recording history or other charts. Runtime horizontal
time-window expansion and vertical-axis rescaling must preserve chart data,
extrema and real telemetry gaps; they are not physical resize.

## Data flow and ownership

Each filtered incoming reading goes independently to the authoritative recorder
and to the chart-local screen hierarchy. The optional history sample observer
uses the recorder's filtered value, timestamp and break state without polling
again or changing recorded knots.

- Preserve original recording accuracy, 6,144-knot capacity, HISTORY FULL and
  rolling retention. Shared history is not downsampled to screen resolution.
- The screen hierarchy has eleven levels, spans `60 * (4/3)^level` seconds,
  with at most the chart's physical column count in each ring.
- Each reading updates one bucket per retained level directly. Because 4:3
  boundaries do not align, levels consume the same readings independently;
  expansion selects a prepared level without replay/rebinning.
- Screen summaries retain observed extrema. They need not equal extrema of
  the recorder's compressed replay line. Separate detail consumers can keep
  a different resolution; retiring screen levels does not change them.
- Retire finer screen levels only after publication. Missing/disarmed input,
  reset and HISTORY FULL retain their established behavior.

The existing gap rule is unchanged, applied to physical-width columns:
unsampled columns stay empty. Missing telemetry or a break inside an occupied
column hides that whole column; a resume in it does not fill the break. The
next sampled column may resume normally. No interpolation or connection is
drawn across a gap. A break at the first reading of a new column does not
connect it to the previous one.

The prototype remains single-consumer and growing-chart only. Production
ownership, late attachment/reconstruction, previews, zoom, rolling charts,
atomic replacement and actual configuration-time teardown/recreation are not
wired. Do not simulate physical resize by resetting a shared recorder.

## Native representation

Use one filled, borderless one-pixel rectangle per physical column per series.
Its y/height is the inclusive projected min/max range. The fixed pool is
`drawable_width * series_count`; it does not grow with sample count or elapsed
time. No duplicate pool or arbitrary-width phase hierarchy.

At maximum time range, scroll on whole-column origins:
`floor(quarter_index * drawable_width / 4)`. Widths not divisible by four use
alternating integer quarter sizes; four shifts advance exactly one full ring.
One parent per ring quarter per series translates retained columns by integer
pixels. Only active/new columns need individual geometry; gaps/expired slots
are hidden. Native painting/layout still costs work.

Horizontal expansion selects another prepared level and projects that
level's physical-width envelopes. Vertical rescale reprojects their extrema.
Live readings arriving during serialized redraws are caught up within the
remaining callback allowance, including when another chart owns the dispatcher.

## Verification and limits

| Runtime requirement | Limit |
| --- | --- |
| Every complete callback | Strictly below 15,000 counted Lua instructions |
| Append / ordinary quarter-scroll | Strictly below 500 ms through painting |
| Horizontal / vertical rescale | At most 1,000 ms through painting |
| Single-series append | At most one chart turn |
| Multi-series append / scroll | At most two chart turns |
| Runtime rescale | At most five chart turns |

These are the original turn targets; report misses honestly. Physical resize
and preserved post-resize diagnostics are excluded from runtime latency/turn
acceptance, not from callback or pixel checks.

The native workload uses two full-width three-series charts, 24 actual recorded
sources, Smart, live filtered input and unchanged dispatcher/service work on
the 480x272 simulator. Each plot's drawable width is **398 pixels**, so the
correct pool is **2,388 rectangles and 24 quarter parents** across both charts.
The historical `800` fixture label is not screen width; a genuinely 800-pixel
plot legitimately needs 800 envelopes per series.

The independent test oracle records timestamped inputs and recomputes each
selected level's width-column min/max/gap from those inputs, not from mipmap
arrays or old-renderer pixels. Native expected plots come from this oracle.
Bounded oracle target export is outside operation timing; input-trace capture
is included in timed callbacks. Its diagnostic storage is not production
retention or a total-radio heap measurement.

Both initial redraws receive samples before the fixture fences comparison and
drains received input. Polling, recording and Smart continue during drain.
This proves a settled fenced frame, not perpetual zero-lag publication.
Compare every native plot pixel, including blank/gap regions. Bounds use the
following callback's `getUsage()` plus one 200-instruction quantum.

## Evidence and remaining work

Sequential matched native runs compare the committed fixed-800 renderer
(`build/mipmap-historical-800-matched`) with physical-width output
(`build/mipmap-physical-width-final`) under the same four-operation live workload:

| Operation | First complete paint, historical -> physical width | Chart turns, historical -> physical width |
| --- | --- | --- |
| Append | 170 -> 160 ms | 1 -> 1 |
| Horizontal expansion | 1,200 -> 650 ms | 11 -> 6 |
| Vertical rescale | 960 -> 510 ms | 9 -> 4 |
| Ordinary scroll | 440 -> 280 ms | 4 -> 2 |

All four frames in each run match their independent timestamped-input oracle,
including gaps. Different output pixels are intentional where the old output
had colliding temporal buckets. Each operation received live chart input.
All 25 physical-width callbacks were traced, with a conservative worst bound
of 13,400 instructions (historical: 47 callbacks, 14,200).

Across both charts the pool drops from 4,800 spans/96 quarter-phase parents to
2,388 rectangles/24 quarter parents. Simulator LVGL lifetime high-water drops
from 872,147 to 407,317 bytes (53.3%). This comparison includes the rectangle
primitive change as well as width sizing; it is not an isolated measurement
of either change or a total-radio memory bound.

All runtime painted deadlines pass, with no measured append/scroll regression.
**The original turn gate still fails:** horizontal expansion takes six chart
turns against a five-turn target. No limit or callback quota was raised, and
the runner correctly reports the overall workload gate as failing.

Earlier rejected joint-group, interval-union and no-op-cache work investigated
the wrong fixed-800 output premise or failed callback limits. None is retained
in the renderer. The lower-memory rectangle primitive remains: on the earlier
fixed-800 workload it matched vline pixels and reduced LVGL high-water usage
872,147 to 795,355 bytes without a demonstrated latency gain. Historical
reports remain in `build/mipmap-*`; they are not current acceptance results.
The fixed-800 interval-union investigation has stopped.

The physical-width correction is validated; the remaining runtime target is
horizontal expansion's extra chart turn. Before production integration also
establish shared consumer lifetime,
configuration-time recreation, firmware total-memory bounds and MK3 hardware
behavior. Simulator LVGL high-water excludes Lua/C++ allocations; simulator
`getAvailableMemory()` is a hardcoded placeholder, not a radio heap reading.

## Relevant files and reproduction

| File | Purpose |
| --- | --- |
| `src/WIDGETS/AeroGrid/lib/chart_mipmap.lua` | Incoming-reading hierarchy and integer scroll origin |
| `tests/support/chart_mipmap_prototype.lua` | Physical-width rectangle pool and quarter scrolling |
| `tests/support/chart_mipmap_stress.lua` | Real services, live input and independent target export |
| `tests/support/mipmap_reading_oracle.lua` | Independent timestamped-reading envelope reference |
| `tests/unit/lib/test_chart_mipmap_width_oracle.lua` | Widths, extrema, gaps and unchanged shared recording |
| `tests/integration/widget/test_chart_mipmap_group_scroll.lua` | Integer widths 226-800, gaps and wraps |
| `tests/experiments/run_chart_feasibility.py` | Mock/native whole-callback and painted-frame reports |
| `tools/capture-native.cpp` | Frame timestamps and quiescent LVGL lifetime peak |

Use fresh output directories:

```sh
python3 tests/experiments/run_chart_feasibility.py --recorded --stress --batch 130 --output build/mipmap-width-mock-new
python3 tests/experiments/run_chart_feasibility.py --native --recorded --stress --batch 130 --output build/mipmap-width-native-new
```

Nonzero exit remains expected when any runtime target fails. `--batch` is
an upper bound; telemetry/Smart work reduces the per-series allowance.
`--resized-scroll` retains a historical preservation diagnostic only, not the
intended configuration-time resize lifecycle. Legacy `--columns` labels do
not override actual geometry for the current recorded prototype.
