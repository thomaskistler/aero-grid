# `flight-timer`

Shows one of the radio's own model timers.

## Read this first: the timer is EdgeTX's, not this panel's

AeroGrid does not run a timer. EdgeTX owns the count direction, the start
value, whether the timer counts up or down, whether it survives a power
cycle, its name, and whether it shows elapsed or remaining time — and it
keeps counting whether or not this panel is on screen. The panel reads
`model.getTimer()` and draws what the radio reports.

**So most of what you want is configured in Model Setup → Timers, not here.**
This panel chooses *which* timer, which of its values leads, and when to go
amber or red.

## Settings

| Key | Type | Default | Values | What it does |
| --- | --- | --- | --- | --- |
| `timer` | number | `0` | `0`–`2` | Which model timer, counting from zero. |
| `label` | string | *(empty)* | any text | The panel's heading. **Empty means derive it**: the timer's own configured name, or `TIMER n` if it has none. |
| `accent` | string | `cyan` | `cyan`, `green`, `amber`, `orange` | The stripe down the left edge. |
| `reading` | string | `model` | `model`, `elapsed`, `remaining` | Which of the timer's values leads. `model` follows the pilot's own elapsed/remaining choice on the timer itself. |
| `warning` | number | — | seconds | Go amber at this many seconds. |
| `critical` | number | — | seconds | Go red at this many seconds. |

There is deliberately no direction setting: EdgeTX already says whether a
timer counts up or down, and the panel reads that rather than restating it.

**`warning` and `critical` are compared in the direction the timer runs.** A
countdown becomes critical at or below the threshold — it is running out. A
count-up timer becomes critical at or above it — it has run long. You give
the same number either way and the panel applies it the right way round.

**`reading: remaining` on a count-up timer shows elapsed instead**, because a
timer with no total has nothing remaining. That is silent; nothing refuses it
at load.

## What it draws, and what it sheds

These are the frames in **App mode**, which is what the shipped dashboards
use — every screen on both tracked models is `LayoutId: Layout1x1AM`, and
`layouts/layout1x1AppMode.cpp` registers that id as "App mode". Measured at a
placement the menu button does not reach, which is every cell of the grid but
the top-left one:

| Span | Panel | Clock | Supporting row | Progress bar |
| --- | --- | --- | --- | --- |
| `1x1` | 117 x 65 | `MIDSIZE` | no | no |
| `2x1`, `3x1` | 238–359 x 65 | `MIDSIZE` | **asked for, refused** | no |
| `4x1` | 480 x 65 | `MIDSIZE` | **asked for, refused** | yes |
| `1x2` | 117 x 134 | `DBLSIZE` | yes | no |
| `2x2`, `3x2`, `4x2` | 238–480 x 134 | `XXLSIZE` | yes | yes |

On an ordinary **Full screen** custom screen every panel is shorter, so the
clock is a size smaller at every span but `1x2`: `SMLSIZE` on one row and
`DBLSIZE` on two.

> **This table gave the Full screen figures and called them the only
> figures**, which is the same premise error that put Full-screen crop sizes
> on the `model-identity` page: the shipped dashboards are App mode. The
> figures were right for a zone nobody pages to.

**A single row never carries the supporting row**, whatever its width. The
layout asks for one from two cells upward, and a one-row panel has no space
beneath the clock, so the shared ladder refuses it. Nothing is reported; the
row simply is not drawn.

The progress bar is a countdown's own fraction of its start value. **A
count-up timer has no total, so it never draws one** even on a panel that
grants it.

### What the supporting row says

| Timer | Row | On a one-column panel |
| --- | --- | --- |
| a countdown, running | `OF 5:00` — its start value, **not clamped** | same |
| a countdown, past zero | `ELAPSED PAST ZERO` | `PAST ZERO` |
| a count-up timer | `COUNTING UP` | same |
| a count-up timer asked for `reading: remaining` | `NO COUNTDOWN` | `NO TOTAL` |
| no timer configured | `NO TIMER` | same |

**A row too wide for its panel loses words, not meaning.** A supporting row
is already at the smallest font the dashboard has, so the only thing left to
give up is wording. Each state offers its forms longest first and the panel
takes the longest that fits.

Two states need a shorter form and the other three do not, which is why only
two columns above differ. `ELAPSED PAST ZERO` is 125 px against the 105 px
content box of a `1x2`, the narrowest panel that draws a row at all; the
shorter `PAST ZERO` is 67.

> **This used to overhang rather than shorten.** The row was centred on a box
> wider than the panel, so it started ten pixels outside the left edge and ran
> ten past the right, over whatever was beside it — and a Lua label wraps
> rather than clipping, so it could not simply be cut off. The page said to
> keep the component two cells wide if a countdown of yours can run past zero.
> That advice is no longer needed.

### On a single row there are no words at all

