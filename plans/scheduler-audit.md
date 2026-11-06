# Scheduler Audit (Phase 0)

Phase 0 of [scheduler-utilization.md](scheduler-utilization.md). No runtime code
changed; this records what each task costs and whether it can be cut smaller.

Costs are Lua VM **instructions per call**. **M** = measured natively, **E** =
estimated from measured parts (labelled where used), **U** = not measured.
Classes are proposed, not decided (see the plan's open questions).

## Method

- Native EdgeTX Companion 2.12 TX16S simulator, real widget, real services.
  `tools/audit-native.cpp` replaces the firmware's 200-instruction hook with an
  every-instruction counter and does not enforce the 20000 limit, so oversized
  callbacks are measured rather than killed. The counter matches the firmware:
  on 8 known-length callbacks (0 to 9000 loop iterations) `getUsage` equals
  `count / 200` exactly (`hook-check`).
- Per-task costs come from windows around the real functions (service
  `update`, panel `refresh`/`render`/`apply`, chart stages, loader stages).
  Bookkeeping runs with the counter paused. Each window costs about 35
  instructions of probe (10 inside, up to 27 outside). Leaf costs are exact and
  fixed-overhead figures subtract the probe, but a task's total includes about
  35 for every window nested in it (a callback with 10 windows reads about
  0.35k high).
- Each panel runs at its smallest and largest legal span. Every numeric reading
  swings up to 40% on every poll, so panels and recorders always take their
  changed-value path. Chart history was filled to capacity (3 series x 6144
  knots, `HISTORY FULL`) with 20,000+ callbacks on a virtual clock.
- Costs are the worst **observed**, not proven bounds. The time-dependent paths
  vary about 5% between runs. The Lua mock is not used.

Reproduce: `python3 tools/audit-scheduler.py --all --traces`, then `--report`.

## Headline findings

1. **The current static caps can exceed 20000.** `REFRESH_CAP = 6` admits six
   metric panels (about 2.9-4.3k each) in one callback. With 16 metric panels,
   47 of 300 traced callbacks exceeded 20000 (worst 20.5k); a 10-panel mixed layout
   with 30 sources reached 26.2k. Readings that change on every poll are the
   worst case, so this needs hardware confirmation, but a layout can reach it.
2. **Largest single tasks:** chart reading/legend update 7.0k, chart trace
   projection 6.9k, `state` panel build 10.4k, theme read 9.0k.
3. **Fixed overhead is small:** about 0.5k (refresh) and 0.3k (background) with
   one panel, growing about 20 per extra panel.
4. **Services are cheap except telemetry,** about 5.9k as measured (5.5k
   without probe cost) at its 8-source cap.

## Services and flight

Unit = what one grant buys. "Per unit" is the worst cost of one unit including
the recording it triggers. Maxima of different parts come from different calls
and must not be added; telemetry's figures below are from single calls.

| Task | Class | Unit (cap) | Worst at max units | Per unit | Fixed | Bounded | Split |
|---|---|---|---|---|---|---|---|
| telemetry (poll + record) | CRITICAL | source polled (8; 4 with Smart) | Per call, 8 sources: 5.9k worst (M, stress: 6 recorded sources 0.72-0.83k each, 2 unrecorded 0.33k each = 5.15k; precision scan 0.15k; fixed and probe 0.55k). 3 recorded sources: 2.9k (M) | Per source, one call: 0.94k for a recorded source = poll 0.12k + history record 0.73k + loop 0.09k (M). Unrecorded source: 0.33k (M). Use 0.94k as the declared cost; 8 recorded sources would be about 7.9k (E) | Per call: 0.17-0.37k (loop, link publish), plus precision scan up to 0.15k on one source (M) | Yes by cap; recording repeats per history entry on the same source (only one per source measured) | Already per source; resume = a cursor. Do not separate poll from record: the sample time must travel with the reading |
| history | CRITICAL | entry (1) | 0.44k (M) | 17 | 0.38k advance/boundaries (M) | Yes | Single small unit |
| control switches | CRITICAL | switch condition (6) | 0.55k at 6 (M) | 0.08k per condition (M) | 0.07k (M) | Yes | Arm and boundary readers are owned by the separate Armed task; direct Control switch readers stay critical |
| control entries | NORMAL | trim/global-variable/State-switch entry (6) | 1.12k at 6 (M) | 0.21k per entry (M; State switch is lower) | 0.07k (M) | Yes | Natural-unit exception below 2.24k; normal display data |
| control outputs | NORMAL | channel output (32) | 1.69k at 32 (M) | 0.05k per channel (M) | 0.06k (M) | Yes | Output panel sets 10-tick cadence; natural-unit exception below 2.24k |
| flight tick (detection, count, output) | HIGH | 1 tick | 2.8k (M) | n/a | n/a | Yes | Phases (proposals, private services, Smart, advance, output) could be staged; `pumpedAt`/`lastTick` exist. Not needed at 2.8k |
| Smart (inside tick) | HIGH | 1 update (discovery scans 8 sensors per call, then 4 reads) | 2.0k (M) | n/a | n/a | Yes | Discovery already resumable (`self.scan`); steady update splits per sensor read |
| flight first tick (settings document load, attach) | HIGH | 1 load | 2.4k (M, residual of one callback) | n/a | n/a | One-off; grows with the document | Reuse `yaml.tokenizeChunk` as the layout loader does |
| session reset check | HIGH | 1 check | 0.41k (M) | n/a | n/a | Yes | Not needed |
| extrema | HIGH | track (6) | 0.46k at 2 (M); about 1.0k at 6 (E) | 0.16k (M) | 0.09k | Yes | Already per track |
| model | NORMAL | facet (4) | 0.44k at 4 (M) | 0.1k (M) | 0.06k | Yes | Already per facet |
| navigation | NORMAL | entry (2) | 0.36k at 1 (M); about 0.6k at 2 (E) | 0.28k (M) | 0.04k | Yes | Already per entry |
| armed | n/a | none | no scheduled update; read cost sits in readers | n/a | n/a | Yes | n/a |
| reset steps | HIGH | 8 items per call | history 0.07k, extrema 0.01k, navigation 0.01k (M) | n/a | n/a | Yes | Already capped |

## Panel refresh

One refresh = one unit. All are bounded code paths at a given span.
`render` collects values into a reused table; `apply` paints from it. That is a
ready split point: the table survives between callbacks, so resuming costs a
flag. Worth it where `apply` is large.

| Panel | Class | Refresh worst (min span / max span) | render | apply | Split |
|---|---|---|---|---|---|
| metric | NORMAL | 4.3k / 3.7k (relayout `update` 3.7k, rare) | 0.4k | 0.6k | render/apply; relayout by region |
| output | NORMAL | 0.2k / 5.1k | 0.6k | 3.8k | Per row in `apply`; warm-up already one row per callback |
| navigation | NORMAL | 1.1k / 3.3k | 0.2k | 3.0k | render/apply; `apply` per row |
| link-status | NORMAL | 1.2k / 2.2k | 0.9k | 0.9k | render/apply |
| trim-panel | NORMAL | 1.4k / 1.4k | 0.2k | 1.0k | render/apply |
| rx-battery | NORMAL | 1.2k / 1.6k | 0.3k | 1.1k | render/apply |
| tx-battery | NORMAL | 1.0k / 1.1k | 0.1k | 0.9k | Not needed |
| flight-timer | NORMAL | 1.0k / 1.0k | 0.3k | 0.7k | Not needed |
| state | NORMAL | 0.2k / 0.9k | 0.1k | 0.6k | Not needed |
| flight-mode | NORMAL | 0.5k / 0.5k | 14 | 0.3k | Not needed |
| flight-counter | NORMAL | 0.6k / 0.6k | 18 | 0.4k | Not needed |
| model-identity | NORMAL | 0.5k / 0.9k (interval 5 s) | 24 | 0.7k | Not needed |
| host-diagnostics | BACKGROUND | 0.3k / 0.4k | n/a | n/a | Not needed |
| service-probe | BACKGROUND | 0.3k / 0.4k | n/a | n/a | Not needed |
| theme-showcase | BACKGROUND | U | | | Diagnostic only; 4x4 only |

Every panel's `background` hook costs 26 (flight-counter up to 0.16k).

## Chart stages

Largest legal input: 4x4, 3 series, 6144 knots each, 64-flight capacity. A
callback runs at most one stage per chart. "Kind" maps to the plan's callback
kinds. Unit = items per call.

| Stage | Kind | Class | Worst | Unit | Bounded | Split |
|---|---|---|---|---|---|---|
| frame begin (swap and copy fields) | draw | NORMAL | 1.1k | 1 | Yes | Not needed |
| axis | metadata | NORMAL | 0.8k | breaks (already staged) | Yes | Already staged |
| reading text and legend (`render`) | metadata | NORMAL | 7.0k | series (3) | Yes | **Coarse.** Split text setters (per series) from legend geometry recalculation (rare); resume flag `readingGeometry` already exists |
| header, ranges | metadata | NORMAL | 0.19k each | 1 | Yes | Not needed |
| grid | grid | NORMAL | 0.4k | slot (12; 1 or 3 per call) | Yes | Already per slot |
| project | draw | NORMAL | 6.9k | history knot (cap 7-9 per call, up to ~0.75k each) | Yes | **Ready.** `limit` is the grant; job state persists, resume cost about 0.1k (`prepare`) |
| apply runs | draw | NORMAL | 1.1k | run objects | Yes | Already incremental |
| flights | draw | NORMAL | 0.4k | flight slot | Yes | Already per slot |
| arms, resumes | draw | NORMAL | 0.2k each | 1 | Yes | Not needed |
| session reset step | draw | HIGH | 0.9k | staged | Yes | Already staged |

Callback mix: a draw turn also pays a telemetry service update, so a worst
chart callback was 11.0k (7.3k chart + 2.6k telemetry + 0.4k flight tick).

## Loader and lifecycle

| Task | Class | Unit | Worst | Bounded | Split |
|---|---|---|---|---|---|
| theme read | NORMAL | 1 theme file | 9.0k | By theme file size | **Coarse.** Chunk the parse like `tokenizeChunk` |
| header finalize | NORMAL | 1 | 4.6k | Constant | Per field |
| header | NORMAL | 1 | 0.7k at 1 panel, 3.2k at 16 | Grows with panel count | By panel |
| tokenize | NORMAL | line chunk (constant) | 2.0k | Yes | Already chunked |
| panel item parse | NORMAL | 1 panel item | 3.2k | By item length, not capped | Per config key |
| panel validate / migrate | NORMAL | 1 panel | 0.5k / 0.1k | Yes | Not needed |
| panel build | NORMAL | 1 panel | state 10.4k, chart 10.3k, navigation 8.4k, rx-battery 6.9k, link-status 6.7k, metric 6.3k, flight-timer 5.8k, trim 5.6k, flight-counter 5.3k, flight-mode 5.1k, tx-battery 5.0k, model-identity 4.2k, output 4.0k, service-probe 3.5k, host-diagnostics 3.1k | Yes | **Coarse.** Build the skeleton, then add children from `refresh` as `output` already does for rows; the panel must be safe to draw half built |
| services stage | NORMAL | 1 service module | 0.9k | Yes | Already per module |
| reflow | NORMAL | 2 panels per call | 6.7k per call (about 3.3k per panel, metric `update`) | By panel | Only inside the panel's `update` |
| retire / rebuild page | NORMAL | 1 | 1.1k / 0.06k | Yes | Not needed |
| app rebuild (fullscreen exit) | NORMAL | 1 panel | U; expect about the panel's build cost | n/a | n/a |

## Fixed overhead per callback kind

Everything in a callback that is not a task above, including `dispatchDue`,
`updateServices`, flight/reset polling and the per-callback flight identity
check (21).

| Callback | Mean / max | Note |
|---|---|---|
| refresh, steady, 1 panel | 0.5k / 0.57k | 16 panels: 0.84k / 0.92k |
| refresh, steady, 10 panels | 0.67k / 0.83k | about 20 per extra panel |
| background, steady | 0.28k / 0.30k (1 panel); 0.40k / 0.41k (16) | plus 26 per panel `background` |
| refresh during staged load | 0.15k / 0.26k | plus the stage |
| create / update | 2.2k / 33 | once |

## Known limits

- Replay traces stop at 300 callbacks per scenario, so a long run (such as the
  history fill) is represented by its measurement phase only.
- `--report` merges every `results.json` in `build/scheduler-audit`, including
  results from earlier runs; clear the directory before a full run you intend
  to report.

## Not measured

- Interactive UI tasks: editor build and advance, model settings UI, log
  viewer, AeroGrid menu, location details, fullscreen input dispatch. They need
  fullscreen and touch.
- Services below their cap (extrema, navigation): scaled estimates only.
- Hardware. These are instruction counts; C++ time and real-sensor values are
  not covered.

## Traces

`tests/fixtures/scheduler-traces/*.txt` hold per-callback native traces for
replay: `kind|tick|total|overhead|task=cost/units,...`. They come from
`metric-16`, `stress`, `flight-smart`, `session-reset` and `chart-full`.
