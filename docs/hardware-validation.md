# Phase 1 hardware validation

Simulator acceptance is complete for the nine display panels. **Phase 1 hardware
acceptance is closed by user decision on 2026-10-05**, based on the reported
TX16S v2 dashboard acceptance with EdgeTX 2.12.4 and subsequent testing recorded
below.

The user has no access to other radios. TX16S v3, TX15, and GX15 are **not tested**,
not acceptance blockers and not hardware-validated targets. Additional radio and
protocol coverage and resource characterization are follow-up work, not gates
for this acceptance decision.

Closure does not assert that every procedural check passed. Unrecorded sensor and
protocol cases remain unverified, native LVGL/bitmap resource budgets remain
unestablished. The user confirmed the font-callback memory fix on 2026-10-05;
verification of that fix is closed. Preserve the remaining coverage limits when
describing tested support.

## Record for each run

Record radio model, EdgeTX version, AeroGrid commit, receiver/protocol and
firmware version, dashboard ID, source names, and any failures. Mark a check
not applicable when the required hardware or sensor is unavailable; do not
mark it passed.

### 2026-10-04: TX16S v2, EdgeTX 2.12.4

- Package: AeroGrid `0.10.0`, confirmed on the radio's diagnostics dashboard.
  Installed image built from the software hardening changes merged as
  `a8442ec675c60aa93baaee7ff18928e838e27089`.
- Result: the user reported all recommended dashboards verified on hardware,
  with no issues observed.
- The historical validation covered the main dashboard, nine individual
  display-panel configurations, and host/service diagnostics.
- Receiver/protocol, receiver firmware, source names, and individual test conditions
  were not recorded. This is a user-reported dashboard
  acceptance result, not evidence that every checklist item or protocol passed.
- TX16S v3, TX15, and GX15 remain unverified.

The checkboxes below describe the full validation procedure for future runs,
not an outstanding acceptance to-do list. The aggregate dashboard result and
closure decision do not mark unrecorded individual checks as passed.

### Debug-screen experiment

Three photographs supplied in sequence on 2026-10-04 show the following
radio-wide statistics. Free memory is rounded to decimal MB; the other values
are transcribed as displayed.

| Field | Initial | After first round | After second round |
| --- | --- | --- | --- |
| Free memory | ~2.965 MB | ~2.158 MB | ~2.167 MB |
| Lua duration maximum | 10 ms | 10 ms | 10 ms |
| Lua interval maximum | 340 ms | 430 ms | 430 ms |
| Script | 3721 B | 3721 B | 3721 B |
| Widget | 10315 B | 15975 B | 15893 B |
| Extra | 0 B | 0 B | 0 B |
| Mixer duration maximum | 0.52 ms | 0.54 ms | 0.54 ms |
| Mixer period | 3 ms | 3 ms | 3 ms |
| Minimum free stack: Menu / Mix / Audio | 10668 / 640 / 1236 | 10668 / 640 / 1236 | 10668 / 640 / 1236 |

The first round reduced free memory by approximately 0.81 MB and increased
the Widget field by 5660 B. The second round recovered approximately 9 KB
of free memory, while Widget decreased by 82 B. The later samples do not show
continued memory growth; maximum Lua duration, mixer duration, and stack
statistics also remained stable between those samples.

Initial allocation as additional dashboards are visited is a possible
explanation for the first-round change, not a proven attribution. These are
aggregate radio statistics with other widgets installed, and the Widget field
does not account for the whole free-memory change. Exact workload, elapsed
durations, and counter-reset history were not recorded. Two later samples
support short-run stability, not a long-run leak guarantee or a release budget.
Native LVGL object counts and AeroGrid-specific memory/timing remain unmeasured.

### Aircraft-dashboard experiment after PR #101

The user supplied three further photographs after installing the aircraft
dashboard changes and confirmed that test stages follow photo timestamp order,
not attachment order. This continues testing on TX16S v2 / EdgeTX 2.12.4.
The supplied filenames indicate 2026-10-05 UTC (2026-10-04 locally).

