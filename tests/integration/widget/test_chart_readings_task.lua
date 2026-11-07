-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local chart = fixture.module("panels/chart.lua")
local panelHost = fixture.module("lib/panel_host.lua")
local dashboard = fixture.createLoaded(nil, { Layout = "review-chart", Theme = "modern-dark" })
local reference = assert(fixture.instanceOf(dashboard, "power"))
local function equal(actual, expected, path)
    if type(expected) ~= "table" then
        assert(actual == expected, path .. ": " .. tostring(actual) .. " ~= " .. tostring(expected))
        return
    end
    assert(type(actual) == "table", path)
    for key, value in pairs(expected) do
        equal(actual[key], value, path .. "." .. tostring(key))
    end
    for key in pairs(actual) do
        assert(expected[key] ~= nil, path .. ": unexpected " .. tostring(key))
    end
end
local function readings(panel)
    local result = {
        area = panel.area,
        font = panel.legendFont,
        extremaFont = panel.extremaFont,
        showExtrema = panel.showExtrema,
        legendWidth = panel.legendWidth,
        baseline = panel.legendBaseline,
        series = {},
    }
    for index, item in ipairs(panel.series) do
        local row = {}
        for _, name in ipairs({
            "readout",
            "valueText",
            "unitText",
            "minimumText",
            "maximumText",
            "valueX",
            "valueY",
            "valueWidth",
            "unitX",
            "unitY",
            "unitWidth",
            "nameX",
            "nameY",
            "nameWidth",
            "nameText",
            "extremaY",
            "readingRevision",
            "readingPrecision",
            "readingUnit",
        }) do
            row[name] = item[name]
        end
        for _, name in ipairs({ "name", "value", "unit", "extrema", "maximum", "minSymbol", "maxSymbol" }) do
            local properties = {}
            for key, value in pairs(item[name].properties) do
                if type(value) ~= "function" then
                    properties[key] = value
                end
            end
            row[name] = { properties = properties, hidden = item[name].hidden }
        end
        result.series[index] = row
    end
    return result
end
local function taskFor(panel)
    return panelHost.task({
        module = {
            decl = chart.readingDecl,
            step = chart.readingStep,
            stageOf = chart.readingStageOf,
        },
        instance = panel,
        interval = 10,
    })
end
local function advance(task)
    local delay = task:step(1, task.stage, getTime())
    assert(task.used <= 1)
    return delay
end
local function finish(task)
    for _ = 1, 30 do
        if advance(task) == 10 then
            return
        end
    end
    error("chart reading stages did not finish")
end

for _, rect in ipairs({
    { x = 0, y = 0, w = 480, h = 272 },
    { x = 0, y = 0, w = 800, h = 180 },
    { x = 0, y = 0, w = 160, h = 90 },
}) do
    for _, count in ipairs({ 0, 1, 3 }) do
        local metrics, feeds = {}, {}
        for index = 1, count do
            metrics[index] = { source = "Q" .. index, label = string.rep("LONG CAPTION ", 6), precision = 3 }
            feeds[index] = {
                revision = 1,
                value = -123456.789 * index,
                min = -987654.321,
                max = 1234567.89,
                unitText = "mAh",
                precision = 2,
                stale = index == 2,
            }
        end
        local settings = assert(panelHost.resolveSettings(chart, { metrics = metrics, label = "READINGS" }))
        local function create()
            local cursor = 0
            return chart.create(lvgl.box({ x = 0, y = 0, w = rect.w, h = rect.h }), rect, settings, {
                theme = reference.theme,
                themeBuilder = reference.themeBuilder,
                primitives = reference.primitives,
                state = function(state, accent)
                    return reference.themeBuilder.state(reference.theme, state, accent)
                end,
                history = {
                    session = function()
                        return { elapsed = 0, configured = true, available = true }
                    end,
                    subscribe = function()
                        cursor = cursor + 1
                        return feeds[cursor]
                    end,
                },
            })
        end
        local expectedPanel, panel = create(), create()
        local expectedTask, task = taskFor(expectedPanel), taskFor(panel)
        finish(expectedTask)
        local expected = readings(expectedPanel)
        assert(advance(task) == 1)
        if count == 3 then
            assert(panel.series[2].readingRevision == nil, "one grant changes at most one series")
        end
        for _, feed in ipairs(feeds) do
            feed.value, feed.min, feed.max, feed.revision = 42, -1, 100, 2
        end
        finish(task)
        equal(readings(panel), expected, "completed readings")
        finish(expectedTask)
        finish(task)
        equal(readings(panel), readings(expectedPanel), "next reading revision")
        assert(advance(task) == 10 and panel.readingWork == nil, "stable readings need no follow-on stages")

        for _, target in ipairs({ "measure", "layout", "font", "layout-final", "position" }) do
            local partial = create()
            local pending = taskFor(partial)
            partial.legendWidth = 0
            local stage = target == "layout-final" and "layout" or target
            for _ = 1, 20 do
                if pending.stage == stage and (target ~= "layout-final" or partial.readingWork.geometry) then
                    break
                end
                advance(pending)
            end
            assert(pending.stage == stage, "invalidation setup must reach " .. target)
            chart.update(partial, { x = 0, y = 0, w = 320, h = 200 })
            assert(partial.readingWork == nil)
            assert(pending:step(1, stage, getTime()) == 1 and pending.used == 0 and pending.stage == "readings")
            finish(pending)
            equal(partial.readingGeometry, partial.geometryVersion, "reflow restarts " .. target)
        end

        panel.readingGeometry = nil
        advance(task)
        chart.resetSession(panel)
        assert(panel.readingWork == nil, "session reset invalidates partial readings")
    end
end

print("Chart staged readings and geometry passed")
