-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))().new()
local equal = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual
local editor = fixture.module("lib/editor.lua")

local variants = {
    ["flight-mode"] = { { showIndex = true } },
    ["flight-counter"] = { { history = false } },
    ["model-identity"] = { { presentation = "name", showLabels = true }, { presentation = "both" } },
    navigation = { { showCoordinates = true, showSatellites = true }, { showTape = true } },
    metric = {
        { metrics = { { source = "Alt", label = "ALT" } }, visual = "bar" },
        { metrics = { { source = "Alt", label = "ALT" } }, visual = "radial" },
    },
    ["rx-battery"] = {
        { visual = "bar", showDelta = true },
        { visual = "battery" },
        { visual = "none", showDelta = true },
    },
    ["tx-battery"] = {
        { visual = "bar", showPercent = true },
        { visual = "battery", showPercent = true },
        { visual = "none", showPercent = true },
    },
}

local function checkPanel(context, description)
    equal(#context.errors, 0, description .. ": " .. table.concat(context.errors, "; "))
    equal(#context.panels, 1, description)
    local entry = context.panels[1]
    assert(not entry.failed, description .. ": " .. tostring(entry.error))
    local panel = entry.instance
    local rect = context.dashboardLoader.panelRect(context, entry.placement)
    equal(panel.panel.width, rect.w, description .. ": reflow width")
    equal(panel.panel.height, rect.h, description .. ": reflow height")
    if panel.value and not panel.value.hidden then
        local value = panel.value.properties
        local font = value.font
        assert(
            value.x >= 0 and value.x + value.w <= rect.w,
            description
                .. ": reading exceeds panel width: "
                .. tostring(value.text)
                .. " x="
                .. value.x
                .. " w="
                .. value.w
                .. " panel="
                .. rect.w
        )
        assert(value.y >= 0, description .. ": reading starts above panel")
        assert(value.y + panel.themeBuilder.fontAscent(font) <= rect.h, description .. ": reading exceeds panel height")
    end
    if panel.indicators then
        for _, indicator in ipairs(panel.indicators) do
            local bar = indicator.bar
            assert(bar.w > 0 and bar.h > 0, description .. ": empty trim bar")
            assert(bar.x >= 0 and bar.x + bar.w <= rect.w, description .. ": trim bar exceeds panel width")
            assert(bar.y >= 0 and bar.y + bar.h <= rect.h, description .. ": trim bar exceeds panel height")
        end
    end
    if panel.area.showTape then
        local area = panel.area
        assert(area.tapeWidth >= 54 and area.tapeHeight > 0, description .. ": unusable bearing tape")
        assert(area.tapeX >= 0 and area.tapeX + area.tapeWidth <= rect.w, description .. ": tape exceeds width")
        assert(area.tapeY >= 0 and area.tapeY + area.tapeHeight <= rect.h, description .. ": tape exceeds height")
    end
end

local checked = 0
local function exercise(typeName, config, columns, rows, fullscreen, col, row)
    fixture.reset()
    fixture.lvglMock.setAppMode(true)
    fixture.lvglMock.setFullScreen(fullscreen)
    local context = fixture.createLoaded(nil, { Layout = "Empty", Theme = "modern-dark" })
    local placement = {
        id = "subject",
        type = typeName,
        col = col,
        row = row,
        colSpan = columns,
        rowSpan = rows,
        config = editor.clone(config),
    }
    local built, buildError = context.dashboardLoader.buildPanel(context, placement, nil, true)
    assert(built, typeName .. ": " .. tostring(buildError))
    context.document.panels = { placement }
    for _, size in ipairs({ { 480, 272 }, { 320, 240 }, { 800, 480 }, { 480, 272 } }) do
        context.zone.w, context.zone.h = size[1], size[2]
        fixture.pump(context, 100)
        checkPanel(
            context,
            string.format(
                "%s %dx%d at %d,%d @ %dx%d fullscreen=%s",
                typeName,
                columns,
                rows,
                col,
                row,
                size[1],
                size[2],
                tostring(fullscreen)
            )
        )
        checked = checked + 1
    end
end

for _, catalog in ipairs(editor.CATALOG) do
    if catalog.type ~= "host-diagnostics" and catalog.type ~= "service-probe" then
        for _, config in ipairs(variants[catalog.type] or { {} }) do
            for rows = 1, 4 do
                for columns = 1, 4 do
                    for _, fullscreen in ipairs({ false, true }) do
                        exercise(catalog.type, config, columns, rows, fullscreen, 4 - columns, 4 - rows)
                        if rows >= 3 and (columns < 4 or rows < 4) then
                            exercise(catalog.type, config, columns, rows, fullscreen, 0, 0)
                        end
                    end
                end
            end
        end
    end
end
assert(checked >= 12 * 16 * 2 * 4, "missing regular panel span coverage")
fixture.lvglMock.setAppMode(false)
fixture.lvglMock.setFullScreen(false)