| Field | 00:27:19: aircraft dashboard started | 00:30:26: screen cycling, then a few minutes running | 00:32:58: receiver disconnected/reconnected, then longer running |
| --- | --- | --- | --- |
| Free memory | 3308208 B | 3197200 B | 3183624 B |
| Lua duration maximum | 10 ms | 10 ms | 10 ms |
| Lua interval maximum | 580 ms | 580 ms | 580 ms |
| Script | 3721 B | 3721 B | 3721 B |
| Widget | 81125 B | 81946 B | 83027 B |
| Extra | 0 B | 0 B | 0 B |
| Mixer duration maximum | 0.52 ms | 0.52 ms | 0.52 ms |
| Mixer period | 3 ms | 3 ms | 3 ms |
| Minimum free stack: Menu / Mix / Audio | 10668 / 640 / 1236 | 10668 / 640 / 1236 | 10668 / 640 / 1236 |

Across the approximately 5 minute 39 second photo span, free memory decreased
by 124584 B: 111008 B after screen cycling and another 13576 B after the
disconnect/reconnect stage. Widget increased by 1902 B: 821 B and then
1081 B. Timing maxima and stack minima did not change in the photographs.

These samples show stable reported timing maxima and stack headroom, but
memory has not demonstrably plateaued. Screen activation, telemetry recovery,
allocation, and garbage-collection timing may contribute; these photographs
do not isolate a leak or attribute the radio-wide free-memory change to
AeroGrid. The Widget field does not account for the full decrease.
No counter reset, exact screen sequence, installed commit confirmation, or
post-GC measurement was recorded. Do not compare the Widget totals directly
with the earlier review-dashboard run as if the workload were identical.

The next useful measurement is a warmed-up aircraft dashboard held on the
same screen with the receiver connected, sampled at regular intervals, then
repeated identical screen/reconnect cycles. This separates ongoing idle
growth from first-use allocations and recovery behavior. These observations
do not close the target matrix or establish native release budgets.

### Further run after a radio restart

The user confirmed starting the radio, leaving it running, and cycling
through some widgets in the middle. The exact timing of widget cycling and
receiver state were not specified. Filename timestamps order the five
photographs as follows (2026-10-05 UTC, 2026-10-04 locally):

| Field | 00:43:13 | 00:47:26 | 00:48:43 | 00:49:08 | 00:49:22 |
| --- | --- | --- | --- | --- | --- |
| Free memory | 3769312 B | 3734808 B | 3735208 B | 3625912 B | 3633976 B |
| Widget | 66983 B | 69910 B | 69849 B | 70468 B | 69782 B |
| Lua duration maximum | 10 ms | 10 ms | 10 ms | 10 ms | 10 ms |
| Lua interval maximum | 350 ms | 350 ms | 350 ms | 350 ms | 350 ms |
| Mixer duration maximum | 0.57 ms | 0.57 ms | 0.57 ms | 0.57 ms | 0.57 ms |
| Mixer period | 3 ms | 3 ms | 3 ms | 3 ms | 3 ms |
| Script | 3721 B | 3721 B | 3721 B | 3721 B | 3721 B |
| Extra | 0 B | 0 B | 0 B | 0 B | 0 B |
| Free stack: Menu | 10772 | 10772 | 10772 | 10772 | 10772 |
| Free stack: Mix | 640 | 640 | 640 | 640 | 640 |
| Free stack: Audio | 1120 | 1236 | 1236 | 1236 | 1236 |

Over approximately 6 minutes 8 seconds, free memory decreased by 135336 B
and Widget increased by 2799 B. Neither field grew monotonically: free memory
recovered by 400 B between 00:47:26 and 00:48:43, and by 8064 B between the
last two photographs; Widget peaked at 70468 B and then fell by 686 B.
The largest adjacent free-memory drop was 109296 B between 00:48:43 and
00:49:08; its relationship to widget cycling is not established.

The late Widget samples cluster around 70 KB, which is consistent with
short-run settling and transient allocations, but does not demonstrate a
long-run plateau. Free memory remains lower than at the first sample.
Reported timing maxima were unchanged throughout this run. The Audio stack
figure increased from 1120 to 1236; record that observation without treating
it as a monotonic watermark across the whole sequence.
Because this run follows a radio restart, its counters and allocation
baseline must be kept separate from the earlier 580 ms interval run.
These photographs still do not establish an AeroGrid-specific leak or
memory budget.

