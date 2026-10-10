-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))().new()
local equal = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual
local definition = fixture.module("main.lua")
local checked = {}

local function labelPositions(object, result, visible)
    visible = visible and not object.hidden
    if visible and object.kind == "label" then
        result[object] = {
            x = object.properties.x,
            y = object.properties.y,
            w = object.properties.w,
            text = object.properties.text,
        }
    end
    for _, child in ipairs(object.children) do
        labelPositions(child, result, visible)
    end
end

local function checkPanel(context, entry)
    local panel = entry.instance
    assert(not entry.failed, entry.placement.id .. ": " .. tostring(entry.error))
    checked[entry.placement.type] = true
    local area = panel.area
    if panel.value and area and area.valueCentre then
        local font = area.value or area.clock or area.nameFont or area.name
        local before = { x = panel.value.properties.x, w = panel.value.properties.w }
        local unitX = panel.unit and panel.unit.properties.x
        panel.readingAnchor, panel.readingUnitAnchor = nil, nil
        context.primitives.centreReading(panel, panel.themeBuilder, area, font, panel.text)
        equal(panel.value.properties.x, before.x, entry.placement.type .. ": unchanged reading already centred")
        equal(panel.value.properties.w, before.w, entry.placement.type .. ": reading group width already correct")
        if panel.unit then
            equal(panel.unit.properties.x, unitX, entry.placement.type .. ": unit already follows unchanged reading")
        end
    end
    if entry.module.apply and panel.rendered then
        local before = {}
        labelPositions(entry.container, before, true)
        for _, key in ipairs({
            "detailAnchor",
            "linkAnchor",
            "extraAnchor",
            "sideAnchor",
            "marginAnchor",
            "countAnchor",
            "packAnchor",
            "originAnchor",
            "coordinatesAnchor",
            "rangeAnchor",
            "secondaryAnchor",
            "labelsAnchor",
        }) do
            panel[key] = nil
        end
        entry.module.apply(panel, panel.rendered)
        local after = {}
        labelPositions(entry.container, after, true)
        for object, position in pairs(before) do
            if after[object] and after[object].text == position.text then
                for _, key in ipairs({ "x", "y", "w" }) do
                    equal(
                        after[object][key],
                        position[key],
                        entry.placement.type .. ": reflow already positions label " .. key
                    )
                end
            end
        end
    end
end

for _, dashboard in ipairs({
    "review-metric",
    "review-link-status",
    "review-tx-battery",
    "review-cell-battery",
    "review-navigation",
    "review-flight-timer",
    "review-flight-mode",
    "review-model-identity",
    "review-text",
    "review-trim-panel",
    "Default",
    "services",
    "Host",
}) do
    fixture.reset()
    fixture.lvglMock.setAppMode(true)
    fixture.lvglMock.setFullScreen(false)
    local context = fixture.createLoaded(nil, { Layout = dashboard, Theme = "modern-dark" })
    fixture.pump(context, 40)
    equal(#context.errors, 0, dashboard .. ": " .. table.concat(context.errors, "; "))
    for _, size in ipairs({ { 480, 272 }, { 320, 240 }, { 480, 272 } }) do
        for _, fullscreen in ipairs({ true, false }) do
            context.zone.w, context.zone.h = size[1], size[2]
            fixture.lvglMock.setFullScreen(fullscreen)
            definition.refresh(context)
            local guard = 0
            while context.reflowIndex do
                definition.refresh(context)
                guard = guard + 1
                assert(guard < 100, "reflow did not finish")
            end
            -- No telemetry tick or panel refresh between reflow and the assertions.
            for _, entry in ipairs(context.panels) do
                checkPanel(context, entry)
            end
            fixture.pump(context, 10)
            equal(#context.errors, 0, dashboard .. ": " .. table.concat(context.errors, "; "))
        end
    end
end
for _, panelType in ipairs({
    "metric",
    "link-status",
    "tx-battery",
    "cell-battery",
    "navigation",
    "flight-timer",
    "flight-mode",
    "model-identity",
    "text",
    "trim-panel",
    "flight-counter",
    "service-probe",
    "host-diagnostics",
}) do
    assert(checked[panelType], "missing reflow coverage for " .. panelType)
end
fixture.lvglMock.setAppMode(false)
fixture.lvglMock.setFullScreen(false)
