# `link-status`

Shows measured link quality or RSSI, link freshness, and optional RF details.
Link quality is never inferred from RSSI. The panel does not calculate an
aggregate health percentage or issue voice/haptic alerts.

## Settings

| Key | Default | Meaning |
| --- | --- | --- |
| `qualitySource` | empty | Exact link-quality source name, usually receiver-side `RQly` for ELRS. |
| `rssiSource` | `RSSI` | Exact signal-strength source name; ELRS receiver examples use `1RSS`. |
| `reading` | `auto` | `quality`, `rssi`, or `auto`, which prefers available quality and falls back to RSSI. |
| `protocol` | `generic` | `generic` preserves source units and raw RFMD; `elrs4` enables ELRS 4.x rate and nominal sensitivity mapping. |
| `modeSource` | empty | Optional RFMD source. Required for automatic ELRS margin. |
| `snrSource` | empty | Optional signal-to-noise source, usually `RSNR`. |
| `powerSource` | empty | Optional transmit-power source, usually `TPWR`. |
| `qualityWarning` / `qualityCritical` | none | Independent low-LQ thresholds, in percent from 0 to 100. Require `qualitySource`. |
| `marginWarning` / `marginCritical` | none | Low RSSI-margin thresholds, in dB. Require `elrs4`, RSSI, and mode sources. |
| `warning` / `critical` | none | Low thresholds in the primary source's unit. Require explicit `reading: quality` or `reading: rssi`. |
| `barMin` / `barMax` | `0` / `100` | Primary-reading values corresponding to empty/full bar. |
| `visual` | `bar` | `bar` or `none`. |
| `extrema` | `none` | `none`, EdgeTX minimum `source`, or flight-session minimum `flight`. |
| `extremaSource` | empty | Explicit minimum source; otherwise source mode uses the leading source's `-` suffix. |
| `label` | `LINK` | Panel heading. |
| `accent` | `green` | Normal accent: `green`, `cyan`, `amber`, or `orange`. |

Source names are case-sensitive. Unknown settings are rejected at load.
Critical thresholds must be less than or equal to their warning thresholds.
No alarm thresholds are supplied by default.

## Readings and layout

The headline and bar show the selected source's measured value. The normal
bar uses the configured accent; warning, critical, and stale states use the
state color. The bar is not a health score.

Supported spans are `1x1` through `4x1`, `1x2` through `4x2`, and `2x3`
through `4x3`. Supporting information sheds when it cannot fit.

- `1x1` shows the primary reading and state badge.
- ELRS `2x1` with explicit `reading: quality`, RSSI and mode sources places
  large LQ on the left, with smaller RSSI above parenthesized margin on the
  right. The right column sheds if it cannot fit without collision.
- Taller ELRS quality panels without extrema pair RSSI and margin in a
  full-width supporting row, for example `-100dBm (+23dB)`.
- Other supporting rows show the requested minimum or secondary source,
  alongside link status.
- When a second supporting row fits, optional decoded rate, SNR and power
  appear there. Width shortages shed power first, then SNR.

Alarm causes take priority over the paired RSSI reading when space is limited:
for example `LOW MARGIN (+5dB)`. Wider panels retain the full pair and cause.
In the compact side-column presentation, alarms are indicated by panel color
and the shared `WARN`/`CRIT` badge.

## RSSI margin and ELRS modes

**RSSI** measures received signal power in dBm for ELRS. A less-negative
number is stronger. EdgeTX's CRSF RSSI unit is labelled dB; the ELRS profile
renders it as dBm.

**Margin** is the difference between receiver RSSI and the selected mode's
nominal receiver sensitivity. With RSSI at -100 dBm and sensitivity at
-123 dBm, the margin is +23 dB. The difference is measured in **dB**, not
dBm. Negative margin means RSSI is below the nominal sensitivity.
This is estimated signal headroom, not a guaranteed failsafe boundary,
remaining range, or probability of successful reception.

`elrs4` uses the global RFMD enumeration and nominal sensitivity tables
verified in ELRS 4.0.0 and 4.1.0. RFMD is not a frequency in Hz or the
hardware-specific rate-table index. Recognized single-band entries cover
SX127x, SX128x and LR1121 modes. ELRS 3.x RFMD values must not use this mapping.
Unknown/reserved modes are reported explicitly rather than assigned a guessed
rate or sensitivity.

