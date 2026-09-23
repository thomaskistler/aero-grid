-- SPDX-License-Identifier: GPL-2.0-only

--- One EdgeTX model timer, presented for the dashboard.
---
--- AeroGrid does not implement a second timer engine. EdgeTX already owns the
--- count direction, the start value, persistence, the configured name, and
--- whether the timer shows elapsed or remaining time, and it keeps counting
--- while this widget is not even visible. The component reads
--- `model.getTimer(index)` through `modelService` and renders what the radio
--- reports.
---
--- The one thing that genuinely needs presenting rather than reporting is a
--- countdown that has run past zero. EdgeTX keeps counting into negative
--- numbers there, which is easy to misread as a healthy timer, so the
--- component states it explicitly as well as showing the minus sign.

---@class AeroGridTimerSettings
---@field timer? number Zero-based EdgeTX timer index.
---@field label? string Panel label; the timer's own name is used when empty.
---@field accent? string
---@field reading? "model"|"elapsed"|"remaining"
---@field warning? number Seconds at which the timer becomes a caution.
---@field critical? number Seconds at which the timer becomes critical.

---@class AeroGridTimerContext
---@field panel table
---@field feed? AeroGridModelTimer
---@field stateName string
---@field text string Last rendered clock reading.

local flightTimer = {
    id = "flight-timer",
    apiVersion = 1,
    supportedSpans = {
        "1x1",
        "2x1",
        "3x1",
        "4x1",
        "1x2",
        "2x2",
        "3x2",
        "4x2",
    },
    -- A clock advances once a second, so anything faster is wasted work charged
    -- to the same instruction budget as every other component on the dashboard.
    refreshInterval = 100,
    settings = {
        { key = "timer", label = "Model timer", type = "number", default = 0 },
        -- An empty label is not an absent one: it means derive the heading at
        -- runtime, here from the timer's own name, or its number when it has none. A
        -- component with a fixed heading states it as its default instead.
        { key = "label", label = "Label", type = "string", default = "" },
        {
            key = "accent",
            label = "Accent",
            type = "string",
            default = "cyan",
            choices = { "cyan", "green", "amber", "orange" },
        },
        -- `model` follows the timer's own configured elapsed/remaining choice.
        -- Which of the timer's values leads the panel, named `reading` like every
        -- other component that chooses between its own values.
        {
            key = "reading",
            label = "Show",
            type = "string",
            default = "model",
            choices = { "model", "elapsed", "remaining" },
        },
        { key = "warning", label = "Warning seconds", type = "number" },
        { key = "critical", label = "Critical seconds", type = "number" },
        -- A countdown is judged on the time it has left and a count-up timer on
        -- the time it has used, so the direction follows the timer rather than
        -- the layout and cannot be stated.
        -- No `direction`. It is real here -- a countdown alarms on the time it
        -- has left and a count-up timer on the time it has used -- but EdgeTX
        -- already says which a timer is, through `model.getTimer`, and
        -- `resolveState` has always read that rather than the setting. Stating
        -- it was restating the radio.
    },
}

--- Model timers a radio has, from `MAX_TIMERS` in
--- `radio/src/dataconstants.h:94`. `luaModelGetTimer` answers nothing at all
--- for an index at or above it (`radio/src/lua/api_model.cpp`), so 0, 1 and
--- 2 are the whole set on every colour target.
flightTimer.TIMER_COUNT = 3

