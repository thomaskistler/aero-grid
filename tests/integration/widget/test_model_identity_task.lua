-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local dashboard = fixture.createLoaded(nil, { Layout = "review-metric", Theme = "modern-dark" })
local reference = dashboard.panels[1].instance
local panel = fixture.module("panels/model-identity.lua")
local host = fixture.module("lib/panel_host.lua")
local support = fixture.module("lib/services.lua")
local builder = reference.themeBuilder

local function writes(node)
    local total = node.writes
    for _, child in ipairs(node.children) do
        total = total + writes(child)
    end
    return total
end

local function run()
    for _, mode in ipairs({ "modern-dark", "modern-light" }) do
        local theme = builder.build(mode)
        for _, shape in ipairs({
            { 1, 1, 117, 65 },
            { 2, 1, 238, 65 },
            { 2, 2, 238, 134 },
            { 1, 4, 160, 480 },
            { 4, 4, 800, 480 },
        }) do
            for _, presentation in ipairs({ "auto", "name", "image", "both" }) do
                for _, labels in ipairs({ false, true }) do
                    for filesystem = 1, 4 do
                        if filesystem == 1 then
                            fstat = function()
                                return { size = 1024 }
                            end
                        elseif filesystem == 2 then
                            fstat = function()
                                return nil
                            end
                        elseif filesystem == 3 then
                            fstat = nil
                        else
                            fstat = function()
                                error("deliberate identity filesystem failure")
                            end
                        end
                        local feed = { available = true, name = "MODEL", labels = "GLIDER" }
                        local settings = assert(host.resolveSettings(panel, {
                            presentation = presentation,
                            showLabels = labels,
                        }))
                        local services = {
                            theme = theme,
                            themeBuilder = builder,
                            primitives = reference.primitives,
                            fonts = builder.typography(shape[1], shape[2]),
                            span = { colSpan = shape[1], rowSpan = shape[2] },
                            model = {
                                identity = function()
                                    return support.snapshot(feed)
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
                        for cycle = 1, 8 do
                            feed.name = cycle % 2 == 0 and "MMMMMMMMMMMMMMM" or "ggggy AEROPLANE"
                            feed.labels = cycle % 2 == 0 and "GLIDER, ELECTRIC" or ""
                            feed.bitmapPath = cycle == 1 and nil or "/IMAGES/fixture.png"
                            feed.available = cycle ~= 6
                            local previousText, previousState, previousLabels =
                                instance.text, instance.stateName, instance.labelsText
                            if cycle == 8 then
                                instance.feed = nil
                            end
                            local now = cycle * 500
                            assert(task:step(1, "run", now) == 500 and task.used == 1)
                            assert(entry.nextRefresh == now + 500)
                            if cycle == 8 then
                                assert(instance.text == previousText and instance.stateName == previousState)
                                assert(instance.labelsText == previousLabels)
                            else
                                local available = cycle ~= 6
                                assert(instance.text == (available and feed.name or "--"))
                                assert(instance.stateName == (available and "normal" or "unavailable"))
                                if instance.showLabels then
                                    assert(instance.labelsText == (available and feed.labels or ""))
                                end
                            end
                            if cycle == 2 and instance.area.showImage then
                                if filesystem == 2 or filesystem == 4 then
                                    assert(instance.imageRejected == feed.bitmapPath and not instance.image)
                                else
                                    assert(instance.imagePath == feed.bitmapPath and instance.image)
                                end
                            end
                            local before = writes(instance.panel.root)
                            task:step(1, "run", now)
                            assert(writes(instance.panel.root) == before, "stable identity frames must not repaint")
                        end
                        local resized = { x = 0, y = 0, w = rect.w + 20, h = rect.h + 30 }
                        panel.update(instance, resized)
                        assert(instance.panel.root.properties.w == resized.w)
                        assert(instance.panel.root.properties.h == resized.h)
                        local scheduler = fixture.module("lib/scheduler.lua").new({ steady = 1250, background = 1130 })
                        assert(scheduler:add({ id = "identity", decl = panel.decl, instance = task, due = 5000 }))
                        local previous, before = entry.nextRefresh, writes(instance.panel.root)
                        scheduler:run("background", 5000, 0)
                        assert(entry.nextRefresh == previous and writes(instance.panel.root) == before)
                        scheduler:run("steady", 5000, 0)
                        assert(entry.nextRefresh == 5500)
                    end
                end
            end
        end
    end
end
local previous = fstat
local ok, message = pcall(run)
fstat = previous
assert(ok, message)
print("Model identity task: image lookup/fallback, heading changes and hidden eligibility passed")
