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


#: The reading ladder, largest first, mirroring `theme.READING_FONTS`.
LADDER = ["XXLSIZE", "DBLSIZE", "MIDSIZE", "SMLSIZE"]


def scaled_width(textW, from_font, to_font):
    """The same string's width at another size.

    Exact under the model the geometry was measured with: `lcd.sizeText` in
    the fixture charges each character a fixed fraction of the line height,
    so a string's width is linear in that height. It is an approximation of a
    radio, in the same way and to the same degree as everything else on this
    page.
    """
    return int(round(textW * FONTS[to_font][0] / FONTS[from_font][0]))


def fit_into(reading, widest_at, width):
    """The largest ladder font whose widest reading and unit fit `width`.

    Sized from the **widest** string the component can ever print, not from
    what it happens to say now, because that is what the dashboard's own
    fitter does and it is the only question worth asking: a `tx-battery`
    reading `7.9` must still hold `88.8` without resizing under the pilot.
    Asking whether the current value fits would have reported no cost at all.

    Returns the font, how many sizes it gave up, and **whether it fits at
    all**. The third value is not decoration: the first version of this
    returned the smallest font and a step count of zero when nothing fitted,
    so a reading that could not live in half a panel was reported as costing
    nothing. That is the same shape as `theme.fitReading` returning the
    smallest font whether or not the text fits, which cost this project a
    defect once already.
    """
    start = LADDER.index(reading.font) if reading.font in LADDER else 0
    for step in range(start, len(LADDER)):
        font = LADDER[step]
        digits, unit = widest_at.get(font, (0, 0))
        need = digits + (GAP_UNIT + unit if unit else 0)
        if need <= width:
            return font, step - start, True
    return LADDER[-1], len(LADDER) - 1 - start, False


#: The air a unit keeps from its reading, from `theme.unitGap`. Small, because
#: a glyph's advance already carries its own bearing.
GAP_UNIT = 2


def apply_font(obj, font):
    """Resize a label, keeping its measured width consistent with its size."""
    if obj is None or obj.font == font:
        return
    obj.textW = scaled_width(obj.textW, obj.font, font)
    obj.lineH = FONTS[font][0]
    obj.font = font


