# `cell-battery`

Displays an aircraft battery from either a **cells monitor** or a **pack-voltage
source**, such as `RxBt`. The source must actually measure the battery:
regulated receiver supply voltage does not reveal the flight pack's voltage.

The headline always shows two decimals. This is display precision, not a
promise of sensor accuracy or resolution. No remaining-capacity percentage is
inferred from voltage.

## Pack-voltage source

Set `sourceType: pack` and configure `cells` to the actual series cell count,
an integer from 1 to 16. The count is never guessed from voltage.

```yaml
- id: flight-pack
  type: cell-battery
  col: 0
  row: 0
  colSpan: 2
  rowSpan: 2
  config:
    source: RxBt
    sourceType: pack
    cells: 4
    reading: pack
```

`reading: pack` puts total voltage on the main line, with cell count and
average cell voltage underneath. `reading: average` reverses the two voltages:
average on the main line, cell count and pack voltage underneath.

The average is pack voltage divided by configured cell count. **It is not a
measured individual cell voltage and cannot detect imbalance or a weak cell.**
`reading: lowest` and `lowestSource` are therefore rejected for a pack source.
Warning and critical thresholds remain **volts per cell**, judged against
the derived average in pack mode.

Source names are **case-sensitive**. Use the source's exact EdgeTX lookup name rather than
assuming its on-screen capitalization is the lookup name.

For example, a four-cell pack at 16.80 V shows `16.80` as the headline,
`4S` on the left below it, and `4.20V AVG` on the right. With
`reading: average`, the headline becomes `4.20` and the supporting voltage
becomes `16.8V PACK`, or `16.8V` when the longer form does not fit.

## Cells-monitor source

The default is `sourceType: cells`. Configure
`source: Cels` to receive a table of individual voltages. The default headline
is the lowest valid cell; `reading: average` or `reading: pack` are also
available. Thresholds judge the lowest cell regardless of headline.
`lowestSource: Cels-` optionally supplies the lowest-cell reading independently.

`cells: 0` follows the measured count. A positive `cells` setting describes the
expected count, and a mismatch is shown in the count row rather than replacing
the measured count.

```yaml
- id: monitored-pack
  type: cell-battery
  col: 0
  row: 0
  colSpan: 2
  rowSpan: 2
  config:
    source: Cels
    sourceType: cells
    lowestSource: Cels-
    reading: lowest
    cells: 4
```

Omit `lowestSource` to use the lowest valid entry of the cells table.
An explicit lowest-cell source can still supply the lowest-cell headline
when the table is unavailable; it cannot supply a measured count or pack sum.

## Settings

| Setting | Default | Meaning |
| --- | --- | --- |
| `source` | `Cels` | Exact EdgeTX source name. A cells table in `cells` mode; a numeric voltage in `pack` mode. |
| `sourceType` | `cells` | `cells` or `pack`. The shape is explicit, never guessed from the value. |
| `reading` | `lowest` | `lowest`, `average`, or `pack` for a cells monitor; `average` or `pack` for a pack source. Pack mode must override the default. |
| `lowestSource` | empty | Optional independent numeric lowest-cell source, only in cells mode. |
| `cells` | `0` | In cells mode, `0` uses the measured count; a positive value specifies an expected count. In pack mode, a configured integer from 1 to 16 is mandatory. |
| `showCount` | `true` | Show measured count for a cells monitor, configured count for a pack source. |
| `showPack` | `true` | Show supporting pack voltage; when pack voltage leads, show average cell voltage instead. |
| `visual` | `battery` | `battery`, `bar`, or `none`. The upright battery sits beside the reading. Its fill measures voltage against the usable per-cell range, not remaining charge. |
| `cellEmpty` / `cellFull` | `3.3` / `4.2` | Usable range in volts per cell. |
| `warning` / `critical` | `3.5` / `3.3` | Low-voltage thresholds in volts per cell. |
| `label` / `accent` | `PACK` / `cyan` | Heading and semantic accent. |

Accent choices are `cyan`, `green`, `amber`, and `orange`. Unknown settings
are rejected at load. Pack mode also rejects a missing or invalid count,
`reading: lowest`, and a nonempty `lowestSource`.

## Battery glyph and responsive layout

