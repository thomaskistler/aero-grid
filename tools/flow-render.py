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


def place_unit(reading, unit):
    """Put the unit back where the reading now ends.

    **This is the defect this project has now hit six times**, and the sixth
    was in this file: something decides a size and something else draws at a
    position computed for the old one. Resizing a reading from `SMLSIZE` to
    `MIDSIZE` widens `-72` by 13 px, and a unit shifted by the reading's
    delta rather than re-placed against its new end lands 13 px inside the
    digits. It showed as `dBm` printed over `-72` on exactly the panels
    where the band moved the font, and not on the panels where it did not --
    which is why two spans of the same width behaved differently.

    So placement is derived from the reading's current width every time,
    mirroring `theme.placeUnit`, rather than carried along as an offset. The
    vertical is the shared baseline from #45: both sit so that
    `y + ascent` is the same line.
    """
    if reading is None or unit is None:
        return
    unit.x = reading.x + reading.textW + GAP_UNIT
    unit.y = reading.y + FONTS[reading.font][1] - FONTS[unit.font][1]


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


def bands_for(compact, panel_h, bottom, has_label, has_tertiary,
              floor_h=0, content_top=None, body=None):
    """The proportional vertical bands, as (top, height) pairs.

    **`body` is the widget's own answer, and it wins when it is offered.**
    This function reimplemented `theme.bands` and got two things wrong that
    the dashboard gets right, which is how the page came to promise fourteen
    readings would grow when the implementation grows none. A generator that
    re-derives what the code already computes will drift from it; the
    geometry rig now reports the real band and the page renders that.

    Label a quarter, body a half, tertiary a quarter; and where a part is
    absent its quarter goes to the body. Derived from the panel exactly as
    the slots are, which is the point of the rule: a band does not move
    because of what is in it.

    **Two corrections, and they are why the font table on this page changed.**
    The first version of this function over-measured the body band in two
    ways, and the fonts it predicted were wrong as a result -- it promised
    fourteen readings would grow and none shrink, where the implementation
    measures none growing and two shrinking.

    *A bar is floor furniture, not band contents.* The tertiary quarter was
    reserved only for supporting rows, so a panel drawing a bar got a
    three-quarter body running down to the panel's own floor -- and a reading
    sized against that band lies straight across the bar. A bar's height is
    fixed by the theme and does not grow with the panel, so it takes what it
    needs rather than a proportion.

    *A heading that overflows its band pushes the body down.* On a short panel
    the label quarter is smaller than any font the dashboard has, so the
    heading keeps its size and spills. The body has to start below where the
    heading actually ends, not below its nominal quarter.
    """
    top = compact
    extent = max(1, (panel_h - bottom) - compact)
    quarter = extent // 4

    label_h = quarter if has_label else 0
    tert_h = quarter if has_tertiary else floor_h
    body_top = top + label_h
    if has_label and content_top is not None and content_top > body_top:
        body_top = content_top
    body_h = max(1, (top + extent) - tert_h - body_top)
    if body is not None:
        body_top, body_h = body
        tert_h = max(0, (top + extent) - (body_top + body_h))
    return {
        "label": (top, label_h),
        "body": (body_top, body_h),
        "tertiary": (body_top + body_h, tert_h),
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


def ink_span(obj):
    """Where an object's ink sits within its line box, as (offset, height).

    LVGL lays a label out in a line box of `line_height`, with the baseline
    `base_line` up from its floor -- so the glyphs occupy the top `ascent`
    pixels and the remaining `base_line` is descent and leading. Every
    reading in this catalogue is digits, a minus, a point or a colon, none of
    which descend, so that tail is empty. The offset is therefore zero and
    the height is the ascent: **the ink is flush with the top of the line box
    and the slack is all underneath it.**

    That asymmetry is the whole of the finding below. Centring the line box
    centres the slack along with the ink, which lifts the digits above the
    middle of whatever they are centred in.
    """
    height, ascent = FONTS.get(obj.font, (17, 13))
    return 0, ascent


def clamp_to_panel(y, obj, panel_h):
    """Keep a label's ink inside the panel, whatever its band says.

    **The font wins, and then it is clamped.** On a 53 px panel the label
    band is 11 px and the heading is drawn at `SMLSIZE`, 17 -- and the
    smallest font the dashboard has is `TINSIZE` at 12, so "let the band
    win" is not an available answer there. Centring the heading in a band
    smaller than itself puts a pixel of it above the panel's top edge, where
    it is simply clipped.

    So the band yields and the panel does not. The bands stop being exactly
    proportional at the bottom of the size range, and nothing is ever drawn
    off the panel.

    The alternative -- falling back to today's stacking below a threshold --
    was rejected deliberately. **Two layout rules with a size threshold
    between them is a worse thing to own than one rule that bends at the
    bottom of its range**: every component, every span and every future
    addition then has to be reasoned about twice, once on each side of a
    line whose position is itself arbitrary.
    """
    off, ink = ink_span(obj)
    top = max(0, y + off)
    top = min(top, max(0, panel_h - ink))
    return top - off


def optical_dy(reading, vy, vye, centre_rule):
    """How far a secondary element moves to sit on the reading's centre.

    Under `box` that centre is the middle of the reading's line box, which
    is the settled rule. Under `ink` it is the middle of the glyphs alone.
    They differ by half the `base_line`, and since that slack is all below
    the digits, centring on the box drops the element below the number's
    visual middle.
    """
    ink_off, ink_h = ink_span(reading)
    if centre_rule == "ink":
        top, height = reading.y + ink_off, ink_h
    else:
        top, height = reading.y, reading.lineH
    return (top + (height - (vye - vy)) // 2) - vy


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
           compact=0, bottom=0, vertical=False, slots=SLOT_STRICT,
           font_rule="line", centre_rule="box", content_top=None,
           body=None):
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
    reading.x += dx
    place_unit(reading, unit)

    moved_visual_bottom = bounds[3] if bounds is not None else None
    if has_visual:
        vx, vy, vxe, vye = bounds
        vdx = (right_centre - (vxe - vx) // 2) - vx
        vdy = optical_dy(reading, vy, vye, centre_rule)
        for o in out:
            if o.role == "visual" and not o.hidden:
                o.x += vdx
                o.y += vdy
        moved_visual_bottom = vye + vdy

    # Every row uses the panel's two slots, not just the body. A row holding
    # one item centres it across the whole content box, exactly as a lone
    # reading does; a row holding two puts them on the same 30% and 70%
    # centres the reading and its visual use. That makes the arrangement one
    # rule applied at every level rather than a body rule plus a footer
    # special case -- which is worth more than the appearance, because it is
    # the difference between something extensible and something to memorise.
    supporting = [o for o in out if o.role == "supporting" and not o.hidden]
    for items in group_rows(supporting):
        slot_row(items, pad, content, slots)

    bands = None
    if vertical:
        heading = next((o for o in out if o.role == "heading"), None)
        # A bar takes the floor, not a share. `bounds` is the whole visual
        # extent, and a visual that spans the content width is a bar.
        floor_h = 0
        if bounds is not None and spans:
            floor_h = (panel_h - bottom) - bounds[1]
        bands = bands_for(compact, panel_h, bottom,
                          heading is not None, bool(supporting),
                          floor_h, content_top, body)
        bands["split"] = has_visual

        if heading is not None:
            heading.y = clamp_to_panel(
                centre_in_band(bands["label"], heading.lineH),
                heading, panel_h)

        # The font follows the band. A reading occupying four quarters is
        # drawn larger than one occupying two, which is the whole of the new
        # rule -- and it is what settles the collision the bands created,
        # because a font chosen to fit its band cannot overflow it.
        banded = (ink_font if font_rule == "ink" else band_font)(
            bands["body"][1])
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
            reading.x += dx2
            place_unit(reading, unit)
            if has_visual:
                vb = visual_bounds(out)
                vdx2 = (right_centre - (vb[2] - vb[0]) // 2) - vb[0]
                # And re-centre it vertically. Both the reading's box and the
                # element's height changed with the font, so the optical
                # centring struck before the change no longer holds -- and
                # this page exists partly to show what that centring does,
                # so it has to be the real relationship and not a stale one.
                vdy2 = optical_dy(reading, vb[1], vb[3], centre_rule)
                for o in out:
                    if o.role == "visual" and not o.hidden:
                        o.x += vdx2
                        o.y += vdy2

        # The reading and whatever shares its band move together, so the
        # optical-centre relationship between them survives the move.
        #
        # **What counts as the block's extent is the placement question.**
        # Under `box` it is the reading's line box, which is the settled
        # rule; under `ink` it is only the part of that box a digit actually
        # marks. They differ by `base_line`, all of it below the glyphs, so
        # centring the box lifts the digits above the band's middle by half
        # of it. The band guides in the rendering show the difference.
        ink_off, ink_h = ink_span(reading)
        if centre_rule == "ink":
            block_top = reading.y + ink_off
            block_bottom = block_top + ink_h
        else:
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


def group_rows(items):
    """Supporting labels grouped into the rows they are drawn on.

    Grouped by their drawn `y` rather than by any declared structure,
    because the dump is geometry: what makes two labels a row is that the
    component put them on the same line.
    """
    byline = {}
    for o in items:
        byline.setdefault(o.y, []).append(o)
    return [sorted(v, key=lambda o: o.x) for _, v in sorted(byline.items())]


def slot_row(items, pad, content, slots):
    """Place one row of supporting labels on the panel's slots.

    One item centres across the whole content box; two go on the same two
    slot centres the reading and its visual use. **Three or more is left
    alone** -- the rule names two slots and inventing a third placement for
    a case that does not occur would be making up a rule rather than showing
    one. Nothing in the catalogue draws three on a line.
    """
    if not items:
        return
    if len(items) == 1:
        o = items[0]
        o.x = pad + (content - o.textW) // 2
        return
    if len(items) != 2:
        return
    for o, frac in zip(items, slots):
        o.x = pad + int(round(content * frac)) - o.textW // 2


def row_margin(flowed, pad, content):
    """The tightest clearance between two items sharing a supporting row.

    `None` where no row holds two, so the question does not arise. Measured
    at the strings the component is drawn with: unlike the reading, the
    geometry dump carries no widest form for a supporting label, and the
    page says so rather than implying a guarantee it has not checked.
    """
    supporting = [o for o in flowed if o.role == "supporting" and not o.hidden]
    margins = [b.x - (a.x + a.textW)
               for items in group_rows(supporting) if len(items) == 2
               for a, b in [items]]
    return min(margins) if margins else None


def arrange(objects, panel_w, panel_h, pad, content, widest_at=None,
            compact=0, bottom=0, font_rule="line", centre_rule="box",
            content_top=None, body=None):
    """The settled arrangement: tightened slots, strict halves as fallback.

    Tightening moves the two slot centres to 30% and 70%, which is closer
    than strict halves' 25% and 75% and therefore no longer guarantees the
    two elements cannot meet. Where they would, the panel falls back to
    strict halves, which cannot collide by construction.

    **The fallback is decided from the widest string the component can ever
    print, not from the value on screen, and that is the whole point of
    writing this down.** Deciding it from the current reading would make the
    arrangement a function of the data: a voltage crossing from `9.9` to
    `10.0` would flip the panel between two layouts and every element in it
    would jump. That is the moves-when-content-changes objection that ruled
    out the centred variant, in a worse form -- a drift becomes a switch.

    Asking the widest form instead fixes the arrangement once, at build. A
    panel with room to spare today keeps the layout it will need at its
    widest, and nothing it can ever display will rearrange it. So the
    fallback is a property of the component and its span, not of the moment,
    and `navigation` at `2x2` is a strict-halves panel permanently: it is
    not that it sometimes overlaps, it is that its content does not fit the
    tighter arrangement.

    Returns the arrangement plus the slots it settled on, so the page can
    mark which panels took the fallback.

    **The fallback is per panel, not per row.** A supporting row whose two
    items would meet could fall back on its own, leaving a panel with a
    tightened body over a strict footer -- and the columns would then not
    line up down the panel, which is the one thing slot-derived positions
    are for. So any overlap anywhere puts the whole panel on strict halves.
    It costs more panels their tightening, and the page shows what the other
    reading would have done.
    """
    out, steps, fits, bands = halves(
        objects, panel_w, panel_h, pad, content, widest_at, compact, bottom,
        vertical=True, slots=SLOT_TIGHT,
        font_rule=font_rule, centre_rule=centre_rule,
        content_top=content_top, body=body)
    margin = slot_margin(out, pad, content, widest_at, bands)
    rows_margin = row_margin(out, pad, content)
    worst = min([m for m in (margin, rows_margin) if m is not None],
                default=None)
    if worst is not None and worst < 0:
        out, steps, fits, bands = halves(
            objects, panel_w, panel_h, pad, content, widest_at, compact,
            bottom, vertical=True, slots=SLOT_STRICT,
            font_rule=font_rule, centre_rule=centre_rule,
            content_top=content_top, body=body)
        return out, steps, fits, bands, SLOT_STRICT, margin, rows_margin
    return out, steps, fits, bands, SLOT_TIGHT, margin, rows_margin


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


def svg_of(objects, w, h, ghost=None, bands=None, pad=0, content=0, ink=None):
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
    if ink:
        top, height = ink
        parts.append(
            f'<rect class="ink" x="1" y="{top}" width="{w - 2}" '
            f'height="{height}" />'
        )
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


#: Every column this page has offered has now been decided, and each
#: removal is stated in the page rather than left as a silent absence.
#:
#: `flow -- centred` went first, dominated on both counts the page measures.
#: `flow -- left-aligned` and strict `halves` went when the arrangement was
#: settled as tightened halves with strict halves kept only as the fallback.
#: `font by ink` went last: the font is chosen by line height.
#:
#: The ink rendering is kept in the generator rather than deleted, because
#: the only reason it could not reach the 80% the user asked for was the
#: ladder having no step between 40 and 69 px. If the ladder ever gains one,
#: the question reopens and this is what answers it.
FONT_RULES = [
    ("by line height", "line"),
]

cases = rows(G.CASES)
by_zone = {"widget": [], "appmode": []}
slack_rows = []
halves_steps = []
ladder_rows = []
collide_rows = []
fallback_rows = []
collide_log = []
case_index = {}
findings = []

#: The one constructed case on the page. Nothing in the catalogue prints a
#: descender -- every unit is `V`, `A`, `m` or `dBm` and every heading is
#: upper case -- so the cost of choosing a font by ink cannot be shown from
#: real geometry. It is shown from an invented one instead, and labelled as
#: invented wherever it appears, because a rule has to survive a component
#: nobody has written yet.
CONSTRUCTED_UNIT = "mph"


def ink_guide(flowed):
    """Where the reading's glyphs actually sit, for the overlay."""
    reading = next((o for o in flowed if o.role == "reading"), None)
    if reading is None:
        return None
    off, height = ink_span(reading)
    return (reading.y + off, height)


def band_fill(flowed, bands):
    """What fraction of the body band the reading's glyphs cover."""
    guide = ink_guide(flowed)
    if guide is None or not bands or bands["body"][1] <= 0:
        return 0
    return 100 * guide[1] // bands["body"][1]


def ink_boxes(objects, content=0):
    """Every visible drawn thing as a rectangle, labels measured by ink.

    **Labels and everything else**, which is the correction that matters. The
    first version of this collected only labels, and a reading lying straight
    across its own bar was therefore invisible to it -- a blind spot the size
    of every non-text object, in the check this page's credibility rested on.
    It was found by implementing the rule and watching the widget's own suite
    reject geometry this one had reported healthy.

    A panel's surface and its accent are excluded by what they are: the
    surface spans the content box and the accent sits inside the padding.
    Both are under the content by construction rather than by accident.
    """
    out = []
    for o in objects:
        if o.hidden:
            continue
        if o.role in ("surface", "accent", "container"):
            continue
        if o.kind == "label":
            if not o.text:
                continue
            off, height = ink_span(o)
            out.append((o, o.x, o.y + off, o.x + o.textW,
                        o.y + off + height, True))
        elif o.kind == "arc":
            radius = o.radius or 0
            out.append((o, o.x, o.y, o.x + radius * 2, o.y + radius * 2,
                        False))
        elif o.kind in ("rectangle", "image"):
            out.append((o, o.x, o.y, o.x + (o.w or 0), o.y + (o.h or 0),
                        False))
    return out


def collisions(objects, panel_h, content=0):
    """Labels that overlap anything, and labels that leave the panel.

    **This check is the reason the page is worth anything, and it is also the
    reason one of its numbers was wrong for a revision.** It was added after a
    reader spotted a unit printed over its own reading, which was invisible to
    every other measure here: the slot margins were comfortable, the fonts
    were right, the bands held, and two labels were on top of each other.

    Then it compared labels only, and a reading sized against a body band that
    ran down to the panel floor lay across its own bar without a word. It now
    compares a label against every drawn thing.

    One of each pair has to be text. Two shapes overlapping is a bar's fill
    inside its track or a level inside a cell, which is how those are built.
    """
    bs = ink_boxes(objects, content)
    hits = []
    for i in range(len(bs)):
        for j in range(i + 1, len(bs)):
            a, b = bs[i], bs[j]
            if not (a[5] or b[5]):
                continue
            ox = min(a[3], b[3]) - max(a[1], b[1])
            oy = min(a[4], b[4]) - max(a[2], b[2])
            if ox > 0 and oy > 0:
                hits.append(f"{describe(a)} over {describe(b)}, "
                            f"{ox}&times;{oy}&nbsp;px")
    for entry in bs:
        o, _x0, y0, _x1, y1, is_label = entry
        if not is_label:
            continue
        if y0 < 0:
            hits.append(f"{describe(entry)} {-y0}&nbsp;px above the panel top")
        if y1 > panel_h:
            hits.append(f"{describe(entry)} {y1 - panel_h}&nbsp;px below the "
                        f"panel floor")
    return hits


def describe(entry):
    """Name one box for a failure message."""
    o = entry[0]
    if entry[5]:
        return f"{o.role} <code>{html.escape(o.text)}</code>"
    return f"{o.role or o.kind} ({o.kind})"


def collide_audit():
    """Every label overlap and every label off the panel, in every column."""
    lines = ['<table><thead><tr><th>zone</th><th>component</th><th>span</th>'
             '<th>column</th><th>what collides</th></tr></thead><tbody>']
    clean = True
    for zone, name, span, col, hits in collide_log:
        if not hits:
            continue
        clean = False
        lines.append(
            f'<tr class="has-slack"><td>{zone}</td>'
            f'<td><code>{html.escape(name)}</code></td>'
            f'<td>{html.escape(span)}</td><td>{col}</td>'
            f'<td>{"; ".join(hits)}</td></tr>'
        )
    if clean:
        lines.append('<tr><td colspan="5">nothing overlaps and nothing '
                     'leaves a panel, in any column</td></tr>')
    lines.append('</tbody></table>')
    return "".join(lines)


def next_up(font):
    """The next larger font on the reading ladder, or None at the top."""
    i = LADDER.index(font) if font in LADDER else 0
    return LADDER[i - 1] if i > 0 else None


def stuck_reason(band_h, font):
    """Why choosing by ink did not move this band's font.

    Computed rather than written down. The obvious caption here is "the
    ladder has nothing between 40 and 69 px", which is true of one band and
    not of the others, and a hand-typed reason that is right once is exactly
    the drift this file has already been caught by.
    """
    up = next_up(font)
    if up is None:
        return "already the largest reading font there is"
    line_h, ink_h = FONTS[up]
    return (f"the next step up, {up}, is {ink_h}&nbsp;px of ink in a "
            f"{band_h}&nbsp;px band &mdash; the ladder has nothing between "
            f"{FONTS[font][0]} and {line_h}&nbsp;px")


for case in cases:
    objects = [Obj(o) for o in rows(case.objects)]
    w, h = int(case.w), int(case.h)
    classify(objects, w, h)
    hole = hole_of(objects, w)

    pad, content = int(case.pad), int(case.content)
    bounds = visual_bounds(objects)
    spans = bounds is not None and (bounds[2] - bounds[0]) >= content - 2

    # Widths of the widest reading the component can print, at the font it
    # is currently drawn in, so the slot question is asked of the string the
    # fitter actually sized for.
    widest_at = {k: (int(case.widestAt[k][1]), int(case.widestAt[k][2]))
                 for k in case.widestAt.keys()} if case.widest else None

    cells = [
        f'<figure><figcaption>today</figcaption>'
        f'<div class="frame">{svg_of(objects, w, h, hole)}</div>'
        f'<p class="cap">as shipped</p></figure>'
    ]
    collide_log.append((case.zone, case.component, case.span, "today",
                        collisions(objects, h)))

    variants = {}
    for label, rule in FONT_RULES:
        flowed, steps, fits, bands, used, margin, rmargin = arrange(
            objects, w, h, pad, content, widest_at,
            int(case.compact), int(case.bottom), font_rule=rule,
            centre_rule="box", content_top=int(case.top),
            body=(int(case.bodyY), int(case.bodyH)))
        variants[rule] = (flowed, steps, fits, bands, used, margin,
                          rmargin)

    before = next((o for o in objects if o.role == "reading"), None)

    for label, rule in FONT_RULES:
        flowed, steps, fits, bands, used, margin, rmargin = variants[rule]
        fill = band_fill(flowed, bands)
        hits = collisions(flowed, h)
        collide_log.append((case.zone, case.component, case.span, label, hits))
        notes = []
        if used == SLOT_STRICT and margin is not None:
            notes.append('<span class="fb">strict-halves fallback</span>')
        if not fits:
            notes.append('<span class="cost">will not fit</span>')
        elif steps:
            notes.append(f'<span class="cost">&minus;{steps} size'
                         f'{"s" if steps > 1 else ""}</span>')
        read = next((o for o in flowed if o.role == "reading"), None)
        cells.append(
            f'<figure><figcaption>banded, font {label} '
            f'{"".join(notes)}</figcaption>'
            f'<div class="frame">'
            f'{svg_of(flowed, w, h, bands=bands, pad=pad, content=content, ink=ink_guide(flowed))}'
            f'</div>'
            f'<p class="cap">{read.font if read else "&mdash;"}, ink fills '
            f'<strong>{fill}%</strong> of the body band</p>'
            f'</figure>'
        )

    flowed, steps, fits, bands, used, margin, rmargin = variants["line"]
    after = next((o for o in flowed if o.role == "reading"), None)
    if before is not None and after is not None:
        ladder_rows.append((
            case.zone, case.component, case.span,
            before.font, after.font,
            LADDER.index(after.font) - LADDER.index(before.font)
            if before.font in LADDER and after.font in LADDER else 0,
            bands["body"][1] if bands else 0,
        ))
    if margin is not None or rmargin is not None:
        # The tightened margins come back from `arrange` whether or not the
        # fallback was taken, so the tables can show what the panel would
        # have done alongside what it does.
        s_out, _, _, s_bands = halves(
            objects, w, h, pad, content, widest_at, int(case.compact),
            int(case.bottom), vertical=True, slots=SLOT_STRICT,
            content_top=int(case.top),
            body=(int(case.bodyY), int(case.bodyH)))
        strict_margin = slot_margin(s_out, pad, content, widest_at, s_bands)
        strict_rmargin = row_margin(s_out, pad, content)
        if margin is not None:
            collide_rows.append((case.zone, case.component, case.span,
                                 margin, strict_margin))
        fallback_rows.append((case.zone, case.component, case.span,
                              used == SLOT_STRICT, margin, strict_margin,
                              rmargin, strict_rmargin))
    halves_steps.append((case.zone, case.component, case.span, steps, fits))
    case_index[(case.zone, case.component, case.span)] = (
        objects, w, h, pad, content, int(case.compact), int(case.bottom),
        widest_at, int(case.top), (int(case.bodyY), int(case.bodyH)))

    kind = "none"
    if bounds is not None:
        kind = "full-width bar" if spans else "compact"
    slack_rows.append((case.zone, case.component, case.span,
                       hole[0][2] if hole else 0, kind))

    by_zone[case.zone].append(
        f'<section><h3>{html.escape(case.component)} '
        f'<span class="span">{html.escape(case.span)}</span> '
        f'<span class="px">{w} &times; {h} px</span></h3>'
        f'<div class="row">{"".join(cells)}</div></section>'
    )

def figure(caption, svg, cap=""):
    return (f'<figure><figcaption>{caption}</figcaption>'
            f'<div class="frame">{svg}</div>'
            f'<p class="cap">{cap}</p></figure>')


def descender_case(key=("widget", "metric-radial", "2x1")):
    """The cost of choosing by ink, rendered on a constructed unit.

    **Nothing in the catalogue descends.** Every unit it prints is `V`, `A`,
    `m` or `dBm`; every heading is upper case; every reading is digits, a
    minus, a point or a colon. So the one thing choosing a font by its ink
    gives up cannot be shown from real geometry at all, and showing only
    real geometry would make the cost look theoretical.

    The panel below is therefore real in every respect except its unit
    string, which is replaced with `mph`. It is labelled as constructed
    wherever it appears. The rule is being decided for components nobody has
    written yet, and `mph` is not an exotic unit to expect one of them to
    print.
    """
    entry = case_index.get(key)
    if entry is None:
        return "", 0
    objects, w, h, pad, content, compact, bottom, widest_at, top, body = entry
    made = [o.copy() for o in objects]
    unit = next((o for o in made if o.role == "unit" and not o.hidden), None)
    if unit is None:
        return "", 0
    # Widened under the same model the rest of the page measures with, so
    # the constructed string is no more exact and no less than a real one.
    per_char = unit.textW / max(1, len(unit.text))
    unit.text = CONSTRUCTED_UNIT
    unit.textW = int(round(per_char * len(CONSTRUCTED_UNIT)))

    cells, overflow = [], {}
    modes = [("by line height, placed on the line box", "line", "box"),
             ("by ink, placed on the line box", "ink", "box"),
             ("by ink, placed on the ink", "ink", "ink")]
    for label, rule, place in modes:
        flowed, _, _, bands, _, _, _ = arrange(
            made, w, h, pad, content, widest_at, compact, bottom,
            font_rule=rule, centre_rule=place)
        u = next((o for o in flowed if o.role == "unit" and not o.hidden),
                 None)
        band_floor = bands["body"][0] + bands["body"][1] if bands else h
        # A descender reaches the bottom of the line box, which is where
        # `base_line` is measured from.
        past = max(0, (u.y + u.lineH) - band_floor) if u is not None else 0
        overflow[(rule, place)] = past
        note = (f'<span class="stuck">the <code>p</code> drops '
                f'{past}&nbsp;px past the band floor</span>'
                if past else 'stays inside the band')
        cells.append(figure(
            f'font {label}',
            svg_of(flowed, w, h, bands=bands, pad=pad, content=content,
                   ink=ink_guide(flowed)),
            f'{u.font if u else "&mdash;"} unit &mdash; {note}'))
    return "".join(cells), overflow


def optical_pair(key=("widget", "navigation", "4x2")):
    """Centring the dial on the reading's line box against on its ink."""
    entry = case_index.get(key)
    if entry is None:
        return "", 0, None
    objects, w, h, pad, content, compact, bottom, widest_at, top, body = entry
    cells, centres = [], []
    for label, rule in (("on the line box &mdash; settled rule", "box"),
                        ("on the ink", "ink")):
        flowed, _, _, bands, _, _, _ = arrange(
            objects, w, h, pad, content, widest_at, compact, bottom,
            font_rule="ink", centre_rule=rule, content_top=top, body=body)
        read = next((o for o in flowed if o.role == "reading"), None)
        vb = visual_bounds(flowed)
        off, ink_h = ink_span(read)
        ink_mid = read.y + off + ink_h / 2
        vis_mid = (vb[1] + vb[3]) / 2 if vb else ink_mid
        centres.append(vis_mid - ink_mid)
        cells.append(figure(
            f'dial centred {label}',
            svg_of(flowed, w, h, bands=bands, pad=pad, content=content,
                   ink=ink_guide(flowed)),
            f'dial sits {abs(vis_mid - ink_mid):.0f}&nbsp;px '
            f'{"below" if vis_mid > ink_mid else "above"} the digits&rsquo; '
            f'middle'))
    return "".join(cells), centres[0], key


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


def label_band_case(key=("widget", "link-status", "1x1")):
    """The small-panel label band: what was chosen, and what it replaced.

    A quarter of a 53 px panel is 11 px; the heading is `SMLSIZE` at 17 and
    the smallest font the dashboard has is `TINSIZE` at 12. So "let the band
    win" was never on the table -- there is no font that fits -- and the
    question was only where the overflow goes.
    """
    entry = case_index.get(key)
    if entry is None:
        return "", 0
    objects, w, h, pad, content, compact, bottom, widest_at, top, body = entry

    flowed, _, _, bands, _, _, _ = arrange(
        objects, w, h, pad, content, widest_at, compact, bottom,
        content_top=top, body=body)

    # What it would have done unclamped, kept only to show what was fixed.
    loose = [o.copy() for o in flowed]
    lh = next((o for o in loose if o.role == "heading"), None)
    above = 0
    if lh is not None and bands:
        lh.y = centre_in_band(bands["label"], lh.lineH)
        above = max(0, -(lh.y + ink_span(lh)[0]))

    cells = [
        figure("rejected &mdash; unclamped, the band centred blindly",
               svg_of(loose, w, h, bands=bands, pad=pad, content=content,
                      ink=ink_guide(loose)),
               f"<strong>{above}&nbsp;px of the heading falls off the top of "
               f"the panel</strong> and is clipped"),
        figure("chosen &mdash; font wins, clamped to the panel",
               svg_of(flowed, w, h, bands=bands, pad=pad, content=content,
                      ink=ink_guide(flowed)),
               "the same font, pushed down so nothing leaves the panel; the "
               "band yields and the overflow all goes inward"),
    ]
    return "".join(cells), above


def fallback_table():
    """Which panels took the strict-halves fallback, and what forced it."""
    lines = ['<table><thead><tr><th>component</th><th>span</th>'
             '<th>body, tightened</th><th>rows, tightened</th>'
             '<th>body, strict</th><th>rows, strict</th>'
             '<th>arrangement</th><th>forced by</th></tr></thead><tbody>']

    def cell(v):
        return f"{v} px" if v is not None else "&mdash;"

    for zone, name, span, fell, tight, strict, rt, rs in fallback_rows:
        if zone != "widget":
            continue
        if fell:
            why = []
            if tight is not None and tight < 0:
                why.append("the body")
            if rt is not None and rt < 0:
                why.append("a supporting row")
            note, cls = "strict halves", ' class="has-slack"'
            forced = " and ".join(why) or "&mdash;"
        else:
            note, cls, forced = "tightened", '', "&mdash;"
        lines.append(
            f'<tr{cls}><td><code>{html.escape(name)}</code></td>'
            f'<td>{html.escape(span)}</td><td>{cell(tight)}</td>'
            f'<td>{cell(rt)}</td><td>{cell(strict)}</td><td>{cell(rs)}</td>'
            f'<td>{note}</td><td>{forced}</td></tr>'
        )
    lines.append('</tbody></table>')
    return "".join(lines)


def per_row_case(key=("widget", "navigation", "2x2")):
    """One panel under the two readings of where the fallback belongs.

    Per panel is what the page renders everywhere; per row is the
    alternative, and the point of showing it on the panel that takes the
    fallback is that you can see the columns stop lining up.
    """
    entry = case_index.get(key)
    if entry is None:
        return ""
    objects, w, h, pad, content, compact, bottom, widest_at, top, body = entry
    whole, _, _, wb, _, _, _ = arrange(
        objects, w, h, pad, content, widest_at, compact, bottom,
        content_top=top, body=body)
    # Per row: the body falls back on its own evidence, each row on its own.
    mixed, _, _, mb = halves(
        objects, w, h, pad, content, widest_at, compact, bottom,
        vertical=True, slots=SLOT_STRICT)
    tight_rows, _, _, _ = halves(
        objects, w, h, pad, content, widest_at, compact, bottom,
        vertical=True, slots=SLOT_TIGHT)
    by_y = {o.y: o.x for o in tight_rows
            if o.role == "supporting" and not o.hidden}
    if row_margin(tight_rows, pad, content) is None or \
            (row_margin(tight_rows, pad, content) or 0) >= 0:
        for o in mixed:
            if o.role == "supporting" and not o.hidden and o.y in by_y:
                o.x = by_y[o.y]
    return (
        figure("fallback per panel &mdash; rendered",
               svg_of(whole, w, h, bands=wb, pad=pad, content=content),
               "body and rows both strict, so the columns line up")
        + figure("fallback per row &mdash; the alternative",
                 svg_of(mixed, w, h, bands=mb, pad=pad, content=content),
                 "body strict, supporting rows still tightened &mdash; the "
                 "columns no longer agree down the panel")
    )


slack_table = slack_table()
ladder_table = ladder_table()
collide_table = collide_table()
ink_table = ink_table()
fallback_table = fallback_table()
collide_audit = collide_audit()
label_band_figs, label_band_above = label_band_case()
per_row_figs = per_row_case()
descender_figs, descender_over = descender_case()
descender_box = descender_over.get(("ink", "box"), 0)
descender_ink = descender_over.get(("ink", "ink"), 0)
optical_figs, optical_gap, optical_case = optical_pair()

# Which panels took the fallback, counted rather than typed.
_fb = [r for r in fallback_rows if r[0] == "widget"]
fb_taken = [f"{r[1]} {r[2]}" for r in _fb if r[3]]
fb_total = len(_fb)
fb_list = ", ".join(f"<code>{html.escape(n)}</code>" for n in fb_taken)

# How many rendered cases the ink rule actually moves, which is the
# difference the page exists to show.
ink_moved_cases = 0
ink_case_total = 0
for _z, _n, _s, _old, _new, _d, _bh in ladder_rows:
    if _z != "widget" or _bh <= 0:
        continue
    ink_case_total += 1
    if ink_font(_bh) != band_font(_bh):
        ink_moved_cases += 1

# Supporting rows, at the strings the components are drawn with.
_rw = [r for r in fallback_rows if r[0] == "widget" and r[6] is not None]
row_total = len(_rw)
row_worst = min((r[6] for r in _rw), default=0)
row_worst_case = min(_rw, key=lambda r: r[6])[1:3] if _rw else ("", "")
row_forced = sum(1 for r in _rw if r[6] < 0)
# A clearance is easier to judge as characters than as pixels, so it is
# converted with the same per-character model the geometry was measured
# under rather than described as "comfortable".
_per_char = FONTS["SMLSIZE"][0] * 0.58
row_worst_chars = int(row_worst / _per_char) if _per_char else 0

# How full each distinct band is, before and after, and whether a descender
# would leave it. Digits have none; units and labels do.
#
# **The bands come from the generator's own enumeration, not from the cases
# on this page.** They used to be the distinct bands among the six components
# rendered here, at four spans, in one zone, all of them placed in the grid's
# top left cell -- which is 24 panels of the 272 the schema permits, and the
# one cell EdgeTX covers with its menu button. That set was missing four of
# the bands this dashboard builds and carried five it does not, and the
# conclusion drawn from it named two sizes that never occur. `BANDS` walks
# every placement of every span in both zones through `theme.ladder`, with
# the supporting row taken and declined, and is checked against every panel
# the real host built here.
_bands = [int(r.band) for r in rows(G.BANDS)]
_band_where = {int(r.band): str(r.where) for r in rows(G.BANDS)}
ink_rows = []
for _b in _bands:
    _line, _ink = band_font(_b), ink_font(_b)
    # How far a descender would reach past the band floor **if the glyphs
    # were centred in the band**. Under line-box centring it reaches
    # nothing, because centring the box already reserves the descent -- so
    # this column measures the cost of adopting ink for placement as well as
    # for the font choice, which is the only way the cost arises.
    _ink_top = (_b - FONTS[_ink][1]) // 2
    _over = max(0, _ink_top + FONTS[_ink][0] - _b)
    ink_rows.append((_b, _line, 100.0 * FONTS[_line][1] / _b,
                     _ink, 100.0 * FONTS[_ink][1] / _b, _over,
                     _band_where.get(_b, "")))
ink_band_count = len(ink_rows)
ink_band_rows = "".join(
    '<tr{cls}><td>{band} px</td><td>{line}</td><td>{occ_l:.1f}%</td>'
    '<td>{ink}</td><td>{occ_i:.1f}%</td><td>{over}</td>'
    '<td class="where">{where}</td></tr>'.format(
        cls=' class="better"' if line != ink else "",
        band=band, line=line, occ_l=occ_l, ink=ink, occ_i=occ_i,
        over=f"+{over} px" if over else "none",
        where=html.escape(where))
    for band, line, occ_l, ink, occ_i, over, where in ink_rows
)
ink_moved_bands = ", ".join(f"{r[0]} px" for r in ink_rows if r[1] != r[3])
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
    moved, _, ok, _bands, _slots, _m, _rm = arrange(
        objs, cw, ch, cpad, ccontent, wa,
        int(case.compact), int(case.bottom), content_top=int(case.top),
        body=(int(case.bodyY), int(case.bodyH)))
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
<title>AeroGrid content flow &mdash; the decided arrangement</title>
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
  .ink {{ fill: {PALETTE['green']}; fill-opacity: .10;
    stroke: {PALETTE['green']}; stroke-opacity: .55; stroke-width: 1; }}
  .cap {{ font-size: 11.5px; color: #7d8794; margin: 5px 0 0;
    max-width: 30em; line-height: 1.45; }}
  .cap strong {{ color: #cdd5dd; }}
  .grew {{ color: {PALETTE['green']}; font-weight: 600; }}
  .stuck {{ color: {PALETTE['amber']}; }}
  .fb {{ color: {PALETTE['cyan']}; font-weight: 600;
    text-transform: none; letter-spacing: 0; margin-left: 6px; }}
  .legend {{ display: flex; gap: 26px; flex-wrap: wrap; font-size: 12.5px;
    color: #9aa4b0; margin: 10px 0 4px; }}
  .key {{ display: inline-block; width: 22px; height: 11px;
    vertical-align: -1px; margin-right: 7px; border-radius: 2px; }}
</style></head><body>
<h1>Content flow &mdash; the decided arrangement</h1>
<p class="intro">Every panel below is drawn at its true pixel size from the
real theme, the real region arithmetic and the real measured text widths.</p>

<div class="real"><strong>What is real:</strong> the <em>today</em> column is
not a drawing. Each panel was built through the actual widget host, and its
objects were walked out of the LVGL mock &mdash; every coordinate, font,
colour and string is what the dashboard produces right now. Text is set to
its measured width so the proportions hold, though the browser's glyphs are
not EdgeTX's.</div>

<div class="warn"><strong>What is speculative:</strong> both
<em>font</em> columns are transformations applied in
<code>tools/flow-render.py</code> to that same geometry. <strong>Nothing in
the widget implements any of this.</strong> The arrangement is agreed and
unbuilt; the font rule is the question on this page.</div>

<h2>What this page is now</h2>
<p class="intro"><strong>Every question this page asked has been
answered.</strong> It is no longer a comparison; it is the record of what
was decided, rendered from real geometry so the decisions can be checked
rather than remembered. Two columns per case: what the dashboard draws
today, and what the agreed rule produces.</p>

<div class="warn"><strong>Four columns have been removed as they were
decided, and each removal is stated rather than left as a silent
absence.</strong>
<ul>
<li><code>flow &mdash; centred</code> went first, dominated on both counts
    this page measures &mdash; {worst_offset}&nbsp;px of heading gap against
    the slotted {halves_offset} &mdash; and it re-centres whenever its
    contents change width.</li>
<li><code>flow &mdash; left-aligned</code> and strict <code>halves</code>
    went when the arrangement was settled as <strong>tightened
    halves</strong>, with strict halves kept only as the fallback.</li>
<li><code>font by ink</code> went last, when the font was settled as
    <strong>chosen by line height</strong>.</li>
</ul>
All four still exist in the generator; none is an open choice, and each is a
one-line change if one should be reopened.</div>

<h2>Settled, and recorded rather than re-offered</h2>
<ul>
  <li><strong>Tightened halves.</strong> Two slots derived from the panel,
      centred at <strong>30% and 70%</strong> of the content width. Positions
      come from the panel, not from the content, so a slot does not move
      when what is in it changes and every reading in a row of equal panels
      lands at the same x.</li>
  <li><strong>Strict halves as the fallback</strong>, at 25% and 75%, for a
      panel whose widest content will not take the tighter slots.</li>
  <li><strong>A panel with only a reading does not split.</strong> The
      reading centres across the whole box; there is no second slot to
      protect.</li>
  <li><strong>Furniture at the edges, content in the middle.</strong> The
      heading is pinned to the panel's top inset and a supporting row hangs
      from its bottom inset &mdash; or from a bar, where one owns the floor.
      The reading's ink sits on the panel's own vertical centre. Not one of
      the three consults what the panel contains. <em>Stated three times
      before: an absent part used to give its quarter to the body; then the
      split was a fixed quarter/half/quarter with the reading centred in the
      middle band; then the reading moved to the panel's centre while the
      row still floated in a quarter, which left the gap above it larger
      than the gap below.</em></li>
  <li><strong>The font comes from the panel's height</strong> &mdash; half of
      it wherever anything shares the panel, all of it where nothing does.
      It is the largest font whose <strong>ink</strong> fits, ink being the
      ascent rather than the line height, which carries a descent and a
      leading no reading in this catalogue draws into. <em>This said line
      height until the ink rule replaced it.</em></li>
  <li><strong>Where no font fits, the font wins and is clamped to the
      panel.</strong> The budget yields; nothing is ever drawn off the
      panel, and nothing is drawn under EdgeTX's menu button.</li>
  <li><strong>A secondary element sits on the optical centre of the
      reading's line box.</strong> Not its baseline, not its top. Decided
      from rendered mocks.</li>
  <li><strong>A bar is exempt.</strong> A bar's length <em>is</em> the
      reading, and a track that stops short of the panel edge measures
      against a scale the eye cannot see.</li>
</ul>

<h2>The fallback, and why it is decided from the widest string</h2>
<p class="intro">Strict halves cannot collide <em>provided each element fits
its half</em>: the two own disjoint regions, so no string can reach the
other. Tightening gives that up &mdash; centres 40% apart instead of 50%
have overlapping territory, and only the actual widths keep them separate.
Where they would meet, the panel falls back to strict halves.</p>

<div class="real"><strong>The fallback is chosen at build, from the widest
string the component can ever print &mdash; not from the value on screen.
This is the part that matters and the part most likely to be reinvented
wrongly.</strong>
<p>Deciding it from the current reading would make the arrangement a
function of the data. A voltage crossing from <code>9.9</code> to
<code>10.0</code> would flip the panel between two layouts and every element
in it would jump &mdash; the moves-when-content-changes objection that ruled
out the centred variant, in a worse form, because a drift becomes a
switch.</p>
<p>Asking the widest form instead fixes the arrangement once. A panel with
room to spare today keeps the layout it will need at its widest, and nothing
it can ever display rearranges it. So the fallback is a property of the
component and its span rather than of the moment:
<strong>{fb_list or "no panel"}</strong> {"is" if len(fb_taken) == 1 else "are"}
{"a" if len(fb_taken) == 1 else ""} strict-halves panel{"" if len(fb_taken) == 1 else "s"}
permanently. It is not that they sometimes overlap; it is that their content
does not fit the tighter arrangement.</p></div>

<p class="intro">Measured against the <strong>widest</strong> string each
component can print, at the font it is drawn in. {len(fb_taken)} of
{fb_total} panels take the fallback, and they are marked in the mocks:</p>

{fallback_table}

<div class="warn"><strong><code>navigation</code> at <code>1x1</code> is
marked as a fallback and the fallback does not rescue it</strong> &mdash;
15&nbsp;px of overlap under strict halves as well as 26 under tightened.
That is not a failure of either: <code>888.88km</code> needs 60&nbsp;px, half
that panel is 48, and the reading is already at <code>SMLSIZE</code>, the
bottom of the reading ladder. Strict halves' guarantee assumes each element
fits its half, and here one does not.
<p>It resolves itself on a radio. The component already drops its dial
rather than let a distance clip &mdash; a distance's unit changes with range,
so it cannot be shortened. With the dial gone the panel has one element, and
a one-element panel does not split. The overlap is an artefact of forcing
the split on a panel that would not take it.</p></div>

<h2>Decided: the font comes from the band's ink</h2>
<div class="real"><strong>Chosen, and it was chosen the other way
first.</strong> The reading's font is the largest whose <em>ink</em> &mdash;
its ascent &mdash; fits its band, and the reading is placed by centring that
ink rather than its line box. Line height was chosen first, on two band
sizes that this dashboard does not build; the record of that is below,
because a guide that lists only the winners invites proposing the losers
again.</div>

<p class="intro">The question came from an observation that fonts should use
at least 80% of their vertical allotment. Not implemented as a literal
filter, because <code>height &ge; 0.8 &times; band</code> together with
<code>height &le; band</code> is a window a five-step ladder often has no
member in. The measurable question underneath it was whether the band is
measured against the right thing.</p>

<p class="intro"><code>theme.fontHeight</code> is LVGL's line height: ascent
plus descent plus leading. What a reading puts on the panel is its
<em>ascent</em> &mdash; and every reading in this catalogue is digits, a
minus, a decimal point or a colon, none of which descend. So a band sized
against line height genuinely does carry slack nothing draws into, and the
observation was correct on its own terms:</p>

<table><thead><tr><th>band</th><th>by line height</th><th>ink fills</th>
<th>by ink</th><th>ink fills</th><th>descender past the band</th>
<th>where it occurs</th></tr></thead>
<tbody>{ink_band_rows}</tbody></table>

<p class="intro">Every band this dashboard can build, walked over both zones,
all sixteen spans, every placement of each, and the supporting row both taken
and declined. There are {ink_band_count} of them. Choosing by line height
fills {line_worst:.1f}&ndash;{line_best:.1f}% of a band with ink; by ink the
worst is {ink_worst:.1f}% and the best {ink_best:.1f}%. The two rules
disagree on {ink_moves} bands: {ink_moved_bands}.</p>

<div class="warn"><strong>The rejection rested on two bands this dashboard
never builds.</strong> It was argued on 36&nbsp;px, where ink buys a size,
and on 51&nbsp;px, where it buys nothing because the ladder steps 40 to 69
with nothing between &mdash; and the second was read as the ladder's
granularity blocking the metric. 36&nbsp;px is not in the table above. 51 is,
and there the two rules do still agree, so half of the old argument survives
as a fact about one band rather than as a verdict on the rule.
<p><strong>What was wrong was the case set, not the arithmetic.</strong> The
bands were taken from the panels rendered on this page: six components, four
spans, one zone, every one of them in the grid's top left cell. The walk
above is the whole schema, and it is checked against every panel the real
host built here.</p></div>

<p class="intro"><strong>Two consequences follow from the choice, and both
were paid rather than avoided.</strong></p>
<ul>
  <li><strong>The descender question is real and is now an
      assertion.</strong> Measured on a constructed <code>mph</code> panel,
      because nothing in the catalogue descends by itself: placed on its
      line box the <code>p</code> reached {descender_box}&nbsp;px past the
      band floor, and placed on its ink it reaches {descender_ink}&nbsp;px.
      Centring a line box reserved the descent whether or not anything used
      it; centring ink does not, so the space below a reading's baseline
      belongs to whatever is drawn beneath. That is safe only while nothing
      descends into it, and the widget's suite constructs the strings that
      can &mdash; every unit this dashboard renders that descends, and the
      model name, which is free text.</li>
  <li><strong>The optical centre moved to the ink too.</strong> Centring the
      dial on a line box while the font came from ink would have split the
      two &mdash; on <code>{optical_case[1]} {optical_case[2]}</code> the
      dial sat {optical_gap:.0f}&nbsp;px off the digits' middle. Adopting
      ink for the font and not for the placement is half a change, which is
      what the last section of this page said before either half was
      taken.</li>
</ul>

<div class="legend">
  <span><span class="key" style="background:{PALETTE['cyan']};opacity:.45">
    </span>the band</span>
  <span><span class="key" style="background:{PALETTE['green']};opacity:.45">
    </span>where the reading's glyphs actually sit</span>
</div>
<p class="intro">Both guides are drawn on every panel below. The gap between
the green box and the cyan one is the slack the 80% question was about, kept
visible because it is a real property of the chosen rule rather than an
argument against it.</p>
change.</p>

<h3 class="plain">And the reading sits high in its own band</h3>
<p class="intro">The same asymmetry shows without any secondary element at
all. Because a line box's slack is all underneath the glyphs, centring the
box in a band puts the digits above the band's middle &mdash; the green box
sits high against the cyan one on every panel below, under both rules, and
more so under the ink rule where the box is larger. <strong>That is a
finding rather than a rendering artefact</strong>, and the honest reading of
it is that adopting ink for the font choice and not for the placement is
half a change.</p>

<h2>Every row uses the panel's slots, not just the body</h2>
<p class="intro">The 30% and 70% centres are a property of the panel, so
every row uses them. <strong>What is implemented, so the reading is
checkable:</strong></p>
<ul>
  <li>A row holding <strong>one</strong> item centres it across the whole
      content box &mdash; exactly what a lone reading does.</li>
  <li>A row holding <strong>two</strong> puts them on the same two slot
      centres the reading and its visual use.</li>
  <li>A row holding <strong>three or more is left alone.</strong> The rule
      names two slots, and inventing a third placement for a case that does
      not occur would be making up a rule rather than showing one. Nothing
      in the catalogue draws three on a line.</li>
</ul>
<p class="intro">That makes the arrangement one rule applied at every level
rather than a body rule plus a footer special case, which is worth more than
the appearance: it is the difference between something extensible and a set
of exceptions to memorise.</p>

<h3 class="plain">Does the two-column protection still hold?</h3>
<p class="intro"><code>cell-battery</code>, <code>link-status</code> and
<code>navigation</code> split their supporting row left and right
specifically so the two halves cannot collide, and that was the original
reason for pinning them to the edges. Moving them to 30% and 70% changes
that protection, so it is measured rather than assumed. The tightest
clearance anywhere is <strong>{row_worst}&nbsp;px</strong>, on
<code>{row_worst_case[0]} {row_worst_case[1]}</code>, across
{row_total} rows; {row_forced} rows force a fallback.</p>

<div class="warn"><strong>That number is measured at the strings the
components are drawn with, and not at their widest &mdash; state it plainly
rather than implying a guarantee.</strong> The geometry dump carries a
widest form for the <em>reading</em>, because the component's own fitter
needs one, and carries nothing equivalent for a supporting label. So the
body clearances in the table above are worst-case and the row clearances are
not.
<p>What can be said is the headroom. {row_worst}&nbsp;px is about
<strong>{row_worst_chars} more characters</strong> at <code>SMLSIZE</code>
under the same width model the rest of the page uses, on the tightest row in
the catalogue. <code>LQ 88%</code> becoming <code>LQ 100%</code> spends one
of them. That is comfortable, but it is headroom rather than a proof, and
making it a proof means the components declaring their widest supporting
strings the way they already declare their widest reading.</p></div>

<h3 class="plain">Per panel or per row &mdash; and which is rendered</h3>
<p class="intro">If a supporting row's two items would meet, that row could
fall back to strict halves on its own. Then a panel could have a tightened
body over a strict footer, and the columns would stop lining up down the
panel &mdash; which is the one thing slot-derived positions are for.
<strong>So the fallback is per panel: any overlap anywhere puts the whole
panel on strict halves.</strong> It is the more consistent of the two and it
costs more panels their tightening. Here is what the other reading does, on
the panel that takes the fallback:</p>
<div class="row">{per_row_figs}</div>

<h2>Decided: the label band yields, and the font is clamped to the panel</h2>
<div class="real"><strong>Chosen: font wins, clamped.</strong> Where a band
cannot hold even the smallest font, the font is kept and its position is
clamped so nothing leaves the panel. The bands stop being exactly
proportional there, and nothing overflows.</div>
<p class="intro">A quarter of a 53&nbsp;px panel is 11&nbsp;px. The heading
is drawn at <code>SMLSIZE</code>, 17&nbsp;px, and the smallest font the
dashboard has is <code>TINSIZE</code> at 12. <strong>So "let the band win"
was never available</strong> &mdash; there is no font that fits &mdash; and
the only question was where the overflow goes. Unclamped, it went upward and
{label_band_above}&nbsp;px of the heading was clipped by the panel's own
edge:</p>
<div class="row">{label_band_figs}</div>

<div class="warn"><strong>The third answer &mdash; fall back to today's
stacking below a size &mdash; was rejected, and the reason is worth keeping.
Two layout rules with a size threshold between them is a worse thing to own
than one rule that bends at the bottom of its range.</strong> Every
component, every span and every future addition would then have to be
reasoned about twice, once on each side of a line whose position is itself
arbitrary. A rule that degrades gracefully at its smallest size stays one
rule.</div>

<h2>Nothing overlaps, and this is how that is known</h2>
<p class="intro">Every visible label in every column is checked against
every other, as ink rectangles, and against the panel's own edges. It is
mechanical, it runs on all {len(collide_log)} rendered panels, and it exists
because a reader found a unit printed over its own reading that no other
measure on this page could see: the slot margins were comfortable, the fonts
were right, the bands held, and two labels were on top of each other.</p>
{collide_audit}

<h2>The arrangement, for reference</h2>
<ul>
  <li>The reading is centred on the left slot, the secondary element on the
      right, and a panel with one element centres it across the whole
      box.</li>
  <li>Supporting rows sit at the bottom, centred as one group.</li>
  <li>Worth noting that the two readings of the tightening instruction agree:
      three fifths across the left half is 0.6 &times; 50% = 30%, and two
      fifths across the right half is 50% + 0.4 &times; 50% = 70%. The
      literal reading and the summary give the same number.</li>
</ul>

{collide_table}

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


<h2>App mode &mdash; what the shipped dashboards are</h2>
<p class="intro">Every screen on both tracked models carries
<code>LayoutId: Layout1x1AM</code>, which
<code>layout1x1AppMode.cpp:53</code> registers as "App mode". So the
<code>sim</code> and <code>sim2</code> screens the user pages through are
these, and this is the arrangement they are actually looking at.</p>

<div class="warn"><strong>Corrected:</strong> this page put Full screen
first and said that was what the user pages through. It was not, and the
ordering is not cosmetic &mdash; a page that leads with the zone nobody
looks at invites every judgement to be made against the wrong figures.</div>

<div class="warn"><strong>Found while building this, not fixed:</strong> a
panel at the grid's top left in App mode reserves a strip for the menu
button, and that pushes its content down far enough to change what it draws.
A <code>tx-battery</code> at <code>2x1</code> is <strong>65 px tall in App
mode against 53 in Full screen, and it is the taller one that sheds its
battery</strong> &mdash; the reading starts at y=45 rather than y=21, leaving
12 px where the glyph needs 26. A taller panel drawing less than a shorter
one is worth a look on its own, separately from this rule.</div>

{"".join(by_zone["appmode"])}

<h2>Full screen &mdash; the supported fallback</h2>
<p class="intro">An ordinary Full screen custom screen keeps EdgeTX's own top
bar, so its zone is 19 px shorter and no panel is obstructed. It remains
supported and nothing ships on it, which is why it is second here.</p>

{"".join(by_zone["widget"])}

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
  <li><strong>A unit printed over its own reading, in the proposed columns
      only.</strong> Reported by a reader of the last revision on
      <code>link-status</code>, where <code>dBm</code> landed 12&nbsp;px
      inside <code>-72</code> at <code>1x1</code> and <code>2x1</code> but
      not at <code>2x2</code>. <strong>It was this page's defect, not the
      dashboard's</strong> &mdash; all {len(collide_log) // 3} shipped panels
      are clean. When the band moved the reading's font, the transformation
      widened the reading and then shifted the unit by the reading's
      displacement rather than re-placing it against the reading's new end,
      so the unit kept an offset computed at the old size. The overlap is
      exactly the growth minus the gap: <code>-72</code> gains 13&nbsp;px
      from <code>SMLSIZE</code> to <code>MIDSIZE</code> and the gap is 1.
      <strong>Width was not the discriminator and neither was the span</strong>
      &mdash; it was whether the band-derived font differed from today's,
      which is why two panels of the same width behaved differently.
      <em>This is the sixth appearance of one defect shape in this project:
      something decides a size and something else draws at a position
      computed for the old one.</em> The fix derives the unit's position
      from the reading's current width every time, and the audit above now
      checks mechanically for it.</li>
  <li><strong>The heading falls {label_band_above}&nbsp;px off the top of
      every 53&nbsp;px panel</strong> under the banded rule. Not a component
      defect &mdash; the small-panel label band has no font that fits it,
      and this is that unresolved question presenting concretely. Three
      answers are rendered above.</li>
  <li><strong><code>navigation</code>'s two supporting rows survive the
      slot rule</strong>, which was worth checking since they are the rows
      that already overflow their band by 11&nbsp;px. It draws a bearing
      beside an orientation on one line and coordinates on a second, so the
      first takes the two slots and the second centres. The band overflow is
      unchanged by this &mdash; it is vertical and the slot rule is
      horizontal.</li>
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
      <strong>{widget_slack}</strong> actually carry any slack to reclaim.</li>
</ul>
</body></html>
"""

out = ROOT / "build" / "flow-mocks.html"
out.write_text(page)
print(f"wrote {out}")
for note in findings:
    print(note)
