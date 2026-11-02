# Chart mipmap implementation plan

## Status

The acceptance workload is the worst case: **two populated 800-column,
three-series charts**, incoming readings, 24 recorded sources and Smart.
Fixed-geometry scrolling now completes in **460 ms through confirmed painting**.
All measured native callbacks remain below 15,000 instructions. Expansion,
vertical rescaling and resizing still exceed the 1,000 ms painted deadline.
**Production integration is not yet approved.** The production renderer remains
unchanged; its optional history sample-observer hook is dormant without a consumer.

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

The worst-case adapter now groups native spans by ring quarter and fractional
pixel phase. Moving 48 parent containers per three-series chart translates the
retained spans exactly, including half/quarter-pixel rounding. Only the active
and newly exposed quarter needs individual updates or hiding. Native layout
and painting still perform work; this is not a zero-CPU transform. The grouped
path requires integral quarter-columns and the original horizontal geometry.
Resized geometry and unsupported widths retain the bounded per-span fallback.

Each redraw tracks its captured sample revision and timestamp. New readings
received during drawing are caught up within the remaining column allowance;
finished charts also process append updates while another chart owns the
dispatcher. A window boundary reached by one series moves every series, even
those receiving no reading. Stable-window vertical/resize jobs skip the future
tail already hidden by the published frame, without skipping stale-slot cleanup
when the level or origin changes.

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

These are the original experiment targets. The strict callback ceiling and
painted deadlines remain primary. Seven extreme redraw turns alone were not a
priority for the user; the smaller panel example was illustrative, not a reason
to replace worst-case acceptance. Report turn counts without presenting the
original five-turn target as the sole blocker.

## Current measurements

Final native run: `build/chart-mipmap-worst-native-v6/native-results.json`.
Both charts have 800 summary columns and three series, compressed into the
480-pixel simulator's two full-width panels. Ordinary polling, recording,
Smart and dispatcher serialization use the real host path, with deterministic
synthetic firmware readings.

| Operation | Max chart turns | Whole host callbacks | First verified paint | Worst instruction bound | Incoming sample events |
| --- | --- | --- | --- | --- | --- |
| Append | 1 | 2 | 180 ms | 8,200 | 4 |
| Horizontal expansion | 11 | 20 | 1,160 ms | 13,200 | 10 |
| Vertical rescale | 9 | 18 | 1,070 ms | 13,600 | 6 |
| Populated fixed-level quarter-scroll | 4 | 7 | 460 ms | 11,600 | 6 |
| Resize of the scrolled view | 9 | 18 | 1,050 ms | 14,000 | 8 |

Every one of the **65 complete callbacks** has a trace entry and stays strictly
below 15,000 instructions. Bounds use the next callback's `getUsage()` for the
preceding complete refresh, plus one 200-instruction quantum (EdgeTX v2.12.0).
All five native frames match every expected plot pixel, including cleared
regions. Painting adds 50-60 ms after setter completion; the 990 ms resize
submission is therefore **not** a painted-deadline pass.

The preceding per-span scroll run took 1,170 ms through painting. The grouped
path moves 96 native containers across both charts rather than individually
shifting the retained spans. Start timing now aligns with a natural chart-source
poll, ensuring the short scroll receives readings without changing polling
quotas, service order or cursors. Ordinary sources remain available; their
maximum observed age at completion is 570 ms.

Input feeds both charts throughout their initial redraws. Once both initial
frames complete, the fixture establishes a comparison fence and drains all
readings received through that fence. **Polling and recording continue during
the drain**; only forwarding into the test maps stops. This proves a settled
fenced frame, not perpetual zero-lag publication under continuously changing
input. Preparation, trigger alignment and bounded diagnostic target export
are outside timed submission callbacks.

The stress adapter caps each series at 64 columns with telemetry work, 80 with
other Smart-pump work, and 130 otherwise, also respecting `--batch`. General
x-changing redraws retain their 90-column ceiling. Admission throttling applies
only when the renderer itself records a reading, not when the host already
delivered it. These are measured opt-in operating points, not a production
instruction scheduler. Mock Lua setters inflate counts relative to native C++
setters; mock geometry passes do not establish a native budget pass.

## Remaining work before integration

Reduce worst-case expansion/rescale/resize painting below 1,000 ms; verify the
scroll deadline after horizontal geometry changes, where grouped shifting
currently falls back. The original two-turn scroll/five-turn redraw targets
also remain unmet. The full gate stays failing rather than being relaxed.
Confirm actual layout resizing, shared consumer lifetime/reconstruction,
atomic publication, firmware heap use and MK3 display/hardware behavior.
Warm allocations remain outside operation timing.

Correctness coverage compares all levels with independent incoming-reading
extrema, including non-aligned boundaries, partial buckets, gaps/resumes,
smoothing, long timestamp jumps, wraparound, reset, full recording and
retirement. Recording with/without an observer must retain identical knots.
The renderer checks the full window's final visibility and geometry, not just
the changed tail. Grouped-scroll tests at 600/800 columns exercise all four
fractional-pixel phases, repeated ring wraps, gaps, vertical changes, resized
fallback and an uneven-series boundary during redraw. Continuous competing
charts and real 24-source/Smart regressions cover catch-up and service fairness.

## Files and reproduction

| File | Purpose |
| --- | --- |
| `src/WIDGETS/AeroGrid/lib/history_service.lua` | Optional filtered-sample/reset observer |
| `src/WIDGETS/AeroGrid/lib/chart_mipmap.lua` | Bounded incoming-reading hierarchy; not enabled by production chart |
| `tests/support/mipmap_recorder.lua` | Deterministic input through real recording |
| `tests/support/chart_mipmap_prototype.lua` | Opt-in sample-to-native adapter |
| `tests/unit/lib/test_chart_mipmap.lua` | Extrema, gaps, resets, lifetime and unchanged-recording checks |
| `tests/integration/widget/test_chart_mipmap_prototype.lua` | Dense native-object geometry checks |
| `tests/integration/widget/test_chart_mipmap_continuous.lua` | Continuous competing-chart catch-up |
| `tests/integration/widget/test_chart_mipmap_group_scroll.lua` | Group translations, rounding and fallback correctness |
| `tests/support/chart_mipmap_stress.lua` | Real-service/Smart workload and fenced comparison |
| `tests/integration/widget/test_chart_mipmap_stress.lua` | Live-input and recording-fairness regression |
| `tests/experiments/run_chart_feasibility.py` | Mock/native reports and exact painted-frame verification |
| `tools/capture-native.cpp` | Optional firmware-timestamped framebuffer trace |
| `tests/test_chart_feasibility.py` | Complete-pixel comparison and timestamp regressions |

Use fresh output directories:

```sh
python3 tests/experiments/run_chart_feasibility.py --recorded --stress --batch 130 --output build/mipmap-worst-mock-new
python3 tests/experiments/run_chart_feasibility.py --native --recorded --stress --batch 130 --output build/mipmap-worst-native-new
```

Nonzero exit status is expected while workload limits fail. `--batch` is an
upper limit; the stress adapter may select a smaller service-aware allowance.
Stress warm-up uses 50 ms synthetic readings; live samples arrive through real
polling. Non-stress `--sample-ticks` controls preparation spacing, not dispatch.
Without `--recorded`, the runner retains drawing-only and isolated mapping/
setter lower bounds, which cannot demonstrate a full performance-gate pass.
