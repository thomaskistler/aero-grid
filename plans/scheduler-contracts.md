# Scheduler Margin Rule and Task Contracts

Design addendum to [scheduler-utilization.md](scheduler-utilization.md), using
the costs in [scheduler-audit.md](scheduler-audit.md). No code changes. Costs are
Lua VM instructions; **M** = measured, **E** = estimated, **U** = unmeasured, as
in the audit. Everything labelled "declared" is a proposal.

## 1. Margin rule

An audited maximum is the worst cost *observed* under a stimulus, not a proof.
The declared bound is what the scheduler trusts, so it must sit above anything
the stimulus set could have missed.

### Declared bound

For each task, take `m`, the worst observed cost over the fault-injection set
below (per unit for `u`, per call for `f`; never add maxima from different
calls, fit `cost(n) <= f + n*u` over the measured unit counts `n` instead).

```
declared = ceil10(F * m + A)

CRITICAL, HIGH:      F = 1.25, A = 100 (per call; A = 0 for a per-unit bound)
NORMAL, BACKGROUND:  F = 1.10, A = 50  (A = 0 for a per-unit bound)
```

- The audit saw about 5% run-to-run variation on time-dependent paths and
  measured with probe windows that read about 35 high per nested window (the
  CI check uses the same probe, so it stays consistent). `F` covers variation
  and unseen inputs; `A` covers small tasks, where a multiplier alone is
  noise.
- Why the classes differ: `CRITICAL` and `HIGH` work is never shed by the
  margin, so a wrong bound there recurs every callback. `NORMAL` and
  `BACKGROUND` work is shed by margin growth and backed off by the near-miss
  guard, so a smaller factor recovers more utilization.
- Bounds are not rounded to the 200-instruction quantum per task (that would
  waste about 100 per task). Only the callback total is compared at quantum
  level: with plan total `U`, a near-miss is `usage > floor(U / 200)`. This
  cannot false-alarm, and is blind to overshoot inside the last quantum, which
  is why the margin floor is two quanta: `Mmin = 400`.

### Fault-injection set

Run natively (the audit harness), each with at least 5 different clock phases
or seeds; `m` is the maximum over all runs.

1. **Largest layouts:** 16 panels at the largest span, 4x4 chart, 3 series x
   6144 knots (`HISTORY FULL`), 64 flights, 8 sources, Smart on and off.
2. **Worst inputs:** every reading changes on every poll, including extreme
   values (longest formatted text, sign and precision changes).
3. **Gaps:** sensor dropout and resume, link loss, long gaps then resume.
4. **Resets:** session reset and model change mid-chart, mid-stage and with
   full history; layout reload mid-load.
5. **Grant sweep:** every task at 1 unit and at its cap, plus **multiple
   history entries recorded for one source in one call** (the audit measured
   only one).
6. **Periodic and boundary paths:** run long enough for each interval path
   (for example the 5 s model identity) and every history boundary.

### CI enforcement

Native measurement needs the macOS Companion harness, which CI does not run
today, so there are two checks.

- **Every CI run (no native):** a checked-in bounds table must satisfy
  (a) every task in the checked-in native traces stays at or below its declared
  bound, (b) the design-time `CRITICAL` admission test (below), (c) no atom
  above the lump limit and (d) no task registered without a measured bound.
- **Native job (macOS, when run):** rerun the fault-injection set and fail if any
  task exceeds its declared bound. Warn when usage exceeds 90% of a bound (the
  bound must be re-declared through the rule in the same change) or is under
  60% (loose, wasted utilization). A change that raises a bound must include the
  new measurement.

A breach in CI is a cost-table bug, the same as a runtime near-miss.

### Callback overhead

Overhead is declared per callback type, as `base + slope * panels`, with the
`CRITICAL`/`HIGH` factors (it is never shed). The audit measured callback type,
not chart stage kind, as what changes overhead.

| Callback | Audit max (M) | Declared at 16 panels |
|---|---|---|
| refresh, steady | 0.57k (1 panel), 0.92k (16) | 1.25k (about 0.65k + 25 per panel) |
| background, steady | 0.30k (1), 0.41k (16); panel `background` hooks 26 each | 0.62k (hooks included, enforced by the CI check) |
| refresh during staged load | 0.26k | 0.43k |
| create / update | 2.2k, once | not scheduled; must fit under the ceiling alone |

The audit's overhead includes the current `dispatchDue`/`updateServices`. The
new scheduler's own cost is **unmeasured** and is added once Phase 2 (shadow
mode) measures it.

### Ceiling

The 20000 firmware limit leaves 5000 above the 15000 ceiling (33%), plus `Mmin`.
That gap is the only protection against a systematic miss in the measurements,
and the margin factors above are layered inside it. A higher ceiling shrinks
it (17000 leaves 18%, less than `F = 1.25`). Keep 15000 until hardware data
exists; see Decisions.

