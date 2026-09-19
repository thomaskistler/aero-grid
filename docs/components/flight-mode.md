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
| `label` | string | `MODE` | any text | The panel's heading. The default is `MODE`; a single-cell header has room for about five characters, so `FLIGHT MODE` needs a wider panel. |
| `accent` | string | `green` | `cyan`, `green`, `amber`, `orange` | The stripe down the left edge. Green is the default because a flight mode is a statement of healthy current state, which is what the palette reserves green for. `cyan` is reserved for electrical readings, so prefer one of the other three. |
| `showIndex` | boolean | `false` | `true`, `false` | Adds a supporting row reading `#<n>`, where `<n>` is EdgeTX's flight mode number. **Needs a panel two rows tall.** On a single-row panel it is refused at load with the panel named, because no single row has space beneath the reading at any width. |

Anything else is rejected at load with the layout, panel and key named.

## What it draws, and what it sheds

The panel always draws its heading and the mode name. The mode number is a
supporting row and is the first thing to go.

**A single row never shows the mode number**, however wide the panel is, so
`showIndex` on any `Nx1` span is refused at load rather than ignored. If you
want the number, give the panel two rows.

### Your longest mode name decides the size

The reading is sized so that **the longest mode name your model has** fits
across the panel. It is never sized from the mode you happen to be in, so
switching modes never resizes anything, and it is never clipped: where a name
cannot fit at one size, the font steps down instead.

That means the size depends on your model, not just on the span. These are the
two ends of it:

| Span | Names up to 4 characters | Names up to 10 characters |
| --- | --- | --- |
| `1x1` | `MIDSIZE` | `SMLSIZE` |
| `2x1`, `3x1`, `4x1` | `MIDSIZE` | `MIDSIZE` |
| `1x2` | `DBLSIZE` | `SMLSIZE` |
| `2x2` | `XXLSIZE` | `MIDSIZE` |
| `3x2` | `XXLSIZE` | `DBLSIZE` |
| `4x2` | `XXLSIZE` | `XXLSIZE` |

An unnamed mode counts as `FM0` through `FM8`, three characters.

So **one long mode name shrinks the reading for all of them**. If a panel looks
smaller than you expected, the usual cause is a single ten-character mode name
you forgot about; shortening it brings every mode up a size. If you want both
the long name and the large font, `4x2` carries ten characters at `XXLSIZE`.

The widths behind this are estimated rather than measured — the Lua API cannot
measure text outside a draw callback — so treat the character counts as close
rather than exact.

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

Two cells square, so the mode number is shown beneath the name as `#1`. With
short mode names the reading is `XXLSIZE` here; a ten-character name anywhere
in the model brings it down to `MIDSIZE`.

## See also

- `review-flight-mode` is a shipped layout that puts this panel at six spans
  on one screen, which is the quickest way to see the table above rather than
  read it.
- `variable-indicator` uses "flight mode" in the same sense: EdgeTX's modes,
  because a global variable holds one value per mode.
