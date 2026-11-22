-- SPDX-License-Identifier: GPL-2.0-only

local _, armedConfig = ...
local validSwitch = assert(armedConfig, "flight counter requires switch validation").valid

--- Presentation only; the shared flight service owns tracking and effects.
local flightCounter = {
    id = "flight-counter",
    supportedSpans = { "any" },
    refreshInterval = 20,
    settings = {
        { key = "label", label = "Label", type = "string", default = "FLT" },
        {
            key = "armSwitch",
            label = "Arm switch position",
            type = "string",
            default = "",
            legacyArm = true,
        },
        { key = "_legacyFlight", type = "boolean", default = false, legacyFlight = true },
        { key = "motorSource", type = "string", default = "ch3", legacyFlight = true },
        { key = "motorReversed", type = "boolean", default = false, legacyFlight = true },
        { key = "minMotorPercent", type = "number", default = 25, legacyFlight = true },
        { key = "minFlightDuration", type = "number", default = 30, legacyFlight = true },
        { key = "disarmDuration", type = "number", default = 10, legacyFlight = true },
    },
}

function flightCounter.validateSettings(settings, _, _, modelArmed)
    local errors = {}
    local arm = settings.armSwitch
    if modelArmed == nil and arm ~= nil and arm ~= "" and not validSwitch(arm) then
        errors[#errors + 1] = "armSwitch must be blank, a physical switch position, or a logical switch"
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

function flightCounter.regionsFor(theme, builder, rect, fonts, digits)
    return builder.panel(theme, rect, fonts, {
        frame = builder.frame(theme, rect, fonts, nil, "IN-FLIGHT"),
        forms = { string.rep("9", digits or 3) },
        draws = { rows = false, visual = false },
    }, {})
end

function flightCounter.render(context, out)
    out.text = context.flight.countAvailable and tostring(context.flight.displayCount) or "--"
    if not context.flight.countAvailable then
        out.state = "unavailable"
    elseif context.flight.active then
        out.state = "active"
    else
        out.state = "normal"
    end
end

function flightCounter.apply(context, drawn)
    local presentation = context.state(drawn.state, "green")
    context.stateName, context.text = drawn.state, drawn.text
    local digits = math.max(3, #drawn.text)
    if context.digits ~= digits then
        context.digits = digits
        flightCounter.update(context, context.rect)
    end
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
    local errors = flightCounter.validateSettings(settings, nil, nil, services.host and services.host.modelArmed)
    assert(#errors == 0, table.concat(errors, "; "))
    assert(
        services.control and services.flight and services.clock and services.armed,
        "flight counter services unavailable"
    )
    local shared = services.flight:state()
    local digits = math.max(3, #tostring(shared.displayCount or 0))
    local area = flightCounter.regionsFor(services.theme, services.themeBuilder, rect, services.fonts, digits)
    local presentation = services.state("unavailable", "green")
    local context = {
        settings = settings,
        theme = services.theme,
        themeBuilder = services.themeBuilder,
        primitives = services.primitives,
        state = services.state,
        fonts = services.fonts,
        clock = services.clock,
        preview = services.preview == true,
        rect = rect,
        digits = digits,
        arm = services.armed:state(settings.armSwitch),
        flight = shared,
        area = area,
    }
    context.panel, context.label, context.badge = services.primitives.panelWithHeader(
        parent,
        rect,
        services.theme,
        presentation,
        area.frame,
        services.fonts,
        settings.label,
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
    context.lastTick = now
    local changed, drawn = context.primitives.changed(context, flightCounter.render)
    if changed then
        flightCounter.apply(context, drawn)
    end
end

flightCounter.refresh = tick
flightCounter.background = tick

function flightCounter.rebindArming(context, services)
    context.arm = services.armed:state(context.settings.armSwitch)
    context.lastTick = nil
end

function flightCounter.update(context, rect)
    local area = flightCounter.regionsFor(context.theme, context.themeBuilder, rect, context.fonts, context.digits)
    context.primitives.resizeHeader(context, rect, area.frame, context.settings.label)
    context.area, context.rect = area, rect
    context.primitives.setFont(context.value, area.value)
    context.value:set({ x = area.valueX, y = area.valueY, w = area.valueWidth })
    context.readingAnchor, context.readingUnitAnchor = nil, nil
    context.primitives.centreReading(context, context.themeBuilder, area, area.value, context.text)
end

return flightCounter
