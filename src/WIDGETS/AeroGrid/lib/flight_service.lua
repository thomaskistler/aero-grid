-- SPDX-License-Identifier: GPL-2.0-only

local flight = {}
local broker = {}
broker.__index = broker

local ROUNDING = string.packsize("n") == 4 and 0.0000005 or 0.000000000000001

--- Minimum ticks between detection decisions. The host sets up flight work
--- every 20 ticks; a shorter limit keeps a late decision from skipping the next.
local DECIDE_INTERVAL = 10

local function above(value, threshold)
    -- Unit conversion must not turn equality into "above", including on the
    -- firmware's float32 Lua build and at nonzero altitude references.
    return value - threshold > ROUNDING * math.max(1, math.abs(value), math.abs(threshold))
end

local function reliable(reading, now, maxAge)
    return reading
        and reading.available ~= false
        and reading.fresh == true
        and type(reading.updatedAt) == "number"
        and now >= reading.updatedAt
        and now - reading.updatedAt <= maxAge
end

local function smartReference(context, now, armLive, armed, maxAge)
    if not context.settings.smartDetection then
        return
    end
    local sensors = context.smart
    if sensors and context.sensorGeneration ~= sensors.generation then
        context.altitudeReference = nil
        context.referenceCandidate, context.referenceCandidateAt = nil, nil
        context.referencePending, context.referencePendingAt = nil, nil
        context.altitudeSince, context.speedSince = nil, nil
        context.sensorGeneration = sensors.generation
    end
    if not armLive then
        context.wasArmed = nil
        context.referenceCandidate, context.referenceCandidateAt = nil, nil
        context.referencePending, context.referencePendingAt = nil, nil
        context.altitudeSince, context.speedSince = nil, nil
    elseif not armed then
        context.wasArmed, context.altitudeReference = false, nil
        context.altitudeSince, context.speedSince = nil, nil
        local altitude = sensors and sensors.altitude
        if context.smartAvailable ~= false and reliable(altitude, now, maxAge) then
            -- The arm and sensor pollers are independent. Confirm the sample
            -- against a false-arm observation at or after its receipt evidence.
            if context.referencePendingAt and context.referencePendingAt <= context.arm.updatedAt then
                context.referenceCandidate, context.referenceCandidateAt =
                    context.referencePending, context.referencePendingAt
            end
            if altitude.evidenceAt and altitude.evidenceAt <= context.arm.updatedAt then
                context.referenceCandidate, context.referenceCandidateAt = altitude.value, altitude.evidenceAt
            end
            context.referencePending, context.referencePendingAt = altitude.value, altitude.evidenceAt
        else
            context.referenceCandidate, context.referenceCandidateAt = nil, nil
            context.referencePending, context.referencePendingAt = nil, nil
        end
    elseif context.wasArmed == false then
        local altitude = sensors and sensors.altitude
        if context.smartAvailable ~= false and reliable(altitude, now, maxAge) then
            if
                context.referenceCandidateAt
                and now >= context.referenceCandidateAt
                and now - context.referenceCandidateAt <= 120
            then
                context.altitudeReference = context.referenceCandidate
            elseif altitude.sampleFresh then
                context.altitudeReference = altitude.value
            end
        end
        context.referenceCandidate, context.referenceCandidateAt = nil, nil
        context.referencePending, context.referencePendingAt = nil, nil
        context.wasArmed = true
    else
        context.wasArmed = true
    end
end

local function smartReason(context, now, maxAge)
    if not context.settings.smartDetection then
        return nil
    end
    local sensors = context.smart
    local altitude, speed = sensors and sensors.altitude, sensors and sensors.speed
    if altitude and altitude.continuity ~= context.altitudeContinuity then
        context.altitudeSince, context.altitudeContinuity = nil, altitude.continuity
    end
    if speed and speed.continuity ~= context.speedContinuity then
        context.speedSince, context.speedContinuity = nil, speed.continuity
    end
    local baro = context.smartAvailable ~= false
        and context.altitudeReference ~= nil
        and reliable(altitude, now, maxAge)
        and above(altitude.value, context.altitudeReference + 3)
    local moving = context.smartAvailable ~= false and reliable(speed, now, maxAge) and above(speed.value, 4.4704)
    context.altitudeSince = baro and (context.altitudeSince or now) or nil
    context.speedSince = moving and (context.speedSince or now) or nil
    if context.altitudeSince and altitude.confirmedAt and altitude.confirmedAt - context.altitudeSince >= 200 then
        return "smart-altitude"
    elseif context.speedSince and speed.confirmedAt and speed.confirmedAt - context.speedSince >= 200 then
        return "smart-speed"
    end
