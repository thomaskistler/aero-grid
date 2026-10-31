-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local hostIo = io
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local definition = fixture.module("main.lua")
local yaml = fixture.module("lib/yaml.lua")
local equal = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual
local path = root .. "/build/test-widget-fixture/"
fixture.reset()

for index = 1, 3 do
    local file = assert(hostIo.open(path .. "layouts/background-" .. index .. ".yaml", "w"))
    file:write(assert(yaml.serialize({
        version = 5,
        grid = { columns = 4, rows = 4 },
        panels = {
            {
                id = "chart-" .. index,
                type = "chart",
                col = 0,
                row = 0,
                colSpan = 4,
                rowSpan = 1,
                config = { metrics = { { source = "Alt" } } },
            },
        },
    })))
    file:close()
end

os.execute("mkdir -p '" .. path .. "AEROGRID/models'")
local filename = model.getInfo().filename
local modelPath = assert(fixture.module("lib/model_settings_store.lua").path(path, filename))
local file = assert(hostIo.open(modelPath, "w"))
file:write(assert(yaml.serialize({
    version = 1,
    revision = 0,
    modelFilename = filename,
    armed = "SFv",
    sessionReset = "L52",
    flight = fixture.module("lib/flight_config.lua").resolve({ minFlightDuration = 1 }),
})))
file:close()

fixture.radio.fields.ch3 = { id = 306, name = "ch3" }
fixture.radio.values[305], fixture.radio.values[306] = -1024, 0
model.setGlobalVariable(8, 0, 0)
local widgets = {}
for index = 1, 3 do
    widgets[index] = definition.create(
        { x = 0, y = 0, w = 480, h = 272 },
        { Layout = "background-" .. index, Theme = "modern-dark" },
        path
    )
end

local first = widgets[1]
for _ = 1, 300 do
    fixture.tick(20)
    definition.refresh(first)
    if first.flightFactory.broker then
        break
    end
end
local owner = assert(first.flightFactory.broker)
assert(not owner.documentLoaded and not owner.store, "stop before the shared model store is initialized")
equal(widgets[2].serviceRuntime, nil)
equal(widgets[3].serviceRuntime, nil)

definition.background(widgets[2])
assert(owner.documentLoaded and not owner.loadError, "a hidden layout must initialize the shared model settings")
equal(owner.document.armed, "SFv")
equal(owner.document.sessionReset, "L52")

local function pump(count)
    for _ = 1, count do
        fixture.tick(20)
        for index, context in ipairs(widgets) do
            (index == 1 and definition.refresh or definition.background)(context)
            equal(#context.errors, 0, table.concat(context.errors, "\n"))
            assert(not context.flightErrorText, context.flightErrorText)
        end
    end
end
pump(300)
for _, context in ipairs(widgets) do
    assert(not context.stage and not context.reloadState, "each layout must finish loading")
    equal(context.flightBroker, owner, "all three layouts must share the same flight broker")
    equal(context.serviceRuntime.byId.armed:state().condition, "SFv")
end

fixture.radio.values[305] = 1024
pump(30)
equal(model.getGlobalVariable(8, 0), 1, "hidden and visible layouts must qualify only one flight")
assert(owner.state.active)
for _, context in ipairs(widgets) do
    equal(context.serviceRuntime.byId.history:session().flightLast, 1, "hidden charts must receive the flight")
end

definition.update(widgets[3], { Layout = "background-2", Theme = "modern-dark" })
pump(300)
assert(not widgets[3].stage and not widgets[3].reloadState, "a hidden layout must finish reloading")
equal(widgets[3].flightBroker, owner)
equal(model.getGlobalVariable(8, 0), 1, "reloading a hidden layout must not duplicate the flight")
