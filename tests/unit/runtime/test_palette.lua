-- SPDX-License-Identifier: GPL-2.0-only

local root = ... or "."
local fixture = assert(loadfile(root .. "/tests/support/runtime_fixture.lua"))(root)
local edgetx = fixture.edgetx
local firmware = fixture.firmware
local toRgb565 = fixture.toRgb565
local toLcdFlags = fixture.toLcdFlags
local grid = fixture.grid
local yaml = fixture.yaml
local layout = fixture.layout
local panelHost = fixture.panelHost
local theme = fixture.theme
local buildCustomTheme = fixture.buildCustomTheme
local primitives = fixture.primitives
local assertEqual = fixture.assertEqual
local assertFont = fixture.assertFont

local function testColorConversion()
    local function toRgb565(rgb)
        local red = math.floor(rgb / 65536) % 256
        local green = math.floor(rgb / 256) % 256
        local blue = rgb % 256
        return math.floor(red * 31 / 255) * 2048 + math.floor(green * 63 / 255) * 32 + math.floor(blue * 31 / 255)
    end

    assertEqual(theme.fromRgb565(toRgb565(0x000000)), 0x000000)
    assertEqual(theme.fromRgb565(toRgb565(0xFFFFFF)), 0xFFFFFF)

    -- Widening is lossy, so require closeness rather than equality.
    local widened = theme.fromRgb565(toRgb565(0x70D6F3))
    local red = math.floor(widened / 65536) % 256
    assert(math.abs(red - 0x70) <= 8, "red channel drifted: " .. red)

    assertEqual(math.floor(theme.contrast(0x000000, 0xFFFFFF) + 0.5), 21)
    assertEqual(theme.contrast(0x123456, 0x123456), 1)
    assertEqual(theme.shade(0x000000, 1), 0xFFFFFF)
    assertEqual(theme.shade(0xFFFFFF, -1), 0x000000)
end

