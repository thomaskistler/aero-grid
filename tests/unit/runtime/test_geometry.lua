-- SPDX-License-Identifier: GPL-2.0-only

local root = ... or "."
local fixture = assert(loadfile(root .. "/tests/support/runtime_fixture.lua"))(root)
local edgetx = fixture.edgetx
local firmware = fixture.firmware
local loadModule = fixture.loadModule
local grid = fixture.grid
local layout = fixture.layout
local panelHost = fixture.panelHost
local theme = fixture.theme
local primitives = fixture.primitives
local modelService = fixture.modelService
local assertEqual = fixture.assertEqual
local assertFont = fixture.assertFont
local telemetryHarness = fixture.telemetryHarness

local function testMetricDirection()
    local metric = loadModule("panels/metric.lua")

    -- A single threshold defaults to rising.
    local rising = { critical = 110 }
    assertEqual(metric.resolveState(rising, 120, false), "critical")
    assertEqual(metric.resolveState(rising, 10, false), "normal")

    -- An explicit falling direction reverses it, which a battery needs.
    local falling = { critical = 3.3, direction = "falling" }
    assertEqual(metric.resolveState(falling, 3.0, false), "critical")
    assertEqual(metric.resolveState(falling, 4.1, false), "normal")

    -- Two thresholds still infer direction without configuration.
    local inferred = { warning = 21.0, critical = 19.8 }
    assertEqual(metric.resolveState(inferred, 20.5, false), "warning")
    assertEqual(metric.resolveState(inferred, 19.0, false), "critical")
    assertEqual(metric.resolveState(inferred, 24.0, false), "normal")

    -- An explicit rising direction overrides the inference.
    local forced = { warning = 21.0, critical = 19.8, direction = "rising" }
    assertEqual(metric.resolveState(forced, 24.0, false), "critical")

    -- Missing and non-numeric readings are unavailable, not zero.
    assertEqual(metric.resolveState(inferred, nil, false), "unavailable")
    assertEqual(metric.resolveState(inferred, 0 / 0, false), "unavailable")
    assertEqual(metric.resolveState(inferred, 24.0, true), "stale")

    -- A zero-width range must not divide by zero.
    assertEqual(metric.fraction({ rangeMin = 5, rangeMax = 5 }, 5, primitives), 0)
    assertEqual(metric.fraction({ rangeMin = 0, rangeMax = 10 }, 20, primitives), 1)
    assertEqual(metric.fraction({ rangeMin = 0, rangeMax = 10 }, -5, primitives), 0)
    assertEqual(metric.fraction({ rangeMin = 10, rangeMax = 0 }, 5, primitives), 0.5)
    assertEqual(metric.format(nil, 2), "--")
    assertEqual(metric.format(1.239, 2), "1.24")
end

--- Content must stack inside the panel using real font heights, never
--- overlapping and never running past the bottom edge.
local function testContentFitsPanel()
    local metric = loadModule("panels/metric.lua")
    local heightOf = theme.fontHeight

    -- Panel heights for spans at 480 x 272 with 4 px gutters, plus tight cases.
    local cases = {
        { name = "2x2", w = 238, h = 134, colSpan = 2, rowSpan = 2 },
        { name = "2x1", w = 238, h = 65, colSpan = 2, rowSpan = 1 },
        { name = "1x1", w = 117, h = 65, colSpan = 1, rowSpan = 1 },
        -- Smaller than any span the grid can produce: a single cell is 117 by
        -- 65. Kept as a stress case, and marked so the assertions can ask it the
        -- question it can actually answer.
        { name = "tiny", w = 60, h = 40, colSpan = 1, rowSpan = 1, synthetic = true },
    }

    for _, case in ipairs(cases) do
        local layout = metric.presentationFor(case.colSpan, case.rowSpan)
        layout.visual = "bar"
        local fonts = theme.typography(case.colSpan, case.rowSpan)
        local area = metric.regionsFor(
            theme.build("modern-dark"),
            theme,
            { x = 0, y = 0, w = case.w, h = case.h },
            layout,
            fonts
        )

        -- **The ink, not the line box.** A reading is placed so that its ink is
        -- centred in the band, which leaves the box hanging below it by the
        -- font's descent and leading -- 15 px at XXLSIZE. Nothing is drawn
        -- there: every reading in the catalogue is digits, a minus, a point or a
        -- colon, and none of them descend. Measuring the box here would report
        -- an overlap with a bar that no glyph reaches, which is the same
        -- disagreement the integration collision check already resolves in
        -- favour of ink.
        --
        -- The one reading that *can* descend is `model-identity`'s model name,
        -- which is free text. It is asserted below that no panel drawing a
        -- bar draws descending text, so this measure cannot hide a real overlap.
        local valueBottom = area.valueY + theme.fontAscent(area.value)
        assert(
            valueBottom <= case.h,
            case.name .. ": value overflows the panel, ends at " .. valueBottom .. " in " .. case.h
        )

        -- Assertions use the resolved flags: a short panel sheds optional detail.
        -- The unit rides beside the reading now, so it shares the reading's rows
        -- rather than taking one below it, and the property to hold is that their
        -- baselines meet rather than that one sits under the other.
        if area.showUnit then
            assertEqual(
                area.unitY + heightOf(area.unitFont) - theme.fontBaseLine(area.unitFont),
                area.valueY + heightOf(area.value) - theme.fontBaseLine(area.value),
                case.name .. ": the unit does not sit on the reading's baseline"
            )
            assert(area.unitY + heightOf(area.unitFont) <= case.h, case.name .. ": unit overflows the panel")
            assert(
                heightOf(area.unitFont) < heightOf(area.value),
                case.name .. ": the unit is drawn at or above the reading's own size"
            )
        end

        if area.showVisual then
            local unitBottom = valueBottom
            assert(area.barY >= unitBottom, case.name .. ": bar overlaps content above it")
            assert(area.barY + 4 <= case.h, case.name .. ": bar overflows the panel")
        end

        if area.showDetail then
            assert(area.detailY + heightOf(fonts.label) <= area.barY, case.name .. ": range overlaps the bar")
        end

        -- The label row must clear the value -- **on a panel that draws a label.**
        -- Corrected: this asked the question of every case, including the 60 x 40
        -- stress panel, which is too narrow to keep a heading at all and drops it
        -- (`frame.labelHidden`). So the check was holding the reading clear of an
        -- object nothing draws, and it went red the moment a panel with no
        -- heading was allowed to use its whole height for the reading. That is
        -- the permitted-versus-drawn seam, this time in the check rather than in
        -- the code it watches.
        local drawsLabel = not area.frame.labelHidden
        if drawsLabel then
            assert(area.valueY >= heightOf(fonts.label), case.name .. ": value overlaps the label")
        else
            -- The panel still has to hold the reading it chose, which is the only
            -- thing on it.
            assert(area.valueY >= 0, case.name .. ": value starts above the panel")
        end
    end

    -- A short panel must reduce the primary font rather than overflow.
    local short = metric.regionsFor(
        theme.build("modern-dark"),
        theme,
        { x = 0, y = 0, w = 238, h = 65 },
        { showUnit = true, showVisual = true, showRange = false, visual = "bar" },
        theme.typography(2, 1)
    )
    local tall = metric.regionsFor(
        theme.build("modern-dark"),
        theme,
        { x = 0, y = 0, w = 238, h = 134 },
        { showUnit = true, showVisual = true, showRange = true, visual = "bar" },
        theme.typography(2, 2)
    )
    assert(heightOf(short.value) < heightOf(tall.value), "a short panel did not reduce its primary font")
end

--- Panels sharing an interval must not all fall due on the same frame.
local function testRefreshScheduling()
    assertEqual(panelHost.refreshInterval({ refreshInterval = 20 }), 20)
    assertEqual(panelHost.refreshInterval({}), 0)
    assertEqual(panelHost.refreshInterval({ refreshInterval = -5 }), 0)

    -- An interval of zero or one cannot be staggered.
    assertEqual(panelHost.phaseOffset(0, 7), 0)
    assertEqual(panelHost.phaseOffset(1, 7), 0)

    -- Sixteen panels sharing a 20 tick interval must land on distinct
    -- frames, so the host never pays for all of them at once.
    local used = {}
    for ordinal = 1, 16 do
        local offset = panelHost.phaseOffset(20, ordinal)
        assert(offset >= 0 and offset < 20, "offset outside the interval: " .. offset)
        assert(not used[offset], "two panels share phase " .. offset)
        used[offset] = true
    end

    -- More panels than frames must wrap rather than fail.
    assertEqual(panelHost.phaseOffset(4, 5), 0)
    assertEqual(panelHost.phaseOffset(4, 6), 1)

    -- The contract rejects a nonsensical interval rather than misscheduling.
    local function rejects(interval)
        local ok = panelHost.validateModule(
            { id = "d", apiVersion = 1, create = function() end, refreshInterval = interval },
            "d"
        )
        assertEqual(ok, false, "accepted interval " .. tostring(interval))
    end
    rejects(-1)
    rejects(1.5)
    rejects("fast")
    assert(panelHost.validateModule({ id = "d", apiVersion = 1, create = function() end, refreshInterval = 0 }, "d"))
end

