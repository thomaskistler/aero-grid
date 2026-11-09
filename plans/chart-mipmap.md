# Chart mipmap implementation plan

## Actual gated-runtime callback gate

The opt-in normal chart now uses **71 ordinary / 63 Smart / 41 telemetry**
columns per series, without the telemetry early yield. Telemetry takes priority
over Smart only when the service timestamp matches the current callback; stale
service markers do not select the telemetry quota. Default enablement is unchanged.

The user approved keeping Lua-mock correctness and lifecycle checks while moving
the callback-budget assertion to real native EdgeTX setters. The repeatable gate
copies the repository chart source unchanged and checks all four controlled
operations plus continuous operation. Every conservative whole-callback bound
`(getUsage() + 1) * 200` must be **strictly below 15,000**. This already includes
the requested 5,000-instruction firmware margin; no additional margin is imposed.

The isolated comparison below did not establish safe actual-runtime quotas:
73/65/43 reached 15,000 horizontally and 15,200 vertically when used throughout
warm-up and measured work with fresh service classification. At 71/63/43,
horizontal reached 15,200 on a telemetry callback; 71/63/42 reached exactly
15,000 and was correctly rejected. The passing 71/63/41 run is:

| Operation | First complete paint | Callbacks | Worst callback bound | Pixel mismatches |
| --- | --- | --- | --- | --- |
| Append | 750 ms | 13 | 8,600 | 0 / 128,640 |
| Horizontal rescale | 1,440 ms | 26 | 14,800 | 0 / 128,640 |
| Vertical rescale | 1,020 ms | 18 | 14,800 | 0 / 128,640 |
| Ordinary scroll | 970 ms | 17 | 8,400 | 0 / 128,640 |
| Continuous operation | Not measured | 1,872 | 12,200 | Not measured |

Evidence: `build/chart-runtime-gate-production-v6/runtime-gate.json`.
Reproduce on macOS with Companion 2.12 installed:

```sh
caffeinate -i make test-chart-native
```

Full Python/Lua behavior suites and Lua lint passed. Controlled cases use the
50 ms policy and fence chart observers after initial publication; services keep
running. Continuous operation does not fence. References retain normal overlays,
and diagnostic memory includes both pools. These results establish the tested
native callback/pixel gate, not universal quota maxima, hardware memory safety,
or release acceptance. Hardware memory and broader release checks remain pending.

### Extended native coverage

`build/chart-runtime-gate-extended-v1/runtime-gate.json` passes all eleven cases
with unchanged 71/63/41 runtime quotas. The original four operations again have
zero pixel mismatches and worst bounds no higher than 14,800; continuous
operation peaks at 12,200. Additional cases:

| Case | First complete paint | Worst callback bound | Pixel mismatches |
| --- | --- | --- | --- |
| Horizontal expansion from level 4 | 1,600 ms | 14,800 | 0 |
| Horizontal expansion from level 9 | 1,390 ms | 14,800 | 0 |
| Maximum-level scroll near lap 2.25 | 1,010 ms | 8,000 | 0 |
| Maximum-level scroll near lap 4.25 | 960 ms | 7,800 | 0 |
| Horizontal expansion at 368 columns | 1,510 ms | 14,600 | 0 |
| Maximum-level scroll at 226 columns | 850 ms | 9,200 | 0 |

Reproduce with:

```sh
caffeinate -i python3 tests/experiments/run_chart_runtime_gate.py --extended --output build/chart-runtime-gate-extended-new
```

Higher-level and later-lap cases use bounded seed replay, not an uninterrupted
long flight or sequential scrolls in one session. Width cases resize before
measured rendering; they do not measure the resize callback itself. Live resize,
native pause/resume fallback were not covered by those eleven cases.

### Native live resize and recording resume

`build/chart-runtime-lifecycle-v4/runtime-gate.json` passes **2,672 callbacks**
with worst conservative bound **12,200**, including a live 398-to-368-column
resize and a real pause/resume. Both charts retain Smart detection and 24
recorded sources. The fixture waits through the flight disarm hold before
rearming; the earlier short pause correctly left recording active and did not
exercise a resume.

