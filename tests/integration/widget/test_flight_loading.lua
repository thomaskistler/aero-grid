-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local path = root .. "/build/test-widget-fixture/"
local definition = fixture.module("main.lua")
local yaml = fixture.module("lib/yaml.lua")
local storeModule = fixture.module("lib/model_settings_store.lua")
local filename = model.getInfo().filename
local values = fixture.module("lib/flight_config.lua").defaults()
values.history = {}
for index = 1, 96 do
    values.history[index] = "retained obsolete value " .. index
end
local content = assert(yaml.serialize({
    version = 1,
    modelFilename = filename,
    revision = 7,
    armed = "SFv",
    flight = values,
}))
content = string.gsub(content, "\n", " # " .. string.rep("comment ", 12) .. "\n")
os.execute("mkdir -p '" .. path .. "AEROGRID/models'")
local settingsPath = assert(storeModule.path(path, filename))
local file = assert(io.open(settingsPath, "w"))
file:write(content)
file:close()
fixture.reset()
local function create()
    return definition.create(
        { x = 0, y = 0, w = 480, h = 272 },
        { Layout = "review-flight-mode", Theme = "modern-dark" },
        path
    )
end
local first, second = create(), create()
local seen, waiting, replaced, maximum = {}, false, false, 0
local expectedArmed = "SFv"
local function step(context, callback)
    if context.stage then
        seen[context.stage] = true
    end
    waiting = waiting or context.stage == "flight-load-wait"
    local work = context.flightLoading
    if work and work.owner and work.owner.store then
        work.owner.store.load = function()
            error("runtime loading must never use synchronous store.load")
        end
    end
    if context == first and work and work.job and work.job.stage == "publish" and not replaced then
        local job = work.job
        context.dashboardLoader.beginLoad(context)
        assert(context.flightPublicationJob == job, "replacement must retain started model publication")
        replaced = true
    end
    local runtime = context.serviceRuntime
    if runtime and runtime.byId.armed then
        local owner = context.flightBroker
        assert(owner.documentLoaded and (owner.document and owner.document.armed) == expectedArmed)
        assert(
            runtime.modelArmed == expectedArmed and context.modelArmed == expectedArmed,
            "dashboard Armed must capture the loaded model condition"
        )
    end
    local instructions = 0
    debug.sethook(function()
        instructions = instructions + 200
    end, "", 200)
    local ok, message = pcall(callback, context)
    debug.sethook()
    assert(ok, message)
    maximum = math.max(maximum, instructions)
    assert(instructions <= 15000, "staged Flight loading callback exceeded budget: " .. instructions)
end
for _ = 1, 2000 do
    if not first.stage and not first.reloadState and not second.stage and not second.reloadState then
        break
    end
    fixture.tick(10)
    step(first, definition.refresh)
    step(second, definition.background)
end
assert(not first.stage and not first.reloadState and not second.stage and not second.reloadState)
assert(waiting and replaced and not first.flightPublicationJob)
assert(first.flightBroker == second.flightBroker and first.flightBroker.document.revision == 7)
assert(first.flightBroker.document.flight.history == nil)
assert(#first.errors == 0 and #second.errors == 0)
for _, stage in ipairs({
    "flight-store-module",
    "flight-store-writer",
    "flight-store-armed",
    "flight-store-create",
    "flight-load-begin",
    "flight-load",
    "flight-register-begin",
    "flight-register",
    "load-finish",
}) do
    assert(seen[stage], "missing explicit Flight loading stage " .. stage)
end
file = assert(io.open(settingsPath, "r"))
assert(file:read("*a") == content, "loading must not rewrite persisted settings")
file:close()
for _, mode in ipairs({ "missing", "recovered", "damaged" }) do
    os.remove(settingsPath)
    os.remove(settingsPath .. ".bak")
    if mode ~= "missing" then
        file = assert(io.open(settingsPath, "w"))
        file:write("version: 0\n")
        file:close()
    end
    if mode == "recovered" then
        file = assert(io.open(settingsPath .. ".bak", "w"))
        file:write(content)
        file:close()
    end
    definition = fixture.module("main.lua")
    fixture.reset()
    expectedArmed = mode == "recovered" and "SFv" or nil
    local context = create()
    local function settle()
        for _ = 1, 2000 do
            if not context.stage and not context.reloadState then
                return
            end
            fixture.tick(10)
            step(context, definition.background)
        end
        error("Flight initial load did not settle: " .. mode)
    end
    settle()
    local owner = context.flightBroker
    assert(owner.documentLoaded)
    if mode == "damaged" then
        assert(string.find(owner.loadError, "Unsupported model settings schema", 1, true))
    else
        assert(not owner.loadError and owner.document)
        assert(context.flightLoadInfo[mode == "missing" and "missing" or "recovered"])
    end
    local document, loadError = owner.document, owner.loadError
    owner.store.startLoad = function()
        error("same-model reload must reuse cached success or failure")
    end
    context.dashboardLoader.beginLoad(context)
    settle()
    assert(owner.document == document and owner.loadError == loadError)
end
print("Flight loading: pre-Armed selection, shared ownership, publication replacement and budgets passed: " .. maximum)