end

--- The broker supplies once-only side-effect adapters for every qualification.
function flight.advance(context, now, maxAge)
    local armLive = context.controlAvailable ~= false
        and reliable(context.arm, now, maxAge)
        and type(context.arm.value) == "boolean"
    local armed = armLive and context.arm.value
    if context.phase == "active" or context.phase == "ending" then
        if not armLive or armed then
            context.disarmedAt, context.phase = nil, "active"
        else
            context.disarmedAt = context.disarmedAt or now
            context.phase = "ending"
            if now - context.disarmedAt >= context.settings.disarmDuration * 100 then
                if context.completed then
                    context:completed(now)
                end
                context.phase = "ground"
                context.startedAt, context.disarmedAt = nil, nil
                context.wasArmed, context.altitudeReference = false, nil
                context.altitudeSince, context.speedSince = nil, nil
                smartReference(context, now, true, false, maxAge)
            end
        end
        return
    end
    smartReference(context, now, armLive, armed, maxAge)
    if context.detectionAvailable == false then
        context.phase, context.startedAt = "ground", nil
        context.altitudeSince, context.speedSince = nil, nil
        return
    end
    assert(not context.motor.telemetry, "flight counter motorSource must be a radio-local motor channel")
    local motorLive = reliable(context.motor, now, maxAge)
        and type(context.motor.value) == "number"
        and context.motor.value == context.motor.value
        and math.abs(context.motor.value) < math.huge
    local motor = motorLive and context.motor.value or -1024
    if context.settings.motorReversed then
        motor = -motor
    end
    local link = context.link
    local live = link.updatedAt and now >= link.updatedAt and now - link.updatedAt <= maxAge and link.live
    if
        not (
            armed
            and motorLive
            and (motor + 1024) * 100 / 2048 > context.settings.minMotorPercent
            and (context.settings.requireReceiver == false or live)
        )
    then
        context.phase, context.startedAt = "ground", nil
        context.altitudeSince, context.speedSince = nil, nil
        return
    end
    if not context.startedAt then
        context.startedAt, context.phase = now, "starting"
    end
    local reason = smartReason(context, now, maxAge)
    if now - context.startedAt >= context.settings.minFlightDuration * 100 then
        reason = "standard"
    end
    if reason then
        context.reason = reason
        context.flightCount = context.control:incrementFlightCount()
        context.phase = "active"
        if context.qualified then
            context:qualified(now)
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
        -- Members' schedulers that run the shared tasks, woken when a task falls due early.
        schedulers = setmetatable({}, { __mode = "k" }),
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
    if self.countImport and self.countImport.handle then
        self.store.operations.close(self.countImport.handle)
    end
    self.countImport, self.pendingCount, self.countTask = nil, nil, nil
    self.countDue, self.countImportFailed = nil, nil
    self.countStarted = nil
    self.filename, self.epoch = filename, self.epoch + 1
    self.session, self.smart, self.signature, self.output = nil, nil, nil, nil
    self.document, self.loadError, self.settingsAdoption = nil, nil, nil
    self.settingsError = nil
    self.events, self.errors = {}, {}
    self.lastTick, self.readyAfterDisarm = nil, nil
    self.readyAfterDisarmAt = nil
    self.resetCondition, self.resetFeed, self.resetValue = nil, nil, nil
    self.setupAt = nil
    self:dropTasks()
    for key in pairs(self.state) do
        self.state[key] = nil
    end
    self.state.modelFilename, self.state.epoch = filename, self.epoch
    self.state.phase, self.state.active, self.state.status = "ground", false, "unconfigured"
    self.state.revision = 0
    self.documentLoaded = false
    self.dormantRevision = nil
