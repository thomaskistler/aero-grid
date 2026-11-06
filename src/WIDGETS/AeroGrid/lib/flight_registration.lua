-- SPDX-License-Identifier: GPL-2.0-only

local registration = { RUNTIME_API = 1 }

registration.BOUNDS = {
    begin = 120,
    retained = 180,
    sources = 270,
    arms = 350,
    claim = 350,
    declaration = 350,
    commit = 200,
    reject = 110,
    ["load-begin"] = 100,
    ["load-start"] = 400,
    ["publish-start"] = 400,
    publish = 400,
}

function registration.workBound(job)
    if job.done then
        return 0
    elseif job.stage == "load" then
        return job.store:loadWorkBound(job.load) + 300
    end
    return registration.BOUNDS[job.stage]
end

--- Load the owning broker's document before constructing dashboard Armed.
--- The caller initializes the store and broker identity in separate atoms.
function registration.beginLoad(context, store)
    local factory = context.flightFactory
    local owner = factory and factory.broker
    if not owner or owner:owningContext() ~= context or not factory.members[context] then
        return nil, "Only the owning Flight context can load model settings"
    elseif owner.documentLoaded then
        return { done = true, ok = not owner.loadError, error = owner.loadError }
    elseif not store then
        return nil, "Flight model settings store is unavailable"
    end
    return {
        stage = "load-start",
        context = context,
        factory = factory,
        owner = owner,
        member = factory.members[context],
        document = context.document,
        runtime = context.serviceRuntime,
        filename = context.modelFilename or owner.filename,
        store = store,
    }
end

function registration.begin(context, options)
    local factory = context.flightFactory
    local member = factory and factory.members[context]
    local document, runtime = context.document, context.serviceRuntime
    if not member then
        return { done = true, ok = true }
    elseif type(document) ~= "table" or not runtime or not runtime.byId.armed then
        return nil, "Flight registration requires the loaded document and Armed service"
    elseif document.legacyFlightArms ~= nil and type(document.legacyFlightArms) ~= "table" then
        return nil, "legacyFlightArms must be a mapping"
    elseif options and options.store and (not factory.broker or factory.broker:owningContext() ~= context) then
        return nil, "Only the owning Flight context can load model settings"
    end
    return {
        stage = "retained",
        context = context,
        factory = factory,
        member = member,
        document = document,
        runtime = runtime,
        filename = context.modelFilename or member.modelFilename,
        retained = {},
        original = document.legacyFlightArms or {},
        settings = {},
        declarations = {},
        sources = context.flightSources or {},
        index = 1,
        store = options and options.store,
        owner = factory.broker,
    }
end

local function declare(job, source, condition)
    local armed = job.runtime.byId.armed
    local name = armed.condition ~= nil and armed.condition or condition or ""
    if not armed.valid(name) then
        armed:state(condition)
    end
    job.source, job.condition = source, condition
    if name ~= "" and not armed.views[name] then
        job.claim = job.runtime.byId.control:startArmSwitch(name)
        job.stage = "claim"
    else
        job.stage = "declaration"
    end
end

