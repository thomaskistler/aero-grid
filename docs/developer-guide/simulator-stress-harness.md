# Native simulator stress harness

The runner drives the native TX16S Companion simulator with real
touch/key input and a disposable copy of `tests/fixtures/sdcard`. It resolves
the requested AeroGrid revision to a commit and preserves the initial and
final SD images, logs, screenshot, and JSON report under
`build/simulator-stress/`. It does not modify the source checkout or share its
SD image with another simulator.

On macOS, install Xcode command-line tools and EdgeTX Companion. Select the
library explicitly when it is not at the default Companion 2.12 path:

```sh
python3 tools/simulator-runner.py --help
python3 tools/simulator-runner.py \
  --library "/Applications/EdgeTX Companion 2.12.app/Contents/Resources/libedgetx-tx16s-simulator.dylib" \
  --revision main --inputs tests/fixtures/simulator-runner/tap-center.txt --duration 10 \
  --progress-hook
python3 tools/simulator-runner.py \
  --workflow add-move-resize-save-restart
python3 tools/simulator-runner.py --self-test
```

Scripts use 10 ms ticks and ordered lines: `tick touch x y down|up` or
`tick key button down|up`. `tick wait TOKEN timeout_ticks` waits for an
editor-state marker and requires `--progress-hook`; all other actions execute
on their scheduled tick. Touch coordinates use the 480×272 TX16S display; key
buttons are native simulator button IDs. `--progress-hook` instruments only
the copied AeroGrid source with a one-shot marker after a dashboard refresh
with panels loaded, records the first `context.errors` count, and writes editor
state only when it changes. A wait timeout fails the run. The hook does not
assert that a particular input had its intended effect. Use `--expect-file`
for a **different**, scenario-created marker that is written only after the
intended UI postcondition succeeds. A heartbeat alone cannot pass that check.
Without an action postcondition marker, the report is `incomplete` (exit 2),
not a healthy pass. Detected failures exit 1. The
runner handles SIGINT/SIGTERM by releasing a held touch and calling the
simulator shutdown API; a stuck process is force-stopped after a five-second
grace period, and its SD image remains available. `--process-timeout` can set
a shorter wall-clock deadline; otherwise it is the requested duration plus a
15-second startup/shutdown margin.

The first fixed workflow starts from Empty, uses the editor to add and
configure a two-reading Metric panel, moves and resizes it, saves it as a new
layout, then starts a fresh simulator process with that layout selected. The
final assertion reads the layout and geometry loaded by AeroGrid, checks the
two saved metric labels, and requires zero `context.errors`. Its real input
timeline is adapted from the existing editor recipe and gated on panel,
metric, drawer, and geometry postconditions; it takes about 154 simulated
seconds. Before the fresh-process check, it restores the initial `radio.yml`
and `model1.yml` on the disposable SD image, then selects the newly saved
AeroGrid layout. This avoids a stock Companion shutdown-generated radio file
that it rejects on restart while preserving the saved AeroGrid layout.
The report retains those restart-input backups. Each process, input plan,
screenshot, saved SD image, and workflow assertion is recorded in its run
report. Run this command without `--inputs`, `--expect-file`, or
`--progress-hook`; the workflow owns those steps. This is comparative
stock-simulator coverage, not reproduction of the unavailable radio failure.
Other fixed workflows and the full suite are not implemented yet.

When `--revision` resolves to the current checkout's `HEAD`, the prepared
source includes its current AeroGrid working tree. Tracked changes are saved
as `dirty-source.patch`; untracked AeroGrid files and hashes are listed in
the report. Other revisions use the clean committed source archive. Development
layouts are added to the isolated image for either case. The report notes
whether scheduler code was detected; Phase 1 runs the selected source's
existing default and does not switch or verify scheduler modes.

## What the report verifies

The runner records the simulator library hash and architecture, selected
AeroGrid commit and prepared-source hash, input plan, simulator exit/signal,
matched failure-log patterns, screenshot, and LVGL allocator high-water
snapshot when the library exports the known monitor symbol. Firmware commit,
patch/build identity, target architecture, build flags, effective budgets, and
resource caps can be supplied with the corresponding `--firmware-*` options.
The shipped stock Companion library does not establish the failing radio's
firmware identity, budgets, or matching Lua/LVGL caps. Its outcomes are
comparative coverage only. Lua heap and live allocator sampling are not
implemented; LVGL free-space fields are sampled after shutdown, not during the
workload. The optional one-shot progress hook adds one Lua file write after the
first loaded-dashboard refresh; the A/B measurement does not calibrate this
hook's callback cost.

`--measure-observation-overhead` repeats the same plan from a second copy of
the same initial image without per-tick framebuffer copies. One stock-library
comparison measured 7.58 s observed versus 7.20 s unobserved (+5.263% wall
time). This single sample measures only host-side copy cost; it does not
measure Lua callback instrumentation or firmware instruction-budget impact.

`--self-test` is separate from simulator runs. It tests log-pattern parsing,
owned-process abort supervision, a deliberately timed-out child, and the rule
that a heartbeat cannot replace an action postcondition; log samples are parser
tests, not injected firmware failures. The report explicitly leaves
visible script-error state, AeroGrid error/rejected-panel fault injection,
instruction and Lua memory exhaustion, live heartbeat stalls, native simulator
binary aborts, resource thresholds, and `luaRef()`-specific failures
unverified until fault injection and state observation are available on the
selected firmware.

The scheduler audit reference is pinned to
`ed5f17feb1085bb104ea954ccd1a84286686f330` on
`thomaskistler/scheduler-audit-builder`. Its native hook replacement disables
the instruction limit for measurements and patches x86_64 code; its
`hook-check` comparison validates the historical counter against `getUsage()`
at 200-instruction resolution, not on the selected firmware. The pinned
revision has no scheduler-mode selector, so legacy/mixed comparisons were not
run. Phase 1 therefore does not use it as an enforced-budget pass/fail
detector.

## Baseline and reproduction status

No matching radio firmware/build identity, AeroGrid revision, or failing
interaction sequence was provided. The two motivating failures have therefore
not been attempted or reproduced, and no stock-simulator run is reproduction
evidence. The stock run booted AeroGrid, completed a loaded dashboard refresh
with nine panels and zero `context.errors`, and delivered the scripted touch
(`TE_PRESSED`, `TE_RELEASED`, `CLICKED`). It is an incomplete smoke result
because the tap's intended UI effect was not asserted. A deliberate two-second
timeout returned nonzero, called the native shutdown path, and preserved the
SD image/log/screenshot. The installed Companion library is x86_64; its app
version fields are blank. A `passed` report means only that configured checks
succeeded; it is not yet a reliable regression gate. Do not interpret absence
of a log match as proof that a failure path is impossible.
