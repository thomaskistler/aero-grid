-- SPDX-License-Identifier: GPL-2.0-only

local module = { RUNTIME_API = 1 }

--- Install direct function references on the shared theme API.
---@param theme table
function module.install(theme)
    --- Memo for theme.riderDepth, which reads the firmware's font metrics.
    local riderDepth

    --- Minimum useful header width; narrower labels are hidden rather than clipped.
    local MIN_LABEL_WIDTH = 30

    --- Resolve the padded content geometry every panel panel shares.
    ---
    --- Panels derive their regions from this rather than repeating the same
    --- arithmetic, so a header row sits in the same place on every panel and a
    --- state badge never lands on top of the label it accompanies. Every
    --- measurement comes from a real font line height, because EdgeTX's fonts are
    --- far taller than they look and fixed offsets overflow on the radio.
    ---
    --- A panel may also be handed a corner the dashboard does not own. In App mode
    --- EdgeTX paints its menu button over the top-left of the screen, above
    --- everything the widget draws, and it cannot be hidden because it is the only
    --- route to the radio's menus. Laying the header and the content start out
    --- around that corner here means the one shared helper handles it once,
    --- instead of ten panels each compensating and disagreeing about how.
    ---@param resolved AeroGridTheme
    ---@param rect AeroGridRect
    ---@param fonts table Typography roles for this panel's span.
    ---@param reserved? table Width and height of an obstructed top-left corner.
    ---@param badgeText? string Additional panel-specific state badge.
    ---@return table frame
    function theme.frame(resolved, rect, fonts, reserved, badgeText)
        local spacing = resolved.spacing
        -- Short panels cannot afford the standard vertical rhythm, but the left
        -- padding has a floor their height has no say in: the accent occupies that
        -- edge, and content starting at the accent's own right edge read as crowded
        -- against it on every panel under 80 px tall.
        local tight = rect.h < 80
        local pad = tight and spacing.paddingTight or spacing.padding
        local compact = tight and 2 or spacing.paddingCompact
        local padRight = spacing.paddingRight
        if reserved and reserved.side then
            pad = math.max(pad, reserved.w + 4)
        end

        local content = math.max(1, rect.w - pad - padRight)

        -- The badge takes exactly what its vocabulary needs, and is clamped to the
        -- content rather than to half of it. The old half-content clamp protected
        -- the label by clipping the badge, which is the wrong way round: a
        -- half-drawn state word is worse than an absent one, because CRIT and CRI
        -- are not equally alarming, while a shortened source name is merely less
        -- informative. The label now yields to the badge and is dropped outright
        -- when what is left would only clip.
        local badgeWidth = theme.badgeWidth(fonts.badge)
        if badgeText then
            badgeWidth = math.max(badgeWidth, theme.measureText(fonts.badge, badgeText))
        end
        if badgeWidth > content then
            badgeWidth = content
        end
        local badgeX = math.max(pad, rect.w - padRight - badgeWidth)
        local labelHeight = theme.fontHeight(fonts.label)
        local labelX = pad
        -- **The heading is pinned to the top of its band, not centred in it.** A
        -- heading is furniture: it says what the panel is, and it should land in
        -- the same place whatever size the panel happens to be. Centring it in a
        -- band that is a quarter of the panel's extent made it drift down as
        -- panels grew -- 0 px from the top on a one-row panel, 13 on two rows, 21
        -- on three and 30 on four, so a column of panels of different heights had
        -- its headings at four different offsets.
        --
        -- The proportional band was designed for the **reading**, where growing
        -- with the panel is the point. Applying the same rule to the heading is
        -- what produced the drift.
        --
        -- **The band still exists and the body still starts below it.** Only the
        -- heading's own position moves; the quarter is still reserved and `top` is
        -- still measured from where a centred heading would have ended. That is
        -- deliberate rather than incidental: `top` feeds `theme.ladder`, which
        -- decides whether a panel is granted a supporting row and a
        -- visualization, and `theme.bands`, which decides where the reading sits.
        -- Letting the body rise into the space the heading vacated would change
        -- what every panel in the catalogue draws, which is a different decision
        -- from where the heading sits.
        local extent = math.max(1, (rect.h - 4) - compact)
        local centred = theme.clampToPanel(
            theme.centreInBand({ y = compact, h = math.floor(extent / 4) }, labelHeight),
            fonts.label,
            rect.h
        )
        local top = math.max(compact + labelHeight + 2, centred + labelHeight + 2)

        -- Not clamped, and it cannot need to be. `clampToPanel` exists because a
        -- heading centred in a band could be pushed off a short panel -- at one
        -- row the centred value is -1 px and the clamp lifted it to 0. Pinned, the
        -- heading starts at the panel's own top inset, which is 2 px on a short
        -- panel and 6 on any other, against a clamp that binds only above
        -- `rect.h - 13`. The nearest that comes to binding is 2 against 40.
        local labelY = compact

        if reserved then
            -- The header shares the obstructed band, so it moves along to its right
            -- rather than below it, which would cost the panel a whole row.
            if compact < reserved.h then
                labelX = reserved.w + 4
            end
            -- Taller panels lose height; one-row panels already reserved width.
            if not reserved.side and top < reserved.h then
                top = reserved.h
            end
        end

        -- The badge column is reserved whether or not a badge is showing, and the
        -- label's width does not depend on whether one is.
        --
        -- Handing the label the empty column and taking it back when a badge
        -- appears would reflow the label at exactly the moment a panel changes
        -- state, which is the text-jumping the specification forbids and is worse
        -- than a permanently shorter label: a header that moves draws the eye to
        -- itself rather than to the reading that just went critical. Every
        -- panel in the catalogue can reach a badged state, so a column that was
        -- conditional would be conditional on nothing in practice anyway.
        local labelWidth = badgeX - labelX - 4
        local labelHidden = labelWidth < MIN_LABEL_WIDTH
        -- A hidden label has no width rather than a token one, so a panel too narrow
        -- to carry both still has coherent geometry.
        if labelHidden then
            labelWidth = 0
        end

        return {
            width = rect.w,
            height = rect.h,
            pad = pad,
            padRight = padRight,
            compact = compact,
            content = content,
            labelHeight = labelHeight,
            -- The font itself, not only its height. `theme.rowTop` needs the ascent
            -- as well, because a row is pinned by its baseline and the descent below
            -- that baseline is what the floor inset has to absorb. `theme.ladder`
            -- is not handed the typography, so the frame is where the two meet.
            labelFont = fonts.label,
            labelY = labelY,
            badgeWidth = badgeWidth,
            badgeX = badgeX,
            labelX = labelX,
            labelWidth = labelWidth,
            -- Dropped rather than clipped, which is the judgement the obstructed
            -- corner already made and which applies to a narrow panel for the same
            -- reason: the reading and its state are what a pilot needs, and the source
            -- name is the part that can be given up.
            labelHidden = labelHidden,
            top = top,
            bottom = 4,
            reserved = reserved,
        }
    end

    --- Where the two content slots are centred, as fractions of the content width.
    ---
    --- Positions come from the **panel**, never from what is in them. That is the
    --- whole of the arrangement: a slot cannot move because its contents changed
    --- width, so a reading gaining a digit does not shift the battery beside it,
    --- and across a row of equal-width panels every reading lands at the same x.
    --- Two earlier proposals were rejected for failing exactly that, and the
    --- design guide records both with the geometry that ruled them out.
    ---
    --- Tightened is the arrangement; strict is the fallback. Strict cannot
    --- collide *provided each element fits its half*, because the two own
    --- disjoint regions; tightening trades that guarantee for the elements
    --- sitting closer together.
    theme.SLOT_TIGHT = { 0.30, 0.70 }
    theme.SLOT_STRICT = { 0.25, 0.75 }

    --- The x coordinates the two slots are centred on.
    ---@param frame table Result of theme.frame.
    ---@param slots? table One of theme.SLOT_TIGHT or theme.SLOT_STRICT.
    ---@return integer left
    ---@return integer right
    function theme.slotCentres(frame, slots)
        slots = slots or theme.SLOT_TIGHT
        return frame.pad + math.floor(frame.content * slots[1] + 0.5),
            frame.pad + math.floor(frame.content * slots[2] + 0.5)
    end

    --- Left edge of a block of `width` centred on `centre`.
    ---@param centre integer
    ---@param width integer
    ---@return integer
    function theme.slotX(centre, width)
        return centre - math.floor(width / 2)
    end

    --- Whether the two slots can hold this pair without the elements meeting.
    ---
    --- **Asked of the widest string the panel can ever print, never of the
    --- value on screen, and decided once at build.** Deciding it from the current
    --- reading would make the arrangement a function of the data: a voltage
    --- crossing `9.9` to `10.0` would flip the whole panel between two layouts and
    --- every element in it would jump. That is the moves-when-content-changes
    --- objection that ruled out centring, in a worse form, because a drift becomes
    --- a switch.
    ---
    --- Asking the widest form instead fixes the arrangement for the life of the
    --- panel, so one with room to spare today keeps the layout it will need at its
    --- widest, and nothing it can ever display rearranges it.
    ---
    --- **It can fail, and it says so.** Strict halves cannot collide only while
    --- each element fits its own half; where the reading is wider than half the
    --- content, no pair of slots separates them and there is nothing honest to
    --- return. A caller that ignores the verdict gets strict halves and an
    --- overlap; a caller deciding whether to keep a visualization at all has to
    --- check it, and now can. The failing answer being indistinguishable from a
    --- good one is the shape that has cost this project a defect three times.
    ---
    --- **Both edges, not only the shared one.** A reading centred on the left
    --- slot has a panel edge on one side and the visualization on the other, and
    --- this used to check only the second. That was safe only because the
    --- reading was fitted into half the panel before it ever arrived here, so it
    --- could not reach the first. Readings now take the size the whole panel
    --- allows -- a decoration does not cost magnitude -- and a `-120.00` at
    --- MIDSIZE in a single cell is 74 pixels wide against a left slot with 26 to
    --- its left. It cleared the dial and hung eleven pixels off the panel.
    ---
    --- So the verdict is what it always claimed to be: whether this pair of
    --- slots can hold both elements. Answering for one boundary and being read
    --- as answering for the arrangement is the same shape as every other defect
    --- in this file's history.
    ---@param frame table Result of theme.frame.
    ---@param readingWidth integer Widest the reading and its unit will ever be.
    ---@param visualWidth integer Width of the element in the right slot.
    ---@return table slots theme.SLOT_TIGHT, or theme.SLOT_STRICT where they meet.
    ---@return boolean fits Whether either arrangement actually separates them.
    function theme.slotsFor(frame, readingWidth, visualWidth)
        local halfReading = math.ceil(readingWidth / 2)
        for _, slots in ipairs({ theme.SLOT_TIGHT, theme.SLOT_STRICT }) do
            local left, right = theme.slotCentres(frame, slots)
            local readingStart = left - halfReading
            local readingEnd = left + halfReading
            local visualStart = right - math.floor(visualWidth / 2)
            if visualStart >= readingEnd and readingStart >= frame.pad then
                return slots, true
            end
        end
        return theme.SLOT_STRICT, false
    end

    --- How much vertical room the reading is sized against.
    ---
    --- **Half the panel where the panel carries anything else, the whole panel
    --- where it does not.** There is no band for the reading any more: the
    --- panel's height is the budget, halved when something else has to share the
    --- panel with it.
    ---
    --- **Four things count as sharing, and the rule was stated with two.** A
    --- heading and a supporting row are the two the user named. A visualization
    --- is the third and was found by measurement rather than by argument: an
    --- 80 x 65 panel is granted a bar and refused a heading and a row, so on the
    --- two-item statement its reading took the whole 65 px, and XXLSIZE ink
    --- centred on the panel ends at 59 against a bar whose track starts at 55.
    --- A bar is furniture in exactly the sense the rule means -- something else
    --- on the panel that the reading must not be sized as though it were alone.
    ---
    --- The fourth is EdgeTX's menu button, which is the same thing seen from the
    --- panel's side. A panel the button reaches into is not a panel with nothing
    --- on it but a reading, and the user's rule for the corner -- that it keeps
    --- the half while the button is drawn and follows every other panel once the
    --- widget goes fullscreen and the button is hidden -- falls out of counting
    --- the button as furniture rather than being a case bolted on beside the
    --- rule.
    ---
    --- **The button also caps the room, because it is the one piece of furniture
    --- the panel does not own.** A heading and a row are drawn by the widget and
    --- can be reasoned with; the button is painted over the widget by the
    --- firmware and cannot. So the reading may never be larger than what the
    --- button leaves below it, and on a 117 x 65 corner that is 20 px rather
    --- than the 32 px half. Without the cap the sweep finds fifteen readings
    --- drawn under the button, including `tx-battery` at a shipped `2 x 2`.
    ---
    --- **The alternative was centring in the region below the button**, which is
    --- the other reading of the user's question, and it was measured rather than
    --- argued away: on a 238 x 134 corner the region below the button is 89 px,
    --- its centre is 89.5, and a DBLSIZE reading centred there runs from 74 to
    --- 105 against a supporting row's quarter that starts at 103. It collides at
    --- the shipped corner panel *and* costs that panel a font size, so the
    --- region is not what the reading is centred in -- the panel is, and the
    --- button clamps.
    ---
    --- **Asked of what the panel reserves, never of what the panel draws.**
    --- A heading is present when the panel is wide enough to keep one, a row or
    --- a visualization when it is tall enough to be granted one. That is the
    --- guarantee the fixed bands were chosen for and it is kept here: two panels
    --- of one size get one answer, whatever is configured into them. It is also
    --- why the bar had to count as furniture rather than be dodged by asking
    --- whether one is drawn -- the question the interface deliberately does not
    --- offer.
    ---
    --- Which means the whole-panel budget is reachable only by a panel too
    --- narrow for a heading, too short for a bar, and clear of the button --
    --- measured, narrower than 95 px and shorter than 48. The grid is fixed at
    --- four by four, so the only way to build one is a small zone:
    --- `testAReadingAloneTakesTheWholePanel` reflows to 380 x 188, whose cell is
    --- 92 by 44 and takes MIDSIZE where a half of it would take SMLSIZE. A rule
    --- whose second half fires on nothing is a rule with one half, so the case
    --- is constructed rather than assumed.
    ---
    --- **And "the whole panel" is not literally `rect.h`.** A reading centred on
    --- the panel and sized to its full height hangs a descending unit off the
    --- bottom edge, so the containment cap below binds on every lone panel --
    --- the budget is the height less twice the rider's depth. That is worth
    --- stating rather than leaving as a surprise, because the phrase promises
    --- more than the geometry can give.
    ---@param frame table Result of theme.frame.
    ---@param rect AeroGridRect
    ---@param rows integer Supporting rows the panel grants.
    ---@param visual boolean Whether the panel grants a visualization.
    ---@return integer
    function theme.readingRoom(frame, rect, rows, visual, centre, floorY)
        local reserved = frame.reserved
        local shared = reserved ~= nil or not frame.labelHidden or (rows or 0) > 0 or visual == true
        local room = shared and math.floor(rect.h / 2) or rect.h
        if reserved and not reserved.side then
            room = math.min(room, math.max(1, rect.h - reserved.h))
        end
        -- **And never deep enough to reach the supporting row.** A reading centred
        -- on the panel is symmetric about that centre, so what it may occupy
        -- before its baseline meets the row is twice the clearance -- less twice
        -- the strip a descending unit claims below that baseline, which is
        -- symmetric too because the ink grows in both directions while the rider
        -- hangs off the bottom.
        --
        -- This binds on exactly the panels where the half is generous enough to
        -- reach: a Full screen two-row span is 108 px, its row's glyphs start at
        -- 83, and XXLSIZE plus a MIDSIZE rider ends at 87.
        if centre and floorY then
            room = math.min(room, math.max(1, 2 * math.floor(floorY - centre) - 2 * theme.riderDepth()))
        end
        return room
    end

    --- How far below a reading's ink anything riding on its baseline can reach.
    ---
    --- A unit sits on the reading's baseline, so its own ink ends where the
    --- reading's does -- but a *descending* unit carries glyphs into the strip
    --- between that baseline and the bottom of its line box, and nothing
    --- reserves that strip. `rpm`, `mph`, `deg`, `g`, `km/h`, `m/s` and `ml/m`
    --- are all in `telemetry_service`'s table and all descend.
    ---
    --- **This is what made the safety argument behind `theme.bandFont` true by
    --- luck.** That argument is that the unreserved strip below a reading's
    --- baseline is safe while nothing descends into it, and
    --- `testReadingsDoNotDescendOverAnything` is what holds it -- and it held
    --- because the middle-band budget happened to leave nine pixels of slack on
    --- the panels where a descender could reach a supporting row. Sizing against
    --- half the panel spends that slack, and the check went red on a Full screen
    --- `2 x 2`: `rpm` two pixels into `CUR 10.0A`. So the depth is reserved
    --- rather than left to the budget.
    ---
    --- Measured from the real fonts at call time rather than written down: the
    --- deepest a rider can reach is the largest `height - ascent` across the
    --- unit fonts the reading ladder can produce.
    ---@return integer
    function theme.riderDepth()
        if riderDepth then
            return riderDepth
        end
        local deepest = 0
        for _, font in ipairs(theme.READING_FONTS) do
            local rider = theme.unitFont(font)
            local below = theme.fontHeight(rider) - theme.fontAscent(rider)
            if below > deepest then
                deepest = below
            end
        end
        riderDepth = deepest
        return deepest
    end

    --- Where a supporting row's box starts, to hang one inset above its floor.
    ---
    --- **Furniture belongs at the edges and content floats in the middle.** The
    --- heading is pinned to the panel's top inset; this is the mirror, and the
    --- mirror is the whole of the rule. Between the two the reading sits on the
    --- panel's own centre, so all three positions are absolute and not one of
    --- them consults what the panel contains.
    ---
    --- **Corrected: a row used to be centred in the bottom quarter.** That was
    --- symmetric arithmetic with an asymmetric result -- the heading was already
    --- pinned, so the slack between the heading and the reading was the top
    --- inset while the slack between the reading and the row was half a quarter
    --- less a row. On a `3 x 2` `flight-timer` that is 21 px above the number
    --- against 13 below, which the user read from a radio as the reading not
    --- being centred when it was, to the pixel. Pinning the row makes it 21 and
    --- 21 without deriving any position from what the panel holds.
    ---
    --- **The floor is the bar's top where a panel reserves a bar**, and the
    --- panel's bottom edge where it does not. A bar's length *is* the reading,
    --- so it spans the panel and keeps the floor; a row above it hangs from the
    --- bar exactly as a row on a bare panel hangs from the edge. Asked of what
    --- the panel *reserves* rather than of what it currently draws, so a bar
    --- arriving or leaving at runtime does not move the row -- which is the
    --- text-jumping the specification forbids.
    ---
    --- **The inset is never less than the font's descent.** A row's baseline
    --- sits one inset above the floor and a descender is drawn below that
    --- baseline: `LQ 88%` reaches 2 px past it, the only wording in the
    --- catalogue that does. Six pixels of inset absorbs it, but a panel under
    --- 80 px tall insets by two, and `1 x 2` at 79 px is the one panel that is
    --- both tight and granted a row. Without the floor the `%` would touch the
    --- bar it hangs from.
    ---@param frame table Result of theme.frame.
    ---@param font any The row's font.
    ---@param floorY integer What the row hangs from.
    ---@param count? integer Rows in the group, default 1.
    ---@return integer
    function theme.rowTop(frame, font, floorY, count)
        local height = theme.fontHeight(font)
        local inset = math.max(frame.compact, height - theme.fontAscent(font))
        local group = ((count or 1) - 1) * (height + 2)
        return math.max(1, floorY - inset - theme.fontAscent(font) - group)
    end

    --- The proportional vertical bands a panel divides into.
    ---
    --- **A label band of one quarter, a body of one half, a tertiary of one
    --- quarter, and no redistribution.** The three are fixed proportions of the
    --- panel's extent, and an absent part does not give its share to anything:
    --- a panel that draws no supporting row reserves the bottom quarter anyway
    --- and leaves it empty.
    ---
    --- **Corrected: a part used to give its quarter to the body.** That made two
    --- panels of one size lay their readings out differently according to what
    --- was *in* them -- a body of a half where a supporting row was drawn and a
    --- body of three quarters where it was not -- so a reading moved up or down
    --- the panel depending on whether the panel beside it had a row. The user
    --- saw that on a radio and rejected it, after it had been measured as
    --- correct here. It is the same objection that produced the slots: a
    --- position derived from the panel cannot move because of what is in it,
    --- and a position derived from the content can.
    ---
    --- What it costs is stated rather than discovered: a one-row panel that
    --- draws no supporting row now sizes its reading against a half rather than
    --- three quarters. The design guide carries the figures and the acceptance.
    ---
    --- **The bands tile the extent exactly and the rounding goes to the body.**
    --- `floor(extent / 4)` twice leaves one or two pixels over on most panels,
    --- and the body is where a pixel is worth something -- it is measured
    --- against a font ladder, where the label and the tertiary hold one line of
    --- `SMLSIZE` whatever is left.
    ---@param frame table Result of theme.frame.
    ---@param rect AeroGridRect
    ---@param hasLabel boolean
    ---@return table bands `{label, body, tertiary}`, each `{y, h}`.
    function theme.bands(frame, rect, hasLabel)
        local top = frame.compact
        local extent = math.max(1, (rect.h - frame.bottom) - top)
        local quarter = math.floor(extent / 4)
        local labelHeight = hasLabel and quarter or 0

        -- **Always reserved, drawn into or not.** This used to be the question
        -- `hasTertiary` answered, and with it went `floorHeight` -- how much a bar
        -- takes off the panel's floor -- and `rowHeight`, how much two supporting
        -- rows need when a quarter will not hold them. All three sized this band
        -- from what the panel was going to put in it, which is exactly the
        -- dependence on content this rule removes. A quarter is a quarter.
        --
        -- A bar still sits on the panel's floor, which is this band's own floor,
        -- so a bar is drawn *inside* the tertiary quarter rather than beneath it.
        -- It is shorter than the quarter at every span this dashboard builds, so
        -- a panel drawing a bar and a supporting row has room for the row above
        -- it; `testTertiaryQuarterHoldsItsFurniture` is what holds that.
        local tertiaryHeight = quarter

        -- **Where the heading's font overflows its band, the body yields too.** The
        -- label band is a quarter, and on a short panel a quarter is smaller than
        -- any font the dashboard has, so the heading keeps its size and spills
        -- downward. `theme.clampToPanel` keeps it on the panel; this keeps it off
        -- the reading. Without it a 40 px panel drew its heading through its own
        -- number, which is the same "the font wins" decision followed one step
        -- further than the mocks followed it.
        local bodyTop = top + labelHeight
        if hasLabel and frame.top > bodyTop then
            bodyTop = frame.top
        end
        local bodyHeight = math.max(1, (top + extent) - tertiaryHeight - bodyTop)

        return {
            label = { y = top, h = labelHeight },
            body = { y = bodyTop, h = bodyHeight },
            tertiary = { y = bodyTop + bodyHeight, h = tertiaryHeight },
            extent = extent,
        }
    end

    --- The largest reading font whose ink fits a band.
    ---
    --- This inverts the older rule. There the composition came from the box and
    --- the font from the composition; here the band comes from the panel and the
    --- font from the band, which means the font does not consult the content at
    --- all and therefore cannot resize with it. The stability guarantee the
    --- fitter had to be careful to preserve now holds by construction.
    ---
    --- Chosen by **ink** -- the font's ascent -- rather than by its line height,
    --- which carries a descent and a leading that no digit, minus, point or
    --- colon in this catalogue draws into. Re-derived for the reading's room
    --- rather than for the middle band it used to be given: the dashboard builds
    --- twelve distinct rooms and the two rules disagree on four of them. 26 and
    --- 27 px take MIDSIZE rather than SMLSIZE, 32 px DBLSIZE rather than
    --- MIDSIZE, and 66 px XXLSIZE rather than DBLSIZE. A 66 px room drew a
    --- reading filling 47% of it where the next font up fills 82%.
    ---
    --- **This was decided the other way first**, on a 36 px band and a 51 px
    --- band, and the correction is worth knowing rather than quietly made: 36 px
    --- is not a band this dashboard builds at all, and the enumeration that said
    --- it was had been taken over the panels one generator happened to render.
    --- The design guide carries the record.
    ---
    --- **What it costs is a strip nothing reserves**, between a reading's
    --- baseline and the bottom of its line box. Whatever is drawn beneath a
    --- reading may sit there, which is safe only while nothing descends into it
    --- -- so `testReadingsDoNotDescendOverAnything` constructs the strings that
    --- can: the units `telemetry_service` renders with a descender, and
    --- `model-identity`'s model name, which is free text.
    ---@param height integer Band height in pixels.
    ---@return any font
    function theme.bandFont(height)
        local ordered = theme.READING_FONTS
        for index = 1, #ordered do
            if theme.fontAscent(ordered[index]) <= height then
                return ordered[index]
            end
        end
        return ordered[#ordered]
    end

    --- Where a block of `height` starts, to sit centred in a band.
    ---
    --- **The font wins.** Where the block is taller than its band it stays centred
    --- and overflows symmetrically rather than being shrunk to fit: a reading may
    --- drop redundancy and never magnitude, and shrinking a number to satisfy a
    --- decorative band is paying magnitude for layout.
    ---@param band table `{y, h}`.
    ---@param height integer
    ---@return integer
    function theme.centreInBand(band, height)
        return band.y + math.floor((band.h - height) / 2)
    end

    --- Where a block of `height` starts, to sit centred on the panel.
    ---
    --- **The reading's centre is the panel's centre, always**, whatever else the
    --- panel carries and however large that is. The counterpart to the
    --- panel-derived budget, and the two are not separable: sizing a reading
    --- against the panel and then placing it in a band is how a `metric` bar
    --- first found itself underneath its own reading.
    ---
    --- **Corrected: this used to centre the block in the body band.** The bands
    --- were symmetric and the reading was centred in the middle one, so the
    --- arithmetic said centred -- but the heading is pinned to the top of its
    --- band while a supporting row is centred in its own, so the slack collected
    --- above the reading and not below it. On a `3 x 2` `flight-timer` that is
    --- 22 px of clear space above the reading against 12 below, in a panel whose
    --- reading was, by measurement, within a pixel of the panel's centre the
    --- whole time. The user read the panel as uncentred from a radio, and what
    --- they were reading was the gap, not the number.
    ---@param ladder table Result of theme.ladder.
    ---@param height integer
    ---@return integer
    function theme.bodyTop(ladder, height)
        -- Never above the first row the panel owns -- the panel's own top edge,
        -- or the bottom of EdgeTX's menu button on the one panel it covers. Where
        -- the block is taller than what is left, centring would push its first
        -- pixels under the button or off the edge, where they are simply painted
        -- over; the overflow goes downward only, which is the decision
        -- `clampToPanel` makes at the same edge for the same reason. The room the
        -- font was chosen from carries the same cap, so the downward overflow
        -- cannot reach the panel's floor.
        return math.max(ladder.top, math.floor(ladder.centre - height / 2))
    end

    --- Keep a label's glyphs on the panel, whatever its band says.
    ---
    --- **The font wins, and then it is clamped.** On a 53 px panel the label band
    --- is 11 px and the heading is SMLSIZE at 17, while the smallest font the
    --- dashboard has is TINSIZE at 12 -- so "let the band win" is not an available
    --- answer there, in any panel. Centring the heading in a band smaller than
    --- itself puts a pixel of it above the panel's top edge, where it is simply
    --- clipped. The band yields; the panel does not.
    ---
    --- The alternative, falling back to the older stacking below a size threshold,
    --- was rejected deliberately: two layout rules with a threshold between them
    --- is a worse thing to own than one rule that bends at the bottom of its
    --- range, because every panel and every future addition would then have to
    --- be reasoned about twice, on either side of a line whose position is itself
    --- arbitrary.
    ---
    --- Only the ascent is protected. A line box's descent and leading carry no
    --- glyphs for the strings this dashboard draws, so clamping the box rather
    --- than the ink would push every heading down for slack nothing marks.
    ---@param y integer
    ---@param font any
    ---@param panelHeight integer
    ---@return integer
    function theme.clampToPanel(y, font, panelHeight)
        local ink = theme.fontAscent(font)
        local top = math.max(0, y)
        return math.min(top, math.max(0, panelHeight - ink))
    end

    --- Lay out a standard panel into a table the panel owns.
    ---
    --- **Most panels are one arrangement with different words in it**: a
    --- heading, a reading, an optional visualization beside it, an optional
    --- supporting row beneath. Every decision that arrangement needs already
    --- lives here -- the frame, the ladder, the bands, the band font, the slots,
    --- the fitter -- and the *assembly* of those decisions was copied into each
    --- panel, which is why the same band was called `valueY`, `nameY` and
    --- `clockY` in three files and why one mistake had to be fixed in nine.
    ---
    --- **It fills `out` rather than returning a fresh table.** A reflow runs
    --- `REFLOW_BATCH` panels per callback, and the reflow callback has about
    --- four hundred instructions of headroom against the slowest loader stage;
    --- allocating a region table and its sub-tables per panel per reflow is
    --- the one cost that could make sharing this more expensive than copying it.
    --- The panel keeps one table for the life of the panel and this
    --- overwrites it.
    ---
    --- **`spec.draws` is what the panel will put on the screen, never what its
    --- height would permit.** That distinction is a defect shape this project
    --- has now paid for twice -- once placing a row, once reserving a band -- so
    --- the interface does not offer the other question. A panel that wants a
    --- supporting row says it draws one; the ladder may still refuse it on a
    --- panel too short to hold it, because composition is decided here so that
    --- two panels of one size agree.
    ---
    --- What it deliberately does not do: compasses, battery glyphs, trim cells,
    --- and anything a diagnostics view draws. A builder that can express every
    --- panel expresses nothing, and those are the panels whose arrangement
    --- is genuinely their own.
    ---@param resolved AeroGridTheme
    ---@param rect AeroGridRect
    ---@param fonts table Typography roles for this span.
    ---@param spec table
    --- `frame`: this panel's frame, from its own `themeBuilder.frame`.
    --- `forms`: reading wordings, longest first, widest the panel can print.
    --- `draws`: `{rows = boolean, visual = boolean}` -- what will be drawn.
    --- `bar`: true where the visualization is a full-width bar, which spans the
    ---   panel by design and is exempt from the slot rule.
    --- `compact`: `function(rect, half) -> size` for a visual that stands beside
    ---   the reading and therefore takes the right slot. Its absence is what
    ---   says a panel has one element rather than two.
    --- `unit`: a unit that rides beside the reading, or nil for none.
    --- `unitRequired`: the unit carries magnitude and may not be dropped -- a
    ---   distance's `km` against a voltage's `V`.
    --- `rowItems`: 1 or 2, what the supporting row will actually hold. Not what
    ---   the panel could put there: a row of two on a panel drawing one
    ---   puts a lone caption on the left slot, which is a defect this project
    ---   has already shipped once.
    ---@param out table The panel's own region table, overwritten in place.
    ---@return table out
    function theme.panel(resolved, rect, fonts, spec, out)
        -- **`spec.frame`, not `theme.frame`.** The host wraps `frame` per panel
        -- to lay a panel out around the corner EdgeTX paints its menu button over,
        -- and that wrapper is reachable only through the `themeBuilder` a panel
        -- was handed. Calling the module's own function here skips it, and the
        -- panel in the grid's top left draws its heading under the button -- which
        -- is precisely the defect the shared frame exists to prevent, reintroduced
        -- by the helper meant to share it.
        local frame = spec.frame
        local draws = spec.draws
        local ladder = theme.ladder(resolved, rect, frame)

        -- The panel's intent, narrowed by what the panel can hold. A panel
        -- may decline what it was granted and may not claim what it was not.
        local rows = draws.rows == true and ladder.rows > 0
        local visual = draws.visual == true and ladder.visual

        -- **A reading beside a compact visual gets a slot; one on its own gets the
        -- box.** A bar spans the panel by design and is exempt, so only a compact
        -- visual makes this a two-element panel. The visual is bounded by the slot
        -- it lives in as well as by the panel, so a narrow panel shrinks it rather
        -- than letting it reach across the middle into the reading.
        local half = math.floor(frame.content / 2)
        local compact = visual and spec.compact ~= nil
        local size = compact and math.min(spec.compact(rect, half, ladder), half) or 0
        if compact and size <= 0 then
            compact, visual = false, false
        end

        -- The reading's forms, or the reading and a unit it may not drop. A unit
        -- that carries magnitude -- a distance's `km` -- is part of the reading
        -- and the pair is what the ladder is walked against; one that is
        -- redundancy is bought with width after the font is chosen.
        --
        -- **Fitted against the whole content box, never against the slot.** The
        -- reading does not know there is a dial and must not: a reading that
        -- shrinks to make room for a decoration has paid for the decoration with
        -- magnitude, and magnitude is the first thing a pilot reads. Whether the
        -- dial survives is settled below, by the one place that knows how wide the
        -- reading turned out to be.
        local font, formIndex, unitFont, showUnit
        if spec.unit ~= nil then
            font, unitFont, showUnit =
                theme.fitReadingUnit(spec.forms[1], spec.unit, frame.content, ladder.room, spec.unitRequired)
            formIndex = 1
        else
            font, formIndex = theme.fitReading(spec.forms, frame.content, ladder.room)
        end

        -- **One name for the reading's band.** Three panels called this
        -- `valueY`, `nameY` and `clockY`, and one carried two of them for one
        -- thing. The name is `valueY` here and a panel that wants another word
        -- for it has to write the alias itself, which is the point: the divergence
        -- has to be deliberate to happen at all.
        local height = theme.fontHeight(font)
        local width = spec.unit ~= nil
                and theme.readingWidth(font, spec.forms[formIndex], unitFont, showUnit and spec.unit or nil)
            or theme.measureText(font, spec.forms[formIndex])

        -- Asked of the widest string the panel can ever print, so a panel's
        -- arrangement is fixed for its life rather than flipping as its value
        -- changes.
        --
        -- **This is the only place the dial's fate is decided, and it is the place
        -- that knows the reading's width.** It used to be decided twice: once
        -- above, by fitting the reading into half a panel so a dial would have
        -- somewhere to go, and again here, by shedding the dial if that had not
        -- been enough. A reading could therefore lose a size to buy room for a
        -- visualization that was then dropped anyway -- paying for something it
        -- did not get. Splitting one question across two places is the seam that
        -- has produced eight defects in this dashboard, so it is answered once.
        --
        -- The reading has already taken the size the panel allows. If the dial
        -- separates from it, the panel carries both; if it does not, the dial
        -- goes. Nothing is refitted, because nothing was narrowed.
        local slots
        local equalGap
        if compact and spec.equalGaps then
            if showUnit and not spec.unitRequired and spec.minimumGapFraction then
                if frame.content - width - size < rect.w * spec.minimumGapFraction then
                    showUnit = false
                    width = theme.measureText(font, spec.forms[formIndex])
                end
            end
            -- Reserve at least four pixels in each gap without shrinking the reading.
            local available = frame.content - width - 12
            size = available > 0 and spec.compact(rect, available, ladder) or 0
            if size > 0 then
                equalGap = math.floor((frame.content - width - size) / 3)
            else
                compact, size, visual = false, 0, false
            end
        elseif compact then
            local separated
            slots, separated = theme.slotsFor(frame, width, size)
            if not separated then
                compact, size, slots, visual = false, 0, nil, false
            end
        end

        -- Computed once, and only where a compact visual makes them mean
        -- anything. The reading and the visual both want them, and asking twice is
        -- two multiplications and two roundings per panel per reflow -- the kind of
        -- cost that turns a shared helper into a more expensive copy. A bar-backed
        -- panel has no slots at all and must not pay for them; the two-item
        -- supporting row asks separately because it splits whether or not the body
        -- above it does.
        local slotLeft, slotRight
        local centre
        if equalGap then
            slotLeft = frame.pad + equalGap + math.floor(width / 2)
            slotRight = frame.pad + frame.content - equalGap - size + math.floor(size / 2)
            centre = slotLeft
        elseif compact then
            slotLeft, slotRight = theme.slotCentres(frame, slots)
            centre = slotLeft
        else
            centre = frame.pad + math.floor(frame.content / 2)
        end

        out.frame = frame
        out.pad = frame.pad
        out.content = frame.content
        out.ladder = ladder

        -- A lone reading centres across the whole content box. A reading with a
        -- compact visual beside it takes the left slot, which is the caller's
        -- business until a panel in this set has one.
        -- Reading and visual share the body band and are centred on each other, so
        -- the block the band centres is the deeper of the two.
        --
        -- **Measured as ink, not as line box.** A font's line height carries a
        -- descent and a leading that nothing in this catalogue draws into, so
        -- centring the box centres a rectangle that is taller than the glyphs and
        -- leaves the number sitting high in its band. `theme.bodyTop` is given the
        -- ink height for that reason, and the line box is then placed so the ink
        -- lands where the band wants it -- which for a non-descending string means
        -- the box top and the ink top are the same pixel.
        local ink = theme.fontAscent(font)
        local blockHeight = math.max(ink, size)
        local blockTop = theme.bodyTop(ladder, blockHeight)

        out.value = font
        out.formIndex = formIndex
        out.unitFont = unitFont
        out.showUnit = showUnit == true
        out.centreReadingGroup = equalGap ~= nil
        out.valueCentre = centre
        out.valueX = theme.slotX(centre, width)
        out.valueWidth = width
        -- Only where there is one. A panel with no compact visual writes three
        -- nils per reflow otherwise, and `out` is reused rather than rebuilt so
        -- they have to be cleared rather than simply absent -- which is the cost
        -- of the table the panel owns, paid where it is actually owed.
        if compact then
            out.visualSize = size
            out.visualCentreX = slotRight
            out.visualCentreY = blockTop + math.floor(blockHeight / 2)
        elseif out.visualSize ~= nil then
            out.visualSize, out.visualCentreX, out.visualCentreY = nil, nil, nil
        end
        -- The room the reading had, which is not the width it draws in: the drawn
        -- box hugs the measured string so its slot can centre it, and a later
        -- question about whether a unit still fits has to be asked against the
        -- room. **A slotted reading's room is its slot, not the panel** -- asking
        -- the whole box would tell a unit arriving at runtime that it fits beside
        -- a reading sharing the panel with a dial.
        --
        -- It is not simply half the panel, because the reading is no longer fitted
        -- to half the panel. It is centred on the left slot, so what it can occupy
        -- is symmetric about that centre: bounded on one side by the content edge
        -- and on the other by where the dial begins. The slots that decided the
        -- dial's fate are the slots that answer this, so the two cannot drift.
        if equalGap then
            out.valueBudget = width
        elseif compact then
            local visualStart = slotRight - math.floor(size / 2)
            out.valueBudget = 2 * math.max(1, math.min(slotLeft - frame.pad, visualStart - slotLeft))
        else
            out.valueBudget = frame.content
        end
        -- The line box's top, which for a string that does not descend is also
        -- the ink's top. `height` is the box and `ink` is what is drawn; the block
        -- was measured in ink, so the offset inside it is too.
        out.valueY = blockTop + math.floor((blockHeight - ink) / 2)

        -- A bar spans the panel by design and sits on its floor rather than in a
        -- band; a supporting row sits in the tertiary band above it.
        local barY = math.max(1, rect.h - frame.bottom - resolved.spacing.barHeight)
        out.barY = barY
        out.showVisual = visual
        out.showDetail = rows
        -- **Hung from the panel's floor, mirroring the heading pinned to its
        -- top.** A bar owns the floor where one is reserved, so the row hangs from
        -- the bar instead; on a bare panel it hangs from the bottom edge.
        --
        -- Asked of `spec.bar`, which is whether this panel ever draws one, rather
        -- than of whether one is on screen now -- a panel that can draw a bar and
        -- currently does not still keeps its floor clear for one, so the row does
        -- not move when the bar arrives. The comment here used to say the
        -- opposite of what the line beneath it did, which is worth correcting
        -- rather than quietly fixing: it claimed the question was what the
        -- panel draws, and then gave the reason for asking what it reserves.
        out.detailY = theme.rowTop(frame, fonts.label, spec.bar and barY or rect.h)
        -- **A row of one centres across the content box; a row of two takes the
        -- panel's two slot centres.** Which it is is the panel's to say,
        -- because a span knows only what is permitted -- `metric` may carry a
        -- secondary reading at `2 x 2` and whether it does depends on a source
        -- being configured. Two boxes centred that far apart can each be half the
        -- distance between them before they meet, and that is the budget each
        -- wording is fitted to.
        if spec.rowItems == 2 then
            -- The row's own slots, which are the tightened pair whatever the body
            -- fell back to: a row is two labels and cannot collide the way a reading
            -- and a dial can.
            local left, right = theme.slotCentres(frame)
            local budget = math.max(1, right - left - 4)
            out.detailCentre, out.detailWidth = left, budget
            out.detailX = left - math.floor(budget / 2)
            out.rowRightCentre, out.rowRightWidth = right, budget
            out.rowRightX = right - math.floor(budget / 2)
        else
            out.detailCentre = frame.pad + math.floor(frame.content / 2)
            out.detailWidth = frame.content
            out.detailX = frame.pad
            if out.rowRightCentre ~= nil then
                out.rowRightCentre, out.rowRightWidth, out.rowRightX = nil, nil, nil
            end
        end

        out.showSide = false
        out.supportingPlacement = rows and "footer" or "hidden"
        local supporting = spec.supporting
        if supporting then
            local rowHeight = theme.fontHeight(fonts.label)
            local firstWidth = supporting.width or theme.measureText(fonts.label, supporting[1] or "")
            local secondWidth = supporting.width or theme.measureText(fonts.label, supporting[2] or "")
            local count = supporting[2] ~= nil and 2 or 1
            local footerFits = rows
                and not supporting.sideOnly
                and firstWidth <= out.detailWidth
                and (count == 1 or secondWidth <= out.rowRightWidth)
            out.showDetail = footerFits
            out.supportingPlacement = footerFits and "footer" or "hidden"
            if not footerFits and not compact then
                local sideWidth = math.max(firstWidth, secondWidth)
                local sideSlots, fits = theme.slotsFor(frame, width, sideWidth)
                local top = math.max(frame.top, math.floor(ladder.centre - rowHeight * count / 2))
                local floorY = visual and spec.bar and barY or rect.h - frame.bottom
                if fits and top + rowHeight * count <= floorY then
                    local left, right = theme.slotCentres(frame, sideSlots)
                    out.valueCentre = left
                    out.valueBudget = math.min(left - frame.pad, right - math.ceil(sideWidth / 2) - left) * 2
                    out.valueX = theme.slotX(left, width)
                    out.sideCentre, out.sideWidth = right, sideWidth
                    out.sideY, out.marginY = top, top + rowHeight
                    out.showSide = true
                    out.supportingPlacement = "side"
                    out.detailCentre, out.detailWidth, out.detailY = right, sideWidth, top
                    out.detailX = theme.slotX(right, sideWidth)
                    if count == 2 then
                        out.rowRightCentre, out.rowRightWidth = right, sideWidth
                        out.rowRightX, out.rowRightY = out.detailX, top + rowHeight
                    end
                end
            end
        end
        if not out.showSide then
            out.rowRightY = out.detailY
        end
        out.primaryMinX = nil
        if frame.reserved and frame.reserved.side and not spec.cornerCandidate then
            local candidateSpec = {}
            for key, value in pairs(spec) do
                candidateSpec[key] = value
            end
            candidateSpec.frame = theme.frame(resolved, rect, fonts)
            candidateSpec.cornerCandidate = true
            local candidate = theme.panel(resolved, rect, fonts, candidateSpec, {})
            local reserved = frame.reserved
            local function overlaps(x, y, w, h)
                return x < reserved.w + 4 and y < reserved.h and x + w > 0 and y + h > 0
            end
            -- Only restore the primary independently when it has no slotted visual
            -- or side stack. Those share its geometry and must move as a group.
            if not candidate.visualSize and not candidate.showSide and not out.visualSize and not out.showSide then
                local numberWidth = theme.measureText(candidate.value, spec.forms[candidate.formIndex])
                local x = candidate.valueCentre - math.floor(numberWidth / 2)
                if not overlaps(x, candidate.valueY, candidate.valueWidth, theme.fontHeight(candidate.value)) then
                    out.value = candidate.value
                    out.formIndex = candidate.formIndex
                    out.unitFont = candidate.unitFont
                    out.showUnit = candidate.showUnit
                    out.valueCentre = candidate.valueCentre
                    out.valueX = x
                    out.valueWidth = candidate.valueWidth
                    out.valueY = candidate.valueY
                    out.valueBudget = math.min(candidate.valueBudget, 2 * (candidate.valueCentre - frame.pad))
                    out.primaryMinX = frame.pad
                end
            end
        end
        return out
    end

    --- Font roles for a panel span.
    --- Sizes are EdgeTX globals, read at call time so tests can install mocks.
    ---@param colSpan integer
    ---@param rowSpan integer
    ---@return table fonts
    function theme.typography(colSpan, rowSpan)
        local cells = (colSpan or 1) * (rowSpan or 1)
        local primary = MIDSIZE

        if cells >= 4 then
            primary = XXLSIZE
        elseif cells >= 2 then
            primary = DBLSIZE
        end

        return {
            primary = primary,
            secondary = cells >= 4 and MIDSIZE or SMLSIZE,
            unit = cells >= 4 and MIDSIZE or SMLSIZE,
            label = SMLSIZE,
            badge = SMLSIZE,
        }
    end
end

return module
