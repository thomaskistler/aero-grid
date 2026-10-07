-- SPDX-License-Identifier: GPL-2.0-only

--- One panel owns detection; other dashboards may display GV9 without tracking.
local flightCounter = {
    id = "flight-counter",
    apiVersion = 1,
    supportedSpans = { "1x1", "2x1", "3x1", "4x1", "1x2", "2x2", "3x2", "4x2" },
    refreshInterval = 20,
    settings = {
        { key = "label", label = "Label", type = "string", default = "FLT" },
        {
            key = "armSwitch",
            label = "Armed switch position",
            type = "string",
            default = "SF^",
        },
        { key = "motorSource", label = "Motor channel", type = "string", default = "ch3" },
        { key = "motorReversed", label = "Reversed motor channel", type = "boolean", default = false },
        { key = "minMotorPercent", label = "Minimum motor percent", type = "number", default = 25 },
        { key = "minFlightDuration", label = "Qualification seconds", type = "number", default = 30 },
        { key = "disarmDuration", label = "Disarm seconds", type = "number", default = 10 },
        { key = "announcements", label = "Announce flights", type = "boolean", default = false },
        { key = "history", label = "Write CSV history", type = "boolean", default = true },
    },
}

function flightCounter.validateSettings(settings)
    local errors = {}
    local arm = settings.armSwitch
    if type(arm) ~= "string" or not (string.match(arm, "^S[A-Z][%^v%-]$") or string.match(arm, "^L%d%d$")) then
        errors[#errors + 1] = "armSwitch must be a position such as SF^, SA-, SFv, or a logical switch such as L01"
    end
    if type(settings.motorSource) ~= "string" or settings.motorSource == "" then
        errors[#errors + 1] = "motorSource must name a radio source"
    end
    for _, key in ipairs({ "minFlightDuration", "disarmDuration" }) do
        local value = settings[key]
        if type(value) ~= "number" or value ~= value or value <= 0 or value > 3600 then
            errors[#errors + 1] = key .. " must be greater than 0 and at most 3600 seconds"
        end
    end
    local percent = settings.minMotorPercent
    if type(percent) ~= "number" or percent ~= percent or percent < 0 or percent >= 100 then
        errors[#errors + 1] = "minMotorPercent must be in the range 0..<100"
    end
    return errors
end

local function isLive(reading, now)
    return reading
        and reading.fresh
        and type(reading.value) == "number"
        and reading.value == reading.value
        and type(reading.updatedAt) == "number"
        and now >= reading.updatedAt
        and now - reading.updatedAt <= 100
end

--- Qualification requires all inputs; ending needs only a reliable arm reading.
function flightCounter.advance(context, now)
    local count = context.feed
    if not count.available then
        return
    end
    assert(
        count.precision == 0 and count.raw >= 0 and count.raw <= 999 and count.raw == math.floor(count.raw),
        "flight counter requires integer GV9 FM0 in the range 0..999, with precision 0"
    )
    local armLive = isLive(context.arm, now)
    assert(not context.motor.telemetry, "flight counter motorSource must be a radio-local motor channel")
    local armed = armLive and context.arm.value > 0

    if context.phase == "active" or context.phase == "ending" then
        if not armLive then
            -- Unknown is not disarmed, and cannot confirm an uninterrupted timeout.
            context.disarmedAt = nil
            context.phase = "active"
        elseif armed then
            context.disarmedAt = nil
            context.phase = "active"
        else
            if not context.disarmedAt then
                context.disarmedAt = now
                context.phase = "ending"
            end
            if now - context.disarmedAt >= context.settings.disarmDuration * 100 then
                local duration = (context.disarmedAt - context.startedAt) / 100
                context.phase = "ground"
                context.startedAt, context.disarmedAt = nil, nil
                if context.settings.history then
                    context.model:logFlight(context.date, duration, context.flightCount)
                end
                if context.settings.announcements then
                    context.model:announceFlight(context.flightCount, true)
                end
            end
        end
        return
    end

    local motorLive = isLive(context.motor, now)
    local motor = motorLive and context.motor.value or -1024
    if context.settings.motorReversed then
        motor = -motor
    end
    local motorPercent = (motor + 1024) * 100 / 2048
    local link = context.link
    local telemetryLive = link.updatedAt and now >= link.updatedAt and now - link.updatedAt <= 100 and link.live
    local qualifying = armed and motorLive and motorPercent > context.settings.minMotorPercent and telemetryLive
    if not qualifying then
        context.phase = "ground"
        context.startedAt = nil
        return
    end
    if not context.startedAt then
        context.startedAt = now
        context.phase = "starting"
        if context.settings.history then
            context.date = context.model:flightDate()
        end
    end
    if now - context.startedAt >= context.settings.minFlightDuration * 100 then
        context.flightCount = context.control:incrementFlightCount()
        context.phase = "active"
        if context.settings.announcements then
            context.model:announceFlight(context.flightCount, false)
        end
    end
end

function flightCounter.regionsFor(theme, builder, rect, fonts)
    return builder.panel(theme, rect, fonts, {
        frame = builder.frame(theme, rect, fonts, nil, "IN-FLIGHT"),
        forms = { "999" },
        draws = { rows = false, visual = false },
    }, {})
end

function flightCounter.render(context, out)
    out.text = context.feed.available and tostring(context.feed.raw) or "--"
    if context.phase == "active" or context.phase == "ending" then
        out.state = "active"
    else
        out.state = context.feed.available and "normal" or "unavailable"
    end
end

function flightCounter.apply(context, drawn)
    local presentation = context.state(drawn.state, "green")
    context.stateName, context.text = drawn.state, drawn.text
    context.value:set({ text = drawn.text, color = presentation.value })
    context.primitives.centreReading(context, context.themeBuilder, context.area, context.area.value, drawn.text)
    context.label:set({ color = presentation.label })
    context.primitives.setBadge(
        context,
        context.themeBuilder,
        context.badge,
        context.area.frame,
        context.fonts.badge,
        presentation.badge or "",
        presentation.accent
    )
    context.primitives.stylePanel(context.panel, presentation)
end

function flightCounter.create(parent, rect, settings, services)
    local errors = flightCounter.validateSettings(settings)
    assert(#errors == 0, table.concat(errors, "; "))
    assert(
        services.telemetry and services.control and services.model and services.clock,
        "flight counter services unavailable"
    )
    assert(services.control.env.setGlobalVariable, "flight counter requires model.setGlobalVariable")
    local area = flightCounter.regionsFor(services.theme, services.themeBuilder, rect, services.fonts)
    local presentation = services.state("unavailable", "green")
    local context = {
        settings = settings,
        theme = services.theme,
        themeBuilder = services.themeBuilder,
        primitives = services.primitives,
        state = services.state,
        fonts = services.fonts,
        clock = services.clock,
        control = services.control,
        model = services.model,
        feed = services.control:globalVariable(8, 0),
        arm = services.control:armSwitch(settings.armSwitch),
        motor = services.telemetry:subscribe(settings.motorSource, false),
        link = services.telemetry:link(),
        area = area,
        phase = "ground",
    }
    context.panel = services.primitives.panel(parent, rect, services.theme, presentation)
    context.label, context.badge = services.primitives.header(
        context.panel.root,
        services.theme,
        area.frame,
        services.fonts,
        settings.label,
        presentation,
        services.themeBuilder
    )
    context.value = services.primitives.value(context.panel.root, services.theme, {
        x = area.valueX,
        y = area.valueY,
        w = area.content,
        text = "--",
        color = presentation.value,
        font = area.value,
    })
    local _, drawn = context.primitives.changed(context, flightCounter.render)
    flightCounter.apply(context, drawn)
    return context
end

local function tick(context)
    local now = context.clock()
    if context.lastTick and now - context.lastTick < flightCounter.refreshInterval then
        return
    end
    -- A scheduling gap cannot prove that a timed condition stayed true.
    if context.lastTick and now - context.lastTick > 100 then
        if context.phase == "starting" then
            context.startedAt = nil
            context.phase = "ground"
        elseif context.phase == "ending" then
            context.disarmedAt = nil
            context.phase = "active"
        end
    end
    context.lastTick = now
    flightCounter.advance(context, now)
    local changed, drawn = context.primitives.changed(context, flightCounter.render)
    if changed then
        flightCounter.apply(context, drawn)
    end
end

flightCounter.refresh = tick
flightCounter.background = tick

function flightCounter.update(context, rect)
    local area = flightCounter.regionsFor(context.theme, context.themeBuilder, rect, context.fonts)
    context.primitives.resizePanel(context.panel, rect)
    context.primitives.placeHeader(
        context.label,
        context.badge,
        area.frame,
        context.themeBuilder,
        context.fonts,
        context.settings.label,
        context.badgeText
    )
    context.area = area
    context.primitives.setFont(context.value, area.value)
    context.value:set({ x = area.valueX, y = area.valueY, w = area.valueWidth })
    context.readingAnchor, context.readingUnitAnchor = nil, nil
    context.primitives.centreReading(context, context.themeBuilder, area, area.value, context.text)
end

return flightCounter
