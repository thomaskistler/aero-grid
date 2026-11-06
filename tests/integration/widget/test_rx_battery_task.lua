-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local sameTree = assert(loadfile(root .. "/tests/support/panel_tree.lua"))()
local dashboard = fixture.createLoaded(nil, { Layout = "review-metric", Theme = "modern-dark" })
local reference = dashboard.panels[1].instance
local panel = fixture.module("panels/rx-battery.lua")
local host = fixture.module("lib/panel_host.lua")
local support = fixture.module("lib/services.lua")
local builder = reference.themeBuilder

local function writes(node)
    local count = node.writes
    for _, child in ipairs(node.children) do
        count = count + writes(child)
    end
    return count
end

for _, mode in ipairs({ "modern-dark", "modern-light" }) do
    local theme = builder.build(mode)
    for _, shape in ipairs({
        { 1, 1, 117, 65 },
        { 2, 2, 238, 134 },
        { 4, 1, 480, 65 },
        { 1, 4, 160, 480 },
        { 4, 4, 800, 480 },
    }) do
        for _, visual in ipairs({ "battery", "bar", "none" }) do
            for _, reading in ipairs({ "cell", "pack" }) do
                for _, flags in ipairs({ 0, 3, 7 }) do
                    local state =
                        { available = true, raw = { 4.2, 4.1, 4.0, 4.1, 4.2, 4.1 }, fresh = true, updatedAt = 100 }
                    local settings = assert(host.resolveSettings(panel, {
                        visual = visual,
                        reading = reading,
                        cells = flags == 3 and 16 or 0,
                        showCount = flags > 0,
                        showPack = flags > 0,
                        showDelta = flags == 7,
                    }))
                    local services = {
                        theme = theme,
                        themeBuilder = builder,
                        primitives = reference.primitives,
                        fonts = builder.typography(shape[1], shape[2]),
                        telemetry = {
                            subscribe = function()
                                return support.snapshot(state)
                            end,
                        },
                        state = function(name, accent)
                            return builder.state(theme, name, accent)
                        end,
                    }
                    local rect = { x = 0, y = 0, w = shape[3], h = shape[4] }
                    local function create()
                        return panel.create(
                            lvgl.box({ x = 0, y = 0, w = rect.w, h = rect.h }),
                            rect,
                            settings,
                            services
                        )
                    end
                    local legacy, instance = create(), create()
                    local candidates = 0
                    instance.themeBuilder = setmetatable({
                        panel = function(...)
                            candidates = candidates + 1
                            return builder.panel(...)
                        end,
                    }, { __index = builder })
                    local entry = { module = panel, instance = instance, interval = 20 }
                    local task = host.task(entry)
                    local function step()
                        local before, stage = candidates, task.stage
                        local delay = task:step(1, stage, 100)
                        assert(candidates - before == (stage == "geometry" and 1 or 0))
                        return delay
                    end
                    local function finish()
                        for _ = 1, 16 do
                            local delay = step()
                            assert(task.used == 1)
                            if delay == 20 then
                                return
                            end
                            assert(delay == 1)
                        end
                        error("RX task did not finish")
                    end
                    for cycle = 1, 12 do
                        state.available, state.stale, state.fresh, state.updatedAt =
                            cycle ~= 3, cycle == 4, cycle ~= 4, cycle * 100
                        state.raw = {}
                        for index = 1, cycle % 2 == 0 and 16 or 6 do
                            state.raw[index] = 3 + index / 100 + cycle / 100
                        end
                        if cycle == 5 or cycle == 11 then
                            state.raw = cycle == 5 and 12.6 or 64
                        elseif cycle == 6 then
                            state.raw = {}
                        elseif cycle == 7 then
                            state.raw = { 0, 0 / 0, 31, "bad" }
                        elseif cycle == 8 then
                            state.raw = { 3.8, 0, 4.1, "bad" }
                        elseif cycle == 9 then
                            state.raw = nil
                        elseif cycle == 10 then
                            legacy.feed, instance.feed = nil, nil
                        elseif cycle == 12 then
                            legacy.feed, instance.feed = support.snapshot(state), support.snapshot(state)
                            panel.resetSession(legacy, 1100)
                            panel.resetSession(instance, 1100)
                        end
                        panel.refresh(legacy)
                        local hasFeed = instance.feed ~= nil
                        local delay = step()
                        assert(task.used == 1)
                        if hasFeed then
                            assert(delay == 1)
                            local raw = state.raw
                            if type(raw) == "table" then
                                for key in pairs(raw) do
                                    raw[key] = 999
                                end
                            end
                            state.available, state.stale, state.raw = false, true, 999
                            finish()
                        else
                            assert(delay == 20)
                        end
                        sameTree(legacy.panel.root, instance.panel.root)
                    end
                    state.available, state.stale, state.raw = true, false, { 4.0, 4.1 }
                    panel.refresh(legacy)
                    finish()
                    local before = writes(instance.panel.root)
                    finish()
                    assert(writes(instance.panel.root) == before, "stable RX frames must not repaint")
                    sameTree(legacy.panel.root, instance.panel.root)
                    local resized = { x = 0, y = 0, w = rect.w + 20, h = rect.h + 30 }
                    panel.update(legacy, resized)
                    panel.update(instance, resized)
                    sameTree(legacy.panel.root, instance.panel.root)
                    local scheduler = fixture.module("lib/scheduler.lua").new({ steady = 1250, background = 1130 })
                    assert(scheduler:add({ id = "rx", decl = panel.decl, instance = task, due = 200 }))
                    local before, previous = writes(instance.panel.root), entry.nextRefresh
                    scheduler:run("background", 200, 0)
                    assert(writes(instance.panel.root) == before and entry.nextRefresh == previous)
                    scheduler:run("steady", 200, 0)
                    assert(instance.refreshWork, "foreground must retain the skipped release")
                    finish()
                    if mode == "modern-dark" and visual == "bar" and reading == "cell" and flags == 7 then
                        for _, target in ipairs({ "geometry", "layout", "render", "apply" }) do
                            for _, action in ipairs({ "resize", "refresh", "reset" }) do
                                state.raw = { 4.1 }
                                local subject = create()
                                state.raw = {}
                                for index = 1, 16 do
                                    state.raw[index] = 3.5 + index / 100
                                end
                                for _ = 1, 16 do
                                    if panel.stageOf(subject) == target then
                                        break
                                    end
                                    local _, unfinished = panel.step(subject, 1, panel.stageOf(subject))
                                    assert(unfinished)
                                end
                                assert(panel.stageOf(subject) == target)
                                state.raw = { 4.0, 4.2 }
                                if action == "resize" then
                                    panel.update(subject, resized)
                                elseif action == "refresh" then
                                    panel.refresh(subject)
                                else
                                    panel.resetSession(subject, 1300)
                                end
                                local _, unfinished = panel.step(subject, 1, target)
                                assert(unfinished and subject.used == 0 and panel.stageOf(subject) == "prepare")
                                local expected = create()
                                if action == "resize" then
                                    panel.update(expected, resized)
                                elseif action == "reset" then
                                    panel.resetSession(expected, 1300)
                                end
                                panel.refresh(expected)
                                local resumed = host.task({ module = panel, instance = subject, interval = 20 })
                                for attempt = 1, 16 do
                                    local delay = resumed:step(1, resumed.stage, 1400)
                                    if delay == 20 then
                                        break
                                    end
                                    assert(attempt < 16, "cancelled RX frame did not resume")
                                end
                                sameTree(
                                    expected.panel.root,
                                    subject.panel.root,
                                    shape[3] .. "x" .. shape[4] .. ":" .. target .. ":" .. action
                                )
                            end
                        end
                    end
                end
            end
        end
    end
end
print("RX Battery task: frozen-frame parity, stable frames, reflow and stale-stage cancellation passed")