--- Every origin wording must fit the width it is given, and must step down
--- through phrasings that still read as sentences rather than being clipped.
local function testOriginCaptionFits()
    local navigation = loadModule("panels/navigation.lua")
    local fix = { known = true, fix = true, home = true, state = "normal" }
    local noHome = { known = true, fix = true, home = false, state = "normal" }
    local noSource = { known = false }

    -- With no layout context the caller gets the full wording.
    assertEqual(navigation.originText(fix), "")

    -- The caption row on a 2 x 2 panel is about 131px.
    assertEqual(navigation.originText(fix, theme, SMLSIZE, 131), "")
    assertEqual(navigation.originText(noHome, theme, SMLSIZE, 131), "NO HOME POS")
    assertEqual(navigation.originText(noSource, theme, SMLSIZE, 131), "NO GPS SOURCE")

    -- Generous width keeps the full wording.
    assertEqual(navigation.originText(fix, theme, SMLSIZE, 400), "")

    -- Whatever the width, the chosen wording must fit it, or be the shortest
    -- available when nothing does. Nothing may simply be clipped.
    for _, view in ipairs({ fix, noHome, noSource, { known = true, fix = false } }) do
        local variants = navigation.originVariants(view)
        local shortest = variants[#variants]
        for width = 10, 400, 7 do
            local text = navigation.originText(view, theme, SMLSIZE, width)
            local fitted = theme.textWidth(SMLSIZE, text) <= width
            assert(
                fitted or text == shortest,
                "caption '" .. text .. "' neither fits " .. width .. "px nor is shortest"
            )
            -- A wording must never be a truncation of a longer one with a dangling
            -- word; each rung is checked to be one of the declared phrasings.
            local declared = false
            for _, candidate in ipairs(variants) do
                if candidate == text then
                    declared = true
                end
            end
            assert(declared, "caption '" .. text .. "' is not a declared wording")
        end
    end
end

local function testFontHeightsMatchTheFirmware()
    local citation = edgetx.citation("FONT_HEIGHT")
    for font, height in pairs(firmware.FONT_HEIGHT) do
        assertEqual(
            theme.fontHeight(font),
            height,
            edgetx.fontName(font) .. " is not the height the radio draws it at (" .. citation.file .. ")"
        )
    end
end

--- Width is asked of the radio, and the estimate is only a fallback.
---
--- The two differ enough to tell apart, which is the point: `theme.textWidth`
--- charges every character 0.58 of a line height, so a decimal point costs
--- what a digit does, and against the real advances of the font EdgeTX ships
--- `7.9` comes out 68% too wide. That generosity is correct when deciding
--- whether something fits and wrong when deciding where something starts.
---
--- The mock's `lcd.sizeText` is a proportional model rather than the radio's
--- own numbers -- it cannot be more, since every font the dashboard draws
--- with is LZ4-compressed in the tree. What it reproduces faithfully is the
--- shape: a narrow `.`, a wide `m`, and a total that depends on which
--- characters a string holds rather than only how many.
local function testWidthIsMeasuredNotEstimated()
    -- The estimate is length times height times a constant, so two strings of
    -- the same length measure the same however different they look.
    assertEqual(theme.textWidth(MIDSIZE, "8.8"), theme.textWidth(MIDSIZE, "888"))

    -- Measurement does not, and that difference is what a test can see.
    assert(
        theme.measureText(MIDSIZE, "8.8") < theme.measureText(MIDSIZE, "888"),
        "a decimal point measures as wide as a digit, so this is the estimate" .. " wearing a different name"
    )

    -- **The estimate is generous on digits, and only on digits.** It is one
    -- allowance per character, sized between a digit and a capital, so the
    -- direction of its error depends on what the string holds. This used to be
    -- asserted as a general property of "the readings this dashboard prints",
    -- which was a claim about every panel made by looking at one kind of
    -- string.
    local checked = 0
    for _, sample in ipairs({ "7.9", "10.0", "88.8", "-100", "888.88", "1:04:12" }) do
        for _, font in ipairs(theme.READING_FONTS) do
            checked = checked + 1
            assert(
                theme.textWidth(font, sample) >= theme.measureText(font, sample),
                "the estimate under-reports "
                    .. sample
                    .. " at "
                    .. edgetx.fontName(font)
                    .. ", which would clip rather than shrink"
            )
        end
    end
    assert(checked >= 24, "only " .. checked .. " pairs were compared")

    -- And the counterexample, which is not hypothetical: `model-identity`
    -- sizes its panel against a row of `M`, because `LEN_MODEL_NAME` is 15 and
    -- that is the widest name EdgeTX will store. A capital advances wider than
    -- the allowance, so the estimate reports less than the truth for exactly
    -- the string that panel fits against -- and a fit that believes it
    -- draws past the panel edge rather than shrinking. Pinned here so the
    -- boundary above cannot be read as a general guarantee again.
    for _, font in ipairs(theme.READING_FONTS) do
        assert(
            theme.textWidth(font, "MMMMMM") < theme.measureText(font, "MMMMMM"),
            "the estimate no longer under-reports capitals at "
                .. edgetx.fontName(font)
                .. ", so the reason fitting measures has"
                .. " changed and the comment above is now telling a different story"
        )
    end

    -- The gap between them is the user's complaint, stated as a number. At the
    -- largest reading a `7.9` was placed tens of pixels further right than the
    -- radio draws it.
    local slack = theme.textWidth(XXLSIZE, "7.9") - theme.measureText(XXLSIZE, "7.9")
    assert(
        slack > 20,
        "the estimate is only "
            .. slack
            .. " pixels generous at XXLSIZE, so this change buys nothing and the"
            .. " gap the user reported has another cause"
    )

    -- Empty and absent text measure zero rather than raising, because a panel
    -- with no reading yet still places its unit.
    assertEqual(theme.measureText(MIDSIZE, ""), 0)
    assertEqual(theme.measureText(MIDSIZE, nil), 0)

    -- Without `lcd.sizeText` the estimate answers, because a host that cannot
    -- measure still has to produce a number rather than nil.
    local realLcd = lcd
    lcd = { RGB = realLcd.RGB, getColor = realLcd.getColor }
    local fallback = theme.measureText(MIDSIZE, "8.8")
    lcd = realLcd
    assertEqual(
        fallback,
        theme.textWidth(MIDSIZE, "8.8"),
        "a host without lcd.sizeText did not fall back to the estimate"
    )

    -- And a host whose `sizeText` answers something unusable is the same case.
    local broken = {
        RGB = realLcd.RGB,
        getColor = realLcd.getColor,
        sizeText = function()
            return nil
        end,
    }
    lcd = broken
    local refused = theme.measureText(MIDSIZE, "8.8")
    lcd = realLcd
    assertEqual(refused, theme.textWidth(MIDSIZE, "8.8"), "a sizeText that answered nil was believed")
end

--- `slotsFor` answers for the arrangement, not for one of its boundaries.
---
--- The function decides whether a panel keeps its visualization at all, and
--- until now it had no test of its own: it was covered only through whatever
--- the panels happened to draw. That was survivable while a reading was
--- fitted into half a panel before it ever reached here, because then it
--- could not reach the far edge. Readings take the size the whole panel
--- allows now, so both boundaries are live and both have to be answered.
---
--- A reading is centred on the left slot. It has the panel's content edge on
--- one side and the visualization on the other, and a verdict of "these
--- separate" that consults only the second is not a verdict about the
--- arrangement -- it is a verdict about one half of it, read as though it
--- covered both.
local function testSlotsForAnswersForBothEdges()
    local fonts = theme.typography(1, 1)
    local built = theme.build("modern-dark")
    local frame = theme.frame(built, { x = 0, y = 0, w = 117, h = 53 }, fonts)
    local left = theme.slotCentres(frame, theme.SLOT_STRICT)
    local room = left - frame.pad

    -- Comfortable: a narrow reading and a small dial separate, and the panel
    -- holds both.
    local _, roomy = theme.slotsFor(frame, 20, 20)
    assertEqual(roomy, true, "a narrow reading beside a small dial was refused")

    -- **The far edge.** Wide enough that centring it on the left slot pushes
    -- it off the panel, but paired with a dial small enough that the two never
    -- touch each other. Checking only the gap between them calls this a good
    -- arrangement, and it is a reading hanging off the side of the panel.
    local overhang = (room + 8) * 2
    local _, hangs = theme.slotsFor(frame, overhang, 4)
    assertEqual(
        hangs,
        false,
        string.format(
            "a reading %d px wide was accepted on a slot with %d px to the panel"
                .. " edge, so it is drawn %d px off the side -- the verdict answered"
                .. " for the gap against the dial and was read as answering for the"
                .. " arrangement",
            overhang,
            room,
            math.floor(overhang / 2) - room
        )
    )

    -- And the near edge still fails for its own reason, so the check above has
    -- not merely replaced one blind spot with another: a reading that fits the
    -- panel but collides with the dial is refused too.
    local _, collides = theme.slotsFor(frame, room * 2, frame.content)
    assertEqual(collides, false, "a reading that fits the panel but meets the dial was accepted")
end

--- `fitReading`'s verdict is accurate, in both directions.
---
--- The function returns the smallest font on the ladder when nothing fits,
--- rather than failing, which is the only thing it can do -- but a caller
--- that reads only the font cannot tell that case from a comfortable fit.
--- `tx-battery` could not, and took width for a battery the reading needed.
---
--- So the verdict has to be right, and "right" is two claims: true only when
--- the returned form genuinely fits at the returned font, and false only when
--- no form fits at any font the room allows. Asserting one direction would
--- pass a function that always answered true.
local function testFitReadingReportsWhetherItFits()
    local ROOM = 200

    -- **Measured, not estimated, because that is what the function now asks.**
    -- A test that builds its boundary with a different width function than the
    -- code is testing a coincidence: these agreed only while `fitReading` also
    -- estimated, and the estimate over-reports by about half again at the
    -- larger fonts. Derived from `measureText` so the boundary here is the
    -- boundary there.
    -- Comfortable: a short reading in a wide column.
    local font, index, fits = theme.fitReading({ "88.8" }, 400, ROOM)
    assertEqual(fits, true)
    assertEqual(index, 1)
    assert(theme.measureText(font, "88.8") <= 400, "the verdict was true for a form that does not fit")

    -- Impossible: the widest reading this dashboard prints, in a column
    -- narrower than it needs at the smallest font on the ladder.
    local smallest = theme.READING_FONTS[#theme.READING_FONTS]
    local tooNarrow = theme.measureText(smallest, "888.88km") - 1
    local narrowFont, _, narrowFits = theme.fitReading({ "888.88km" }, tooNarrow, ROOM)
    assertEqual(narrowFits, false, "the verdict was true for a reading nothing could fit")
    assertFont(narrowFont, smallest, "a reading nothing could fit was not drawn at the smallest font")

    -- Exactly on the boundary, which is where an off-by-one lives: a column of
    -- exactly the width needed fits, and one pixel less does not.
    local exact = theme.measureText(smallest, "888.88km")
    assertEqual(
        select(3, theme.fitReading({ "888.88km" }, exact, ROOM)),
        true,
        "a column of exactly the width needed was called too narrow"
    )
    assertEqual(
        select(3, theme.fitReading({ "888.88km" }, exact - 1, ROOM)),
        false,
        "a column one pixel too narrow was called wide enough"
    )

    -- And the verdict follows the *form* that was chosen, not the longest
    -- offered: a caller whose short form fits gets true.
    local _, chosen, formFits = theme.fitReading({ "888.88km", "88" }, exact - 1, ROOM)
    assertEqual(formFits, true, "a caller offering a form that fits was told nothing fits")
    assertEqual(chosen, 2)

    -- The verdict is checked across the whole ladder rather than at one size,
    -- because a rule that varies with size proves nothing at a single one.
    local checked = 0
    for _, ladderFont in ipairs(theme.READING_FONTS) do
        local room = theme.fontHeight(ladderFont)
        local need = theme.measureText(ladderFont, "88.8")
        local got, _, verdict = theme.fitReading({ "88.8" }, need, room)
        checked = checked + 1
        assertFont(got, ladderFont, "a column of exactly the width needed moved the font")
        assertEqual(verdict, true, edgetx.fontName(ladderFont) .. " was told its exact width does not fit")
    end
    assertEqual(checked, #theme.READING_FONTS)
end

--- A unit sits on its reading's baseline, not its top and not its bottom.
---
--- **EdgeTX gives Lua no way to ask for this.** `lcd.sizeText` returns a
--- width and `getFontHeight`, which is `lv_font_get_line_height`; nothing in
--- `radio/src/lua/` exposes ascent or baseline. So the alternative to knowing
--- the numbers is aligning the two labels by their tops or by their bottoms,
--- and this measures how wrong each is rather than asserting that one of them
--- looks acceptable.
---
--- For the pairs this dashboard actually produces:
---
---     reading + unit        tops wrong by   bottoms wrong by
---     XXLSIZE + MIDSIZE          31 px             9 px
---     DBLSIZE + SMLSIZE          18 px             5 px
---     MIDSIZE + SMLSIZE          10 px             2 px
---     SMLSIZE + TINSIZE           4 px             1 px
---
--- Nine pixels is most of a MIDSIZE line's descender, so bottom alignment is
--- not a near miss at the size that matters most; the unit would sit visibly
--- below the number. The numbers are knowable, so neither approximation is
--- needed, and this test is what stops one creeping back in.
local function testUnitSitsOnTheBaseline()
    local citation = edgetx.citation("FONT_BASE_LINE")

    for font, base in pairs(firmware.FONT_BASE_LINE) do
        assertEqual(
            theme.fontBaseLine(font),
            base,
            edgetx.fontName(font)
                .. " has a different baseline from the font the"
                .. " radio ships ("
                .. citation.file
                .. ")"
        )
        assertEqual(
            theme.fontAscent(font),
            theme.fontHeight(font) - base,
            edgetx.fontName(font) .. "'s ascent is not its line height less its" .. " baseline"
        )
    end

    local checked = 0
    for _, reading in ipairs(theme.READING_FONTS) do
        local rider = theme.unitFont(reading)
        checked = checked + 1

        -- The rider is smaller. A unit at the reading's own size is a second
        -- reading rather than a unit.
        assert(
            theme.fontHeight(rider) < theme.fontHeight(reading),
            edgetx.fontName(reading)
                .. " rides with a unit at "
                .. edgetx.fontName(rider)
                .. ", which is not smaller than it"
        )

        -- Their baselines meet, at every y the caller might place the reading at.
        for _, y in ipairs({ 0, 7, 25, 104 }) do
            local unitY = theme.unitTop(reading, rider, y)
            assertEqual(
                unitY + theme.fontAscent(rider),
                y + theme.fontAscent(reading),
                edgetx.fontName(reading)
                    .. " and "
                    .. edgetx.fontName(rider)
                    .. " do not share a baseline when the reading's top is "
                    .. y
            )
        end

        -- And the two approximations are wrong, by enough to be worth the table.
        -- Asserting they differ from the truth is what stops someone replacing
        -- `unitTop` with `y` or with `height - unitHeight` and finding the suite
        -- still green.
        local trueTop = theme.unitTop(reading, rider, 0)
        assert(trueTop > 0, edgetx.fontName(reading) .. ": aligning tops is exactly right, so this pair proves nothing")
        local bottoms = theme.fontHeight(reading) - theme.fontHeight(rider)
        assert(
            bottoms ~= trueTop,
            edgetx.fontName(reading) .. ": aligning bottoms is exactly right, so this pair proves nothing"
        )
    end

    assertEqual(checked, #theme.READING_FONTS)

    -- The pair that matters most is the one the approximation is worst on.
    local worst = theme.fontHeight(XXLSIZE) - theme.fontHeight(MIDSIZE) - theme.unitTop(XXLSIZE, MIDSIZE, 0)
    assertEqual(
        worst,
        9,
        "the error in bottom alignment at the largest reading moved, so the" .. " table in this comment is stale"
    )
end

--- Text must be fitted by measured width as well as height, because a long
--- reading in a narrow cell clips sideways where a short one would not.
local function testTextFitting()
    assert(theme.textWidth(XXLSIZE, "1234") > theme.textWidth(SMLSIZE, "1234"), "a larger font must measure wider")
    assertEqual(theme.textWidth(SMLSIZE, ""), 0)
    assertEqual(theme.textWidth(SMLSIZE, nil), 0)

    -- Height alone would choose the biggest font that fits vertically, which is
    -- exactly the defect this exists to prevent.
    assertFont(theme.fitPrimary(80), XXLSIZE)
    assertFont(theme.fitText("-1234.5", 60, 80), SMLSIZE, "a narrow cell must reduce the font rather than clip")
    assertFont(theme.fitText("9", 400, 80), XXLSIZE, "a short value in a wide cell must keep the largest font")
    -- Nothing fits, so the smallest font is the honest answer.
    assertFont(theme.fitText("123456789012", 10, 10), SMLSIZE)

    -- A panel frame must keep its badge clear of its label at every width.
    local resolved = theme.build("modern-dark")
    for _, width in ipairs({ 60, 117, 238, 480 }) do
        local frame = theme.frame(resolved, { x = 0, y = 0, w = width, h = 134 }, theme.typography(1, 1))
        assert(frame.pad + frame.labelWidth <= frame.badgeX, "badge overlaps the label at width " .. width)
        assert(frame.badgeX + frame.badgeWidth <= width, "badge runs past the panel at width " .. width)
    end
end

--- Supporting text picks a wording that fits rather than clipping.
local function testLabelFitting()
    local variants = { "NO HOME POSITION", "NO HOME POS", "NO HOME" }

    assertEqual(
        theme.fitLabel(variants, SMLSIZE, 400),
        "NO HOME POSITION",
        "a wide row took a shorter wording than it had room for"
    )
    assertEqual(theme.fitLabel(variants, SMLSIZE, 120), "NO HOME POS")
    assertEqual(theme.fitLabel(variants, SMLSIZE, 80), "NO HOME")

    -- Nothing fits, so the shortest offered is the honest answer: the caller
    -- chose what its last resort would be.
    assertEqual(theme.fitLabel(variants, SMLSIZE, 4), "NO HOME")
    -- And a caller with no layout context gets the full wording.
    assertEqual(theme.fitLabel(variants, SMLSIZE, nil), "NO HOME POSITION")

    -- The chosen wording must actually fit, which is the property callers rely
    -- on; asserting which string comes back would pass on a helper that always
    -- returned the shortest one.
    for _, width in ipairs({ 400, 200, 120, 100, 80, 40 }) do
        local text = theme.fitLabel(variants, SMLSIZE, width)
        local needed = theme.textWidth(SMLSIZE, text)
        assert(
            needed <= width or text == variants[#variants],
            string.format("fitLabel returned %q needing %d px for a row of %d", text, needed, width)
        )
    end
end

--- A cell's outline is lighter beside a smaller number, all the way down.
---
--- The integration test drives the two fonts the grid actually produces. This
--- walks the whole ladder, including the two the panel cannot currently
--- reach, because `theme.fitReading` will hand back any of the five and a
--- stroke that only behaved at the two in use would be a trap for whoever
--- reaches the others.
---
--- Asserted as a shape -- never heavier beside a smaller number, and strictly
--- lighter at the ends -- rather than as five numbers. Pinning the numbers
--- would fail on any change to the ratio while saying nothing about whether
--- the ratio was still doing its job, and the numbers are pinned where they
--- matter anyway, in the documented table.
local function testBatteryStrokeScalesWithFont()
    local ladder = theme.READING_FONTS
    assert(#ladder >= 4, "the reading ladder is shorter than this test assumes")

    -- Wide enough that the width ceiling never binds, so what is measured is
    -- the font's contribution alone.
    local ROOMY = 60

    local previous, checked = nil, 0
    for index = #ladder, 1, -1 do
        local font = ladder[index]
        local stroke = primitives.batteryStroke(theme, font, ROOMY)
        checked = checked + 1

        assert(
            stroke >= primitives.GLYPH_STROKE_MIN,
            edgetx.fontName(font) .. " is outlined at " .. stroke .. ", which is a hairline rather than a drawn cell"
        )
        if previous then
            assert(
                stroke >= previous,
                edgetx.fontName(font) .. " is outlined more lightly than the smaller font below it"
            )
        end
        previous = stroke
    end

    assertEqual(checked, #ladder)

    -- The ends differ, which is what makes it a scale rather than a constant
    -- with a floor.
    local lightest = primitives.batteryStroke(theme, ladder[#ladder], ROOMY)
    local heaviest = primitives.batteryStroke(theme, ladder[1], ROOMY)
    assert(heaviest > lightest, "the largest and smallest readings are outlined" .. " identically, at " .. heaviest)

    -- A narrow cell is outlined more lightly than its reading asks for,
    -- because the stroke is taken out of the interior twice over. Without this
    -- the smallest cell the host will draw has a 13 pixel body outlined at 4,
    -- leaving 3 pixels of interior.
    local narrow = primitives.batteryStroke(theme, ladder[1], primitives.GLYPH_MIN_WIDTH)
    assert(narrow < heaviest, "the narrowest cell is outlined as heavily as the" .. " widest, at " .. narrow)

    -- And the interior it leaves is still a level rather than a line.
    local geometry = primitives.batteryGeometry(0, 0, primitives.GLYPH_MIN_WIDTH, primitives.GLYPH_MIN_HEIGHT, narrow)
    assert(geometry.interiorWidth >= 4, "the smallest cell has a " .. geometry.interiorWidth .. " pixel interior")
    assert(
        geometry.interiorHeight >= 8,
        "the smallest cell has a "
            .. geometry.interiorHeight
            .. " pixel interior height, so a level in it"
            .. " could not be read as a proportion"
    )

    -- A level partway up that interior lands somewhere distinguishable from
    -- both ends, which is the property the interior exists for.
    local level = primitives.batteryFill(geometry, 0.5)
    assert(
        level > 1 and level < geometry.interiorHeight - 1,
        "half a charge in the smallest cell draws at "
            .. level
            .. " of "
            .. geometry.interiorHeight
            .. ", which reads as empty or full"
    )
end

--- A battery stays visible in every state, on every palette.
---
--- The user asked for the outline, the terminal and the level to share one
--- state colour, so a critical pack is red throughout. The empty part of the
--- cell is then the panel showing through, and a red cell on a red-tinted
--- panel is the case most likely to disappear. This is that case, held to a
--- number.
---
--- A first pass at this measured 1.01 for exactly that pairing and led to a
--- backing rectangle being added to fix a problem that was not there. The
--- reading was taken on `resolved.color`, whose values are `LcdFlags` words
--- rather than colours; `theme.contrast` is arithmetic on colour channels and
--- the resolved theme carries `rgb` and `alertRgb` for this purpose. Every
--- value below is a 24-bit one.
local function testBatteryStaysVisible()
    -- 3 is roughly where two colours stop being tellable apart at a glance from
    -- arm's length. The worst pairing this palette produces is 3.07, so the
    -- cell clears it everywhere, and a change that made any state worse would
    -- be caught here rather than on a radio.
    local LEAST = 3

    --- What the cell is drawn in, which is the state's own accent.
    local function cellRgb(resolved, state, accent)
        if state == "warning" then
            return resolved.rgb.amber
        end
        if state == "critical" then
            return resolved.rgb.critical
        end
        if state == "stale" or state == "unavailable" then
            return resolved.rgb.textFaint
        end
        return resolved.rgb[accent]
    end

    local checked, worst, where = 0, 99, ""
    for _, mode in ipairs({ "modern-dark", "modern-light" }) do
        local resolved = theme.build(mode)
        for _, state in ipairs({ "normal", "warning", "critical", "stale", "unavailable" }) do
            local backdrop = primitives.batteryBackdropRgb(resolved, state)
            for _, accent in ipairs({ "cyan", "green", "amber", "orange" }) do
                local ratio = theme.contrast(cellRgb(resolved, state, accent), backdrop)
                local minimum = LEAST
                -- Modern Light deliberately preserves its brighter amber without correction.
                if mode == "modern-light" and (state == "warning" or (state == "normal" and accent == "amber")) then
                    minimum = 1.5
                end
                checked = checked + 1
                if ratio < worst then
                    worst, where = ratio, mode .. "/" .. state .. "/" .. accent
                end
                assert(
                    ratio >= minimum,
                    mode
                        .. "/"
                        .. state
                        .. "/"
                        .. accent
                        .. ": the cell is indistinguishable from the panel it stands on, at "
                        .. string.format("%.2f", ratio)
                )
            end
        end
    end

    assert(checked >= 40, "only " .. checked .. " combinations were checked")

    -- The margin is recorded rather than merely cleared, so a change that eats
    -- most of it is visible in the diff even while the test still passes.
    assert(
        worst < 3.5,
        "the worst pairing is now "
            .. string.format("%.2f", worst)
            .. " at "
            .. where
            .. ", so this test no longer describes the palette"
    )

    -- And the pairing the whole question was about, named rather than left to
    -- be inferred from the loop.
    local modern = theme.build("modern-dark")
    assert(
        theme.contrast(modern.rgb.critical, modern.alertRgb.critical) >= LEAST,
        "a red cell on a red panel stopped being readable"
    )
end

--- A clock never outgrows the form its font was chosen from.
---
--- **A sizing form is a claim about the future**, and nothing in this suite
--- could check one: it names the widest string a panel will ever print,
--- and "ever" is not a thing a fixture can build. This project has now been
--- wrong about it twice, in opposite directions and with opposite costs.
---
---  * `model-identity` was sized for **less** than it draws. Its form was a
---    row of `M`, measured by an estimate that under-reports capitals, and
---    the model name ran eleven pixels past the panel at `1 x 2`. Sized too
---    small, so it clipped.
---  * `flight-timer` was sized for **more** than it draws. Its form was
---    `-88:88:88`, reserving for a countdown ten hours past zero, which
---    measures 218 px against a `2 x 2` content box of 226 -- so the clock
---    stepped down a font on 8 px of margin, and the `3 x 2` beside it with
---    129 px did not. Sized too large, so it cost a size. Worse, the margin
---    was inside what the harness cannot resolve: it models glyph advances
---    from the one uncompressed font in the tree and the dashboard draws in
---    bold faces, so the radio stepped down where the harness did not. Two
---    panels of one height disagreed on a radio and agreed here.
---
--- Neither was catchable by measuring the form, because in both cases the
--- form was measured correctly and was the wrong string. What is checkable
--- is the **loop**: where a panel bounds what it can print, the bound's
--- own output must equal the form. That is what this asserts, and it is why
--- `flight-timer.FORMS` is `-99:59` -- a value the clamp can actually
--- produce -- rather than a row of eights that is not even a valid clock.
---
--- It only reaches a panel that *has* a bound. `model-identity`'s name
--- comes from the pilot and has none, which is the residue: see the
--- specification's note on forms.
local function testClockNeverOutgrowsItsForm()
    local timer = loadModule("panels/flight-timer.lua")

    -- The bound, stated in seconds and as the string it prints.
    assertEqual(timer.CLAMP, 99 * 60 + 59)
    assertEqual(timer.formatClock(timer.CLAMP), "99:59")
    assertEqual(timer.formatClock(-timer.CLAMP), "-99:59")

    -- **The clock does not change shape.** The minutes field keeps counting
    -- rather than growing an hours field, so a reading crossing an hour does
    -- not widen by two characters while it is being read. This is what the
    -- shared formatter does instead, and why this panel does not use it.
    assertEqual(timer.formatClock(3599), "59:59")
    assertEqual(timer.formatClock(3600), "60:00", "the clock grew an hours field, so its width is not fixed after all")
    assertEqual(
        modelService.formatTime(3600),
        "1:00:00",
        "the service stopped reporting hours, which the diagnostics line wants"
    )

    -- **The loop.** The widest string the clamp can produce is the form the
    -- font was chosen from. Break either and this fails.
    assertEqual(
        timer.formatClock(timer.clamp(-math.huge)),
        timer.FORMS[1],
        "the clamp can print a string wider than the form sized for it"
    )

    -- And the form is the wider of the two signs, because a sign costs width
    -- and the negative one is the reachable state this panel exists for.
    assert(
        theme.measureText(theme.READING_FONTS[1], timer.FORMS[1])
            >= theme.measureText(theme.READING_FONTS[1], timer.formatClock(timer.CLAMP)),
        "the form is narrower than the positive clamp, so the sign was forgotten"
    )

    -- The clamp bounds magnitude and leaves direction alone. An expired
    -- countdown is negative and is the one state this panel must never
    -- let be misread as healthy, so the sign survives whatever the magnitude.
    assertEqual(timer.clamp(5999), 5999, "a value inside the bound moved")
    assertEqual(timer.clamp(-5999), -5999)
    assertEqual(timer.clamp(6000), 5999, "a value past the bound was not folded")
    assertEqual(
        timer.clamp(-6000),
        -5999,
        "a countdown past zero lost its sign at the clamp, which reports time"
            .. " remaining where the truth is time overrun"
    )

    -- EdgeTX's own extremes, which a pilot can set from Model Setup: TIMER_MAX
    -- is 0xffffff/2 (radio/src/timers.h:34) and TIMER_MIN is its negative
    -- (radio/src/timers.h:36). Both are 2330 hours, so what the clamp folds
    -- away is genuinely reachable in firmware.
    local TIMER_MAX = math.floor(0xffffff / 2)
    assertEqual(timer.clamp(TIMER_MAX), 5999)
    assertEqual(timer.clamp(-TIMER_MAX - 1), -5999)
    assertEqual(timer.formatClock(timer.clamp(TIMER_MAX)), "99:59")
    assertEqual(timer.formatClock(timer.clamp(-TIMER_MAX - 1)), "-99:59")

    -- A value that is not a number passes through, because `formatTime`
    -- already answers `--:--` for one and a clamp that invented a zero would
    -- turn an absent timer into a running one.
    assertEqual(timer.clamp(nil), nil)
    assertEqual(timer.formatClock(timer.clamp(nil)), "--:--")

    -- **The service is not clamped.** `service-probe` reports what the radio
    -- said, and a diagnostics view showing a folded value would be reporting
    -- on a world assembled for it rather than the one the dashboard is in.
    assertEqual(
        modelService.formatTime(TIMER_MAX),
        "2330:10:07",
        "the shared formatter was clamped, so the diagnostics view now lies"
    )
end

--- A reading that holds no redundancy offers exactly one form.
---
--- This is the magnitude rule, checked at the only place it can be: the forms
--- a panel declares. Every entry below is a reading with nothing to give
--- up, and offering it a shorter form would mean dropping a digit, a clock
--- field, or a unit that is not redundant. `flight-timer` had such a form and
--- it turned `1:04:12` into `04:12`, an hour reported as four minutes.
local function testLosslessReadingsOfferOneForm()
    local cases = {
        { "flight-timer", "FORMS", "a clock has no redundancy: every shorter form drops a field" },
    }

    for _, case in ipairs(cases) do
        local module = loadModule("panels/" .. case[1] .. ".lua")
        local forms = module[case[2]]
        assert(type(forms) == "table", case[1] .. " declares no forms")
        if case[3] then
            assertEqual(#forms, 1, case[1] .. ": " .. case[3])
        end
    end

    -- A distance cannot shorten, and unlike a voltage it cannot drop its unit
    -- either: the unit changes with range, so `1.23km` and `1.23m` are
    -- different readings rather than one abbreviated.
    local navigation = loadModule("panels/navigation.lua")
    assertEqual(navigation.DIGITS, "888.88")
    assertEqual(navigation.UNIT, "km")

    -- And a metric, whose unit is a separate label entirely.
    local metric = loadModule("panels/metric.lua")
    assertEqual(
        #metric.widestSample({ rangeMin = 0, rangeMax = 400 }, 1),
        1,
        "a metric offered a shorter form, which could only lose a digit"
    )
end

--- The redraw decision covers the whole declaration, including its shape.
---
--- Comparing values alone is not enough, because a panel may stop drawing
--- something: a bar writes a zero tick only while its range
--- spans zero, and drops the key when it no longer does. A comparison that
--- walked only the new table would find every key it held unchanged and
--- report no change, leaving a tick on screen over a range that has none.
---
--- The reused scratch table is the other half of that. If it were not cleared
--- between renders, a key written once would linger for the life of the panel
--- and compare equal to itself forever, which is the same defect wearing the
--- opposite hat.
local function testRedrawDecision()
    local context = {}
    local function renderer(fields)
        return function(_, out)
            for key, value in pairs(fields) do
                out[key] = value
            end
        end
    end

    local changed, drawn = primitives.changed(context, renderer({ a = 1, b = "x" }))
    assertEqual(changed, true, "the first render must paint")
    assertEqual(drawn.a, 1)

    assertEqual(
        primitives.changed(context, renderer({ a = 1, b = "x" })),
        false,
        "nothing moved and the panel repainted anyway"
    )

    assertEqual(primitives.changed(context, renderer({ a = 2, b = "x" })), true, "a changed value did not repaint")

    -- A key that appears is a change.
    assertEqual(
        primitives.changed(context, renderer({ a = 2, b = "x", c = true }), true),
        true,
        "a new field did not repaint"
    )

    -- And a key that disappears is a change, which is the case a walk over the
    -- new table alone cannot see: every key it still holds is unchanged.
    local gone = primitives.changed(context, renderer({ a = 2, b = "x" }))
    assertEqual(gone, true, "a field that stopped being drawn did not repaint")

    -- The table handed back must hold only what this render wrote. A key left
    -- over from an earlier render would be painted, and would compare equal to
    -- itself on every frame after that.
    local _, current = primitives.changed(context, renderer({ a = 3 }))
    assertEqual(current.a, 3)
    assertEqual(current.b, nil, "a field from an earlier render survived into this one")
    assertEqual(current.c, nil, "a field from an earlier render survived into this one")
end

--- One ladder, so two panels of the same size answer the same question.
---
--- Every panel used to decide its own composition and then fit its own
--- string against the result, so identical panels disagreed twice over. The
--- assertions here are about *agreement between panels*, which is the
--- thing that was broken; a bound like "no larger than the box allows" was
--- true of the old code too and would prove nothing.
--- A heading lands in the same place whatever the panel's height.
---
--- It used to be centred in the label band, which is a quarter of the
--- panel's extent, so it drifted downward as panels grew: 0 px from the top
--- on a one-row panel, 13 on two rows, 21 on three and 30 on four. A column
--- of panels of different heights had its headings at four different
--- offsets, which is what the user saw on the radio.
---
--- The band is right for a **reading**, where growing with the panel is the
--- point, and wrong for furniture that says what the panel is.
---
--- **And the body must not move with it.** `frame.top` feeds `theme.ladder`,
--- which decides whether a panel is granted a supporting row, and
--- `theme.bands`, which decides where the reading sits. Letting the body
--- rise into the space the heading vacated would change what every panel in
--- the catalogue draws. So `top` is asserted to be what it was, span by
--- span, beside the heading that moved.
--- Every reading sits in its panel's body band, including the one that is a
--- name rather than a number.
---
--- `model-identity` pinned its name directly under the heading instead, at
--- the panel's content top. That is not where anything else on the dashboard
--- puts a reading, and on a tall panel it was far from it: 16 px above the
--- band at `2 x 2`, 45 at `2 x 3` and 59 at `4 x 4`, the name stuck to the
--- heading with the panel empty beneath it.
---
--- It went unnoticed through eight milestones and four reviews because it is
--- the only reading in the catalogue that is text, so no cross-panel
--- comparison ever lined it up against a neighbour and no font assertion
--- covered it -- the band rule chooses the same font either way, because the
--- font comes from the band's height and not from where the reading sits in
--- it. **Nothing about the numbers says the reading is in the wrong place
--- unless where it sits is asserted.**
local function testReadingsSitInTheirBand()
    local resolved = theme.build("modern-dark")
    local GUTTER, CELLS, WIDTH, HEIGHT = 4, 4, 480, 272
    local cellWidth = math.floor((WIDTH - GUTTER * (CELLS - 1)) / CELLS)
    local cellHeight = math.floor((HEIGHT - GUTTER * (CELLS - 1)) / CELLS)

    local identity = loadModule("panels/model-identity.lua")
    local checked = 0

    for _, span in ipairs(identity.supportedSpans) do
        local cols, rows = string.match(span, "(%d)x(%d)")
        cols, rows = tonumber(cols), tonumber(rows)
        local rect = {
            x = 0,
            y = 0,
            w = cellWidth * cols + GUTTER * (cols - 1),
            h = cellHeight * rows + GUTTER * (rows - 1),
        }
        local fonts = theme.typography(cols, rows)
        -- `presentation: name` is the case this is about. With a picture the
        -- name is the heading and the body belongs to the picture, which is a
        -- different arrangement and is settled.
        local settings = { presentation = "name" }
        local layout = identity.presentationFor(settings, cols, rows)
        local area = identity.regionsFor(resolved, theme, rect, layout, fonts, settings)

        -- Asked of the ladder the way every other panel asks, and told what
        -- this panel draws rather than what its span permits: a name-only panel
        -- draws no supporting row.
        local frame = theme.frame(resolved, rect, fonts)
        local ladder = theme.ladder(resolved, rect, frame, { rows = layout.showLabels == true })
        -- Ink, as the panel asks and as every other reading is placed.
        local expected = theme.bodyTop(ladder, theme.fontAscent(area.nameFont))

        checked = checked + 1
        assertEqual(
            area.nameY,
            expected,
            string.format(
                "model-identity at %s draws its name at y=%d where the shared body"
                    .. " band puts a reading of that size at y=%d, %d px away. Every"
                    .. " other reading in the catalogue is centred in this band; a name"
                    .. " pinned under the heading is the one panel that disagrees with"
                    .. " the rest of the dashboard",
                span,
                area.nameY,
                expected,
                math.abs(area.nameY - expected)
            )
        )
    end

    assertEqual(checked, #identity.supportedSpans, "not every declared span was measured")
end

--- **The supporting row hangs one inset above its floor**, mirroring the
--- heading pinned one inset below the panel's top.
---
--- The two together are what make the reading look centred. It already
--- *was* centred, to the pixel, before either of them -- what the eye judges
--- is the gap above against the gap below, and a pinned heading against a
--- row centred in a quarter gives two different gaps around a correctly
--- centred number.
---
--- **Asserted as a distance from the floor, not as a coordinate.** A check
--- that recomputed `theme.rowTop` and compared would agree with any
--- arithmetic at all, including the centring this replaces.
--- **A reading clears the supporting row beneath it, at every height a
--- reflow can produce rather than only the eight the grid can.**
---
--- The reading is centred on the panel and grows symmetrically about that
--- centre, so a row moving up meets it halfway.
---
--- **What it catches and what it does not, established by breaking both.**
--- Moving the row up 30 px fails it by name at 117 x 79. Removing
--- `theme.readingRoom`'s floor cap altogether does *not* -- and that is a
--- finding rather than a weakness in the check: pinning the row moved it far
--- enough down that the half-panel budget now binds first on every panel
--- granted a row, so the cap #86 added is dead for them. It is still live
--- for a panel with no row at all, where it is what keeps a reading sized
--- against its whole height from hanging a descending unit off the bottom
--- edge -- `testAReadingAloneTakesTheWholePanel` is what holds that, and it
--- goes red if the cap is removed.
---
--- So this sweep watches the row against the reading, and nothing else.
---
--- **It is a sweep because the grid cannot reach the tight cases.** A 4 x 4
--- grid over 480 x 272 builds eleven panel heights; a zone in App mode is
--- whatever the screen leaves, and a reflowed widget sees any of them.
---
--- **What this does not cover, and it is a real gap.** A panel that reserves
--- a bar and is *not* granted a supporting row has the bar's own track
--- beneath its reading, and nothing caps the reading against it: eight
--- panel sizes between 40 and 272 px put a descending unit into their own
--- bar, worst case one pixel at 117 x 48. That predates pinning -- it is
--- unchanged on `main` -- and the obvious cap is wrong, because the ladder
--- is told only that a visualization was *granted*, which for a battery cell
--- or a compass is something standing beside the reading rather than under
--- it. Capping on that shed `tx-battery`'s cell at three Full-screen spans.
--- Reported rather than fixed here, because it is not this change's defect
--- and the fix needs the bar's own question asked somewhere that knows it.
local function testAReadingClearsTheRowBeneathIt()
    local resolved = theme.build("modern-dark")
    local swept, tightest, where = 0, math.huge, ""

    for height = 40, 272 do
        for _, width in ipairs({ 117, 238, 480 }) do
            local rect = { x = 0, y = 0, w = width, h = height }
            local fonts = theme.typography(2, 2)
            local frame = theme.frame(resolved, rect, fonts)
            local ladder = theme.ladder(resolved, rect, frame)

            if ladder.rows > 0 then
                local font = theme.bandFont(ladder.room)
                local ink = theme.fontAscent(font)
                local bottom = theme.bodyTop(ladder, ink) + ink + theme.riderDepth()
                local rowY = theme.rowTop(frame, fonts.label, rect.h)
                swept = swept + 1
                if rowY - bottom < tightest then
                    tightest = rowY - bottom
                    where = string.format("%d x %d, reading ends at %d, row at %d", width, height, bottom, rowY)
                end
            end
        end
    end

    assert(swept >= 400, "only " .. swept .. " panels in the sweep were granted a supporting row")
    assert(tightest >= 0, "a reading reaches " .. -tightest .. " px into the row beneath it at " .. where)
end

--- **The supporting row hangs one inset above its floor**, mirroring the
--- heading pinned one inset below the panel's top.
---
--- The two together are what make the reading look centred. It already
--- *was* centred, to the pixel, before either of them -- what the eye judges
--- is the gap above against the gap below, and a pinned heading against a
--- row centred in a quarter gives two different gaps around a correctly
--- centred number.
---
--- **Asserted as a distance from the floor, not as a coordinate.** A check
--- that recomputed `theme.rowTop` and compared would agree with any
--- arithmetic at all, including the centring this replaces.
local function testTheRowHangsFromTheFloor()
    local resolved = theme.build("modern-dark")
    local GUTTER, CELLS, WIDTH, HEIGHT = 4, 4, 480, 272
    local cellHeight = math.floor((HEIGHT - GUTTER * (CELLS - 1)) / CELLS)

    -- Where a centred row landed, measured on the commit before pinning.
    -- Written out rather than derived, for the reason the heading's twin
    -- states: an expectation computed from the code under test passes whatever
    -- the code does.
    local CENTRED_BEFORE = { 45, 106, 166, 227 }

    local checked = 0
    for rows = 2, 4 do
        local rect = { x = 0, y = 0, w = 238, h = cellHeight * rows + GUTTER * (rows - 1) }
        local fonts = theme.typography(2, rows)
        local frame = theme.frame(resolved, rect, fonts)
        local font = fonts.label
        local ink = theme.fontAscent(font)

        -- A bare panel hangs its row from the bottom edge.
        local bare = theme.rowTop(frame, font, rect.h)
        assertEqual(
            rect.h - (bare + ink),
            frame.compact,
            string.format(
                "a %d-row panel put its supporting row's baseline %d px above the"
                    .. " panel's floor where the heading sits %d px below its top, so"
                    .. " the slack above the reading and the slack below it differ",
                rows,
                rect.h - (bare + ink),
                frame.compact
            )
        )

        assert(
            bare ~= CENTRED_BEFORE[rows],
            string.format(
                "a %d-row panel still puts its row where centring in the bottom"
                    .. " quarter put it, so nothing was pinned",
                rows
            )
        )

        -- And the whole of it stays on the panel, descender included. `LQ 88%%`
        -- is the one catalogue wording that reaches below its baseline.
        local deepest = theme.fontHeight(font) - ink
        assert(
            bare + ink + deepest <= rect.h,
            string.format(
                "a %d-row panel hangs its row's descent %d px off the panel's floor",
                rows,
                (bare + ink + deepest) - rect.h
            )
        )

        -- A panel reserving a bar hangs the row from the bar instead, by the
        -- same inset, because the bar owns the floor.
        local barY = rect.h - frame.bottom - resolved.spacing.barHeight
        local barred = theme.rowTop(frame, font, barY)
        assertEqual(
            barY - (barred + ink),
            frame.compact,
            string.format(
                "a %d-row panel with a bar hung its row %d px above the bar where a"
                    .. " bare panel hangs its row %d px above the floor",
                rows,
                barY - (barred + ink),
                frame.compact
            )
        )
        assert(
            barred + ink + deepest <= barY,
            string.format(
                "a %d-row panel drew its row's descent %d px into the bar beneath it",
                rows,
                (barred + ink + deepest) - barY
            )
        )

        -- **A group is pinned by its last row, not by its first.** Pinning each
        -- row would put both on the floor; pinning the first would put the
        -- second off the panel.
        local group = theme.rowTop(frame, font, rect.h, 2)
        local second = group + theme.fontHeight(font) + 2
        assertEqual(
            rect.h - (second + ink),
            frame.compact,
            string.format(
                "a %d-row panel hung a two-row group by the wrong row: its last row's"
                    .. " baseline is %d px above the floor",
                rows,
                rect.h - (second + ink)
            )
        )
        assert(group < bare, "a two-row group did not start above a single row")
        checked = checked + 1
    end
    assertEqual(checked, 3, "not every span was measured")

    -- **The inset is never less than the font's descent**, and the one panel
    -- that proves it is both tight and granted a row: 238 x 79 insets by 2 px
    -- while `SMLSIZE` carries 4 px below its baseline. Without the floor the
    -- `%` of `LQ 88%%` would touch the bar it hangs from.
    local tight = { x = 0, y = 0, w = 238, h = 79 }
    local tightFonts = theme.typography(2, 1)
    local tightFrame = theme.frame(resolved, tight, tightFonts)
    local tightLadder = theme.ladder(resolved, tight, tightFrame)
    assertEqual(tightFrame.compact, 2, "the tight panel this case is built on is no longer tight")
    assertEqual(tightLadder.rows, 1, "the tight panel this case is built on is no longer granted a row")

    local tightFont = tightFonts.label
    local tightInk = theme.fontAscent(tightFont)
    local tightDeep = theme.fontHeight(tightFont) - tightInk
    local tightBar = tight.h - tightFrame.bottom - resolved.spacing.barHeight
    local placed = theme.rowTop(tightFrame, tightFont, tightBar)
    assert(
        placed + tightInk + tightDeep <= tightBar,
        string.format(
            "the one tight panel that draws a row hangs its descent %d px into the" .. " bar",
            (placed + tightInk + tightDeep) - tightBar
        )
    )
end

local function testHeadingIsPinnedToTheTop()
    testTheRowHangsFromTheFloor()
    testAReadingClearsTheRowBeneathIt()
    local resolved = theme.build("modern-dark")
    local GUTTER, CELLS, WIDTH, HEIGHT = 4, 4, 480, 272
    local cellHeight = math.floor((HEIGHT - GUTTER * (CELLS - 1)) / CELLS)

    -- What `frame.top` was before the heading was pinned, measured on the
    -- commit that pinned it. Written out rather than recomputed, because a
    -- test that derives the expectation from the same arithmetic it is
    -- checking agrees with any arithmetic at all.
    local TOP_BEFORE = { 21, 32, 40, 49 }

    local offsets = {}
    for rows = 1, 4 do
        local rect = { x = 0, y = 0, w = 117, h = cellHeight * rows + GUTTER * (rows - 1) }
        local fonts = theme.typography(1, rows)
        local frame = theme.frame(resolved, rect, fonts)

        offsets[#offsets + 1] = frame.labelY
        assertEqual(
            frame.labelY,
            frame.compact,
            string.format(
                "a %d-row panel put its heading %d px below the panel's own top inset,"
                    .. " so a column of panels of different heights has its headings at"
                    .. " different offsets",
                rows,
                frame.labelY - frame.compact
            )
        )

        assertEqual(
            frame.top,
            TOP_BEFORE[rows],
            string.format(
                "pinning the heading moved where content begins on a %d-row panel."
                    .. " `frame.top` feeds the ladder's row and visual grants and the"
                    .. " body band's position, so this is every reading in the catalogue"
                    .. " moving, not a heading",
                rows
            )
        )
    end

    -- **Two positions remain, and they are the panel's own top inset rather
    -- than the heading's own idea.** A panel under 80 px tall is `tight` and
    -- takes 2 px of vertical inset where a taller one takes 6, which is an
    -- existing rule that governs every vertical measurement on such a panel,
    -- not something the heading decides. It cannot be flattened to one number
    -- either: a tight panel's content begins at 21 px and its heading is 17 px
    -- tall, so a heading pinned to 6 would run 2 px into the body.
    --
    -- So the property is that panels sharing a top inset share a heading
    -- offset -- which is what the user sees as "the heading is always in the
    -- same place" -- and the residual 4 px belongs to the tight rule.
    local byInset = {}
    for rows = 1, 4 do
        local rect = { x = 0, y = 0, w = 117, h = cellHeight * rows + GUTTER * (rows - 1) }
        local frame = theme.frame(resolved, rect, theme.typography(1, rows))
        local seen = byInset[frame.compact]
        if seen == nil then
            byInset[frame.compact] = offsets[rows]
        else
            assertEqual(
                offsets[rows],
                seen,
                string.format(
                    "two panels with the same %d px top inset put their headings at" .. " different heights",
                    frame.compact
                )
            )
        end
    end

    -- And the spread is the inset's, not the band's. Four offsets became two,
    -- and the two differ by exactly the tight rule's 4 px.
    local lowest, highest = offsets[1], offsets[1]
    for _, value in ipairs(offsets) do
        if value < lowest then
            lowest = value
        end
        if value > highest then
            highest = value
        end
    end
    assertEqual(
        highest - lowest,
        4,
        string.format(
            "headings span %d px across panel heights; the band-centred rule this"
                .. " replaced spanned 30, and the tight inset accounts for 4",
            highest - lowest
        )
    )
end

local function testSharedLadder()
    local resolved = theme.build("modern-dark")

    --- The composition a panel of this size carries.
    local function ladderFor(w, h)
        local fonts = theme.typography(w >= 200 and 2 or 1, h >= 100 and 2 or 1)
        local frame = theme.frame(resolved, { x = 0, y = 0, w = w, h = h }, fonts)
        return theme.ladder(resolved, { x = 0, y = 0, w = w, h = h }, frame)
    end

    -- A single grid row has no space for a supporting row once the reading has
    -- what it needs; two rows do. This is the decision that used to be made
    -- eight times, and it is now made once and is the same answer for everyone.
    assertEqual(ladderFor(238, 65).rows, 0, "a 65 px panel claimed room for a supporting row")
    assertEqual(ladderFor(238, 134).rows, 1, "a 134 px panel did not grant a supporting row")
    assertEqual(ladderFor(238, 65).visual, true, "a 65 px panel cannot carry a bar")

    -- The room left for the reading grows with the panel, and never shrinks as
    -- it grows. That is the property the four non-monotonic ladders violated.
    local previous = 0
    for _, h in ipairs({ 65, 134, 203, 272 }) do
        local room = ladderFor(238, h).room
        assert(room >= previous, string.format("a %d px panel left less room for its reading than a shorter one", h))
        previous = room
    end
end

--- A reading may give up redundancy, never magnitude.
local function testReadingForms()
    -- The box decides the font. Same box, same answer, whatever is drawn in it.
    local a = theme.fitReading({ "100" }, 226, 80)
    local b = theme.fitReading({ "4.44V" }, 226, 80)
    assertFont(a, b, "two readings in the same box chose different fonts")

    -- The longest form is preferred wherever it fits. Taking a shorter one
    -- anyway gives up a unit for nothing, and an assertion that only looked at
    -- narrow panels would never notice.
    local wide, wideIndex = theme.fitReading({ "-100dBm", "-100" }, 400, 80)
    assertEqual(wideIndex, 1, "a reading abbreviated on a panel with room for it")

    -- And abbreviating is preferred to shrinking, which is the whole mechanism:
    -- at this width the full form does not fit at the target size, so the unit
    -- goes and the reading stays the size its neighbours are.
    --
    -- **The width is 150 because 226 no longer constructs this case.** A room
    -- of 80 chooses XXLSIZE, where `-100dBm` advances 212 px and `-100`
    -- advances 103. While fitting estimated, 226 px was narrow enough to force
    -- the abbreviation; measured, the full form fits there with 14 px to spare
    -- and the first assertion above already covers that. A width between the
    -- two is what actually exercises dropping redundancy rather than
    -- magnitude.
    local kept, keptIndex = theme.fitReading({ "-100dBm", "-100" }, 150, 80)
    assertEqual(keptIndex, 2, "the reading shrank instead of dropping its unit")
    assertFont(
        kept,
        theme.fitReading({ "100" }, 150, 80),
        "abbreviating did not keep the reading at its neighbours' size"
    )

    -- With nothing to give up, the font steps instead. Offering one form is how
    -- a panel says its reading holds no redundancy.
    local only = theme.fitReading({ "-88:88:88" }, 150, 80)
    assert(
        theme.fontHeight(only) < theme.fontHeight(kept),
        "a reading with no shorter form kept a size it does not fit"
    )

    -- Whatever comes back must actually fit, or the panel clips. This is the
    -- property; asserting a particular font would pass on a helper that always
    -- returned the smallest.
    -- **`MMMMMM` is in this list because it is the case the old check could not
    -- have caught.** The estimate is a per-character allowance sized between a
    -- digit and a capital: at MIDSIZE it allows 16.8 px where `8` advances 12
    -- and `M` advances 19. So it over-reports digits and *under*-reports
    -- capitals, and `model-identity` sizes its panel against a row of `M`
    -- because that is the widest name EdgeTX will store. At `1 x 2` that chose
    -- MIDSIZE for a form the estimate called 101 px and the font draws in 116,
    -- against 105 px of content -- eleven pixels past the panel, in a
    -- panel whose whole reading is the name. Every form here used to be
    -- digits, so nothing in the suite stood where that happened.
    for _, width in ipairs({ 400, 226, 160, 105, 60, 30 }) do
        for _, forms in ipairs({
            { "100" },
            { "-100dBm", "-100" },
            { "888.88km" },
            { "MMMMMMMMMMMMMMM", "MMMMMMMMMM", "MMMMMM" },
        }) do
            local chosen, at = theme.fitReading(forms, width, 80)
            -- Measured, because "actually fits" is a claim about the pixels the
            -- font advances and not about the estimate of them.
            local needed = theme.measureText(chosen, forms[at])
            assert(
                needed <= width or chosen == SMLSIZE,
                string.format(
                    "fitReading returned %q at %s, needing %d px of %d",
                    forms[at],
                    edgetx.fontName(chosen),
                    needed,
                    width
                )
            )
        end
    end
end

--- A bipolar bar grows outward from its own centre and keeps its neutral
--- marker visible at every deflection.
local function testBipolarGeometry()
    assertEqual(primitives.signedFraction(50, -100, 100), 0.5)
    assertEqual(primitives.signedFraction(-50, -100, 100), -0.5)
    -- Each side is measured against its own bound, so an asymmetric range is
    -- still centred at zero rather than at the middle of its span.
    assertEqual(primitives.signedFraction(-10, -20, 100), -0.5)
    assertEqual(primitives.signedFraction(500, -100, 100), 1)
    assertEqual(primitives.signedFraction(0 / 0, -100, 100), 0)
    assertEqual(primitives.signedFraction(5, -100, 0), 0, "a bound of zero cannot produce a fraction")

    -- setBipolarBar is pure geometry, so it is checked against a recording stub
    -- rather than against a live LVGL object.
    local bar = {
        x = 10,
        y = 20,
        w = 100,
        h = 8,
        vertical = false,
        fill = {
            set = function(self, changes)
                self.last = changes
            end,
        },
    }

    primitives.setBipolarBar(bar, 0.5)
    assertEqual(bar.fill.last.x, 60, "a positive fill must start at the centre")
    assertEqual(bar.fill.last.w, 25)

    primitives.setBipolarBar(bar, -0.5)
    assertEqual(bar.fill.last.x, 35, "a negative fill must end at the centre")
    assertEqual(bar.fill.last.w, 25)

    primitives.setBipolarBar(bar, 0)
    assertEqual(bar.fill.last.w, 1, "a centred bar must still be visible")

    local upright = {
        x = 0,
        y = 0,
        w = 6,
        h = 100,
        vertical = true,
        fill = {
            set = function(self, changes)
                self.last = changes
            end,
        },
    }
    primitives.setBipolarBar(upright, 1)
    assertEqual(upright.fill.last.y, 0, "positive deflection must grow upward")
    assertEqual(upright.fill.last.h, 50)
    primitives.setBipolarBar(upright, -1)
    assertEqual(upright.fill.last.y, 50, "negative deflection must grow downward")
end

--- Explicit settings retain their values; missing presentation gets defaults.
local function testMetricDefaults()
    local metric = loadModule("panels/metric.lua")

    local settings, warnings = panelHost.resolveSettings(metric, {
        metrics = { { source = "Alt", label = "HEIGHT", rangeMax = 1200 } },
    })
    assertEqual(#warnings, 0)
    assertEqual(settings.accent, "cyan")
    assertEqual(settings.visual, "bar")
    assertEqual(settings.metrics[1].label, "HEIGHT")
    assertEqual(settings.metrics[1].rangeMax, 1200)
    assert(#metric.validateSettings({}) > 0, "missing metrics must be rejected")
    for _, key in ipairs({
        "preset",
        "source",
        "label",
        "unit",
        "precision",
        "rangeMin",
        "rangeMax",
        "warning",
        "critical",
        "direction",
        "extrema",
        "extremaMode",
        "extremaSource",
        "secondarySource",
        "secondaryLabel",
    }) do
        local _, rejected = panelHost.resolveSettings(metric, { metrics = { { source = "Alt" } }, [key] = "old" })
        assert(#rejected > 0, key .. " was silently accepted")
    end

    -- The forms decide the font, so they must come from the bounds rather than
    -- from whichever value happens to be showing.
    assertEqual(metric.widestSample({ rangeMin = 0, rangeMax = 1200 }, 1)[1], "1200.0")
    assertEqual(metric.widestSample({ rangeMin = -50, rangeMax = 10 }, 0)[1], "-50")

    -- A metric offers exactly one form. Its unit is drawn as a separate label,
    -- so the reading is digits alone and holds no redundancy to give up;
    -- anything shorter would drop magnitude.
    assertEqual(
        #metric.widestSample({ rangeMin = 0, rangeMax = 1200 }, 1),
        1,
        "a metric offered a shorter form, which could only lose a digit"
    )
end

--- The composition table in `docs/panels/tx-battery.md` is true.
---
--- That page tells someone configuring a dashboard which spans show the bar
--- and which show the percentage, and which span drops the unit. Those are
--- the facts a layout is written against, and nothing checked them: the
--- existing coverage is of `hasRange`, `fraction` and `resolveState`, which
--- are the arithmetic rather than the composition.
---
--- Written as the documented table rather than as the rule that produces it,
--- because restating `cells >= 2` here would pass for any implementation that
--- happened to contain those words and would say nothing about what a person
--- sees.
local function testTxBatteryComposition()
    local battery = loadModule("panels/tx-battery.lua")
    local resolved = theme.build("modern-dark")

    -- span, reading font, unit shown, cell w x h, outline, percentage under
    --
    -- The cell stands upright, so it is half as wide as it is tall. That is
    -- what took the percentage out from under it at every span: `100%` needs 39
    -- pixels at the label font and the widest cell here is 25.
    --
    -- The outline column is the interesting one. `1x2` and `2x2` draw cells of
    -- exactly the same size and outline them differently, because the readings
    -- they stand beside are different sizes. A stroke derived from the span or
    -- from the cell would give those two rows the same number.
    -- **The one-row spans read at DBLSIZE, and the panel's height is why.**
    -- A reading is sized against half the panel now rather than against a
    -- middle band cut out of it: half of 65 px is 32 and DBLSIZE is 31 px of
    -- ink, so it fits. The glyph follows it, from 13 x 26 to 16 x 32, because
    -- the cell is sized against the reading it stands beside rather than
    -- against the span.
    --
    -- **Corrected twice, and the pair is the record.** Under the rule that
    -- gave an absent part's quarter to the body these spans read at DBLSIZE;
    -- under fixed quarter/half/quarter bands a one-row body was 29 px and they
    -- stepped down to MIDSIZE, which the user accepted with the figures in
    -- front of them and then disliked on a radio. Half the panel is 32 rather
    -- than 29 because a half of the panel is not a half of what the frame's
    -- insets leave, and those 3 px are the whole of the recovery.
    --
    -- **The two-row spans are unaffected in size**, which is not obvious and is
    -- worth the line: half of a 134 px panel is 67 px and XXLSIZE is 54 px of
    -- ink, so the largest reading on the dashboard still fits a half. It was
    -- the *line box* of 69 that did not, which is what the ink rule settled.
    -- Their reading still *moves*, to the panel's own centre.
    --
    -- `1 x 2` and `2 x 2` shed the `V`, which is the abbreviation rule in
    -- its documented order: an XXLSIZE `88.8` is 102 px of a 105 px box at
    -- `1 x 2` and of a 113 px half at `2 x 2`, and the unit is redundancy
    -- because the panel's own heading names what is measured. Magnitude is
    -- kept and redundancy spent, which is the trade the rule names.
    local documented = {
        { "1x1", "DBLSIZE", true, nil, nil, nil, false },
        { "2x1", "DBLSIZE", true, 16, 32, 2, false },
        { "3x1", "DBLSIZE", true, 16, 32, 2, false },
        { "4x1", "DBLSIZE", true, 16, 32, 2, false },
        { "1x2", "XXLSIZE", false, nil, nil, nil, false },
        { "2x2", "XXLSIZE", false, 25, 50, 4, false },
        { "3x2", "XXLSIZE", true, 25, 50, 4, false },
        { "4x2", "XXLSIZE", true, 25, 50, 4, false },
    }

    local GUTTER, CELLS, WIDTH, HEIGHT = 4, 4, 480, 272
    local cellWidth = math.floor((WIDTH - GUTTER * (CELLS - 1)) / CELLS)
    local cellHeight = math.floor((HEIGHT - GUTTER * (CELLS - 1)) / CELLS)

    assertEqual(#documented, #battery.supportedSpans, "the documented table and the declared spans disagree in length")

    for index, row in ipairs(documented) do
        local span, font, showUnit = row[1], row[2], row[3]
        local glyphWidth, glyphHeight = row[4], row[5]
        local border, under = row[6], row[7]
        assertEqual(
            battery.supportedSpans[index],
            span,
            "the documented table is in a different order from supportedSpans"
        )

        local cols, rows = string.match(span, "(%d)x(%d)")
        cols, rows = tonumber(cols), tonumber(rows)
        local rect = {
            x = 0,
            y = 0,
            w = cellWidth * cols + GUTTER * (cols - 1),
            h = cellHeight * rows + GUTTER * (rows - 1),
        }
        local fonts = theme.typography(cols, rows)
        local layout = battery.presentationFor(cols, rows)
        layout.visual = "battery"
        local area = battery.regionsFor(resolved, theme, primitives, rect, layout, fonts)

        assertEqual(edgetx.fontName(area.value), font, span .. " does not draw its reading at the documented size")
        assertEqual(area.showUnit, showUnit, span .. " disagrees with the documentation about showing its unit")
        assertEqual(area.glyphWidth, glyphWidth, span .. " draws a glyph of a different width from the documented one")
        assertEqual(
            area.glyphHeight,
            glyphHeight,
            span .. " draws a glyph of a different height from the documented one"
        )
        assertEqual(
            area.glyphBorder,
            border,
            span .. " outlines its cell at a different weight from the documented" .. " one"
        )
        assertEqual(
            area.detailUnderGlyph,
            under,
            span .. " disagrees with the documentation about where the percentage" .. " sits"
        )

        -- The reading and whatever rides beside it have to fit the column they
        -- actually have, which is what is left once the glyph has taken its
        -- share -- not the panel's full width. This is the assertion that would
        -- have caught the reading being fitted as `88.8` and drawn as `88.8V`.
        local carried =
            theme.readingWidth(area.value, battery.DIGITS, area.unitFont, area.showUnit and battery.UNIT or nil)
        assert(
            carried <= area.valueWidth,
            span .. " draws its reading and unit past its own column: " .. carried .. " into " .. area.valueWidth
        )

        -- And the unit really is smaller than the number it rides beside, which
        -- is the whole of what makes it a rider rather than a second reading.
        if area.showUnit then
            assert(
                theme.fontHeight(area.unitFont) < theme.fontHeight(area.value),
                span .. " draws its unit at or above the reading's own size"
            )
        end

        -- And a cell, where there is one, has to fit beside it and stand upright.
        if area.glyphWidth then
            assert(
                area.glyphX + area.glyphWidth <= area.pad + area.content,
                span .. " draws its battery past the panel edge"
            )
            assert(area.glyphX >= area.pad + area.valueWidth, span .. " draws its battery over the reading")
            assert(area.glyphHeight > area.glyphWidth, span .. " draws a battery wider than it is tall")
            local floor = area.showDetail and area.detailY or rect.h
            assert(
                area.glyphY + area.glyphHeight <= floor,
                span
                    .. " draws its battery over the row beneath it: ends at "
                    .. (area.glyphY + area.glyphHeight)
                    .. ", row at "
                    .. floor
            )
        end
    end

    -- The reading is digits and nothing else. There is no longer a form to
    -- choose between, which is what stopped `88.8` being measured and `88.8V`
    -- being drawn -- 116 pixels into a 105 pixel column, invisible below 10 V
    -- because `7.9V` happens to fit where `10.0V` does not.
    assertEqual(battery.reading(7.9), "7.9")
    assertEqual(battery.reading(10.0), "10.0")
    assertEqual(battery.reading(nil), "--")

    assertEqual(
        battery.reading(88.8),
        battery.DIGITS,
        "the widest number the fitter is asked about is not the widest it prints"
    )

    -- The cell's column ends where the percentage begins, at every height a
    -- reflow can produce rather than only at the eight the grid can.
    --
    -- This is worth sweeping rather than sampling: at the spans a 4 x 4 grid
    -- makes, the cell's own height cap binds before the room does, so the panel
    -- sizes a layout can ask for never exercise the floor at all. A zone in App
    -- mode is whatever the screen leaves, and a short two-row panel is where a
    -- cell would grow down through the row beneath it.
    local swept = 0
    for height = 70, 200, 2 do
        for _, width in ipairs({ 117, 238, 480 }) do
            local rect = { x = 0, y = 0, w = width, h = height }
            -- `showPercent` true, because the row only exists when a layout asks
            -- for it: without that this sweep builds panels with no supporting
            -- row, finds nothing to clear, and passes while checking nothing.
            local layout = battery.presentationFor(width > 200 and 2 or 1, 2, true)
            layout.visual = "battery"
            local area = battery.regionsFor(
                resolved,
                theme,
                primitives,
                rect,
                layout,
                theme.typography(width > 200 and 2 or 1, 2)
            )
            if area.glyphHeight and area.showDetail then
                swept = swept + 1
                assert(
                    area.glyphY + area.glyphHeight <= area.detailY,
                    "a "
                        .. width
                        .. " by "
                        .. height
                        .. " panel stands its battery "
                        .. (area.glyphY + area.glyphHeight - area.detailY)
                        .. " pixels into the row beneath it"
                )
            end
        end
    end
    assert(swept >= 50, "only " .. swept .. " panels in the sweep both drew a battery and showed a percentage")
end

--- Identity presentation, and the file check that stands in for a decode the
--- LVGL image object never reports back to Lua.
local function testIdentityPresentation()
    local identity = loadModule("panels/model-identity.lua")

    assertEqual(identity.presentationFor({ presentation = "name" }, 4, 4).showImage, false)
    assertEqual(identity.presentationFor({ presentation = "image" }, 1, 1).showName, false)
    assertEqual(identity.presentationFor({ presentation = "both" }, 1, 1).showImage, true)
    -- `auto` spends space on a picture only when there is space to spend.
    assertEqual(identity.presentationFor({ presentation = "auto" }, 1, 1).showImage, false)
    assertEqual(identity.presentationFor({ presentation = "auto" }, 2, 2).showImage, true)

    local exists, checked = identity.fileExists("")
    assertEqual(exists, false)
    assertEqual(checked, true, "an empty path is answered without the filesystem")

    local previous = fstat
    fstat = nil
    local _, unchecked = identity.fileExists("/IMAGES/plane.png")
    assertEqual(unchecked, false, "without fstat nothing can be proven, so the fallback must stay")

    -- A firmware whose fstat raises must not take the panel with it.
    fstat = function()
        error("no filesystem")
    end
    assertEqual(identity.fileExists("/IMAGES/plane.png"), false)

    fstat = function(path)
        return path == "/IMAGES/plane.png" and { size = 10 } or nil
    end
    assertEqual(identity.fileExists("/IMAGES/plane.png"), true)
    assertEqual(identity.fileExists("/IMAGES/gone.png"), false)
    fstat = previous

    -- The image is created after the text and painted with `fill`, so anything
    -- it is allowed to overlap simply disappears. Every row that will be drawn
    -- has to come out of the height the image is given.
    local resolved = theme.build("modern-dark")
    local sizes = { { 234, 130 }, { 472, 264 }, { 117, 130 }, { 117, 60 } }
    local cases = {
        { showName = true, showImage = true, showLabels = true },
        { showName = false, showImage = true, showLabels = true },
        { showName = true, showImage = true, showLabels = false },
        { showName = false, showImage = true, showLabels = false },
    }

    for _, layout in ipairs(cases) do
        for _, size in ipairs(sizes) do
            local width, height = size[1], size[2]
            local area = identity.regionsFor(
                resolved,
                theme,
                { x = 0, y = 0, w = width, h = height },
                layout,
                theme.typography(2, 2)
            )
            local where = width .. "x" .. height

            if area.showImage then
                local bottom = area.imageY + area.imageHeight
                assert(bottom <= height, where .. ": the image ran past the panel")
                if area.showName then
                    assert(
                        bottom <= area.nameY,
                        where
                            .. ": the image covered the model name, image ends at "
                            .. bottom
                            .. ", name starts at "
                            .. area.nameY
                    )
                end
                if area.showLabels then
                    assert(
                        bottom <= area.labelsY,
                        where
                            .. ": the image covered the labels row, image ends at "
                            .. bottom
                            .. ", labels start at "
                            .. area.labelsY
                    )
                end
            end
        end
    end
end

--- The link view is the only thing that can tell a dead link from a protocol
--- that never populates an RSSI sensor, so it has to say both.
local function testTelemetryLinkView()
    local harness = telemetryHarness()
    local service = harness.service
    local link = service:link()
    local pack = service:subscribe("RxBt")

    -- Subscribing to the link is itself a reason to run the service.
    assert(service.count >= 2, "the link subscription was not counted")

    service:update(0)
    assertEqual(link.live, true)
    assertEqual(link.rssi, 80)
    assertEqual(link.indicator, true)

    harness.rssi = 0
    harness.values[100] = 0
    service:update(1)
    assertEqual(link.live, false, "a dead link was reported as live")
    assertEqual(link.indicator, true)
    assertEqual(pack.state, "stale")

    -- A protocol with no RSSI sensor: values keep arriving while getRSSI reads
    -- zero. The indicator is wrong, and the service must say so rather than
    -- pinning every reading stale.
    local other = telemetryHarness()
    local otherLink = other.service:link()
    local reading = other.service:subscribe("RxBt")
    other.rssi = 0
    other.service:update(0)
    assertEqual(reading.value, 24.4, "a live reading was discarded as stale")
    assertEqual(otherLink.live, true, "the link view still trusted an indicator a reading had disproved")
    assertEqual(otherLink.indicator, false, "a broken indicator was not reported")
    assertEqual(otherLink.rssi, 0)

    -- The view is immutable like every other snapshot.
    local ok = pcall(function()
        otherLink.live = false
    end)
    assertEqual(ok, false, "the link view accepted a write")
end

--- A compass is north-up and says nothing when there is nothing to say.
local function testCompassGeometry()
    -- LVGL measures zero at three o'clock; a compass measures zero at twelve.
    assertEqual(primitives.arcAngle(0), 270)
    assertEqual(primitives.arcAngle(90), 0)
    assertEqual(primitives.arcAngle(180), 90)
    assertEqual(primitives.arcAngle(270), 180)
    assertEqual(primitives.arcAngle(359.6), 270)

    local compass = {
        centreX = 50,
        centreY = 50,
        radius = 30,
        pointers = {
            {
                set = function(self, changes)
                    self.last = changes
                end,
            },
        },
    }
    local previousLvgl = lvgl
    lvgl = {
        hide = function(object)
            object.hidden = true
        end,
        show = function(object)
            object.hidden = false
        end,
    }
    primitives.setCompass(compass, 90)
    assertEqual(compass.bearing, 90)
    compass.pointerRadius = 12
    primitives.setCompass(compass, 90)
    assertEqual(compass.pointers[1].last.pts[1][1], 62)
    assertEqual(compass.pointers[1].last.pts[1][2], 50)
    assertEqual(compass.pointers[1].hidden, false)
    for bearing = 0, 359 do
        local triangles = primitives.compassPoints(compass, bearing)
        for _, points in ipairs(triangles) do
            for _, point in ipairs(points) do
                assert((point[1] - 50) ^ 2 + (point[2] - 50) ^ 2 <= 13 ^ 2)
            end
        end
    end

    -- A withheld bearing hides the pointer rather than resting it at north,
    -- which would read as a valid due-north fix.
    primitives.setCompass(compass, nil)
    assertEqual(compass.bearing, nil)
    assertEqual(compass.pointers[1].hidden, true)
    primitives.setCompass(compass, 0 / 0)
    assertEqual(compass.pointers[1].hidden, true)
    lvgl = previousLvgl
end

--- The square an arc of a given centre and radius covers.
---
--- `radius` is the arc's *outer* edge: `lv_draw_arc.c` sets `rout = radius`
--- and `rin = radius - w`, so the stroke is drawn inside it and a thickness
--- adds nothing to the box. The widget used to carry a `primitives.arcBounds`
--- that added half the thickness, which was both wrong and called by nothing
--- but tests. It is a test's own arithmetic over a planned region, so it
--- lives here; where there is a real object, measure the object instead.
local function arcSquare(centreX, centreY, radius)
    return {
        x = centreX - radius,
        y = centreY - radius,
        w = radius * 2,
        h = radius * 2,
    }
end

--- A dial that cannot be read is not worth the pixels, so it is dropped
--- before the dominant reading is shrunk.
local function testNavigationRegions()
    local navigation = loadModule("panels/navigation.lua")
    local resolved = theme.build("modern-dark")
    local fonts = theme.typography(2, 2)
    local layout = navigation.presentationFor("detailed")

    local large = navigation.regionsFor(
        resolved,
        theme,
        { x = 0, y = 0, w = 238, h = 134 },
        layout,
        fonts,
        { digits = "888.88", unit = "km" }
    )
    -- **The compass is shed at this span, and that is the magnitude rule.**
    -- The band chooses by ink now, so a 62 px band holds XXLSIZE rather than
    -- DBLSIZE, and a distance drawn 29 px taller is wide enough that no pair
    -- of slots separates it from the dial. The reading keeps its size and the
    -- shape goes, which is the order the specification states and the user
    -- chose on the radio. `2 x 2` is where it bites: at `3 x 2` and wider
    -- there is room for both.
    assertEqual(large.showCompass, false, "a 2 x 2 panel kept its compass beside an XXLSIZE distance")
    -- **And the coordinates go too, because the quarter will not hold them.**
    -- This panel draws two supporting rows and they are the only two-row
    -- footer in the catalogue: 32 px of ink against a tertiary quarter of 31.
    -- The band used to grow to fit them, which is what the fixed-bands rule
    -- removed, so the second row is now granted by the band that has to hold
    -- it rather than by the body band above it. A three-row span keeps both --
    -- asserted below, so this is a threshold rather than a disappearance.
    assertEqual(large.showCoordinates, true, "compact footer must retain coordinates at 2 x 2")
    assertEqual(large.showDetail, true, "the bearing row went with the coordinates, which is not the rule")

    local tall = navigation.regionsFor(
        resolved,
        theme,
        { x = 0, y = 0, w = 238, h = 203 },
        navigation.presentationFor("detailed"),
        theme.typography(2, 3),
        { digits = "888.88", unit = "km" }
    )
    assertEqual(tall.showCoordinates, true, "a 2 x 3 panel has a 48 px quarter and still drew one row")

    local wide = navigation.regionsFor(
        resolved,
        theme,
        { x = 0, y = 0, w = 359, h = 134 },
        layout,
        fonts,
        { digits = "888.88", unit = "km" }
    )
    assertEqual(wide.showCompass, true, "a 3 x 2 panel has room for both and drew no compass")
    -- The dial sits inside its own panel, measured from its centre.
    local box = arcSquare(wide.centreX, wide.centreY, wide.radius)
    assert(box.x >= 0 and box.y >= 0, "the dial was placed off the panel")
    assert(box.x + box.w <= 359, "the dial overflowed the panel")
    assert(box.y + box.h <= 134, "the dial overflowed the panel")
    -- And never over the reading beside it. Measured on the panel that draws
    -- both, which is no longer the one above.
    assert(wide.pad + wide.valueWidth <= box.x, "the dial overlaps the value")

    -- A panel that cannot afford everything sheds the coordinates first and the
    -- dial next, and never the distance.
    local short = navigation.regionsFor(
        resolved,
        theme,
        { x = 0, y = 0, w = 238, h = 62 },
        layout,
        fonts,
        { digits = "888.88", unit = "km" }
    )
    assertEqual(short.showCoordinates, false)

    local tiny = navigation.regionsFor(
        resolved,
        theme,
        { x = 0, y = 0, w = 58, h = 40 },
        layout,
        fonts,
        { digits = "888.88", unit = "km" }
    )
    assertEqual(tiny.showCompass, false, "an unreadable dial was kept")
    assertEqual(tiny.radius, 0)
    -- The *room*, not the drawn box. A panel this small cannot hold `888.88km`
    -- at any font on the ladder, so the box it draws in is wider than the
    -- panel and clamping happens downstream; what this pins is that shedding
    -- the dial handed the whole content box back to the reading rather than
    -- leaving it with the half it would have had beside one.
    assertEqual(tiny.valueBudget, tiny.content, "the reading did not reclaim the room")
end

--- Every region of the three telemetry panels, at every span they claim,
--- must clear every other region. Two rows resolved onto the same line draw
--- over each other on the radio and look like one unreadable smear, and
--- nothing about the resolved numbers says so unless it is asserted.
local function testTelemetryContentFitsPanel()
    local cellBattery = loadModule("panels/cell-battery.lua")
    local linkStatus = loadModule("panels/link-status.lua")
    local navigationPanel = loadModule("panels/navigation.lua")
    local resolved = theme.build("modern-dark")
    local heightOf = theme.fontHeight

    -- Panel sizes for spans at 480 x 272 with 4 px gutters, plus tight cases.
    local cases = {
        { name = "2x2", w = 238, h = 134, colSpan = 2, rowSpan = 2 },
        { name = "2x1", w = 238, h = 65, colSpan = 2, rowSpan = 1 },
        { name = "1x1", w = 117, h = 65, colSpan = 1, rowSpan = 1 },
        { name = "shrunk", w = 158, h = 68, colSpan = 2, rowSpan = 2 },
        -- Smaller than any span the grid can produce: a single cell is 117 by
        -- 65. Kept as a stress case, and marked so the assertions can ask it the
        -- question it can actually answer.
        { name = "tiny", w = 60, h = 40, colSpan = 1, rowSpan = 1, synthetic = true },
    }

    for _, case in ipairs(cases) do
        local rect = { x = 0, y = 0, w = case.w, h = case.h }
        local fonts = theme.typography(case.colSpan, case.rowSpan)
        local labelHeight = heightOf(fonts.label)
        -- What a supporting row actually marks. A row's line box carries a
        -- descent and a leading below its baseline, and the strings these rows
        -- print -- a bearing, a caption, a pair of coordinates -- reach none of
        -- it. Containment against the panel's own edge is a question about
        -- glyphs, so it is asked of the ink; whether a *descending* string
        -- would still clear is `testReadingsDoNotDescendOverAnything`.
        local labelInk = theme.fontAscent(fonts.label)

        --- Shared assertions: the reading fits its own region in both axes, and
        --- clears the header above it and whatever row sits below it.
        --- @param reading table `digits`, and `unit` where the panel has one.
        local function assertReading(what, area, valueFont, valueWidth, reading)
            -- The drawn extent, which is the ink. A reading is centred by its ink
            -- now, so its line box hangs below the glyphs by the font's descent
            -- and leading; measuring the box would report a reading sitting on a
            -- supporting row that no glyph comes near. See
            -- `testReadingsDoNotDescendOverAnything` for why that is safe here and
            -- what would make it unsafe.
            local bottom = area.valueY + theme.fontAscent(valueFont)
            assert(
                bottom <= case.h,
                what .. " " .. case.name .. ": the reading overflows the panel, ends at " .. bottom
            )
            -- **Against the header this panel draws.** The 60 x 40 stress case is
            -- too narrow to keep a heading and drops it, so asking for clearance
            -- from a label row there holds the reading off an object nothing
            -- draws -- and a panel with no heading is exactly the panel allowed to
            -- use its whole height. Same correction as `testContentFitsPanel`, in
            -- the second place that had made it.
            local header = area.frame and area.frame.labelHidden and 0 or labelHeight
            assert(area.valueY >= header, what .. " " .. case.name .. ": the reading overlaps the header")
            assert(
                area.pad + valueWidth <= case.w,
                what .. " " .. case.name .. ": the reading runs past the right edge"
            )

            -- Width matters as much as height, and the width that matters is the
            -- number **and whatever rides beside it**. Measuring the digits alone
            -- would pass a panel whose unit hangs over the edge, which is the whole
            -- of what an inline unit can get wrong.
            local carried =
                theme.readingWidth(valueFont, reading.digits, area.unitFont, area.showUnit and reading.unit or nil)
            -- **The reading fits, or the panel had nothing left to spend.**
            -- The 60 x 40 stress case used to be excused from this outright, on
            -- the grounds that a panel narrower than any the grid builds cannot
            -- fit the widest reading -- and the excuse asserted that the font had
            -- bottomed out. It had, but only because the vertical room had
            -- bottomed out first: a 17 px middle band left SMLSIZE and nothing
            -- else, whatever the width was. A panel with no heading and no row
            -- sizes against its whole height now, so the fitter starts at DBLSIZE
            -- and steps down on width alone -- and `cell-battery` fits at MIDSIZE
            -- where the old check demanded SMLSIZE.
            --
            -- So the excuse is gone and the real property is asked of every case.
            -- `navigation` is the one that still cannot fit: its unit carries the
            -- scale and may never be dropped, so `1.23km` is 54 px of a 48 px box
            -- however small the font gets. That is a refusal to clip rather than a
            -- fit, and what it has to prove is that nothing smaller was left.
            if carried > valueWidth then
                assertEqual(
                    valueFont,
                    theme.READING_FONTS[#theme.READING_FONTS],
                    what
                        .. " "
                        .. case.name
                        .. ": the reading and its unit clip at "
                        .. carried
                        .. " in "
                        .. valueWidth
                        .. ", and a smaller font was still available"
                )
            end

            -- A unit that is not smaller than its number is a second reading.
            if area.showUnit then
                assert(
                    heightOf(area.unitFont) < heightOf(valueFont),
                    what .. " " .. case.name .. ": the unit is drawn at or above the reading's own size"
                )
            end

            if area.showDetail then
                assert(
                    bottom <= area.detailY,
                    what .. " " .. case.name .. ": the reading overlaps the supporting row below it"
                )
            end
        end

        --- A two-column supporting row: neither half may touch the other.
        local function assertColumns(what, area, leftWidth, rightX, rightWidth)
            assert(area.pad + leftWidth <= rightX, what .. " " .. case.name .. ": supporting columns overlap")
            assert(
                rightX + rightWidth <= case.w,
                what .. " " .. case.name .. ": a supporting column runs past the right edge"
            )
        end

        local cellLayout = cellBattery.presentationFor(case.colSpan, case.rowSpan)
        cellLayout.visual = "bar"
        local cells = cellBattery.regionsFor(resolved, theme, rect, cellLayout, fonts, { digits = "4.44", unit = "V" })
        assertReading("cell-battery", cells, cells.value, cells.content, { digits = "4.44", unit = "V" })
        if cells.showDetail then
            assert(
                cells.detailY + labelHeight <= cells.barY,
                "cell-battery " .. case.name .. ": the detail row overlaps the bar"
            )
            assertColumns("cell-battery", cells, cells.detailWidth, cells.rowRightX, cells.detailWidth)
        end
        if cells.showVisual then
            assert(
                cells.barY + resolved.spacing.barHeight <= case.h,
                "cell-battery " .. case.name .. ": the bar overflows the panel"
            )
        end

        local linkLayout = linkStatus.presentationFor(case.colSpan, case.rowSpan)
        linkLayout.visual = "bar"
        local link = linkStatus.regionsFor(resolved, theme, rect, linkLayout, fonts, { digits = "-100", unit = "dBm" })
        assertReading("link-status", link, link.value, link.content, { digits = "-100", unit = "dBm" })
        if link.showDetail then
            assert(
                link.detailY + labelHeight <= link.barY,
                "link-status " .. case.name .. ": the detail row overlaps the bar"
            )
            assertColumns("link-status", link, link.detailWidth, link.rowRightX, link.rowRightWidth)
        end

        for _, presentation in ipairs({ "distance", "bearing", "compass", "detailed" }) do
            local navLayout = navigationPanel.presentationFor(presentation)
            local nav =
                navigationPanel.regionsFor(resolved, theme, rect, navLayout, fonts, { digits = "888.88", unit = "km" })
            local what = "navigation/" .. presentation
            -- The room, as `cell-battery` and `link-status` pass their `content`
            -- above. This asked for `valueWidth` while that field meant both the
            -- room and the drawn box, and kept asking for it after they were
            -- separated -- which is the same name meaning two things, the defect
            -- that separating them was meant to end.
            assertReading(
                what,
                nav,
                nav.value,
                nav.valueBudget,
                { digits = navigationPanel.DIGITS, unit = navigationPanel.UNIT }
            )

            if nav.showDetail then
                assert(
                    nav.detailY + labelInk <= case.h,
                    what .. " " .. case.name .. ": the bearing row overflows the panel"
                )
                assertColumns(what, nav, nav.detailWidth, nav.originX, nav.originWidth)
            end
            if nav.showCoordinates then
                -- The coordinates sit below the bearing row, not on top of it.
                assert(
                    nav.detailY + theme.fontHeight(nav.rowFont) <= nav.coordinatesY,
                    what .. " " .. case.name .. ": the coordinates row overlaps the bearing row"
                )
                assert(
                    nav.coordinatesY + theme.fontAscent(nav.rowFont) <= case.h,
                    what .. " " .. case.name .. ": the coordinates row overflows the panel"
                )
            end
            if nav.showCompass then
                local box = arcSquare(nav.centreX, nav.centreY, nav.radius)
                assert(box.x >= 0 and box.y >= 0, what .. " " .. case.name .. ": the dial was placed off the panel")
                assert(
                    box.x + box.w <= case.w and box.y + box.h <= case.h,
                    what .. " " .. case.name .. ": the dial overflows the panel"
                )
                assert(nav.pad + nav.valueWidth <= box.x, what .. " " .. case.name .. ": the dial overlaps the reading")

                -- **And the dial clears the rows beneath it.** This is the one the
                -- catalogue had no check for: a dial is not a label, so the
                -- integration suite's collision check sees it, but no shipped layout
                -- draws this panel with two supporting rows *and* a compass, so
                -- nothing exercised the pair. The dial used to be sized against
                -- whatever vertical room was left and stand from the content top
                -- downward, which put it 44 by 2 pixels through the row below at
                -- `2 x 2` and `4 x 2`.
                if nav.showDetail then
                    assert(
                        box.y + box.h <= nav.detailY,
                        what
                            .. " "
                            .. case.name
                            .. ": the dial runs "
                            .. (box.y + box.h - nav.detailY)
                            .. " px into the supporting row beneath it"
                    )
                end
            end
        end
    end

    -- Shedding exists to protect the dominant reading, not merely to avoid an
    -- overlap. A 2 x 1 panel could fit its supporting row and a small value at
    -- the same time; the specification says to drop the row instead, so the
    -- reading a pilot glances at stays large.
    local squeezed = { x = 0, y = 0, w = 238, h = 65 }
    local wideFonts = theme.typography(2, 1)

    local cellLayout = cellBattery.presentationFor(2, 1)
    cellLayout.visual = "bar"
    local shedCells =
        cellBattery.regionsFor(resolved, theme, squeezed, cellLayout, wideFonts, { digits = "4.44", unit = "V" })
    assertEqual(shedCells.showDetail, false, "cell-battery kept a supporting row a short panel could not afford")
    assert(
        heightOf(shedCells.value) >= heightOf(MIDSIZE),
        "cell-battery shed a row without buying its reading any size"
    )

    local linkLayout = linkStatus.presentationFor(2, 1)
    linkLayout.visual = "bar"
    local shedLink =
        linkStatus.regionsFor(resolved, theme, squeezed, linkLayout, wideFonts, { digits = "-100", unit = "dBm" })
    assertEqual(shedLink.showDetail, false, "link-status kept a supporting row a short panel could not afford")
    assert(heightOf(shedLink.value) >= heightOf(MIDSIZE), "link-status shed a row without buying its reading any size")

    local shedNav = navigationPanel.regionsFor(
        resolved,
        theme,
        squeezed,
        navigationPanel.presentationFor("detailed"),
        wideFonts,
        { digits = navigationPanel.DIGITS, unit = navigationPanel.UNIT }
    )
    assertEqual(shedNav.showCoordinates, false, "navigation kept a coordinates row a short panel could not afford")
    assert(heightOf(shedNav.value) >= heightOf(MIDSIZE), "navigation shed a row without buying its reading any size")
end

testOriginCaptionFits()
testRefreshScheduling()
testMetricDirection()
testContentFitsPanel()
testFontHeightsMatchTheFirmware()
testWidthIsMeasuredNotEstimated()
testSlotsForAnswersForBothEdges()
testFitReadingReportsWhetherItFits()
testUnitSitsOnTheBaseline()
testTextFitting()
testBatteryStrokeScalesWithFont()
testBatteryStaysVisible()
testClockNeverOutgrowsItsForm()
testLosslessReadingsOfferOneForm()
testRedrawDecision()
testReadingsSitInTheirBand()
testHeadingIsPinnedToTheTop()
testSharedLadder()
testReadingForms()
testLabelFitting()
testBipolarGeometry()
testMetricDefaults()
testTxBatteryComposition()
testIdentityPresentation()
testTelemetryLinkView()
testCompassGeometry()
testNavigationRegions()
testTelemetryContentFitsPanel()
