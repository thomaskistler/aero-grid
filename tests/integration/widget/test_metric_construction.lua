-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local sameTree = assert(loadfile(root .. "/tests/support/panel_tree.lua"))()
local context = fixture.createLoaded(nil, { Layout = "review-metric", Theme = "modern-dark" })
fixture.pump(context, 40)
assert(#context.errors == 0, table.concat(context.errors, "\n"))
local metric = fixture.module("panels/metric.lua")
local host = fixture.module("lib/panel_host.lua")
local builder = context.panels[1].instance.themeBuilder

local function finishTask(instance)
    local task = host.task({ module = metric, instance = instance, interval = 20 })
    for now = 1, 100 do
        if task:step(task.want or 1, task.stage, now) ~= 1 then return end
    end
    error("metric task did not finish")
end

for _, mode in ipairs({ "modern-dark", "modern-light" }) do
    local theme = builder.build(mode)
    for _, shape in ipairs({ { 1, 1, 117, 65 }, { 4, 1, 480, 65 }, { 2, 2, 238, 134 } }) do
        for _, count in ipairs({ 0, 1, 3 }) do
            for _, visual in ipairs({ "none", "bar", "radial" }) do
                local entries = {}
                for index = 1, count do
                    entries[index] = { source = "Alt", label = "ALT", unit = "m", precision = 2 }
                end
                local config = assert(host.resolveSettings(metric, { metrics = entries, visual = visual }))
                local dependencies = {
                    theme = theme,
                    themeBuilder = builder,
                    primitives = fixture.module("lib/primitives.lua"),
                    fonts = builder.typography(shape[1], shape[2]),
                    span = { colSpan = shape[1], rowSpan = shape[2] },
                    telemetry = context.serviceRuntime.byId.telemetry,
                    state = function(state, accent)
                        return builder.state(theme, state, accent)
                    end,
                }
                local rect = { x = 0, y = 0, w = shape[3], h = shape[4] }
                local function create(staged)
                    dependencies.staged = staged
                    return metric.create(lvgl.box({ x = 0, y = 0, w = rect.w, h = rect.h }), rect, config, dependencies)
                end
                local synchronous, staged = create(false), create(true)
                assert(staged.createStage == "frame" and not staged.panel)
                assert(not metric.construct(staged, rect) and staged.createStage == "geometry" and not staged.panel)
                assert(not metric.construct(staged, rect) and staged.createStage == "header" and not staged.panel)
                assert(not metric.construct(staged, rect) and staged.createStage == "controls" and staged.panel)
                assert(metric.construct(staged, rect))
                assert(not staged.createParent and not staged.createPresentation and not staged.createStage)
                assert(metric.construct(staged, rect), "completed construction is idempotent")
                sameTree(synchronous.panel.root, staged.panel.root)
                finishTask(synchronous)
                finishTask(staged)
                sameTree(synchronous.panel.root, staged.panel.root)

                for _, resizeAt in ipairs({ "frame", "geometry", "header", "controls", "reflow", "place", "publish" }) do
                    for _, event in ipairs({ "cancelRefresh", "update" }) do
                        local partial = create(true)
                        local changed = { x = 1, y = 2, w = rect.w + 20, h = rect.h + 30 }
                        if resizeAt == "reflow" or resizeAt == "place" or resizeAt == "publish" then
                            while partial.createStage ~= "controls" do
                                assert(not metric.construct(partial, rect))
                            end
                            assert(not metric.construct(partial, changed) and partial.createStage == "reflow")
                            while partial.createStage ~= resizeAt do
                                assert(not metric.construct(partial, changed))
                            end
                            changed = { x = 3, y = 4, w = rect.w + 40, h = rect.h + 60 }
                        else
                            while partial.createStage ~= resizeAt do
                                assert(not metric.construct(partial, rect))
                            end
                        end
                        metric[event](partial, changed)
                        local done = false
                        for _ = 1, 8 do
                            done = metric.construct(partial, changed)
                            assert(type(done) == "boolean")
                            if done then
                                break
                            end
                        end
                        assert(done and not partial.createStage and not partial.createParent)
                        assert(partial.panel.root.properties.w == changed.w)
                        assert(partial.panel.root.properties.h == changed.h)
                        finishTask(partial)
                        if partial.unit and not partial.unit.hidden then
                            assert(partial.unit.properties.font() == partial.area.unitFont)
                        end
                    end
                end
            end
        end
    end
end
print("Metric construction: staged output parity, every pending resize and completion passed")