end

function broker:setDocument(document)
    assert(
        document.modelFilename == nil or document.modelFilename == self.filename,
        "Model changed; reopen model settings"
    )
    if self.document and self.document.armed ~= document.armed then
        for host in pairs(self.members) do
            host.navigationHomes = {}
            local mine = host.modelFilename == nil or host.modelFilename == self.filename
            -- Only dashboards whose armed service used a different switch need a reload.
            if mine and host.builtArmed and host.builtArmed.value ~= document.armed then
                host.modelArmingReload = true
            end
        end
    end
    local changed = self.document and (self.document.revision or 0) ~= (document.revision or 0)
    local detectionChanged = changed
        and (
            self.document.armed ~= document.armed
            or self.document.sessionReset ~= document.sessionReset
            or self.config.key(self.config.resolve(self.document.flight))
                ~= self.config.key(self.config.resolve(document.flight))
        )
    if changed and (detectionChanged or self.errors.count or self.errors.detection) then
        self.readyAfterDisarm = true
        self.errors.count, self.errors.detection = nil, nil
        self.state.countError, self.state.detectionError = nil, nil
        self.state.diagnosticRevision = (self.state.diagnosticRevision or 0) + 1
        self.countImportFailed = nil
        if self.pendingCount then
            if document.flightCount == self.pendingCount.value then
                self.pendingCount = nil
            else
                self.pendingCount.failed, self.pendingCount.prepared = nil, nil
            end
        end
    end
    self.document = document
    self.countDirty = true
    self:dropTasks()
    if self.countTask then
        self.countTask.due = 0
        self:wake(self.countTask)
    end
    self.loadError, self.state.persistenceError = nil, nil
    self.settingsError, self.errors.persistence = nil, nil
    self.state.configurationRevision = document.revision or 0
    self.documentLoaded = true
    self.state.count = document.flightCount
    if self.factory then
        self.factory.revision = (self.factory.revision or 0) + 1
    end
end
function broker:incrementCount()
    local current = self.document and self.document.flightCount
    local counter = assert(self.store and self.store.counter, "Flight count store unavailable")
    assert(counter.valid(current) and current < counter.MAX, "Internal flight count is unavailable or full")
    assert(not self.pendingCount, "Previous flight count is not saved; resolve the persistence error")
    local value = current + 1
    self.pendingCount = { previous = current, value = value }
    self:dropTasks()
    if self.countTask then
        self.countTask.due = 0
        self:wake(self.countTask)
    end
    self:publishCount()
    return value
end

function broker:publishCount()
    local source = self.document.flight and self.document.flight.countSource or "internal"
    self.state.countSource = source
    self.state.count = self.pendingCount and self.pendingCount.value or self.document.flightCount
    local ok, value = true, self.state.count
    if source ~= "internal" then
        ok, value = pcall(self.store.counter.external, self.env, source == "gv8gv9")
    end
    self.state.countAvailable = ok and value ~= nil
    self.state.displayCount = ok and value or nil
    self.countDirty = nil
    if not ok then
        self:error("source", value)
    elseif self.errors.source then
        self.errors.source, self.state.sourceError = nil, nil
        self.state.diagnosticRevision = (self.state.diagnosticRevision or 0) + 1
    end
end

--- Converted settings that would fill a gap in the model's settings.
function broker:conversion()
    local document = self.document
    if not document or document.flightCount == nil or self.pendingCount or self:loading() then
        return nil
    end
    local converted = self:converted()
    if document.armed == nil and converted.armed or document.flight == nil and converted.flight then
        return converted
    end
end

