# AeroGrid Design Guide

This document is for someone building a component or a layout, and it answers two
questions: what does the dashboard look like, and why does it look like that. It is
deliberately separate from `aerogrid-spec.md`, which is an architecture document
carrying firmware constraints, fixture discipline and milestone state. Where the two
overlap the specification is authoritative on behaviour and this document is
authoritative on appearance.

It records rejections with the same weight as decisions. Every rejection here cost
real time to establish, and a guide that lists only the winners invites someone to
propose the losers again next month. Several of the entries below were recorded once,
found to be wrong, and corrected; those corrections are called out where they happened,
because a decision that drifted is exactly the kind a guide exists to pin down.

## What is implemented and what is only agreed

**Read this before treating anything below as a description of the dashboard.**

| Area | State |
| --- | --- |
| The panel as a card, accent stripe, alert tints, header geometry, badge vocabulary | Implemented and shipped |
| Colour semantics, the derived palettes, the legibility pass | Implemented and shipped |
| The shared responsive ladder, the abbreviation rule, shedding | Implemented and shipped |
| The battery glyph: vertical, one colour, outline scaled to the reading's font | Implemented and shipped |
| The unit inline beside the reading, placed by measurement | Implemented and shipped |
| Content flow: proportional bands, the band-derived font, the clamp | Implemented and shared by every component |
| Content flow: the two slots and the build-time fallback | Implemented and shared by every component that draws a reading |
| The standard panel assembled in one place (`theme.panel`) | Implemented; **six of the twelve components are on it** |

