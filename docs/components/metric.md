# `metric`

Displays one to three independently configured numeric EdgeTX sources.
The first reading is the headline; the other two are supporting readings.
Sensor minimum and maximum readings are ordinary sources, such as `GAlt-`
and `GAlt+`. The panel does not derive measurements or convert units.

## Readings

Configure an ordered `metrics` list with one to three entries:

| Entry key | Default | Meaning |
| --- | --- | --- |
| `source` | required | Exact, case-sensitive numeric EdgeTX source name. |
| `label` | source name | Panel heading for the first entry; caption for supporting entries. |
| `unit` | sensor unit | Display-unit override. An explicit empty string hides the unit. No numerical conversion is performed. |
| `precision` | sensor precision | Fixed decimal places, an integer from 0 to 3. |

Each entry resolves its unit and precision independently. A missing reading
shows `--` without a unit. Supporting readings include their captions,
for example `MAX 180 m` or `VS 2.5 m/s`.

## Panel settings

| Key | Default | Meaning |
| --- | --- | --- |
| `metrics` | absent | Ordered list of one to three numeric readings. |
| `accent` | `cyan` | Normal accent: `cyan`, `green`, `amber`, or `orange`. |
| `visual` | `bar` | `bar`, `radial`, or `none`. |
| `rangeMin` / `rangeMax` | `0` / `100` | Primary values corresponding to empty/full visualization when no preset supplies a range. |
| `warning` / `critical` | none | Thresholds in the primary source's numerical units. |
| `direction` | `auto` | `rising`, `falling`, or `auto`. Auto infers falling only when both thresholds are present and critical is below warning. |
| `preset` | `custom` | Legacy `custom`, `altitude`, or `speed` defaults; optional when using a metrics list. |

The bar or radial follows only the primary value. Its fraction is bounded
to 0–1; the numerical reading is not clamped to the configured range.
Normal visuals use the configured accent; alarm and stale states use the
shared state color.

Threshold comparisons include the boundary. Critical takes priority over
warning. Use explicit `direction` when configuring a single threshold, or
when the intended direction should not depend on threshold ordering.
No thresholds are supplied by default. Supporting readings do not trigger
primary alarms.

## Layout

Supported spans are `1x1` through `4x1` and `1x2` through `4x2`.
The shared panel builder chooses the supporting arrangement:

1. A footer if its height and text widths fit. One supporting reading is
   centered; two use the left and right slots.
2. Otherwise, a right-hand stack beside the primary reading, if the group fits.
3. Otherwise, both supporting readings are hidden and the primary remains centered
   unless a surviving radial occupies the right slot.

Supporting readings never shrink the primary font. A radial that survives
its own fit has priority over the right slot and prevents the side-stack
fallback. A bottom bar does not occupy that slot.
The arrangement is reconsidered when the zone, supporting text, or resolved
primary unit changes.

A normal `2x2` can show the footer; a normal `2x1` can show the right-hand stack.
A `1x1` normally retains only the primary reading and state badge.
Available geometry, not the span name alone, determines whether supporting
readings fit. Units and visuals also shed where necessary.

## States and freshness

| Condition | Presentation |
| --- | --- |
| Live primary, no crossed thresholds | Value and normal accent. |
| Primary crosses warning or critical | `WARN` or `CRIT` badge and state color. |
| Primary becomes stale | Last value retained, `STALE` badge and muted presentation. |
| Primary unavailable | `--`, `N/A` badge, no unit beside the sentinel. |
| Supporting source unavailable | Its caption followed by `--`, without a unit. |
| Supporting source stale | Last value retained; it does not change the primary state. |

Freshness follows the shared telemetry service. EdgeTX numeric sensors do not
expose reliable individual reception ages through Lua. Source discovery and
telemetry-link evidence determine availability; valid zero is a reading while
the link is live. Real-radio verification remains necessary.

## Existing configurations

Without `metrics`, the original settings remain supported:

| Key | Meaning |
| --- | --- |
| `source`, `label`, `unit`, `precision` | Primary reading. Precision `-1` follows the sensor. |
| `extrema` | `none`, EdgeTX `source`, or existing flight-session `flight` tracking. |
| `extremaMode` | `min` or `max`; defaults to `max`. |
| `extremaSource` | Explicit sensor-extreme source; otherwise source mode uses the primary's `-` or `+` suffix. |
| `secondarySource`, `secondaryLabel` | Additional footer reading; its own sensor supplies units and precision. |

The altitude preset supplies `Alt`, heading `ALT`, green accent, range 0–400,
source MAX, and secondary `VSpd` labelled `VS`. Speed supplies `GSpd`,
heading `SPD`, cyan accent, range 0–200, and source MAX. Custom supplies
heading `METRIC`, cyan accent, no extrema, and a bar.
Explicit nonempty legacy settings override preset defaults. With no extrema,
the legacy footer shows the configured range.

When `metrics` is present, its entries replace the legacy primary, extrema,
and secondary settings. Panel-level visual, range, accent, and threshold
settings still apply. The metrics list has no flight-session tracking option.

## Examples

Altitude, EdgeTX maximum, and vertical speed:

```yaml
- id: altitude
  type: metric
  col: 0
  row: 0
  colSpan: 2
  rowSpan: 2
  config:
    metrics:
      - source: GAlt
        label: ALT
        unit: m
        precision: 0
      - source: GAlt+
        label: MAX
        unit: m
        precision: 0
      - source: VSpd
        label: VS
        unit: m/s
        precision: 1
    accent: green
    rangeMin: 0
    rangeMax: 400
    direction: rising
    warning: 300
    critical: 400
```

Compact voltage with independently configured current and altitude readings:

```yaml
- id: power
  type: metric
  col: 0
  row: 1
  colSpan: 2
  rowSpan: 1
  config:
    metrics:
      - source: RxBt
        label: VOLTAGE
        precision: 1
      - source: Curr
        label: CUR
        precision: 1
      - source: GAlt
        label: ALT
        precision: 0
    visual: none
    direction: falling
    warning: 22
    critical: 20
```

Use thresholds appropriate to the actual source. `RxBt` may measure a
regulated receiver supply rather than the flight pack.