function broker:saveCount()
    local pending = self.pendingCount
    if not pending then
        if self:loading() then
            return
        end
        local converted = self:conversion()
        if converted then
            -- Settings models saved before conversion get it once, with an unchanged count.
            local count = self.document.flightCount
            self.pendingCount = { previous = count, value = count, imported = converted }
            return
        end
        if self.document.flightCount ~= nil then
            return
        end
        converted = self:converted()
        if not self.countImport then
            local legacy = self.document.flight ~= nil or self.document.armed ~= nil or converted.flight ~= nil
            self.countImport = self.store.counter.begin(self.store.operations, self.filename, legacy, self.env)
            return
        end
        local done, imported = self.store.counter.step(self.countImport)
        if not done then
            return
        end
        self.countImport = nil
        -- Arm and flight settings converted from released layouts are saved once, with the first count.
        imported.armed = imported.armed or converted.armed
        imported.flight = imported.flight or converted.flight
        pending = { value = imported.count, imported = imported }
        self.pendingCount = pending
        return
    end
    if not pending.prepared then
        local ok, prepared = self.store:prepareCount(self.filename, pending.previous, pending.value, pending.imported)
        assert(ok, prepared)
        pending.prepared = prepared
        return
    end
    if pending.prepared.baseRevision ~= self.document.revision then
        pending.prepared = nil
        return
    end
    local ok, document = self.store:commit(pending.prepared)
    assert(ok, document)
    self.pendingCount = nil
    self:setDocument(document)
    self.state.importNotice = pending.imported and pending.imported.notice or self.state.importNotice
    self.state.diagnosticRevision = (self.state.diagnosticRevision or 0) + 1
end

--- Whether any member widget of this model is still loading its layout.
function broker:loading()
    for _, member in pairs(self.members) do
        if member.modelFilename == self.filename and member.pending then
            return true
        end
    end
    return false
end

--- Arm and flight settings converted from this model's released layouts.
function broker:converted()
    local result = {}
    for _, member in pairs(self.members) do
        local legacy = member.modelFilename == self.filename and member.legacy
        if legacy then
            result.armed = result.armed or legacy.armed
            result.flight = result.flight or legacy.flight
        end
    end
    return result
end