Assertions verify local map replacement without changing the sibling map,
republication after resize without a legacy double buffer, a genuine recording
pause and nonzero resume marker, both charts switching to the existing legacy
resume renderer, and retained history/observer data. No transition pixel oracle
is supplied: this is a native callback/lifecycle gate, not painted-output
acceptance. The scenario is now the twelfth extended case and can run alone:

```sh
caffeinate -i python3 tests/experiments/run_chart_runtime_gate.py --case live-resize-resume --output build/chart-runtime-lifecycle-new
```

Uninterrupted longer flights, sequential maximum-level scrolling and actual-radio
memory remain outstanding. Default enablement is unchanged.

### Service-driven accelerated long flight

`build/chart-runtime-long-flight-v5/runtime-gate.json` passes **5,705 callbacks**
with worst conservative bound **12,600**. Each of the six series publishes all
eleven levels and at least six consecutive maximum-level scrolls. The flight
remains recording with no resume marker. All readings arrive through the actual
services without seed replay or observer fences. Explicit coverage records are
required by the gate; missing levels, scrolls or uninterrupted status fail.

The diagnostic advances 50 logical ticks per 50 ms admission (10x), reaching
266,400 ticks of recorded chart time (44.4 minutes). This is not a real-time
44-minute soak: logical sample density and service alignment differ. The
reported 12,500 ms first-expansion submission is logical time, not a measured
paint deadline. No long-flight pixel oracle is supplied.

Every retained level's tag keys remain within the plot-width ring bounds.
The integrated renderer currently retains all eleven levels; it does not call
the prototype's `releaseBelow` helper. These bounded-storage checks therefore
do not establish fine-level retirement or actual-radio memory safety.

The scenario is the thirteenth extended case:

```sh
caffeinate -i python3 tests/experiments/run_chart_runtime_gate.py --case long-flight --output build/chart-runtime-long-flight-new
```

The unchanged lifecycle scenario was rerun after the shared fixture changes:
`build/chart-runtime-lifecycle-v5/runtime-gate.json` again passes 2,672 callbacks
at 12,200. Full Python/Lua suites and Lua lint pass. Actual-radio memory,
real-time soak and long-flight/transition pixel acceptance remain outstanding;
default enablement remains off.

## Combined scroll correction and telemetry optimization (2026-11-08)

The user authorized combining both investigations into draft PR #192, with
production gating unchanged. At this checkpoint the runtime still used 40/24
and retained the telemetry early yield; the quotas below existed only in
isolated diagnostic SD copies. The actual-runtime section above supersedes
that runtime policy, not these historical comparison results.

The scroll mismatch was a renderer defect, not an oracle discrepancy. A full
redraw at a non-lap maximum-level origin left the quarter groups in a different
ring layout from the layout assumed by the next grouped scroll. Every x-moving
begin now installs canonical per-series phase offsets. The regression covers
the first level-10 frame at `1.25 * span - 20`, twelve subsequent quarter
scrolls, and widths 226, 397, 398, 399, 400 and 800.

Telemetry work now reuses history ring addressing, block-array references and
precision epsilon constants, avoids idle subscription precision scans while
re-enrolling late resolutions, and reuses the incoming mipmap sample position.
Exact equivalence against `2f040da` passed 40 cases and 288,040 samples,
comparing history bytes, summaries and mipmaps.

### Combined four-operation native comparison

Both implementations use identical timestamped seed readings and gaps, two
398-column three-series charts, 24 sources, Smart detection, native Companion
2.12 drawing, and the controlled 50 ms logical/admission policy. Integrated
quotas are **73 ordinary / 65 Smart / 43 telemetry** per series, with the
telemetry guard bypassed only during measured work. The direct-dispatch
prototype baseline uses **130 / 130 / 90**, with lighter overlay work. Both
retain the 90-column x-update cap. The prototype's vertical projection is
bottom-anchored to match the normal chart's range expansion.

| Operation | Prototype complete paint | Prototype callbacks / bound | Integrated complete paint | Integrated callbacks / bound |
| --- | --- | --- | --- | --- |
| Append | 590 ms | 10 / 7,200 | 800 ms | 14 / 8,200 |
| Horizontal rescale | 640 ms | 10 / 14,800 | 1,480 ms | 25 / 14,800 |
| Vertical rescale | 590 ms | 10 / 14,800 | 1,160 ms | 18 / 14,800 |
| Ordinary scroll | 490 ms | 10 / 13,400 | 900 ms | 17 / 9,400 |

