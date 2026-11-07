-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local dashboard = fixture.createLoaded(nil, { Layout = "review-metric", Theme = "modern-dark" })
local reference = dashboard.panels[1].instance
local panel = fixture.module("panels/tx-battery.lua")
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
        { 4, 1, 800, 90 },
        { 1, 4, 160, 480 },
        { 4, 4, 800, 480 },
    }) do
        for _, visual in ipairs({ "battery", "bar", "none" }) do
            for _, percent in ipairs({ false, true }) do
                for _, override in ipairs({ false, true }) do
                    local reading = { available = true, value = 7.4, stale = false }
                    local range = { available = true, empty = 6.4, full = 8.4 }
                    local config = { visual = visual, showPercent = percent, warning = 6.5, critical = 6.0 }
                    if override then
                        config.packEmpty, config.packFull = 6.4, 8.4
                    end
                    local settings = assert(host.resolveSettings(panel, config))
                    local services = {
                        theme = theme,
                        themeBuilder = builder,
                        primitives = reference.primitives,
                        fonts = builder.typography(shape[1], shape[2]),
                        span = { colSpan = shape[1], rowSpan = shape[2] },
                        model = {
                            txVoltage = function()
                                return support.snapshot(reading)
                            end,
                            batteryRange = function()
                                return support.snapshot(range)
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
                    local instance = create()
                    local entry = { module = panel, instance = instance, interval = panel.refreshInterval }
                    local task = host.task(entry)
                    for cycle = 1, 12 do
                        reading.available, reading.stale = cycle ~= 3, cycle == 4
                        reading.value = cycle == 5 and 6.3 or cycle == 6 and 5.8 or cycle * 1.234
                        range.available = cycle ~= 7
                        range.empty, range.full = 6.4, cycle == 9 and 6.4 or 8.4
                        if cycle == 10 then
                            instance.range = nil
                        elseif cycle == 11 then
                            instance.range = support.snapshot(range)
                        elseif cycle == 12 then
                            instance.feed = nil
                        end
                        local previousText, previousState, previousReading =
                            instance.text, instance.stateName, instance.reading
                        local now = cycle * 50
                        assert(task:step(1, "run", now) == 50 and task.used == 1)
                        assert(entry.nextRefresh == now + 50)
                        if instance.feed then
                            local value = reading.available and reading.value or nil
                            assert(instance.text == panel.reading(value))
                            assert(instance.reading == value)
                            assert(instance.stateName == panel.resolveState(settings, value, reading.stale))
                            if instance.detailLabel and instance.showDetail then
                                assert(instance.detailLabel.properties.text == instance.detail)
                            end
                        else
                            assert(instance.text == previousText and instance.stateName == previousState)
                            assert(instance.reading == previousReading)
                        end
                        local before = writes(instance.panel.root)
                        task:step(1, "run", now)
                        assert(writes(instance.panel.root) == before, "stable TX battery frames must not repaint")
                    end
                    local resized = { x = 0, y = 0, w = rect.w + 20, h = rect.h + 30 }
                    panel.update(instance, resized)
                    assert(instance.panel.root.properties.w == resized.w)
                    assert(instance.panel.root.properties.h == resized.h)
                    local scheduler = fixture.module("lib/scheduler.lua").new({ steady = 1250, background = 1130 })
                    assert(scheduler:add({ id = "tx", decl = panel.decl, instance = task, due = 700 }))
                    local previous, before = entry.nextRefresh, writes(instance.panel.root)
                    scheduler:run("background", 700, 0)
                    assert(entry.nextRefresh == previous and writes(instance.panel.root) == before)
                    scheduler:run("steady", 700, 0)
                    assert(entry.nextRefresh == 750)
                end
            end
        end
    end
end
print("TX battery task: range transitions, stable frames, resizing and hidden eligibility passed")