--- Refuse a timer index the radio does not have.
---
--- **An out-of-range index is an authoring mistake, and it used to load.**
--- `timer: 9` produced a panel drawing `NO TIMER`, which is the same thing a
--- correctly written layout draws on a radio whose timer is not configured
--- -- so the one case the author can fix looked exactly like the one they
--- cannot, and nothing said which it was.
---
--- It belongs here and not at runtime because it is knowable from the layout
--- alone: the count is a firmware constant, not model state. That is the
--- line this hook draws, and it is why the count-up timer asked for
--- `remaining` is reported on the panel instead -- see `detailVariants`.
---@param settings AeroGridTimerSettings
---@param span? table
---@param config? table What the layout actually stated.
---@return string[] messages
function flightTimer.validateSettings(settings, span, config)
    local messages = {}
    -- Read from the layout rather than the resolved settings: a default that
    -- is in range is not a request, and only a request can be refused.
    local stated = config and config.timer
    if stated == nil then
        return messages
    end

    if type(stated) ~= "number" or stated ~= math.floor(stated) or stated < 0 or stated >= flightTimer.TIMER_COUNT then
        messages[#messages + 1] = "timer must be 0, 1 or 2; a radio has "
            .. tostring(flightTimer.TIMER_COUNT)
            .. " model timers and "
            .. tostring(stated)
            .. " is not one of them, so the panel would draw"
            .. " NO TIMER whatever the model is set to."
    end

    return messages
end

--- The largest magnitude this panel will print, in seconds.
---
--- **A display clamp, not a limit on the timer.** EdgeTX's own range is
--- `TIMER_MAX`, `0xffffff/2` or 8388607 seconds (`radio/src/timers.h:34`),
--- which is 2330 hours, and `TIMER_MIN` is its negative
--- (`radio/src/timers.h:36`). A pilot can set anything in that range from
--- Model Setup, so the range this clamp folds away is genuinely reachable in
--- firmware -- it is just not reachable in flying.
---
--- The reading is what is clamped, and only the reading, because the reading
--- is the one string whose font is chosen from `FORMS` below. The service's
--- own `text` is left alone, so `service-probe` keeps reporting what the
--- radio actually said: a diagnostics view that showed a clamped value would
--- be reporting on a world assembled for it. The supporting row is fitted to
--- its own width by `theme.fitLabel` rather than sized from `FORMS`, so it is
--- not clamped either -- which means a countdown whose total runs past the
--- clamp still says `OF 5:00:00` beneath a clamped reading, and the panel
--- tells on itself wherever that row is drawn.
---
--- The docs page states what this hides. See `docs/components/flight-timer.md`.
flightTimer.CLAMP = 99 * 60 + 59

--- Forms of the clock, longest first, and there is deliberately only one.
--- See the note in `regionsFor`: every shorter form of a clock drops a field,
--- and a field is magnitude.
---
--- **This is the widest string the component can actually print**, which is
--- the clamp above carrying a sign. It was `-88:88:88`, reserving for a
--- countdown ten hours past zero, and that cost a font size: at `2 x 2` in
--- App mode it measures 218 px against a 226 px content box, so the clock
--- stepped down from `XXLSIZE` on a margin of 8 px -- 3.5% -- while the
--- `3 x 2` beside it had 129 px and did not. Two panels of one height
--- disagreed, which is the thing the shared ladder exists to prevent.
---
--- It is written as a value the component can produce rather than as a row
--- of eights, so the claim is checkable: `testClockNeverOutgrowsItsForm`
--- asserts that the clamp's own output is exactly this string. A form is a
--- claim about the widest thing a component will ever draw, and this project
--- has now been wrong about that twice in opposite directions -- see the
--- specification's note on forms.
flightTimer.FORMS = { "-99:59" }

--- Fold a reading down to the largest magnitude this panel prints.
---
--- **The sign survives.** A countdown that has run past zero is negative, and
--- that is the one state this component exists to make unmistakable: dropping
--- the sign would turn an hour and forty minutes *past* a landing time into
--- an hour and forty minutes *remaining*. So the clamp bounds the magnitude
--- and leaves the direction alone, and `-99:59` is therefore the widest
--- string it can produce.
---@param seconds any
---@return any seconds Clamped where it is a number, unchanged otherwise.
function flightTimer.clamp(seconds)
    if type(seconds) ~= "number" then
        return seconds
    end
    if seconds > flightTimer.CLAMP then
        return flightTimer.CLAMP
    end
    if seconds < -flightTimer.CLAMP then
        return -flightTimer.CLAMP
    end
    return seconds
end

--- Render a second count as this panel's clock: minutes and seconds, always.
---
--- **It does not change shape, and that is the whole of why it exists.**
--- `modelService.formatTime` grows an hours field the moment a reading
--- passes 3600 seconds, so a clock steps from `59:59` to `1:00:00` -- two
--- characters wider -- while it is being read. That is a panel reflowing
--- itself at the moment attention is on it, and it is what forced the old
--- sizing form to reserve for `-88:88:88`.
---
--- So the minutes field simply keeps counting: 90 minutes is `90:00` rather
--- than `1:30:00`, and both name the same duration. Together with the clamp
--- above this bounds the string at `-99:59` and fixes the panel's width for
--- its whole life.
---
--- **The service's own formatter is untouched**, and is still what
--- `service-probe` reports: hours are the right presentation for a
--- diagnostics line, which is read once and is not being flown by.
---@param seconds any
---@return string
function flightTimer.formatClock(seconds)
    if type(seconds) ~= "number" then
        return "--:--"
    end

    local sign = seconds < 0 and "-" or ""
    local total = math.floor(math.abs(seconds) + 0.5)
    return string.format("%s%d:%02d", sign, math.floor(total / 60), total % 60)
end

--- Describe how the component presents itself at a given span.
---@param colSpan integer
---@param rowSpan integer
---@return table
function flightTimer.presentationFor(colSpan, rowSpan)
    local cells = (colSpan or 1) * (rowSpan or 1)

    -- A countdown's progress bar needs a known total, so it appears only on
    -- panels large enough to carry it without crowding the clock.
    if cells >= 4 then
        return { showDetail = true, showVisual = true }
    end
    if cells >= 2 then
        return { showDetail = true, showVisual = false }
    end
    return { showDetail = false, showVisual = false }
end

--- Choose which of the timer's readings to display.
--- EdgeTX records the pilot's own elapsed/remaining preference on the timer,
--- so `model` honours it and the other choices override it deliberately.
---@param settings AeroGridTimerSettings
---@param feed AeroGridModelTimer
---@return number seconds
function flightTimer.displayValue(settings, feed)
    local display = settings.reading

    if display == "elapsed" then
        return feed.elapsed
    end
    if display == "remaining" then
        return feed.countdown and feed.remaining or feed.elapsed
    end

    -- EdgeTX's own presentation: `value` already counts the right way, and
    -- showElapsed flips a countdown to count up instead.
    if feed.showElapsed then
        return feed.elapsed
    end
    return feed.value
end

--- Resolve the component state from the timer's own reading.
---
--- A countdown is judged on the time it has left and a count-up timer on the
--- time it has used, because those are the two numbers a pilot actually flies
--- to. An expired countdown is always critical: it is the one state that must
--- not be mistaken for a healthy timer.
---@param settings AeroGridTimerSettings
---@param feed? AeroGridModelTimer
---@return string
function flightTimer.resolveState(settings, feed)
    if type(feed) ~= "table" or not feed.available then
        return "unavailable"
    end
    if feed.countdown and feed.expired then
        return "critical"
    end

    local measured = feed.countdown and feed.remaining or feed.elapsed
    local warning = type(settings.warning) == "number" and settings.warning or nil
    local critical = type(settings.critical) == "number" and settings.critical or nil

    if feed.countdown then
        if critical and measured <= critical then
            return "critical"
        end
        if warning and measured <= warning then
            return "warning"
        end
    else
        if critical and measured >= critical then
            return "critical"
        end
        if warning and measured >= warning then
            return "warning"
        end
    end

    return "normal"
end

--- Wordings for the row beneath the clock, longest first.
---
--- **One form per state, and each fits every panel that draws a row.** The
--- longest is `COUNTING UP` at 84 px, against the 105 px content box of a
--- `1 x 2` -- the narrowest panel the ladder grants a row at all -- and
--- against the 86 px a row sharing a line with another would get. This row
--- never shares a line, so only the first budget binds; both are quoted
--- because a form that clears the tighter one cannot be broken by a later
--- arrangement.
---
--- **It was a ladder, briefly, and a ladder was the wrong answer.** The row
--- said `ELAPSED PAST ZERO`, which is 125 px into that 105 px box, so it was
--- centred on a box wider than its panel and ran ten pixels off each edge --
--- a Lua label wraps rather than clipping, so it could not simply be cut.
--- The first fix offered `PAST ZERO` beneath it and let `theme.fitLabel`
--- choose. That works and it buys nothing: a form short enough to fit the
--- narrowest panel is short enough for every other, so the longer form was
--- only ever drawn where the shorter one would also have been correct. The
--- state is now `EXPIRED`, one word, everywhere.
---
--- A ladder earns its place where the *longer* form carries something the
--- shorter cannot and there is a real panel wide enough to show it. That is
--- a judgement about wording rather than about width, and this row had none
--- to make.
---
--- **The shortest wording of each state still differs from every other's.**
--- Shortening may cost detail and may never cost meaning, which is what
--- stops `EXPIRED` and `NO TOTAL` collapsing into one word that covers both.
--- `testSupportingWordingsStayDistinct` holds this component to it.
---
--- The list is still a list and still goes through `theme.fitLabel`, because
--- every supporting row in the catalogue does; a single-entry list comes
--- back out of it unchanged.
---@param feed? AeroGridModelTimer
---@param formatTime fun(seconds: any): string
---@param settings? AeroGridTimerSettings What the layout asked for.
---@return string[] variants Longest first.
function flightTimer.detailVariants(feed, formatTime, settings)
    if type(feed) ~= "table" or not feed.available then
        return { "NO TIMER" }
    end

    if feed.countdown then
        -- **The total is magnitude and has no shorter form.** Dropping a field
        -- of it would report a different duration, which no width is worth. It
        -- fits every panel that draws a row: the widest a radio can hold is
        -- `OF 139810:07`, at 81 px.
        if feed.expired then
            return { "EXPIRED" }
        end
        return { "OF " .. formatTime(feed.start) }
    end

    -- **A count-up timer asked for `remaining` says so.** There is no total to
    -- take a remainder of, so the panel shows elapsed -- which it did
    -- silently, and a layout author reading the setting back believed it.
    -- This cannot be refused at load the way an out-of-range index can: which
    -- timers count down is the pilot's model setup, not the layout's, so the
    -- contradiction is only knowable once the radio has answered.
    --
    -- It goes in the supporting row because that is where this dashboard puts
    -- why: a badge names the state and the row says what is behind it.
    if settings ~= nil and settings.reading == "remaining" then
        return { "NO TOTAL" }
    end

    return { "COUNTING UP" }
end

--- Describe the timer beneath the clock, fitted to the row it will be given.
---
--- Fitted rather than written straight into the label, which is what every
--- supporting row in the catalogue with more than one wording already does.
--- `theme.fitLabel` takes the longest form that fits.
---@param feed? AeroGridModelTimer
---@param formatTime fun(seconds: any): string
---@param settings? AeroGridTimerSettings
---@param themeBuilder? table
---@param font? any
---@param width? integer Row width; nil keeps the longest wording.
---@return string
function flightTimer.detailText(feed, formatTime, settings, themeBuilder, font, width)
    local variants = flightTimer.detailVariants(feed, formatTime, settings)
    if themeBuilder == nil or width == nil then
        return variants[1]
    end
    return themeBuilder.fitLabel(variants, font, width)
end

--- Fraction of a countdown that has been used, for the optional bar.
--- A count-up timer has no total, so it has no fraction and no bar.
---@param feed? AeroGridModelTimer
---@return number
function flightTimer.fraction(feed)
    if type(feed) ~= "table" or not feed.available then
        return 0
    end
    if not feed.countdown or type(feed.start) ~= "number" or feed.start <= 0 then
        return 0
    end

    local used = feed.elapsed / feed.start
    if used < 0 then
        return 0
    end
    if used > 1 then
        return 1
    end
    return used
end

--- Compute the content regions for the current rectangle.
---@param theme AeroGridTheme
---@param themeBuilder table
---@param rect AeroGridRect
---@param layout table
---@param fonts table
---@return table
function flightTimer.regionsFor(theme, themeBuilder, rect, layout, fonts, out)
    -- The whole arrangement, from the shared builder. A timer's only
    -- visualization is a bar, which spans the panel by design and is exempt
    -- from the slot rule, so the clock never splits and centres across the
    -- whole content box.
    local area = themeBuilder.panel(theme, rect, fonts, {
        -- Built through this component's own builder, which the host may have
        -- wrapped to lay the panel out around the menu button's corner.
        frame = themeBuilder.frame(theme, rect, fonts),
        forms = flightTimer.FORMS,
        draws = {
            rows = layout.showDetail == true,
            visual = layout.showVisual == true,
        },
        bar = true,
    }, out or {})

    -- The clock under its own word, because `render` and `apply` read it. It
    -- used to carry `clockY` beside `valueY` for one band, which is exactly
    -- the divergence the shared name exists to stop.
    area.clock = area.value
    return area
end

--- Build the component's LVGL objects.
---@param parent any
---@param rect AeroGridRect
---@param settings AeroGridTimerSettings
---@param services table
---@return AeroGridTimerContext
function flightTimer.create(parent, rect, settings, services)
    local theme = services.theme
    local primitives = services.primitives
    local fonts = services.fonts
    local span = services.span
    local layout = flightTimer.presentationFor(span.colSpan, span.rowSpan)
    local presentation = services.state("normal", settings.accent)
    local area = flightTimer.regionsFor(theme, services.themeBuilder, rect, layout, fonts)

    local context = {
        theme = theme,
        themeBuilder = services.themeBuilder,
        primitives = primitives,
        state = services.state,
        fonts = fonts,
        layout = layout,
        settings = settings,
        stateName = "normal",
        text = "--:--",
        detail = "",
    }

    -- Subscribing in create is what tells the model service that this timer is
    -- referenced; a timer nothing references is never read.
    local modelService = services.model
    if modelService then
        context.feed = modelService:timer(settings.timer)
    end
    -- **This panel's own clock, not the service's.** The service formats for a
    -- diagnostics line and grows an hours field; this panel needs a string
    -- whose width is fixed for the life of the panel, because its font was
    -- chosen from one. `formatClock` answers `--:--` for anything that is not
    -- a number, so there is nothing to fall back to when the service is
    -- absent.
    context.formatTime = flightTimer.formatClock

    local panel = primitives.panel(parent, rect, theme, presentation)
    context.panel = panel

    -- The timer's configured name is the most useful label there is, so it wins
    -- unless the layout states one. It is only known once the service has read
    -- the timer, which is why refresh revisits it.
    context.label, context.badge = primitives.header(
        panel.root,
        theme,
        area.frame,
        fonts,
        flightTimer.labelText(context),
        presentation,
        services.themeBuilder
    )
    -- The heading is refitted whenever it changes, so the column it has to
    -- fit is kept beside it.
    context.frame = area.frame
    -- Kept, because the clock is centred on a slot and `apply` needs to know
    -- where that slot is. This component had no reason to remember its regions
    -- while everything it drew started at the padding.
    context.area = area

    context.value = primitives.value(panel.root, theme, {
        x = area.valueX,
        y = area.valueY,
        w = area.valueWidth,
        text = context.text,
        color = presentation.value,
        font = area.clock,
    })

    context.detailLabel = primitives.label(panel.root, theme, {
        x = area.pad,
        y = area.detailY,
        w = area.content,
        text = "",
        color = theme.color.textFaint,
        font = fonts.label,
    })

    if layout.showVisual then
        context.bar = primitives.bar(panel.root, theme, {
            x = area.pad,
            y = area.barY,
            w = area.content,
            fraction = 0,
            color = presentation.accent,
        })
    end

    -- What the panel currently draws, so `render` declares only that and a
    -- reflow that changes nothing about visibility says nothing again.
    context.showDetail = area.showDetail
    context.showVisual = area.showVisual and context.bar ~= nil

    if not area.showDetail then
        lvgl.hide(context.detailLabel)
    end
    if context.bar and not area.showVisual then
        lvgl.hide(context.bar.track)
        lvgl.hide(context.bar.fill)
    end

    local _, drawn = primitives.changed(context, flightTimer.render)
    flightTimer.apply(context, drawn)
    return context
end

--- Resolve the panel label, preferring the timer's own configured name.
---@param context AeroGridTimerContext
---@return string
function flightTimer.labelText(context)
    local stated = context.settings.label
    if type(stated) == "string" and stated ~= "" then
        return stated
    end

    local feed = context.feed
    if type(feed) == "table" and type(feed.name) == "string" and feed.name ~= "" then
        return feed.name
    end

    return "TIMER " .. tostring(context.settings.timer)
end

--- Repaint the component from its current subscription.
---@param context AeroGridTimerContext
--- Collect everything this panel draws.
---
--- The timer's configured start is why this is a declaration. `apply` drew it
--- in "OF 5:00" and used it for the bar, while the refresh compared only the
--- displayed value, so a timer reconfigured mid-flight kept the old total.
--- The timer's own name is here for the same reason: it arrives with the
--- first successful read, and used to be reconciled by a second, separate
--- comparison bolted onto the end of refresh.
---@param context AeroGridTimerContext
---@param out table
function flightTimer.render(context, out)
    local feed = context.feed
    local settings = context.settings
    local available = type(feed) == "table" and feed.available == true

    out.state = flightTimer.resolveState(settings, feed)
    out.text = available and context.formatTime(flightTimer.clamp(flightTimer.displayValue(settings, feed))) or "--:--"
    -- Declared only where it is drawn. A panel too short for a supporting row
    -- was still formatting a second clock every frame and writing it into a
    -- hidden label, which is the invisible work the reveal work removed from
    -- five components and this one was not among them.
    if context.showDetail then
        out.detail = flightTimer.detailText(
            feed,
            context.formatTime,
            settings,
            context.themeBuilder,
            context.fonts.label,
            context.area.detailWidth
        )
    end
    if context.showVisual then
        out.fraction = flightTimer.fraction(feed)
    end
    out.label = string.upper(flightTimer.labelText(context))
end

--- Paint the panel from what `render` collected, and from nothing else.
---@param context AeroGridTimerContext
---@param drawn table
function flightTimer.apply(context, drawn)
    local presentation = context.state(drawn.state, context.settings.accent)

    context.stateName = drawn.state
    context.text = drawn.text
    context.detail = drawn.detail or ""
    context.labelValue = drawn.label

    context.value:set({ text = drawn.text, color = presentation.value })
    -- The clock is centred on its slot, so where it starts depends on what it
    -- reads: a timer crossing into hours grows about its middle rather than
    -- running rightwards. Keyed on the text, so a steady second costs nothing
    -- beyond the comparison.
    context.primitives.centreReading(context, context.themeBuilder, context.area, context.area.clock, drawn.text)
    -- Through the fitter, not straight into the label: this heading comes from
    -- the model at runtime and is exactly the kind that overflows its column.
    context.primitives.setHeading(
        context.label,
        context.themeBuilder,
        context.frame,
        context.fonts,
        drawn.label,
        presentation.label
    )
    context.primitives.setBadge(
        context,
        context.themeBuilder,
        context.badge,
        context.area.frame,
        context.fonts.badge,
        presentation.badge or "",
        presentation.accent
    )
    if context.showDetail then
        context.detailLabel:set({ text = context.detail })
        -- A row of one item centres across the content box, exactly as a lone
        -- reading does.
        context.primitives.centreLabel(
            context,
            "detailAnchor",
            context.themeBuilder,
            context.detailLabel,
            context.area.detailCentre,
            context.area.detailY,
            context.fonts.label,
            context.detail
        )
    end
    context.primitives.stylePanel(context.panel, presentation)

    if context.showVisual and context.bar then
        context.primitives.setBar(context.bar, drawn.fraction, presentation.accent)
    end
end

--- Advance the component, repainting only when something drawn changed.
---@param context AeroGridTimerContext
function flightTimer.refresh(context)
    if not context.feed then
        return
    end
    local changed, drawn = context.primitives.changed(context, flightTimer.render)
    if changed then
        flightTimer.apply(context, drawn)
    end
end

--- Reposition after a zone change, shedding or restoring optional rows.
---@param context AeroGridTimerContext
---@param rect AeroGridRect
function flightTimer.update(context, rect)
    -- Into the table this panel already owns, rather than a fresh one per
    -- reflow: see `theme.panel`.
    local area =
        flightTimer.regionsFor(context.theme, context.themeBuilder, rect, context.layout, context.fonts, context.area)

    context.primitives.resizePanel(context.panel, rect)
    -- The heading is the model's timer name rather than the setting, so the
    -- refit is given what the panel currently shows.
    context.primitives.placeHeader(
        context.label,
        context.badge,
        area.frame,
        context.themeBuilder,
        context.fonts,
        context.labelValue,
        context.badgeText
    )
    context.frame = area.frame
    context.value:set({
        x = area.valueX,
        y = area.valueY,
        w = area.valueWidth,
        font = function()
            return area.clock
        end,
    })
    context.area = area
    -- Every anchor is about a slot and a font that have just moved.
    context.readingAnchor, context.readingUnitAnchor = nil, nil
    context.detailAnchor = nil

    local primitives = context.primitives
    primitives.reconcile(
        context.detailLabel,
        area.showDetail,
        { x = area.pad, y = area.detailY, w = area.content },
        area.showDetail == context.showDetail
    )
    primitives.centreLabel(
        context,
        "detailAnchor",
        context.themeBuilder,
        area.showDetail and context.detailLabel or nil,
        area.detailCentre,
        area.detailY,
        context.fonts.label,
        context.detail
    )

    local showVisual = area.showVisual and context.bar ~= nil
    primitives.reconcileBar(
        context.bar,
        area.showVisual,
        area.pad,
        area.barY,
        area.content,
        flightTimer.fraction(context.feed),
        showVisual == context.showVisual
    )

    -- A row that has just reappeared holds whatever it had when it was shed,
    -- and `render` stopped declaring its key while it was hidden, so the record
    -- of what was drawn is dropped and the next refresh repaints it.
    if area.showDetail ~= context.showDetail or showVisual ~= context.showVisual then
        context.rendered = nil
    end
    context.showDetail = area.showDetail
    context.showVisual = showVisual
end

return flightTimer