All eight frames match all 128,640 compared panel pixels with **zero mismatches**.
Every complete measured callback has conservative bound `(getUsage() + 1) * 200`
strictly below 15,000; no CPU-limit failure occurred. The combined integrated
telemetry allowance of 43 fits, so no reduction was necessary. Matching seed
hashes (prototype and integrated) are 14800113, 4912788, 7332694 and 13755531,
with 3010, 3280, 3154 and 3016 seed samples respectively.

Artifacts are `build/mipmap-controlled-<operation>-integrated-combined-integrated-v1`
and `build/mipmap-controlled-<operation>-prototype-combined-prototype-v1`.
The local diagnostic adapter is `build/mipmap-four-operations.{lua,py}`:

```sh
caffeinate -i python3 build/mipmap-four-operations.py --modes integrated --batch 73 --smart-batch 65 --telemetry-batch 43 --version combined-integrated-v1
caffeinate -i python3 build/mipmap-four-operations.py --modes prototype --batch 130 --smart-batch 130 --telemetry-batch 90 --version combined-prototype-v1
python3 tests/experiments/run_telemetry_cost.py --baseline-ref 2f040da --verify
```

These are controlled comparative timings, not hardware deadlines or complete
production acceptance. Inputs fence after the initial redraws while services
continue; the reference retains existing normal overlays rather than
independently recomputing their algorithms. Diagnostic memory includes both
pools. Historical fixed-800/398 and 160 ms natural-trigger results below remain
separate. Radio memory, long-running behavior, broader acceptance and default
enablement remain outstanding. Full Python/Lua suites and Lua lint passed for
the combined changes.

## Saved integration checkpoint

The user requested committing and pushing the current gated integration and
diagnostic work to draft PR #192 after pausing this workstream. Earlier
"uncommitted" and "no commit/push authorized" notes below describe their
respective investigation stages, not this later authorization. The normal
renderer remains the default; integration latency and complete acceptance
remain unresolved. Scheduling investigation continues separately under the
user's manual direction.

## Current contract

The opt-in prototype renders **one min/max envelope per series per actual
drawable pixel column**. Its output width is `floor(chart.area.w)`, not the
historical experiment's 800 temporal slots. Multiple readings in one column
extend that column's observed extrema; incidental separated strokes from
colliding old prototype buckets are not part of the output contract.

The existing renderer remains the default and PR #192 remains draft. The
physical-width prototype is committed and pushed as `b75509f`; normal-chart
integration is uncommitted and internally opt-in. Only currently supported
firmware APIs are in scope; no firmware changes or reliance on unmerged
EdgeTX functionality.

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

The normal chart now has an internally gated growing-chart integration.
Previews, rolling charts, late/incomplete consumers and actual pause/resume
sessions retain the existing renderer. In particular, compressed recording
pauses and dotted resume connectors are not replaced with different gap
semantics. Do not simulate physical resize by resetting a shared recorder.

Integration groundwork now provides explicit consumer detach/destruction and
chart-local restart at a new width/time origin. A consumer attached after
recording begins is marked incomplete until the next session reset; compressed
knots cannot recover the original observed extrema. The normal renderer must
remain its fallback rather than silently presenting partial coverage. Tests
verify that restart/destruction leave the recorder and sibling consumers
unchanged, and that repeated restarts do not accumulate observers. This
ownership API is wired into normal chart create/update/destroy behind an
internal opt-in dependency, not enabled by default. Configuration-time size
changes restart only that chart's consumer at its current session timestamp;
position-only changes retain it. Preview and rolling charts do not attach.

Normal chart geometry previously changed during live
legend growth, not just dashboard configuration. A mocked live-value change
from ordinary readings to `999999` shrinks existing plots from 156 to 122,
151 to 129 and 393 to 350 columns without changing panel size. The permission
to discard data on configuration-time resize does not cover this runtime
case. The user chose to hold plot width stable between configuration changes.
Live legend growth now steps down fonts within its original allocation; values
that still cannot fit show explicit overflow rather than a truncated number.
Vertical geometry may still change with font size and requires reprojection,
not loss of screen history. Configuration resize recalculates the allocation.

