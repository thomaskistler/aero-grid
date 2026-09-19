# `flight-mode`

Shows the flight mode **the transmitter** is currently in, by name.

## Read this first: which flight mode

This is **EdgeTX's own flight mode** — one of the up-to-nine mixer modes
configured on the radio, each with its own trims and rates, usually selected
by a switch, and named in Model Setup. `getFlightMode()` returns the active
mode's index and that configured name, so this panel neither reads switches
nor keeps a mapping of its own. A mode you never named shows as `FM0`, `FM1`
and so on, which is EdgeTX's numbering rather than something this panel
invents.

**It is not the aircraft's flight mode.** In particular it is not:

- arming state, armed or disarmed;
- the flight controller's mode — Angle, Acro, Horizon, Rescue, Launch;
- gyro or stabilisation state;
- anything at all that the aircraft reports.

All of those live on the aircraft and can only reach the radio as telemetry.
This panel needs no telemetry, works with the transmitter on a bench and
nothing bound, and will happily show `ACRO` while the aircraft is in Angle
mode if that is what you called the switch position.

The same term means the same EdgeTX modes in `variable-indicator`, where a
global variable holds a separate value per flight mode. If you are looking for
the aircraft's mode, this is not the panel, and at the time of writing the
catalogue has none.

## Settings

| Key | Type | Default | Values | What it does |
| --- | --- | --- | --- | --- |
| `label` | string | `MODE` | any text | The panel's heading. Four characters, because a single-cell header has room for about five and `FLIGHT MODE` needs eleven. A header too long for its panel is shortened by the shared header rather than overflowing. |
| `accent` | string | `green` | `cyan`, `green`, `amber`, `orange` | The stripe down the left edge. Green is the default because a flight mode is a statement of healthy current state, which is what the palette reserves green for. `cyan` is reserved for electrical readings, so prefer one of the other three. |
| `showIndex` | boolean | `false` | `true`, `false` | Adds a supporting row reading `MODE <n>`, where `<n>` is EdgeTX's flight mode number. Only drawn where there is room for it — see below. |

Anything else is rejected at load with the layout, panel and key named.

## What it draws, and what it sheds

The panel always draws its heading and the mode name. The mode number is a
supporting row and is the first thing to go.

| Span | Panel | Reading | Supporting row |
| --- | --- | --- | --- |
| `1x1` | 117 x 65 | `MIDSIZE` | shed |
| `2x1` | 238 x 65 | `MIDSIZE` | shed |
| `3x1` | 359 x 65 | `MIDSIZE` | shed |
| `4x1` | 480 x 65 | `MIDSIZE` | shed |
| `1x2` | 117 x 134 | `DBLSIZE` | shown |
| `2x2` | 238 x 134 | `XXLSIZE` | shown |
| `3x2` | 359 x 134 | `XXLSIZE` | shown |
| `4x2` | 480 x 134 | `XXLSIZE` | shown |

**A single row never shows the mode number**, however wide the panel is.
`showIndex: true` on any `Nx1` panel changes nothing you can see. If you want
the number, give the panel two rows.

The reading's size comes from the panel, not from the mode you are in, so
switching modes never resizes anything.

### Long names are clipped rather than shrunk

A flight mode name can be up to ten characters. The reading's size is chosen
from the room available, and the name is then drawn at that size whether or
not it fits across the panel. Where it does not, the overrun is cut off at the
panel edge.

| Span | Room for | A ten-character name |
| --- | --- | --- |
| `1x1` | ~6 characters | clipped |
| `2x1`, `3x1`, `4x1` | 10 characters | fits |
| `1x2` | ~4 characters | clipped |
| `2x2` | ~5 characters | clipped |
| `3x2` | ~8 characters | clipped |
| `4x2` | 10 characters | fits |

The widths behind this are estimated rather than measured — the Lua API cannot
measure text outside a draw callback — so treat the character counts as close
rather than exact.

In practice, if your mode names are short (`NORM`, `SPORT`, `LAUNCH`) any span
is fine. If they are long and you want to read all of them, use `2x1` or wider
on a single row, or `4x2`.

## States

This panel reaches two of the seven states.

| State | When | What you see |
| --- | --- | --- |
| `normal` | EdgeTX reports a flight mode, which is whenever the radio is on | The mode name in the reading colour, no badge |
| `unavailable` | The firmware does not provide `getFlightMode` | `--` and an `N/A` badge |

It has no thresholds, so it never reaches `warning` or `critical`, and its
reading is radio-local rather than telemetry, so it never goes `stale`.
`unavailable` is not reachable by configuration: it needs a radio whose
firmware lacks the call.

## Example

```yaml
- id: mode
  type: flight-mode
  col: 0
  row: 0
  colSpan: 2
  rowSpan: 2
  config:
    label: MODE
    accent: green
    showIndex: true
```

Two cells square, so the mode number is shown beneath the name. Keep the mode
names to about five characters at this span, or move to `4x2`.

## See also

- `review-flight-mode` is a shipped layout that puts this panel at six spans
  on one screen, which is the quickest way to see the table above rather than
  read it.
- `variable-indicator` uses "flight mode" in the same sense: EdgeTX's modes,
  because a global variable holds one value per mode.
