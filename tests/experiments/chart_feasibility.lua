-- SPDX-License-Identifier: GPL-2.0-only

local root, kernel, recorded, scenarios, batch, profileEnabled, sampleTicks = ...
assert(root)
kernel = kernel or "combined"
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))().new()
local probe = assert(loadfile(root .. "/tests/support/chart_feasibility.lua"))()
local function load(path, ...)
    local base = string.sub(path, 1, 6) == "tests/" and root .. "/" or root .. "/src/WIDGETS/AeroGrid/"
    return assert(loadfile(base .. path))(...)
end
local prototype = recorded and load("tests/support/chart_mipmap_prototype.lua", load)
local definition = fixture.module("main.lua")
local rows = {}

for _, scenario in
    ipairs(scenarios or {
        { charts = 1, series = 1, points = 600, chunk = 1 },
        { charts = 1, series = 3, points = 600, chunk = 1 },
        { charts = 1, series = 3, points = 800, chunk = 1 },
        { charts = 1, series = 2, points = 240, chunk = 1 },
        { charts = 2, series = 2, points = 226, chunk = 1 },
    })
do
    fixture.reset()
    fixture.radio.rssi, fixture.radio.values[300] = 80, 1024
    local layout = { "version: 3", "grid:", "  columns: 4", "  rows: 4", "panels:" }
    for chart = 1, scenario.charts do
        layout[#layout + 1] = string.format(
            "  - id: chart%d\n    type: chart\n    col: %d\n    row: 0\n    colSpan: %d\n    rowSpan: %d\n"
                .. "    config:\n      armSwitch: SAv\n      metrics:",
            chart,
            (chart - 1) * 2,
            scenario.charts == 1 and 4 or 2,
            scenario.charts == 1 and 4 or 2
        )
        for series = 1, scenario.series do
            local id = 5000 + chart * 10 + series
            local name = "P" .. id
            fixture.radio.fields[name] = { id = id, name = name, unit = 1 }
            fixture.radio.values[id] = series * 20
            layout[#layout + 1] = "        - source: " .. name
        end
    end
    fixture.radioMock.indexFields()
    local path = root .. "/build/test-widget-fixture/"
    local file = assert(io.open(path .. "layouts/chart-feasibility.yaml", "w"))
    file:write(table.concat(layout, "\n") .. "\n")
    file:close()
    local context = fixture.createLoaded(
        { x = 0, y = 0, w = 480, h = 272 },
        { Layout = "chart-feasibility", Theme = "modern-dark" },
        path
    )
    local original = {}
    collectgarbage("collect")
    local memoryBefore, objectsBefore = collectgarbage("count"), #fixture.lvglMock.objects
    for _, entry in ipairs(context.panels) do
        local item
        if recorded then
            item = prototype.new(entry.instance, scenario.points)
            item.batch = batch or 130
            item.sampleTicks = scenario.sample_ticks or sampleTicks or 20
            item.scrollGaps = scenario.scroll_gaps
            item.live = scenario.continuous
        else
            item = probe.new(entry.instance, {
                points = scenario.points,
                chunkSize = scenario.chunk,
                overlays = 12,
                kernel = kernel,
            })
        end
        while not item:prepare() do
        end
        if recorded then
            assert(item.warmJobs == nil, "warm jobs must not retain retired level arrays")
        end
        entry.instance.feasibility = item
        if not original[entry.module] then
            original[entry.module] = entry.module.refresh
            entry.module.refresh = function(instance)
                return instance.feasibility:step()
            end
        end
    end
    collectgarbage("collect")
    local poolKiB, poolObjects = collectgarbage("count") - memoryBefore, #fixture.lvglMock.objects - objectsBefore
    for _, operation in ipairs(scenario.operations or { "append", "horizontal", "vertical", "scroll", "resize" }) do
        context.refreshOwner = nil
        for _, entry in ipairs(context.panels) do
            if recorded and operation == "scroll" then
                while not entry.instance.feasibility:prepareScroll() do
                end
                entry.instance.feasibility:verify()
            end
            entry.instance.feasibility:begin(operation)
            entry.nextRefresh = getTime()
        end
        local worst, callbacks = 0, 0
        local feeding = scenario.continuous
        local profile = {}
        repeat
            fixture.tick(16)
            fixture.lvglMock.setPropertyValidation(false)
            fixture.lvglMock.setCallCounting(false)
            fixture.lcdMock.setTextMeasurement(false)
            local instructions = 0
            local setterInstructions = 0
            local marks = {}
            if recorded and profileEnabled then
                for _, entry in ipairs(context.panels) do
                    local setter = entry.instance.feasibility.objects[1].set
                    local function measuredSet(object, changes)
                        local before = instructions
                        setter(object, changes)
                        setterInstructions = setterInstructions + instructions - before
                    end
                    for _, object in ipairs(entry.instance.feasibility.objects) do
                        rawset(object, "set", measuredSet)
                    end
                    entry.instance.feasibility.checkpoint = function(_, stage)
                        marks[#marks + 1] = { stage, instructions }
                    end
                end
            end
            debug.sethook(function()
                instructions = instructions + 100
            end, "", 100)
            if feeding then
                for _, entry in ipairs(context.panels) do
                    local item = entry.instance.feasibility
                    item:sample(math.max(item.clock, item.nextStamp) + 5)
                    item.admitted = true
                end
            end
            local ok, message = pcall(definition.refresh, context)
            debug.sethook()
            local setter = profile.mock_setter_body or { total = 0, worst = 0 }
            setter.total, setter.worst = setter.total + setterInstructions, math.max(setter.worst, setterInstructions)
            profile.mock_setter_body = setter
            local previous = 0
            for _, mark in ipairs(marks) do
                local name = mark[1] == "start" and "host_before_chart" or mark[1]
                local component = profile[name] or { total = 0, worst = 0 }
                local cost = mark[2] - previous
                component.total = component.total + cost
                component.worst = math.max(component.worst, cost)
                profile[name] = component
                previous = mark[2]
            end
            local host = profile.host_after_chart or { total = 0, worst = 0 }
            host.total, host.worst = host.total + instructions - previous, math.max(host.worst, instructions - previous)
            profile.host_after_chart = host
            fixture.lvglMock.setPropertyValidation(true)
            fixture.lvglMock.setCallCounting(true)
            fixture.lcdMock.setTextMeasurement(true)
            assert(ok, message)
            fixture.lvglMock.settle()
            assert(#context.errors == 0, table.concat(context.errors, "\n"))
            worst = math.max(worst, instructions)
            callbacks = callbacks + 1
            assert(callbacks <= 120, "synthetic job failed to drain")
            local active = false
            local completed = true
            for _, entry in ipairs(context.panels) do
                local item = entry.instance.feasibility
                active = active or item.active
                completed = completed and item.completedAt ~= nil
                if scenario.continuous then
                    for series, map in ipairs(item.maps) do
                        active = active or item.published[series].revision ~= map.revision
                    end
                end
            end
            if completed then
                feeding = false
            end
        until not active
        local maxMs, turns, submitted = 0, 0, 0
        for _, entry in ipairs(context.panels) do
            local item = entry.instance.feasibility
            local elapsed = (item.finishedAt - item.startedAt) * 10
            maxMs = math.max(maxMs, elapsed)
            turns = math.max(turns, item.turns)
            submitted = submitted + item.submitted
            local expected = 0
            if recorded then
                item:verify()
            end
            for _, index in ipairs(item.work or {}) do
                if not item.columns[index].gap then
                    expected = expected + 1
                end
                local column, changes = item.columns[index], item.changes[index]
                if operation ~= "vertical" then
                    assert(changes.x == math.floor(item.offset + column.x * item.scale), "projected x differs")
                end
                if operation ~= "scroll" then
                    local top = math.floor(item.bottom - column.high * item.height)
                    assert(changes.y == top, "projected top differs")
                    assert(
                        changes.h == math.floor(item.bottom - column.low * item.height) - top + 1,
                        "projected span differs"
                    )
                end
                if kernel ~= "mapping" then
                    local properties = item.objects[index].properties
                    for key, value in pairs(changes) do
                        assert(properties[key] == value, "setter did not copy projected coordinates")
                    end
                end
            end
            if not recorded then
                assert(
                    item.submitted == (kernel == "mapping" and 0 or expected),
                    "submit each non-gap column exactly once"
                )
            end
        end
        local incremental = operation == "append" or operation == "scroll"
        local turnLimit = incremental and (scenario.series == 1 and operation == "append" and 1 or 2) or 5
        local passed = worst < 15000
            and turns <= turnLimit
            and (incremental and maxMs < 500 or not incremental and maxMs <= 1000)
        rows[#rows + 1] = {
            charts = scenario.charts,
            series = scenario.series,
            points = scenario.points,
            chunk = scenario.chunk,
            operation = operation,
            kernel = kernel,
            instructions = worst,
            ms = maxMs,
            turns = turns,
            submitted = submitted,
            shifted = context.panels[1].instance.feasibility.shifted or 0,
            component_profile = profileEnabled and profile or {},
            profile_instrumented = profileEnabled == true,
            batch_per_series = batch or 130,
            sample_ticks = scenario.sample_ticks or sampleTicks or 20,
            passed = passed,
            pool_kib = poolKiB,
            pool_objects = poolObjects,
        }
        print(
            string.format(
                "FEASIBILITY charts=%d series=%d points=%d chunk=%d op=%s turns=%d host_callbacks=%d"
                    .. " max_ms=%d instructions=%d native_sets=%d gate=%s",
                scenario.charts,
                scenario.series,
                scenario.points,
                scenario.chunk,
                operation,
                turns,
                callbacks,
                maxMs,
                worst,
                submitted,
                passed and "PASS" or "FAIL"
            )
        )
        if recorded and profileEnabled then
            for _, stage in ipairs({
                "host_before_chart",
                "recording",
                "maintenance",
                "setup",
                "drawing",
                "host_after_chart",
                "mock_setter_body",
            }) do
                local cost = profile[stage] or { total = 0, worst = 0 }
                print(
                    string.format(
                        "COMPONENT op=%s stage=%s total=%d worst=%d",
                        operation,
                        stage,
                        cost.total,
                        cost.worst
                    )
                )
            end
        end
    end
    print(
        string.format(
            "WARM_POOLS charts=%d points=%d memory_kib=%.1f objects=%d",
            scenario.charts,
            scenario.points,
            poolKiB,
            poolObjects
        )
    )
    for module, refresh in pairs(original) do
        module.refresh = refresh
    end
end
return rows
