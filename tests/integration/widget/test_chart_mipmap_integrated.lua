-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local definition = fixture.module("main.lua")
local yaml = fixture.module("lib/yaml.lua")
fixture.reset()
fixture.radio.rssi, fixture.radio.values[300] = 80, -1024
local sensors = {
    [12] = { type = 0, id = 9, instance = 0, unit = 9, prec = 2 },
    [37] = { type = 0, id = 2, instance = 0, unit = 40, prec = 0 },
    [49] = { type = 0, id = 2, instance = 2, unit = 8, prec = 1 },
    [59] = { type = 0, id = 2, instance = 5, unit = 0, prec = 0 },
}
local sensorValues = { [12] = 0, [37] = { lat = 1, lon = 2, delay = 0 }, [49] = 0, [59] = 8 }
model.getModule = function(index)
    return { Type = index == 0 and 5 or 0 }
end
model.getSensor = function(index)
    return sensors[index]
end
getSourceValue = function(id)
    return sensorValues[(id - 6000) / 3], true, true
end
fixture.radio.fields.ch3 = { id = 4400, name = "ch3" }
fixture.radio.values[4400] = 0
for index, sensor in pairs(sensors) do
    fixture.radio.fields["telem" .. (index + 1)] = { id = 6000 + index * 3, unit = sensor.unit }
end
local path = root .. "/build/test-widget-fixture/"
local layout = { version = 3, grid = { columns = 4, rows = 4 }, panels = {} }
for chart = 1, 2 do
    local metrics = {}
    for series = 1, 3 do
        local index = (chart - 1) * 3 + series
        local name = "Q" .. index
        fixture.radio.fields[name] = { id = 5000 + index, name = name, unit = 1 }
        fixture.radio.values[5000 + index] = index / 10
        metrics[series] = { source = name, precision = 3, rangeMin = -1, rangeMax = 2 }
    end
    layout.panels[chart] = {
        id = "chart" .. chart,
        type = "chart",
        col = 0,
        row = (chart - 1) * 2,
        colSpan = 4,
        rowSpan = 2,
        config = { armSwitch = "SAv", metrics = metrics },
    }
end
fixture.radioMock.indexFields()
local file = assert(io.open(path .. "layouts/mipmap-integrated.yaml", "w"))
io.write(file, assert(yaml.serialize(layout)))
io.close(file)
local context = definition.create({ x = 0, y = 0, w = 480, h = 272 }, {
    Layout = "mipmap-integrated",
    Theme = "modern-dark",
}, path)
context.chartMipmap = fixture.module("lib/chart_mipmap.lua")
context.chartMipmapRenderer = fixture.module("lib/chart_mipmap_renderer.lua")
local worst, callbacks = 0, 0
local function pump(count)
    for _ = 1, count do
        fixture.tick(5)
        if fixture.radio.values[300] > 0 then
            for index = 1, 24 do
                if fixture.radio.values[5000 + index] then
                    fixture.radio.values[5000 + index] = (getTime() * 17 + index * 13) % 97 / 100
                end
            end
        end
        fixture.lvglMock.setPropertyValidation(false)
        fixture.lvglMock.setCallCounting(false)
        fixture.lcdMock.setTextMeasurement(false)
        local instructions = 0
        debug.sethook(function()
            instructions = instructions + 100
        end, "", 100)
        definition.refresh(context)
        debug.sethook()
        fixture.lvglMock.setPropertyValidation(true)
        fixture.lvglMock.setCallCounting(true)
        fixture.lcdMock.setTextMeasurement(true)
        fixture.lvglMock.settle()
        callbacks, worst = callbacks + 1, math.max(worst, instructions)
        -- Lua mock setters are not firmware instruction costs. The native
        -- runtime gate enforces the whole-callback limit with real setters.
        assert(#context.errors == 0, table.concat(context.errors, "; "))
    end
end
pump(800)
context.flightBroker:setDocument({
    modelFilename = context.flightBroker.filename,
    revision = 1,
    armed = "SAv",
    flight = context.flightConfig.resolve({ smartDetection = true }),
})
pump(400)
fixture.radio.values[300] = 1024
pump(800)
for _, entry in ipairs(context.panels) do
    local chart = entry.instance
    assert(chart.mipmapPrepared and next(chart.mipmapRenderer.published), "normal chart did not publish mipmap output")
    assert(chart.backPlot == nil, "single-pool renderer allocated legacy double buffers")
    assert(#chart.mipmapRenderer.objects == chart.area.w * 3)
end
local history = context.serviceRuntime.byId.history
for index = 7, 24 do
    fixture.radio.fields["Q" .. index] = { id = 5000 + index, name = "Q" .. index, unit = 1 }
    fixture.radio.values[5000 + index] = index / 10
    history:subscribe("Q" .. index, { armSwitch = "SAv", precision = 3 })
end
fixture.radioMock.indexFields()
assert(history.count == 24)
pump(1800)
local first, sibling = context.panels[1].instance, context.panels[2].instance
local siblingMap = sibling.mipmapConsumers[1].map
local oldMap, oldRoot = first.mipmapConsumers[1].map, first.mipmapRenderer.root
context.panels[1].module.update(first, { x = 0, y = 0, w = first.rect.w - 30, h = first.rect.h })
assert(first.mipmapConsumers[1].map ~= oldMap)
assert(sibling.mipmapConsumers[1].map == siblingMap)
pump(500)
assert(oldRoot.cleared, "resize did not retire the old native pool")
assert(first.mipmapPrepared and next(first.mipmapRenderer.published))
assert(first.backPlot == nil)
local owner = first.mipmapConsumers[1]
-- A real recording resume uses the existing compressed-gap/connector renderer.
fixture.radio.values[300] = -1024
pump(40)
fixture.radio.values[300] = 1024
pump(80)
assert(first.session.resumeLast > 0, "fixture did not create an actual pause/resume")
for _ = 1, 1000 do
    if first.mipmapRenderer == nil then
        break
    end
    pump(1)
end
assert(first.mipmapRenderer == nil and owner.map ~= nil, "resume fallback lost recording observer")
context.panels[1].module.destroy(first)
context.panels[2].module.destroy(sibling)
assert(first.mipmapConsumers == nil and sibling.mipmapConsumers == nil)
print(
    string.format(
        "Normal integrated chart: %d callbacks, worst%d instructions; local resize and resume fallback pass",
        callbacks,
        worst
    )
)
