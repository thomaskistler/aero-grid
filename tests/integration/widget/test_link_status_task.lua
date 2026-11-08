-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local sameTree = assert(loadfile(root .. "/tests/support/panel_tree.lua"))()
local dashboard = fixture.createLoaded(nil, { Layout = "review-metric", Theme = "modern-dark" })
local reference = dashboard.panels[1].instance
local panel = fixture.module("panels/link-status.lua")
local host = fixture.module("lib/panel_host.lua")
local support = fixture.module("lib/services.lua")
local builder = reference.themeBuilder

do
    local context = fixture.createLoaded(nil, { Layout = "review-link-status", Theme = "modern-dark" })
    fixture.pump(context, 100, 10)
    local instance = fixture.instanceOf(context, "wide-quality")
    panel.cancelRefresh(instance)
    instance.text = "NO LINK"
    instance.link = { live = true }
    instance.qualityFeed = { known = true, available = true, stale = true, value = 70, unitText = "%" }
    instance.rssiFeed = nil
    local _, unfinished = panel.step(instance, 1, "prepare")
    assert(unfinished and not instance.refreshWork, "recovery waits once for the source poll")
    instance.qualityFeed.stale = false
    panel.step(instance, 1, "prepare")
    assert(instance.refreshWork and not instance.refreshWork.feeds.qualityFeed.stale,
        "recovery must capture the fresh reading")
    panel.cancelRefresh(instance)
    instance.qualityFeed.stale = true
    panel.step(instance, 1, "prepare")
    assert(not instance.refreshWork, "a new recovery gets one retry")
    panel.step(instance, 1, "prepare")
    assert(instance.refreshWork and instance.refreshWork.feeds.qualityFeed.stale,
        "a persistently stale source must still be displayed")
    panel.cancelRefresh(instance)
    panel.step(instance, 1, "prepare")
    panel.cancelRefresh(instance)
    panel.step(instance, 1, "prepare")
    assert(not instance.refreshWork, "cancellation clears a pending recovery retry")
    instance.link.live = false
    panel.step(instance, 1, "prepare")
    assert(instance.refreshWork and not instance.refreshWork.feeds.link.live,
        "a flapping link must not keep delaying the disconnected state")
    panel.cancelRefresh(instance)
    instance.link.live = true
    panel.step(instance, 1, "prepare")
    local entry = fixture.entryById(context, "wide-quality")
    local record = assert(context.schedulerHost.panelTasks[entry])
    local scheduler = context.schedulerHost.scheduler
    fixture.tick(5)
    scheduler:run("background", getTime(), 0)
    assert(instance.recoveryDeferred and not instance.refreshWork,
        "hidden callbacks cannot advance a panel's pending retry")
    assert(not context.schedulerHost:resetPanelRelease(entry, getTime()))
    assert(not instance.recoveryDeferred and not instance.refreshWork and record.stage == "prepare",
        "session reset must discard the retry and wake the prepare stage")
    panel.step(instance, 1, "prepare")
    assert(instance.recoveryDeferred)
    assert(not panel.reflow(instance, { x = 0, y = 0, w = instance.rect.w, h = instance.rect.h },
        nil, nil, nil, true))
    assert(not instance.recoveryDeferred and not instance.refreshWork,
        "reflow must discard the pending retry and any frozen frame")
end

