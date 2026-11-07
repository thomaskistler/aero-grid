-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local sameTree = assert(loadfile(root .. "/tests/support/panel_tree.lua"))()
local dashboard = fixture.createLoaded(nil, { Layout = "review-metric", Theme = "modern-dark" })
local reference = dashboard.panels[1].instance
local panel = fixture.module("panels/host-diagnostics.lua")
local host = fixture.module("lib/panel_host.lua")
local builder = reference.themeBuilder
local hostFor = assert(loadfile(root .. "/tests/support/scheduler_diagnostics_fixture.lua"))()(fixture.module)
local frames = 0

for _, mode in ipairs({ "modern-dark", "modern-light" }) do
    local theme = builder.build(mode)
    for _, shape in ipairs({
        { 2, 2, 238, 134 },
        { 4, 2, 480, 134 },
        { 4, 4, 800, 480 },
        { 1, 1, 117, 12 },
    }) do
        for _, section in ipairs({ "identity", "theme", "panels", "sources", "log" }) do
            for variant = 1, 4 do
                local reportHost, change = hostFor(section, variant)
                local expectedHost, expectedChange = hostFor(section, variant)
                local settings = assert(host.resolveSettings(panel, { section = section }))
                local rect = { x = 0, y = 0, w = shape[3], h = shape[4] }
                local function create(report)
                    return panel.create(lvgl.box({ x = 0, y = 0, w = rect.w, h = rect.h }), rect, settings, {
                        theme = theme,
                        themeBuilder = builder,
                        primitives = reference.primitives,
                        fonts = builder.typography(shape[1], shape[2]),
                        host = report,
                        state = function(state, accent)
                            return builder.state(theme, state, accent)
                        end,
                    })
                end
                local expected, instance = create(expectedHost), create(reportHost)
                local task = host.task({ module = panel, instance = instance, interval = 50 })
                local expectedTask = host.task({ module = panel, instance = expected, interval = 50 })
                local function finishExpected()
                    for _ = 1, 1200 do
                        if expectedTask:step(expectedTask.want or 1, expectedTask.stage, getTime()) == 50 then return end
                    end
                    error("Host Diagnostics comparison did not finish")
                end
                local function step(grant)
                    local delay = task:step(grant or 1, task.stage, getTime())
                    assert(task.used >= 0 and task.used <= (grant or 1))
                    return delay
                end
                local function finish(grant)
                    for _ = 1, 1200 do
                        if step(grant) == 50 then
                            assert(not instance.refreshWork)
                            return
                        end
                    end
                    error("Host Diagnostics did not finish")
                end
                local function writes()
                    local total = 0
                    for _, row in ipairs(instance.rows) do
                        total = total + (row.writes or 0)
                    end
                    return total
                end
                local function settle()
                    for _ = 1, 4 do
                        finishExpected()
                        finish(3)
                    end
                    sameTree(expected.panel.root, instance.panel.root)
                end
                settle()
                for cycle = 1, 8 do
                    change(cycle)
                    expectedChange(cycle)
                    finishExpected()
                    assert(step() == 1)
                    for _ = 1, 1200 do
                        if task.stage == "apply" then
                            break
                        end
                        assert(step() == 1)
                    end
                    assert(task.stage == "apply")
                    change(99)
                    finish(cycle % 3 + 1)
                    sameTree(expected.panel.root, instance.panel.root)
                    change(cycle)
                    settle()
                    local before = writes()
                    finish(3)
                    assert(writes() == before, "stable diagnostics repainted")
                    frames = frames + 1
                end
                for _, target in ipairs({ "collect", "finish", "apply" }) do
                    local collects = section == "panels" and variant ~= 4
                        or (section == "theme" or section == "sources") and variant <= 2
                        or section == "log" and variant ~= 3
                    if target ~= "collect" or collects then
                        for _, action in ipairs({ "cancelRefresh", "update" }) do
                            change(1)
                            expectedChange(1)
                            assert(step() == 1)
                            for _ = 1, 1200 do
                                if task.stage == target then
                                    break
                                end
                                assert(step() == 1)
                            end
                            assert(task.stage == target)
                            if target == "collect" and variant == 2 and section ~= "theme" then
                                for _ = 1, 8 do
                                    assert(step() == 1 and task.stage == "collect")
                                end
                            elseif target == "apply" and instance.visibleLines > 1 then
                                assert(step() == 1)
                            end
                            change(2)
                            expectedChange(2)
                            if action == "update" then
                                panel.update(instance, rect)
                                panel.update(expected, rect)
                            else
                                panel[action](instance)
                            end
                            assert(not instance.refreshWork)
                            assert(step() == 1 and task.used == 0 and task.stage == "prepare")
                            settle()
                        end
                    end
                end
                local before = writes()
                local scheduler = fixture.module("lib/scheduler.lua").new({ steady = 1250, background = 1130 })
                assert(scheduler:add({ id = "diagnostics", decl = panel.decl, instance = task, due = 700 }))
                scheduler:run("background", 700, 0)
                assert(not instance.refreshWork and writes() == before)
                panel.step(instance, 0, panel.stageOf(instance))
                assert(instance.used == 0 and not instance.refreshWork)
                if section == "sources" and variant == 1 then
                    reportHost.serviceRuntime.byId.telemetry.entries[1] = false
                    finish(1)
                    assert(instance.texts[1] == "report failed:" or instance.visibleLines == 0)
                    assert(not task.entry.failed, "report errors must remain visible, not disable diagnostics")
                end
            end
        end
    end
end
assert(frames == 1280)
print("Host Diagnostics task: " .. frames .. " changing frames, bounded reports, log snapshots and partial grants")
