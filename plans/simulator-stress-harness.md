# Simulator stress harness plan

Status: proposed; this document does not authorize implementation.

## Goal

Find reproducible AeroGrid lifecycle failures in the real EdgeTX simulator,
especially `luaRef()` failures and exhausted Lua instruction budgets. Exercise
dashboard setup, panel editing, saving, screen transitions, and radio restarts.
The two reported failures are motivating symptoms, not diagnosed root causes.

## Approach and boundaries

Build on the native TX16S Companion tooling in `tools/capture-native.cpp`,
`tools/video-native.cpp`, and their Python runners. Initially target macOS and
TX16S, but make the simulator library selectable. The primary reproduction
target must match the failing radio's firmware revision, local patches, and
effective instruction budgets; the installed Companion version is not enough.
Stock 2.12 is an optional comparison, not a substitute for that target.

Record firmware commit, patch/build identity, build flags, architecture, library
hash, and effective budgets for script loading, App/regular widgets, background,
and native LVGL callbacks. Verify whether the build actually enforces limits;
Debug and Release can differ. If the original build cannot be identified or
recreated, label results as comparative coverage, not reproduction evidence.

Make AeroGrid source selection an independent run dimension: accept a revision
or branch, resolve it to an immutable commit, and record any dirty-source patch
and the prepared source hash. For scheduler builds, also select and record the
effective scheduler mode where supported. Do not assume main contains the
scheduler migration or that every revision supports legacy/mixed modes.
Reproduce the user's actual AeroGrid build first; compare other revisions/modes
using the same firmware, input plan, sensor stream, and initial SD snapshot.
Verify scheduler deferral behavior: low instruction usage is not a success if
work is deferred indefinitely. Track task/dashboard progress alongside budget
headroom, including when remaining room becomes negative.

Drive real firmware touch, key, and rotary input where the simulator supports it.
Do not substitute direct editor function calls for the interactions under test:
native input dispatch and LVGL callback lifetimes are part of the coverage.
Prepare starting dashboards on disk; also include a workflow that creates and
configures a dashboard through the firmware UI. Resolve semantic targets
(panel tile, drawer row, button) to current visible geometry before dispatching
real input. Prefer a test-only target/state export for AeroGrid controls and a
versioned firmware adapter for native controls. Missing, hidden, ambiguous, or
stale targets are checkpoint divergences, not permission to guess coordinates.

Use lightweight, test-only state observation if logs and screenshots cannot
reliably confirm progress. Instrument only the disposable SD image, never the
release or normal simulator image. Do not disable instruction limits, force
garbage collection, or change scheduling to make runs pass. Observation inside
Lua callbacks adds instruction cost; establish that overhead before relying on
results near the budget limit.

This is a correctness and lifecycle harness with resource-pressure diagnostics,
not a general performance profiler. Simulator results do not prove radio timing,
hardware memory stability, or support for other radios. Production fixes are
separate work after reproducing and diagnosing a failure.

## Coverage

| Area | Scenarios |
| --- | --- |
| Starting dashboards | Empty, typical mixed panels, dense grids, multiple charts, and full-size channel output. |
| Dashboard setup | Create a screen, select App mode, install AeroGrid, select layout and theme. |
| Panel editing | Add every production catalog type; change settings; move, resize, remove, save, and discard. |
| Nested settings | Metric/chart entries and state conditions; add/remove entries and change sources. |
| Transitions | Repeated editor/drawer entry and exit, picker cancellation, RTN immediately after a setting change, fullscreen/App return, dashboard switching. |
| In-process teardown | Model switch away/back, widget removal/recreation, screen add/remove, and layout/theme option changes. Confirm which paths actually unload Lua, retire widgets, or only rebuild a page. |
| Persistence | Save, restart in a fresh simulator process, and verify loaded settings and geometry. Discard must leave committed settings unchanged. Test safe in-process simulator stop/start separately if supported. |
| Sustained activity | Changing sticks/switches and firmware-level synthetic telemetry while panels refresh; alternate active and hidden dashboards. |
| Resource pressure | Repeated equivalent open/edit/close cycles, chart history/recording under load, Lua heap pressure, and LVGL allocator usage/fragmentation. |

Use valid settings, supported spans, and available grid positions for the
positive-path suite. Deliberately invalid input belongs in separately identified
negative tests with explicit expected outcomes, not a blanket error allowlist.
Physical receiver/protocol fidelity is outside the initial scope; synthetic
sensor-driven load through the real firmware telemetry APIs is required.

## Resource and load fidelity

Compare the simulator's Lua allocator cap and LVGL allocator configuration with
the failing radio. Record differences, including host pointer/object sizes:
matching a configured cap does not make native memory consumption identical.
Do not silently remove caps or raise instruction budgets. If limits differ,
identify what can be tested faithfully and what still needs the matching radio.

