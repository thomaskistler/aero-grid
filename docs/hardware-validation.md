# Phase 1 hardware validation

Simulator acceptance is complete for the nine display panels. Physical-radio
validation remains outstanding. Record results separately for TX16S v2,
TX16S v3, TX15, and GX15 running EdgeTX 2.12 or later; do not treat one radio
or protocol as evidence for another.

## Record for each run

Record radio model, EdgeTX version, AeroGrid commit, receiver/protocol and
firmware version, dashboard ID, source names, and any failures. Mark a check
not applicable when the required hardware or sensor is unavailable; do not
mark it passed.

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
- [ ] Confirm all panels remain read-only and do not alter model settings.

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
- [ ] Run Dashboard IDs `host`, `services`, and `services2`; inspect layout path,
  component loading, unresolved sources, normalized readings, and failures.
- [ ] Check missing/corrupt layouts and missing sources produce useful errors
  without disabling unrelated panels.
- [ ] Record instruction use, Lua/bitmap memory, LVGL object count, and refresh
  cost during loading, steady operation, dashboard switching, and reflow.
- [ ] Repeat dashboard switching and resizing long enough to identify growing
  memory or object counts.
- [ ] Establish release budgets from the recorded simulator and radio results,
  retaining headroom below the firmware callback instruction limit.

## Automated mock baseline

`tests/integration/widget/test_resource_stability.lua` exercises six dashboards
(`main`, `review-metric`, `review-navigation`, `host`, `services`, `services2`)
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