### Design-time admission test

Overhead + `Mmin` + the declared sum of every `CRITICAL` task due together must
fit under the ceiling. With the declared values below:

- Smart on (telemetry cap 4): 5.5k + 0.65k + 2.6k + 1.25k + 0.4k = **10.4k**,
  leaving 4.6k, enough for the flight tick (3.6k).
- Smart off (telemetry cap 8, all recorded): 10.0k (E) + 0.65k + 2.6k + 1.25k +
  0.4k = **14.9k**. It passes by about 150 and leaves no room for `HIGH` work in
  the worst callback, so `HIGH` tolerance 1 can be violated. See Decisions.

## 2. Task contracts

Defaults: tolerance is 0, 1, 4, 20 for `CRITICAL`, `HIGH`, `NORMAL`,
`BACKGROUND` (the plan's starting point). "Next release" is counted from the
callback in which the task ran. One release is pending per task.

**Lump limit.** A single unit or split piece must have a declared bound of at
most **4000** (about the room left beside the worst `CRITICAL` load with Smart
on). A larger atom may never fit beside guaranteed work. Items marked **Flag**
cannot meet the plan's provable-bound requirement until split or capped as
stated.

### Telemetry (CRITICAL)

| Field | Contract |
|---|---|
| Unit, cap | Source polled; cap 8, 4 with Smart. Poll and record stay together (the sample time travels with the reading) |
| Declared | 1.18k per recorded source (M 0.94k), 0.42k per unrecorded (M 0.33k), 0.75k per call fixed (M 0.17-0.37k plus up to 0.15k precision scan on one source). At cap 8 recorded: 10.0k provisional (E, from 7.9k) |
| Split | Already per source; resume is a cursor |
| Next release | Delay 1 while sources remain after the cursor; otherwise next callback. Never deferred |
| **Flag** | Recording may repeat per history entry on one source, and only one was measured. Cap entries recorded per source per call (proposal: 1, carrying the rest in the next call) or measure and declare the cap. Cap 8 recorded sources is unmeasured (E) |

### Chart stages (NORMAL, except reset)

One stage per chart per callback. Each stage returns delay 1 until the frame is
complete, then the chart idles until its next frame release.

| Stage | Worst (M) | Declared | Unit | Split |
|---|---|---|---|---|
| frame begin | 1.1k | 1.3k | 1 | No |
| axis | 0.8k | 0.9k | breaks | Already staged |
| reading text and legend | 7.0k | 7.8k | series (3) | **Flag.** Split text setters per series from legend geometry (the `readingGeometry` flag exists). Per-piece cost is unmeasured; if the geometry piece alone exceeds 4.0k it needs a second split |
| header, ranges | 0.19k each | 0.3k each | 1 | No |
| grid | 0.4k per call | 0.5k per call (1-3 slots) | slot (12) | Already per slot |
| project | 6.9k | 0.83k per knot, 0.2k fixed (resume about 0.1k, M) | knot (cap 7-9 per call) | Ready: `limit` is the grant; job state persists |
| apply runs | 1.1k | 1.3k | run | Already incremental |
| flights | 0.4k | 0.5k | slot | Already per slot |
| arms, resumes | 0.2k each | 0.3k each | 1 | No |
| session reset step (HIGH) | 0.9k | 1.2k | staged | Already staged |

### Panel refreshes (NORMAL; BACKGROUND for diagnostics)

Unit is one refresh. Next release is the panel's current refresh cadence (for
example 5 s for model-identity), or delay 1 while an `apply` is pending after
`render` (the render table survives between callbacks). A refresh that could
not be admitted stays pending, never stacked. Worst is the larger of the
smallest and largest legal span (M).

| Panel | Worst | Declared | Split |
|---|---|---|---|
| metric | 4.3k | 4.8k | **Flag.** Steady refresh (render 0.4k + apply 0.6k) is small; the rest is `update` relayout (3.7k, rare). Make relayout its own task, split by region to at most 4.0k declared |
| output | 5.1k | 5.7k | **Flag.** `apply` is 3.8k at the largest span; split per row |
| navigation | 3.3k | 3.7k | `apply` per row (3.0k); within the limit, split if the cost spread is wide |
| link-status | 2.2k | 2.5k | render/apply, optional |
| rx-battery | 1.6k | 1.8k | render/apply, optional |
| trim-panel | 1.4k | 1.6k | render/apply, optional |
| tx-battery | 1.1k | 1.3k | No |
| flight-timer | 1.0k | 1.2k | No |
| state | 0.9k | 1.0k | No |
| model-identity | 0.9k | 1.0k | No |
| flight-counter | 0.6k | 0.7k | No |
| flight-mode | 0.5k | 0.6k | No |
| host-diagnostics, service-probe | 0.4k | 0.5k | No (BACKGROUND) |
| theme-showcase | U | none | **Flag.** Unmeasured: stays on the current static path until measured |