for _, mode in ipairs({ "modern-dark", "modern-light" }) do
    local theme = builder.build(mode)
    for _, shape in ipairs({
        { 1, 1, 117, 65 },
        { 2, 1, 238, 65 },
        { 2, 2, 238, 134 },
        { 1, 4, 160, 480 },
        { 4, 4, 800, 480 },
    }) do
        for _, protocol in ipairs({ "generic", "elrs4" }) do
            for _, primary in ipairs({ "auto", "quality", "rssi" }) do
                for _, visual in ipairs({ "none", "bar" }) do
                    for _, extrema in ipairs({ "none", "source" }) do
                        local states, views = {}, {}
                        local link = { live = true, indicator = true, rssi = 72 }
                        for name in pairs({ RSSI = true, LQ = true, MODE = true, SNR = true, POWER = true, MIN = true }) do
                            states[name] = { name = name }
                            views[name] = support.snapshot(states[name])
                        end
                        local function stimulus(cycle)
                            for name, value in pairs({
                                RSSI = -72 - cycle,
                                LQ = 96 - cycle,
                                MODE = cycle == 8 and 255 or 6,
                                SNR = cycle,
                                POWER = cycle * 100,
                                MIN = -100,
                            }) do
                                local state = states[name]
                                state.known, state.available, state.stale = cycle ~= 6, cycle ~= 5, cycle == 7
                                state.value, state.precision = value, 0
                                state.unitText = name == "LQ" and "%" or name == "RSSI" and "dBm" or ""
                            end
                            link.live, link.indicator, link.rssi = cycle ~= 3, cycle ~= 3, 72
                        end
                        stimulus(1)
                        local settings = assert(host.resolveSettings(panel, {
                            protocol = protocol,
                            reading = primary,
                            visual = visual,
                            extrema = extrema,
                            rssiSource = "RSSI",
                            qualitySource = "LQ",
                            modeSource = "MODE",
                            snrSource = "SNR",
                            powerSource = "POWER",
                            extremaSource = "MIN",
                            qualityWarning = 95,
                            qualityCritical = 90,
                            rssiWarning = -75,
                            rssiCritical = -80,
                        }))
                        local services = {
                            theme = theme,
                            themeBuilder = builder,
                            primitives = reference.primitives,
                            fonts = builder.typography(shape[1], shape[2]),
                            span = { colSpan = shape[1], rowSpan = shape[2] },
                            telemetry = {
                                subscribe = function(_, name)
                                    return views[name]
                                end,
                                link = function()
                                    return support.snapshot(link)
                                end,
                            },
                            state = function(name, accent)
                                return builder.state(theme, name, accent)
                            end,
                        }
                        local rect = { x = 0, y = 0, w = shape[3], h = shape[4] }
                        local function create()
                            local context = panel.create(
                                lvgl.box({ x = 0, y = 0, w = rect.w, h = rect.h }),
                                rect,
                                settings,
                                services
                            )
                            return context
                        end
                        local expected, instance = create(), create()
                        local expectedTask = host.task({ module = panel, instance = expected, interval = 20 })
                        local function finishExpected()
                            for _ = 1, 20 do
                                if expectedTask:step(expectedTask.want or 1, expectedTask.stage, getTime()) == 20 then return end
                            end
                            error("Link Status comparison did not finish")
                        end
                        local task = host.task({ module = panel, instance = instance, interval = 20 })
                        local function step()
                            local rssi, quality = instance.rssiFeed, instance.qualityFeed
                            local delay = task:step(1, task.stage, getTime())
                            assert(task.used == 0 or task.used == 1)
                            assert(instance.rssiFeed == rssi and instance.qualityFeed == quality)
                            return delay
                        end
                        local function finish()
                            for _ = 1, 6 do
                                if step() == 20 then
                                    return
                                end
                            end
                            error("Link Status task did not finish")
                        end
                        for cycle = 1, 8 do
                            stimulus(cycle)
                            finishExpected()
                            assert(step() == 1)
                            local frozen = assert(instance.refreshWork)
                            for _, state in pairs(states) do
                                state.value, state.available = -999, false
                                state.known, state.stale, state.precision, state.unitText =
                                    false, true, 3, "after capture"
                            end
                            link.live = not link.live
                            finish()
                            assert(not instance.refreshWork and frozen.feeds.rssiFeed.value ~= states.RSSI.value)
                            sameTree(expected.panel.root, instance.panel.root)
                            stimulus(cycle)
                            local writes = instance.value.writes
                            finish()
                            assert(instance.value.writes == writes, "stable link frames must not repaint")
                        end

                        for _, target in ipairs({ "geometry", "layout", "render", "apply" }) do
                            for _, action in ipairs({ "cancelRefresh", "update" }) do
                                stimulus(2)
                                link.live = instance.sample.digits == "NO LINK"
                                finishExpected()
                                for _ = 1, 5 do
                                    if task.stage == target then
                                        break
                                    end
                                    assert(step() == 1)
                                end
                                assert(task.stage == target and instance.refreshWork)
                                if action == "update" then
                                    local changed = { x = 0, y = 0, w = rect.w + 20, h = rect.h + 30 }
                                    panel.update(expected, changed)
                                    panel.update(instance, changed)
                                    finishExpected()
                                else
                                    panel[action](instance)
                                end
                                assert(not instance.refreshWork)
                                assert(step() == 1 and task.used == 0 and task.stage == "prepare")
                                finish()
                                sameTree(expected.panel.root, instance.panel.root, action .. " after " .. target)
                            end
                        end
                        local scheduler = fixture.module("lib/scheduler.lua").new({ steady = 1250, background = 1130 })
                        assert(scheduler:add({ id = "link", decl = panel.decl, instance = task, due = 700 }))
                        local writes = instance.value.writes
                        scheduler:run("background", 700, 0)
                        assert(not instance.refreshWork and instance.value.writes == writes)

                        instance.rssiFeed, instance.qualityFeed = nil, nil
                        assert(step() == 20 and not instance.refreshWork)
                        instance.rssiFeed, instance.qualityFeed = views.RSSI, views.LQ
                        stimulus(2)
                        assert(step() == 1)
                        for _ = 1, 3 do
                            if task.stage == "render" then
                                break
                            end
                            assert(step() == 1)
                        end
                        local render = panel.render
                        panel.render = function()
                            error("deliberate link render failure")
                        end
                        local ok, message = pcall(panel.step, instance, 1, "render")
                        panel.render = render
                        assert(not ok and string.find(message, "deliberate link render failure", 1, true))
                        assert(instance.rssiFeed == views.RSSI and instance.qualityFeed == views.LQ)
                        panel.cancelRefresh(instance)
                    end
                end
            end
        end
    end
end
print("Link Status task: frozen readings, loss/recovery geometry and cancellation passed")
