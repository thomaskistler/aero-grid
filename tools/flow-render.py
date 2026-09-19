"""Render the content-flow mocks as one HTML page of inline SVG.

Run with `make mocks`, which writes `build/flow-mocks.html`. The page is a
build artefact and is not committed; this generator is, so it can be re-run
against whatever the dashboard currently draws.

The geometry on the "today" side is not drawn by hand: `tools/flow-geometry.lua`
builds each panel through the real widget host and walks the objects back out
of the LVGL mock, so every coordinate, font, colour and string is what the
dashboard actually produces. The "proposed" side is a transformation applied
here, in this file, to that same geometry. **It is a proposal. Nothing in the
widget implements it.**
"""

import html
import sys
from pathlib import Path

from lupa import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute((ROOT / "build" / "flow-cases.lua").read_text())
G = lua.globals()


def rows(table):
    return [table[i] for i in range(1, len(table) + 1)]


def rgb(value):
    if value is None:
        return None
    return "#%06x" % int(value)


PALETTE = {k: rgb(G.PALETTE[k]) for k in G.PALETTE.keys()}
FONTS = {k: (int(G.FONTS[k].height), int(G.FONTS[k].ascent)) for k in G.FONTS.keys()}

# Panel padding, from theme.spacing. Read rather than assumed: it is the left
# inset every component's content starts at.
PAD = 8


class Obj:
    """One drawn object, flattened out of the Lua dump."""

    def __init__(self, o):
        self.kind = o.kind
        self.x = int(o.x)
        self.y = int(o.y)
        self.w = None if o.w is None else int(o.w)
        self.h = None if o.h is None else int(o.h)
        self.hidden = bool(o.hidden)
        self.font = o.font or None
        self.rgb = rgb(o.rgb)
        self.text = o.text or ""
        self.filled = bool(o.filled)
        self.thickness = None if o.thickness is None else int(o.thickness)
        self.rounded = None if o.rounded is None else int(o.rounded)
        self.radius = None if o.radius is None else int(o.radius)
        self.start = None if o.startAngle is None else int(o.startAngle)
        self.end = None if o.endAngle is None else int(o.endAngle)
        self.bgRgb = rgb(o.bgRgb)
        self.bgStart = None if o.bgStart is None else int(o.bgStart)
        self.bgEnd = None if o.bgEnd is None else int(o.bgEnd)
        self.textW = int(o.textW)
        self.lineH = int(o.lineH)
        self.role = None

    def copy(self):
        clone = Obj.__new__(Obj)
        clone.__dict__.update(self.__dict__)
        return clone


def classify(objects, panel_w, panel_h):
    """Name each object's part in the arrangement.

    Derived from what the objects are rather than from a list of component
    internals: the heading is the first small label on the header row, the
    badge is the one in the reserved right-hand column, the reading is the
    label in the largest font, the unit is the only label with no width
    (`primitives.unit` gives it none so LVGL sizes it to content), and a
    visual is any arc or any rectangle that is neither the panel surface nor
    the accent.
    """
    labels = [o for o in objects if o.kind == "label" and not o.hidden]
    if not labels:
        return

    header_y = min(o.y for o in labels)
    heading = None
    badge = None
    for o in labels:
        if o.y == header_y:
            if heading is None:
                heading = o
                o.role = "heading"
            else:
                badge = o
                o.role = "badge"

    body = [o for o in labels if o.role is None]
    reading = None
    if body:
        reading = max(body, key=lambda o: (o.lineH, -o.y))
        reading.role = "reading"

    for o in body:
        if o.role is None and o.w is None:
            o.role = "unit"
        elif o.role is None:
            o.role = "supporting"

    # Everything painted that is not the panel itself or its accent stripe.
    for o in objects:
        if o.hidden or o.kind == "label":
            continue
        if o.kind == "box":
            o.role = "container"
        elif o.kind == "rectangle":
            if o.w == panel_w and o.h == panel_h:
                o.role = "surface"
            elif o.x <= 4 and (o.w or 0) <= 6:
                o.role = "accent"
            else:
                o.role = "visual"
        elif o.kind == "arc":
            o.role = "accent" if (o.radius or 0) <= 8 else "visual"