Collect Lua memory using `collectgarbage("count")` where supported, and LVGL
used/peak bytes, largest free block, and fragmentation via a verified
`lv_mem_monitor` ABI. The capture runner already uses that monitor after
shutdown; live sampling needs a safe firmware-thread checkpoint or appropriate
synchronization, not unsynchronized reads from the driver thread. Associate
samples with action boundaries and periodic steady-state checkpoints, including
before/after teardown and each boot. Do not compare fresh-process baselines as
though they were one continuously leaking heap.

Warm up first, then compare repeated equivalent lifecycle cycles. Record
persistent growth and reduced free-space headroom; distinguish normal caches
and natural GC sawtooth behavior from retained growth. Establish explicit
growth/headroom thresholds from baseline measurements before making them gates.
Suspected leaks remain reported even if no crash occurs. Do not force GC during
the normal workload; any forced-GC diagnostic is a separately labeled run.

Feed reproducible sensor values through firmware-level `setTelemetryValue` or
the simulator's telemetry injection interface, with real configured sensors,
units, precision, and update cadence. Include changing values, loss/recovery,
multiple chart series, and sufficient simulated flight state/history to exercise
recording. Verify that sources resolve, panels receive fresh samples, and
history actually grows; a visible but idle chart is not load coverage.

Before designing new instruction instrumentation, evaluate the scheduler
branches' `tools/audit-scheduler.py` and `tools/audit-native.cpp`; use
`thomaskistler/scheduler-audit-builder` as a starting reference and pin the
available audit revision. Evaluate its `hook-check` validation against
`getUsage()` and its legacy/mixed comparison support. These tools are not in the
current main-based checkout. Record whether to adopt or adapt them, with a
specific reason for any rejection (for example firmware incompatibility,
incomplete callback coverage, or changed execution semantics). Revalidate
counters and overhead on the selected firmware/AeroGrid combination; historical
validation alone is not sufficient. Prefer reuse to a parallel counter.

Capture a per-refresh instruction/near-limit signal using the chosen audit
mechanism, verified `getUsage()` semantics, or a justified alternative. Establish
whether the signal covers widget work, LVGL property callbacks, or an
aggregate/previous refresh; never label a
percentage as an exact instruction count without that evidence. Report peak
usage and callbacks above a declared warning threshold (initial proposal: 80%
of the applicable enforced allowance), independently of hard-limit failures.
Measure observation/telemetry-generator overhead against an unobserved baseline
and identify its budget scope. If extra diagnostic firmware is necessary,
identify it separately and confirm failures on the matching reproduction build.

## Delivery phases

Each phase delivers usable tooling and includes focused tests for what it adds.
Later phases extend the earlier deliverables; they do not postpone usability or
testing until the end. Firmware/AeroGrid selection, isolation, and reporting
start in Phase 1 and remain available throughout. These phases deliver the
harness, not production fixes.

### 1. Native runner and failure capture

**Deliverables**

- A command-line runner that boots a selected simulator library and AeroGrid
  revision with a disposable SD image, executes a simple input script, captures
  the display/output, and shuts down or times out safely.
- A failure detector and machine-readable run report with build identity,
  exit status, last confirmed progress, logs, screenshots, and preserved SD state.
- A separate detector self-test suite with deliberate failures and explicit
  reporting of any detector that could not be verified end to end.
- A baseline/reproduction report: outcomes for the two reported failures,
  resource/budget fidelity, observation overhead, and the decision to reuse,
  adapt, or reject the existing scheduler instruction-audit tooling.

At this point, a developer can run a simple scripted reproduction and collect
evidence. The runner does not yet provide the complete AeroGrid workflow suite.

**Implementation and checks**

Capture what the user was doing immediately before each failure, the exact error
text/photo if available, radio/firmware build, AeroGrid commit/branch and
scheduler mode if present, dashboard configuration, and saved SD state. Attempt
those workflows directly on the matching simulator before broadening into
random testing. Unknown details stay
unknown; do not infer installed patches or an allocation failure from `luaRef()`
alone.

Establish reliable boot, input, display capture, orderly shutdown, and startup
from an isolated SD image. Give each simulator process and action a deadline.
On timeout, stop only the process owned by that run and preserve its artifacts.

Verify these independent failure signals for each supported firmware build:

| Signal | Required observation |
| --- | --- |
| Firmware trace | Actual build-specific messages, including `ERROR in`, `CPU limit`, `Script killed`, panic, `not enough memory`, Lua shutdown, and `luaRef()` failure where present. |
| Visible script failure | Native script-error overlay/state, including an error while the process remains alive. Do not rely solely on text logs or a screenshot saved for humans. |
| AeroGrid failure | Logged errors, `context.errors`, rejected/failed panels, and editor/preview/save errors, including hidden widgets. |
| Native failure | Exit status, abort/signal, and crash diagnostics when available. |
| Lost progress | Heartbeat stall, failed postcondition, or action/process deadline expiry. A driver heartbeat alone does not prove widget progress. |
| Resource warning | Declared heap-growth/headroom and instruction near-limit thresholds. |