**Approved publication choice:** use one native pool with progressive redraw
for performance, not the existing renderer's double-buffered atomic replacement.
Intermediate frames may contain old/new columns while a redraw is in progress;
the completed output must still be exact. The user explicitly approved this
trade-off. Gated integration does not allocate a legacy back buffer while using
the mipmap renderer. All eleven screen levels are currently retained; the
prototype's post-publication fine-level retirement is not enabled here.

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

The user accepts the measured six-turn horizontal expansion for now and has
paused further optimization of that extra turn. Keep the original five-turn
target and its diagnostic failure visible; this temporary acceptance does not
relax the strict callback ceiling or painted deadlines.

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

All prototype runtime painted deadlines pass, with no measured append/scroll regression.
**The original turn gate still fails:** horizontal expansion takes six chart
turns against a five-turn target. No limit or callback quota was raised, and
the runner correctly reports the overall workload gate as failing.

The follow-up completion trace identifies the sixth turn as real live-input
catch-up, not a setup/publication-only turn. Each chart finishes its initial
expansion in five turns. While the second chart holds the existing serialized
dispatcher, the first receives another reading and becomes stale. After the
second finishes on host callback 10, callback 11 repairs 22 columns in the
first chart; only then does the independent complete-frame check pass.
The same five-initial-plus-one-repair sequence reproduces in the mock trace.
Dropping that callback, freezing chart input early or counting only initial
completion would change correctness or conceal the original target miss.
There is no demonstrated removable empty turn. Further improvement needs
cheaper initial submission or an explicitly budgeted shared repair schedule,
not a quota increase or a harness-only scheduling shortcut.

Earlier rejected joint-group, interval-union and no-op-cache work investigated
the wrong fixed-800 output premise or failed callback limits. None is retained
in the renderer. The lower-memory rectangle primitive remains: on the earlier
fixed-800 workload it matched vline pixels and reduced LVGL high-water usage
872,147 to 795,355 bytes without a demonstrated latency gain. Historical
reports remain in `build/mipmap-*`; they are not current acceptance results.
The fixed-800 interval-union investigation has stopped.

The physical-width prototype is validated and its extra horizontal turn is
temporarily accepted. These measurements do not establish normal-chart
integration performance.

### Gated normal-chart integration

The new `chart_mipmap_renderer.lua` owns a single pool and handles clipped raw
values, append catch-up, integer grouped scroll, rescale and bounded setup/reset.
`chart.lua` supplies normal ranges, headers, grid, flight bands and arm markers.
Sample subscriptions have explicit detach/reset/resize lifetimes. Mock coverage
includes two charts, changing inputs, Smart, 24 sources, local resize, real
pause/resume fallback and an active flight whose clock moves every callback.

An active flight initially kept the serialized dispatcher forever: the flight
helper's true result means it performed work, not necessarily that more slots
remain. The integration now yields only for unfinished decoration passes,
freezes their elapsed bound, and clears that state on completion/reset/resize/
fallback/destruction. Both charts now advance to the first expanded level.
Native submission also skips redundant legend/range refreshes during a running
projection job; fresh readings remain recorded and are caught up.

Sequential native callback-smoke runs, with the real normal refresh and live
input, measured initial expansion submission at **3,920 -> 3,310 ms** after that
metadata change (`build/mipmap-normal-integrated-native-v5` -> `v6`).
The latest run traced 1,896 whole callbacks with a conservative worst bound of
9,800 instructions; both 398-column charts published level 1, using six series,
2,388 rectangles and 24 recorded sources. Simulator LVGL lifetime peak was
389,846 bytes, not total radio memory.

The user requested testing the obvious submission-throttle change before broader
optimization. Two subsequent sequential native smoke runs changed only the
per-series allowance, retaining telemetry-callback yields and all other
scheduling (`build/mipmap-normal-integrated-native-v7` and `v8`):

| Allowance, ordinary / Smart | Initial expansion submission | Worst whole-callback bound |
| --- | --- | --- |
| 40 / 24 baseline | 3,310 ms | 9,800 instructions |
| 130 / 80, capped at 90 when updating x | 1,540 ms | 15,800 instructions: fails |
| 110 / 70, capped at 90 when updating x | 1,750 ms | 13,600 instructions: passes native smoke |

