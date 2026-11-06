-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local sameTree = assert(loadfile(root .. "/tests/support/panel_tree.lua"))()
for _, kind in ipairs({ "chart", "navigation", "metric", "theme-showcase" }) do
    fixture.reset()
    local host = fixture.createLoaded(
        nil,
        { Layout = "review-" .. (kind == "theme-showcase" and "metric" or kind), Theme = "modern-dark" }
    )
    fixture.pump(host, 60, 10)
    local entry = host.panels[1]
    local module = kind == "theme-showcase" and fixture.module("panels/theme-showcase.lua") or entry.module
    local placement = { col = 0, row = 0, colSpan = 4, rowSpan = 4 }
    local services = host.dashboardLoader.buildServices(host, placement)
    local settings = kind == "theme-showcase" and {} or entry.settings
    local function create()
        return module.create(
            lvgl.box({ x = 0, y = 0, w = 800, h = 480 }),
            { x = 0, y = 0, w = 480, h = 272 },
            settings,
            services
        )
    end
    local function settle(context)
        if module.refresh then
            for _ = 1, 80 do
                module.refresh(context)
            end
        end
    end
    local function object(context)
        return context.root or context.panel.root
    end
    for restartAt = 0, 10 do
        local staged, synchronous = create(), create()
        settle(staged)
        settle(synchronous)
        local rect = { x = 0, y = 0, w = 640, h = 360 }
        if module.reflow then
            local done = module.reflow(staged, rect, settings, nil, placement, true)
            for advance = 1, 40 do
                if advance == restartAt then
                    rect = { x = 1, y = 2, w = 800, h = 480 }
                    done = module.reflow(staged, rect, settings, nil, placement, true)
                end
                if done then
                    break
                end
                done = module.reflow(staged, rect, settings, nil, placement, false)
                assert(type(done) == "boolean")
            end
            assert(done and not staged.reflowWork, kind .. ": geometry did not finish")
            assert(module.reflow(staged, rect, settings, nil, placement, false), "completion must be idempotent")
        else
            module.update(staged, rect, settings, nil, placement)
        end
        module.update(synchronous, rect, settings, nil, placement)
        settle(staged)
        settle(synchronous)
        sameTree(object(synchronous), object(staged))
    end
    for _, interruption in ipairs({ "update", "cancelRefresh", "resetSession" }) do
        if module[interruption] then
            local staged, synchronous = create(), create()
            settle(staged)
            settle(synchronous)
            local rect = { x = 1, y = 2, w = 640, h = 360 }
            assert(not module.reflow(staged, rect, settings, nil, placement, true))
            if interruption == "update" then
                rect = { x = 3, y = 4, w = 800, h = 480 }
                module.update(staged, rect, settings, nil, placement)
            elseif interruption == "resetSession" then
                for _, context in ipairs({ staged, synchronous }) do
                    for _ = 1, 200 do
                        local _, pending = module.resetSession(context, 1000)
                        if not pending then
                            break
                        end
                    end
                end
            else
                module.cancelRefresh(staged)
            end
            assert(
                staged.reflowWork and staged.reflowWork.invalidated,
                kind .. ": " .. interruption .. " must invalidate captured geometry"
            )
            local done
            for _ = 1, 40 do
                done = module.reflow(staged, rect, settings, nil, placement, false)
                if done then
                    break
                end
            end
            assert(done and not staged.reflowWork)
            module.update(synchronous, rect, settings, nil, placement)
            settle(staged)
            settle(synchronous)
            sameTree(object(synchronous), object(staged))
        end
    end
end

fixture.reset()
local host = fixture.createLoaded(nil, { Layout = "review-chart", Theme = "modern-dark" })
fixture.pump(host, 40, 10)
local lifecycle = host.dashboardLifecycle
host.zone = { x = 0, y = 0, w = 640, h = 360 }
lifecycle.beginReflow(host)
assert(lifecycle.advanceReflow(host) and host.reflowEntry, "large geometry must retain a continuation")
host.zone = { x = 0, y = 0, w = 800, h = 480 }
lifecycle.beginReflow(host)
assert(not host.reflowEntry, "a new zone invalidates the previous continuation")
for _ = 1, 40 do
    if not lifecycle.advanceReflow(host) then
        break
    end
end
assert(not host.reflowIndex and not host.reflowEntry)
local entry = host.panels[1]
local original = entry.module.reflow
entry.module.reflow = function()
    return nil
end
lifecycle.beginReflow(host)
lifecycle.advanceReflow(host)
entry.module.reflow = original
assert(entry.failed and string.find(entry.error, "reflow must return a boolean", 1, true))
for _ = 1, 20 * #host.panels do
    if not host.reflowIndex or not lifecycle.advanceReflow(host) then
        break
    end
end
assert(not host.reflowIndex and #host.errors > 0, "a failed reflow must report and retire, not loop")
print("Panel reflow: completed geometry parity, interrupted zones and callback failures passed")
