-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local host = fixture.createLoaded(nil, { Layout = "review-state", Theme = "modern-dark" })
fixture.pump(host, 60)
local function load(relative, ...)
    if string.sub(relative, 1, 9) == "@support/" then
        return assert(loadfile(root .. "/tests/support/" .. string.sub(relative, 10)))(...)
    end
    return fixture.module(relative, ...)
end
local sameTree = load("@support/panel_tree.lua")
local panelHost = fixture.module("lib/panel_host.lua")
for _, kind in ipairs({ "state", "metric", "link-status" }) do
    local cases = load("@support/reflow_cases.lua")(load, host, kind)
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
            local context = panel.create(
                lvgl.box({ x = 0, y = 0, w = 1000, h = 1000 }),
                case.rect,
                case.settings,
                case.dependencies()
            )
            completeTask(context)
            return context
        end
        local function finish(context, rect, done)
            for _ = 1, 10 do
                if done then
                    break
                end
                done = panel.reflow(context, rect, nil, nil, nil, false)
            end
            assert(done and not context.reflowWork, case.name)
        end
        for _, target in ipairs({ { x = 1, y = 2, w = 800, h = 480 }, { x = 3, y = 4, w = 90, h = 50 } }) do
            for _, event in ipairs({
                "complete",
                "resize",
                "implicit-resize",
                "in-place-resize",
                "update",
                "cancelRefresh",
                "reset",
            }) do
                for stop = 0, 20 do
                    local staged, synchronous = create(), create()
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
                    local rect = requested
                    if
                        event == "resize"
                        or event == "implicit-resize"
                        or event == "in-place-resize"
                        or event == "update"
                    then
                        rect = { x = 5, y = 6, w = case.rect.w, h = case.rect.h }
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
                    elseif event == "reset" then
                        local scheduler = host.schedulerHost
                        local entry = { module = panel, instance = staged, placement = { id = "subject", type = kind } }
                        local message = scheduler:resetPanelRelease(entry, getTime())
                        assert(not message and not entry.failed, message)
                        assert(staged.reflowWork.invalidated)
                    elseif event ~= "complete" then
                        panel[event](staged)
                        assert(staged.reflowWork.invalidated)
                    end
                    for _, context in ipairs({ staged, synchronous }) do
                        for _, feeds in ipairs(context.feeds or {}) do
                            for _, feed in ipairs(feeds) do
                                feed.value = not feed.value
                            end
                        end
                    end
                    finish(staged, rect, done)
                    assert(panel.reflow(staged, rect, nil, nil, nil, false), "completion is idempotent")
                    panel.update(synchronous, rect)
                    sameTree(synchronous.panel.root, staged.panel.root, case.name .. "/" .. event)
                    completeTask(staged)
                    completeTask(synchronous)
                    sameTree(synchronous.panel.root, staged.panel.root, case.name .. "/refreshed-" .. event)
                    checked = checked + 1
                end
            end
        end
    end
    print(
        kind
            .. " reflow: "
            .. #cases
            .. " legal span/theme/variant cases, "
            .. checked
            .. " completed and interrupted trees passed"
    )
end