Dual-band rates are recognized but have **no calculated margin**, because
an antenna RSSI value does not identify its band. Missing/stale mode or RSSI,
and RSSI with incompatible units, also withhold margin. Auxiliary stale
readings carry `*`; stale RFMD is not decoded.

Choose receiver/control-side sources such as `RQly`, `1RSS` and `RSNR`,
not transmitter-return telemetry such as `TQly` and `TRSS`. Antenna RSSI
selection is explicit; the panel does not choose the active antenna.

## SNR and power

**SNR** compares the received signal with the receiver's estimated noise
level. +8 dB means signal power is approximately six times noise power.
Positive SNR is generally favorable in LoRa modes, but there is no universal
good/bad cutoff: usable SNR depends on mode, and LoRa can receive at negative
SNR. Some fast modes report zero rather than meaningful SNR.

SNR is informational. It neither modifies measured LQ nor adds an automatic
alarm. LQ shows packet reception; RSSI margin indicates nominal sensitivity
headroom; SNR provides noise context. Interpret them together and watch trends.

Power displays the configured source's measured value and unit. It does not
modify LQ, margin or alarm state.

## States and freshness

The most severe configured **live** threshold condition wins. Comparisons
include the boundary: a value equal to warning or critical triggers that state.
Equal-severity conditions prefer the primary-reading cause, then LQ, then margin.
Link-down takes precedence over threshold alarms.

| Condition | Presentation |
| --- | --- |
| Live readings, no crossed thresholds | Measured value, normal accent. |
| Low LQ, RSSI or margin | `WARN`/`CRIT`, state color, explicit cause where supporting text fits. |
| Link down after receiving data | Last reading retained, critical state, `LINK DOWN` or shorter caption where available. |
| Stale primary source | Last reading retained, `STALE`; an independent live critical/warning condition can take precedence. |
| Source not recognized | `N/A` reading and badge. |
| Source waiting for data | `--` reading and `N/A` badge. |
| Valid zero while live | Measured zero, not an unavailable sentinel. |

Freshness uses the shared telemetry service's link evidence. Numeric sensors
do not expose reliable per-sensor reception age through EdgeTX Lua. A
discovered RFMD sensor reporting zero cannot be distinguished from genuine
ELRS 4.x mode zero. Transmitter-local ELRS RFMD and TPWR are excluded from
receiver-link evidence because they can continue without a connected receiver.
Real-radio verification of telemetry and freshness remains necessary.

## Examples

ELRS quality with automatic margin and optional details:

```yaml
- id: receiver-link
  type: link-status
  col: 0
  row: 0
  colSpan: 2
  rowSpan: 3
  config:
    protocol: elrs4
    reading: quality
    qualitySource: RQly
    rssiSource: 1RSS
    modeSource: RFMD
    snrSource: RSNR
    powerSource: TPWR
```

Compact LQ with RSSI/margin stacked on the right and no bottom bar:

```yaml
- id: compact-link
  type: link-status
  col: 0
  row: 0
  colSpan: 2
  rowSpan: 1
  config:
    protocol: elrs4
    reading: quality
    qualitySource: RQly
    rssiSource: 1RSS
    modeSource: RFMD
    visual: none
```

Generic RSSI with a source-unit bar and EdgeTX minimum:

```yaml
- id: signal
  type: link-status
  col: 0
  row: 0
  colSpan: 2
  rowSpan: 2
  config:
    reading: rssi
    rssiSource: RSSI
    barMin: 0
    barMax: 100
    extrema: source
```

Select alarm thresholds for the actual receiver, protocol, rate and operating
conditions. See [ELRS signal health](https://www.expresslrs.org/info/signal-health/),
the [RFMD enumeration](https://github.com/ExpressLRS/ExpressLRS/blob/4.1.0/src/include/common.h)
and [nominal sensitivity tables](https://github.com/ExpressLRS/ExpressLRS/blob/4.1.0/src/src/common.cpp).
