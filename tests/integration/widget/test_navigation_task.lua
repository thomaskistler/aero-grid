-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local sameTree = assert(loadfile(root .. "/tests/support/panel_tree.lua"))()
local dashboard = fixture.createLoaded(nil, { Layout = "review-navigation", Theme = "modern-dark" })
local reference = dashboard.panels[1].instance
local navigation = fixture.module("panels/navigation.lua")
local panelHost = fixture.module("lib/panel_host.lua")
local support = fixture.module("lib/services.lua")
local builder = reference.themeBuilder

for _, mode in ipairs({ "modern-dark", "modern-light" }) do
    local theme = builder.build(mode)
    for _, shape in ipairs({ { 1, 1, 117, 65 }, { 2, 2, 238, 134 }, { 4, 1, 800, 90 }, { 4, 4, 800, 480 } }) do
        for flags = 0, 7 do
            for _, format in ipairs({ "degrees", "quadrant" }) do
                local state = {
                    source = "GPS",
                    known = true,
                    fix = true,
                    home = true,
                    state = "normal",
                    latitude = 47.3769,
                    longitude = 8.5417,
                    distance = 123,
                    bearing = 12,
                }
                local satellites = { value = 12, available = true }
                local view, counts = support.snapshot(state), support.snapshot(satellites)
                local settings = assert(panelHost.resolveSettings(navigation, {
                    showTape = flags % 2 == 1,
                    showCoordinates = math.floor(flags / 2) % 2 == 1,
                    satelliteSource = flags >= 4 and "Sats" or "",
                    bearingFormat = format,
                }))
                local services = {
                    theme = theme,
                    themeBuilder = builder,
                    primitives = reference.primitives,
                    fonts = builder.typography(shape[1], shape[2]),
                    span = { colSpan = shape[1], rowSpan = shape[2] },
                    host = { path = root .. "/src/WIDGETS/AeroGrid/" },
                    navigation = {
                        subscribe = function()
                            return view
                        end,
                        describeDistanceParts = reference.service.describeDistanceParts,
                    },
                    telemetry = {
                        subscribe = function()
                            return counts
                        end,
                    },
                    state = function(name, accent)
                        return builder.state(theme, name, accent)
                    end,
                }
                local rect = { x = 0, y = 0, w = shape[3], h = shape[4] }
                local function create()
                    local context =
                        navigation.create(lvgl.box({ x = 0, y = 0, w = rect.w, h = rect.h }), rect, settings, services)
                    navigation.refresh(context)
                    return context
                end
                local legacy, instance = create(), create()
                local task = panelHost.task({ module = navigation, instance = instance, interval = 25 })
                local function step()
                    local delay = task:step(1, task.stage, getTime())
                    assert(task.used == 0 or task.used == 1)
                    return delay
                end
                local function finish()
                    for _ = 1, 4 do
                        if step() == 25 then
                            return
                        end
                    end
                    error("navigation task did not finish")
                end
                if instance.tape then
                    for _, context in ipairs({ legacy, instance }) do
                        context.tape.width, context.tape.height, context.tape.surface = nil, nil, nil
                        context.tape.pending = true
                    end
                    navigation.refresh(legacy)
                    finish()
                    assert(not instance.tape.pending)
                    sameTree(legacy.panel.root, instance.panel.root)
                end
                for cycle = 1, 10 do
                    state.known, state.fix, state.home = cycle ~= 3, cycle ~= 4, cycle ~= 5
                    state.state = cycle == 6 and "stale" or "normal"
                    state.homeStatus = cycle == 5 and "waiting" or nil
                    state.latitude, state.longitude = 47.3769 + cycle / 100, 8.5417 - cycle / 100
                    state.distance = cycle ~= 4 and cycle ~= 5 and cycle * 1234.56 or nil
                    state.bearing = cycle ~= 4 and cycle ~= 5 and cycle * 53.1 or nil
                    satellites.value = cycle == 7 and 6 or cycle == 8 and 3 or 12
                    satellites.stale = cycle == 9
                    navigation.refresh(legacy)
                    local captured = {}
                    for key, value in pairs(state) do
                        captured[key] = value
                    end
                    local count, stale = satellites.value, satellites.stale
                    if step() ~= 25 then
                        assert(instance.refreshWork and task.stage == "reading")
                        state.distance, state.bearing, state.latitude = -999, 359, -89
                        state.state, state.known = "stale", false
                        satellites.value, satellites.stale = 0, true
                        finish()
                    end
                    sameTree(legacy.panel.root, instance.panel.root)
                    for _, key in ipairs({
                        "source",
                        "known",
                        "fix",
                        "home",
                        "state",
                        "homeStatus",
                        "latitude",
                        "longitude",
                        "distance",
                        "bearing",
                    }) do
                        state[key] = captured[key]
                    end
                    satellites.value, satellites.stale = count, stale
                end
                local writes = instance.value.writes
                assert(step() == 25 and instance.value.writes == writes, "a stable frame must not repaint")
                legacy.feed, instance.feed = nil, nil
                if instance.tape then
                    legacy.tape.pending, instance.tape.pending = true, true
                end
                navigation.refresh(legacy)
                finish()
                sameTree(legacy.panel.root, instance.panel.root)
                legacy.feed, instance.feed = view, view
                navigation.refresh(legacy)
                finish()
                sameTree(legacy.panel.root, instance.panel.root)
                local stages = instance.showTape and { "reading", "tape-frame", "tape" }
                    or instance.tape and { "reading", "tape-frame" }
                    or { "reading" }
                for _, target in ipairs(stages) do
                    state.distance = state.distance + 12345.6
                    navigation.refresh(legacy)
                    for _ = 1, 3 do
                        if task.stage == target then
                            break
                        end
                        assert(step() == 1)
                    end
                    assert(task.stage == target and instance.refreshWork)
                    navigation.cancelRefresh(instance)
                    navigation.cancelRefresh(instance)
                    assert(not instance.refreshWork)
                    assert(step() == 1 and task.used == 0 and task.stage == "render")
                    finish()
                    sameTree(legacy.panel.root, instance.panel.root, "cancelled " .. target)

                    state.distance = state.distance + 12345.6
                    navigation.refresh(legacy)
                    for _ = 1, 3 do
                        if task.stage == target then
                            break
                        end
                        assert(step() == 1)
                    end
                    assert(task.stage == target and instance.refreshWork)
                    local changed = { x = 0, y = 0, w = rect.w + 20, h = rect.h + 30 }
                    navigation.update(legacy, changed)
                    navigation.update(instance, changed)
                    assert(not instance.refreshWork)
                    assert(
                        step() == 1 and task.used == 0 and task.stage == "render",
                        "reflow invalidates a planned stage"
                    )
                    finish()
                    sameTree(legacy.panel.root, instance.panel.root)
                    state.distance = state.distance + 12345.6
                    navigation.refresh(legacy)
                    assert(step() == 1)
                    navigation.refresh(instance)
                    assert(step() == 1 and task.used == 0, "legacy refresh invalidates a captured frame")
                    finish()
                    sameTree(legacy.panel.root, instance.panel.root)
                end
            end
        end
    end
end
print("Navigation task: frozen output, complete legacy parity, stale plans and stable frames passed")
