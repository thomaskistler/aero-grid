-- SPDX-License-Identifier: GPL-2.0-only

local flight = { RUNTIME_API = 1 }
local broker = {}
broker.__index = broker

local function reliable(reading, now)
    return reading
        and reading.available ~= false
        and reading.fresh == true
        and type(reading.updatedAt) == "number"
        and now >= reading.updatedAt
        and now - reading.updatedAt <= 100
end

--- Pure standard detector. The broker supplies once-only side-effect adapters.
function flight.advance(context, now)
    local armLive = context.controlAvailable ~= false
        and reliable(context.arm, now)
        and type(context.arm.value) == "boolean"
    local armed = armLive and context.arm.value
    if context.phase == "active" or context.phase == "ending" then
        if not armLive or armed then
            context.disarmedAt, context.phase = nil, "active"
        else
            context.disarmedAt = context.disarmedAt or now
            context.phase = "ending"
            if now - context.disarmedAt >= context.settings.disarmDuration * 100 then
                local duration = (context.disarmedAt - context.startedAt) / 100
                if context.completed then
                    context:completed(now)
                end
                context.phase = "ground"
                context.startedAt, context.disarmedAt = nil, nil
                if context.settings.history then
                    context.model:logFlight(context.date, duration, context.flightCount)
                end
                if context.settings.announcements then
                    context.model:announceFlight(context.flightCount, true)
                end
            end
        end
        return
    end
    if context.detectionAvailable == false or not context.feed.available then
        context.phase, context.startedAt = "ground", nil
        return
    end
    assert(
        context.feed.precision == 0
            and context.feed.raw >= 0
            and context.feed.raw <= 999
            and context.feed.raw == math.floor(context.feed.raw),
        "flight counter requires integer GV9 FM0 in the range 0..999, with precision 0"
    )
    assert(not context.motor.telemetry, "flight counter motorSource must be a radio-local motor channel")
    local motorLive = reliable(context.motor, now)
        and type(context.motor.value) == "number"
        and context.motor.value == context.motor.value
        and math.abs(context.motor.value) < math.huge
    local motor = motorLive and context.motor.value or -1024
    if context.settings.motorReversed then
        motor = -motor
    end
    local link = context.link
    local live = link.updatedAt and now >= link.updatedAt and now - link.updatedAt <= 100 and link.live
    if not (armed and motorLive and (motor + 1024) * 100 / 2048 > context.settings.minMotorPercent and live) then
        context.phase, context.startedAt = "ground", nil
        return
    end
    if not context.startedAt then
        context.startedAt, context.phase = now, "starting"
        if context.settings.history then
            context.date = context.model:flightDate()
        end
    end
    if now - context.startedAt >= context.settings.minFlightDuration * 100 then
        context.flightCount = context.control:incrementFlightCount()
        context.phase = "active"
        if context.qualified then
            context:qualified(now)
        end
        if context.settings.announcements then
            context.model:announceFlight(context.flightCount, false)
        end
    end
end

function flight.newBroker(env, support, modules, config, members)
    local self = setmetatable({
        env = env,
        support = support,
        modules = modules,
        config = config,
        members = members or setmetatable({}, { __mode = "k" }),
        epoch = 0,
        sequence = 0,
        serial = 0,
        events = {},
        errors = {},
        state = { phase = "ground", active = false, status = "unconfigured", revision = 0 },
    }, broker)
    self.view = support.snapshot(self.state)
    return self
end

function broker:error(kind, message)
    message = tostring(message)
    if self.errors[kind] ~= message then
        self.state.diagnosticRevision = (self.state.diagnosticRevision or 0) + 1
    end
    self.errors[kind] = message
    self.state[kind .. "Error"] = message
end

function broker:identity()
    local info = self.env.getInfo and self.env.getInfo()
    assert(
        type(info) == "table" and type(info.filename) == "string" and info.filename ~= "",
        "Flight detection requires model filename"
    )
    return info.filename
end

function broker:reset(filename)
    self.filename, self.epoch = filename, self.epoch + 1
    self.session, self.runtime, self.signature, self.output = nil, nil, nil, nil
    self.document, self.loadError = nil, nil
    self.events, self.errors = {}, {}
    self.lastTick, self.readyAfterDisarm = nil, nil
    for key in pairs(self.state) do
        self.state[key] = nil
    end
    self.state.modelFilename, self.state.epoch = filename, self.epoch
    self.state.phase, self.state.active, self.state.status = "ground", false, "unconfigured"
    self.state.revision = 0
    self.documentLoaded = false
    self.dormantRevision = nil
    self.cachedRevision, self.cachedProposal, self.cachedSignature, self.cachedStatus = nil, nil, nil, nil