function broker:boundary(kind, at, observedAt)
    self.sequence = self.sequence + 1
    local record = self.support.snapshot({
        epoch = self.epoch,
        sequence = self.sequence,
        flightId = self.session.flightId,
        armKey = self.session.armKey,
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

--- The model's flight settings and Armed condition, once both are set.
function broker:proposal()
    local failure
    for _, member in pairs(self.members) do
        if member.modelFilename == self.filename and member.error then
            failure = member.error
            break
        end
    end
    if failure ~= self.state.configurationError then
        self.state.configurationError = failure
        self.state.diagnosticRevision = (self.state.diagnosticRevision or 0) + 1
    end
    if failure then
        return nil, nil, "error"
    end
    local document = self.document
    if self.proposalDocument ~= document then
        local settings, armKey = document and document.flight, document and document.armed
        local ready = settings and armKey and armKey ~= ""
        self.proposalDocument = document
        self.cachedProposal = ready and { settings = settings, armKey = armKey } or nil
        self.cachedSignature = ready and self.config.key(settings) .. ":" .. armKey or nil
    end
    return self.cachedProposal, self.cachedSignature, self.cachedProposal and "ready" or "unconfigured"
end

function broker:validateOutput(name, armKey, resetCondition)
    if not name or name == "" then
        return
    end
    assert(self.env.setStickySwitch and self.env.getLogicalSwitch, "Flight status switch requires Sticky switch APIs")
    assert(string.gsub(armKey or "", "^!", "") ~= name, "Flight status switch cannot be the Arm input")
    resetCondition = resetCondition == nil and self.document and self.document.sessionReset or resetCondition
    if resetCondition and resetCondition ~= "" then
        assert(string.gsub(resetCondition, "^!", "") ~= name, "Flight status switch cannot be the Session reset input")
    end
    local index = tonumber(string.sub(name, 2)) - 1
    local definition = self.env.getLogicalSwitch(index)
    assert(type(definition) == "table" and definition.func == 17, name .. " must be a dedicated Sticky logical switch")
    for _, key in ipairs({ "v1", "v2", "v3", "and", "delay", "duration" }) do
        assert((definition[key] or 0) == 0, name .. " must have no inputs, AND, delay or duration")
    end
    return index
end

function broker:resetSession(now)
    self.epoch = self.epoch + 1
    self.events = {}
    self.state.epoch = self.epoch
    self.readyAfterDisarm, self.readyAfterDisarmAt = true, now
    local session = self.session
    if session then
        if session.settings.flightSwitch ~= "" then
            self.output = {
                name = session.settings.flightSwitch,
                armKey = session.armKey,
                desired = false,
                flightId = session.flightId or 0,
            }
        end
        for _, key in ipairs({
            "startedAt",
            "disarmedAt",
            "groundAt",
            "flightId",
            "flightCount",
            "qualifiedAt",
            "reason",
            "wasArmed",
            "altitudeReference",
            "altitudeSince",
            "speedSince",
            "referenceCandidate",
            "referenceCandidateAt",
            "referencePending",
            "referencePendingAt",
        }) do
            session[key] = nil
        end
        session.phase, session.outputInitialized = "ground", true
    end
    for _, key in ipairs({ "startedAt", "disarmedAt", "qualifiedAt", "endedAt", "completedAt", "flightId", "reason" }) do
        self.state[key] = nil
    end
    self.state.phase, self.state.active = "ground", false
    self.state.revision = (self.state.revision or 0) + 1
    for host, member in pairs(self.members) do
        if member.modelFilename == self.filename and host.dashboardLifecycle then
            host.sessionResetPending, host.sessionResetJob = true, nil
        end
    end
    if self.factory then
        self.factory.revision = (self.factory.revision or 0) + 1
    end
end

local RESOLVE_RETRY = 500

--- Read a switch condition straight from EdgeTX. An unknown switch reads as
--- unavailable, never as false, and is looked up again every five seconds.
local function readSwitch(owner, reading, now)
    local index = reading.index
    if not index then
        reading.available, reading.fresh = false, false
        if now < (reading.retryAt or 0) then
            return
        end
        index = owner.modules.control.switchIndex(owner, reading.name)
        if type(index) ~= "number" or index == 0 then
            reading.retryAt = now + RESOLVE_RETRY
            return
        end
        reading.index = index
    end
    local value = owner.env.getSwitchValue(index)
    local known = type(value) == "boolean"
    reading.available, reading.fresh = known, known
    if known then
        reading.value, reading.updatedAt = value, now
    end
end

--- Read the motor channel straight from EdgeTX.
local function readMotor(owner, reading, now)
    local id = reading.id
    if not id then
        reading.fresh = false
        if now < (reading.retryAt or 0) then
            return
        end
        local info = owner.env.getFieldInfo(reading.name)
        if type(info) ~= "table" or type(info.id) ~= "number" then
            reading.retryAt = now + RESOLVE_RETRY
            return
        end
        id, reading.telemetry = info.id, type(info.unit) == "number"
        reading.id = id
    end
    local value = owner.env.getValue(id)
    reading.fresh = type(value) == "number"
    if reading.fresh then
        reading.value, reading.updatedAt, reading.available = value, now, true
    end
end

--- Read the reset switch at each setup, including while detection is dormant.
function broker:readReset(now)
    local condition = self.document and self.document.sessionReset or ""
    if condition ~= self.resetCondition then
        self.resetCondition, self.resetValue = condition, nil
        self.resetFeed = condition ~= "" and { name = condition, value = false, updatedAt = 0 } or nil
    end
    local feed = self.resetFeed
    if feed then
        local ok, message = pcall(readSwitch, self, feed, now)
        if not ok or not feed.fresh then
            self.resetValue = nil
            self:error("reset", ok and "Session reset switch unavailable: " .. condition or message)
            return
        end
    end
    if self.errors.reset then
        self.errors.reset, self.state.resetError = nil, nil
        self.state.diagnosticRevision = (self.state.diagnosticRevision or 0) + 1
    end
    if not feed then
        return
    end
    local previous = self.resetValue
    self.resetValue = feed.value
    -- Booting, changing the selection, or recovering while held is not an edge.
    if previous == false and feed.value == true then
        self:resetSession(now)
    end
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
    local env = self.env
    assert(
        env.getSwitchIndex and env.getSwitchValue and env.getFieldInfo and env.getValue,
        "Flight detection requires switch and source APIs"
    )
    local smart, smartSensors
    if settings.smartDetection then
        smart = self.modules.smart.new(env, self.support)
        smartSensors = smart:enable()
    end
    local session = {
        settings = settings,
        phase = "ground",
        arm = { name = proposal.armKey, value = false, updatedAt = 0 },
        motor = { name = settings.motorSource },
        link = { live = false },
        armKey = proposal.armKey,
        smart = smartSensors,
    }
    local owner = self
    session.control = {
        incrementFlightCount = function()
            local ok, count = owner:effect("count", owner.incrementCount, owner)
            assert(ok, count)
            return count
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
    self.smart, self.session, self.signature = smart, session, signature
    if self.errors.detection then
        self.errors.detection, self.state.detectionError = nil, nil
        self.state.diagnosticRevision = (self.state.diagnosticRevision or 0) + 1
    end
    self.state.armKey = proposal.armKey
    self.state.startedAt, self.state.qualifiedAt, self.state.endedAt, self.state.completedAt = nil, nil, nil, nil
    self.state.reason, self.state.smartStatus = nil, nil
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

--- Resolve the configuration and attach detection before this tick's polls.
function broker:prepare(now)
    local proposal, signature, status = self:proposal()
    self.state.status = self.loadError and "error" or status
    self.state.persistenceError = self.loadError or self.settingsError
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
    if not self.session and self.factory and status == "unconfigured" then
        self.dormantRevision = self.factory.revision
    end
end

--- Read the detection inputs, which only flight detection uses.
function broker:readInputs(now)
    local session = self.session
    local ok, message = pcall(function()
        readSwitch(self, session.arm, now)
        readMotor(self, session.motor, now)
        local rssi = self.env.getRSSI and self.env.getRSSI() or 0
        session.link.live = type(rssi) == "number" and rssi > 0
        if session.link.live then
            session.link.updatedAt = now
        end
    end)
    session.controlAvailable, session.detectionAvailable = ok, ok
    if not ok then
        self:error("detection", message)
    end
    local smart = self.smart
    if smart and not smart.failed then
        local updated, failure = pcall(smart.update, smart, now)
        if not updated then
            smart.failed = true
            self:error("detection", "smart: " .. tostring(failure))
        end
    end
    session.smartAvailable = not (smart and smart.failed)
end

--- Advance detection from the inputs just read.
function broker:decide(now)
    local proposal, signature = self:proposal()
    local session = self.session
    if self.lastTick and now >= self.lastTick and now - self.lastTick < DECIDE_INTERVAL then
        self:flushOutput(now)
        return
    end
    if self.lastTick and (now < self.lastTick or now - self.lastTick > 100) then
        session.groundAt = nil
        session.altitudeSince, session.speedSince, session.wasArmed = nil, nil, nil
        session.altitudeReference = nil
        if session.phase == "starting" then
            session.phase, session.startedAt = "ground", nil
        elseif session.phase == "ending" then
            session.phase, session.disarmedAt = "active", nil
        end
    end
    self.lastTick = now
    local active = session.phase == "active" or session.phase == "ending"
    if
        self.readyAfterDisarm
        and reliable(session.arm, now, self.support.MAX_SAMPLE_AGE)
        and session.arm.value == false
        and (not self.readyAfterDisarmAt or session.arm.updatedAt >= self.readyAfterDisarmAt)
    then
        self.readyAfterDisarm, self.readyAfterDisarmAt = nil, nil
    end
    if
        active
        or (
            proposal
            and signature == self.signature
            and not self.loadError
            and not self.errors.count
            and self.document.flightCount ~= nil
            and not self.pendingCount
            and not self.readyAfterDisarm
            and (not self.output or self.output.desired)
        )
    then
        local ok, failure = pcall(flight.advance, session, now, self.support.MAX_SAMPLE_AGE)
        if not ok then
            self:error("detection", failure)
            self.errors.count = self.errors.count or failure
        end
    elseif not active then
        session.phase, session.startedAt = "ground", nil
        session.altitudeSince, session.speedSince, session.wasArmed = nil, nil, nil
        session.altitudeReference = nil
    end
    if
        not self.output
        and proposal
        and signature == self.signature
        and not self.loadError
        and session.controlAvailable
        and session.settings.flightSwitch ~= ""
        and session.phase == "ground"
        and reliable(session.arm, now, self.support.MAX_SAMPLE_AGE)
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
    self.state.reason = session.reason
    if session.smart then
        self.state.smartStatus = session.smartAvailable and session.smart.status
            or "Smart unavailable: sensor reader failed; standard only."
        if session.smartAvailable and session.altitudeReference == nil then
            self.state.smartStatus = self.state.smartStatus .. " Baro needs a live arming reference."
        end
    end
    self.state.flightId = session.flightId
    self.state.revision = self.state.revision + 1
end

--- Run this tick's flight work once, whichever widget reaches it first.
--- `detect` is false while detection is dormant; the reset switch is still read.
function broker:setup(now, detect)
    if self.setupAt == now then
        return
    end
    self.setupAt = now
    self.countStarted = true
    local ok, message = pcall(self.readReset, self, now)
    if not ok then
        self:error("reset", message)
    end
    if detect then
        ok, message = pcall(self.prepare, self, now)
        if not ok then
            self:error("detection", message)
        end
        if self.session then
            self:readInputs(now)
            ok, message = pcall(self.decide, self, now)
            if not ok then
                self:error("detection", message)
            end
        end
    end
end

--- Move a shared task forward in every member's scheduler that runs it.
function broker:wake(task, exact)
    for scheduler in pairs(self.schedulers) do
        scheduler.reschedule(task, exact)
    end
end

--- Retire the task list; the next `tasks` call builds a new one.
function broker:dropTasks()
    self.taskList = nil
end

--- Whether the count has work it can do now.
local function countWork(owner, now)
    local pending = owner.pendingCount
    return owner.countStarted
        and owner.documentLoaded
        and owner.document ~= nil
        and owner.store ~= nil
        and not owner.settingsAdoption
        and not owner.settingsError
        and (
            pending and not pending.failed
            or not pending and not owner.countImportFailed and owner.document.flightCount == nil
            or owner:conversion() ~= nil
            or owner.countDirty
            or owner.document.flight
                and owner.document.flight.countSource ~= "internal"
                and now >= (owner.countDue or 0)
        )
end

--- The count checks for work in a free turn, sleeping without any, and pays
--- for the work in the turn that follows.
local function countStep(task, now, granted)
    local owner = task.broker
    if not countWork(owner, now) then
        task.cost, task.due = 0, now + 20
        return 0, false
    end
    if granted == 0 then
        local pending = owner.pendingCount
        -- A save measured up to 6.2k instructions natively.
        task.cost = pending and not pending.failed and 14 or owner.countImport and 16 or 4
        return 0, true
    end
    task.cost = 0
    owner.countDue, task.due = now + 20, now
    local ok, message = pcall(function()
        assert(owner:identity() == owner.filename, "Model changed during flight count save")
        local pending = owner.pendingCount
        if not owner.countImportFailed and not (pending and pending.failed) then
            owner:saveCount()
        end
    end)
    if not ok then
        if owner.pendingCount then
            owner.pendingCount.failed = true
        else
            owner.countImportFailed = true
            if owner.countImport and owner.countImport.handle then
                owner.store.operations.close(owner.countImport.handle)
            end
            owner.countImport = nil
        end
        owner:error("count", message)
    end
    owner:publishCount()
    if owner.document.flightCount ~= nil and not owner.pendingCount then
        task.due = now + 20
        if owner.state.countSource == "internal" then
            owner:dropTasks()
        end
    end
    return granted, false
end

--- The broker's scheduler tasks, shared by every member widget's scheduler.
--- Only the count has work of its own; detection runs in the flight task.
function broker:tasks()
    local list = self.taskList
    if list then
        return list
    end
    list = {}
    if not self.countTask then
        self.countTask = {
            name = "flight.count",
            broker = self,
            cost = 0,
            step = countStep,
            onError = function(task, message)
                task.broker:error("count", message)
            end,
        }
    end
    if
        not self.document
        or self.document.flightCount == nil
        or self.pendingCount
        or self:conversion() ~= nil
        or self.countDirty
        or self.document.flight and self.document.flight.countSource ~= "internal"
    then
        list[#list + 1] = self.countTask
    end
    self.taskList = list
    return list
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