local function advance(job)
    local context, owner = job.context, job.owner
    if job.stage ~= "publish" then
        assert(
            context.flightFactory == job.factory
                and job.factory.members[context] == job.member
                and context.document == job.document
                and context.serviceRuntime == job.runtime
                and (context.modelFilename or job.member.modelFilename) == job.filename,
            "Flight registration was replaced"
        )
    end
    if owner and job.stage ~= "publish" then
        assert(owner.filename == job.filename and owner:identity() == job.filename, "Model changed; reload dashboard")
        if job.store then
            assert(owner:owningContext() == context, "Flight registration owner was replaced")
        end
    end
    if job.stage == "retained" then
        local source, condition = next(job.original, job.cursor)
        job.cursor = source
        if source == nil then
            job.stage = "sources"
        else
            assert(
                type(source) == "string" and type(condition) == "string",
                "legacyFlightArms entries must name retained switches"
            )
            job.retained[source] = condition
        end
    elseif job.stage == "sources" then
        local placement = job.sources[job.index]
        if not placement then
            job.stage, job.cursor = "arms", nil
            return
        end
        local values = placement.config or {}
        if values._legacyFlight or values.armSwitch and values.armSwitch ~= "" then
            job.retained[placement.id] = values.armSwitch or ""
        end
        if values._legacyFlight then
            job.settings[placement.id] = context.flightConfig.resolve(values)
        end
        job.index = job.index + 1
    elseif job.stage == "arms" then
        local source, condition = next(job.retained, job.cursor)
        job.cursor = source
        if source ~= nil then
            assert(
                type(source) == "string" and type(condition) == "string",
                "legacyFlightArms entries must name retained switches"
            )
            declare(job, source, condition)
        elseif #job.declarations == 0 then
            declare(job, "Armed")
        else
            job.stage = "commit"
        end
    elseif job.stage == "claim" then
        if job.runtime.byId.control:advanceArmSwitch(job.claim) then
            job.stage, job.claim = "declaration", nil
        end
    elseif job.stage == "declaration" then
        local view = job.runtime.byId.armed:state(job.condition)
        job.declarations[#job.declarations + 1] = {
            source = job.source,
            armKey = view.key,
            settings = job.settings[job.source],
        }
        job.stage = job.cursor == nil and "commit" or "arms"
    elseif job.stage == "commit" then
        job.document.legacyFlightArms = next(job.retained) and job.retained or nil
        local member = job.member
        member.declarations, member.pending, member.error = job.declarations, false, nil
        member.modelFilename, member.layoutName = job.filename, context.layoutName
        job.factory.revision = (job.factory.revision or 0) + 1
        job.stage = job.store and owner and not owner.documentLoaded and "load-start" or "done"
    elseif job.stage == "load-start" then
        local message
        job.load, message = job.store:startLoad(job.filename)
        if not job.load then
            return message
        end
        job.stage = "load"
    elseif job.stage == "load" then
        local done, document, info = job.store:advanceLoad(job.load)
        if done then
            if not document then
                return info
            end
            job.loaded, job.loadInfo = document, info
            job.stage = "publish-start"
        end
    elseif job.stage == "publish-start" then
        local message
        job.publication, message = owner:startPublication(job.loaded)
        if not job.publication then
            return message
        end
        job.stage = "publish"
    elseif job.stage == "publish" then
        local done, ok, message = owner:advancePublication(job.publication)
        if done then
            if not ok then
                return message
            end
            job.stage = "done"
        end
    else
        error("Unknown Flight registration stage: " .. tostring(job.stage))
    end
end

function registration.advance(job)
    if job.done then
        return true, job.ok, job.error
    end
    local ok, message = pcall(advance, job)
    if not ok or message then
        job.done, job.ok, job.error = true, false, tostring(message)
        local owner = job.owner
        if
            ok
            and message
            and (job.stage == "load-start" or job.stage == "load")
            and owner
            and owner.filename == job.filename
            and not owner.documentLoaded
        then
            owner.loadError, owner.documentLoaded = job.error, true
        end
    elseif job.stage == "done" then
        job.done, job.ok = true, true
    else
        return false
    end
    return true, job.ok, job.error
end

function registration.configure(context)
    local member = context.flightFactory.members[context]
    if not member then
        return
    end
    local declarations = {}
    local retained = context.document.legacyFlightArms or {}
    assert(type(retained) == "table", "legacyFlightArms must be a mapping")
    local settingsBySource = {}
    for _, placement in ipairs(context.flightSources or {}) do
        local values = placement.config or {}
        if values._legacyFlight or values.armSwitch and values.armSwitch ~= "" then
            retained[placement.id] = values.armSwitch or ""
        end
        if values._legacyFlight then
            settingsBySource[placement.id] = context.flightConfig.resolve(values)
        end
    end
    context.document.legacyFlightArms = next(retained) and retained or nil
    local armed = context.serviceRuntime.byId.armed
    for source, condition in pairs(retained) do
        assert(
            type(source) == "string" and type(condition) == "string",
            "legacyFlightArms entries must name retained switches"
        )
        local view = armed:state(condition)
        declarations[#declarations + 1] = {
            source = source,
            armKey = view.key,
            settings = settingsBySource[source],
        }
    end
    if #declarations == 0 then
        local view = armed:state()
        declarations[1] = { source = "Armed", armKey = view.key }
    end
    member.declarations, member.pending, member.error = declarations, false, nil
    member.modelFilename, member.layoutName = context.modelFilename or member.modelFilename, context.layoutName
    context.flightFactory.revision = (context.flightFactory.revision or 0) + 1
end

return registration