def content_right(objects):
    """Where the reading, with whatever rides beside it, actually ends."""
    reading = next((o for o in objects if o.role == "reading"), None)
    if reading is None:
        return PAD
    right = reading.x + reading.textW
    unit = next((o for o in objects if o.role == "unit"), None)
    if unit is not None and not unit.hidden:
        right = max(right, unit.x + unit.textW)
    return right


def visual_bounds(objects):
    parts = [o for o in objects if o.role == "visual" and not o.hidden]
    if not parts:
        return None
    xs, ys, xe, ye = [], [], [], []
    for o in parts:
        if o.kind == "arc":
            # `x` is the corner the firmware stores, not the centre: the mock
            # models `LvglWidgetRoundObject::setPos` subtracting the radius.
            r = o.radius or 0
            t = o.thickness or 0
            xs.append(o.x - t // 2)
            ys.append(o.y - t // 2)
            xe.append(o.x + 2 * r + t // 2)
            ye.append(o.y + 2 * r + t // 2)
        else:
            xs.append(o.x)
            ys.append(o.y)
            xe.append(o.x + (o.w or 0))
            ye.append(o.y + (o.h or 0))
    return min(xs), min(ys), max(xe), max(ye)


#: Air between the reading and a visual following it, left-aligned.
#: Slack collects after the group, so the gap only has to separate two
#: things rather than carry the arrangement.
GAP_LEFT = 10

#: The gap when the group is centred. Centring puts the slack on both sides
#: instead of after, which is what lets the elements sit further apart.
#:
#: **A single constant does not work, and neither does a pure proportion.**
#: A proportion was tried first -- a third of the reading's line height --
#: because that is what keeps the gap consistent against the number it
#: separates. Measured across the cases that actually occur it gave 6 px at
#: SMLSIZE and 9 at MIDSIZE, which is *less* than the left-aligned 10 and so
#: exactly the opposite of the intent: the centred variant would have looked
#: tighter than the one it is meant to open up.
#:
#: So it is a floor with a proportional term above it. The floor is what
#: guarantees the centred variant is never tighter than the left-aligned one;
#: the proportion is what stops a large reading looking crowded. Over the
#: range that occurs -- a compact visual costs the reading a size, so it is
#: never beside an XXLSIZE number -- the floor binds at SMLSIZE and MIDSIZE
#: and the proportion binds at DBLSIZE: 14, 14 and 20 px.
GAP_CENTRE_MIN = 14
GAP_CENTRE_DIVISOR = 2


def centre_gap(reading):
    return max(GAP_CENTRE_MIN, reading.lineH // GAP_CENTRE_DIVISOR)


def reflow(objects, panel_w, panel_h, pad, content, justify):
    """Apply the proposed rule to a copy of the drawn geometry.

    The rule: the reading leads; a secondary element **follows** it rather
    than being pinned to the right edge; supporting rows **follow** the block
    above them rather than being pinned to the panel floor.

    `justify` is the open question the page now asks. `left` keeps the group
    at the content box's left edge and lets the slack collect after it.
    `centre` centres the group in the content box, which puts the slack on
    both sides and buys room for a wider gap between the elements.

    A secondary element always sits on the **optical centre** of the
    reading's line box. That was an open choice and is not any more.
    """
    out = [o.copy() for o in objects]
    reading = next((o for o in out if o.role == "reading"), None)
    if reading is None:
        return out

    centred = justify == "centre"
    gap = centre_gap(reading) if centred else GAP_LEFT

    unit = next((o for o in out if o.role == "unit" and not o.hidden), None)
    bounds = visual_bounds(out)

    # The reading and its unit move together: the unit is placed against the
    # reading's drawn end, so it is part of the group rather than beside it.
    group = [reading] + ([unit] if unit else [])
    group_right = content_right(out)

    moved_visual_bottom = None
    flowed_visual = False

    if bounds is not None:
        vx, vy, vxe, vye = bounds
        vw, vh = vxe - vx, vye - vy

        # A bar spans the panel's width by design; following the reading would
        # make it a stub. Only a compact visual flows.
        spans_width = vw >= content - 2
        if not spans_width:
            dx = (group_right + gap) - vx
            dy = (reading.y + (reading.lineH - vh) // 2) - vy
            for o in out:
                if o.role == "visual" and not o.hidden:
                    o.x += dx
                    o.y += dy
            moved_visual_bottom = vye + dy
            group_right = vxe + dx
            flowed_visual = True
        else:
            moved_visual_bottom = vye

    if centred:
        # Centre the whole group -- reading, unit and whatever followed it --
        # in the content box. Measured from the reading's left edge to the
        # group's real right edge, so a short reading is centred on what is
        # drawn rather than on the column it was given.
        group_width = group_right - reading.x
        shift = (pad + (content - group_width) // 2) - reading.x
        if shift > 0:
            for o in out:
                if o.role in ("reading", "unit"):
                    o.x += shift
                elif o.role == "visual" and not o.hidden and flowed_visual:
                    o.x += shift

    # Supporting rows follow the block above them rather than the panel floor.
    supporting = [o for o in out if o.role == "supporting" and not o.hidden]
    if supporting:
        block_bottom = reading.y + reading.lineH
        if moved_visual_bottom is not None:
            block_bottom = max(block_bottom, moved_visual_bottom)
        top = min(o.y for o in supporting)
        dy = (block_bottom + gap) - top
        if dy < 0:
            for o in supporting:
                o.y += dy

        if centred:
            # A supporting row is a box with text left-aligned inside it, so
            # centring the arrangement has to centre the text rather than the
            # box. Where the row is two columns -- a bearing beside an origin,
            # a cell count beside a pack voltage -- each is centred in its own
            # column, which is what keeps the two from colliding.
            for o in supporting:
                if o.w and o.textW < o.w:
                    o.x += (o.w - o.textW) // 2
    return out


def svg_of(objects, w, h, ghost=None):
    parts = [
        f'<svg class="panel" width="{w}" height="{h}" viewBox="0 0 {w} {h}">'
    ]
    for o in objects:
        if o.hidden or o.kind == "box":
            continue
        fill = o.rgb or "#888888"
        if o.kind == "rectangle":
            r = o.rounded or 0
            if o.filled:
                parts.append(
                    f'<rect x="{o.x}" y="{o.y}" width="{o.w}" height="{o.h}" '
                    f'rx="{r}" fill="{fill}" />'
                )
            else:
                t = o.thickness or 1
                parts.append(
                    f'<rect x="{o.x + t / 2}" y="{o.y + t / 2}" '
                    f'width="{max(0, (o.w or 0) - t)}" '
                    f'height="{max(0, (o.h or 0) - t)}" rx="{r}" '
                    f'fill="none" stroke="{fill}" stroke-width="{t}" />'
                )
        elif o.kind == "arc":
            r = o.radius or 0
            t = o.thickness or 2
            cx, cy = o.x + r, o.y + r

            def sweep_path(a0, a1, colour, whole=False):
                import math

                # A full turn has to be decided before the modulo, or 0..360
                # reduces to 0..0 and the ring vanishes -- which is exactly
                # what it did on the first pass, leaving a compass pointer
                # with no dial behind it.
                if whole or (a1 - a0) >= 360:
                    return (
                        f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="none" '
                        f'stroke="{colour}" stroke-width="{t}" />'
                    )
                a0 %= 360
                a1 %= 360
                span = (a1 - a0) % 360
                if span == 0:
                    return ""
                x1 = cx + r * math.cos(math.radians(a0))
                y1 = cy + r * math.sin(math.radians(a0))
                x2 = cx + r * math.cos(math.radians(a1))
                y2 = cy + r * math.sin(math.radians(a1))
                large = 1 if span > 180 else 0
                return (
                    f'<path d="M {x1:.1f} {y1:.1f} A {r} {r} 0 {large} 1 '
                    f'{x2:.1f} {y2:.1f}" fill="none" stroke="{colour}" '
                    f'stroke-width="{t}" stroke-linecap="round" />'
                )

            # The background ring first, then the indicator over it. An arc
            # carries both, and drawing only the second leaves a compass as a
            # pointer with no dial.
            if o.bgRgb:
                parts.append(sweep_path(o.bgStart or 0, o.bgEnd or 360,
                                        o.bgRgb, whole=o.bgEnd is None))
            parts.append(sweep_path(o.start or 0, o.end or 0, fill))
        elif o.kind == "label" and o.text:
            height, ascent = FONTS.get(o.font, (17, 13))
            # Drawn on the same baseline the radio uses: a label's top plus
            # its font's ascent. The glyphs will not be EdgeTX's, so the
            # width is forced to the measured one rather than the browser's.
            baseline = o.y + ascent
            size = int(ascent * 1.05)
            parts.append(
                f'<text x="{o.x}" y="{baseline}" font-size="{size}" '
                f'fill="{fill}" textLength="{max(1, o.textW)}" '
                f'lengthAdjust="spacingAndGlyphs">{html.escape(o.text)}</text>'
            )
        elif o.kind == "image":
            parts.append(
                f'<rect x="{o.x}" y="{o.y}" width="{o.w}" height="{o.h}" '
                f'fill="none" stroke="#666" stroke-dasharray="3 3" />'
            )
    # Last, so the panel's own surface does not paint over it.
    if ghost:
        for gx, gy, gw, gh in ghost:
            parts.append(
                f'<rect class="hole" x="{gx}" y="{gy}" width="{gw}" '
                f'height="{gh}" />'
            )
    parts.append("</svg>")
    return "".join(parts)


def hole_of(objects, panel_w):
    """The slack the current arrangement leaves between elements."""
    right = content_right(objects)
    bounds = visual_bounds(objects)
    if bounds is None:
        return []
    vx, vy, vxe, vye = bounds
    if vx - right < 12:
        return []
    if vxe - vx >= (panel_w - PAD * 2) - 2:
        return []
    return [(right, vy, vx - right, vye - vy)]


#: The two arrangements the page now asks about. Vertical alignment is not
#: among them any more: optical centre was chosen, so offering it as a choice
#: would only invite reopening it.
JUSTIFY = [
    ("left-aligned", "left"),
    ("centred", "centre"),
]

cases = rows(G.CASES)
by_zone = {"widget": [], "appmode": []}
slack_rows = []
findings = []

for case in cases:
    objects = [Obj(o) for o in rows(case.objects)]
    w, h = int(case.w), int(case.h)
    classify(objects, w, h)
    hole = hole_of(objects, w)

    pad, content = int(case.pad), int(case.content)
    bounds = visual_bounds(objects)
    spans = bounds is not None and (bounds[2] - bounds[0]) >= content - 2

    variants = [(label, reflow(objects, w, h, pad, content, key))
                for label, key in JUSTIFY]

    gap_note = ""
    if hole:
        reading = next((o for o in objects if o.role == "reading"), None)
        gap = centre_gap(reading) if reading else GAP_LEFT
        gap_note = (
            f'<p class="note gap">Slack between the reading and the '
            f'visual today: <strong>{hole[0][2]} px</strong>. '
            f'Gap in the centred variant: {gap} px.</p>'
        )

    cells = [
        f'<figure><figcaption>today</figcaption>'
        f'<div class="frame">{svg_of(objects, w, h, hole)}</div></figure>'
    ]
    for label, flowed in variants:
        cells.append(
            f'<figure><figcaption>flow &mdash; {label}</figcaption>'
            f'<div class="frame">{svg_of(flowed, w, h)}</div></figure>'
        )

    kind = "none"
    if bounds is not None:
        kind = "full-width bar" if spans else "compact"
    slack_rows.append((case.zone, case.component, case.span,
                       hole[0][2] if hole else 0, kind))

    by_zone[case.zone].append(
        f'<section><h3>{html.escape(case.component)} '
        f'<span class="span">{html.escape(case.span)}</span> '
        f'<span class="px">{w} &times; {h} px</span></h3>'
        f'{gap_note}<div class="row">{"".join(cells)}</div></section>'
    )

def slack_table():
    lines = ['<table><thead><tr><th>zone</th><th>component</th><th>span</th>'
             '<th>slack</th><th>visual</th></tr></thead><tbody>']
    for zone, name, span, slack, kind in slack_rows:
        mark = ' class="has-slack"' if slack else ''
        lines.append(
            f'<tr{mark}><td>{zone}</td><td><code>{html.escape(name)}</code></td>'
            f'<td>{html.escape(span)}</td><td>{slack or ""}</td>'
            f'<td>{kind}</td></tr>'
        )
    lines.append('</tbody></table>')
    return "".join(lines)


slack_table = slack_table()

# How far the centred reading ends up from the left-aligned heading, over
# the cases that actually centre anything. Measured rather than described,
# because "it may look misaligned" is not something a reader can weigh.
offsets = []
for case in cases:
    if case.zone != "widget":
        continue
    objs = [Obj(o) for o in rows(case.objects)]
    cw, ch = int(case.w), int(case.h)
    cpad, ccontent = int(case.pad), int(case.content)
    classify(objs, cw, ch)
    cb = visual_bounds(objs)
    if cb is None or (cb[2] - cb[0]) >= ccontent - 2:
        continue
    head = next((o for o in objs if o.role == "heading"), None)
    moved = reflow(objs, cw, ch, cpad, ccontent, "centre")
    cread = next((o for o in moved if o.role == "reading"), None)
    if head and cread:
        offsets.append((cread.x - head.x, f"{case.component} {case.span}", cw))
worst_offset, worst_offset_case, worst_offset_w = max(offsets, default=(0, "-", 1))
worst_offset_pct = round(worst_offset * 100 / worst_offset_w)

gap_xxl = max(GAP_CENTRE_MIN, FONTS["XXLSIZE"][0] // GAP_CENTRE_DIVISOR)
gap_dbl = max(GAP_CENTRE_MIN, FONTS["DBLSIZE"][0] // GAP_CENTRE_DIVISOR)
gap_mid = max(GAP_CENTRE_MIN, FONTS["MIDSIZE"][0] // GAP_CENTRE_DIVISOR)
gap_sml = max(GAP_CENTRE_MIN, FONTS["SMLSIZE"][0] // GAP_CENTRE_DIVISOR)

# Counted rather than written down, so the prose cannot drift from the mocks
# the way a hand-typed figure did on the first pass.
widget_rows = [r for r in slack_rows if r[0] == "widget"]
widget_total = len(widget_rows)
widget_compact = sum(1 for r in widget_rows if r[4] == "compact")
widget_bar = sum(1 for r in widget_rows if r[4] == "full-width bar")
widget_none = sum(1 for r in widget_rows if r[4] == "none")
widget_slack = sum(1 for r in widget_rows if r[3])
widest = max(slack_rows, key=lambda r: r[3])

page = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<title>AeroGrid content flow &mdash; design mocks</title>
<style>
  body {{ background: {PALETTE['canvas']}; color: #e8ecf1;
    font: 14px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    margin: 0; padding: 32px 40px 80px; }}
  h1 {{ font-size: 24px; margin: 0 0 4px; }}
  h2 {{ font-size: 17px; margin: 44px 0 10px; padding-top: 18px;
    border-top: 1px solid #2b333d; }}
  h3 {{ font-size: 15px; font-weight: 600; margin: 26px 0 8px; }}
  h3.plain {{ color: #cdd5dd; margin-top: 22px; }}
  .span {{ color: {PALETTE['cyan']}; font-weight: 600; }}
  .px {{ color: #7d8794; font-weight: 400; font-size: 13px; }}
  .intro {{ max-width: 62em; color: #b9c2cc; }}
  .intro strong {{ color: #fff; }}
  .warn {{ border-left: 3px solid {PALETTE['amber']}; padding: 10px 16px;
    background: #241f16; margin: 18px 0; max-width: 62em; }}
  .real {{ border-left: 3px solid {PALETTE['cyan']}; padding: 10px 16px;
    background: #16222a; margin: 18px 0; max-width: 62em; }}
  .row {{ display: flex; flex-wrap: wrap; gap: 22px; align-items: flex-start; }}
  figure {{ margin: 0; }}
  figcaption {{ font-size: 12px; color: #8b95a1; margin-bottom: 6px;
    text-transform: uppercase; letter-spacing: .06em; }}
  .frame {{ background: {PALETTE['canvas']}; padding: 6px;
    border: 1px solid #2b333d; border-radius: 4px; display: inline-block; }}
  .panel {{ display: block; }}
  .hole {{ fill: {PALETTE['amber']}; fill-opacity: .16;
    stroke: {PALETTE['amber']}; stroke-opacity: .5; stroke-dasharray: 3 3; }}
  .note {{ font-size: 13px; color: #9aa4b0; margin: 4px 0 10px; }}
  .gap strong {{ color: {PALETTE['amber']}; }}
  code {{ background: #1b2129; padding: 1px 5px; border-radius: 3px;
    font-size: 12.5px; }}
  ul {{ max-width: 62em; color: #b9c2cc; }}
  table {{ border-collapse: collapse; font-size: 13px; margin: 12px 0 8px; }}
  th, td {{ text-align: left; padding: 3px 14px 3px 0;
    border-bottom: 1px solid #242b34; color: #9aa4b0; }}
  th {{ color: #6f7985; font-weight: 600; font-size: 11px;
    text-transform: uppercase; letter-spacing: .06em; }}
  tr.has-slack td {{ color: #d8dee6; }}
  tr.has-slack td:nth-child(4) {{ color: {PALETTE['amber']};
    font-weight: 600; }}
</style></head><body>
<h1>Content flow &mdash; design mocks</h1>
<p class="intro">Every panel below is drawn at its true pixel size from the
real theme, the real region arithmetic and the real measured text widths.</p>

<div class="real"><strong>What is real:</strong> the <em>today</em> column is
not a drawing. Each panel was built through the actual widget host, and its
objects were walked out of the LVGL mock &mdash; every coordinate, font,
colour and string is what the dashboard produces right now. Text is set to
its measured width so the proportions hold, though the browser's glyphs are
not EdgeTX's.</div>

<div class="warn"><strong>What is speculative:</strong> every
<em>proposed</em> column is a transformation applied in
<code>build/flow-render.py</code> to that same geometry. <strong>Nothing in
the widget implements this rule.</strong> It is a proposal for you to judge,
and the numbers under it are what the rule would produce, not what any
component has been changed to do.</div>

<h2>The rule, as implemented for these mocks</h2>
<ul>
  <li>The reading leads. In the left-aligned variant it keeps the content
      box's left edge; in the centred variant the whole group moves together
      and the reading still leads it.</li>
  <li>A secondary element <strong>follows</strong> the reading &mdash; at
      the reading's measured end, plus its unit, plus a gap &mdash; rather
      than being pinned to the right edge.</li>
  <li>A secondary element sits on the <strong>optical centre</strong> of the
      reading's line box. Settled, not offered.</li>
  <li>Supporting rows <strong>follow</strong> the block above them rather
      than being pinned to the panel floor.</li>
  <li>A visual that spans the panel's width by design &mdash; a bar &mdash;
      is left alone. Following the reading would turn it into a stub, and
      that is the first place the rule does more harm than good.</li>
</ul>

<h2>Settled: a secondary element sits on the reading's optical centre</h2>
<p class="intro">This page previously offered baseline, top and optical
centre side by side. <strong>Optical centre was chosen</strong>, so the other
two are gone rather than left here to be re-argued. It is now a rule of the
design system: a compact visual is vertically centred on the reading's line
box, at every span and in every component.</p>

<h2>The open question: left-aligned, or centred</h2>
<p class="intro">Both columns below apply the flow rule. They differ only in
where the group sits.</p>
<ul>
  <li><strong>Left-aligned</strong> keeps the group at the content box's left
      edge and lets all the slack collect after it. The gap between reading
      and visual is a flat 10&nbsp;px, because the gap only has to separate
      two things rather than carry the arrangement.</li>
  <li><strong>Centred</strong> centres the group in the content box, putting
      the slack on both sides. That is what buys room for a wider gap.</li>
</ul>

<h3 class="plain">The gap in the centred variant, and what it took to
choose it</h3>
<p class="intro">A pure proportion was the obvious answer and it was wrong.
A third of the reading's line height keeps the gap consistent against the
number it separates, but measured across the cases that actually occur it
gives <strong>6&nbsp;px at <code>SMLSIZE</code> and 9 at
<code>MIDSIZE</code></strong> &mdash; <em>less</em> than the left-aligned
10, so the centred variant would have looked tighter than the one it is
meant to open up.</p>
<p class="intro">So it is a floor of <strong>{gap_sml}&nbsp;px</strong> with
a proportional term above it, half the reading's line height. A compact
visual costs the reading a font size, so it is never drawn beside an
<code>XXLSIZE</code> number; over the range that does occur the floor binds
at <code>SMLSIZE</code> and <code>MIDSIZE</code> and the proportion binds at
<code>DBLSIZE</code> &mdash; <strong>{gap_sml}, {gap_mid} and
{gap_dbl}&nbsp;px</strong>. Each case below prints the gap it used, so the
claim is checkable rather than asserted.</p>

<div class="warn"><strong>Two things to look at that a static page cannot
settle.</strong>
<p><strong>The header does not centre.</strong> The heading stays left and
the badge stays right, both fixed &mdash; the badge column is reserved on
every panel whether or not a badge is showing, and the specification is
explicit that the heading's width must not depend on the state. So a centred
reading sits under a left-aligned heading, and the gap between them is not
small: <strong>{worst_offset} px</strong> on
<code>{worst_offset_case}</code>, which is
{worst_offset_pct}% of that panel's width. Whether that reads as centred or
as an orphaned heading is visible in the mocks and nowhere else.</p>
<p><strong>Centred content moves when it changes width.</strong> Left
alignment degrades predictably: elements stay where they are and the last one
sheds. A centred group re-centres whenever anything in it changes width, so a
voltage going from <code>9.9</code> to <code>10.0</code> shifts the number
<em>and</em> the battery beside it, every time. On a reading that changes a
digit rarely that is nothing; on one that crosses a digit boundary in flight
it is a visible twitch at the moment attention is on it. No static page can
show that, which is why it is written here instead.</p></div>

<h2>Full screen &mdash; what the shipped dashboards are</h2>
<p class="intro">The <code>sim</code> and <code>sim2</code> screens the user
pages through are Full screen custom screens, so this is the arrangement they
are actually looking at.</p>

{"".join(by_zone["widget"])}

<h2>App mode &mdash; the same panels, and not the same panels</h2>
<div class="warn"><strong>Found while building this, not fixed:</strong> a
panel at the grid's top left in App mode reserves a strip for the menu
button, and that pushes its content down far enough to change what it draws.
A <code>tx-battery</code> at <code>2x1</code> is <strong>65 px tall in App
mode against 53 in Full screen, and it is the taller one that sheds its
battery</strong> &mdash; the reading starts at y=45 rather than y=21, leaving
12 px where the glyph needs 26. A taller panel drawing less than a shorter
one is worth a look on its own, separately from this rule.</div>

{"".join(by_zone["appmode"])}

<h2>Where edge anchoring was doing useful work</h2>
<ul>
  <li><strong>Bars.</strong> A bar's length <em>is</em> the reading &mdash;
      a track that stops short of the panel edge measures against a scale
      the eye cannot see. Every bar here is therefore exempted from the
      rule, which means the rule does not apply to most of
      <code>metric</code>, <code>cell-battery</code>, <code>link-status</code>
      or a barred <code>tx-battery</code> at all.</li>
  <li><strong>Two-column supporting rows.</strong>
      <code>cell-battery</code>, <code>link-status</code> and
      <code>navigation</code> split their supporting row into a left and a
      right column, and the right column is edge-anchored on purpose so the
      two can never collide. Flowing those would need a different rule than
      the one for a single element.</li>
  <li><strong>A panel with no slack.</strong> Where the reading already
      fills its column, following and pinning give the same answer, and the
      rule changes nothing. The mocks show which those are.</li>
</ul>

<h2>How much slack there actually is</h2>
<p class="intro">Measured, per panel, as the distance between where the
reading ends and where the visual begins. Zero means the rule would change
nothing there.</p>
{slack_table}

<h2>Found while building this &mdash; not fixed</h2>
<ul>
  <li><strong>A taller panel drawing less than a shorter one.</strong> A
      <code>tx-battery</code> at <code>2x1</code> is 65 px tall in App mode
      and 53 in Full screen, and it is the <em>taller</em> one that sheds its
      battery. App mode reserves a strip at the grid's top left for the menu
      button, which pushes the reading from y=21 to y=45 and leaves 12 px
      where the glyph needs 26. The same panel also drops from
      <code>MIDSIZE</code> to <code>SMLSIZE</code>.</li>
  <li><strong>The slack is largest exactly where panels are widest.</strong>
      It is not a fixed margin that looks worse when magnified: the worst case
      here is <code>{widest[1]}</code> at <code>{widest[2]}</code>, which
      leaves <strong>{widest[3]} px</strong> between its reading and its
      visual. Every extra cell of width goes into the hole rather than into
      the content.</li>
  <li><strong>The rule reaches less of the catalogue than it first
      appears.</strong> Of the {widget_total} Full screen cases here,
      <strong>{widget_compact}</strong> have a compact visual and would move,
      <strong>{widget_bar}</strong> draw a full-width bar and are exempt, and
      <strong>{widget_none}</strong> have no visual at all &mdash; and only
      <strong>{widget_slack}</strong> actually carry any slack to reclaim. So
      the sweep is narrower than eleven components, though a
      <code>metric</code> with <code>visual: radial</code> is a different case
      from the same component with <code>visual: bar</code>.</li>
</ul>
</body></html>
"""

out = ROOT / "build" / "flow-mocks.html"
out.write_text(page)
print(f"wrote {out}")
for note in findings:
    print(note)