The 130/80 run traced 1,882 callbacks; three conservative bounds reached or
exceeded 15,000 (15,600, 15,800 and 15,000). The 110/70 run traced 1,884
callbacks with real input and both charts publishing level 1. Its LVGL lifetime
peak was 389,802 bytes. These are continuous-smoke submission measurements,
not independent complete-painted-frame or matched append/scroll/vertical gates.
The reduced allowance demonstrably accounts for much of the integration
slowdown; this does not attribute the remaining latency.

The 110/70 candidate also failed the existing whole-callback Lua integration
test at 28,800 counted instructions. That test counts Lua mock native-setter
implementations, unlike the actual firmware's C++ setters; its failure must
not be silently ignored or its threshold raised. The experimental allowances
were restored to 40/24 rather than leave a failing regression in place.
Before adopting the native-safe candidate, resolve the native/mock accounting
discrepancy with explicit measurement and retain a real whole-callback safety
gate. No increased allowance is accepted or enabled by these experiments.

**Integration remains blocked from default enablement.** Even initial submission
exceeds the 1,000 ms runtime rescale deadline. These continuous-input smoke runs
do not measure matched append/scroll/vertical operations or first complete
painted frames. An independent native oracle including normal overlays is
still required; do not borrow the prototype's 650/510 ms painted results or
report a zero/missing readiness value as success. The smoke runner deliberately
keeps `paint_verified` and `gate_passed` false.

The new matched horizontal harness is experimental and has not established a
valid latency comparison. The final sequential pair
(`build/mipmap-matched-prototype-v6`,
`build/mipmap-matched-integrated-baseline-v4`) has identical pre-trigger input
fingerprints (123 samples, hash 1583777513, logical trigger 117712).
Both complete panel regions match their post-timing input-derived reference
spans (128,640 pixels); normal overlays are retained, not independently
recomputed. The prototype required 12 timed callbacks and the 40/24 integration
75, with conservative native bounds 10,000 and 7,000 respectively.
However, the integrated run's firmware timestamps jumped to millions of ticks
and reported an impossible roughly 1,895-second duration for this capture.
Reject that run's wall-clock/paint latency numbers; do not present them as a
matched slowdown. Clock isolation/capture timing must be corrected and validated
before drawing a timing conclusion. The prototype reported 1,980 ms in this
different natural-trigger harness, not a reproduction of the historical 650 ms
controlled operation. Runtime code/allowances remain unchanged by the harness.

The user suggested laptop sleep as the cause of the timestamp jump and requested
a rerun. Sequential runs under command-scoped `caffeinate -i` completed without
that jump. All three have the same 123-sample pre-trigger fingerprint
(1583777513), logical trigger 117712, 24 sources, two 398-column three-series
charts, and the same 160 ms timed host-admission policy:

| Awake matched run | Ordinary / Smart allowance | Callbacks | First complete paint | Worst native callback bound |
| --- | --- | --- | --- | --- |
| `mipmap-matched-awake-prototype-v1` | 130 / 80 | 12 | 1,880 ms | 10,000 instructions |
| `mipmap-matched-awake-integrated-v1` | 40 / 24 | 75 | 12,100 ms | 7,000 instructions |
| `mipmap-matched-awake-integrated-fast-v1` | 130 / 80 | 35 | 5,840 ms | 7,400 instructions |

All three match all 128,640 compared panel pixels against the input-derived
post-timing replacement spans, with no mismatches. Existing normal overlay
objects remain in the reference; this does not independently verify their
algorithms. The chart-input fence is applied after both initial redraws, so the
longer redraws receive more input before drain (6, 24 and 12 events respectively);
polling, Smart and shared recording continue. These are matched trigger/cadence/
completion-policy measurements, not identical final input traces.

The throttle accounts for a large part of the difference, but equal maximum
allowances still leave 35 versus 12 callbacks. This establishes remaining
integration scheduling/work overhead in this harness without attributing it to
specific phases. Integration still yields on telemetry callbacks; equal
allowances do not mean equal effective submission schedules. Do not equate
these 160 ms whole-host-admission measurements with the earlier continuous
smoke's 1.54/3.31-second submission results, or the historical 650 ms controlled
prototype paint. No run here meets the 1-second deadline.

