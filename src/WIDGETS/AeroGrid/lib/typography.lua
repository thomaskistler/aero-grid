-- SPDX-License-Identifier: GPL-2.0-only

local module = { RUNTIME_API = 1 }

--- Install direct function references on the shared theme API.
---@param theme table
function module.install(theme)
    --- Badge column width per font, since typography varies by span.
    local badgeWidths = {}

    --- Line heights of EdgeTX's 480 x 272 "std" font set, in pixels.
    --- Other display classes ship shorter or taller sets, so these are a
    --- calibrated approximation; callers must still clamp content to the panel.
    ---@param font any One of the EdgeTX size constants.
    ---@return integer
    function theme.fontHeight(font)
        if font == XXLSIZE then
            return 69
        end
        if font == DBLSIZE then
            return 40
        end
        if font == MIDSIZE then
            return 29
        end
        if font == SMLSIZE then
            return 17
        end
        if font == TINSIZE then
            return 12
        end
        return 21
    end

    --- Choose the largest primary font whose line height fits the space available.
    --- The specification asks for the largest value that fits at every span, which
    --- depends on the panel's real height rather than on its cell count alone.
    ---@param available integer Vertical pixels the value may occupy.
    ---@return any font
    function theme.fitPrimary(available)
        local ordered = { XXLSIZE, DBLSIZE, MIDSIZE, SMLSIZE }

        for _, font in ipairs(ordered) do
            if theme.fontHeight(font) <= available then
                return font
            end
        end

        return SMLSIZE
    end

    --- Mean character advance as a fraction of a font's line height.
    --- EdgeTX's fonts are proportional, so width has to be estimated where it is
    --- not measured. The ratio is deliberately generous: overestimating shrinks a
    --- reading that would have fit, while underestimating clips it, and the
    --- specification requires text to abbreviate or reduce before it clips.
    local ADVANCE_RATIO = 0.58

    --- Estimate the rendered width of a string in a given font.
    ---
    --- **Generous on purpose, and therefore wrong for placement.** Every
    --- character is charged the same 0.58 of a line height, so a decimal point
    --- costs what a digit does. Against the real advances of the font EdgeTX
    --- ships, `7.9` comes out **68% too wide** and `88.8` 58% too wide -- at
    --- XXLSIZE that is roughly 48 pixels of empty space. Deciding *whether*
    --- something fits may err that way. Deciding *where* something starts may
    --- not: see `theme.measureText`.
    ---@param font any
    ---@param text any
    ---@return integer
    function theme.textWidth(font, text)
        local length = #tostring(text == nil and "" or text)
        return math.floor(length * theme.fontHeight(font) * ADVANCE_RATIO + 0.5)
    end

    --- Measure the rendered width of a string, asking the radio where it can.
    ---
    --- `lcd.sizeText(text, flags)` is `luaLcdSizeText`, which calls
    --- `getTextWidth` -> `lv_txt_get_width(s, len, getFont(flags), 0,
    --- LV_TEXT_FLAG_EXPAND)`: it sums the real per-glyph advances out of the font
    --- and nothing else. Three things make it usable here where the estimate used
    --- to be the only option:
    ---
    ---  * it takes no draw context. Unlike every other `lcd` drawing function it
    ---    carries no `luaLcdAllowed` or `luaLcdBuffer` guard, so it answers from
    ---    a `create` or an `update` as readily as from a paint;
    ---  * our size constants are the flags it wants. `SMLSIZE` and the rest are
    ---    `FONT(XS)` and friends, which is exactly what `getFont` indexes;
    ---  * the font it consults is decompressed once and cached, so the cost is a
    ---    C loop over the string rather than a decode per call.
    ---
    --- The estimate remains the fallback, because a host without `lcd.sizeText`
    --- -- the unit tests are one -- still has to produce a number.
    --- **Fitting measures too, and the estimate is only the fallback.** It used
    --- to decide whether something fits while `readingWidth` decided where to
    --- put it, and the two disagreed by far more than a rounding. The estimate is
    --- one allowance per character, sized between a digit and a capital: at
    --- MIDSIZE it allows 16.8 px where `8` advances 12 and `M` advances 19.
    ---
    --- So it was wrong in **both** directions, and the safety argument that used
    --- to sit here -- that it never reports less than the measurement, so
    --- anything the fit accepts the placement can draw -- was simply false.
    ---
    ---  * On digits it over-reports, by about half again at the larger fonts:
    ---    `88.8` at XXLSIZE estimates 160 px and advances 102. That costs
    ---    nothing but sizes -- a unit shed that would have fitted, a reading
    ---    stepped down that had room. `tx-battery` took its font from the band
    ---    rather than from this ladder to escape it, which is a panel
    ---    working around a shared helper rather than one with a special
    ---    visualization.
    ---  * On capitals it under-reports, and that clips. `model-identity` sizes
    ---    its panel against a row of `M` because that is the widest name EdgeTX
    ---    will store, and at `1 x 2` the estimate called `MMMMMM` 101 px where
    ---    MIDSIZE draws it in 116 -- eleven pixels past 105 px of content, in
    ---    the panel whose entire reading is the name.
    ---
    --- Measuring removes both, and removes the disagreement as well: the
    --- function that decides the font and the function that places the string
    --- now answer from the same advances. The estimate remains underneath, in
    --- `measureText`, for a host with no `lcd.sizeText` -- which is a host that
    --- can only guess anyway.
    ---@param font any
    ---@param text any
    ---@return integer
    function theme.measureText(font, text)
        local sizeText = type(lcd) == "table" and lcd.sizeText
        if type(sizeText) ~= "function" then
            return theme.textWidth(font, text)
        end

        local width = sizeText(tostring(text == nil and "" or text), font)
        if type(width) ~= "number" then
            return theme.textWidth(font, text)
        end
        return width
    end

    --- Distance from the bottom of a font's line box to its baseline.
    ---
    --- `getFontHeight` is `lv_font_get_line_height`, so `lcd.sizeText` hands Lua a
    --- line height and nothing else: **EdgeTX does not expose ascent or baseline
    --- to a script at all**. The numbers are fixed properties of the generated
    --- fonts, read from `radio/src/fonts/lvgl/std/lv_font_en_*.c`, and the flags
    --- map to those files through `api_general.cpp` and `gui/colorlcd/fonts.cpp`:
    --- TINSIZE is `FONT(XXS)`, SMLSIZE `FONT(XS)`, MIDSIZE `FONT(L)`, DBLSIZE
    --- `FONT(bold XL)` and XXLSIZE `FONT(bold XXL)`. Their line heights are 12,
    --- 17, 29, 40 and 69, which is where `fontHeight` above comes from, and the
    --- table below is the `base_line` beside each.
    ---
    --- With both, a baseline is exact rather than approximate: `lv_draw_sw_letter`
    --- places a glyph at `pos.y + (line_height - base_line) - box_h - ofs_y`, so
    --- the baseline of a label whose top is `y` sits at `y + line_height -
    --- base_line`.
    ---@param font any
    ---@return integer
    function theme.fontBaseLine(font)
        if font == XXLSIZE then
            return 15
        end
        if font == DBLSIZE then
            return 9
        end
        if font == MIDSIZE then
            return 6
        end
        if font == SMLSIZE then
            return 4
        end
        if font == TINSIZE then
            return 3
        end
        return 5
    end

    --- Pixels from the top of a font's line box down to its baseline.
    ---@param font any
    ---@return integer
    function theme.fontAscent(font)
        return theme.fontHeight(font) - theme.fontBaseLine(font)
    end

    -- Digit descriptors decoded from EdgeTX v2.12.0 fonts/lvgl/std/
    -- lv_font_en_{bold_XXL,bold_XL,L,XS,XXS}.c; glyphs start at y +
    -- line_height - base_line - box_h - ofs_y (lv_draw_sw_letter).
    function theme.numberInkCentre(font, text)
        local ascent = theme.fontAscent(font)
        if font == XXLSIZE then
            local top, bottom = ascent, 0
            for index = 1, #text do
                local digit = string.sub(text, index, index)
                if string.match(digit, "%d") then
                    local height = (digit == "1" or digit == "4" or digit == "7") and 46
                        or ((digit == "2" or digit == "5" or digit == "9") and 47 or 48)
                    local offset = (digit == "0" or digit == "3" or digit == "5" or digit == "6" or digit == "8") and -1
                        or 0
                    top = math.min(top, ascent - height - offset)
                    bottom = math.max(bottom, ascent - offset)
                elseif digit == "." then
                    top = math.min(top, ascent - 10)
                    bottom = math.max(bottom, ascent + 1)
                end
            end
            if bottom > 0 then
                return (top + bottom) / 2
            end
        end
        local height = font == DBLSIZE and 22
            or (font == MIDSIZE and 17 or (font == SMLSIZE and 9 or (font == TINSIZE and 7 or ascent)))
        return ascent - height / 2
    end

    --- The font a unit rides at beside a reading of a given size.
    ---
    --- Two steps down the reading ladder wherever there are two, which lands the
    --- unit between two fifths and three fifths of the number's line height at
    --- every pairing this dashboard produces: 29 against 69, 17 against 40, 17
    --- against 29, 12 against 17. A unit larger than that competes with the
    --- number, and a unit smaller stops being legible at arm's length.
    ---@param font any
    ---@return any
    function theme.unitFont(font)
        if font == XXLSIZE then
            return MIDSIZE
        end
        if font == DBLSIZE then
            return SMLSIZE
        end
        if font == MIDSIZE then
            return SMLSIZE
        end
        return TINSIZE
    end

    --- Where the top of a unit's label goes so its baseline meets the reading's.
    ---
    --- Aligning the two **tops** is wrong by the difference in ascent, which for
    --- an XXLSIZE reading beside a MIDSIZE unit is 54 against 23: the unit would
    --- float 31 pixels above where it belongs. Aligning **bottoms** is wrong by
    --- the difference in `base_line`, which is smaller but still 9 pixels for
    --- that pair, so the unit would sit visibly low. Neither approximation is
    --- needed, because both terms are known.
    ---@param readingFont any
    ---@param unitFont any
    ---@param readingY integer Top of the reading's label.
    ---@return integer
    function theme.unitTop(readingFont, unitFont, readingY)
        return readingY + theme.fontAscent(readingFont) - theme.fontAscent(unitFont)
    end

    --- Air between a reading and the unit riding beside it.
    ---
    --- A twelfth of the unit's line height, which is one pixel at SMLSIZE and
    --- TINSIZE and two at MIDSIZE. It was a fifth, and that was chosen while the
    --- reading's width was being estimated 58% high: the gap was never what the
    --- user was looking at, it was an overlong measurement with a gap on the end,
    --- and shrinking the constant alone would have left most of the space.
    ---
    --- It is small rather than zero because a glyph's advance already carries its
    --- own right side bearing, so a number and a unit set flush are not actually
    --- touching -- the mock shows them close, and close is what this is. A
    --- proportional gap on top of a proportional bearing keeps the pair looking
    --- the same at every size.
    ---@param unitFont any
    ---@return integer
    function theme.unitGap(unitFont)
        return math.max(1, math.floor(theme.fontHeight(unitFont) / 12 + 0.5))
    end

    --- Width a reading and its inline unit occupy together.
    ---@param font any
    ---@param digits any
    ---@param unitFont any
    ---@param unit any
    ---@return integer
    --- **Measured, not estimated, and the slot rule is what forced it.** The
    --- estimate is generous by design so that text shrinks rather than clips,
    --- which is the right bias when the alternative is a clipped reading and no
    --- way to know. It is the wrong bias when the answer can simply be correct:
    --- generosity then refuses things that fit.
    ---
    --- `navigation` at `2 x 2` is where that stopped being theoretical. Its
    --- widest distance, `888.88km`, measures 113 px at `DBLSIZE` and its slot is
    --- 113 px, so it fits exactly -- and the estimate calls it 160 and sheds the
    --- dial beside it. A panel lost a compass to a safety margin protecting it
    --- from a problem it did not have.
    ---
    --- This is one function rather than the whole boundary. The remaining
    --- fitters -- `fitText`, `fitReading`, `fitHeading`, `fitLabel` -- still
    --- estimate, because their callers ask about strings they may abbreviate
    --- rather than about a pair that must fit or lose its neighbour. Every
    --- caller of this one runs at build or reflow, never per frame, so the
    --- measurement costs nothing a panel pays repeatedly.
    function theme.readingWidth(font, digits, unitFont, unit)
        local width = theme.measureText(font, digits)
        if unit == nil or unit == "" then
            return width
        end
        return width + theme.unitGap(unitFont) + theme.measureText(unitFont, unit)
    end

    --- Choose the font for a reading that carries its unit beside it.
    ---
    --- **The unit never costs the reading a size.** It rides at whatever font the
    --- number was going to take, or it is dropped. That is the specification's own
    --- order -- a form may drop redundancy, never magnitude -- and the unit is
    --- redundancy, because the panel's heading names what is being measured.
    ---
    --- What changes is how often that happens. A unit used to be a character of
    --- the reading itself, so a `V` beside an XXLSIZE number cost 40 pixels; at
    --- two steps down it costs 23 including its gap. It therefore fits in a great
    --- many places it did not, which is the whole of the improvement. Buying it
    --- with a size of the number would be paying for redundancy with magnitude,
    --- and the first thing a pilot reads is how big the number is.
    ---
    --- The caller passes the widest digits it will ever print, never the current
    --- ones, so neither the font nor the unit's presence changes as the value
    --- does.
    --- **Some units cannot be dropped**, and those callers say so. A distance's
    --- unit changes with its range, so `1.23km` and `1.23m` are different
    --- readings rather than one abbreviated; the unit is magnitude there, not
    --- redundancy. For those the pair is what the ladder is walked against, and
    --- the number steps down until both fit, because the alternative is a
    --- distance with no scale on it.
    ---@param digits string Widest digits the caller will ever print.
    ---@param unit any Unit text, or nil/empty for none.
    ---@param width integer Pixels available.
    ---@param room integer Vertical pixels the composition left.
    ---@param required? boolean The unit carries magnitude and may not be dropped.
    ---@return any font
    ---@return any unitFont
    ---@return boolean showUnit
    ---@return boolean fits Whether what will be drawn actually fits.
    function theme.fitReadingUnit(digits, unit, width, room, required)
        local bare = unit == nil or unit == ""
        if required and not bare then
            local ordered = theme.READING_FONTS
            local start = #ordered
            for index = 1, #ordered do
                if theme.fontAscent(ordered[index]) <= room then
                    start = index
                    break
                end
            end
            for step = start, #ordered do
                local font = ordered[step]
                local rider = theme.unitFont(font)
                if theme.readingWidth(font, digits, rider, unit) <= width then
                    return font, rider, true, true
                end
            end
            local last = ordered[#ordered]
            return last, theme.unitFont(last), true, false
        end

        local font, _, fits = theme.fitReading({ digits }, width, room)
        local rider = theme.unitFont(font)
        local showUnit = fits and not bare and theme.readingWidth(font, digits, rider, unit) <= width
        return font, rider, showUnit, fits
    end

    --- Choose the largest font in which a string fits both a width and a height.
    --- `fitPrimary` only answers the vertical question, which leaves a long value
    --- in a narrow cell overflowing sideways. Callers pass the widest string the
    --- panel can ever display, not the current one, so the chosen size stays
    --- stable as values change.
    ---@param text any Widest string the caller will render.
    ---@param width integer Horizontal pixels available.
    ---@param height integer Vertical pixels available.
    ---@return any font
    function theme.fitText(text, width, height)
        local ordered = { XXLSIZE, DBLSIZE, MIDSIZE, SMLSIZE }

        for _, font in ipairs(ordered) do
            if theme.fontHeight(font) <= height and theme.textWidth(font, text) <= width then
                return font
            end
        end

        return SMLSIZE
    end

    --- Decide what a panel of this size carries, and how large its reading is.
    --- Composition depends on the panel dimensions, not its content, so panels
    --- of the same size share the same bands and reading font. Content-specific
    --- visibility and placement are handled by `theme.panel` and each panel.
    ---@param resolved AeroGridTheme
    ---@param rect AeroGridRect
    ---@param frame table Result of theme.frame.
    ---@return table ladder `{rows, visual, bands, room}`
    function theme.ladder(resolved, rect, frame)
        local spacing = resolved.spacing
        local rowHeight = frame.labelHeight + 2
        local barHeight = spacing.barHeight + 2
        local fixed = frame.top + frame.bottom

        -- Granted in order of what a panel loses least by dropping. A visualization
        -- is a shape and survives being small; a supporting row is text and does
        -- not, so the row is the first thing a short panel gives up.
        local visual = fixed + barHeight + theme.fontHeight(SMLSIZE) <= rect.h
        local used = fixed + (visual and barHeight or 0)
        local rows = used + rowHeight + theme.fontHeight(MIDSIZE) <= rect.h and 1 or 0

        -- The bands the panel's *furniture* lives in: the heading at the top, the
        -- supporting row at the bottom. The reading no longer takes the band
        -- between them -- see `theme.readingRoom` -- but the two outer bands are
        -- unchanged, and a row that would not fit its quarter still does not.
        --
        -- It stays here rather than moving into each panel, because two panels
        -- of one size agreeing is the whole reason this function exists. A band
        -- rule applied by some panels and not others would reintroduce exactly
        -- the disagreement it replaced.
        --
        -- **The bands do not depend on what the panel draws**, which is why
        -- nothing about `draws` reaches them. The tertiary quarter used to be
        -- reserved only when the floor was spoken for -- by a supporting row or by
        -- a bar -- and given to the body otherwise, so a panel drawing no row read
        -- at a size a panel drawing one could not. That is a layout that depends
        -- on content, and the user rejected it on a radio after it had been
        -- measured as correct here. `theme.bands` records what went with it.
        --
        -- `draws` still narrows the *grants* below, because a panel may
        -- decline a row it was offered and the row's own placement follows that.
        -- It cannot widen them: a panel may not claim a row the panel is too
        -- short to hold, which is the whole point of deciding composition here.
        local bands = theme.bands(frame, rect, true)

        -- The first row of the panel the widget owns, and the first row it has
        -- promised to something else. The reading is centred between them.
        local top = frame.reserved and not frame.reserved.side and frame.reserved.h or 0
        local centre = rect.h / 2
        -- Where a supporting row's glyphs begin, which is what the reading has to
        -- clear. **The row is pinned to the panel's floor now**, so this follows
        -- it down and the reading gains whatever the row gave up -- which is the
        -- half of this change that is not about position at all. Measuring the
        -- quarter instead would charge the reading the whole of the air above the
        -- row, and measuring where the row used to be would charge it air that is
        -- no longer there.
        --
        -- **Measured against the highest a row can land, which is the one hanging
        -- from a bar.** A bar-reserving panel's row sits above the bar and so is
        -- nearer the reading than a bare panel's row hanging from the edge -- 85
        -- against 93 on a Full screen `2 x 2`.
        --
        -- **This comment said the opposite, and the check caught it.** It argued
        -- that clearing the lower position clears the higher one, which is the
        -- inequality the wrong way round; `cell-battery` at that span took XXLSIZE
        -- and put its unit four pixels into its own supporting row.
        --
        -- **Conservative rather than asked of the panel, and that is the
        -- point of this function.** Two panels of one size must get one answer
        -- whatever drew them, so the budget may not depend on whether this
        -- particular panel's visualization happens to be a bar. Telling the
        -- ladder would be the redistribution objection again, in a third place.
        local barTop = rect.h - frame.bottom - resolved.spacing.barHeight
        local floorY = rows > 0 and theme.rowTop(frame, frame.labelFont, barTop) or (rect.h - frame.bottom)

        return {
            rows = rows,
            visual = visual,
            bands = bands,
            room = theme.readingRoom(frame, rect, rows, visual, centre, floorY),
            -- The panel's own vertical centre, which is where the reading's ink
            -- goes whatever else the panel carries. Held here so the one place that
            -- decides the font and the one that decides the position read the same
            -- number; they were separate once and a reading was sized against a band
            -- it was not drawn in.
            centre = centre,
            -- The first row of the panel the widget actually owns: zero everywhere,
            -- and the bottom of EdgeTX's menu button on the one panel it reaches
            -- into. Nothing centred may start above it, because what is drawn there
            -- is painted over.
            top = top,
        }
    end

    --- Choose the font and the wording a reading is drawn in.
    ---
    --- The forms are offered longest first and are all derived from the widest
    --- value the panel can ever print, never from the current one, so a
    --- reading does not resize or reword as it changes.
    ---
    --- **A form may drop redundancy, never magnitude.** A unit the panel's own
    --- label already states, a name, a suffix: those are abbreviation. A digit of
    --- precision, or a field of a clock, is not. `4.44V` to `4.44` removes
    --- something the panel says elsewhere; `1:04:12` to `04:12` removes an hour
    --- and reports a different reading, which no font size is worth. Callers
    --- therefore offer only lossless forms, and where the shortest of them still
    --- will not fit, the font steps down instead.
    ---
    --- The ladder a reading is sized from, largest first.
    ---
    --- It no longer has to answer what a reading would give up for something
    --- beside it, because a reading gives up nothing: it takes the size the
    --- panel allows and the decoration fits in what is left or is shed. The
    --- companion `readingStep`, which existed only so `navigation` could say
    --- "one size smaller than that", went with the rule it served.
    theme.READING_FONTS = { XXLSIZE, DBLSIZE, MIDSIZE, SMLSIZE }

    --- **It can fail, and it says so.** When even the shortest form will not fit
    --- at the smallest font, there is no font that fits and nothing honest to
    --- return, so it returns the smallest of each and a third value of `false`.
    --- Measuring the answer again in the caller is how `tx-battery` came to take
    --- width for a battery the reading needed, so the verdict is here rather than
    --- in every caller's own guard.
    ---
    --- **Two kinds of caller, and they are allowed to differ.** One *draws*: it
    --- has offered every form it has, and when none of them fits at the smallest
    --- font there is nothing further it can do, so it draws the smallest and the
    --- verdict is information rather than a decision. `flight-timer`,
    --- `flight-mode` and `model-identity` are all of this kind. The other
    --- *allocates*: it is deciding whether to spend the panel's width on
    --- something else -- a battery, a unit -- and for it the verdict is the
    --- decision, because spending width the reading has already failed to fit in
    --- makes a bad situation worse. `glyphFor` and `fitReadingUnit` are of this
    --- kind. The difference is not two assumptions about one function; it is one
    --- answer used for two purposes.
    ---@param forms string[] Lossless wordings, longest first.
    ---@param width integer Pixels available.
    ---@param room integer Vertical pixels the composition left.
    ---@return any font
    ---@return integer index Form chosen, from 1.
    ---@return boolean fits Whether the chosen form actually fits the width.
    function theme.fitReading(forms, width, room)
        local ordered = theme.READING_FONTS
        local start = #ordered

        -- **The band holds the ink, not the line box.** Same rule as
        -- `theme.bandFont`, and it has to be the same rule: a font chosen one way
        -- and a band measured the other is the disagreement the shared ladder
        -- exists to remove.
        for index = 1, #ordered do
            if theme.fontAscent(ordered[index]) <= room then
                start = index
                break
            end
        end

        -- The target the box allows, then down until something fits.
        for step = start, #ordered do
            for index = 1, #forms do
                if theme.measureText(ordered[step], forms[index]) <= width then
                    return ordered[step], index, true
                end
            end
        end

        return ordered[#ordered], #forms, false
    end

    --- Fit a heading to its column, stepping the font down rather than wrapping.
    ---
    --- A Lua label is `lv_label_create` with a font style and nothing else
    --- (`etx_label_create`, `gui/colorlcd/libui/etx_lv_theme.cpp`), so its long
    --- mode is LVGL's default, which `lv_label_constructor` sets to
    --- `LV_LABEL_LONG_WRAP`. A height of zero is not zero either:
    --- `LvglSimpleWidgetObject::parseParam` turns it into `LV_SIZE_CONTENT`. So a
    --- heading wider than its column **wrapped and grew downward over the
    --- reading**: `TRANSMITTER` in a single cell's 52 pixel column took three
    --- lines and 51 pixels of a 65 pixel panel. Nothing about the text changed,
    --- so no assertion about what a label says could see it.
    ---
    --- Lua cannot call `lv_label_set_long_mode`, so clipping and dots are not
    --- available to choose. The levers are the text, the width and the font, and
    --- of those only the font is free: a heading is a name the layout author
    --- chose, and shortening `TRANSMITTER` to `TRANS` is the same loss of
    --- identity as `ACROTRAINER` to `ACRO`.
    ---
    --- So the font steps down first, which costs nothing. Where even the smallest
    --- font cannot fit the name, it is cut to what fits **and the caller is told
    --- what was dropped**, so the author can choose a shorter heading. Being told
    --- is what makes it an abbreviation rather than a quiet corruption.
    ---@param text any
    ---@param width? integer Column available; nil or zero fits nothing.
    ---@param font any Preferred font, stepped down from.
    ---@return string text Text that fits.
    ---@return any font Font it fits at.
    ---@return string? dropped Full text, when it had to be cut.
    function theme.fitHeading(text, width, font)
        local wanted = string.upper(tostring(text == nil and "" or text))
        if wanted == "" then
            return wanted, font
        end
        if type(width) ~= "number" or width <= 0 then
            return wanted, font
        end

        -- The overwhelmingly common case, and the one every panel pays for at
        -- build: a short heading at the font the panel already chose. Answered
        -- before any ladder is built, because building one to discard it is a cost
        -- every panel pays for the rare heading that needs it.
        if theme.textWidth(font, wanted) <= width then
            return wanted, font
        end

        local ladder = {}
        local height = theme.fontHeight(font)
        for _, candidate in ipairs({ SMLSIZE, TINSIZE }) do
            if theme.fontHeight(candidate) < height then
                ladder[#ladder + 1] = candidate
            end
        end
        if #ladder == 0 then
            ladder[1] = font
        end

        for _, candidate in ipairs(ladder) do
            if theme.textWidth(candidate, wanted) <= width then
                return wanted, candidate
            end
        end

        -- Nothing fits. Cut to the smallest font's capacity rather than wrapping
        -- over the reading, and hand back what was lost so it can be reported.
        local smallest = ladder[#ladder]
        local advance = math.max(1, theme.textWidth(smallest, "M"))
        local room = math.max(1, math.floor(width / advance))
        return string.sub(wanted, 1, room), smallest, wanted
    end

    --- Choose the longest of several wordings that fits a width.
    ---
    --- Supporting rows were the one place nothing was fitted. The dominant reading
    --- goes through `fitText` in every panel; a supporting row went through
    --- nothing at all, so `16.4V PACK` was drawn into 48 pixels of a panel that
    --- needed 99, and `BRG 009 N` into 38 of 89. A row cannot shrink its font the
    --- way a reading can, because it is already the smallest the dashboard uses,
    --- so the only thing left to vary is the words.
    ---
    --- `navigation` already did this for one of its two captions, with a private
    --- ladder of phrasings. This is that, shared, so a panel says what it
    --- means at a length it has room for rather than clipping mid-word.
    ---
    --- The last variant is returned when none fits: it is the shortest the caller
    --- offered, and a caller wanting a guaranteed fit ends its list with something
    --- very short.
    ---@param variants string[] Wordings, longest first.
    ---@param font any
    ---@param width? integer Pixels available; nil returns the longest wording.
    ---@return string
    function theme.fitLabel(variants, font, width)
        if type(width) ~= "number" then
            return variants[1]
        end

        for index = 1, #variants do
            if theme.textWidth(font, variants[index]) <= width then
                return variants[index]
            end
        end

        return variants[#variants]
    end

    --- Every badge the dashboard may print, and the whole of that vocabulary.
    ---
    --- A closed set, and a short one, because the badge column is reserved on
    --- every panel whether or not a badge is showing. Its width is whatever the
    --- longest word needs, so a long word is not paid for by the state that uses
    --- it; it is paid for by every header on the dashboard.
    ---
    --- The set had grown to thirteen strings, nine of which did not fit the 56 px
    --- the column reserved. `NO SOURCE` is the theme's own default for an
    --- unavailable panel, needed 89 px, and was therefore clipped on every panel
    --- at every span. Widening the column to 89 px would have fixed that by
    --- taking the width out of the header label instead, which on a single cell
    --- had about four characters to give.
    ---
    --- So the vocabulary was cut rather than the column widened, to one rule:
    --- **a badge names the state, and the panel's supporting row says why.** A
    --- badge is read at a glance from arm's length and is one word from a closed
    --- set the theme owns. A detail row is a vocabulary the panel owns, is
    --- fitted to whatever width its panel gives it, and is where the difference
    --- between a pack that has not been detected and a source answering wrongly
    --- actually belongs.
    ---
    --- **The row's defence is its vocabulary and not its width**, which matters
    --- because the width changed: a two-item row now takes the panel's two slot
    --- centres and gets 40% of the content where the column split it replaced
    --- reached all of it. `NO CELLS` against `CELLS ERR`, and `DOWN` against
    --- `NO RSS`, still say different things at that width. A panel whose
    --- shortest wordings collapse onto one another has lost the distinction
    --- however wide its panel happens to be.
    ---
    --- **The row says what to do, not merely which failure occurred**, and that
    --- is narrower than it first looks. `cell-battery` once drew `NOT CELS`,
    --- `BAD CELS` and `NO CELS` for three shapes. Two of them -- a source that
    --- is not cells at all, and one reporting nonsense -- are one thing to a
    --- pilot: something is arriving and is wrong, go and fix it. They print one
    --- wording now, and the row is not poorer for it. The five shapes behind
    --- them are still separated where the difference can be used, which is the
    --- diagnostics view.
    ---
    --- Panels therefore no longer override the badge. `NOT CELLS` against
    --- `BAD CELLS` spent nine characters separating two failure modes of one
    --- panel -- and those two have since turned out to be one failure mode
    --- with two causes, which is the stronger version of the same argument.
    --- `NO SENSOR` against `NO SOURCE` were near-identical strings for two
    --- situations with the same fix. Every one of those distinctions was already
    --- being drawn, or has since been found not to be a distinction at all.
    theme.BADGES = {
        stale = "STALE",
        warning = "WARN",
        critical = "CRIT",
        editing = "EDIT",
        -- Nothing usable from the source: unconfigured, unrecognized, or answering
        -- with a shape this panel cannot read. All three want the same fix and
        -- the detail row says which it is.
        unavailable = "N/A",
    }

    --- Widest string the badge vocabulary can produce, in pixels.
    ---
    --- Resolved once and cached. Not computed at load, because the font constants
    --- are EdgeTX globals and a module that read them while being loaded would
    --- depend on the order the host happens to load its modules in; and not per
    --- call, because `theme.frame` runs for every panel of every reflow and
    --- this never changes.
    ---@param font any Badge font, from theme.typography.
    ---@return integer
    function theme.badgeWidth(font)
        local cached = badgeWidths[font]
        if cached then
            return cached
        end

        local widest = 0
        for _, text in pairs(theme.BADGES) do
            local width = theme.textWidth(font, text)
            if width > widest then
                widest = width
            end
        end

        badgeWidths[font] = widest
        return widest
    end
end

return module
