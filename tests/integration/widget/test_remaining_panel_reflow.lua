-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local sameTree = assert(loadfile(root .. "/tests/support/panel_tree.lua"))()
local hostModule = fixture.module("lib/panel_host.lua")
local checked = 0

for _, theme in ipairs({ "modern-dark", "modern-light" }) do
    fixture.reset()
    local host = fixture.createLoaded(nil, { Layout = "review-tx-battery", Theme = theme })
    fixture.pump(host, 60, 10)
    local placement = { col = 0, row = 0, colSpan = 4, rowSpan = 4 }
    local services = host.dashboardLoader.buildServices(host, placement)
    for _, kind in ipairs({ "output", "tx-battery" }) do
        local module = fixture.module("panels/" .. kind .. ".lua")
        for variant = 1, 12 do
            local settings = assert(hostModule.resolveSettings(module, kind == "output" and {
                firstChannel = variant % 6 == 0 and 32 or variant % 6 == 5 and 17 or 1,
                channelCount = 32,
                showNames = variant ~= 2,
                showTrim = variant ~= 3,
            } or {
                visual = ({ "battery", "bar", "none" })[(variant - 1) % 3 + 1],
                showPercent = variant <= 3 or variant >= 7 and variant <= 9,
                packEmpty = variant <= 3 and 6.4 or nil,
                packFull = variant <= 3 and 8.4 or nil,
                warning = 7.5,
                critical = 6.5,
            }))
            local feeds = {}
            for channel = 0, 31 do
                feeds[channel] = {
                    available = variant ~= 4,
                    nameReady = variant ~= 5,
                    name = channel % 2 == 0 and "WWWW long channel" or "",
                    fraction = channel % 2 == 0 and -1.5 or 1.5,
                    trim = { available = true, fraction = 0.75 },
                }
            end
            services.control = {
                output = function(_, channel)
                    return feeds[channel]
                end,
            }
            local function settle(context)
                local task = hostModule.task({ module = module, instance = context, interval = 20 })
                for step = 1, 2000 do
                    if task:step(task.want or 1, task.stage, getTime()) ~= 1 then return end
                    if kind == "output" and feeds[0].nameReady == false and step == 100 then
                        assert(context.showRows == 0, "rows must wait for unresolved names")
                        return
                    end
                end
                error(kind .. ": panel task did not finish")
            end
            local function create()
                local context = module.create(
                    lvgl.box({ x = 0, y = 0, w = 800, h = 1200 }),
                    { x = 0, y = 0, w = 90, h = 50 },
                    settings,
                    services
                )
                if kind == "tx-battery" then
                    context.feed = { available = variant ~= 4, value = 5 + variant, stale = variant == 5 }
                    context.range = { available = variant < 6, empty = 6.4, full = 8.4 }
                end
                settle(context)
                return context
            end
            local function finish(context, rect, done)
                for _ = 1, 200 do
                    if done then
                        break
                    end
                    done = module.reflow(context, rect, settings, nil, placement, false)
                    assert(type(done) == "boolean")
                end
                assert(done and not context.reflowWork, kind .. ": reflow must finish without service progress")
                assert(module.reflow(context, rect, settings, nil, placement, false))
            end
            local staged, synchronous = create(), create()
            for _, shape in ipairs({ { 800, 1200 }, { 90, 50 }, { 160, 480 }, { 800, 90 }, { 320, 200 } }) do
                local rect = { x = 1, y = 2, w = shape[1], h = shape[2] }
                finish(staged, rect, module.reflow(staged, rect, settings, nil, placement, true))
                module.update(synchronous, rect, settings)
                -- Output's synchronous update mounts rows through its task.
                -- Compare without refreshing the completed staged geometry.
                if kind == "output" then
                    settle(synchronous)
                end
                local ok, err = pcall(sameTree, synchronous.panel.root, staged.panel.root)
                assert(
                    ok,
                    kind
                        .. "/"
                        .. theme
                        .. "/"
                        .. variant
                        .. "/"
                        .. shape[1]
                        .. "x"
                        .. shape[2]
                        .. ": "
                        .. tostring(err)
                )
                if kind == "output" and variant == 1 and shape[2] == 1200 then
                    assert(staged.showRows == 32 and staged.rows[32].captionText == "CH32")
                end
                checked = checked + 1
            end
            local target = { x = 3, y = 4, w = 800, h = 1200 }
            local done = module.reflow(staged, target, settings, nil, placement, true)
            for _ = 1, 200 do
                local work = staged.reflowWork
                if work.stage == (kind == "output" and "render" or "publish") then
                    for _, feed in pairs(feeds) do
                        feed.available, feed.fraction = true, -0.25
                        feed.trim.available = false
                    end
                    for _, context in ipairs({ staged, synchronous }) do
                        if kind == "tx-battery" then
                            context.feed.available, context.feed.value, context.feed.stale = true, 7.9, false
                            context.range.available = true
                        end
                    end
                    break
                end
                done = module.reflow(staged, target, settings, nil, placement, false)
                if done then
                    break
                end
            end
            finish(staged, target, done)
            module.update(synchronous, target, settings)
            if kind == "output" then
                settle(synchronous)
            end
            sameTree(synchronous.panel.root, staged.panel.root)
            checked = checked + 1
            if kind == "output" and variant == 5 then
                for _, feed in pairs(feeds) do
                    feed.nameReady = true
                end
                settle(staged)
                settle(synchronous)
                assert(staged.showRows == staged.area.count and staged.showRows > 0)
                sameTree(synchronous.panel.root, staged.panel.root)
            end
            if kind == "output" and variant == 1 then
                module.reflow(staged, target, settings, nil, placement, true)
                for _ = 1, 200 do
                    if staged.reflowWork.stage == "apply" then
                        break
                    end
                    assert(not module.reflow(staged, target, settings, nil, placement, false))
                end
                for _, feed in pairs(feeds) do
                    feed.available, feed.fraction, feed.name = false, 0.75, "NEW"
                end
                finish(staged, target)
                assert(staged.rows[1].available and staged.rows[32].available)
                assert(staged.rows[1].fraction == -0.25 and staged.rows[32].fraction == -0.25)
                settle(staged)
                settle(synchronous)
                sameTree(synchronous.panel.root, staged.panel.root)
                module.reflow(staged, target, settings, nil, placement, true)
                for _ = 1, 200 do
                    if staged.reflowWork.stage == "apply" then
                        break
                    end
                    assert(not module.reflow(staged, target, settings, nil, placement, false))
                end
                module.cancelRefresh(staged)
                assert(staged.reflowWork.invalidated and not staged.rendered, "cancel must discard unpainted cache")
                settle(staged)
                sameTree(synchronous.panel.root, staged.panel.root)
            end
            -- Every continuation can be restarted or preempted synchronously.
            if variant == 1 then
                local replacement = { x = 5, y = 6, w = 320, h = 200 }
                for _, interruption in ipairs({ "resize", "update", "cancelRefresh", "reset" }) do
                    for stop = 0, kind == "output" and 90 or 3 do
                        staged, synchronous = create(), create()
                        for _, context in ipairs({ staged, synchronous }) do
                            module.update(context, target, settings)
                            settle(context)
                        end
                        local done = module.reflow(staged, target, settings, nil, placement, true)
                        for _ = 1, stop do
                            if done then
                                break
                            end
                            done = module.reflow(staged, target, settings, nil, placement, false)
                        end
                        if done then
                            break
                        end
                        if interruption == "resize" then
                            done = module.reflow(staged, replacement, settings, nil, placement, true)
                        elseif interruption == "update" then
                            module.update(staged, replacement, settings)
                            assert(staged.reflowWork.invalidated)
                        elseif interruption == "reset" then
                            local scheduler = host.schedulerHost
                            local entry = { module = module, instance = staged, placement = { id = "subject" } }
                            local message = scheduler:resetPanelRelease(entry, getTime())
                            assert(not message and not entry.failed, message)
                            assert(staged.reflowWork.invalidated)
                        else
                            module.cancelRefresh(staged)
                            assert(staged.reflowWork.invalidated)
                        end
                        local rect = (interruption == "cancelRefresh" or interruption == "reset") and target
                            or replacement
                        finish(staged, rect, done)
                        module.update(synchronous, rect, settings)
                        if kind == "output" then
                            settle(synchronous)
                        end
                        sameTree(synchronous.panel.root, staged.panel.root)
                        checked = checked + 1
                    end
                end
            end
        end
    end
end
print("Remaining panel reflow: " .. checked .. " completed trees and preemptions passed")