The fast run passing its native callback budget does not supersede the earlier
1,882-callback smoke that failed at 15,800 instructions: this is only one matched
horizontal operation. Experimental allowances are injected into isolated SD
copies only; source runtime remains at 40/24. Sleep is a plausible explanation
for the discarded overnight timestamps, not proven by this successful rerun.
No default enablement, commit or push was performed.

### Equal-allowance callback attribution

The user approved investigating the remaining integration overhead. A diagnostic
run (`build/mipmap-matched-attribution-v1`) uses the same matched starting input
fingerprint/trigger and isolated 130/80 allowances, with per-dispatch phase,
service, owner, grid-version and native-job-index observations:

| Callback activity | Count |
| --- | --- |
| Native trace submission | 11 |
| Early return because telemetry ran this callback | 12 |
| Grid-only update | 7 |
| Readout/range metadata followed by an explicit yield | 5 |
| Dispatcher wait without a chart dispatch | 0 |
| Standalone flight/arm-decoration pass | 0 |
| Total | 35 |

Both initial chart submissions consume five drawing callbacks, advancing the
first series through 80, 160, 240, 320 and 398 columns; Smart is polled on every
measured callback, so the effective allowance is 80, not 130. The eleventh
drawing callback repairs input received by the first completed chart while the
second held dispatcher ownership. Flight/arm decoration completes on the same
callbacks as final submission, not as separate delayed work.

The remaining 24 callbacks never call the native renderer's `step`:
`refreshMipmap` returns immediately after telemetry work, repeatedly yields
after `chart.render` reports fresh readings while grid setup is in progress,
and fills/revalidates its twelve grid slots in three-slot passes before
allowing trace drawing. Seven grid-only passes occur inside the timed interval;
one earlier grid pass had already occurred before the first crossing reading.
Metadata produces five additional yields, including one before the final
live-input repair. The trace has no version/geometry-reset loop during drawing
and no idle dispatcher gap to explain these turns.

The instrumented run completes paint in 5,680 ms, matching the prior
uninstrumented 35-callback shape (5,840 ms), with zero mismatches across 128,640
panel pixels and conservative worst callback bound 7,400 instructions.
Tracing adds diagnostic overhead, so it is attribution evidence, not a new
acceptance gate. This accounts for the callback-count difference without
claiming a per-setter CPU slowdown or attributing each millisecond precisely.

The concrete follow-up is to evaluate bounded service-aware submission on
telemetry callbacks and combine small metadata/grid stages with useful drawing
where measured callback headroom permits, rather than increase the per-series
quota again or remove overlays. Such changes must preserve input/recording,
whole-callback limits, complete painted output and normal append/scroll
behavior. They have not been implemented by this investigation. Runtime
allowances remain 40/24; only the isolated diagnostic copy uses 130/80.

Before default enablement, resolve the measured integration latency, establish
matched complete-painted-frame correctness/performance, and validate firmware
total-memory bounds and MK3 hardware behavior. Simulator LVGL high-water
excludes Lua/C++ allocations; simulator `getAvailableMemory()` is a hardcoded
placeholder, not a radio heap reading. No further commit/push is authorized.

## Relevant files and reproduction

| File | Purpose |
| --- | --- |
| `src/WIDGETS/AeroGrid/lib/chart_mipmap.lua` | Incoming-reading hierarchy and integer scroll origin |
| `src/WIDGETS/AeroGrid/lib/chart_mipmap_renderer.lua` | Gated normal-chart single-pool native submission |
| `tests/integration/widget/test_chart_mipmap_integrated.lua` | Actual chart refresh, services, lifecycle and callback limits |
| `tests/experiments/native_chart_mipmap_integrated.lua` | Native normal-chart callback smoke; not a painted-frame gate |
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
python3 tests/experiments/run_chart_feasibility.py --native --recorded --stress --integrated --output build/mipmap-normal-native-new
```

Nonzero exit remains expected when any runtime target fails. `--batch` is
an upper bound; telemetry/Smart work reduces the per-series allowance.
`--resized-scroll` retains a historical preservation diagnostic only, not the
intended configuration-time resize lifecycle. Legacy `--columns` labels do
not override actual geometry for the current recorded prototype.
