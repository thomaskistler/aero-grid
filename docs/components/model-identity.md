# `model-identity`

Shows which model is loaded: its name, the picture you assigned it, or both.

## Read this first: what it costs to have a long model name

This is the only panel whose reading is **text you chose** rather than a
number. Everything else on the dashboard draws digits, and digits are narrow
and all the same width. A model name can be fifteen characters of capitals,
and capitals are nearly twice as wide.

**The panel is sized for a name shorter than the one EdgeTX lets you set.**
It picks its font from three imagined widths — fifteen, ten and six characters
— takes the largest font at which one of them fits, and then draws your actual
name at that size whatever length it is. So a name longer than the width it
settled on is drawn wider than the panel, centred, and overhangs both edges.

| Span | Longest all-capitals name that fits |
| --- | --- |
| `1x1`, `1x2` | 9 characters |
| `2x1` | 11 characters |
| `3x1`, `4x1` | 15 characters |
| `2x2`, `2x3` | 8 characters |
| `3x2` | 7 characters |
| `4x2`, `4x4` | 10 characters |

Lower-case is narrower and gets you several more characters; `Test Model` fits
everywhere. `QUADCOPTER RACE` fits nowhere except `3x1` and `4x1`, and at
`2x2` it reaches 26 px past the left edge of the panel and 27 px past the
right — over whatever is next to it.

**Until this is fixed, keep the name short or give the panel a wide, single
row.** `3x1` and `4x1` hold the longest name EdgeTX will store.

## Settings

| Key | Type | Default | Values | What it does |
| --- | --- | --- | --- | --- |
| `presentation` | string | `auto` | `auto`, `name`, `image`, `both` | Which arrangement to draw. `auto` shows the name alone on a panel smaller than four cells and adds the picture above it on anything larger. |
| `label` | string | `MODEL` | any text | The panel's heading. |
| `accent` | string | `cyan` | `cyan`, `green`, `amber`, `orange` | The stripe down the left edge. |
| `showLabels` | boolean | `false` | `true`, `false` | Adds a supporting row listing the model's configured labels. **Needs a panel two rows tall**; on a single row it is refused at load with the panel named. |

Anything else is rejected at load with the layout, panel and key named.

## What it draws

`auto` is a rule about area rather than about shape: four cells or more gets a
picture, less than four gets the name by itself. `2x2` and `4x1` are both four
cells wide in total but only the first is four *cells*, so `4x1` shows the name
alone.

Asking for a picture does not guarantee one. The panel gives the picture
whatever height is left after the heading, the name and the labels row have
taken theirs, and **drops it entirely below 24 px** rather than drawing a
slot too thin to recognise. On a two-row panel with both the name and the
labels row that threshold is reached easily, so `showLabels: true` on a small
panel is a way of losing the picture.

### Where the name sits

With no picture the name sits directly beneath the heading. With a picture it
sits on the panel's floor and the picture takes the space above it.

Neither position is the one every other panel on the dashboard uses, which is
to centre the reading in the middle half of the panel. This component is the
only one that does not do that, and on a tall panel it is visible: at `4x4`
with no picture the name sits 83 px above where the shared rule would put it,
hard under the heading with the rest of the panel empty beneath it.

### How the picture is scaled

**The picture is scaled to cover the frame and the overflow is cropped.** It
is not fitted inside the frame, and its shape is not preserved by shrinking it
— whichever of the two dimensions needs more magnification decides the zoom
for both, and the excess on the other is cut off.

That matters because the frames are wide and short:

| Span | Picture frame | What a 4:3 photo keeps |
| --- | --- | --- |
| `2x2` | 226 x 56 | 33% of its height |
| `2x3` | 226 x 117 | 69% of its height |
| `4x4` | 468 x 148 | 42% of its height |
| `4x2` | 468 x 27 | 8% of its height |

A portrait-shaped source loses its top and bottom; a source already wider than
the frame loses its sides. **`2x3` is the span to use if you want to recognise
the picture**, because its frame is closest to square.

## When the picture cannot be drawn

The panel checks that the file is on the card before it creates an image
object, and falls back to showing the name when it is not there. This is
deliberate: EdgeTX's image object clears itself when a file will not decode
and reports nothing back, so a panel that simply asked for a missing file
would draw an empty hole.

**That check proves the file exists, not that it is a picture.** A file that
is present and not decodable — the wrong format, a truncated download, a text
file renamed — passes the check, so the fallback does not fire. On
`presentation: image` the name is hidden because a picture was asked for, and
the result is a panel that draws nothing at all.

If a panel set to `image` comes up empty, the file is there and is not
readable as an image. Set `presentation` to `both` while you find out, which
keeps the name visible either way.

## States

This panel reaches two of the seven states.

| State | When | What you see |
| --- | --- | --- |
| `normal` | The model's identity is readable, which is whenever the radio is on | The name in the reading colour, no badge |
| `unavailable` | The firmware does not provide the model information call | `--` and an `N/A` badge |

It has no thresholds, so it never reaches `warning` or `critical`, and its
reading comes from the radio rather than from telemetry, so it never goes
`stale`.

## Examples

A single cell, which is the name by itself. Nothing else fits, and this is the
span where a long name overhangs furthest relative to the panel.

```yaml
- id: identity
  type: model-identity
  col: 0
  row: 0
  colSpan: 1
  rowSpan: 1
  config:
    label: MODEL
```

Two cells wide and three tall, which is the span whose picture frame is
closest to square and therefore the one where the picture is least cropped.
The labels row is on, which costs the picture some height.

```yaml
- id: identity-tall
  type: model-identity
  col: 0
  row: 0
  colSpan: 2
  rowSpan: 3
  config:
    label: MODEL
    accent: green
    presentation: both
    showLabels: true
```

A wide single row showing the name alone. This is the arrangement that holds
the longest model name EdgeTX will store without overhanging the panel.

```yaml
- id: identity-wide
  type: model-identity
  col: 0
  row: 0
  colSpan: 4
  rowSpan: 1
  config:
    label: MODEL
    presentation: name
```

## See also

- `review-model-identity` is a shipped layout that puts this panel at several
  spans on one screen, including the two failures above, so they can be looked
  at rather than read about. Set a fifteen-character model name before opening
  it, or the screen shows nothing interesting.
- `flight-mode` has the same shape of problem solved the other way: it reads
  the longest name your model actually has and sizes itself to that, so it
  never overhangs.