Both halves of [Content flow](#content-flow) are now live everywhere. The vertical half —
bands, the band-derived font and the clamp — always was, because a font rule applied by
some and not others reintroduces the cross-panel disagreement the shared ladder exists to
remove. The horizontal half was true of `tx-battery` alone when that was written; the slot
rule was then chosen on the radio and every component that draws a reading was converted
to it.

What is only partly done is the **assembly**. `theme.panel` builds the standard
arrangement — heading, reading, optional compact visual, optional supporting row — from a
description of what the panel draws, so that the decisions live in one place instead of
being retyped in each component. Where a component stands:

| | Components |
| --- | --- |
| On `theme.panel` | `cell-battery`, `flight-mode`, `flight-timer`, `link-status`, `metric`, `variable-indicator` |
| Own arrangement, by recorded decision | `navigation`, `tx-battery` |
| Own arrangement, never converted | `model-identity` |
| Exempt: no reading to place | `trim-panel`, `host-diagnostics`, `service-probe` |

`navigation` keeps its own because it draws **two** supporting rows and centres them as a
group, which the builder cannot express; the entry below records what was measured.
`tx-battery` keeps its own for reasons that are now partly obsolete and partly open, also
below. `model-identity` is the one with no argument behind it: it is standard in shape and
was simply never assigned to a conversion stage.

## How to check the numbers in this document

Every figure in the [Content flow](#content-flow) section is produced by
`tools/flow-render.py` from real geometry — panels built through the actual widget
host, with objects walked back out of the LVGL mock — rather than typed in from
memory. Run:

```
make mocks
```

which writes `build/flow-mocks.html`. Each figure quoted here appears there, computed
rather than asserted. This matters because hand-typed figures in this project have
drifted three times: a slack count written as 10/8/6 when the real one was 10/9/5, an
occupancy range written as 60–71% when it was 60–63%, and a caption asserting "the
ladder has nothing between 40 and 69 px" on panels where that was not the reason. All
three were corrected by computing the figure in the generator instead. **Do not add a
number to this document that the generator cannot produce.**

Figures outside that section come from the test suite and from EdgeTX's own font
tables, and are cited where they appear.

---

## The panel

### A panel is a card

Deepened canvas, lifted surface, an 8 px corner radius, and **no outline at rest**. The
4–6 px radius originally specified reads as a square panel with the corners shaved at
480 x 272; the softer corner is what the reference design has. Nested cards are
prohibited — a component spanning several cells stays one coherent panel and must not
imitate several unrelated ones unless its data model genuinely contains repeated items.

The accent is a full-height stripe down the panel's leading edge with rounded outer
corners, built as a straight rectangle and two quarter-circle arcs inside a clipping
container one accent-width wide. Each corner arc is centred on the panel's corner
centre with the panel's radius and a thickness of the accent width, so its outer edge
is exactly the curve the panel's own fill is rounded by, and the container removes
everything beyond the accent width.

**Rejected: the tapered pill.** The accent was built as a pill on the strength of a
comment asserting that LVGL clamps a corner radius to half the shorter side. Nobody had
checked, and the submodule the claim would have to be checked against was uninitialised
at the time. It was removed during the presentation pass. The lesson generalised into
the specification's fixture discipline: LVGL's behaviour is citable, but only after
`git submodule update --init --depth 1 radio/src/thirdparty/lvgl`.

**Rejected: layered rectangles.** Stacking rectangles of decreasing width to fake a
rounded stripe produced visible steps at the sizes actually drawn, and the geometry does
not survive a change of corner radius. The clipped-arc construction is indifferent to
what LVGL does with radii, which is why it is preferred even though both could be made
to work.

It took five rounds to arrive at, and the version that worked came from the user rather
than from the measurements.

### Alert states tint the surface; they do not draw a frame

A warning or critical state tints the panel's fill. It does not colour its border.

This leaves **fill meaning a condition of the data and outline meaning where the
interaction focus is**. Previously the border carried both, so a selected warning panel
and a warning panel were the same picture, and a pilot had to read the panel to find out
which.

**The tints are derived per palette rather than fixed.** Modern uses the specified
palette verbatim; Follow EdgeTX derives its tokens from `lcd.getColor()`; Custom applies
a limited override set over Modern. A fixed tint would be legible against one of those
and not the others. Both derived modes pass through a legibility pass that guarantees
minimum contrast for body, muted and faint text, for panel elevation and borders, and
for every semantic accent.

**Critical red is never theme-derived.** A derived palette may make every other accent
agree with the radio's theme; it may not make a critical state quieter than critical.
The dashboard never calls `lcd.setColor()`.

### The header

The heading sits left. The badge sits right. **The badge column is reserved on every
panel whether or not a badge is showing**, so a state change never reflows the heading.

The badge column is exactly as wide as its widest word and is never squeezed. Clamping
it to a fraction of a narrow panel protects the heading by clipping the badge, which is
the wrong way round: `CRIT` and `CRI` are not equally alarming, while a shortened source
name is merely less informative. **A heading with too little room left is dropped rather
than clipped**, on any panel, not only one obstructed by the App mode menu button.

**The badge vocabulary is a closed set of five strings on the theme, and components do
not override it.** It was cut from thirteen rather than widening the column to fit the
longest: `NOT CELLS` and `BAD CELLS` were nine characters separating two failure modes
of one component, and the column is paid for by every header on the dashboard rather
than by the state that uses it. **A badge names the state; the supporting row says why.**
Distinctions such as a cells sensor returning a number against one returning nonsense
belong in the row, which is fitted to whatever width its panel gives it and words them at
whatever length fits. **What carries the distinction is the vocabulary, not the room** —
see [the two-item row](#what-the-two-item-row-cost-and-why-it-was-chosen-anyway), where
that sentence once said "room for words" and stopped being true.

---

## Type

### One ladder, shared

Composition comes from the box, and the font from the composition, so two panels of the
same size agree. One shared responsive ladder replaced eight private copies — which was
why two panels of identical size disagreed, each having shed a different amount before
measuring anything. **A component may decline what it was granted; it cannot claim what
it was not.**

The reading ladder is `SMLSIZE`, `MIDSIZE`, `DBLSIZE`, `XXLSIZE`. A reading never drops
to `TINSIZE`, which is a supporting row's size.

Font metrics, from EdgeTX's generated font tables (line height / base line):

| Font | Line height | Base line | Ascent |
| --- | --- | --- | --- |
| `TINSIZE` | 12 | 3 | 9 |
| `SMLSIZE` | 17 | 4 | 13 |
| `MIDSIZE` | 29 | 6 | 23 |
| `DBLSIZE` | 40 | 9 | 31 |
| `XXLSIZE` | 69 | 15 | 54 |

### Redundancy may go; magnitude may not

A reading may drop something the panel already says. It may never drop something that
changes what the number means.

**A unit that carries magnitude is not redundancy and is never dropped.** A distance's
unit changes with its range, so `1.23km` and `1.23m` are different readings rather than
one abbreviated. `navigation` says so, and for it the pair is what the ladder is walked
against: the number steps down until both fit, because a distance with no scale on it is
worse than a small one.

### The unit is drawn inline, beside the reading

At a smaller size — two ladder steps down where there are two — sharing the reading's
baseline, and **positioned from the reading's measured width** using `lcd.sizeText`
rather than an estimate.

`theme.textWidth` estimates at 0.58 of a line height per character. That was called
deliberately generous, so text shrinks rather than clips — but one allowance per character
is only generous for characters narrower than the allowance. A digit is 0.429 of a line
height and a decimal point 0.199, so at `XXLSIZE` the estimate put `7.9`'s right edge
roughly 48 px beyond where the radio draws it, which is the gap a user reported between a
number and its unit. A capital `M` is 0.667, and there the estimate reports **less** than
the truth: `model-identity` sizes against a row of `M`, and at `1 x 2` was drawing its name
eleven pixels past the panel.

`lcd.sizeText` calls `getTextWidth`, which is `lv_txt_get_width` over the real font, with
no draw context and no LCD state. **Fitting measures too, now.** The open item recorded
here — that every fitting decision still used the estimate — was closed once the
under-reporting was found, because the generosity argument that justified leaving it only
ever held for digits.

**Rejected: `metric` offering a single abbreviation form.** The specification explained
that `metric` offered one form because it drew its unit as a separate label and its
reading was digits alone. That stopped being true when the unit joined the reading, and
the passage was corrected with the code rather than left describing a design that no
longer existed.

---

## Colour

Reserve saturated colour for meaning:

| Colour | Means |
| --- | --- |
| Cyan | Electrical or selected data |
| Green | Healthy or current state |
| Amber | Caution |
| Red | Critical |
| Orange | Only where it identifies a distinct measurement family |

**A component's default accent obeys the colour rule rather than its author's taste.**
`tx-battery` was green and `cell-battery` cyan for the same concept; both are electrical,
so both are cyan.

---

## Visualisations

### A compact visual sits beside the reading, not beneath it

**It is vertically centred on the reading's line box.** Not its baseline, not its top.
The three were drawn side by side from real geometry at every span and the centre is the
one that reads as belonging to the number rather than hanging off it. It applies to every
compact visual in every component — a battery, a dial, a compass — so two panels of
different components at the same span place theirs identically.

**Rejected: baseline alignment and top alignment.** Both were rendered at every span
before being dropped. Baseline alignment is defensible in principle but EdgeTX exposes no
ascent to Lua directly, and aligning the boxes was visually worse than centring them at
every pair of fonts actually used.

**Line box, not ink** — and this was reconsidered and confirmed. When band-derived fonts
were being chosen, a font selected by ink rather than line height would have split the
two: on `navigation 4x2` a dial centred on the line box sits 4.5 px off the digits'
visual middle. The ink option was rejected (below), so line box stands.

A visual that spans the panel's width — a bar — has nothing to centre against and is
unaffected by any of this.

### A bar is exempt from the flow rule

**A bar's length _is_ the reading.** A track that stops short of the panel edge measures
against a scale the eye cannot see. Bars stay full width.

### The battery glyph

Vertical rather than horizontal: taller than wide, with the terminal nub on top, standing
beside the reading like an upright cell.

**The outline and the fill are the same colour, state-coloured**, so a critical pack is
entirely red, outline and interior together. The empty part of the cell is what shows
charge.

`primitives.batteryGlyph` is three rectangles, because `lvgl.box` accepts a `color` and
silently ignores it. **Its outline is built at its final weight and never restated**,
since a border width only reaches LVGL through `LvglWidgetBorderedObject::setOpacity` and
is discarded by a later `set`.

**The outline's thickness is proportional to the reading's resolved font, not to the
span.** The ladder can put different fonts at the same span, and the thing the stroke has
to look right against is the number beside it. A constant stroke that looked right at
`XXLSIZE` ate the interior at `SMLSIZE`, where the interior is what shows charge.

An outline with no fill is a picture of a flat pack, so a panel with no range to measure
against hides the whole glyph rather than drawing it empty.

**The glyph is sized by search rather than by formula.** The answer is not smooth: a
glyph one pixel narrower can be the difference between a reading keeping `XXLSIZE` and
dropping to `DBLSIZE`, and there is no expression for where that edge falls that is not
the loop written out longhand.

### Shedding

**A reading is never shrunk to make room for something beside it.** It takes the size the
whole panel allows; the visualization then fits in what is left, or it is shed.

This replaces an earlier rule that allowed one step down and shed only at two. That rule
could charge a reading for something it never got — narrowed to half the panel so a dial
would have room, then the dial shed anyway, leaving a smaller number and no dial.

`tx-battery` already worked this way, taking its font from the band rather than from the
fitting ladder, so the decision makes it the pattern rather than the exception. The cost is
two panels: `metric` and `variable-indicator` at `1 x 2` each trade their dial for two font
sizes. The user was shown that trade and chose it.

### Open: what a unit yields to

**The order between a reading and a decoration is settled. The order between a *unit* and a
decoration is not, and two components answer it differently.**

`theme.panel` treats the unit as part of the reading: it measures the pair, asks whether
that clears the visual, and sheds the **visual** if it does not. `tx-battery` measures the
unit against the slot instead, so the **unit** goes and the battery stays. Both are
defensible — the heading already names what is being measured, so the unit is redundancy;
but so is the glyph, and nothing in either document ranks one kind of redundancy against
the other.

It is live in two panels. A `tx-battery` at `2 x 2` with its percentage row off currently
drops the `V` and keeps the glyph, where the shared rule would keep **both** — the unit is
being dropped for room that was available. At `1 x 2` with the row on it is a straight
swap: unit or glyph, not both.

Recorded rather than decided, because it changes what a shipped panel draws.

### Open: a compact visual has two dimensions

`theme.panel` describes a compact visual with a single size, because every one built so far
is a circle — a radial or a compass ring, where the diameter is both the width it takes
from the reading and the depth it takes from the band.

**A battery glyph is not a circle.** It measures 17 x 34 px at one-row spans and 25 x 50 at
two-row spans, a one-to-two ratio at every size. Given only one number the builder either
mis-centres it vertically or reserves fifty pixels of width for something twenty-five wide
and sheds glyphs that would have fitted.

This is a generalisation rather than a special case — a compact visual *has* a width and a
height, and a circle simply returns the same number twice — so it is not blocked on
anything except having a component that needs it.

---

## Content flow

**Implemented and shipped.** This section was written from rendered mocks and marked "not
implemented by any component" while it was a proposal; both halves of it are now live
everywhere, and the table at the top of this document records which components assemble it
through `theme.panel` and which still write the assembly out themselves. Run `make mocks`
and open `build/flow-mocks.html` to see every figure below drawn at its true pixel size.

### The problem it solves

Panels are edge-anchored today, so slack collects *between* elements instead of after
them. A `tx-battery` at `4x2` has its voltage hard left, its battery hard right, and
**392 px of hole in the middle — 82% of the panel's width**. The slack is largest exactly
where panels are widest, so every extra cell of width goes into the hole rather than into
the content.

### Two slots, derived from the panel

**Content sits on two slot centres at 30% and 70% of the content box width.** The reading
takes the left slot; a compact visual takes the right.

**The slots come from the panel, not from the content.** That is the whole point: a slot
cannot move because what is in it changed width, and across a row of equal-width panels
every reading lands at the same x.

**A panel holding only a reading does not split.** The reading centres across the whole
content box. The slots exist to give two elements stable positions, and leaving a right
half empty would make a one-element panel look like a two-element panel with something
missing. Five of the twenty-four Full screen cases have no visual at all.

**Rejected: left-aligned flow.** The reading keeps the content box's left edge and all
the slack collects after it. It degrades predictably, which is a real virtue, but it
reclaims the hole without ever lining two panels up with each other.

**Rejected: fully centred content.** The content group centres as a whole. It was dropped
on two counts, both measured:

- Its reading sits **186 px (39% of the panel)** from its own left-aligned heading, against
  the slotted **114 px (24%)**. A centred reading under a fixed-left heading reads as misaligned
  rather than as centred.
- It re-centres whenever its contents change width. A voltage crossing `9.9` to `10.0`
  shifts the number *and* the battery beside it, every time, at the moment attention is on
  it.

Choosing the gap for that variant also produced a result worth remembering: a pure
proportion (one third of the reading's line height) measured **6 px at `SMLSIZE` and 9 at
`MIDSIZE`** — *less* than the left-aligned 10 — so the variant meant to open the layout up
would have looked tighter than the one it replaced. It needed a floor of 14 px plus half
the line height.

### The fallback, and why it is decided at build

Strict halves — slots at 25% and 75% — cannot collide *provided each element fits its
half*, because the two own disjoint regions. Tightening to 30% and 70% gives that up: the
territories overlap and only the actual widths keep the elements apart.

**Where the tightened slots would let two elements meet, the panel falls back to strict
halves.**

**The fallback is decided at build, from the widest string the component can ever print,
never from the value on screen.** Deciding it from the current reading would make the
arrangement a function of the data — `9.9` to `10.0` and the whole panel flips between two
layouts. That is the moves-when-content-changes objection that ruled out centring, in a
worse form: a drift becomes a switch. Asking the widest form fixes the arrangement once,
so a panel with room to spare today keeps the layout it will need at its widest.

`navigation 2x2` is therefore a strict-halves panel *permanently*. It is not that it
sometimes overlaps; it is that its content does not fit the tighter arrangement.

**The fallback is per panel, never per row.** A tightened body over a strict supporting row
leaves the columns disagreeing down the panel, which is the one thing slot-derived
positions exist to prevent. It costs more panels their tightening and it is the more
consistent of the two.

**Rejected: per-row fallback.** Rendered beside the chosen one on `navigation 2x2` so the
columns can be seen failing to line up.

Measured at the widest string each component prints, two of ten panels overlap when
tightened against one under strict halves. `navigation 1x1` overlaps under both, and that
is not tightening's fault: `888.88km` needs 60 px, half that panel is 48, and the reading
is already at the bottom of the ladder. It resolves itself on a radio, because the
component drops its dial rather than clip a distance, and a one-element panel does not
split.

### Every row uses the same slots

The slot centres are a property of the panel, so **every row uses them**:

- A row of **one** item centres it across the whole content box, exactly as a lone reading
  does.
- A row of **two** puts them on the same two slot centres.
- A row of **three or more is left alone.** The rule names two slots, and inventing a third
  placement for a case that does not occur would be making up a rule rather than showing
  one. Nothing in the catalogue draws three on a line.

This makes the arrangement one rule applied at every level rather than a body rule plus a
footer special case — the difference between something extensible and a set of exceptions
to memorise.

#### What the two-item row cost, and why it was chosen anyway

`cell-battery`, `link-status` and `navigation` split their supporting row into a left and a
right column, originally edge-anchored so the two could never collide. **That split was
built, measured, backed out, rebuilt behind a flag, and finally replaced** — the longest
route any decision in this document took, and the only one settled on a radio rather than
from a description.

The cost is arithmetic and it is not small. Two boxes centred 40% of the content apart can
each be **40% wide** before they meet; the column split reached **100%**. `fitLabel` spends
the difference on shorter wording, and on a `2x2` panel every long form in `navigation`'s
vocabulary goes:

| state | column split | slots |
| --- | --- | --- |
| no GPS sensor configured | `NO GPS SOURCE` | **`NO GPS`** |
| sensor present, no fix | `NO FIX` | `NO FIX` |
| fix, home not yet set | `NO HOME POSITION` | **`NO HOME`** |
| flying, oriented from home | `NORTH UP FROM HOME` | **`NORTH UP`** |
| telemetry gone quiet | `LAST KNOWN` | **`LAST`** |

Four of five states lose their full wording — seven characters on the worst. At `4x2` and
wider the row is 184 px and every form survives, so this is a cost the narrow spans pay
alone.

**It was rejected once, on exactly that basis.** The specification puts the
absent-sensor-versus-no-fix distinction in this row *because the row has room for words*,
and a rule that takes the words away contradicts the rule that put them there. So the
implementation was backed out and both arrangements were put on a review screen instead —
same data, same span, side by side, with the top pair rigged to a GPS source no radio has
so that `NO GPS SOURCE` against `NO GPS` was the first thing visible. **The user chose the
narrower row with that cost in front of them.**

**The contradiction was then closed rather than absorbed**, which is the part worth copying.
The defence was never really the width: it is that the *shortest* wording of each state
differs from the shortest wording of every other, because the shortest form is what a
cramped panel prints. `NO GPS` and `NO FIX` are six characters each and say different
things. `link-status` keeps `DOWN` against `NO RSS` the same way. That property is
checkable where "has room for words" was not, so the specification now states it and
`testSupportingWordingsStayDistinct` holds every component to it — including the nine whose
rows have yet to move.

**Shortening may cost detail. It may never cost meaning.**

Clearances under the rule: the tightest anywhere is **34 px**, on `navigation 2x2`, across
six rows, with no row forcing a fallback. **That figure is measured at the strings those
components are drawn with, not at their widest** — the geometry carries a widest form for
the *reading*, because the component's own fitter needs one, and nothing equivalent for a
supporting label. 34 px is about three more `SMLSIZE` characters of headroom; `LQ 88%`
becoming `LQ 100%` spends one. Comfortable, but headroom rather than proof. Making it a
proof means components declaring their widest supporting strings the way they already
declare their widest reading.

### Proportional vertical bands

The panel's vertical extent divides into **a label band of one quarter, a body band of one
half, and a tertiary band of one quarter** — and where a part is absent its quarter goes to
the body. So the splits are 1/4 : 1/2 : 1/4, 1/4 : 3/4, 3/4 : 1/4, or the whole extent.

Like the slots, the bands come from the panel, so a band does not move because of what is
in it.

**Corrected: the heading is pinned to the top of its band rather than centred in it.** The
band is a proportion of the panel, so anything centred in it moves as the panel grows —
which is right for a reading, where growing with the panel is the point, and wrong for a
heading, which is furniture that says what the panel is and should land in the same place
every time. Measured before the correction, on a single column:

| Panel | Label band | Heading top |
| --- | --- | --- |
| 1 row | 14 px | 0 px |
| 2 rows | 31 px | 13 px |
| 3 rows | 48 px | 21 px |
| 4 rows | 65 px | 30 px |

Four panel heights, four heading positions, which is what the user saw on the radio. The
heading now sits at the panel's own top inset: 6 px, or 2 px on a panel under 80 px tall,
which is the existing tight rule that governs every vertical measurement on those panels
and not something the heading decides. Four offsets became two, four pixels apart.

**The band itself is unchanged and the body still starts below it.** That is deliberate:
where content begins feeds the ladder's row and visual grants and the body band's
position, so letting the body rise into the space the heading vacated would change what
every panel in the catalogue draws — a catalogue-wide font change arriving by accident
inside a change about a heading. Verified through `tools/flow-geometry.lua` across every
component at every span in both zones: headings and badges move, and nothing else does.

The two panel heights the Full screen zone produces:

| Panel | Extent | Label / body / tertiary |
| --- | --- | --- |
| 117×53, 238×53 | 47 px | 11 / 36 / — |
| 238×111, 480×111 | 101 px | 25 / 51 / 25 |

**The body band never fails, which was not obvious in advance.** A 53 px panel looks as
though a half — 23 px — could not hold a 29 px `MIDSIZE` reading. But those panels shed
their tertiary row at every width, so the split is 1/4 : 3/4 and the body gets 36, which
holds the tallest block any of them draws. The proportional rule rescues itself exactly
where it looked weakest.

### The font comes from the band

**The largest font whose line height fits the body band.** This inverts today's rule, where
the composition comes from the box and the font from the composition.

**The stability guarantee survives, and becomes structural.** Today's fitter sizes a reading
against the widest string a component can ever print, so a value never resizes as it
changes — but that depends on every component remembering to pass its widest form. A
band-derived font does not consult the content at all, so it cannot resize with it. The
guarantee holds by construction rather than by discipline.

**What it changes, measured through the real host over all forty-eight
component-span-zone cases: 46 unchanged, 2 smaller, none larger.** The band-derived font
is very nearly the rule the dashboard already had. On `tx-battery` the two-row spans drop
from `XXLSIZE` to `DBLSIZE`, because a body band is half a panel's extent and half of a
134 px panel is 62 against `XXLSIZE`'s 69. That is the largest reading on the dashboard
getting smaller, and it was accepted knowingly.

**Corrected: it was accepted for more panels than it was true of.** A quarter of the panel
is reserved for a supporting row, and `tx-battery`'s percentage row is off unless a layout
asks for it — so a panel that was never going to draw a row was charged 31 px for one, and
the 62 px band above was 93 px all along. With the row genuinely off, the two-row spans
take `XXLSIZE` again. The loss is real only where the row is real, which is what the band
rule was always meant to say. Three components had this, and eleven cases got their font
back; the bands quoted throughout this section are the ones a panel actually gets.

> **This table said the opposite until the rule was implemented, and the correction is
> worth recording rather than quietly making.** It claimed 14 of 24 readings would grow
> and none shrink, and the user chose the rule partly on that. The number was an artefact
> of two errors in the generator that produced it, both of which over-measured the body
> band:
>
> - **A bar was not charged for the floor it occupies.** The tertiary quarter was reserved
>   only for supporting rows, so any panel drawing a bar got a three-quarter body band
>   running down to the panel's own floor. A reading sized against that band lies straight
>   across the bar. The generator's own collision check could not see it, **because that
>   check compared labels with labels and a bar is not a label** — a blind spot the size of
>   every non-text object, in the check that made the page trustworthy.
> - **A heading overflowing its band did not push the body down.** On a short panel the
>   label quarter is smaller than any available font, so the heading keeps its size and
>   spills; the body has to start below where the heading actually ends, not below its
>   nominal quarter.
>
> Correct both and the band comes out close to the room the older ladder already computed,
> which is why the fonts barely move. Both the generator and the integration suite now
> check non-text objects.

The second of those reads differently now that the heading is pinned to the top of its
band: the body starts below where a **centred** heading would have ended, which is no
longer where the heading actually ends. That is the point rather than an oversight — the
space is still reserved, so the body does not move — but the sentence above describes the
reasoning at the time and not the arithmetic today.

So the honest summary is that **the vertical half of the arrangement is nearly a no-op and
the horizontal half is where the value is.** The slots are what stop a reading and a
visualization contesting one column, and that is worth having on its own.

**Rejected: choosing the font by ink.** `theme.fontHeight` is LVGL's line height — ascent
plus descent plus leading — and every reading in the catalogue is digits, a minus, a point
or a colon, none of which descend. So a band sized against line height genuinely does carry
slack nothing draws into, and the observation that prompted this ("fonts should use at least
80% of their vertical allotment") was correct on its own terms:

It was rejected on these two bands:

| Band | By line height | Ink fills | By ink | Ink fills |
| --- | --- | --- | --- | --- |
| 36 px | `MIDSIZE` | 63% | `DBLSIZE` | 86% |
| 51 px | `DBLSIZE` | 60% | `DBLSIZE` | 60% |

— because 80% looked unreachable on the larger of them for a reason with nothing to do
with the measurement: a 51 px band takes `DBLSIZE` at 31 px of ink, the next step up is
`XXLSIZE` at 54 px, and between 40 and 69 the ladder has nothing. That was read as the
ladder's granularity rather than the rule's fault.

**Corrected: this dashboard produces neither of those bands.** Enumerating every body band
over both zones, all sixteen spans and the supporting row both on and off, the bands that
actually occur are **22, 34, 50, 62, 69, 79, 87, 97, 108, 112, 132, 139, 155 and 191 px**.
36 and 51 are not among them, and the argument was made on the two sizes where ink happens
to buy the least.

On the bands that do occur, ink and line height disagree twice — and both are cases where
the panel carries a supporting row, which is to say the cases where the reading has least
room and a size is worth most:

| Band | By line height | Ink fills | By ink | Ink fills |
| --- | --- | --- | --- | --- |
| 34 px | `MIDSIZE` | 67.6% | `DBLSIZE` | **91.2%** |
| 62 px | `DBLSIZE` | 50.0% | `XXLSIZE` | **87.1%** |

A 62 px band draws a reading filling half of it where the next font up would fill 87%, and
`XXLSIZE` is excluded there only because its *line height* is 69 — seven pixels of leading
and descent that no digit, minus, point or colon in this catalogue ever draws into.

So the rejection stands as a record of what was tried, and its conclusion does not: the
ladder's granularity is not what blocks ink on the bands this dashboard builds. **The
question is open, not closed.** It is a behaviour change affecting readings on every panel
that carries a supporting row, so it belongs to the user rather than to whoever reads this
next; the rendering that answered it is still in `tools/flow-render.py`.

**Rejected: a literal 80% filter.** `height ≥ 0.8 × band` together with `height ≤ band` is a
window a five-step ladder often has no member in. This one is unaffected by the correction
above — it is a statement about the ladder, not about any particular band.

### The font wins, and is clamped to the panel

**Where a band cannot hold even the smallest available font, the font is kept and its
position is clamped so nothing leaves the panel.** The band yields. Bands stop being exactly
proportional at the bottom of the size range, and nothing is ever drawn off a panel.

This is not a corner case. A quarter of a 53 px panel is 11 px, the heading is `SMLSIZE` at
17, and the smallest font the dashboard has is `TINSIZE` at 12 — **so there is no font that
fits that band on any 53 px panel, in any component.** Unclamped, centring the heading in a
band smaller than itself put 1 px of it above the panel's top edge, where it was clipped.

A reading is never shrunk to satisfy a band. The specification is explicit that a reading may
drop redundancy and never magnitude, and shrinking a number to fit a decorative band is
paying magnitude for layout.

**Rejected: falling back to today's stacking below a size threshold.** Two layout rules with
a size threshold between them is a worse thing to own than one rule that bends at the bottom
of its range. Every component, every span and every future addition would have to be reasoned
about twice, once on each side of a line whose position is itself arbitrary.

### What the rule does not reach

Of the twenty-four Full screen cases: **10** have a compact visual and would move, **9** draw
a full-width bar and are exempt, and **5** have no visual at all. Only **10** carry any slack
to reclaim. The sweep is narrower than the component count suggests, though a `metric` with
`visual: radial` is a different case from the same component with `visual: bar`.

### One consequence, since resolved

`tx-battery` is the only component that gates its visual on **data** rather than on space: it
hides its battery until there is a voltage range to measure against, and that range is a live
subscription to `getGeneralSettings` rather than something read once.

Under the slot rule, a panel with one element does not split. So the range arriving a frame or
two after the panel is built would move the reading **from the panel's centre to its left half
during start-up, every time** — and a pilot editing SYS → Hardware → Battery meter range would
move it again, in flight. That is the objection that ruled out centring, reappearing in the
arrangement chosen to avoid it.

It is confined to one component and it was fixable: reserving the slot whenever the layout
*could* ever show a visual, rather than when one is currently drawn, holds the reading still,
at the cost of a permanently empty right slot on a panel that never gets a range. **That
trade was made, and it is what `tx-battery` does** — `reserveSlot` asks whether this layout
wants a battery, not whether one is being drawn.

It is worth keeping the reasoning rather than only the outcome, because it is the one place
in the dashboard where a layout decision is deliberately made from what a panel *could*
show. Everywhere else the rule is the opposite — bands and rows come from what a panel
draws, never from what it is permitted — and the difference is that a permission which can
change mid-flight is not a permission at all, it is data.

---

## Retired: the span galleries, and what went with them

**Four layouts showed every component at one span — `1x1`, `2x1`, `2x2`, `4x1` — and
they have been taken off the radio.** The user does not page to them, and ten screens is
EdgeTX's ceiling, which the per-component review screens now need.

**What is lost is the only view of cross-component agreement.** A gallery put eleven
panels of the same size side by side, which is where you can see headings landing on the
same line, readings sitting on the same slot, and badges lining up in the same column.
That agreement is exactly what the shared ladder and the slot rule exist to produce, and
it is the thing that is invisible one panel at a time: a heading 13 px too low looks fine
alone and looks wrong beside four that are not.

**A review screen cannot replace it, because it is the transpose.** A review screen holds
one component fixed and varies the span; a gallery holds the span fixed and varies the
component. The first answers "does this component behave across sizes", the second
answers "do these components agree at one size". Both were worth having and only the
first is now on the radio.

Two things soften it and neither replaces it. The galleries are still built by the test
suite from `tests/fixtures/layouts/`, so the collision check still sweeps the densest
arrangement in the catalogue and the single-cell gallery is still held to containing
every component that declares that span. And `tools/flow-geometry.lua` renders several
components at one span into `build/flow-mocks.html`, which is a page rather than a radio
but does show alignment.

**If cross-component drift reappears, this is the view that would have caught it**, and
the honest position is that nobody will be looking.

## Checking a layout mechanically

**Every visible label is checked against every other drawn thing — labels, bars, cells,
dials, tracks and markers — as a rectangle, and against the panel's own edges.**
`testNothingIsDrawnOverAnythingElse` does this over every shipped layout in both zones, so
a layout is covered the moment it is added.

It is cheap, it catches a whole family of defects at once, and it found one that four other
measures on the same page reported as healthy: a unit printed twelve pixels inside its own
reading while the slot margins were comfortable, the fonts were right and the bands held.
It also caught the heading falling off the top of every 53 px panel, which is what produced
the clamp rule above. Neither needed an eye, and neither should have needed one.

**It covers non-text objects because the first version of it did not**, and that omission
let a reading lie across its own bar through a whole revision of the design mocks — see the
band-derived font above. A check that is trusted and blind in one direction is worse than no
check.

Four details it took two attempts to get right, each of which produced false failures:

- **Measure a label the way the radio draws it.** `theme.textWidth` allows one width per
  character regardless of which character it is, so on digits it over-reports; fed to a
  collision check it reported every reading as lying across its own unit. It was described
  here as deliberately generous, which is true of digits and false of capitals — see the
  estimate entry above, and note that fitting no longer uses it either.
- **A label cannot draw past its own width.** A Lua label's long mode is LVGL's default
  wrap, so text too wide for its column comes back down the panel rather than out across it.
  Sideways is the one direction it cannot go.
- **Honour containers.** The accent stripe is two quarter-circle arcs inside a box one
  accent-width wide; unclipped, each appears to lie over the heading.
- **Exclude backgrounds by what they are, not by name.** A panel's surface spans the panel,
  its accent sits inside the left padding, and a bar's fill is drawn inside its own track.
  Those three overlaps are the design.

See the specification's fixture discipline for the defect shape behind the unit: **a
position derived from a size must be recomputed when the size changes, never carried as an
offset.**
