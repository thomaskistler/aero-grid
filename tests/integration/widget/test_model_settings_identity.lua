-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local path = fixture.path
local yaml = fixture.module("lib/yaml.lua")
local filename = fixture.radio.modelFilename
local record = path .. "AEROGRID/models/AGTEST.yaml"
assert(os.execute("mkdir -p '" .. path .. "AEROGRID/models'"))
local original = assert(yaml.serialize({
    version = 1,
    revision = 3,
    modelFilename = "source.yml",
    armed = "SFv",
    flight = fixture.module("lib/flight_config.lua").defaults(),
}))
fixture.writeFile(record, original)
fixture.radio.outputs[31] = { name = "AGTEST", min = -800, max = 900, offset = 25, revert = 1, curve = 2 }
fixture.radio.values[305] = 1024
fixture.lvglMock.setAppMode(true)
fixture.lvglMock.setFullScreen(true)
local definition = fixture.module("main.lua")
local first, second
local writes = 0
local setOutput = model.setOutput
model.setOutput = function(index, output)
    local owner = first.flightFactory.broker
    assert(owner.documentLoaded and owner.document.modelFilename == owner.filename, "accept before adoption")
    assert(fixture.radio.values[305] == 1024, "exercise linking while armed")
    assert(fstat(path .. "AEROGRID/models/" .. output.name .. ".yaml"), "install the record first")
    writes = writes + 1
    setOutput(index, output)
end
first = definition.create({ x = 0, y = 0, w = 480, h = 272 }, { Layout = "Empty" }, path)
second = definition.create({ x = 0, y = 0, w = 480, h = 272 }, { Layout = "Empty" }, path)
local function pump(count)
    for _ = 1, count do
        fixture.tick(5)
        local before, instructions = writes, 0
        debug.sethook(function()
            instructions = instructions + 100
        end, "", 100)
        definition.refresh(first)
        debug.sethook()
        if writes ~= before then
            assert(instructions <= 20000, "adoption callback exceeded native instruction limit: " .. instructions)
        end
        definition.background(second)
    end
end
pump(250)
local owner = first.flightFactory.broker
assert(owner == second.flightFactory.broker and owner.documentLoaded)
assert(owner.document.revision == 3 and owner.document.armed == "SFv")
local id = fixture.radio.outputs[31].name
assert(id ~= "AGTEST" and string.match(id, "^AG[A-Z0-9]+$") and writes == 1)
assert(not owner.settingsAdoption and not owner.loadError and not owner.state.persistenceError)
assert(fixture.radio.outputs[31].min == -800 and fixture.radio.outputs[31].curve == 2)
local file = assert(fixture.hostIo.open(record, "r"))
assert(file:read("*a") == original, "the source record stays untouched")
file:close()
local copy = assert(fixture.hostIo.open(path .. "AEROGRID/models/" .. id .. ".yaml", "r"))
assert(yaml.parse(copy:read("*a")).modelFilename == filename)
copy:close()
pump(100)
assert(writes == 1, "multiple dashboards cannot repeatedly fork")

-- A failed adoption is reported rather than silently kept as pending work.
fixture.radio.modelFilename = "failed-copy.yml"
fixture.radio.outputs[31].name = "AGTEST"
fixture.radio.values[305] = 1024
owner.store.adopt = function()
    return false, "injected record failure"
end
pump(150)
assert(not owner.settingsAdoption and string.find(owner.state.persistenceError, "injected record failure", 1, true))
assert(writes == 1)

-- A model with an existing CH32 name cannot claim the channel.
fixture.radio.modelFilename = "new-model.yml"
fixture.radio.outputs[31].name = "MOTOR"
pump(150)
assert(owner.filename == "new-model.yml" and not owner.settingsAdoption and owner.document.revision == 0)
local ok, message = owner.store:save("new-model.yml", 0, fixture.module("lib/flight_config.lua").defaults())
assert(not ok and string.find(message, "Clear the CH32 name", 1, true))
assert(writes == 1 and fixture.radio.outputs[31].name == "MOTOR")

-- Selecting the arm switch while armed can create the first settings link.
fixture.radio.outputs[31].name = ""
fixture.radio.values[305] = 1024
ok, message = owner.store:save("new-model.yml", 0, fixture.module("lib/flight_config.lua").defaults(), "SFv")
assert(ok, message)
assert(writes == 2 and owner.store:load("new-model.yml").armed == "SFv")
assert(fixture.radio.outputs[31].min == -800 and fixture.radio.outputs[31].curve == 2)