**No one-row panel carries a supporting row, at any width.** That is the
shared ladder's decision and not this component's: a 65 px panel has nothing
beneath the clock. So at `1x1` through `4x1` an expired countdown says what it
can without words — **a minus sign on the clock, a red tint, and a `CRIT`
badge.**

That is deliberate rather than a gap. The minus sign carries the fact and the
badge carries the alarm; the sentence is the elaboration, and the elaboration
is what a panel this size cannot afford. If the distinction between *ninety
seconds left* and *ninety seconds over* is one you need spelled out, give the
panel two rows.

## States

| State | When | What you see |
| --- | --- | --- |
| `normal` | anything not below | the clock, no badge |
| `warning` | past `warning`, in the timer's own direction | amber tint, `WARN` badge |
| `critical` | past `critical`, or a countdown past zero | red tint, `CRIT` badge |
| `unavailable` | the timer is not configured | `--:--` and an `N/A` badge |

**A countdown past zero is always critical**, whatever the thresholds say. It
is the state most easily mistaken for a healthy timer — EdgeTX keeps counting
into negative numbers — so the panel shows a minus sign, turns red and says
so in words.

**On a single-row panel it cannot say so in words**, because there is no
supporting row at any width. At `1x1` an expired countdown is a minus sign
and a red badge and nothing else.

## The clock reads minutes and seconds, and stops at `99:59`

**The minutes field keeps counting rather than growing an hours field.** An
hour and a half is `90:00`, not `1:30:00`. Both name the same duration; only
one of them keeps the same width while you are reading it.

**And the reading stops at `99:59`, or `-99:59` past zero.** A timer set
beyond that shows the clamp rather than the true time.

### What that hides, and why it is worth knowing

EdgeTX's timers run to `TIMER_MAX`, which is `0xffffff/2`
(`radio/src/timers.h:34`) — **8388607 seconds, or 2330 hours** — and
`TIMER_MIN` is its negative. You can set any of that from Model Setup. So the
range this panel folds away is real, it is simply not flyable: anything from
100 minutes upward reads as `99:59`.

**The panel tells on itself wherever it has a supporting row.** The row is
fitted to its own width rather than sized from the clock's form, so it is not
clamped: a countdown of five hours draws `99:59` above `OF 300:00`. On a
single-row panel there is no row at any width, so there the clamp is silent.

**If you fly a timer longer than an hour and forty minutes, this panel is the
wrong instrument for it.** That is a real limitation and it is stated here
rather than discovered.

### Why the clock is no longer smaller than it looks like it could be

The panel used to be sized for `-88:88:88` — a countdown more than ten hours
past zero — and that cost a font size at two spans and produced a defect the
test suite could not see.

At `2x2` in App mode, `-88:88:88` measures 218 px against a 226 px content
box. That is **8 px of margin, 3.5%**, and the test harness models glyph
widths from the one uncompressed font in the EdgeTX tree while the dashboard
draws in bold faces, which are wider on a radio. So the radio measured it as
not fitting and stepped the clock down to `DBLSIZE`; the harness measured it
as fitting and kept `XXLSIZE`. The `3x2` beside it had 129 px of margin and
both agreed. **Two panels of identical height drew their clocks at different
sizes on the radio and at the same size under test.**

With the clamp, the widest string the panel can print is `-99:59` at 146 px,
which is **80 px of margin, 35%**. For that to be wrong a bold face would
have to be 55% wider than the model, where the disagreement happened at 4%.

At `1x2` the old form cost a size outright: `MIDSIZE` where the band's height
allows `DBLSIZE`, because `-88:88:88` needed 126 px of the 105 available.
That span now reads at `DBLSIZE` in both zones.

## Examples

A single cell. The clock and nothing else — no supporting row at this span,
so a countdown past zero shows only its minus sign and badge.

```yaml
- id: flight
  type: flight-timer
  col: 0
  row: 0
  colSpan: 1
  rowSpan: 1
  config:
    timer: 0
    label: FLIGHT
```

Two cells square, which is where everything appears: the largest clock, the
supporting row and the progress bar. Amber at a minute left, red at twenty
seconds.

```yaml
- id: glide
  type: flight-timer
  col: 0
  row: 0
  colSpan: 2
  rowSpan: 2
  config:
    timer: 1
    accent: green
    warning: 60
    critical: 20
```

No `label`, so the heading is the timer's own configured name.

A wide single row showing elapsed time regardless of how the timer itself is
configured.

```yaml
- id: airborne
  type: flight-timer
  col: 0
  row: 0
  colSpan: 4
  rowSpan: 1
  config:
    timer: 0
    label: AIRBORNE
    reading: elapsed
```

## See also

- `review-flight-timer` is slot 3 on the review model. The review model
  configures timer 0 as a countdown already past zero, because a timer's
  state belongs to the model and no layout can produce one.
- `metric` takes thresholds the same way, in the direction its reading runs.
