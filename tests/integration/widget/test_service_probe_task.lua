-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local sameTree = assert(loadfile(root .. "/tests/support/panel_tree.lua"))()
local dashboard = fixture.createLoaded(nil, { Layout = "review-metric", Theme = "modern-dark" })
local reference = dashboard.panels[1].instance
local panel = fixture.module("panels/service-probe.lua")
local host = fixture.module("lib/panel_host.lua")
local builder = reference.themeBuilder
local serviceFor = assert(loadfile(root .. "/tests/support/scheduler_probe_fixture.lua"))()(fixture.module)
local frames = 0

for _, mode in ipairs({ "modern-dark", "modern-light" }) do
    local theme = builder.build(mode)
    for _, shape in ipairs({
        { 2, 2, 238, 134 },
        { 4, 2, 480, 134 },
        { 4, 4, 800, 480 },
        { 1, 1, 117, 12 },
    }) do
        for _, name in ipairs({ "telemetry", "model", "control", "navigation" }) do
            for variant = 1, 4 do
                local service, change = serviceFor(name, variant)
                local settings = assert(host.resolveSettings(panel, { service = name, source = "SOURCE" }))
                local services = {
                    theme = theme,
                    themeBuilder = builder,
                    primitives = reference.primitives,
                    fonts = builder.typography(shape[1], shape[2]),
                    [name] = service,
                    state = function(state, accent)
                        return builder.state(theme, state, accent)
                    end,
                }
                local rect = { x = 0, y = 0, w = shape[3], h = shape[4] }
                local function create()
                    local context =
                        panel.create(lvgl.box({ x = 0, y = 0, w = rect.w, h = rect.h }), rect, settings, services)
                    if variant == 3 then
                        context.service = nil
                    elseif variant == 4 then
                        context.subscribeError = true
                    end
                    return context
                end
                local expected, instance = create(), create()
                local expectedTask = host.task({ module = panel, instance = expected, interval = 50 })
                local function finishExpected()
                    for _ = 1, 160 do
                        if expectedTask:step(expectedTask.want or 1, expectedTask.stage, getTime()) == 50 then return end
                    end
                    error("Service Probe comparison did not finish")
                end
                local task = host.task({ module = panel, instance = instance, interval = 50 })
                local function writes()
                    local total = 0
                    for index = 1, #instance.keys do
                        total = total + (instance.keys[index].writes or 0) + (instance.values[index].writes or 0)
                    end
                    return total
                end
                local function step(grant)
                    local delay = task:step(grant or 1, task.stage, getTime())
                    assert(task.used >= 0 and task.used <= (grant or 1))
                    return delay
                end
                local function finish(grant)
                    for _ = 1, 160 do
                        if step(grant) == 50 then
                            assert(not instance.refreshWork)
                            return
                        end
                    end
                    error("Service Probe did not finish")
                end
                for cycle = 1, 8 do
                    change(cycle)
                    finishExpected()
                    assert(step() == 1)
                    while task.stage == "describe" do
                        assert(step() == 1)
                    end
                    change(99)
                    finish(cycle % 2 + 1)
                    sameTree(expected.panel.root, instance.panel.root)
                    change(cycle)
                    local calls = writes()
                    finish(2)
                    assert(writes() == calls, "stable probe repainted")
                    frames = frames + 1
                end
                for _, target in ipairs({ "describe", "apply" }) do
                    if target ~= "describe" or name == "control" and variant <= 2 then
                        for _, action in ipairs({ "cancelRefresh", "update" }) do
                            change(1)
                            assert(step() == 1)
                            assert(task.stage == target or task.stage == "describe")
                            while task.stage ~= target do
                                assert(step() == 1)
                            end
                            if target == "describe" and variant == 2 and instance.visibleRows > 0 then
                                for _ = 1, 64 do
                                    assert(step() == 1 and task.stage == "describe")
                                end
                            end
                            if target == "apply" and instance.visibleRows > 1 then
                                assert(step() == 1)
                            end
                            change(2)
                            if action == "update" then
                                panel.update(instance, rect)
                                panel.update(expected, rect)
                            else
                                panel[action](instance)
                            end
                            assert(not instance.refreshWork)
                            assert(step() == 1 and task.used == 0 and task.stage == "prepare")
                            finishExpected()
                            finish(1)
                            sameTree(expected.panel.root, instance.panel.root)
                        end
                    end
                end
                local calls = writes()
                local scheduler = fixture.module("lib/scheduler.lua").new({ steady = 1250, background = 1130 })
                assert(scheduler:add({ id = "probe", decl = panel.decl, instance = task, due = 700 }))
                scheduler:run("background", 700, 0)
                assert(not instance.refreshWork and writes() == calls)
                assert(panel.decl.kinds.steady and not panel.decl.kinds["editor-build"])
                local before = instance.refreshWork
                panel.step(instance, 0, panel.stageOf(instance))
                assert(instance.used == 0 and instance.refreshWork == before)
                if name == "control" and variant == 1 then
                    assert(step() == 1 and task.stage == "describe")
                    service.describeStep = function()
                        error("deliberate probe description failure")
                    end
                    local ok, message = pcall(step)
                    service.describeStep = nil
                    assert(not ok and string.find(message, "deliberate probe description failure", 1, true))
                    assert(task.entry.failed)
                end
            end
        end
    end
end
assert(frames == 1024)
print(
    "Service Probe task: " .. frames .. " changing frames, captured rows, partial grants, cancellation and eligibility"
)
