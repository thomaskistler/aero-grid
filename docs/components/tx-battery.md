# `tx-battery`

Shows the **transmitter's own** battery voltage — the pack inside the radio in
your hands, not anything on the aircraft.

The reading comes from EdgeTX's `tx-voltage` source, which is the radio's
measured pack voltage (`MIXSRC_TX_VOLTAGE`, "Transmitter battery voltage
[volts]"). It needs no telemetry and no link: the panel reads correctly on a
bench with nothing bound. For the aircraft's pack, use `cell-battery`.

**Voltage is the only thing this panel measures.** The bar and the percentage
are estimates against a voltage range, and that range comes from your radio's
own battery meter setting, so they work without you configuring anything.

## Settings

| Key | Type | Default | Values | What it does |
| --- | --- | --- | --- | --- |
| `label` | string | `TX` | any text | The panel's heading. The default is `TX`; a single-cell header has room for about five characters, so `TX BATTERY` needs a wider panel. |
| `accent` | string | `cyan` | `cyan`, `green`, `amber`, `orange` | The stripe down the left edge. Cyan because the palette reserves it for electrical data, and this is a battery. |
| `packEmpty` | number | *the radio's* | volts | Overrides the empty end of the radio's battery meter range. |
| `packFull` | number | *the radio's* | volts | Overrides the full end. |
| `warning` | number | *none* | volts | At or below this, the panel goes `warning`. |
| `critical` | number | *none* | volts | At or below this, the panel goes `critical`. |
| `visual` | string | `battery` | `battery`, `bar`, `none` | How the estimate is drawn. See below. |
| `showPercent` | boolean | `false` | `true`, `false` | Whether the estimate is also written as a percentage. |

Anything else is rejected at load with the layout, panel and key named.

## Where the range comes from

**Your radio already knows this, and the panel uses it.** EdgeTX carries a
battery meter range at **SYS → Hardware → Battery meter range**, set to suit
whatever pack your radio has — 6.4 to 8.4 V for a 2S LiPo, 4.6 to 6.0 V for
four alkaline cells. If your battery icon looks sensible, this is already
right, and the bar and percentage work with no configuration at all.

You only need `packEmpty` and `packFull` if you want something different from
what the radio is using — a modified pack, or a dashboard you are writing for
someone else's radio.

**State both or neither.** Half a range is not a range: a stated `packEmpty`
with the radio's `packFull` would measure against two different packs, so a
lone one is ignored and the radio's pair is used. An inverted pair, where
empty is above full, is ignored the same way.

| `packEmpty`/`packFull` | Range used |
| --- | --- |
| neither stated | the radio's |
| both stated, `packFull` above `packEmpty` | yours |
| only one stated | the radio's |
| both stated but inverted | the radio's |
| neither stated, and the radio cannot be asked | **none** — see below |

Changing the range in radio settings takes effect without restarting: the
panel re-reads it, so the percentage follows within a second or so.

### When there is no range at all

On firmware that does not offer `getGeneralSettings`, a panel that states no
range has nothing to measure against. It shows the voltage — which is the
part it actually measures — and draws no bar and no percentage, whatever
`visual` and `showPercent` say.

That is deliberate. A guessed range would put a confident percentage on the
one reading that tells you whether you are about to lose control of the
aircraft.

The percentage is labelled `EST` on screen because it is a linear fit, and a
LiPo's discharge curve is not a straight line. Treat it as an indication of
headroom rather than a fuel gauge.

### Thresholds

`warning` and `critical` are separate from the range and have no defaults,
because what counts as low depends on your pack and on how much margin you
want. They are voltages, and they always count **downward** — a battery only
ever gets worse in one direction, so there is nothing to configure about it.

A useful starting point is about 15% and 5% of your range: for a 2S pack read
against 6.4 to 8.4 V, roughly 6.7 V and 6.5 V.

`critical` is tested before `warning`, so setting them the wrong way round
sends the panel straight to critical and the warning band never appears.

## The battery

By default the estimate is drawn as a **battery**: an outline with a nub, to
the right of the voltage, filled left to right in proportion to the estimate
and coloured by state. A critical pack fills red.

The percentage, where it is shown, sits **beneath the battery**, so the right
of the panel reads as one indicator and the voltage keeps the left to itself.

`visual: bar` draws the older horizontal track across the bottom of the panel
instead, which is worth having on a very wide panel where a small glyph sits
in a lot of empty space. `visual: none` draws neither.

**The battery takes width from the reading.** It is beside the voltage rather
than beneath it, so the voltage is sized against the column that is left. The
rule is that the reading may step down **one** size to make room and no
further; where it would cost two, the panel has told you it is too narrow for
both, and the battery is shed rather than the reading being made unreadable.

In practice this costs one size at exactly one span, `1x2`, and nothing
anywhere else.

## What it draws, and what it sheds

With the default `visual: battery`:

| Span | Panel | Reading | Battery | Percentage |
| --- | --- | --- | --- | --- |
| `1x1` | 117 x 65 | `MIDSIZE` `7.9V` | shed | shed |
| `2x1` | 238 x 65 | `MIDSIZE` `7.9V` | 30 x 15 | shed |
| `3x1` | 359 x 65 | `MIDSIZE` `7.9V` | 30 x 15 | shed |
| `4x1` | 480 x 65 | `MIDSIZE` `7.9V` | 30 x 15 | shed |
| `1x2` | 117 x 134 | `MIDSIZE` `7.9` | 32 x 16 | under the reading |
| `2x2` | 238 x 134 | `XXLSIZE` `7.9` | 60 x 30 | under the battery |
| `3x2` | 359 x 134 | `XXLSIZE` `7.9V` | 60 x 30 | under the battery |
| `4x2` | 480 x 134 | `XXLSIZE` `7.9V` | 60 x 30 | under the battery |

**No single-row panel shows the percentage**, however wide it is:
`showPercent: true` on a `4x1` is as inert as on a `1x1`, because the
percentage needs a row beneath the reading and no 65-pixel panel has one. A
single cell shows neither the percentage nor a visual of any kind.

**At `1x2` the percentage stays under the reading** rather than under the
battery. `72% EST` is 79 pixels at the label font and that panel's battery is
32 wide, so there is nowhere to put it on the right. It also loses the `EST`
before it loses the number, because the column is narrow.

**At `1x2` and `2x2` the reading drops the `V`.** The unit is safe to drop
because the heading already says this is a battery, and the battery beside it
says so again. The digits are never dropped: `7.9` and `7.9V` are the same
reading, where `8` would be a different one.

The voltage itself is always shown, at every span and in every state.

## States

| State | When | What you see |
| --- | --- | --- |
| `normal` | A voltage above `warning`, or no thresholds stated | The voltage in the reading colour, battery fills in the accent, no badge |
| `warning` | Voltage at or below `warning` | Amber accent, tinted panel, amber fill, `WARN` badge |
| `critical` | Voltage at or below `critical` | Red accent, tinted panel, red fill, `CRIT` badge |
| `stale` | The radio stopped answering; the last voltage is kept | Muted reading, `STALE` badge |
| `unavailable` | No voltage has ever been read | `--` and an `N/A` badge |

The battery's **outline** never takes the state colour. It is the container,
the way a bar's track is, and a red outline around a red fill says the same
thing twice. With no range to measure against the whole battery is hidden
rather than drawn empty, because an empty battery is a claim about the pack.

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
    warning: 6.7
    critical: 6.5
    visual: battery
    showPercent: true
```

Two cells square, so the voltage reads at `XXLSIZE` on the left with a battery
to its right and the percentage beneath the battery. No range is stated, so it uses whatever your radio's
battery meter is set to — which is the normal case. Add `packEmpty` and
`packFull` only if you want to override that.

## See also

- `review-tx-battery` is a shipped layout that puts this panel at five spans
  and in three states on one screen, including a healthy and a critical panel
  side by side and a bar next to a battery at the same span, which is the
  quickest way to see the table above.
- `cell-battery` is the equivalent for the aircraft's pack, read per cell over
  telemetry.