Use controlled fixtures to demonstrate every failure detector, including
instruction exhaustion, an on-screen script error, a caught AeroGrid error, Lua
memory exhaustion, a stopped widget heartbeat, and a native-aborted runner.
Distinguish end-to-end injected faults from parser tests using recorded logs.
Add a bounded deliberate retained-reference/leak or registry-allocation failure
fixture if feasible; report any untested ref-specific detector explicitly.
Expected faults run separately from the healthy suite.

Do not assume every error reaches stdout or that absence of a particular string
means a firmware path cannot fail. Resolve unobservable required signals before
calling the harness a reliable gate. Establish resource/budget fidelity and
observation overhead in this phase.

**Acceptance:** firmware/build identity and limitations are recorded, a healthy baseline
passes, injected failures exit nonzero, and a live simulator displaying an error
or ignoring input cannot pass as healthy. Record whether either original
failure reproduced; failure to reproduce does not block broader exploration.

### 2. Fixed regression suite

**Deliverables**

- A reusable real-input action layer with semantic target resolution, readiness
  checks, postcondition assertions, and distinct teardown/restart operations.
- Individually runnable, named workflows covering the coverage table: dashboard
  setup, every catalog panel, nested settings, geometry, save/discard,
  cancellation, screen/model transitions, in-process teardown, and persistence.
- A reproducible firmware-level telemetry workload plus Lua/LVGL memory and
  instruction-usage observations associated with workflow checkpoints.
- A fixed-suite command and per-workflow results showing what actually
  completed, which assertions passed, and resource warnings/failures.

This is the first broadly useful AeroGrid stress harness: a developer can run
one workflow, such as configure a chart and exit fullscreen, or the whole suite.

**Implementation and checks**

Implement a small action vocabulary: tap, hold, drag, key/rotary input, wait for
state, verify, and explicit fresh-process versus in-process restart/teardown.
Wait for readiness rather than relying solely on fixed sleeps. Verify
transitions after release and settling; include purposeful early dismissal as
its own scenario. Re-resolve targets after each UI-changing action.

Start with one complete workflow: empty dashboard, enter editor, add/configure a
panel, move/resize, save, restart, and verify. Then add the coverage table above.
Discover panel types from the production catalog rather than maintaining a
second list that can silently fall behind.

Check actual postconditions: editor/drawer visibility, selected panel type,
panel count, changed values, completed preview/save, and continued dashboard
updates. Check caught AeroGrid errors and failed/rejected panels as well as
firmware errors. Verify expected progress of active and hidden dashboards under
the synthetic sensor workload.

Persistence checks compare expected configuration and geometry with what the
freshly booted widget loaded, not merely file existence or a screenshot.
Fresh-process restart proves persistence, not in-process lifetime safety.
Exercise the normal firmware teardown paths without directly calling internal
shutdown functions; verify which lifecycle boundary each action crossed.

**Acceptance:** each catalog type completes an editing workflow; setup, cancellation,
multi-dashboard navigation, in-process teardown, sensor-driven load, and
fresh-process restart checks have explicit assertions.

### 3. Seeded exploration and replay

**Deliverables**

- A seeded generator that composes valid actions from the observed state, with
  configurable action/time bounds and required minimum coverage.
- A runnable exploration command that varies panel types, settings, geometry,
  transitions, and timings without replacing real firmware input.
- A saved replay bundle containing the initial SD snapshot, source/build
  identity, generated plan, sensor stream, and actual input/state timeline.
- A replay command with checkpoint validation and bounded retry support,
  reporting divergence and reproduced/attempted counts.
- Coverage results distinguishing attempted actions from verified transitions,
  with the seed, host-load context, and last confirmed state for each failure.

At this point, a developer can explore varied editing sessions and replay a
failure without manually reconstructing the session.

**Implementation and checks**

Choose eligible actions from the confirmed current state. Randomize panel
selection, valid settings, geometry, action ordering, hold durations, and pauses.
Keep prerequisite chains intact: create/select a panel before configuring it.

Bias scenarios toward callback lifecycle boundaries and expensive transitions,
including setting-then-RTN, repeated dialog replacement, preview rebuilds,
save/reload, and active/hidden dashboard changes. Keep a minimum set of required
workflows so a random run cannot miss an entire category and still claim it was
covered.