### Everything else

Declared is by the rule from the audit's worst (M unless E).

| Task | Class | Unit (cap) | Declared | Split or cap | Next release |
|---|---|---|---|---|---|
| history | CRITICAL | entry (1) | 0.65k | None | Every callback |
| control switches | CRITICAL | switch condition (6) | `200 + 100 n` (max 800) | 153-553 at grants 1-6 (M); critical arm/boundary readers only |
| control entries | NORMAL | trim/global-variable entry (6) | `130 + 240 n` (max 1570) | 282-1121 at grants 1-6 (M); natural-unit exception below 2.24k |
| control outputs | NORMAL | channel output (32) | `120 + 60 n` (max 2040) | 113-1694 at grants 1-32 (M); output-panel cadence is 10 ticks; natural-unit exception below 2.24k | Delay 1 while entries remain |
| flight tick | HIGH | tick | 3.6k (M 2.8k) | Within limit. Stage by phase only if the Smart share (2.6k) grows | Every callback |
| Smart (in tick) | HIGH | update | 2.6k (M 2.0k) | Per sensor read; discovery already resumable | With the tick |
| flight first tick | HIGH | load | 3.1k (M 2.4k) | **Flag.** Grows with the settings document; cap per call with `tokenizeChunk` | Delay 1 while loading |
| session reset check | HIGH | check | 0.62k | None | Every callback |
| reset steps | HIGH | 8 items | 0.2k | Already capped | Delay 1 while items remain |
| extrema | HIGH | track (6) | 1.35k at 6 (E) | Already per track. Provisional until measured at 6 | Delay 1 while tracks remain |
| model | NORMAL | facet (4) | 0.57k at 4 (90 + 120 per facet; M 0.41k) | Already per facet | 100 ticks after each release (at most once a second); a grant below the facets subscribed to reads the next facets at the next release (framework section 12) |
| navigation service | NORMAL | entry (2) | 0.71k at 2 (E) | Already per entry. Provisional until measured at 2 | Delay 1 while entries remain |
| theme read | NORMAL | theme file | 10.0k | **Flag.** Chunk the parse like `tokenizeChunk` | Delay 1 while chunks remain |
| header finalize | NORMAL | 1 | 5.1k | **Flag.** Split per field | Delay 1 |
| header | NORMAL | panel | 3.6k at 16 panels | Grows with panels: grant per panel | Delay 1 |
| panel item parse | NORMAL | item | 3.6k | **Flag.** Not capped by item length: cap per config key | Delay 1 |
| tokenize | NORMAL | line chunk | 2.3k | Already chunked | Delay 1 |
| panel build | NORMAL | panel | 3.1k-10.4k (M); declared 3.5k-11.5k | **Flag.** Every panel but host-diagnostics (3.1k, within the limit) exceeds 4.0k. Build the skeleton, then add children from `refresh` as `output` does for rows; the panel must be safe to draw half built | Delay 1 |
| reflow | NORMAL | 1 panel (not 2) | 3.7k (M about 3.3k) | Within the limit; grant one panel per call | Delay 1 |
| services stage, retire page | NORMAL | module / page | 1.0k / 1.3k | None | Delay 1 |
| app rebuild, editor, settings UI, log viewer, menu, fullscreen input | NORMAL | n/a | none | **Flag.** Unmeasured (U): stay on the current static path until measured | n/a |

Load and rebuild tasks run in staged-load callbacks, so their atoms are packed
against the lighter staged-load overhead.

## Decisions needed

1. **Telemetry rate.** With Smart off, 8 recorded sources every callback
   leaves no room for `HIGH` work. Allow a source to be polled every second
   callback (worst call about 5.5k), or lower the cap, or accept `HIGH`
   tolerance 1 being missed in that case? Recommend the first, if the
   recording rate allows it.
2. **Ceiling.** Keep 15000 until a hardware run shows zero near-misses, or
   plan to raise it? Recommend keep.
3. **Margin factors.** Accept `F` of 1.25 / 1.10, `A` of 100 / 50 and `Mmin`
   of 400, or tighten after a hardware pass?
4. **Lump limit.** Accept 4000 declared per atom, which sets how many tasks
   need a split?
5. **Unmeasured UI tasks.** Keep them on the current path outside the budget
   (recommended), or measure them before Phase 3?
6. **Entries per source per call.** Cap telemetry recording at one history
   entry per source per call?