### User-reported disconnected-dashboard growth

The user subsequently reported Widget(B) increasing by approximately 1 KB
per minute while the full aircraft dashboard remained displayed, the receiver
was disconnected, and the timer advanced. This was not a timer-only layout,
and Free mem was not being monitored. Exact samples and duration were not
provided. This observation warrants investigation independently of the
earlier mixed screen-cycling workloads.

### 55-minute reduced-dashboard run

The user confirmed the reduced three-panel configuration was the only dashboard, the
receiver was disconnected, and Widget(B) was the observed counter. After
starting the timer and leaving the radio running for 55 minutes, the reported
counter increased from approximately 50 KB to 65 KB. Exact byte values,
intermediate samples, counter-reset history, and collection state were not
recorded. The endpoint difference is approximately 15 KB (30%), averaging
roughly 0.27 KB/minute; two endpoints do not establish a linear growth rate.

This narrows the reproducing configuration to the flight timer, TX battery,
model image, and shared host/services. Receiver telemetry panels, GV panels,
screen cycling, and reconnects are not required for this observed increase.
It does not isolate the timer or distinguish retained allocations from
temporary allocations awaiting firmware garbage collection. The earlier
forced-GC mock test is not a reproduction of this hardware accounting.
Next isolate whether Widget(B) returns toward baseline after the timer stops,
then compare the same duration with the timer panel removed or held constant.

### Non-AeroGrid comparison

The user started a further run with a model that does not use AeroGrid and
reported no apparent leak so far. Duration, Widget(B) endpoints, restart
history, timer activity, and other configured widgets were not supplied.
This is preliminary comparison evidence, not a completed equal-duration
control. Together with the reduced-dashboard result it raises suspicion of
AeroGrid or firmware paths exercised by AeroGrid, without identifying an
owning panel or proving retained-memory leakage.

### Timer start/stop comparison without the model image

Following the proposed image-removal isolation, the user reported Widget(B)
remaining at approximately 49 KB while the timer was stopped. The timer was
started at approximately 19:56 local time on 2026-10-04. At 20:01, Widget(B)
was approximately 51 KB and the user stopped the timer again. The reported
increase is approximately 2 KB over five minutes; readings are rounded.
At approximately 20:07, the user confirmed it remained at 51 KB while the
timer did not advance, approximately five minutes after stopping it.
The exact installed layout and
restart procedure were not independently confirmed.

This strengthens the association with an advancing timer and suggests the
image is not required if removed as planned. It does not yet distinguish
temporary clock-string allocations from retained Lua references or native
label-update allocations. Observe the stopped phase without resetting the
timer or restarting the radio so that reclamation and further growth remain
visible. The stopped interval showed neither further visible growth nor
reclamation at the reported rounded precision. This associates growth with
changing timer values, but stopping allocations can also stop allocation-driven
garbage collection; a stable stopped counter is not proof of retained leakage.

### Font-callback retention found in the update path

