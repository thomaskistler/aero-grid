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

| Span | Clock | Supporting row | Progress bar |
| --- | --- | --- | --- |
| `1x1` | `SMLSIZE` | no | no |
| `2x1`, `3x1` | `SMLSIZE` | **asked for, refused** | no |
| `4x1` | `SMLSIZE` | **asked for, refused** | yes |
| `1x2` | `MIDSIZE` | yes | no |
| `2x2`, `3x2`, `4x2` | `DBLSIZE` | yes | yes |

**A single row never carries the supporting row**, whatever its width. The
layout asks for one from two cells upward, and a one-row panel has no space
beneath the clock, so the shared ladder refuses it. Nothing is reported; the
row simply is not drawn.

The progress bar is a countdown's own fraction of its start value. **A
count-up timer has no total, so it never draws one** even on a panel that
grants it.

### What the supporting row says

| Timer | Row |
| --- | --- |
| a countdown, running | `OF 5:00` — its start value |
| a countdown, past zero | `ELAPSED PAST ZERO` |
| a count-up timer | `COUNTING UP` |
| no timer configured | `NO TIMER` |

**`ELAPSED PAST ZERO` does not fit a single-column panel.** At `1x2` the row
is 125 px of a 105 px content box. It is sized to the string rather than to
the box, so it does not wrap — it is centred and overhangs ten pixels at each
side, starting two pixels outside the panel's own left edge, over whatever is
next to it.

Unlike the other components with supporting rows, this one offers **one
wording per state and no shorter form**, so there is nothing to shed when the
row is too narrow. Keep this component two cells wide if a countdown of yours
can run past zero.

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

## Why the clock is smaller than it looks like it could be

The panel is sized for `-88:88:88` — a countdown more than ten hours past
zero. That is the widest reading the format can produce, and a clock has no
shorter form: dropping a field turns `1:02:34` into `2:34`, which is a
different time rather than an abbreviation. So the widest case is the only
case, and every panel is sized for it.

At `1x2` that costs a size. `DBLSIZE` fits the band's height with room to
spare — 40 px of 50 — and is refused because `-88:88:88` needs 126 px of the
105 available. A real reading there is `2:05`, which needs 76. Even an hour
counted up, `1:02:34`, needs only 101 and would fit.

Everywhere else the band's height decides the font and the sizing string
costs nothing.

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
