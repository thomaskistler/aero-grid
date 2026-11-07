-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local dashboard = fixture.createLoaded(nil, { Layout = "review-metric", Theme = "modern-dark" })
local reference = dashboard.panels[1].instance
local panelHost = fixture.module("lib/panel_host.lua")
local support = fixture.module("lib/services.lua")
local builder = reference.themeBuilder

for _, id in ipairs({ "flight-counter", "flight-mode", "flight-timer" }) do
    local panel = fixture.module("panels/" .. id .. ".lua")
    for _, mode in ipairs({ "modern-dark", "modern-light" }) do
        local theme = builder.build(mode)
        for _, shape in ipairs({
            { 1, 1, 117, 65 },
            { 2, 2, 238, 134 },
            { 4, 1, 800, 90 },
            { 1, 4, 160, 480 },
            { 4, 4, 800, 480 },
        }) do
            for _, detail in ipairs({ false, true }) do
                local state = {
                    available = true,
                    name = "NORMAL",
                    index = 0,
                    raw = 12,
                    value = 100,
                    countdown = true,
                    start = 100,
                    remaining = 100,
                    elapsed = 0,
                }
                local flight, now, clockCalls = { active = false }, 100, 0
                local view = support.snapshot(state)
                local config = {}
                if id == "flight-mode" then
                    config.showIndex = detail
                end
                if id == "flight-timer" then
                    config.warning, config.critical = 20, 10
                end
                local settings = assert(panelHost.resolveSettings(panel, config))
                local services = {
                    theme = theme,
                    themeBuilder = builder,
                    primitives = reference.primitives,
                    fonts = builder.typography(shape[1], shape[2]),
                    span = { colSpan = shape[1], rowSpan = shape[2] },
                    clock = function()
                        clockCalls = clockCalls + 1
                        return now
                    end,
                    model = {
                        widestFlightModeName = function()
                            return "MMMMMMMMMM"
                        end,
                        flightMode = function()
                            return view
                        end,
                        timer = function()
                            return view
                        end,
                    },
                    control = {
                        globalVariable = function()
                            return view
                        end,
                    },
                    flight = {
                        state = function()
                            return flight
                        end,
                    },
                    armed = {
                        state = function()
                            return {}
                        end,
                    },
                    state = function(name, accent)
                        return builder.state(theme, name, accent)
                    end,
                }
                local rect = { x = 0, y = 0, w = shape[3], h = shape[4] }
                local function create()
                    return panel.create(lvgl.box({ x = 0, y = 0, w = rect.w, h = rect.h }), rect, settings, services)
                end
                local instance = create()
                local entry = {
                    module = panel,
                    instance = instance,
                    interval = panel.refreshInterval,
                    placement = { id = "subject" },
                    nextRefresh = now,
                }
                local context = { panels = { entry }, panelHost = panelHost }
                local scheduling = fixture.module("lib/scheduler_host.lua").attach(context, {
                    load = fixture.module,
                    api = {
                        log = function(_, message)
                            error(message)
                        end,
                    },
                })
                for _ = 1, 200 do
                    assert(scheduling:ready(context))
                    if scheduling.panelTasks[entry] then
                        break
                    end
                end
                local task = assert(scheduling.panelTasks[entry])
                for cycle = 1, 9 do
                    now = now + panel.refreshInterval
                    state.available, state.name, state.index = cycle ~= 3, cycle == 8 and "" or "MODE" .. cycle, cycle
                    state.raw, state.elapsed = cycle * 987, cycle * 3601
                    state.remaining, state.value = 100 - cycle * 12, 100 - cycle * 12
                    state.expired, state.countdown, state.showElapsed = cycle == 9, cycle ~= 6, cycle == 6
                    flight.active = cycle % 2 == 0
                    local calls = clockCalls
                    assert(task:step(1, "run", now) == panel.refreshInterval and task.used == 1)
                    assert(entry.nextRefresh == now + panel.refreshInterval)
                    if id == "flight-counter" then
                        assert(clockCalls == calls, "the scheduler, not a second local throttle, owns counter cadence")
                    end
                    local drawn = {}
                    panel.render(instance, drawn)
                    assert(instance.text == drawn.text and instance.stateName == drawn.state)
                    assert(instance.value.properties.text == drawn.text)
                end
                now = now + panel.refreshInterval
                task:step(1, "run", now)
                local writes = instance.value.writes
                now = now + panel.refreshInterval
                assert(task:step(1, "run", now) == panel.refreshInterval)
                assert(instance.value.writes == writes, "stable readouts must not repaint")
                local resized = { x = 0, y = 0, w = rect.w + 20, h = rect.h + 30 }
                panel.update(instance, resized)
                assert(instance.panel.root.properties.w == resized.w)
                assert(instance.panel.root.properties.h == resized.h)
                if id == "flight-counter" then
                    state.raw, now = 321, now + 20
                    local scheduler = fixture.module("lib/scheduler.lua").new({ steady = 1250, background = 1130 })
                    assert(scheduler:add({ id = "counter", decl = panel.decl, instance = task, due = 2147483640 }))
                    scheduler:run("steady", 2147483640, 0)
                    state.raw = 322
                    scheduler:run("steady", -2147483636, 0)
                    assert(instance.text == "322", "counter refresh crosses the signed tick wrap")
                    state.raw = 323
                    scheduler:run("background", -2147483616, 0)
                    assert(instance.text == "322", "background neither consumes nor paints a panel release")
                    scheduler:run("steady", -2147483616, 0)
                    assert(instance.text == "323")
                end
            end
        end
    end
end
print("Flight readout tasks: readings, intervals, stable frames, hidden eligibility and counter wrap passed")