Source inspection of EdgeTX v2.12.4 identified a concrete mechanism:
[`LvglParamFuncOrValue::parse`](https://github.com/EdgeTX/edgetx/blob/v2.12.4/radio/src/lua/lua_lvgl_widget.cpp#L69-L78)
registers a supplied function using `luaL_ref` and overwrites the previous
reference without unref'ing it. `LvglTextParams::parseTextParam` uses this
path for `font`. The statistics screen's Widget(B) field calls
`luaGetMemUsed(lsWidgets)`, so it is Lua-widget-state memory, not AeroGrid-only
or total native LVGL memory.

AeroGrid's timer repainted its heading each second using `setHeading`, which
supplied a newly allocated font callback even when the heading/font was
unchanged. Navigation supporting text updates and multiple panel reflow
paths also replaced font callbacks. This retains old closures through the
firmware registry and matches the advancing/stopped timer observation.
It is a verified source-level leak mechanism; its share of the measured
hardware growth still needs a rerun after the fix.

All shared label primitives now install one persistent font callback at
creation. `primitives.setFont` changes a small backing state, without passing
a replacement function to LVGL. Weak object keys avoid keeping retired labels
alive. All panel font updates use this path, including header fitting,
unit resizing, navigation rows, and panel reflow.

The mock now retains replaced font callbacks as EdgeTX does while objects
are live. A regression advances the timer through 3600 seconds, checks
callback identity and zero replaced references, and verifies resize changes
and restores the font through the same callback. A deliberately replaced
callback proves the mock can detect the defect. Resource/reconnect tests
also assert zero replaced font references. For subsequent reproduction runs,
install the complete updated widget folder and restart the radio before
repeating the timer run, since already leaked registry entries are not
recovered by this code change.

The user began a post-fix hardware timer run at approximately 20:19 local
time on 2026-10-04 with Widget(B) approximately 51 KB. At approximately
20:23:54, the user reported that the problem appeared fixed. No exact ending
byte count was supplied. This is short-run user-reported confirmation of
the fix, not a completed long-duration memory plateau or target-matrix
validation.

On 2026-10-05, the user explicitly confirmed that the memory fix has been
verified. The timer-correlated font-callback retention issue is closed.
No additional run duration or counter readings were supplied, so this records
user-confirmed hardware verification without inventing quantitative measurements.

## Display and controls

- [ ] Load the shipped dashboard in App mode and fullscreen; confirm headings,
  values, units, badges, and supporting readings do not overlap the menu button
  or panel edges.
- [ ] Check readability at normal viewing distance in the Modern and Follow
  EdgeTX themes, including warning, critical, stale, and unavailable states.
- [ ] Check model bitmap scaling and fallback when the image is missing.
- [ ] Check compass direction and cardinal clearance across a full rotation.
- [ ] Check radial and bar stability at minimum, maximum, zero, and outside
  their configured ranges.
- [ ] Change flight mode, timer state, trims, and GVs; confirm updates and
  flight-mode inheritance. Verify decimal GVs using explicit metric precision.
- [ ] Enter temporary fullscreen and long-press a panel; verify touch,
  rotary, and key controls are usable at normal viewing distance.
- [ ] Confirm editing shows a gray circular gear at each panel's top-right without a corner X or EDIT button,
  toolbar, selection outline, or grid guides; dragging snaps only to fitting positions.
- [ ] Confirm configuration/catalog drawers scroll and return to the dashboard;
  new draft panels remain preview cards until saving rather than starting trackers.
- [ ] Verify native dialogs are centered and sized like standard EdgeTX dialogs.
  Check touch/rotary focus, toggles, choices, numeric inputs, the native keyboard,
  source/switch/timer pickers, and grouped metric/text entry dialogs.
- [ ] Confirm there is no custom return button and row spacing matches native
  widget settings. Check physical RTN and outside-touch dismissal return one level without
  saving; dismiss a nested picker or keyboard before closing its parent.
  Repeat close/reopen cycles and check memory/object stability.
- [ ] Confirm blocked sizes are hidden, removal is immediate, and invalid
  settings show feedback without overlapping the following row.
- [ ] Add, move, resize, configure, and remove a panel through settings; confirm collision and
  bounds errors are clear and resize keeps the top-left cell fixed.
- [ ] Confirm + appears in the first empty cell and hides on a full grid.
- [ ] Press Return to close drawers, then save and exit; power-cycle/reload and confirm the layout persists
  for the selected model and Dashboard ID.
- [ ] Verify a successful save retains the previous layout as `.bak`; restore
  from a deliberately invalid primary on a test SD card and confirm fallback.
- [ ] Confirm dashboard panels remain read-only and the editor only changes
  AeroGrid layout files, not model settings.
- [ ] On each supported radio/EdgeTX version, verify the file API supports the
  temporary-file write/read/rename/delete sequence used by save-on-exit.
- [ ] Simulate a save failure; confirm the error is visible and the draft remains
  available for retry, including after leaving and re-entering fullscreen.

## Receiver telemetry

Perform link-loss tests on the bench with propulsion disabled.

- [ ] Check discovered sensor names, units, precision, and valid zero readings
  against EdgeTX's own telemetry display.
- [ ] Disconnect and reconnect the receiver; confirm stale values, unavailable
  sources, link-down indication, and recovery without a widget restart.
- [ ] Verify a real cells sensor returns the supported per-cell table shape.
  For pack-voltage mode, confirm the source measures the pack and the configured
  cell count is correct; this mode cannot detect imbalance.
- [ ] Check GPS fix loss/recovery, home availability, distance, and bearing.
- [ ] On ELRS 4.x, verify receiver LQ, RSSI, RFMD, SNR, and power against the
  radio's readings. Confirm RFMD/TPWR alone cannot establish receiver liveness.
- [ ] Exercise a non-ELRS protocol, including a protocol with no RSSI sensor
  if available. Confirm generic link behavior without ELRS margin assumptions.

## Diagnostics and release budgets

- [ ] Confirm the `host` identity section reports package version `0.10.0`.
  Install the complete package and remove stale bytecode before recording results.
- [ ] Run Dashboard ID `host`; inspect layout path, panel loading,
  unresolved sources, and failures. Check readings against the model's sensors.
- [ ] Check missing/corrupt layouts and missing sources produce useful errors
  without disabling unrelated panels.
- [ ] Record instruction use, Lua/bitmap memory, LVGL object count, and refresh
  cost during loading, steady operation, dashboard switching, and reflow.
- [ ] Repeat dashboard switching and resizing long enough to identify growing
  memory or object counts.
- [ ] Establish release budgets from the recorded simulator and radio results,
  retaining headroom below the firmware callback instruction limit.

## Automated mock baseline

`tests/integration/widget/test_aircraft_memory.lua` exercises the real
default aircraft layout for 24240 refresh callbacks, including ten warm-up cycles
and 100 measured receiver loss/recovery cycles. Each cycle changes pack
voltage, altitude/extrema, vertical speed, LQ, RSSI, RFMD, transmitter voltage,
GVs, and timer values before disconnecting. Assertions verify changed
readings arrive, the link shows `NO LINK`, the battery becomes stale, and
the link recovers.

Each checkpoint restores identical inputs, allows service updates to settle,
releases cleared mock inspection objects, and runs full Lua collection
twice. Live object count must remain unchanged; retained growth must stay
below 1 KiB from the warmed baseline and below 256 B across the final
50 cycles. These are regression-test limits, not hardware release budgets.

The initial run in both normal and stripped-string-metatable modes retained
104 live mock objects, with peak and final growth of 256 B and no further
growth across the final 50 cycles. This did not reproduce ongoing retained
Lua growth in the exercised workload. It does not explain the hardware
Widget increase or exclude slower leaks, independent screen-instance
retention, native LVGL/bitmap leaks, or differences in the firmware Lua
allocator and garbage collector.

The same test also holds the aircraft dashboard disconnected while advancing
the timer continuously at five refresh callbacks per simulated second, without
resetting timer values at checkpoints. After six warm-up minutes, it measures
30 simulated minutes with post-GC checkpoints each minute. Initial peak/final
growth was approximately 2 B. The midpoint-to-end change ranged from 0 to
approximately 84 B across targeted and full-suite runs.
Object count remained 104. This did not reproduce the reported 1 KB/minute
Widget(B) increase as retained Lua memory. Forced collection and mock objects
do not reproduce the firmware's normal GC cadence or its Widget accounting.

`tests/integration/widget/test_resource_stability.lua` exercises six dashboards
covering default, metric, navigation, and host/service diagnostic configurations
over 21 rounds, with three sizes per dashboard. After one warm-up round, it
checks 120 reloads and 360 size changes for a stable live object count, no object
allocation during reflow, and collectible retired pages and service registries.
Post-GC Lua memory growth must remain below 16 KiB per dashboard relative to its
warm-up baseline.

The initial run peaked at 167 mock objects and less than 1 KiB retained growth.
The test also prints the slowest dashboard's average refresh CPU time over
1000 callbacks. Timing depends on the development machine and is informational,
not a radio release budget.

The mock explicitly releases cleared objects from its inspection history before
collecting garbage. Its table-based objects and bitmap stand-ins are not native
LVGL objects or decoded images: these measurements do not establish firmware
Lua memory, bitmap memory, LVGL heap use, or physical-radio refresh time.

Phase 1 is not hardware-validated until applicable checks pass on the target
matrix and failures are resolved or explicitly documented as release limitations.
