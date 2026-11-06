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
local seen, waiting, replaced, partialRuntime, maximum = {}, false, false, false, 0
for _, context in ipairs({ first, second }) do
    local advance = context.dashboardLoader.advanceLoad
    context.dashboardLoader.advanceLoad = function(current)
        seen[current.stage] = true
        return advance(current)
    end
end
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
    local owningWork = first.flightLoading
    if owningWork and owningWork.job and owningWork.job.stage == "publish" and not replaced then
        local job = owningWork.job
        first.dashboardLoader.beginLoad(first)
        assert(first.flightPublicationJob == job, "replacement must retain started model publication")
        replaced = true
    end
    local runtime = context.serviceRuntime
    local initializing = context.stage == "services" and runtime and not runtime.byId.telemetry
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
    if initializing then
        assert(context.scheduler.lastPlan.kind == "loader", "empty service registries must admit bounded setup work")
        partialRuntime = true
    end
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
assert(waiting and replaced and partialRuntime and not first.flightPublicationJob)
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
for _, parkedStage in ipairs({
    "flight-identity", "flight-store-writer", "flight-store-create",
    "flight-load-begin", "flight-load", "publish", "missing", "damaged", "recovered",
}) do
    os.remove(settingsPath)
    os.remove(settingsPath .. ".bak")
    if parkedStage ~= "missing" then
        file = assert(io.open(settingsPath, "w"))
        file:write((parkedStage == "damaged" or parkedStage == "recovered") and "version: 0\n" or content)
        file:close()
    end
    if parkedStage == "recovered" then
        file = assert(io.open(settingsPath .. ".bak", "w"))
        file:write(content)
        file:close()
    end
    local target = (parkedStage == "missing" or parkedStage == "damaged" or parkedStage == "recovered")
        and "flight-identity" or parkedStage
    definition = fixture.module("main.lua")
    fixture.reset()
    local creator = create()
    for _ = 1, 2000 do
        local work = creator.flightLoading
        if creator.stage == target
            or target == "publish" and work and work.job and work.job.stage == "publish" then
            break
        end
        fixture.tick(10)
        definition.refresh(creator)
    end
    local owner = assert(creator.flightBroker)
    assert(not owner.documentLoaded, "creator must stop before atomic publication")
    local hidden, observer = create(), create()
    for _ = 1, 1000 do
        if hidden.stage == "flight-load-wait" then break end
        fixture.tick(10)
        definition.background(hidden)
    end
    assert(hidden.stage == "flight-load-wait")
    local stage, job = creator.stage, creator.flightLoading.job
    creator.reloadState = "clear"
    definition.background(hidden)
    assert(creator.stage == stage and creator.flightLoading.job == job,
        "a cancelled creator must not be helped")
    assert(hidden.dashboardLoader.workBound(hidden) == 100)
    creator.reloadState = nil
    creator.pageRetirement = {}
    definition.background(hidden)
    assert(creator.stage == stage and creator.flightLoading.job == job)
    creator.pageRetirement = nil
    local owning = owner.context
    owner.context = nil
    definition.background(hidden)
    assert(owner:owningContext() == nil and creator.stage == stage,
        "waiting must not replace a collected owner")
    owner.context = owning
    local ownerBound, unproven = creator.dashboardLoader.workBound, nil
    local proof = creator.dashboardLoader.advanceLoad
    creator.dashboardLoader.workBound = function(current)
        if current == creator and unproven ~= nil then
            return unproven ~= "nil" and unproven or nil
        end
        return ownerBound(current)
    end
    creator.dashboardLoader.advanceLoad = function(current)
        assert(current ~= creator, "an unproven owner atom must not be helped without reservation")
        return proof(current)
    end
    for _, value in ipairs({ "nil", 3701, 3800, "unmeasured" }) do
        unproven = value
        assert(hidden.dashboardLoader.workBound(hidden) == nil, tostring(value))
        local plan = hidden.scheduler.lastPlan
        local kind = plan.kind
        plan.kind = "unadmitted"
        fixture.tick(10)
        definition.background(hidden)
        assert(creator.stage == stage and creator.flightLoading.job == job and hidden.stage == "flight-load-wait",
            "an unproven owner atom must leave both contexts waiting")
        assert(plan.kind ~= "loader", "no services may be admitted under an unproven bound")
        plan.kind = kind
    end
    unproven = 3700
    assert(hidden.dashboardLoader.workBound(hidden) == 4000, "a fitting owner atom keeps its exact reservation")
    unproven = nil
    creator.dashboardLoader.workBound, creator.dashboardLoader.advanceLoad = ownerBound, proof
    local advances, advance = 0, creator.dashboardLoader.advanceLoad
    local activeHelper, reservation
    creator.dashboardLoader.advanceLoad = function(current)
        assert(activeHelper.scheduler.lastPlan.kind == "loader")
        assert(reservation and reservation <= 4000
            and activeHelper.schedulerHost.legacy.spent >= reservation,
            "helping must reserve the full enclosing atom before owner mutation")
        advances = advances + 1
        return advance(current)
    end
    for _ = 1, 2000 do
        if not hidden.stage and not observer.stage then break end
        for _, context in ipairs({ hidden, observer }) do
            if owner.store then
                owner.store.load = function() error("shared initialization must not load synchronously") end
            end
            local before, instructions = advances, 0
            activeHelper, reservation = context, context.dashboardLoader.workBound(context)
            fixture.tick(10)
            debug.sethook(function() instructions = instructions + 200 end, "", 200)
            local ok, message = pcall(definition.background, context)
            debug.sethook()
            assert(ok, message)
            assert(advances - before <= 1, "one callback may help at most one owner atom")
            assert(instructions <= 15000, "shared loading exceeded the callback ceiling")
            assert(owner:owningContext() == creator)
            assert(not owner.loadError or parkedStage == "damaged")
            assert(not owner.documentLoaded or parkedStage == "damaged"
                or owner.document.revision == (parkedStage == "missing" and 0 or 7))
        end
    end
    assert(not hidden.stage and not observer.stage and owner.documentLoaded, parkedStage)
    if parkedStage == "damaged" then
        assert(string.find(owner.loadError, "Unsupported model settings schema", 1, true))
    else
        assert(owner.document.armed == (parkedStage ~= "missing" and "SFv" or nil))
        assert(not owner.document.flight or owner.document.flight.history == nil)
    end
    assert(creator.flightLoading == nil and advances > 0)
    assert(#creator.errors == 0 and #hidden.errors == 0 and #observer.errors == 0)
end
print("Flight loading: pre-Armed selection, shared ownership, publication replacement and budgets passed: " .. maximum)