def slot_margin(flowed, pad, content, widest_at, bands=None):
    """Pixels between the reading's slot and the secondary's, at the widest.

    Measured from the **widest** string the component can print, at the font
    it is actually drawn in, because the question is whether the two can ever
    meet rather than whether they meet today. A negative answer is a
    collision. `None` means the panel has no secondary element and the
    question does not arise.
    """
    # Only where the panel actually splits. A full-width bar is exempt from
    # the rule, so measuring a margin against one answers a question nobody
    # asked -- and answers it alarmingly, since a bar starts at the padding
    # and every reading is therefore "past" it.
    if not (bands and bands.get("split")):
        return None
    reading = next((o for o in flowed if o.role == "reading"), None)
    if reading is None:
        return None
    parts = [o for o in flowed if o.role == "visual" and not o.hidden]
    if not parts:
        return None
    vx = min(o.x for o in parts)

    unit = next((o for o in flowed if o.role == "unit" and not o.hidden), None)
    if widest_at and reading.font in widest_at:
        digits, unit_w = widest_at[reading.font]
        widest = digits + (GAP_UNIT + unit_w if unit else 0)
    else:
        widest = reading.textW + (GAP_UNIT + unit.textW if unit else 0)

    # The reading is centred on its slot, so its widest form grows both ways.
    centre = reading.x + (reading.textW
                          + (GAP_UNIT + unit.textW if unit else 0)) // 2
    return vx - (centre + widest // 2)


def bands_for(compact, panel_h, bottom, has_label, has_tertiary):
    """The proportional vertical bands, as (top, height) pairs.

    Label a quarter, body a half, tertiary a quarter; and where a part is
    absent its quarter goes to the body, so the splits are 1/4:1/2:1/4,
    1/4:3/4, 3/4:1/4 or 4/4. Derived from the panel exactly as the halves
    are, which is the point of the rule: a band does not move because of
    what is in it.
    """
    top = compact
    extent = max(1, (panel_h - bottom) - compact)
    quarter = extent // 4

    label_h = quarter if has_label else 0
    tert_h = quarter if has_tertiary else 0
    body_h = extent - label_h - tert_h
    return {
        "label": (top, label_h),
        "body": (top + label_h, body_h),
        "tertiary": (top + label_h + body_h, tert_h),
        "extent": extent,
    }


def band_font(band_h):
    """The largest reading font that fits a band.

    This is the new rule and it inverts the old one. Today the composition
    comes from the box and the font from the composition; here the band comes
    from the panel and the font from the band. The ladder's floor is
    `SMLSIZE`, as `theme.READING_FONTS` has it -- a reading never drops to
    `TINSIZE`, which is a supporting row's size.
    """
    for font in LADDER:
        if FONTS[font][0] <= band_h:
            return font
    return LADDER[-1]


def ink_font(band_h):
    """The largest reading font whose **ink** fits a band.

    `theme.fontHeight` is LVGL's line height: ascent plus descent plus
    leading. What a reading puts on the panel is its ascent, and for digits
    -- which is what every reading in this catalogue is -- there is no
    descender at all. So a band sized against line height carries slack that
    nothing draws into, and choosing by line height picks a font smaller than
    the band can actually hold.

    Ascent is `line_height - base_line`, both compile-time constants of the
    generated fonts, the same pair used for baseline alignment in #45.
    """
    for font in LADDER:
        ascent = FONTS[font][1]
        if ascent <= band_h:
            return font
    return LADDER[-1]


def centre_in_band(band, height):
    """Where a block of `height` starts to sit centred in a band.

    **The font wins.** Where the block is taller than its band it stays
    centred and overflows symmetrically rather than being shrunk to fit. The
    specification is explicit that a reading may drop redundancy and never
    magnitude, and shrinking a number to satisfy a decorative band is paying
    magnitude for layout. The consequence is that on a small panel the bands
    stop being proportional -- which is a finding rather than a failure, and
    the guides in the rendering show exactly where it happens.
    """
    top, band_h = band
    return top + (band_h - height) // 2


#: Where the two slots are centred, as fractions of the content width.
#:
#: Strict halves puts them at the middle of each half -- 25% and 75% -- which
#: guarantees the two can never meet, because each owns a disjoint region.
#: The tightened reading of "3/5 across the left half, 2/5 across the right"
#: moves both inward to 30% and 70%, so they sit 40% apart instead of 50%.
#:
#: That guarantee is what tightening spends. Two centres 40% apart do not own
#: disjoint regions, so a wide reading and a wide secondary can meet in the
#: middle. Every case is checked against the widest string each component can
#: print, and the margins are in the page.
SLOT_STRICT = (0.25, 0.75)
SLOT_TIGHT = (0.30, 0.70)


def halves(objects, panel_w, panel_h, pad, content, widest_at=None,
           compact=0, bottom=0, vertical=False, slots=SLOT_STRICT):
    """The user's third arrangement: two slots derived from the panel.

    The reading is centred in the panel's left half and a secondary element
    in its right half. Unlike both other proposals the positions come from
    the **panel** rather than from the content, so a slot does not move when
    what is in it changes width, and across a row of equal panels every
    reading lands at the same x.

    **A panel with only a reading does not split.** The halves exist to give
    two elements stable slots; with one element there is no second slot to
    protect, and leaving the right half empty would make a one-element panel
    look like a two-element panel with something missing.
    """
    out = [o.copy() for o in objects]
    reading = next((o for o in out if o.role == "reading"), None)
    if reading is None:
        return out, 0, True, None

    unit = next((o for o in out if o.role == "unit" and not o.hidden), None)
    bounds = visual_bounds(out)
    spans = bounds is not None and (bounds[2] - bounds[0]) >= content - 2
    has_visual = bounds is not None and not spans

    half = content // 2
    left_centre = pad + int(round(content * slots[0]))
    right_centre = pad + int(round(content * slots[1]))

    # The slot the reading has to live in, and what that costs it.
    slot = (half - GAP_UNIT * 2) if has_visual else content
    steps, fits = 0, True
    if widest_at:
        font, steps, fits = fit_into(reading, widest_at, slot)
    else:
        font = reading.font
    apply_font(reading, font)
    apply_font(unit, TO_UNIT.get(font, font))

    group = reading.textW + (GAP_UNIT + unit.textW if unit else 0)
    target = left_centre if has_visual else pad + content // 2
    dx = (target - group // 2) - reading.x
    for o in (reading, unit):
        if o is not None:
            o.x += dx

    moved_visual_bottom = bounds[3] if bounds is not None else None
    if has_visual:
        vx, vy, vxe, vye = bounds
        vdx = (right_centre - (vxe - vx) // 2) - vx
        vdy = (reading.y + (reading.lineH - (vye - vy)) // 2) - vy
        for o in out:
            if o.role == "visual" and not o.hidden:
                o.x += vdx
                o.y += vdy
        moved_visual_bottom = vye + vdy

    # The supporting row sits at the bottom, centred as one group across the
    # content box. Taken literally from the description, which is the only
    # honest way to show what it does to a two-column row.
    supporting = [o for o in out if o.role == "supporting" and not o.hidden]
    if supporting:
        left = min(o.x for o in supporting)
        right = max(o.x + o.textW for o in supporting)
        shift = (pad + (content - (right - left)) // 2) - left
        for o in supporting:
            o.x += shift

    bands = None
    if vertical:
        heading = next((o for o in out if o.role == "heading"), None)
        bands = bands_for(compact, panel_h, bottom,
                          heading is not None, bool(supporting))
        bands["split"] = has_visual

        if heading is not None:
            heading.y = centre_in_band(bands["label"], heading.lineH)

        # The font follows the band. A reading occupying four quarters is
        # drawn larger than one occupying two, which is the whole of the new
        # rule -- and it is what settles the collision the bands created,
        # because a font chosen to fit its band cannot overflow it.
        banded = band_font(bands["body"][1])
        if banded != reading.font:
            ratio = FONTS[banded][0] / FONTS[reading.font][0]
            apply_font(reading, banded)
            apply_font(unit, TO_UNIT.get(banded, banded))
            # The secondary element is sized against the reading today, so it
            # follows the reading's new size rather than keeping its own.
            if has_visual:
                vb = visual_bounds(out)
                ax, ay = vb[0], vb[1]
                for o in out:
                    if o.role != "visual" or o.hidden:
                        continue
                    if o.kind == "arc":
                        o.radius = max(6, int(o.radius * ratio))
                        o.thickness = max(2, int(round(
                            (o.thickness or 2) * ratio)))
                    else:
                        o.w = max(2, int(round((o.w or 0) * ratio)))
                        o.h = max(2, int(round((o.h or 0) * ratio)))
                    o.x = ax + int(round((o.x - ax) * ratio))
                    o.y = ay + int(round((o.y - ay) * ratio))
            # Re-place horizontally: the group's width changed with the font.
            group2 = reading.textW + (GAP_UNIT + unit.textW if unit else 0)
            target2 = left_centre if has_visual else pad + content // 2
            dx2 = (target2 - group2 // 2) - reading.x
            for o in (reading, unit):
                if o is not None:
                    o.x += dx2
            if has_visual:
                vb = visual_bounds(out)
                vdx2 = (right_centre - (vb[2] - vb[0]) // 2) - vb[0]
                for o in out:
                    if o.role == "visual" and not o.hidden:
                        o.x += vdx2

        # The reading and whatever shares its band move together, so the
        # optical-centre relationship between them survives the move.
        block_top = reading.y
        block_bottom = reading.y + reading.lineH
        if has_visual:
            vb = visual_bounds(out)
            block_top = min(block_top, vb[1])
            block_bottom = max(block_bottom, vb[3])
        dy = centre_in_band(bands["body"], block_bottom - block_top) - block_top
        for o in out:
            if o.role in ("reading", "unit") or (
                    o.role == "visual" and not o.hidden and has_visual):
                o.y += dy

        if supporting:
            rows_top = min(o.y for o in supporting)
            rows_bottom = max(o.y + o.lineH for o in supporting)
            dy = centre_in_band(bands["tertiary"],
                                rows_bottom - rows_top) - rows_top
            for o in supporting:
                o.y += dy

    return out, steps, fits, bands


#: The unit's font for a given reading font, mirroring `theme.unitFont`:
#: two steps down the ladder wherever there are two.
TO_UNIT = {
    "XXLSIZE": "MIDSIZE",
    "DBLSIZE": "SMLSIZE",
    "MIDSIZE": "SMLSIZE",
    "SMLSIZE": "TINSIZE",
}


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


def svg_of(objects, w, h, ghost=None, bands=None, pad=0, content=0):
    """Draw one panel.

    **Draw order matters and has caught this file out twice.** A panel's
    surface is an opaque filled rectangle, so anything emitted before it is
    painted over and silently disappears. The slack overlay went first and
    was invisible; the band guides went first and were invisible. Both were
    found by rasterising the output and looking at it, not by reading the
    code, because nothing about the emitted SVG is wrong -- the rects are
    there, correct, and underneath.

    The order is therefore: **panel content first, annotations last.** Guides
    and overlays exist to be seen against the content, so they go over it. If
    a third annotation is ever added, it goes at the bottom of this function
    with the others.
    """
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
    # The guides last, over the content. Drawn under it they were invisible:
    # the panel's surface is an opaque filled rectangle and paints over
    # anything emitted before it. The whole value of the guides is seeing
    # where a band is against where its contents actually sit.
    if bands:
        for key in ("label", "body", "tertiary"):
            top, height = bands[key]
            if height <= 0:
                continue
            parts.append(
                f'<rect class="band" x="1" y="{top}" width="{w - 2}" '
                f'height="{height}" />'
            )
        # Only where the panel actually splits. A one-element panel centres
        # across the whole box, so drawing the divider there would show a
        # rule that is not being applied.
        if bands.get("split"):
            half = content // 2
            body_top, body_h = bands["body"]
            parts.append(
                f'<line class="split" x1="{pad + half}" y1="{body_top}" '
                f'x2="{pad + half}" y2="{body_top + body_h}" />'
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


#: Only the left-aligned flow remains of the two content-derived
#: arrangements. Centring was removed rather than kept: it is dominated on
#: both counts the page measures -- 186 px of heading gap against the halved
#: 91 -- and it carries the re-centres-when-content-changes objection that
#: halves exists to avoid. Saying so in the page, because a column vanishing
#: without explanation reads as a decision made for the reader.
JUSTIFY = [
    ("left-aligned", "left"),
]

cases = rows(G.CASES)
by_zone = {"widget": [], "appmode": []}
slack_rows = []
halves_steps = []
ladder_rows = []
collide_rows = []
findings = []

for case in cases:
    objects = [Obj(o) for o in rows(case.objects)]
    w, h = int(case.w), int(case.h)
    classify(objects, w, h)
    hole = hole_of(objects, w)

    pad, content = int(case.pad), int(case.content)
    bounds = visual_bounds(objects)
    spans = bounds is not None and (bounds[2] - bounds[0]) >= content - 2

    variants = [(label, reflow(objects, w, h, pad, content, key), None)
                for label, key in JUSTIFY]
    # Widths of the widest reading the component can print, at the font it
    # is currently drawn in, so the slot question is asked of the string the
    # fitter actually sized for.
    widest_at = {k: (int(case.widestAt[k][1]), int(case.widestAt[k][2]))
                 for k in case.widestAt.keys()} if case.widest else None
    halved, steps, fits, bands = halves(
        objects, w, h, pad, content, widest_at,
        int(case.compact), int(case.bottom), vertical=True)
    tight, _, _, tbands = halves(
        objects, w, h, pad, content, widest_at,
        int(case.compact), int(case.bottom), vertical=True, slots=SLOT_TIGHT)

    # Today's font against the banded one, for the table that made the
    # shared ladder judgeable on paper last time.
    before = next((o for o in objects if o.role == "reading"), None)
    after = next((o for o in halved if o.role == "reading"), None)
    if before is not None and after is not None:
        ladder_rows.append((
            case.zone, case.component, case.span,
            before.font, after.font,
            LADDER.index(after.font) - LADDER.index(before.font)
            if before.font in LADDER and after.font in LADDER else 0,
            bands["body"][1] if bands else 0,
        ))
    step_note = ""
    if not fits:
        step_note = (' <span class="cost">will not fit</span>')
    elif steps:
        step_note = (f' <span class="cost">&minus;{steps} size'
                     f'{"s" if steps > 1 else ""}</span>')
    variants.append(("halves" + step_note, halved, bands))
    variants.append(("halves tightened", tight, tbands))

    # Whether the two slots can still meet, asked of the widest string each
    # component prints rather than what it happens to say. Strict halves
    # cannot collide by construction; tightened can, and this is what says
    # whether it does.
    gapmin = slot_margin(tight, pad, content, widest_at, tbands)
    if gapmin is not None:
        collide_rows.append((
            case.zone, case.component, case.span, gapmin,
            slot_margin(halved, pad, content, widest_at, bands)))
    halves_steps.append((case.zone, case.component, case.span, steps, fits))

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
    for label, flowed, bands_of in variants:
        cells.append(
            f'<figure><figcaption>flow &mdash; {label}</figcaption>'
            f'<div class="frame">'
            f'{svg_of(flowed, w, h, bands=bands_of, pad=pad, content=content)}'
            f'</div></figure>'
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

def ladder_table():
    lines = ['<table><thead><tr><th>component</th><th>span</th>'
             '<th>body band</th><th>today</th><th>banded</th><th>change</th>'
             '</tr></thead><tbody>']
    for zone, name, span, old, new, delta, band_h in ladder_rows:
        if zone != "widget":
            continue
        if delta < 0:
            note, cls = f"+{-delta} larger", ' class="better"'
        elif delta > 0:
            note, cls = f"&minus;{delta} smaller", ' class="has-slack"'
        else:
            note, cls = "unchanged", ""
        lines.append(
            f'<tr{cls}><td><code>{html.escape(name)}</code></td>'
            f'<td>{html.escape(span)}</td><td>{band_h} px</td>'
            f'<td>{old}</td><td>{new}</td><td>{note}</td></tr>'
        )
    lines.append('</tbody></table>')
    return "".join(lines)


def ink_table():
    """Band height, the two font choices, and what each fills the band with."""
    seen = {}
    for zone, name, span, old, new, delta, band_h in ladder_rows:
        if zone != "widget" or band_h <= 0:
            continue
        seen.setdefault((name, span), (old, new, band_h))

    lines = ['<table><thead><tr><th>component</th><th>span</th>'
             '<th>body band</th><th>today</th>'
             '<th>banded by line height</th><th>ink fills</th>'
             '<th>banded by ink</th><th>ink fills</th></tr></thead><tbody>']
    for (name, span), (old, banded, band_h) in seen.items():
        inked = ink_font(band_h)
        occ_line = 100 * FONTS[banded][1] // band_h
        occ_ink = 100 * FONTS[inked][1] // band_h
        cls = ' class="better"' if inked != banded else ''
        lines.append(
            f'<tr{cls}><td><code>{html.escape(name)}</code></td>'
            f'<td>{html.escape(span)}</td><td>{band_h} px</td>'
            f'<td>{old}</td><td>{banded}</td><td>{occ_line}%</td>'
            f'<td>{inked}</td><td>{occ_ink}%</td></tr>'
        )
    lines.append('</tbody></table>')
    return "".join(lines)


def collide_table():
    lines = ['<table><thead><tr><th>component</th><th>span</th>'
             '<th>strict halves</th><th>tightened</th><th></th>'
             '</tr></thead><tbody>']
    for zone, name, span, tight, strict in collide_rows:
        if zone != "widget":
            continue
        note, cls = "", ""
        if tight is not None and tight < 0:
            note, cls = f"overlap of {-tight} px", ' class="has-slack"'
        elif tight is not None and tight < 8:
            note = "close"
        lines.append(
            f'<tr{cls}><td><code>{html.escape(name)}</code></td>'
            f'<td>{html.escape(span)}</td>'
            f'<td>{strict if strict is not None else "&mdash;"} px</td>'
            f'<td>{tight} px</td><td>{note}</td></tr>'
        )
    lines.append('</tbody></table>')
    return "".join(lines)


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
ladder_table = ladder_table()
collide_table = collide_table()
ink_table = ink_table()

# How full each distinct band is, before and after, and whether a descender
# would leave it. Digits have none; units and labels do.
_bands = sorted({r[6] for r in ladder_rows if r[0] == "widget" and r[6] > 0})
ink_rows = []
for _b in _bands:
    _line, _ink = band_font(_b), ink_font(_b)
    _over = FONTS[_ink][0] - FONTS[_ink][1] - (_b - FONTS[_ink][1]) // 2
    ink_rows.append((_b, _line, 100 * FONTS[_line][1] // _b,
                     _ink, 100 * FONTS[_ink][1] // _b,
                     max(0, FONTS[_ink][0] - FONTS[_ink][1]
                         - (_b - FONTS[_ink][1]) // 2)))
ink_band_count = len(ink_rows)
ink_band_rows = "".join(
    '<tr{cls}><td>{band} px</td><td>{line}</td><td>{occ_l}%</td>'
    '<td>{ink}</td><td>{occ_i}%</td><td>{over}</td></tr>'.format(
        cls=' class="better"' if line != ink else "",
        band=band, line=line, occ_l=occ_l, ink=ink, occ_i=occ_i,
        over=f"+{over} px" if over else "none")
    for band, line, occ_l, ink, occ_i, over in ink_rows
)
ink_moves = sum(1 for r in ink_rows if r[1] != r[3])
ink_best = max((r[4] for r in ink_rows), default=0)
ink_worst = min((r[4] for r in ink_rows), default=0)
line_worst = min((r[2] for r in ink_rows), default=0)
line_best = max((r[2] for r in ink_rows), default=0)

_c = [r for r in collide_rows if r[0] == "widget"]
collide_tight = sum(1 for r in _c if r[3] is not None and r[3] < 0)
collide_strict = sum(1 for r in _c if r[4] is not None and r[4] < 0)
collide_total = len(_c)

_w = [r for r in ladder_rows if r[0] == "widget"]
ladder_same = sum(1 for r in _w if r[5] == 0)
ladder_larger = sum(1 for r in _w if r[5] < 0)
ladder_smaller = sum(1 for r in _w if r[5] > 0)
ladder_total = len(_w)

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

# The same panel under halves, so the three arrangements are compared on one
# number rather than three descriptions.
halves_offset = 0
fit_ok = fit_total = 0
for case in cases:
    if case.zone != "widget":
        continue
    objs = [Obj(o) for o in rows(case.objects)]
    cw, ch = int(case.w), int(case.h)
    cpad, ccontent = int(case.pad), int(case.content)
    classify(objs, cw, ch)
    if not any(o.role == "reading" for o in objs):
        continue
    wa = {k: (int(case.widestAt[k][1]), int(case.widestAt[k][2]))
          for k in case.widestAt.keys()} if case.widest else None
    moved, _, ok, _bands = halves(objs, cw, ch, cpad, ccontent, wa)
    fit_total += 1
    fit_ok += 1 if ok else 0
    if f"{case.component} {case.span}" == worst_offset_case:
        head = next((o for o in objs if o.role == "heading"), None)
        hr = next((o for o in moved if o.role == "reading"), None)
        if head and hr:
            halves_offset = hr.x - head.x
halves_offset_pct = round(halves_offset * 100 / worst_offset_w)

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
  .band {{ fill: none; stroke: {PALETTE['cyan']}; stroke-opacity: .30;
    stroke-width: 1; stroke-dasharray: 2 3; }}
  .split {{ stroke: {PALETTE['cyan']}; stroke-opacity: .22;
    stroke-width: 1; stroke-dasharray: 2 3; }}
  .note {{ font-size: 13px; color: #9aa4b0; margin: 4px 0 10px; }}
  .gap strong {{ color: {PALETTE['amber']}; }}
  .cost {{ color: {PALETTE['critical']}; font-weight: 600;
    text-transform: none; letter-spacing: 0; }}
  td.bad {{ color: {PALETTE['amber']}; }}
  tr.better td {{ color: #d8dee6; }}
  tr.better td:last-child {{ color: {PALETTE['green']}; font-weight: 600; }}
  tr.has-slack td:last-child {{ color: {PALETTE['amber']};
    font-weight: 600; }}
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

<h2>The open question: left-aligned, centred, or halves</h2>
<p class="intro">Both columns below apply the flow rule. They differ only in
where the group sits.</p>
<ul>
  <li><strong>Left-aligned</strong> keeps the group at the content box's left
      edge and lets all the slack collect after it. The gap between reading
      and visual is a flat 10&nbsp;px, because the gap only has to separate
      two things rather than carry the arrangement.</li>
  <li><strong>Halves</strong> splits the panel: the reading centred in the
      left half, the secondary element centred in the right. A panel with
      only a reading <strong>does not split</strong> &mdash; the reading
      centres across the whole panel, because the halves exist to give two
      elements stable slots and with one element there is no second slot to
      protect.</li>
  <li><strong>Halves tightened</strong> is the same split with the two slots
      moved inward, so the elements sit closer together.</li>
</ul>

<div class="warn"><strong>The <em>centred</em> column has been removed.</strong>
It is dominated on both things this page measures: its reading sits
{worst_offset}&nbsp;px from its heading against the halved
{halves_offset}, and it re-centres whenever its contents change width, which
is the objection halves was chosen to avoid. Saying so rather than letting a
column vanish &mdash; if you want it back, it is a one-line change.</div>

<h3 class="plain">Where the tightened slots are</h3>
<p class="intro">The slots are centred at <strong>30% and 70% of the content
width</strong>, against strict halves' 25% and 75% &mdash; 40% apart instead
of 50%. Worth noting that the two readings of the instruction agree: three
fifths across the left half is 0.6 &times; 50% = 30%, and two fifths across
the right half is 50% + 0.4 &times; 50% = 70%. The literal reading and the
summary give the same number, so there is nothing to choose between.</p>

<h3 class="plain">What tightening spends</h3>
<p class="intro"><strong>Strict halves cannot collide.</strong> Each element
owns a disjoint region, so no string, however wide, can reach the other.
Moving the centres inward gives that up: the two now have overlapping
territory and only the actual widths keep them apart. Measured against the
<strong>widest</strong> string each component can print, at the font it is
drawn in:</p>

{collide_table}

<p class="intro">{collide_tight} of {collide_total} cases overlap when
tightened, against {collide_strict} under strict halves.</p>
<ul>
  <li><code>tx-battery</code> and <code>metric-radial</code> are comfortable
      everywhere &mdash; 29&nbsp;px clear at the tightest.</li>
  <li><strong><code>navigation</code> at <code>2x2</code> is the case
      tightening breaks</strong>: 19&nbsp;px clear under strict halves,
      5&nbsp;px of overlap when tightened. A <code>888.88km</code> distance
      and the dial would meet.</li>
  <li><strong><code>navigation</code> at <code>1x1</code> overlaps under
      both</strong>, by 15&nbsp;px strict and 26 tightened &mdash; so that
      one is not tightening's fault. It is the same panel whose reading does
      not fit half a box at all, and the real component already resolves it
      by dropping the dial rather than clipping a distance whose unit carries
      its scale. A one-element panel does not split, so the collision never
      happens on a radio.</li>
</ul>
<p class="intro"><strong>The fractions have not been widened back to hide
this.</strong> One span of one component overlaps by five pixels, and the
answer might reasonably be that <code>navigation</code> falls back to strict
halves rather than that the tightening is wrong &mdash; it is already the
component that yields its dial when a distance will not fit, so it has a
precedent for being the exception. That is a decision to make rather than
one to paper over.</p>
<p class="intro">Tightening is horizontal only. It changes no band and no
font, which the table below should confirm.</p>

<div class="real"><strong>Why halves is different in kind.</strong> Left and
centred both derive positions from <em>content width</em>. Halves derives
them from the <em>panel</em>. A slot does not move because its contents
changed, and across a row of equal-width panels every reading lands at the
same x &mdash; which answers both objections to centring at once. What
follows is what it costs.</div>

<h3 class="plain">Does half a panel hold a reading?</h3>
<p class="intro">Asked of the <strong>widest</strong> string each component
can print, not what it happens to say &mdash; a <code>tx-battery</code>
reading <code>7.9</code> must still hold <code>88.8</code> without resizing
under the pilot. Measured with <code>lcd.sizeText</code> at every font on the
ladder.</p>
<p class="intro"><strong>{fit_ok} of {fit_total} cases fit with no change of
size at all.</strong> The exception is <code>navigation</code> at
<code>1x1</code>: <code>888.88km</code> needs 60&nbsp;px and half that panel
is 48, and the reading is already at <code>SMLSIZE</code>, the bottom of the
reading ladder, so there is nothing left to give.</p>
<p class="intro">That case resolves itself, and worth knowing why. The
component already drops its dial rather than let a distance clip &mdash; a
distance's unit changes with range, so it cannot be shortened. With the dial
gone the panel has one element, and under this rule a one-element panel does
not split. So <code>navigation</code> at <code>1x1</code> centres across the
whole panel and the slot problem never arises.</p>

<h3 class="plain">Vertical bands, and where they meet fixed font heights</h3>
<p class="intro">The halves column also applies proportional vertical bands:
label a quarter, primary and secondary a half, tertiary a quarter &mdash;
and where a part is absent its quarter goes to the body. The faint dashed
guides in that column are the bands; the content is where it actually sits.
<strong>The gap between the two is the finding.</strong></p>

<p class="intro"><strong>The font wins.</strong> Where a block is taller than
its band it stays centred and overflows rather than shrinking. The
specification is explicit that a reading may drop redundancy and never
magnitude, and shrinking a number to satisfy a decorative band is paying
magnitude for layout. So the bands are advisory, and on a small panel they
stop being proportional.</p>

<table><thead><tr><th>panel</th><th>bands L/B/T</th><th>what overflows</th>
</tr></thead><tbody>
<tr><td>117&times;53, 238&times;53</td><td>11 / 36 / &mdash;</td>
  <td class="bad">label by 6&nbsp;px, on every component</td></tr>
<tr><td>238&times;111, 480&times;111</td><td>25 / 51 / 25</td>
  <td class="bad">tertiary by 11&nbsp;px, <code>navigation</code> only</td></tr>
</tbody></table>

<p class="intro"><strong>The small-panel failure cannot be fixed by
shrinking.</strong> A quarter of a 53&nbsp;px panel is 11&nbsp;px and the
smallest font the dashboard has is <code>TINSIZE</code> at 12. There is no
font that fits that band, so "let the band win" is not an option there
&mdash; only "let the font win", which is what is rendered, or "fall back to
today's stacking below some size".</p>

<p class="intro"><strong>The body band never fails</strong>, which was not
obvious in advance. A 53&nbsp;px panel looks as if a half &mdash; 23&nbsp;px
&mdash; could not hold a 29&nbsp;px <code>MIDSIZE</code> reading. But those
panels shed their tertiary row, so the split is 1/4 : 3/4 and the body gets
36, which holds the tallest block any of them draws. The proportional rule
rescues itself exactly where it looked weakest.</p>

<p class="intro"><strong><code>navigation</code>'s tertiary is the one case
that could be shrunk.</strong> It puts two rows there &mdash; a bearing
beside an orientation, with coordinates beneath &mdash; needing 36&nbsp;px in
a 25&nbsp;px band. Two <code>TINSIZE</code> rows would be 24 and would fit,
at the cost of making the smallest text on the panel smaller still. Rendered
as overflow rather than shrunk, so you can see what is being traded.</p>

<p class="intro"><strong>The dial fits its band.</strong> It was worth
checking, since today it is sized against the whole content box: at
<code>2x2</code> and <code>4x2</code> the body block including the dial is
44&nbsp;px against a 51&nbsp;px band.</p>

<div class="warn"><strong>So the honest summary is that the proportional
model works above a size and not below it.</strong> At 111&nbsp;px panels it
holds everywhere except <code>navigation</code>'s tertiary. At 53&nbsp;px the
label band is wrong on every component and cannot be made right by any font
the dashboard has. A rule that applies at two rows and falls back to today's
stacking at one is a legitimate answer; a rule that claims to be universal
would not be.</div>

<h3 class="plain">What the band-derived font does to the ladder</h3>
<p class="intro"><strong>This is the most important table on the page.</strong>
The font now comes from the band, and the band from the panel &mdash; which
inverts today's rule, where the composition comes from the box and the font
from the composition. Every component at every span, today's reading font
against the banded one:</p>

{ladder_table}

<p class="intro"><strong>{ladder_larger} of {ladder_total} get larger,
{ladder_same} are unchanged, and none gets smaller.</strong> That is the
opposite of what was expected, and the reason is worth following, because it
is a fact about the panels rather than about the rule.</p>

<ul>
  <li><strong>A 53&nbsp;px panel has no tertiary row</strong> &mdash; it
      sheds it, at every width. So the split is 1/4 : 3/4 and the body gets
      36&nbsp;px, which holds <code>MIDSIZE</code> at 29. Today's ladder
      gives those panels <code>SMLSIZE</code>. The band is more generous than
      the ladder, not less.</li>
  <li><strong><code>XXLSIZE</code> is not lost at <code>2x2</code>, because
      it is not there to lose.</strong> A Full screen <code>2x2</code> is
      111&nbsp;px, and today's ladder already gives it <code>DBLSIZE</code>.
      The 69&nbsp;px <code>XXLSIZE</code> reading belongs to the 134&nbsp;px
      App mode panel, not to this one. The banded font matches today's
      exactly at every <code>2x2</code> and <code>4x2</code>, except
      <code>navigation</code>, which gains a size.</li>
  <li><strong><code>navigation</code> is the one that changes at the large
      spans</strong>, from <code>MIDSIZE</code> to <code>DBLSIZE</code>. It
      draws two tertiary rows where the others draw one, so today's ladder
      charges it for both; the band charges a flat quarter whatever is in
      it.</li>
</ul>

<div class="warn"><strong>App mode goes the other way and is worth a
separate look.</strong> The same table over App mode's taller panels moves
12 of 24 cases by <strong>two</strong> sizes &mdash; <code>SMLSIZE</code> to
<code>DBLSIZE</code> on a 65&nbsp;px panel, because a 59&nbsp;px extent gives
a 45&nbsp;px body band and <code>DBLSIZE</code> is 40. Whether a 40&nbsp;px
reading on a 65&nbsp;px panel is an improvement or a panel with nothing but
a number on it is a judgement, and it is the largest single change this
proposal would make anywhere.</div>

<p class="intro"><strong>The stability guarantee survives, and for free.</strong>
Today's fitter sizes a reading against the widest string a component can ever
print, so a value never resizes as it changes. A band-derived font does not
consult the content at all, so it cannot resize with it &mdash; the guarantee
holds by construction rather than by discipline. That is the strongest
argument for the new rule, and it is stronger than the one it replaces:
today's guarantee depends on every component remembering to pass its widest
form, and this one does not.</p>

<p class="intro"><strong>The secondary element follows the reading's new
size.</strong> It is sized against the reading today, so a larger reading
means a larger glyph and a larger dial. On the 53&nbsp;px panels, where the
reading gains a size, <code>navigation</code>'s dial grows with it &mdash;
and that is the element with the least room to spare, so it is the one to
look at in the mocks rather than to reason about here.</p>

<h3 class="plain">"At least 80% of their vertical allotment"</h3>
<p class="intro">Not implemented as a literal filter, because
<code>fontHeight &ge; 0.8 &times; band</code> together with
<code>fontHeight &le; band</code> is a window a five-step ladder often has no
member in. The question underneath it is measurable, and the answer is that
<strong>the band is being measured against the wrong thing.</strong></p>

<p class="intro"><code>theme.fontHeight</code> is LVGL's line height: ascent
plus descent plus leading. What a reading puts on the panel is its
<em>ascent</em> &mdash; and every reading in this catalogue is digits, a
minus, a decimal point or a colon, none of which descend. So a band sized
against line height carries slack nothing draws into. Ascent is
<code>line_height &minus; base_line</code>, both compile-time constants of
the shipped fonts, the pair already used for baseline alignment.</p>

{ink_table}

<p class="intro">Per distinct band, which is where the pattern is clearer
than per component:</p>
<table><thead><tr><th>band</th><th>by line height</th><th>ink fills</th>
<th>by ink</th><th>ink fills</th><th>descender past the band</th></tr></thead>
<tbody>{ink_band_rows}</tbody></table>

<p class="intro"><strong>Choosing by line height fills
{line_worst}&ndash;{line_best}% of a band with ink. Choosing by ink reaches
{ink_best}%</strong> on the bands where the ladder has a step to move to
&mdash; {ink_moves} of the {ink_band_count} distinct body bands the Full
screen panels produce.</p>

<div class="warn"><strong>The 80% target is unreachable on the larger
band, and not because of the measurement.</strong> A 51&nbsp;px body band
takes <code>DBLSIZE</code>, which is 31&nbsp;px of ink and 60% of the band.
The next step up is <code>XXLSIZE</code> at 54&nbsp;px of ink, which does not
fit by either measure. So there the gap is the <strong>ladder's
granularity</strong> rather than the metric: the steps are 12, 17, 29, 40 and
69&nbsp;px, and between 40 and 69 there is nothing. Reaching 80% on every
band would mean a denser ladder, which is a different change from this one
and a larger one.</div>

<p class="intro"><strong>What choosing by ink costs.</strong> A descender now
crosses the band's floor, by up to 7&nbsp;px. Readings are safe &mdash; no
digit, minus, point or colon descends &mdash; but a unit does: the
<code>p</code> in <code>mph</code>, and any heading with a <code>y</code> or
a <code>g</code>. The unit rides two ladder steps below the reading, so its
own descender is 4&nbsp;px at <code>SMLSIZE</code> rather than 9, and on the
53&nbsp;px panels that still lands inside the panel. It does leave the
<em>band</em>, so bands stop being private the moment fonts are chosen by
ink.</p>

<div class="warn"><strong>This reopens a settled rule, so it is flagged
rather than changed.</strong> The optical-centre rule centres a secondary
element on the reading's <strong>line box</strong>. That was decided from
rendered mocks and is in the specification. If the font is chosen by ink, the
line box and the ink stop agreeing &mdash; a <code>DBLSIZE</code> line box is
40&nbsp;px around 31&nbsp;px of ink, so centring on the box puts a dial
4&nbsp;px below the visual centre of the digits beside it. The mocks still
centre on the line box, as settled. If ink-chosen fonts are adopted, that
rule wants revisiting, and it is yours to revisit rather than mine to
change.</div>

<h3 class="plain">How far the reading ends up from its heading</h3>
<p class="intro">The heading is immovably left, so every arrangement that
moves the reading rightwards opens a gap under it. On the panel where it is
worst, <code>{worst_offset_case}</code>:</p>
<table><thead><tr><th>arrangement</th><th>reading&rsquo;s distance from the
heading</th></tr></thead><tbody>
<tr><td>left-aligned</td><td>0 px &mdash; they share an edge</td></tr>
<tr class="has-slack"><td>centred</td><td>{worst_offset} px
  ({worst_offset_pct}% of the panel)</td></tr>
<tr><td>halves</td><td>{halves_offset} px
  ({halves_offset_pct}% of the panel)</td></tr>
</tbody></table>
<p class="intro">Halves sits about half as far out as fully centred, because
it centres in a half rather than in the whole. Whether that is close enough
to the heading to read as deliberate is the judgement the mocks are for.</p>

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

<h2>The objection that ruled out centring, and whether halves escapes it</h2>
<div class="warn"><p>Centring was marked down because a centred group
re-centres whenever its contents change width. Halves derives positions from
the panel, so it does not have that problem &mdash; <strong>except in one
place, and it is worth knowing before committing to the rule.</strong></p>

<p>Under this rule a panel with two elements splits and a panel with one does
not. So anything that makes a visual appear or disappear changes the
arrangement. Across the catalogue that is almost always a question of
<em>space</em>, which only changes when the zone does. <strong>One component
gates its visual on <em>data</em>:</strong> <code>tx-battery</code> hides its
battery until there is a voltage range to measure against, and that range is
a live subscription to <code>getGeneralSettings</code> rather than something
read once.</p>

<p>Two consequences. The range is not known when the panel is built, so the
battery appears a frame or two later and <strong>the reading moves from the
panel's centre to its left half during start-up, every time</strong>. And a
pilot editing SYS &rarr; Hardware &rarr; Battery meter range would move it
again, in flight &mdash; which is precisely the objection that ruled out
centring, reappearing in the arrangement chosen to avoid it.</p>

<p>It is confined to one component and is fixable &mdash; reserving the slot
whenever the layout could ever show a visual, rather than when one is
currently drawn, would hold the reading still at the cost of a permanently
empty right half on a panel that never gets a range. That is a real trade and
the user should make it rather than discover it.</p></div>

<h2>Found while building this &mdash; not fixed</h2>
<ul>
  <li><strong>The same component places its reading by two rules at two
      spans.</strong> <code>tx-battery</code> sheds its battery at
      <code>1x1</code> and <code>metric</code> its radial, so those panels
      centre across the whole box while their larger siblings split. Both are
      in the page; judge whether it reads as inconsistent or as sensible.</li>
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
