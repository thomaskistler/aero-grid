-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local host = fixture.createLoaded(nil, { Layout = "review-state", Theme = "modern-dark" })
local function load(relative, ...)
    if string.sub(relative, 1, 9) == "@support/" then
        return assert(loadfile(root .. "/tests/support/" .. string.sub(relative, 10)))(...)
    end
    return fixture.module(relative, ...)
end
local sameTree, panelHost = load("@support/panel_tree.lua"), load("lib/panel_host.lua")
local checked = 0
for _, kind in ipairs({ "state", "metric", "link-status", "rx-battery" }) do
    local cases = kind == "rx-battery"
        and load("@support/construction_cases.lua")(load, host.themeBuilder, kind)
        or load("@support/reflow_cases.lua")(load, host, kind)
    local representatives = {}
    for _, case in ipairs(cases) do
        local panel = case.panel
        local function refresh(instance)
            local task = panelHost.task({ module = panel, instance = instance, interval = 20 })
            for _ = 1, 256 do
                if task:step(task.want or 1, task.stage, getTime()) ~= 1 then return end
            end
            error(case.name .. ": refresh did not finish")
        end
        local function create()
            local instance = panel.create(
                lvgl.box({ x = 0, y = 0, w = 1000, h = 1000 }),
                case.rect, case.settings, case.dependencies())
            refresh(instance)
            return instance
        end
        local function finish(instance, rect, done)
            for _ = 1, 256 do
                if done then break end
                done = panel.reflow(instance, rect, nil, nil, nil, false)
                assert(type(done) == "boolean", case.name)
            end
            assert(done and not instance.reflowWork, case.name .. ": reflow did not finish")
            assert(panel.reflow(instance, rect, nil, nil, nil, false), "completion must be idempotent")
        end
        local function compare(staged, synchronous, rect, done)
            local feed, estimate = staged.feed, staged.estimatedCells
            if kind == "rx-battery" then
                staged.feed = setmetatable({}, { __index = function()
                    error("geometry must not read or advance telemetry")
                end })
            end
            finish(staged, rect, done)
            staged.feed = feed
            assert(staged.estimatedCells == estimate, "geometry must preserve cell estimation")
            panel.update(synchronous, rect)
            sameTree(synchronous.panel.root, staged.panel.root, case.name)
            refresh(staged)
            refresh(synchronous)
            sameTree(synchronous.panel.root, staged.panel.root, case.name .. "/refreshed")
            checked = checked + 1
        end
        local large, small = { x = 1, y = 2, w = 800, h = 480 }, { x = 3, y = 4, w = 90, h = 50 }
        local staged, synchronous = create(), create()
        compare(staged, synchronous, large, panel.reflow(staged, large, nil, nil, nil, true))
        compare(staged, synchronous, small, panel.reflow(staged, small, nil, nil, nil, true))

        -- Each interruption boundary is independent of the exhaustive span matrix.
        local signature = string.gsub(case.name, "/%dx%d/", "/")
        if not representatives[signature] then
            representatives[signature] = true
            for _, event in ipairs({
                "resize", "implicit-resize", "in-place-resize", "update", "cancelRefresh",
                kind == "rx-battery" and "resetSession" or "reset",
            }) do
                for stop = 0, 20 do
                    staged, synchronous = create(), create()
                    local requested = { x = large.x, y = large.y, w = large.w, h = large.h }
                    local done = panel.reflow(staged, requested, nil, nil, nil, true)
                    for _ = 1, stop do
                        if done then break end
                        done = panel.reflow(staged, requested, nil, nil, nil, false)
                    end
                    if done then break end
                    local rect = requested
                    if event == "resize" then
                        rect = small
                        done = panel.reflow(staged, rect, nil, nil, nil, true)
                    elseif event == "implicit-resize" then
                        rect = small
                    elseif event == "in-place-resize" then
                        for key, value in pairs(small) do requested[key] = value end
                    elseif event == "update" then
                        rect = small
                        panel.update(staged, rect)
                        assert(staged.reflowWork.invalidated)
                    elseif event == "reset" then
                        local entry = { module = panel, instance = staged,
                            placement = { id = "subject", type = kind } }
                        local message = host.schedulerHost:resetPanelRelease(entry, getTime())
                        assert(not message and not entry.failed, message)
                        assert(staged.reflowWork.invalidated)
                    else
                        panel[event](staged, 1000)
                        if event == "resetSession" then panel.resetSession(synchronous, 1000) end
                        assert(staged.reflowWork.invalidated)
                    end
                    for _, instance in ipairs({ staged, synchronous }) do
                        for _, feeds in ipairs(instance.feeds or {}) do
                            for _, feed in ipairs(feeds) do feed.value = not feed.value end
                        end
                    end
                    compare(staged, synchronous, rect, done)
                end
            end
        end
    end
end
print("Panel reflow: " .. checked .. " span/variant trees and independent interruption boundaries passed")
