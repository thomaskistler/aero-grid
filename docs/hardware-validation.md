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

Phase 1 is not hardware-validated until applicable checks pass on the target
matrix and failures are resolved or explicitly documented as release limitations.