--- Modern mode must reproduce the palette defined in the specification.
local function testModernTheme()
    local resolved = theme.build("modern-dark")

    assertEqual(resolved.mode, "modern-dark")
    assertEqual(#resolved.warnings, 0)
    assertEqual(#resolved.notices, 0)
    assertEqual(resolved.rgb.canvas, 0x0A0C0E)
    assertEqual(resolved.rgb.critical, 0xF05252)
    -- The palette is held twice and the two forms are not interchangeable: rgb
    -- is the 24-bit token contrast arithmetic runs on, color is what a radio
    -- is given to draw with. Asserting they are equal, as this did, asserted
    -- the one thing about them that is false on hardware.
    assertEqual(resolved.color.canvas, toLcdFlags(0x0A0C0E))
    assertEqual(resolved.spacing.gutter, 4)

    -- Panels carry no resting outline, so the fill against the screen is the
    -- only thing separating one panel from the next, and the separation is a
    -- number rather than a matter of taste. The pairing this replaced measured
    -- 1.122, which read as one flat field with faint boxes on it.
    local elevation = theme.contrast(resolved.rgb.canvas, resolved.rgb.surface)
    assert(elevation >= 1.30, string.format("panels are not elevated above the screen: %.3f", elevation))
    assert(
        theme.contrast(resolved.rgb.surface, resolved.rgb.surfaceRaised) >= 1.20,
        "a raised surface is not separated from the panel it sits on"
    )
    -- Lifting the panel spends contrast every token measured against it has to
    -- give up, and the track is the one with the least to spare.
    assert(theme.contrast(resolved.rgb.surface, resolved.rgb.track) >= 2.0, "the track vanished into a lifted surface")

    -- The corner radius is pinned as a number on purpose. Everything that draws
    -- a corner reads it from here, so a test comparing a drawn corner against
    -- this token agrees with any value at all, including the 4 px the design
    -- was rejected for. Eight is the design, and this is where it is stated.
    assertEqual(resolved.spacing.radius, 8)
    -- Content clears the accent stripe rather than starting at its right edge.
    assert(
        resolved.spacing.paddingTight >= resolved.spacing.accentWidth + resolved.spacing.accentGap,
        "a short panel's padding leaves content against the accent stripe"
    )

    -- An unknown mode degrades to Modern and says so.
    local fallback = theme.build("neon")
    assertEqual(fallback.mode, "modern-dark")
    assert(string.match(fallback.warnings[1], "unknown theme"), fallback.warnings[1])

    -- No mode at all is Modern without complaint.
    assertEqual(theme.build().mode, "modern-dark")

    -- **And an empty one is Modern without complaint too, which is not the
    -- same statement.** A Lua widget receives a string option it has never
    -- been given as `""` rather than as nil: the default is
    -- `stringValue.clear()` and it is pushed with `lua_pushstring`, so the
    -- firmware cannot express the difference. Warning about it painted the
    -- diagnostic banner across the dashboard of every first run, which is the
    -- one configuration nobody tests because it is the one nobody chooses.
    --
    -- Whitespace is the same case reached a different way: a name typed and
    -- cleared can leave a space, and the user cannot see it.
    for _, blank in ipairs({ "", " ", "   " }) do
        local unset = theme.build(blank)
        assertEqual(
            unset.mode,
            "modern-dark",
            string.format("a blank theme option %q did not fall back to Modern", blank)
        )
        assertEqual(
            #unset.warnings,
            0,
            string.format(
                "a blank theme option %q warned, which is the banner every user who"
                    .. " adds this widget and does not open its settings would see: %s",
                blank,
                unset.warnings[1] or ""
            )
        )
    end

    -- The warning still earns its keep on a mode that is genuinely a name and
    -- genuinely not ours -- a typo, or a mode we removed. Asserted beside the
    -- blank cases so that silencing the warning altogether fails here.
    assertEqual(
        #theme.build("nonsense").warnings,
        1,
        "a real unknown mode stopped warning, so the blank case was fixed by"
            .. " removing the warning rather than by narrowing it"
    )
end

--- A retired theme name is rejected rather than silently deriving radio colors.
local function testRetiredTheme()
    local resolved = theme.build("edgetx")
    assertEqual(resolved.mode, "modern-dark")
    assertEqual(#resolved.warnings, 1)
    assertEqual(resolved.warnings[1], "unknown theme edgetx")
end

--- Full named palettes receive the same contrast protection as all themes.
local function testCustomTheme()
    local resolved = buildCustomTheme({
        canvas = 0x000000,
        surface = 0x141414,
        accent = "green",
    })

    assertEqual(resolved.rgb.canvas, 0x000000)
    assert(
        theme.contrast(resolved.rgb.canvas, resolved.rgb.surface) >= 1.30,
        "a named theme surface was left flat against its own canvas"
    )
    local lifted = {}
    for index, notice in ipairs(resolved.notices) do
        lifted[index] = notice.text
    end
    assert(
        string.match(table.concat(lifted, "\n"), "lifted to elevate"),
        "the host adapted the named palette without saying so"
    )
    assertEqual(resolved.accent, "green")
    assertEqual(resolved.rgb.border, theme.modernDark().border)
    assertEqual(#resolved.warnings, 0)
    assertEqual(resolved.rgb.text, theme.modernDark().text)

    local light = buildCustomTheme({ surface = 0xFFFFFF })
    assert(theme.contrast(light.rgb.surface, light.rgb.text) >= 4.5, "custom light surface left text unreadable")
end

--- Typography must grow with the panel's span.
local function testTypography()
    assertFont(theme.typography(1, 1).primary, MIDSIZE)
    assertFont(theme.typography(2, 1).primary, DBLSIZE)
    assertFont(theme.typography(1, 2).primary, DBLSIZE)
    assertFont(theme.typography(2, 2).primary, XXLSIZE)
    assertFont(theme.typography(2, 2).unit, MIDSIZE)
    assertFont(theme.typography(1, 1).unit, SMLSIZE)
    assertFont(theme.typography(1, 1).label, SMLSIZE)
end

--- Every state must be distinguishable by more than color alone.
---
--- A presentation carries display values, because a panel hands them
--- straight to an LVGL object. They are compared against `lcd.RGB(token)`
--- rather than against the token, which is the difference between asserting
--- what the radio is given and asserting a mock's identity function.
local function testStates()
    local resolved = theme.build("modern-dark")
    local modern = theme.modernDark()

    local normal = theme.state(resolved, "normal", "green")
    assertEqual(normal.accent, lcd.RGB(modern.green))
    assertEqual(normal.badge, nil)
    assertEqual(normal.value, lcd.RGB(modern.text))

    -- Warning and freshness states override a decorative accent.
    assertEqual(theme.state(resolved, "warning", "green").accent, lcd.RGB(modern.amber))
    assertEqual(theme.state(resolved, "critical", "green").accent, lcd.RGB(modern.critical))
    assertEqual(theme.state(resolved, "stale", "green").value, lcd.RGB(modern.textMuted))
    assertEqual(theme.state(resolved, "unavailable", "green").value, lcd.RGB(modern.textFaint))

    -- Each non-normal state carries a text badge, and which words it uses is
    -- the contract: the badge is what makes a state legible to a colourblind
    -- pilot, so asserting only that it is non-empty asserts nothing a typo
    -- could not satisfy.
    -- Pinned as literals rather than read from theme.BADGES, because a test
    -- taking its expectations from the table it is checking would agree with any
    -- vocabulary at all, including one nobody meant to ship.
    local badges = {
        stale = "STALE",
        warning = "WARN",
        critical = "CRIT",
        unavailable = "N/A",
        editing = "EDIT",
    }
    for name, text in pairs(badges) do
        assertEqual(theme.state(resolved, name).badge, text, name .. " does not carry its own badge")
    end
    assertEqual(theme.state(resolved, "normal").badge, nil, "a healthy panel must not be badged")

    -- Two kinds of thing, said by two different means. The fill is a condition
    -- of the data; the outline is where the interaction is. Nothing says both.
    local focus = resolved.spacing.borderFocus
    for _, name in ipairs({ "normal", "stale", "unavailable", "warning", "critical" }) do
        assertEqual(
            theme.state(resolved, name).borderWidth,
            0,
            name .. " drew an outline, which now means focus rather than state"
        )
    end
    for _, name in ipairs({ "selected", "editing" }) do
        assertEqual(
            theme.state(resolved, name).borderWidth,
            focus,
            name .. " did not draw its outline at the focus weight"
        )
    end

    -- An alarm tints the panel's field instead. Area is seen in peripheral
    -- vision where a line is not, which is the whole reason for the change.
    assertEqual(theme.state(resolved, "normal").surface, nil, "a resting panel asked for a tint")
    assertEqual(theme.state(resolved, "stale").surface, nil, "stale data tinted the panel; absent data is not an alarm")
    assertEqual(
        theme.state(resolved, "unavailable").surface,
        nil,
        "a missing source tinted the panel; absent data is not an alarm"
    )
    assertEqual(
        theme.state(resolved, "warning").surface,
        lcd.RGB(resolved.alertRgb.warning),
        "a warning did not tint its panel"
    )
    assertEqual(
        theme.state(resolved, "critical").surface,
        lcd.RGB(resolved.alertRgb.critical),
        "a critical reading did not tint its panel"
    )
    assert(resolved.alertRgb.warning ~= resolved.alertRgb.critical, "warning and critical tint a panel the same colour")

    -- The whole vocabulary has to fit the column reserved for it, at every span
    -- the typography produces. This is the check the column's width is derived
    -- to satisfy, and it is driven over the table rather than a list so a badge
    -- added later is covered by it whether or not anyone remembers.
    for _, span in ipairs({ { 1, 1 }, { 2, 1 }, { 2, 2 }, { 4, 4 } }) do
        local fonts = theme.typography(span[1], span[2])
        local column = theme.badgeWidth(fonts.badge)
        for name, text in pairs(theme.BADGES) do
            local needed = theme.textWidth(fonts.badge, text)
            assert(
                needed <= column,
                string.format(
                    "%s does not fit the badge column at %dx%d: %s needs %d of %d",
                    name,
                    span[1],
                    span[2],
                    text,
                    needed,
                    column
                )
            )
        end
    end

    -- The column is exactly what the vocabulary needs, with no slack. Asserting
    -- only that every badge fits is satisfied by any column at least that wide,
    -- including the fixed 56 this replaced, and the slack is taken out of the
    -- header label on every panel of the dashboard.
    local fonts = theme.typography(1, 1)
    local widest = 0
    for _, text in pairs(theme.BADGES) do
        local width = theme.textWidth(fonts.badge, text)
        if width > widest then
            widest = width
        end
    end
    assertEqual(
        theme.badgeWidth(fonts.badge),
        widest,
        "the badge column is not the width its vocabulary actually needs"
    )

    -- On a panel with room, the badge gets that width whole. It used to be
    -- clamped to half the content, which protected the label by clipping the
    -- badge: CRIT and CRI are not equally alarming, while a shortened source
    -- name is merely less informative.
    local narrow = theme.frame(resolved, { x = 0, y = 0, w = 117, h = 65 }, fonts)
    assertEqual(narrow.badgeWidth, widest, "a single-cell panel squeezed its badge instead of its label")

    -- And the label keeps what is left, which on a single cell is the whole
    -- argument for the trimmed vocabulary and the asymmetric padding. Pinned as
    -- a number: a bound like "at least four characters" is satisfied by the
    -- geometry this replaced.
    assertEqual(narrow.labelHidden, false, "a single-cell panel cannot show a header label beside its badge")
    assertEqual(
        narrow.labelWidth,
        117 - resolved.spacing.paddingTight - resolved.spacing.paddingRight - widest - 4,
        "a single-cell panel's header label is not the width the frame leaves it"
    )
    assert(
        narrow.labelWidth >= theme.textWidth(SMLSIZE, "CELLS"),
        string.format(
            "a single-cell panel cannot show a five-character label: %d px of a needed %d",
            narrow.labelWidth,
            theme.textWidth(SMLSIZE, "CELLS")
        )
    )

    -- The right margin is smaller than the left padding, because the left has
    -- the accent to clear and the right has nothing. Those four pixels are a
    -- character of header on a single cell.
    assert(
        resolved.spacing.paddingRight < resolved.spacing.paddingTight,
        "the header pays for symmetry it does not need"
    )
    assertEqual(narrow.content, 117 - resolved.spacing.paddingTight - resolved.spacing.paddingRight)

    -- A panel too narrow to carry both drops the label rather than clipping it,
    -- whether or not the menu button is the reason it ran out of room. This used
    -- to apply only to an obstructed corner, so an ordinary narrow panel clipped.
    local tiny = theme.frame(resolved, { x = 0, y = 0, w = 80, h = 65 }, fonts)
    assertEqual(tiny.labelHidden, true, "a panel with no room for a label drew a clipped one anyway")
    assertEqual(tiny.labelWidth, 0, "a hidden label kept a width")

    -- An unknown accent falls back to the theme default rather than failing.
    assertEqual(theme.state(resolved, "normal", "magenta").accent, lcd.RGB(modern.cyan))
    assertEqual(theme.accentColor(resolved, "amber"), lcd.RGB(modern.amber))
end

--- Fractions must be clamped so bad readings cannot draw outside a panel.
local function testPrimitiveMath()
    assertEqual(primitives.barFill(100, 0.5), 50)
    assertEqual(primitives.barFill(100, -1), 0)
    assertEqual(primitives.barFill(100, 2), 100)
    assertEqual(primitives.barFill(100, 0 / 0), 0)
    assertEqual(primitives.barFill(100, "half"), 0)

    assertEqual(primitives.arcSweep(270, 0), 0)
    assertEqual(primitives.arcSweep(270, 1), 270)
    assertEqual(primitives.arcSweep(270, 2), 270)
    assertEqual(primitives.arcSweep(270, nil), 0)

    local resolved = theme.build("modern-dark")
    assertEqual(primitives.contentWidth(resolved, 100), 100 - resolved.spacing.padding * 2)
    assertEqual(primitives.contentWidth(resolved, 4), 1, "width must never collapse")
end

--- Empty flow collections are the natural way to express "no entries".
local function testEmptyCollections()
    local document = assert(yaml.parse("version: 1\ngrid:\n  columns: 4\n  rows: 4\npanels: []\n"))
    assertEqual(type(document.panels), "table")
    assertEqual(#document.panels, 0)

    local normalized, errors = layout.validate(document, grid)
    assertEqual(#errors, 0, table.concat(errors, "\n"))
    assertEqual(#normalized.panels, 0)

    -- A bare key with no value is equally valid and equally empty.
    local bare = assert(yaml.parse("version: 1\ngrid:\n  columns: 4\n  rows: 4\npanels:\n"))
    assertEqual(#select(1, layout.validate(bare, grid)).panels, 0)

    assertEqual(type(assert(yaml.parse("a: {}\n")).a), "table")
end

--- Layout files can no longer select or override a theme.
local function testLayoutTheme()
    local document = assert(yaml.parse([[
version: 1
theme:
  mode: custom
  overrides:
    canvas: 0x000000
grid:
  columns: 4
  rows: 4
panels: []
]]))

    local normalized, errors = layout.validate(document, grid)
    assert(normalized)
    assertEqual(#errors, 1)
    assert(string.find(errors[1], "layout-level theme settings are no longer supported", 1, true), table.concat(errors))
end

--- Every guarantee an alert tint carries must be the reason it was chosen.
---
--- The shipped palettes do not exercise all of them. Removing the elevation
--- and accent checks from the search leaves Modern's tints unchanged, because
--- another check happens to reject the same candidates first, so a test that
--- only looked at Modern would report both as covered while neither did
--- anything. That is the vacuous assertion this project has been caught by
--- before, and the answer is to test the function against palettes where each
--- check is the binding one rather than to assert harder about Modern.
---
--- Each case below is built so exactly one guarantee can reject the candidates
--- a tint would otherwise take. If that guarantee is removed, `alertSurface`
--- returns a colour violating it, and the assertion fails.
local function testAlertTintGuarantees()
    local modern = theme.modernDark()

    --- Tokens that are legible at rest, with one field replaced.
    local function tokensWith(overrides)
        local tokens = {}
        for key, value in pairs(modern) do
            tokens[key] = value
        end
        for key, value in pairs(overrides or {}) do
            tokens[key] = value
        end
        return tokens
    end

    --- Whatever the search returns must satisfy every guarantee, or be absent.
    local function assertCompliant(label, tokens, accent)
        local tint = theme.alertSurface(tokens, accent)
        if tint == nil then
            return nil
        end

        local checks = {
            { "separation from the resting panel", theme.contrast(tokens.surface, tint), 1.30 },
            { "elevation above the screen", theme.contrast(tokens.canvas, tint), 1.30 },
            { "body text", theme.contrast(tint, tokens.text), 4.5 },
            { "muted text", theme.contrast(tint, tokens.textMuted), 3.0 },
            { "faint text", theme.contrast(tint, tokens.textFaint), 1.8 },
            { "its own accent", theme.contrast(tint, accent), 2.5 },
        }
        for _, check in ipairs(checks) do
            assert(
                check[2] >= check[3],
                string.format("%s: the tint leaves %s at %.2f, below %.1f", label, check[1], check[2], check[3])
            )
        end
        return tint
    end

    -- The shipped palettes, which must both produce a tint at all.
    for _, mode in ipairs({ "modern-dark", "custom" }) do
        local resolved = theme.build(mode)
        for _, state in ipairs({ "warning", "critical" }) do
            local accent = state == "warning" and resolved.rgb.amber or resolved.rgb.critical
            assert(
                assertCompliant(mode .. " " .. state, resolved.rgb, accent),
                mode .. " has no " .. state .. " tint at all"
            )
        end
    end

    -- Elevation binds: the screen sits where a tint would otherwise land, so
    -- every candidate separated from the surface is flat against the canvas
    -- until the search is pushed past it.
    assertCompliant("canvas under the tint", tokensWith({ canvas = 0x4B4535 }), modern.amber)

    -- The accent binds: an accent close to the surface it is drawn on leaves a
    -- tint mixed from it closer still, so the accent check is the only thing
    -- that can reject those candidates.
    assertCompliant("accent near the surface", tokensWith({ amber = 0x2E3640 }), 0x2E3640)
    assertCompliant("critical near the surface", tokensWith({ critical = 0x333A44 }), 0x333A44)

    -- Muted and body text are normally the easiest of the three to satisfy,
    -- because faint text is by definition the closest to the surface, so on any
    -- ordinary palette the faint check rejects a candidate before either of them
    -- is consulted and neither can be shown to do anything. A palette that
    -- inverts the ordering makes each the binding one in turn. Nothing ships
    -- looking like this; the point is that the guarantee holds when it has to.
    assertCompliant(
        "muted text nearest the tint",
        tokensWith({ textMuted = 0x555347, textFaint = 0xF0F0F0 }),
        modern.amber
    )
    assertCompliant(
        "body text nearest the tint",
        tokensWith({ text = 0x4A4840, textMuted = 0xF0F0F0, textFaint = 0xE8E8E8 }),
        modern.amber
    )

    -- Faint text binds on a light surface, which is the derived-palette case:
    -- there is no room to lighten, so the search has to darken instead.
    assertCompliant(
        "light surface",
        tokensWith({ surface = 0x364752, canvas = 0x102431, textFaint = 0x737173 }),
        modern.amber
    )

    -- And a palette with nowhere to go returns nothing rather than something
    -- illegible, which is the branch the panel's fallback to its resting surface
    -- exists for. Near-white body text and dark faint text leave no candidate
    -- that meets both contrast floors against this near-white resting surface.
    assertEqual(
        theme.alertSurface(tokensWith({ surface = 0xF2F4F5, canvas = 0xFFFFFF, textFaint = 0x69737A }), modern.amber),
        nil,
        "a palette with no legible tint produced one anyway"
    )
end

--- A hostile surface must never swallow text, accents, or state badges.
local function testDerivedThemesStayLegible()
    testAlertTintGuarantees()
    -- The last two are surfaces that force the critical-red shift: red is never
    -- adjusted, so the surface moves instead, and that move answers only to red.
    -- It can land next to the canvas and leave panels with no edge at all now
    -- that nothing draws an outline, which is why the canvas moves after it.
    local surfaces = { 0xFFFFFF, 0x000000, 0x69737A, 0x808080, 0xF2B84B, 0x101316, 0x1B3A57, 0x8B1A1A }

    for _, surface in ipairs(surfaces) do
        local resolved = buildCustomTheme({ surface = surface, canvas = surface })
        local tokens = resolved.rgb
        local label = string.format("surface 0x%06X", surface)

        assert(theme.contrast(tokens.surface, tokens.text) >= 4.5, label .. ": text")
        assert(theme.contrast(tokens.surface, tokens.textMuted) >= 3.0, label .. ": muted")
        assert(theme.contrast(tokens.surface, tokens.textFaint) >= 1.8, label .. ": faint")

        -- Structural separation must be visible in either direction.
        assert(theme.contrast(tokens.surface, tokens.surfaceRaised) >= 1.20, label .. ": elevation vanished")
        assert(
            theme.contrast(tokens.canvas, tokens.surface) >= 1.30,
            label .. ": the panel is not elevated above the screen"
        )
        -- A track carries meaning: the filled portion is read against it, so it
        -- needs far more separation than panel elevation does. Reusing
        -- surfaceRaised for a compass dial made the dial invisible on a radio.
        assert(theme.contrast(tokens.surface, tokens.track) >= 2.0, label .. ": track vanished into the surface")
        assert(theme.contrast(tokens.surface, tokens.border) >= 1.25, label .. ": border vanished")

        -- Every decorative accent must remain visible on the panel surface.
        for _, key in ipairs({ "cyan", "green", "amber", "orange" }) do
            assert(theme.contrast(tokens.surface, tokens[key]) >= 2.5, label .. ": accent " .. key .. " vanished")
        end

        -- Critical red is an alarm: it must look identical on every radio, so it
        -- is never adjusted. The surface moves instead to keep it visible.
        assertEqual(tokens.critical, theme.modernDark().critical, label .. ": critical red was altered")
        assert(
            theme.contrast(tokens.surface, tokens.critical) >= 2.5,
            label .. ": critical red vanished into the surface"
        )

        -- The unavailable state must stay readable against its own panel.
        --
        -- Readability is a property of the 24-bit tokens, because that is what
        -- the contrast arithmetic is defined on; the state's own `value` is a
        -- display value bound for an LVGL object. Feeding one to `theme.contrast`
        -- measures the luminance of a flag word, which means nothing. So the
        -- state is pinned to the token it must come from, and the token is what
        -- is measured.
        local unavailable = theme.state(resolved, "unavailable")
        assertEqual(unavailable.badge, "N/A", label .. ": badge text")
        assertEqual(
            unavailable.value,
            lcd.RGB(tokens.textFaint),
            label .. ": unavailable text left the resolved palette"
        )
        assert(theme.contrast(tokens.surface, tokens.textFaint) >= 1.8, label .. ": unavailable text vanished")
    end
end

--- Freshness must override a panel's decorative accent.
local function testStaleOverridesAccent()
    local resolved = theme.build("modern-dark")
    local modern = theme.modernDark()

    local normal = theme.state(resolved, "normal", "green")
    local stale = theme.state(resolved, "stale", "green")

    assertEqual(normal.accent, lcd.RGB(modern.green))
    assert(stale.accent ~= lcd.RGB(modern.green), "stale kept the decorative accent")
    assertEqual(stale.accent, lcd.RGB(modern.textFaint))
end

--- A module whose metatable raises must be rejected, not crash the host.
local function testHostileModule()
    local hostile = setmetatable({}, {
        __index = function()
            error("gotcha", 0)
        end,
    })

    local ok, valid = pcall(panelHost.validateModule, hostile, "hostile")
    assert(ok, "hostile module escaped validation")
    assertEqual(valid, false)

    -- Dispatch must also refuse to consult a raising metatable.
    local entry = { placement = { id = "h" }, instance = {}, module = hostile }
    local dispatched, result = pcall(panelHost.dispatch, entry, "refresh")
    assert(dispatched, "hostile module escaped dispatch: " .. tostring(result))
end

--- Threshold direction may be stated explicitly when one bound is configured.

testColorConversion()
testModernTheme()
testRetiredTheme()
testCustomTheme()
testTypography()
testStates()
testPrimitiveMath()
testEmptyCollections()
testLayoutTheme()
testDerivedThemesStayLegible()
testStaleOverridesAccent()
testHostileModule()
