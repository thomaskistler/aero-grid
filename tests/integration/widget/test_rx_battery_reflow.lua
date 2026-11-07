-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local sameTree = assert(loadfile(root .. "/tests/support/panel_tree.lua"))()
local host = fixture.createLoaded(nil, { Layout = "review-rx-battery", Theme = "modern-dark" })
local panelHost = fixture.module("lib/panel_host.lua")
fixture.pump(host, 60)
local cases =
    assert(loadfile(root .. "/tests/support/construction_cases.lua"))()(fixture.module, host.themeBuilder, "rx-battery")
local checked = 0
for _, case in ipairs(cases) do
    local panel = case.panel
    local function completeTask(instance)
        local task = panelHost.task({ module = panel, instance = instance, interval = 20 })
        for _ = 1, 100 do
            if task:step(task.want or 1, task.stage, getTime()) ~= 1 then return end
        end
        error(case.name .. ": panel task did not finish")
    end
    local function create()
        local context =
            panel.create(lvgl.box({ x = 0, y = 0, w = 1000, h = 1000 }), case.rect, case.settings, case.dependencies())
        completeTask(context)
        return context
    end
    local function finish(context, rect, done)
        for _ = 1, 40 do
            if done then
                break
            end
            done = panel.reflow(context, rect, nil, nil, nil, false)
            assert(type(done) == "boolean", case.name)
        end
        assert(done and not context.reflowWork, case.name .. ": reflow must finish")
        assert(panel.reflow(context, rect, nil, nil, nil, false), "completed reflow must be idempotent")
    end
    local staged, synchronous = create(), create()
    local targets = {
        case.rect,
        { x = 1, y = 2, w = case.rect.w + 60, h = case.rect.h + 80 },
        { x = 3, y = 4, w = 90, h = 50 },
    }
    for _, rect in ipairs(targets) do
        local feed, estimate = staged.feed, staged.estimatedCells
        staged.feed = setmetatable({}, {
            __index = function()
                error("geometry must not read or advance telemetry")
            end,
        })
        finish(staged, rect, panel.reflow(staged, rect, nil, nil, nil, true))
        staged.feed = feed
        assert(staged.estimatedCells == estimate, "reflow must not change count estimation")
        panel.update(synchronous, rect)
        sameTree(synchronous.panel.root, staged.panel.root, case.name .. "/completed")
        completeTask(staged)
        completeTask(synchronous)
        sameTree(synchronous.panel.root, staged.panel.root, case.name .. "/refreshed")
        checked = checked + 1
    end
    for _, target in ipairs({ targets[2], targets[3] }) do
        for _, event in ipairs({
            "resize",
            "implicit-resize",
            "in-place-resize",
            "update",
            "cancelRefresh",
            "resetSession",
        }) do
            for stop = 0, 10 do
                staged, synchronous = create(), create()
                local requested = { x = target.x, y = target.y, w = target.w, h = target.h }
                local done = panel.reflow(staged, requested, nil, nil, nil, true)
                for _ = 1, stop do
                    done = panel.reflow(staged, requested, nil, nil, nil, false)
                    if done then
                        break
                    end
                end
                if done then
                    break
                end
                local rect = target
                if
                    event == "resize"
                    or event == "implicit-resize"
                    or event == "in-place-resize"
                    or event == "update"
                then
                    rect = target == targets[3] and targets[2] or targets[3]
                    if event == "resize" then
                        done = panel.reflow(staged, rect, nil, nil, nil, true)
                    elseif event == "in-place-resize" then
                        for key, value in pairs(rect) do
                            requested[key] = value
                        end
                        rect = requested
                    elseif event == "update" then
                        panel.update(staged, rect)
                        assert(staged.reflowWork.invalidated)
                    end
                else
                    panel[event](staged, 1000)
                    if event == "resetSession" then
                        panel.resetSession(synchronous, 1000)
                    end
                    assert(staged.reflowWork.invalidated, event .. " must invalidate captured geometry")
                end
                finish(staged, rect, done)
                panel.update(synchronous, rect)
                sameTree(synchronous.panel.root, staged.panel.root, case.name .. "/" .. event .. "/" .. stop)
                completeTask(staged)
                completeTask(synchronous)
                sameTree(synchronous.panel.root, staged.panel.root, case.name .. "/after-" .. event .. "/" .. stop)
                checked = checked + 1
            end
        end
    end
end
print(
    "RX Battery reflow: "
        .. #cases
        .. " span/theme/visual/data cases, "
        .. checked
        .. " completed and interrupted trees passed"
)
