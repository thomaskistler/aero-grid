-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local sameTree = assert(loadfile(root .. "/tests/support/panel_tree.lua"))()
local dashboard = fixture.createLoaded(nil, { Layout = "review-metric", Theme = "modern-dark" })
local reference = dashboard.panels[1].instance
local metric = fixture.module("panels/metric.lua")
local panelHost = fixture.module("lib/panel_host.lua")
local support = fixture.module("lib/services.lua")
local builder = reference.themeBuilder

for _, mode in ipairs({ "modern-dark", "modern-light" }) do
    local theme = builder.build(mode)
    for _, shape in ipairs({ { 1, 1, 117, 65 }, { 2, 2, 238, 134 }, { 4, 1, 480, 65 }, { 4, 4, 800, 480 } }) do
        for _, visual in ipairs({ "none", "bar", "radial" }) do
            local states, views, entries = {}, {}, {}
            for index = 1, 3 do
                states[index] = { value = index * 10, available = true, precision = 0, unitText = "V" }
                views["Q" .. index] = support.snapshot(states[index])
                entries[index] = { source = "Q" .. index, label = "Q" .. index, warning = 30, critical = 70 }
            end
            local settings = assert(panelHost.resolveSettings(metric, { metrics = entries, visual = visual }))
            local services = {
                theme = theme,
                themeBuilder = builder,
                primitives = reference.primitives,
                fonts = builder.typography(shape[1], shape[2]),
                span = { colSpan = shape[1], rowSpan = shape[2] },
                state = function(state, accent)
                    return builder.state(theme, state, accent)
                end,
                telemetry = {
                    subscribe = function(_, name)
                        return views[name]
                    end,
                },
            }
            local rect = { x = 0, y = 0, w = shape[3], h = shape[4] }
            local function create()
                local instance =
                    metric.create(lvgl.box({ x = 0, y = 0, w = rect.w, h = rect.h }), rect, settings, services)
                metric.refresh(instance)
                return instance
            end
            local legacy, instance = create(), create()
            local task = panelHost.task({ module = metric, instance = instance, interval = 20, nextRefresh = 0 })
            local function step()
                local delay = task:step(1, task.stage, getTime())
                assert(
                    instance.feed == views.Q1 and instance.detailFeed == views.Q2 and instance.secondaryFeed == views.Q3,
                    "a task must restore live subscriptions"
                )
                assert(task.used == 0 or task.used == 1)
                return delay
            end
            local function finish()
                for _ = 1, 8 do
                    if step() == 20 then
                        return
                    end
                end
                error("metric task did not finish")
            end
            for cycle = 0, 7 do
                for index, state in ipairs(states) do
                    state.value, state.precision = cycle * index * 12.345, cycle % 4
                    state.unitText = cycle % 2 == 0 and "mAh" or "V"
                    state.available, state.stale = cycle ~= 3, cycle == 5
                end
                metric.refresh(legacy)
                assert(step() == 1 and task.used == 1)
                local frozen = assert(instance.refreshWork)
                for _, state in ipairs(states) do
                    state.value, state.precision, state.unitText = -999, 3, "changed-after-capture"
                    state.available, state.stale = false, false
                end
                finish()
                assert(not instance.refreshWork and frozen.feed.value ~= states[1].value)
                sameTree(legacy.panel.root, instance.panel.root)
            end
            metric.refresh(legacy)
            finish()
            sameTree(legacy.panel.root, instance.panel.root)
            local writes = instance.value.writes
            assert(step() == 1 and task.stage == "render")
            assert(step() == 20 and instance.value.writes == writes, "a stable frame must not repaint")

            for _, target in ipairs({ "geometry", "layout", "render", "apply" }) do
                for _, state in ipairs(states) do
                    state.available, state.value = true, 12.5
                    state.precision = (instance.sampleDigits + 1) % 4
                    state.unitText = "m"
                end
                metric.refresh(legacy)
                for _ = 1, 5 do
                    if task.stage == target then
                        break
                    end
                    assert(step() == 1)
                end
                assert(task.stage == target and instance.refreshWork)
                local changed = { x = 0, y = 0, w = rect.w + 20, h = rect.h + 30 }
                metric.update(legacy, changed)
                metric.update(instance, changed)
                metric.refresh(legacy)
                assert(not instance.refreshWork)
                assert(
                    step() == 1 and task.used == 0 and task.stage == "prepare",
                    "reflow invalidates a planned refresh stage without charging work"
                )
                finish()
                sameTree(
                    legacy.panel.root,
                    instance.panel.root,
                    mode .. "/" .. shape[1] .. "x" .. shape[2] .. "/" .. visual .. "/" .. target
                )
            end

            states[1].value = 87.5
            metric.refresh(legacy)
            for _ = 1, 5 do
                if task.stage == "apply" then
                    break
                end
                assert(step() == 1)
            end
            assert(task.stage == "apply")
            metric.refresh(instance)
            sameTree(legacy.panel.root, instance.panel.root)
            assert(step() == 1 and task.used == 0, "legacy refresh invalidates a captured task frame")
            finish()

            states[1].value = 101
            for _ = 1, 5 do
                if task.stage == "apply" then
                    break
                end
                assert(step() == 1)
            end
            assert(task.stage == "apply")
            metric.setValue(legacy, 38, true)
            metric.setValue(instance, 38, true)
            sameTree(legacy.panel.root, instance.panel.root)
            assert(step() == 1 and task.used == 0, "a forced reading invalidates the captured frame")
            metric.refresh(legacy)
            finish()
            sameTree(legacy.panel.root, instance.panel.root)

            instance.feed, legacy.feed = nil, nil
            metric.refresh(legacy)
            assert(metric.step(instance, 1, "prepare") == nil and not instance.refreshWork)
            sameTree(legacy.panel.root, instance.panel.root)
            instance.feed, legacy.feed = views.Q1, views.Q1

            assert(step() == 1 and task.stage == "render")
            local render = metric.render
            metric.render = function()
                error("deliberate metric frame failure")
            end
            local ok, message = pcall(metric.step, instance, 1, "render")
            metric.render = render
            assert(not ok and string.find(message, "deliberate metric frame failure", 1, true))
            assert(
                instance.feed == views.Q1 and instance.detailFeed == views.Q2 and instance.secondaryFeed == views.Q3,
                "a failed frozen stage restores all live subscriptions before propagating its error"
            )
        end
    end
end
print("Metric task: frozen metadata/readings, complete legacy parity, stale plans and stable frames passed")