Supported spans are `1x1`, `2x1`, `3x1`, `4x1`, `1x2`, `2x2`, `3x2`,
and `4x2`. A single grid cell shows the headline without a visualization
or supporting row. Larger spans may show the visualization if it fits.
Supporting rows normally require a two-row panel. With `visual: none`,
one-row panels at least two columns wide can instead place the count above
the supporting voltage in a stack to the right of the large headline.
The shared builder uses a footer when it fits, then a side stack, then hides
supporting text rather than shrinking the headline. Disabled supporting
items do not reserve an empty stack row.
The glyph uses the same shape, state color, and font-dependent outline as
`tx-battery`. It is shed when it cannot fit without shrinking the reading,
and hidden when no valid voltage is available.

The upright glyph fills from the bottom over `cellEmpty` to `cellFull`,
clamped to empty/full outside that range. Its outline, terminal, and fill
all take the state color. The fill follows the selected headline: lowest
or average cell voltage for those readings, pack voltage divided by count
for a pack headline. Warning thresholds still use the worst cell in cells
mode, even when the fill follows an average.

`visual: battery` draws no bottom progress bar. `visual: bar` explicitly
selects a bottom track instead, and `visual: none` draws neither.
The equal-gap and 30% whitespace rules below apply to the battery glyph,
not the bar or visualization-free arrangement.

The battery body's horizontal layout reserves the widest reading plus `V`
and the preferred glyph width. If the remaining padded content width is less
than **30% of the full panel width**, it drops `V` without changing the font.
At exactly 30%, `V` stays. This threshold is checked before shrinking the
preferred glyph; it is not 30% for each individual gap.
It then divides the remaining content width into three gaps: left margin,
space between reading and glyph, and right margin. Outer margins are equal;
integer rounding goes into the middle gap. Each gap is at least four pixels.
The glyph shrinks or is shed if the remaining gaps would be below that minimum.
The unit decision uses the widest supported reading, not the live voltage.
The live number and unit center together within the fixed reading block, so
voltage changes do not move the glyph. Supporting rows keep their 30%/70% slots.
This rule applies to `cell-battery`, not `tx-battery`.
The whole glyph, including its terminal, is vertically centered on the
number's digit bounds decoded from the EdgeTX font descriptors, rather than
assuming the entire ascent is ink, within half a pixel for
integer-coordinate rounding. Alignment follows the displayed digits and is
recomputed on reflow.
Explicitly requesting `showCount: true` or `showPack: true` on a one-row panel
requires `visual: none` and `colSpan` of at least 2; otherwise it is rejected.
For example, use `colSpan: 2`, `rowSpan: 1`, `visual: none`,
`showCount: true`, and `showPack: true` for a compact text-only battery panel.
Narrow rows shed text that cannot fit. Missing data shows `--`
without a unit, and stale telemetry retains the last reading with a stale badge.

## Thresholds and unavailable data

Thresholds are always **volts per cell**, including when total pack voltage
is the headline. In cells mode, an explicit `lowestSource` is used when
available, otherwise the lowest valid table entry. In pack mode, only the
derived average can be judged. `critical` is checked before `warning`.
The usable fill range and alarm thresholds are separate settings.

| State | Condition | Presentation |
| --- | --- | --- |
| `normal` | Valid, fresh voltage above the warning threshold | Reading and battery in their normal colors. |
| `warning` | Judged cell voltage at or below `warning` | Amber state color, tinted panel, `WARN` badge. |
| `critical` | Judged cell voltage at or below `critical` | Red state color, tinted panel, `CRIT` badge. |
| `stale` | A retained reading whose source is stale | Last voltage retained, muted presentation, `STALE` badge. |
| `unavailable` | No usable headline | `--`, no unit or battery glyph, `N/A` badge. |

When a supporting row is available, an empty cells table shows `NO CELLS`;
a numeric source incorrectly used as a cells monitor, or an unusable table,
shows `CELLS ERR`. Invalid pack voltage shows `VOLT ERR`. A source that has
not delivered data leaves the count row blank.

Cells tables are summarized from valid entries; a configured count mismatch
can show `3S OF 4`, then `3S/4`, then just `3S` as width decreases.
This reports the measured count rather than inventing a missing cell.
Supporting text that cannot fit is shed.

## See also

- [`tx-battery`](tx-battery.md) measures the transmitter's own battery,
  independently of aircraft telemetry.