Record the seed, generated plan, actual dispatched inputs and resolved targets,
observed states, sensor stream, and timings. Firmware threads run in real time:
record host CPU count, load and process CPU usage, plus campaign concurrency.
Run soaks serially by default; any parallel campaign needs an explicit limit and
separate SD images/process ownership.

Replay against state checkpoints; do not promise bit-for-bit determinism from a
seed when scheduling can vary. Report divergence rather than continuing with
stale coordinates. For a failure that does not repeat, retry from the same
initial snapshot with a declared bounded count (proposed default: three replay
attempts) and report reproduced/attempted counts. Preserve the original failure;
unsuccessful retries neither erase it nor prove it was a harness problem.

**Acceptance:** repeating a saved plan exercises the same intended transitions, failures
identify the last confirmed state and pending action, and coverage reports
distinguish attempted actions from successfully verified actions.

### 4. Soak runner and everyday tooling

**Deliverables**

- Documented smoke, regression, and soak commands built on the existing runner,
  fixed workflows, generator, and replay support.
- A bounded campaign runner with serial execution by default, repeated
  in-process teardown and fresh-process restarts, and safe interruption.
- Artifact retention controls that bound successful-run storage while
  preserving failure evidence, plus a consolidated campaign report with
  coverage, resource trends, restart counts, and unambiguous exit status.
- A published fixed regression seed set and a consolidated harness test command
  that runs without Companion; native simulator campaigns remain opt-in.
- Developer documentation for prerequisites, run/replay usage, result
  interpretation, artifact locations, and known limitations.

At this point, a developer can run a short check or a bounded hour/overnight
campaign without supervising individual simulator sessions.

**Implementation and checks**

Provide three explicit run modes with configurable time/action limits:

| Mode | Purpose |
| --- | --- |
| Smoke | A short fixed workflow, including a restart, for harness development. |
| Regression | Fixed scenarios plus a small published seed set, covering every panel type. |
| Soak | A bounded, longer seed campaign with repeated editing, screen changes, and restarts. |

Proposed initial soak acceptance: one hour of active workload, all required
coverage completed, at least ten successful fresh-process restarts and ten
in-process teardown cycles, and no unexpected errors, stalls, persistence
mismatches, or calibrated resource-gate failures. Record startup/wait time
separately so an idle or repeatedly rebooting simulator cannot satisfy the soak.
Calibrate smoke/regression duration after the baseline; a timeout, unavailable
required detector, or incomplete coverage is not a pass.

Consolidate the tests added in each phase for plan generation, input/state
validation, replay, timeout cleanup, error detection, and reporting, and add
campaign/retention tests without requiring Companion. Keep native runs opt-in
initially; CI integration is later work if a suitable runner exists.
Document prerequisites, run/replay commands, artifact locations, and limitations
in the developer simulator/testing guide.

**Acceptance:** documented commands produce an unambiguous exit status and report, and a
failed run remains inspectable after the simulator process exits.

## Failure artifacts and triage

Each run gets a new directory containing its plan, source/build identity,
simulator library identity and architecture, logs, action/state timeline, latest
screenshot, resource/budget samples, host-load/concurrency context, result
summary, and disposable SD image. Preserve the initial replay snapshot and
committed state at restart boundaries so later writes cannot erase the evidence.
Bound artifact growth during successful soaks; never silently overwrite a failed
run.

A run manifest binds the resolved AeroGrid revision/source patch and effective
scheduler mode to the firmware build, audit-tool revision, and observation
method. Reports separate results by those dimensions rather than combining
different scheduling/budget configurations into one pass rate.

A report distinguishes product failures, harness failures, replay divergence,
and incomplete runs. Record the operation and boot number, expected versus
observed state, detector coverage, configured thresholds, replay command, and
retry outcomes. Do not diagnose a root cause from an error string alone.

First reproduce with the same sources and simulator. Then shorten the sequence
manually while preserving prerequisites, and add the resulting regression at the
appropriate test layer. Automatic sequence reduction, broader radio/OS coverage,
and abrupt power-loss testing are follow-ups, not initial delivery requirements.

## Firmware investigation references

These are related proposals, not evidence that the failing radio included them.
Check actual commits and build flags rather than relying on PR state or number.

- [EdgeTX/edgetx#7973](https://github.com/EdgeTX/edgetx/pull/7973):
  different App-mode instruction allowances and budget enforcement.
- [EdgeTX/edgetx#7974](https://github.com/EdgeTX/edgetx/pull/7974) and
  [EdgeTX/edgetx#7984](https://github.com/EdgeTX/edgetx/pull/7984):
  Lua/LVGL lifetimes and replaced callback references.
- [EdgeTX/edgetx#8004](https://github.com/EdgeTX/edgetx/pull/8004) and
  [EdgeTX/edgetx#8007](https://github.com/EdgeTX/edgetx/pull/8007):
  widget activity after Lua shutdown and refresh of closed dialogs.
