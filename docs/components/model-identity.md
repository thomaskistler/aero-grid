# `model-identity`

Shows which model is loaded: its name, the picture you assigned it, or both.

## Read this first: the picture changes where the name goes

**With a picture, the picture is the panel and the name is its heading.** The
aircraft is what you recognise and the name only says which one it is, so the
picture takes the whole body and the model name moves up to where a panel's
caption normally goes. The `label` you configured is not drawn there, and
setting one on a picture panel is refused at load rather than ignored.

**With no picture, nothing changes:** the name is the reading in the body and
`label` is the heading, as on every other panel.

The two are different treatments of the same string. A heading is
upper-cased, steps its font down to fit, and is **abbreviated** where even
the smallest will not fit — so `QUADCOPTER RACE` becomes `QUADCOP` in a
single cell. A reading is not abbreviated, which is the next section.

## What it costs to have a long model name, with no picture

This is the only panel whose reading is **text you chose** rather than a
number. Everything else on the dashboard draws digits, and digits are narrow
and all the same width. A model name can be fifteen characters of capitals,
and capitals are nearly twice as wide.

**The panel is sized for a name shorter than the one EdgeTX lets you set.**
It picks its font from three imagined widths — fifteen, ten and six characters
— takes the largest font at which one of them fits, and then draws your actual
name at that size whatever length it is. So a name longer than the width it
settled on is drawn wider than the panel, centred, and overhangs both edges.

**This only happens where no picture is drawn.** Give the panel a picture and
the name goes to the heading, which abbreviates rather than overhanging.

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

**Until this is fixed, keep the name short, give the panel a wide single
row, or give it a picture.** `3x1` and `4x1` hold the longest name EdgeTX
will store.

## Settings

| Key | Type | Default | Values | What it does |
| --- | --- | --- | --- | --- |
| `presentation` | string | `auto` | `auto`, `name`, `image`, `both` | Which arrangement to draw. `auto` shows the name alone on a panel smaller than four cells and the picture on anything larger. **`image` and `both` now describe the same panel** — a picture with the name in the heading — because the name no longer shares the body with the picture. Both keys keep working; prefer `image`, which says what you get. |
| `label` | string | `MODEL` | any text | The panel's heading — **only where no picture is drawn**. With a picture the model name takes the heading, so a label set alongside `presentation: image` or `both` is refused at load with the panel named. |
| `accent` | string | `cyan` | `cyan`, `green`, `amber`, `orange` | The stripe down the left edge. |
| `showLabels` | boolean | `false` | `true`, `false` | Adds a supporting row listing the model's configured labels. **Needs a panel two rows tall**; on a single row it is refused at load with the panel named. |

Anything else is rejected at load with the layout, panel and key named.

## What it draws

`auto` is a rule about area rather than about shape: four cells or more gets a
picture, less than four gets the name by itself. `2x2` and `4x1` are both four
cells wide in total but only the first is four *cells*, so `4x1` shows the name
alone.

Asking for a picture does not guarantee one. The panel gives the picture
whatever height is left after the heading and the labels row have taken
theirs, and **drops it entirely below 24 px** rather than drawing a slot too
thin to recognise. The name no longer takes a slice first, so this threshold
is reached far less often than it was: every span this component supports
keeps its picture, at every placement but one. The exception is a one-row
panel in the grid's top-left cell in App mode, where EdgeTX's menu button
pushes the content down and leaves less than 24 px — there the picture is
shed at `1x1`, `2x1`, `3x1` and `4x1` alike, because the button takes height
and a wider panel has no more of it.

### Where the name sits

With a picture, in the heading. With no picture, on the panel's own vertical
centre, the way every other reading on the dashboard is.

It was not always: the name used to be pinned directly under the heading,
which is the panel's content top and not where anything else puts a reading
— 14 px above where it belongs at `2x2`, 49 at `2x3` and 83 at `4x4`, where it read
as stuck to the heading with the panel empty beneath it. This is the one
component whose reading is a name rather than a number, so no cross-panel
comparison ever lined it up against a neighbour and nothing caught it.

### How the picture is scaled

**The whole picture is fitted inside the frame and never cropped.** Whichever
dimension needs the *smaller* magnification decides the zoom for both, so the
picture keeps its shape and the panel shows through at the ends. A picture
smaller than its frame is scaled up to meet it rather than sitting small in
the middle.

An EdgeTX model image is 192 x 114, which is wider in proportion than it is
tall. Whether the height or the width binds depends on the span: a one-row
frame is very wide and very short, so the height binds and the letterbox is
at the sides; a `1x2` frame is narrow and tall, so the width binds and the
letterbox is above and below.

These are the frames in **App mode**, which is what the shipped dashboards
use — every screen on both tracked models is `LayoutId: Layout1x1AM`, and
`layouts/layout1x1AppMode.cpp` registers that id as "App mode". Measured at
a placement the menu button does not reach, which is every cell of the grid
but the top-left one:

| Span | Picture frame | Picture drawn at |
| --- | --- | --- |
| `1x1` … `4x1` | 105–468 x 40 | 67 x 40 |
| `1x2` | 105 x 98 | 105 x 62 |
| `2x2`, `3x2`, `4x2` | 226–468 x 98 | 165 x 98 |
| `2x3` | 226 x 159 | 226 x 134 |
| `3x3`, `4x3` | 347–468 x 159 | 267 x 159 |
| `2x4` | 226 x 219 | 226 x 134 |
| `3x4` | 347 x 219 | 347 x 206 |
| `4x4` | 468 x 219 | 368 x 219 |

In the grid's top-left cell the menu button takes 13 px of the frame's
height at every two-row span, and all of it at every one-row span.

> **This table said Full screen until now, and the figures were Full
> screen's.** It was corrected into that state on the premise that the
> shipped dashboards are ordinary custom screens, which they are not: both
> tracked models carry `Layout1x1AM` on every screen. The premise is the part
> worth remembering — the figures were computed correctly from the wrong
> zone, so nothing about them looked wrong.

A single row gives the picture 40 px of height whatever its width, so a wide
single-row panel is mostly letterbox — it is the arrangement to avoid if the
picture matters. **Two or more rows is where the aircraft is worth looking
at.**

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

Built through the real host, the three cases come out like this. The first and
the third are identical in every decision the panel makes; the only difference
is what is inside the file, which is the one thing it never looks at:

| The bitmap the model names | File check | Image made | Name | What you see |
| --- | --- | --- | --- | --- |
| a real picture | passes | yes | hidden | the picture |
| a file that is not there | fails | no | shown | the model name |
| a file that is not a picture | **passes** | **yes** | **hidden** | **nothing** |

The bitmap comes from the model, so this is a property of the whole screen
rather than of one panel: every `model-identity` on it behaves the same way at
the same time.

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
    accent: green
    presentation: both
    showLabels: true
```

No `label` here, and it would be refused: a panel showing the picture puts
the model name in the heading, so a configured label has nowhere to go.

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
  spans on one screen, so the overhang and the crop can be looked at rather
  than read about. Set a fifteen-character model name before opening it, or
  the screen shows nothing interesting. It cannot show the missing-file or
  unreadable-file cases, because the bitmap belongs to the model rather than
  to a panel and changing it changes every panel at once.
- `flight-mode` has the same shape of problem solved the other way: it reads
  the longest name your model actually has and sizes itself to that, so it
  never overhangs.
