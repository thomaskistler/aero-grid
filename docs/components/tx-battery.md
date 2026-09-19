# `tx-battery`

Shows the **transmitter's own** battery voltage — the pack inside the radio in
your hands, not anything on the aircraft.

The reading comes from EdgeTX's `tx-voltage` source, which is the radio's
measured pack voltage (`MIXSRC_TX_VOLTAGE`, "Transmitter battery voltage
[volts]"). It needs no telemetry and no link: the panel reads correctly on a
bench with nothing bound. For the aircraft's pack, use `cell-battery`.

**Voltage is the only thing this panel actually knows.** The bar and the
percentage are estimates, and they only appear once you tell the panel what
empty and full mean for your radio — see below, because this is the single
thing most likely to surprise you.

## Settings

| Key | Type | Default | Values | What it does |
| --- | --- | --- | --- | --- |
| `label` | string | `TX` | any text | The panel's heading. Two characters, because `TX BATTERY` needs ten and a single-cell header has room for about five. |
| `accent` | string | `cyan` | `cyan`, `green`, `amber`, `orange` | The stripe down the left edge. Cyan because the palette reserves it for electrical data, and this is a battery. |
| `packEmpty` | number | *none* | volts | The whole-pack voltage you consider empty. **No default** — see below. |
| `packFull` | number | *none* | volts | The whole-pack voltage you consider full. **No default.** |
| `warning` | number | *none* | volts | At or below this, the panel goes `warning`. |
| `critical` | number | *none* | volts | At or below this, the panel goes `critical`. |
| `direction` | string | `falling` | `falling` | Which way the thresholds count. A battery only ever gets worse downward, so there is nothing else to choose. |
| `visual` | string | `bar` | `bar`, `none` | Whether the estimate is drawn as a bar. |
| `showPercent` | boolean | `false` | `true`, `false` | Whether the estimate is also written as a percentage. |

Anything else is rejected at load with the layout, panel and key named.

## The range is what switches everything else on

**Without `packEmpty` and `packFull`, there is no bar and no percentage,
however you set `visual` and `showPercent`.**

That is deliberate rather than an oversight. Battery chemistry and cell count
vary by radio — a 2S LiPo, a 1S Li-ion, six AA cells — and EdgeTX does not
tell Lua which one you have. A panel that guessed would draw a confident
percentage derived from nothing, on the one reading that decides whether you
are about to lose control of the aircraft.

So the estimate is off until you state the range, and the voltage is shown
either way:

| `packEmpty`/`packFull` | `visual` | `showPercent` | What you get |
| --- | --- | --- | --- |
| not stated | `bar` | `true` | **Voltage only.** Both switches are ignored. |
| not stated | anything | anything | **Voltage only.** |
| stated | `bar` | `false` | Voltage and a bar |
| stated | `bar` | `true` | Voltage, a bar, and `72% EST` |
| stated | `none` | `true` | Voltage and `72% EST`, no bar |
| stated | `none` | `false` | Voltage only, by choice |

`packFull` must be greater than `packEmpty`; if it is not, the range counts as
unstated.

The percentage is labelled `EST` on screen, because it is an estimate of a
rough linear fit and not a measurement. A LiPo's discharge curve is nothing
like a straight line, so treat the number as an indication of headroom rather
than a fuel gauge.

### Choosing the numbers

The defaults in the shipped layouts are for a **2S LiPo**: `packEmpty: 6.6`,
`packFull: 8.4`. If your radio has a different pack, these are wrong for you.

| Pack | Empty | Full |
| --- | --- | --- |
| 2S LiPo / Li-ion | 6.6 | 8.4 |
| 1S Li-ion | 3.3 | 4.2 |
| 6 x AA NiMH | 6.0 | 8.4 |

Set `warning` and `critical` from the same numbers. A useful starting point is
`warning` around 15% and `critical` around 5% of your stated range — for a 2S
pack, about 6.9 V and 6.7 V.

## What it draws, and what it sheds

| Span | Panel | Reading | Bar | Percentage |
| --- | --- | --- | --- | --- |
| `1x1` | 117 x 65 | `MIDSIZE` `7.9V` | shed | shed |
| `2x1` | 238 x 65 | `MIDSIZE` `7.9V` | shown | shed |
| `3x1` | 359 x 65 | `MIDSIZE` `7.9V` | shown | shed |
| `4x1` | 480 x 65 | `MIDSIZE` `7.9V` | shown | shed |
| `1x2` | 117 x 134 | `DBLSIZE` `7.9` | shown | shown |
| `2x2` | 238 x 134 | `XXLSIZE` `7.9V` | shown | shown |
| `3x2` | 359 x 134 | `XXLSIZE` `7.9V` | shown | shown |
| `4x2` | 480 x 134 | `XXLSIZE` `7.9V` | shown | shown |

**No single-row panel shows the percentage**, however wide it is:
`showPercent: true` on a `4x1` is as inert as on a `1x1`, because the
percentage needs a row beneath the reading and no 65-pixel panel has one. A
single cell shows neither the percentage nor the bar.

**At `1x2` the reading drops the `V`.** That is the one place the panel is
narrow enough to need the space, and the unit is safe to drop because the
heading already says this is a battery. The digits are never dropped: `7.9`
and `7.9V` are the same reading, where `8` would be a different one.

The voltage itself is always shown, at every span and in every state.

## States

| State | When | What you see |
| --- | --- | --- |
| `normal` | A voltage above `warning`, or no thresholds stated | The voltage in the reading colour, no badge |
| `warning` | Voltage at or below `warning` | Amber accent, tinted panel, `WARN` badge |
| `critical` | Voltage at or below `critical` | Red accent, tinted panel, `CRIT` badge |
| `stale` | The radio stopped answering; the last voltage is kept | Muted reading, `STALE` badge |
| `unavailable` | No voltage has ever been read | `--` and an `N/A` badge |

`critical` is tested before `warning`, so if you set them the wrong way round
— `critical` above `warning` — the panel goes straight to critical and the
warning band never appears.

## Resolution

EdgeTX stores this voltage in units of 100 mV and hands Lua the value scaled
by 0.1, so **0.1 V is the finest step the radio can report** and the panel
shows exactly one decimal. A reading that appears to sit still between 7.9 and
8.0 is the hardware's resolution, not a rounding choice here. The same storage
caps the reading at 25.5 V, which is above any transmitter pack.

## Example

```yaml
- id: tx
  type: tx-battery
  col: 0
  row: 0
  colSpan: 2
  rowSpan: 2
  config:
    label: TX
    accent: cyan
    packEmpty: 6.6
    packFull: 8.4
    warning: 6.9
    critical: 6.7
    visual: bar
    showPercent: true
```

A 2S pack, two cells square, so the voltage reads at `XXLSIZE` with a bar and
a percentage beneath it. Drop `packEmpty` and `packFull` and you get the
voltage alone, whatever the last two lines say.

## See also

- `review-tx-battery` is a shipped layout that puts this panel at six spans
  and in three states on one screen, including a ranged and an unranged panel
  side by side, which is the quickest way to see the table above.
- `cell-battery` is the equivalent for the aircraft's pack, read per cell over
  telemetry.
