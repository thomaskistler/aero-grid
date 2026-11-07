-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local dashboard = fixture.createLoaded(nil, { Layout = "review-metric", Theme = "modern-dark" })
local reference = dashboard.panels[1].instance
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

for _, id in ipairs({ "state", "trim-panel" }) do
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
            for option = 1, id == "state" and 4 or 3 do
                local config, switches, trims = {}, {}, {}
                if id == "state" then
                    config.entries = {}
                    for index = 1, math.min(3, option) do
                        local name = "S" .. string.char(64 + index)
                        config.entries[index] = {
                            label = "STATE" .. index,
                            states = {
                                { switch = name .. "^", text = "UP", background = "active" },
                                { switch = name .. "-", text = "MID", background = "warning" },
                                { switch = name .. "v", text = "DOWN", background = "critical" },
                            },
                        }
                        for _, condition in ipairs(config.entries[index].states) do
                            switches[condition.switch] = {}
                        end
                    end
                    if option == 4 then
                        config.entries[1].states[1].text = string.rep("W", 4100)
                    end
                else
                    config.readout = ({ "percent", "raw", "none" })[option]
                    config.scale = ({ "standard", "extended", "auto" })[option]
                end
                local settings = assert(host.resolveSettings(panel, config))
                local services = {
                    theme = theme,
                    themeBuilder = builder,
                    primitives = reference.primitives,
                    fonts = builder.typography(shape[1], shape[2]),
                    control = {
                        displaySwitch = function(_, name)
                            return support.snapshot(switches[name])
                        end,
                        trim = function(_, name)
                            trims[name] = trims[name] or {}
                            return support.snapshot(trims[name])
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
                local entry = { module = panel, instance = instance, interval = panel.refreshInterval }
                local task = host.task(entry)
                for cycle = 1, 10 do
                    for name, state in pairs(switches) do
                        state.known, state.available, state.fresh = cycle ~= 4, cycle ~= 5, cycle ~= 6
                        local position = string.sub(name, -1)
                        state.value = cycle == 9
                            or cycle <= 3 and position == ({ "^", "-", "v" })[cycle]
                            or cycle == 8 and position == "^"
                    end
                    for index, name in ipairs({ settings.trim1, settings.trim2, settings.trim4 }) do
                        local state = trims[name]
                        local direction = index % 2 == 0 and -1 or 1
                        state.available = cycle ~= 6 and (cycle ~= 7 or index == 2)
                        state.fraction = direction * (cycle % 3) / 2
                        state.centered, state.threePosition = state.fraction == 0, cycle == 4 or cycle == 5
                        state.value = state.fraction * (cycle % 2 == 0 and 128 or 512)
                        state.raw = state.value * 8
                    end
                    if id == "state" and cycle == 10 then
                        instance.feeds[1] = nil
                    elseif id == "trim-panel" and cycle == 8 then
                        instance.indicators[1].feed = nil
                    end
                    local now = cycle * 20
                    assert(task:step(1, "run", now) == 20 and task.used == 1)
                    assert(entry.nextRefresh == now + 20)
                    local drawn = {}
                    panel.render(instance, drawn)
                    assert(instance.stateName == drawn.state or id == "state" and instance.stateName == drawn.background)
                    if id == "state" then
                        assert(instance.value.properties.text == drawn.text)
                    elseif instance.showValue then
                        for index, indicator in ipairs(instance.indicators) do
                            assert(indicator.value.properties.text == drawn["text" .. index])
                        end
                    end
                end
                local before = writes(instance.panel.root)
                task:step(1, "run", 220)
                assert(writes(instance.panel.root) == before, "stable control frames must not repaint")
                local resized = { x = 0, y = 0, w = rect.w + 20, h = rect.h + 30 }
                panel.update(instance, resized)
                assert(instance.panel.root.properties.w == resized.w)
                assert(instance.panel.root.properties.h == resized.h)
                local scheduler = fixture.module("lib/scheduler.lua").new({ steady = 1250, background = 1130 })
                assert(scheduler:add({ id = "control-panel", decl = panel.decl, instance = task, due = 240 }))
                local previous = entry.nextRefresh
                before = writes(instance.panel.root)
                scheduler:run("background", 240, 0)
                assert(entry.nextRefresh == previous and writes(instance.panel.root) == before)
                scheduler:run("steady", 240, 0)
                assert(entry.nextRefresh == 260, "foreground must retain a release skipped in background")
            end
        end
    end
end
print("Control panel tasks: readings, intervals, stable frames, resizing and hidden eligibility passed")