end

function broker:setDocument(document)
    assert(
        document.modelFilename == nil or document.modelFilename == self.filename,
        "Model changed; reopen model settings"
    )
    if self.document and (self.document.revision or 0) ~= (document.revision or 0) then
        self.readyAfterDisarm = true
        self.errors.count, self.errors.detection = nil, nil
        self.state.countError, self.state.detectionError = nil, nil
        self.state.diagnosticRevision = (self.state.diagnosticRevision or 0) + 1
    end
    self.document = document
    self.loadError, self.state.persistenceError = nil, nil
    self.state.configurationRevision = document.revision or 0
    self.documentLoaded = true
    if self.factory then
        self.factory.revision = (self.factory.revision or 0) + 1
    end
end

function broker:boundary(kind, at, observedAt)
    self.sequence = self.sequence + 1
    local record = self.support.snapshot({
        epoch = self.epoch,
        sequence = self.sequence,
        flightId = self.session.flightId,
        count = self.session.flightCount,
        kind = kind,
        at = at,
        observedAt = observedAt,
        reason = self.session.reason or "standard",
    })
    self.events[#self.events + 1] = record
    if #self.events > 64 then
        table.remove(self.events, 1)
    end
end

function broker:boundaries(afterSequence, epoch)
    local result = {}
    local oldest = self.events[1] and self.events[1].sequence or self.sequence + 1
    for _, record in ipairs(self.events) do
        if record.sequence > (afterSequence or self.sequence) then
            result[#result + 1] = record
        end
    end
    return result,
        oldest,
        (epoch ~= nil and epoch ~= self.epoch) or (afterSequence ~= nil and afterSequence < oldest - 1)
end

function broker:resolveProposals()
    local selected, signature, pending, conflict
    local candidates = {}
    for _, participant in pairs(self.members) do
        if participant.modelFilename == self.filename then
            if participant.error then
                self.state.configurationError = participant.error
                return nil, nil, "error"
            elseif participant.pending then
                pending = true
            else
                for _, declaration in ipairs(participant.declarations or {}) do
                    local settings = self.document and self.document.flight or declaration.settings
                    if settings and declaration.armKey ~= "" then
                        local key = self.config.key(settings) .. ":" .. declaration.armKey
                        candidates[#candidates + 1] = participant.layoutName
                            .. "/"
                            .. declaration.source
                            .. " ("
                            .. declaration.armKey
                            .. ")"
                        if signature and signature ~= key then
                            conflict = true
                        end

                        signature, selected =
                            key, { settings = settings, armKey = declaration.armKey, armIndex = declaration.armIndex }
                    end
                end
            end
        end
    end
    if conflict then
        table.sort(candidates)
        self.state.configurationError = "Conflicting flight conditions: "
            .. table.concat(candidates, ", ")
            .. ". Use matching Armed settings and save one model flight configuration."
        return nil, nil, "conflict"
    end
    self.state.configurationError = nil
    if pending then
        return nil, nil, "loading"
    end
    return selected, signature, selected and "ready" or "unconfigured"
end

function broker:proposals(now)
    if self.factory and self.cachedRevision == self.factory.revision and now < (self.proposalsDue or 0) then
        return self.cachedProposal, self.cachedSignature, self.cachedStatus
    end
    local previous = self.state.configurationError
    local proposal, signature, status = self:resolveProposals()
    if previous ~= self.state.configurationError then
        self.state.diagnosticRevision = (self.state.diagnosticRevision or 0) + 1
    end
    self.cachedProposal, self.cachedSignature, self.cachedStatus = proposal, signature, status
    self.cachedRevision, self.proposalsDue = self.factory and self.factory.revision, now + 100
    return proposal, signature, status
end

function broker:validateOutput(name, armKey)
    if not name or name == "" then
        return
    end
    assert(self.env.setStickySwitch and self.env.getLogicalSwitch, "Flight-active output requires Sticky switch APIs")
    assert(string.gsub(armKey, "^!", "") ~= name, "Flight-active output cannot be the Armed input")
    local index = tonumber(string.sub(name, 2)) - 1
    local definition = self.env.getLogicalSwitch(index)
    assert(type(definition) == "table" and definition.func == 17, name .. " must be a dedicated Sticky logical switch")
    for _, key in ipairs({ "v1", "v2", "v3", "and", "delay", "duration" }) do
        assert((definition[key] or 0) == 0, name .. " must have no inputs, AND, delay or duration")
    end
    return index
end

function broker:effect(kind, operation, ...)
    if self:identity() ~= self.filename then
        error("Model changed during flight operation")
    end
    local ok, result = pcall(operation, ...)
    if not ok then
        self:error(kind, result)
    elseif kind ~= "output" and self.errors[kind] then
        self.errors[kind], self.state[kind .. "Error"] = nil, nil
        self.state.diagnosticRevision = (self.state.diagnosticRevision or 0) + 1
    end
    return ok, result
end

function broker:attach(proposal, signature, now)
    local settings = self.config.resolve(proposal.settings)
    local errors = self.config.validate(settings)
    assert(#errors == 0, table.concat(errors, "; "))
    self:validateOutput(settings.flightSwitch, proposal.armKey)
    local runtime = self.support.runtime(self.env)
    for _, id in ipairs({ "telemetry", "model", "control" }) do
        local instance = self.modules[id].new(self.env, self.support, runtime)
        self.support.register(runtime, instance, now)
    end
    local control, telemetry, modelService = runtime.byId.control, runtime.byId.telemetry, runtime.byId.model
    local session = {
        settings = settings,
        phase = "ground",
        feed = control:globalVariable(8, 0),
        arm = control:switch(proposal.armKey, proposal.armIndex),
        motor = telemetry:subscribe(settings.motorSource, false),
        link = telemetry:link(),
        armKey = proposal.armKey,
    }
    local owner = self
    session.control = {
        incrementFlightCount = function()
            local ok, count = owner:effect("count", control.incrementFlightCount, control)
            assert(ok, count)
            return count
        end,
    }
    session.model = {
        flightDate = function()
            return modelService:flightDate()
        end,
        logFlight = function(_, ...)
            owner:effect("history", modelService.logFlight, modelService, ...)
        end,
        announceFlight = function(_, ...)
            owner:effect("audio", modelService.announceFlight, modelService, ...)
        end,
    }
    function session:qualified(stamp)
        self.outputInitialized = true
        owner.serial = owner.serial + 1
        self.flightId, self.qualifiedAt = owner.serial, stamp
        owner:boundary("start", self.startedAt, stamp)
        owner.state.qualifiedAt = stamp
        if settings.flightSwitch ~= "" then
            owner.output =
                { name = settings.flightSwitch, armKey = self.armKey, desired = true, flightId = self.flightId }
        end
    end
    function session:completed(stamp)
        owner:boundary("end", self.disarmedAt, stamp)
        owner.state.endedAt, owner.state.completedAt = self.disarmedAt, stamp
        if owner.output then
            owner.output.desired, owner.output.queued = false, nil
        end
    end
    if self.signature and self.signature ~= signature then
        self.readyAfterDisarm = true
    end
    self.runtime, self.session, self.signature = runtime, session, signature
    if self.errors.detection then
        self.errors.detection, self.state.detectionError = nil, nil
        self.state.diagnosticRevision = (self.state.diagnosticRevision or 0) + 1
    end
    self.state.armKey = proposal.armKey
    self.state.startedAt, self.state.qualifiedAt, self.state.endedAt, self.state.completedAt = nil, nil, nil, nil
end

function broker:flushOutput(now)
    local output = self.output
    if not output or output.queuedAt == now then
        return
    end
    local ok, index = pcall(self.validateOutput, self, output.name, output.armKey)
    if not ok then
        self:error("output", index)
        return
    end
    local condition = self.env.getSwitchIndex and self.env.getSwitchIndex(output.name)
    local observed = condition and self.env.getSwitchValue and self.env.getSwitchValue(condition)
    if output.queued then
        if observed == output.desired then
            self.state.outputStatus = "applied"
            if self.state.outputError then
                self.state.diagnosticRevision = (self.state.diagnosticRevision or 0) + 1
            end
            self.state.outputError, self.errors.output = nil, nil
            if not output.desired then
                self.output = nil
            end
        elseif now - output.queuedAt > 100 then
            self:error("output", output.name .. " did not retain the requested state; check other writers")
        end
        return
    end
    local succeeded, full = self:effect("output", self.env.setStickySwitch, index, output.desired)
    if succeeded then
        if full == false then
            output.queued, output.queuedAt = true, now
            self.state.outputStatus = "queued"
        elseif full == true then
            self.state.outputStatus = "pending"
            self:error("output", "Sticky command buffer full; retrying " .. output.name)
        else
            self:error("output", "Sticky API returned an invalid queue result")
        end
    end
end

function broker:tick(now, filename)
    filename = filename or self:identity()
    if filename ~= self.filename then
        self:reset(filename)
    end
    if self.pumpedAt == now then
        return
    end
    self.pumpedAt = now
    local proposal, signature, status = self:proposals(now)
    self.state.status = self.loadError and "error" or status
    self.state.persistenceError = self.loadError
    local active = self.session and (self.session.phase == "active" or self.session.phase == "ending")
    if self.output and not self.output.flightId and (not proposal or signature ~= self.signature or self.loadError) then
        self.output = nil
        if self.session then
            self.session.outputInitialized = false
        end
        self.state.outputStatus = "inhibited"
        if self.errors.output then
            self.errors.output, self.state.outputError = nil, nil
            self.state.diagnosticRevision = (self.state.diagnosticRevision or 0) + 1
        end
    end
    if not active and not self.output and proposal and not self.loadError and signature ~= self.signature then
        local ok, message = pcall(self.attach, self, proposal, signature, now)
        if not ok then
            self:error("detection", message)
            self.state.status = "error"
            return
        end
    end
    local session = self.session
    if not session then
        if self.factory and status == "unconfigured" then
            self.dormantRevision = self.factory.revision
        end
        return
    end
    local id, message = self.support.update(self.runtime, now)
    if message then
        self:error("detection", tostring(id) .. ": " .. message)
    end
    session.controlAvailable = not self.runtime.byId.control.failed
    session.detectionAvailable = session.controlAvailable
        and not self.runtime.byId.telemetry.failed
        and not self.runtime.byId.model.failed
    if self.lastTick and now - self.lastTick < 20 then
        self:flushOutput(now)
        return
    end
    if self.lastTick and (now < self.lastTick or now - self.lastTick > 100) then
        session.groundAt = nil
        if session.phase == "starting" then
            session.phase, session.startedAt = "ground", nil
        elseif session.phase == "ending" then
            session.phase, session.disarmedAt = "active", nil
        end
    end
    self.lastTick = now
    active = session.phase == "active" or session.phase == "ending"
    if self.readyAfterDisarm and reliable(session.arm, now) and session.arm.value == false then
        self.readyAfterDisarm = nil
    end
    if
        active
        or (
            proposal
            and signature == self.signature
            and not self.loadError
            and not self.errors.count
            and not self.readyAfterDisarm
            and (not self.output or self.output.desired)
        )
    then
        local ok, failure = pcall(flight.advance, session, now)
        if not ok then
            self:error("detection", failure)
            self.errors.count = self.errors.count or failure
        end
    elseif not active then
        session.phase, session.startedAt = "ground", nil
    end
    if
        not self.output
        and proposal
        and signature == self.signature
        and not self.loadError
        and session.controlAvailable
        and session.settings.flightSwitch ~= ""
        and session.phase == "ground"
        and reliable(session.arm, now)
        and session.arm.value == false
    then
        session.groundAt = session.groundAt or now
        if not session.outputInitialized and now - session.groundAt >= session.settings.disarmDuration * 100 then
            session.outputInitialized = true
            self.output = { name = session.settings.flightSwitch, armKey = session.armKey, desired = false }
        end
    else
        session.groundAt = nil
    end
    self:flushOutput(now)
    self.state.phase, self.state.active = session.phase, session.phase == "active" or session.phase == "ending"
    self.state.startedAt, self.state.disarmedAt = session.startedAt, session.disarmedAt
    self.state.flightId, self.state.count = session.flightId, session.feed.raw
    self.state.revision = self.state.revision + 1
end

function flight.new(env, support, runtime)
    if not runtime.host or not runtime.host.flightFactory then
        local view = support.snapshot({ phase = "ground", active = false, status = "unconfigured" })
        return {
            id = "flight",
            count = 0,
            interval = 20,
            due = 0,
            revision = 0,
            state = function()
                return view
            end,
        }
    end
    local host, factory = runtime.host, runtime.host.flightFactory
    if not factory.broker then
        factory.broker = flight.newBroker(env, support, runtime.modules, host.flightConfig, factory.members)
    end
    local owner = factory.broker
    owner.factory = factory
    host.flightBroker = owner
    local facade = { id = "flight", count = 0, interval = 20, due = 0, revision = 0, broker = owner }
    function facade:state()
        return owner.view
    end
    function facade:boundaries(sequence, epoch)
        return owner:boundaries(sequence, epoch)
    end
    return facade
end

return flight
