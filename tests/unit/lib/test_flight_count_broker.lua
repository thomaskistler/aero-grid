-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local load = assert(loadfile(root .. "/tests/support/module_loader.lua"))(root)
local memory = assert(loadfile(root .. "/tests/support/memory_files.lua"))()
local files, operations = memory()
local config, support = load("lib/flight_config.lua"), load("lib/services.lua")
local detector, storeModule = load("lib/flight_service.lua"), load("lib/model_settings_store.lua")
local filename, external, now = "plane.yml", 123, 0
local output, disarmed = { name = "AGTEST" }, true
local env = {
    getInfo = function()
        return { filename = filename }
    end,
    getGlobalVariable = function()
        assert(external ~= nil, "initialized internal counts must not read external GVs")
        return external
    end,
    getGlobalVariableDetails = function()
        return { prec = 0 }
    end,
    setGlobalVariable = function()
        error("counting must never write a GV")
    end,
    getSwitchIndex = function()
        return 1
    end,
    getSwitchValue = function()
        return not disarmed
    end,
}
local storeEnv = {
    modelFilename = function()
        return filename
    end,
    flightConfig = config,
    flightCount = load("lib/flight_count.lua"),
    armedConfig = load("lib/armed_service.lua"),
    verifiedFile = load("lib/verified_file.lua"),
    getOutput = function()
        return output
    end,
    setOutput = function(_, value)
        output = value
    end,
    isDisarmed = function()
        return disarmed
    end,
    generateId = function()
        return "AGNEW1"
    end,
}
local sidecar = load("lib/model_settings_sidecar.lua")
storeEnv.sidecar = sidecar
local store = storeModule.new("/WIDGETS/AeroGrid/", load("lib/yaml.lua"), storeEnv, operations)

local function restart()
    local owner = detector.newBroker(env, support, { control = load("lib/control_service.lua") }, config)
    owner.store = store
    owner:reset(filename)
    owner:setDocument(assert(store:load(filename)))
    return owner
end

local function step(owner, times)
    for _ = 1, times or 30 do
        now = now + 20
        owner:setup(now, false)
        for _, task in ipairs(owner:tasks()) do
            if task.name == "flight.count" and now >= (task.due or 0) then
                local _, again = task.step(task, now, 0)
                if again then
                    task.step(task, now, task.cost)
                end
            end
        end
    end
end

local owner = restart()
step(owner)
assert(owner.view.count == 0 and owner.view.displayCount == 0 and owner.view.countAvailable)
assert(store:load(filename).flightCount == 0, "fresh models do not import arbitrary GV9 values")
assert(owner.session == nil, "unconfigured detectors still publish and persist totals")
external = nil
files["/MODELS/plane.yml"] = "invalid model file; initialized totals must not reimport it"
owner = restart()
step(owner)
assert(owner.view.count == 0 and not owner.view.countError, "initialized zero survives restart without reimport")

assert(owner:incrementCount() == 1)
operations.inject("write")
step(owner)
assert(owner.view.count == 1 and owner.pendingCount.failed and owner.view.countError)
assert(store:load(filename).flightCount == 0, "a failed write must retain the saved total")
local pending = owner.pendingCount
step(owner)
assert(owner.pendingCount == pending and owner.view.count == 1, "failed writes must not duplicate increments")
operations.inject(nil)
local saved, document = store:save(filename, 0, config.resolve({ motorSource = "ch5" }), "")
assert(saved, document)
owner:setDocument(document)
step(owner)
assert(owner.pendingCount == nil and owner.view.count == 1 and not owner.view.countError)
document = assert(store:load(filename))
assert(document.flightCount == 1 and document.flight.motorSource == "ch5" and document.armed == "")
owner = restart()
step(owner)
assert(owner.view.count == 1, "saved counts survive widget removal and restart")

external = 842
local values = config.resolve(document.flight)
values.countSource = "gv9"
saved, document = store:save(filename, document.revision, values, "")
assert(saved, document)
owner:setDocument(document)
step(owner)
assert(owner.view.displayCount == 842 and owner.view.count == 1)
assert(owner:incrementCount() == 2)
step(owner)
assert(owner.view.count == 2 and owner.view.displayCount == 842)
values.countSource = "internal"
saved, document = store:save(filename, document.revision, values, "")
assert(saved, document)
owner:setDocument(document)
external = nil
step(owner)
assert(owner.view.displayCount == 2 and store:load(filename).flightCount == 2)
assert(owner:incrementCount() == 3)
local originalPath = assert(sidecar.path("/WIDGETS/AeroGrid/", "AGTEST"))
local original = files[originalPath]
filename = "other.yml"
step(owner)
assert(owner.view.countError and files[originalPath] == original, "model changes must prevent pending writes")
assert(output.name == "AGTEST")

filename, output, disarmed = "fresh.yml", { name = "" }, false
owner = restart()
local host = {}
owner.members[host] = { modelFilename = filename, legacy = { armed = "L01" } }
step(owner)
assert(owner.pendingCount == nil and owner.view.count == 0 and output.name == "AGNEW1" and not owner.view.countError)
assert(store:load(filename).flightCount == 0, "initial count persists while armed")
assert(store:load(filename).armed == "L01", "released layout arm switches convert once into model settings")

print("Flight count initialization, restart, source switching and persistence recovery passed")
