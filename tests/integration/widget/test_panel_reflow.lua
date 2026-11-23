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

local function reflow(context, width, height, fullscreen)
    context.zone.w, context.zone.h = width, height
    fixture.lvglMock.setFullScreen(fullscreen)
    definition.refresh(context)
    local guard = 0
    while context.reflowIndex or context.hostKind do
        definition.refresh(context)
        guard = guard + 1
        assert(guard < 100, "reflow did not finish")
    end
    -- Check immediately, without a telemetry tick or panel refresh.
    for _, entry in ipairs(context.panels) do
        checkPanel(context, entry)
    end
end

for _, dashboard in ipairs({
    "review-metric",
    "review-link-status",
    "review-tx-battery",
    "review-rx-battery",
    "review-navigation",
    "review-flight-timer",
    "review-flight-mode",
    "review-model-identity",
    "review-state",
    "review-trim-panel",
    "Default",
    "services",
    "Diagnostics",
}) do
    fixture.reset()
    fixture.lvglMock.setAppMode(true)
    fixture.lvglMock.setFullScreen(false)
    local context = fixture.createLoaded(nil, { Layout = dashboard, Theme = "modern-dark" })
    fixture.pump(context, 40)
    equal(#context.errors, 0, dashboard .. ": " .. table.concat(context.errors, "; "))
    for _, size in ipairs({ { 480, 272 }, { 320, 240 }, { 480, 272 } }) do
        for _, fullscreen in ipairs({ true, false }) do
            reflow(context, size[1], size[2], fullscreen)
            fixture.pump(context, 10)
            equal(#context.errors, 0, dashboard .. ": " .. table.concat(context.errors, "; "))
        end
    end
end
for _, panelType in ipairs({
    "metric",
    "link-status",
    "tx-battery",
    "rx-battery",
    "navigation",
    "flight-timer",
    "flight-mode",
    "model-identity",
    "state",
    "trim-panel",
    "flight-counter",
    "service-probe",
    "host-diagnostics",
}) do
    assert(checked[panelType], "missing reflow coverage for " .. panelType)
end
fixture.lvglMock.setAppMode(false)
fixture.lvglMock.setFullScreen(false)

local layouts = assert(loadfile(root .. "/tests/support/layout_fixtures.lua"))()
local geometry = assert(loadfile(root .. "/tests/support/widget_geometry.lua"))(fixture)
for _, layout in ipairs({ "CORE_LAYOUT", "TELEMETRY_LAYOUT" }) do
    fixture.reset()
    fixture.lvglMock.setAppMode(false)
    local context = fixture.createLoaded(nil, nil, fixture.makeWidget("reflow-" .. layout, layouts[layout]))
    fixture.pump(context, 20)
    for _, size in ipairs({ { 480, 272 }, { 320, 140 }, { 480, 272 } }) do
        reflow(context, size[1], size[2], false)
        geometry.assertReflowContained(context, layout)
        local nav = fixture.instanceOf(context, "nav")
        if nav then
            assert(nav.area.value ~= nil, "tape panel lost its reading after reflow")
            equal(nav.detailLabel.hidden, true, "tape must not duplicate the bearing row")
            if size[1] == 480 then
                equal(nav.showTape, true, "tape must return after restoring size")
                equal(nav.showCoordinates, true, "restored tape lost its coordinates")
            end
        end
        fixture.pump(context, 10)
        equal(#context.errors, 0, table.concat(context.errors, "; "))
    end
end

for _, subject in ipairs({
    {
        dashboard = "review-flight-mode",
        id = "one-by-one-plain",
        module = "flight-mode",
        preference = "showIndex",
        label = "detailLabel",
        text = "detail",
    },
    {
        dashboard = "review-model-identity",
        id = "corner-name",
        module = "model-identity",
        preference = "showLabels",
        label = "labelsLabel",
        text = "labelsText",
    },
}) do
    fixture.reset()
    local context = fixture.createLoaded(nil, { Layout = subject.dashboard, Theme = "modern-dark" })
    fixture.pump(context, 40)
    equal(#context.errors, 0, table.concat(context.errors, "; "))
    for _, notice in ipairs(context.notices) do
        assert(not string.find(notice.text, subject.preference, 1, true), notice.text)
    end
    local panel = fixture.instanceOf(context, subject.id)
    local module = fixture.module("panels/" .. subject.module .. ".lua")
    equal(panel.settings[subject.preference], true)
    equal(panel[subject.label].hidden, true, subject.module .. ": compact detail is quietly shed")
    for _ = 1, 2 do
        module.update(panel, { x = 0, y = 0, w = 238, h = 134 })
        module.refresh(panel)
        equal(panel[subject.label].hidden, false, subject.module .. ": detail returns when space permits")
        assert(panel[subject.text] ~= "", subject.module .. ": restored detail must be populated")
        module.update(panel, { x = 0, y = 0, w = 117, h = 65 })
        module.refresh(panel)
        equal(panel[subject.label].hidden, true, subject.module .. ": detail is shed again")
        equal(panel.settings[subject.preference], true, subject.module .. ": preference is preserved")
    end
end

-- Entering or leaving fullscreen keeps the zone, so only a panel under the
-- menu-button corner, whose reservation changes, is updated.
fixture.reset()
fixture.lvglMock.setFullScreen(false)
do
    local context = fixture.createLoaded(nil, { Layout = "Default", Theme = "modern-dark" })
    fixture.pump(context, 40)
    equal(#context.errors, 0, table.concat(context.errors, "; "))
    local updates, originals = {}, {}
    for _, entry in ipairs(context.panels) do
        local module, original = entry.module, entry.module.update
        if not originals[module] then
            originals[module] = original
            module.update = function(panel, ...)
                updates[panel] = (updates[panel] or 0) + 1
                return original(panel, ...)
            end
        end
    end
    for _, fullscreen in ipairs({ true, false }) do
        fixture.lvglMock.setFullScreen(fullscreen)
        local reserved = {}
        for _, entry in ipairs(context.panels) do
            reserved[entry] = entry.reserved
            updates[entry.instance] = 0
        end
        definition.refresh(context)
        local guard = 0
        while context.reflowIndex or context.hostKind do
            definition.refresh(context)
            guard = guard + 1
            assert(guard < 100, "reflow did not finish")
        end
        local corner = 0
        for _, entry in ipairs(context.panels) do
            local changed = (reserved[entry] == nil) ~= (entry.reserved == nil)
            corner = corner + (changed and 1 or 0)
            equal(updates[entry.instance], changed and 1 or 0, entry.placement.id .. ": fullscreen update")
        end
        equal(corner, 1, "one panel sits under the menu button")
    end
    for module, original in pairs(originals) do
        module.update = original
    end
end
