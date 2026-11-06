-- SPDX-License-Identifier: GPL-2.0-only

--- Cached telemetry readings with units, precision, and freshness.
---
--- Panels subscribe by EdgeTX source name and hold the returned immutable
--- reading for their lifetime. Two panels naming the same sensor share one
--- subscription, so the dashboard reads each source once per poll no matter how
--- many panels display it.
---
--- Freshness deserves its own note, because EdgeTX makes it subtle. `getValue`
--- returns integer zero for a telemetry source whenever telemetry is not
--- streaming *or* the sensor has never been received, and that is
--- indistinguishable from a genuine zero reading.
---
--- Only a zero is ambiguous, so only a zero is judged. A non-zero value is
--- proof of life whatever the link indicator says, and is always stored. A
--- zero is stored only while the link is believed up; otherwise the last live
--- value is kept and marked stale. Non-telemetry sources such as the
--- transmitter voltage, timers, trims, and global variables do not depend on
--- the link and are always live once resolved.
---
--- The link indicator is `getRSSI() > 0`, the legacy reader's liveness signal,
--- and it is not reliable everywhere: a protocol that
--- never populates an RSSI sensor reads zero on a perfectly live link. The
--- service detects that case and stops trusting the indicator, because a
--- telemetry source cannot return a non-zero value when EdgeTX has nothing.
---
--- This legacy `getValue` path cannot distinguish never-received sensors from
--- genuine zeros while the link is up. GPS carries its own age, which
--- `navigationService` uses. Smart flight inputs instead require the optional
--- `getSourceValue` API's per-sensor receipt/current/fresh flags.

---@class AeroGridReading
---@field name string Source name as configured in the layout.
---@field id? integer Resolved EdgeTX source id.
---@field known boolean The radio recognizes the source name.
---@field telemetry boolean The source is a telemetry sensor subject to the link.
---@field available boolean A live reading has been seen at least once.
---@field fresh boolean The most recent poll produced a live reading.
---@field stale boolean A reading exists but is no longer live.
---@field state "normal"|"stale"|"unavailable" Name accepted by theme.state.
---@field value? number Last live numeric reading.
---@field raw any Last live reading in its original shape, including tables.
---@field kind "number"|"cells"|"gps"|"datetime"|"text" Value shape.
---@field unit integer EdgeTX unit code.
---@field unitText string Short ASCII unit label, empty when the unit is raw.
---@field precision integer Decimal places configured on the sensor.
---@field updatedAt? integer Tick of the last live reading.
---@field age? number Seconds since the last live reading.
---@field revision integer Incremented whenever the reading changes.

local telemetryService = { RUNTIME_API = 1 }
telemetryService.__index = telemetryService

--- Ticks of 10ms between polls. Unspecified subscribers keep the legacy rate.
telemetryService.INTERVAL = 10

--- Subscriptions refreshed per update, served round robin. Sixteen sources
--- split across two updates still give every source 5 Hz at the interval above.
telemetryService.POLL_CAP = 8

telemetryService.decl = {
    class = "critical",
    stages = { run = { fixed = 480, perUnit = 320, maxUnits = 24 } },
}
telemetryService.plainDecl = {
    class = "critical",
    stages = { run = { fixed = 0, perUnit = 320, maxUnits = 1 } },
}
telemetryService.recordedOneDecl = {
    class = "critical",
    stages = { run = { fixed = 0, perUnit = 740, maxUnits = 1 } },
}
telemetryService.legacyDecl = {
    class = "critical",
    stages = { run = { fixed = 260, perUnit = 1220, maxUnits = telemetryService.POLL_CAP } },
}
telemetryService.maintenanceDecl = {
    class = "critical",
    -- One entry inspection per source; the host admits at most 128 tasks.
    stages = { run = { fixed = 450, perUnit = 10, maxUnits = 128 } },
}
local SOURCE_TASK_PREFIX = "service:telemetry:source:"
local SOURCE_DECLARATIONS = {}
local MAX_INTERVAL = 1 << 30
local beginUpdate, finishUpdate

--- Ticks between attempts to resolve a source the radio does not yet know.
--- Sensors appear when telemetry first arrives, so an unresolved name must be
--- retried, but retrying every poll wastes the budget on a missing sensor.
telemetryService.RESOLVE_RETRY = 200

--- Telemetry sensors inspected per update while looking up precision, and the
--- largest sensor table any supported radio provides. Only one subscription
--- scans at a time, so this is the whole cost of the search per update.
telemetryService.SCAN_CAP = 8
telemetryService.SENSOR_LIMIT = 60

--- Short ASCII labels for EdgeTX unit codes, from `TelemetryUnit` in
--- `radio/src/dataconstants.h`. Deliberately ASCII: the radio's fonts and this
--- repository both stay within it.
local UNIT_TEXT = {
    [0] = "",
    "V",
    "A",
    "mA",
    "kts",
    "m/s",
    "ft/s",
    "km/h",
    "mph",
    "m",
    "ft",
    "C",
    "F",
    "%",
    "mAh",
    "W",
    "mW",
    "dB",
    "rpm",
    "g",
    "deg",
    "rad",
    "ml",
    "floz",
    "ml/m",
    "Hz",
    "ms",
    "us",
    "km",
    "dBm",
}
UNIT_TEXT[35] = "h"
UNIT_TEXT[36] = "min"
UNIT_TEXT[37] = "s"

--- Unit codes whose value is not a plain number.
local UNIT_KIND = {
    [38] = "cells",
    [39] = "datetime",
    [40] = "gps",
    [42] = "text",
}

--- Create the service.
---@param env table Result of services.environment.
---@param support table The loaded lib/services.lua module.
---@return table
function telemetryService.new(env, support, runtime)
    local service = setmetatable({
        id = "telemetry",
        interval = telemetryService.INTERVAL,
        revision = 0,
        count = 0,
        due = 0,
        env = env,
        support = support,
        names = {},
        entries = {},
        cursor = 1,
        scanCursor = 1,
        want = 1,
        schedulerTasks = {},
        schedulerRevision = 0,
        runtime = runtime,
        linkLive = false,
        rssi = 0,
    }, telemetryService)
    local maintenance = {
        id = "service:telemetry:maintenance",
        decl = telemetryService.maintenanceDecl,
        want = 1,
        interval = service.interval,
        critical = true,
        step = function(task, grant, _, now)
            if grant < task.want then
                return 1
            end
            beginUpdate(service, now)
            finishUpdate(service, now)
            service.revision = service.revision + 1
            return service.interval
        end,
    }
    service.maintenanceTask = maintenance
    service.schedulerTasks[1] = { id = maintenance.id, instance = maintenance, critical = true }
    if runtime and runtime.host then
        setmetatable(service, {
            __index = function(_, key)
                if key ~= "update" then
                    return telemetryService[key]
                end
            end,
        })
    end
    return service
end

local function sourceDeclaration(recorders)
    local units = math.max(1, recorders)
    local declaration = SOURCE_DECLARATIONS[recorders]
    if not declaration then
        local stage = recorders == 0 and telemetryService.plainDecl.stages.run
            or units == 1 and telemetryService.recordedOneDecl.stages.run
            or telemetryService.decl.stages.run
        declaration = {
            class = telemetryService.decl.class,
            stages = { run = { fixed = stage.fixed, perUnit = stage.perUnit, maxUnits = units } },
        }
        SOURCE_DECLARATIONS[recorders] = declaration
    end
    return declaration, units
end

local function recorderCount(service, entry)
    local history = service.runtime and service.runtime.byId and service.runtime.byId.history
    local tracks = history and history.sources and history.sources[entry.state.name]
    return tracks and #tracks or 0
end

local function updateSourceTask(service, entry)
    local task = entry.task
    if not task then
        task = {
            id = "",
            sourceIndex = #service.schedulerTasks,
            interval = entry.interval,
            critical = true,
            entry = entry,
            service = service,
        }
        task.item = { id = task.id, instance = task, critical = true }
        task.step = function(_, grant, _, now)
            return telemetryService.stepSource(service, entry, grant, now)
        end
        entry.task = task
        service.schedulerTasks[#service.schedulerTasks + 1] = task.item
    end

    local recorders = recorderCount(service, entry)
    local declaration, units = sourceDeclaration(recorders)
    local category = recorders == 0 and "plain:"
        or recorders == 1 and "recorded-one:"
        or "recorded:"
    local taskId = SOURCE_TASK_PREFIX
        .. category
        .. tostring(task.sourceIndex)
    local changed = task.id ~= taskId
        or task.decl ~= declaration
        or task.want ~= units
        or task.interval ~= entry.interval
    task.id, task.item.id = taskId, taskId
    task.decl, task.want, task.interval = declaration, units, entry.interval
    if changed then
        service.schedulerRevision = service.schedulerRevision + 1
    end
end

local function updateMaintenanceInterval(service)
    service.maintenanceTask.want = math.max(1, #service.entries)
    if service.maintenanceTask.interval ~= service.interval then
        service.maintenanceTask.interval = service.interval
        service.schedulerRevision = service.schedulerRevision + 1
    end
end

--- Build the mutable state behind a subscription.
---@param name string
---@return table entry
local function newEntry(name, interval)
    -- EdgeTX exposes a sensor's minimum and maximum as "<name>-" and "<name>+".
    -- Precision is configured on the base sensor, so remember the stem.
    local base = string.gsub(name, "[%+%-]$", "")

    local state = {
        name = name,
        id = nil,
        known = false,
        telemetry = false,
        available = false,
        fresh = false,
        stale = false,
        state = "unavailable",
        value = nil,
        raw = nil,
        kind = "number",
        unit = 0,
        unitText = "",
        precision = 0,
        precisionKnown = false,
        updatedAt = nil,
        age = nil,
        revision = 0,
    }

    return {
        state = state,
        base = base,
        interval = interval,
        nextResolve = 0,
        scanIndex = nil,
    }
end

--- Subscribe to an EdgeTX source by name.
--- An absent or empty name yields a permanently unavailable reading rather
--- than nil, so a panel can render an unconfigured source without
--- branching and without ever indexing nil.
---@param name any
---@param linkEvidence? boolean False identifies a transmitter-local source shared by all subscribers.
---@param interval? integer Ticks of 10ms between polls; omitted means the legacy 10-tick interval.
---@return AeroGridReading
function telemetryService:subscribe(name, linkEvidence, interval)
    if type(name) ~= "string" or name == "" then
        if not self.noneView then
            self.noneView = self.support.snapshot(newEntry("", telemetryService.INTERVAL).state)
        end
        return self.noneView
    end

    if interval == nil then
        interval = telemetryService.INTERVAL
    elseif
        type(interval) ~= "number"
        or interval < 1
        or interval > MAX_INTERVAL
        or interval % 1 ~= 0
    then
        error("telemetry interval must be a positive whole number of ticks", 2)
    end

    local entry = self.names[name]
    if not entry then
        entry = self.support.addSubscription(self, self.entries, newEntry(name, interval))
        self.names[name] = entry
        if not self.batchRemaining then
            self.want = math.min(self.pollCap or telemetryService.POLL_CAP, telemetryService.POLL_CAP, #self.entries)
        end
        if #self.entries == 1 and not self.linkSubscribed then
            self.interval = interval
        elseif interval < self.interval then
            self.interval = interval
        end
    elseif interval < entry.interval then
        entry.interval = interval
        entry.nextPoll = 0
        self.interval = math.min(self.interval, interval)
    end

    if linkEvidence == false then
        entry.linkEvidence = false
    end
    updateSourceTask(self, entry)
    updateMaintenanceInterval(self)
    return entry.view
end

--- Subscribe to the link indicator itself.
---
--- `link-status` needs to tell three situations apart that all look like a
--- zero: a link that is genuinely down, a protocol that populates no RSSI
--- sensor at all, and a reading that really is zero. Only this service knows
--- the difference, because only it watches whether a telemetry source ever
--- contradicted `getRSSI()`.
---@return table view
function telemetryService:link()
    if not self.linkView then
        self.linkState = {
            live = false,
            rssi = 0,
            -- Believed until a telemetry source proves otherwise.
            indicator = true,
            updatedAt = nil,
        }
        self.linkView = self.support.snapshot(self.linkState)
        -- A panel referencing the link is a reason to run the service, even
        -- when it subscribed to no source the radio happens to recognize.
        self.count = self.count + 1
        self.linkSubscribed = true
        self.interval = math.min(self.interval, telemetryService.INTERVAL)
        updateMaintenanceInterval(self)
    end

    return self.linkView
end

--- Look up an existing subscription without creating one.
---@param name any
---@return AeroGridReading?
function telemetryService:reading(name)
    local entry = type(name) == "string" and self.names[name] or nil
    return entry and entry.view or nil
end

--- Observe completed polls without adding firmware reads.
function telemetryService:observe(observer)
    self.observers = self.observers or {}
    self.observers[#self.observers + 1] = observer
end

--- Resolve a source name to its EdgeTX id, unit, and value shape.
---@param entry table
---@param now integer
---@return boolean resolved
function telemetryService:resolve(entry, now)
    local lookup = self.env.getFieldInfo
    if not lookup then
        entry.nextResolve = now + telemetryService.RESOLVE_RETRY
        return false
    end

    local info = lookup(entry.state.name)
    if type(info) ~= "table" or type(info.id) ~= "number" then
        -- The sensor may simply not have been received yet; try again later.
        entry.nextResolve = now + telemetryService.RESOLVE_RETRY
        return false
    end

    local state = entry.state
    state.id = info.id
    state.known = true

    -- EdgeTX reports a unit only for telemetry sensors, which is also how this
    -- service tells link-dependent sources from radio-local ones.
    if type(info.unit) == "number" then
        state.telemetry = true
        state.unit = info.unit
        state.unitText = UNIT_TEXT[info.unit] or ""
        state.kind = UNIT_KIND[info.unit] or "number"
        -- EdgeTX returns the cells table only for the base source. "Cels-" and
        -- "Cels+" carry the same unit but return a plain number, so the lowest
        -- and highest cell would otherwise never be readable.
        if state.kind == "cells" and entry.base ~= state.name then
            state.kind = "number"
        end
        entry.scanIndex = 0
    else
        state.telemetry = false
        state.unit = 0
        state.unitText = ""
        state.kind = "number"
        state.precisionKnown = true
    end

    return true
end

--- Advance the bounded search for a sensor's configured precision.
--- EdgeTX does not report precision through `getFieldInfo`, so the sensor
--- table is searched by name. Only one subscription searches per update and
--- only a fixed number of sensors are inspected, so the cost is flat.
---@param entry table
function telemetryService:scanPrecision(entry)
    local getSensor = self.env.getSensor
    if not getSensor then
        entry.scanIndex = nil
        entry.state.precisionKnown = true
        return
    end

    local index = entry.scanIndex
    local limit = index + telemetryService.SCAN_CAP
    if limit > telemetryService.SENSOR_LIMIT then
        limit = telemetryService.SENSOR_LIMIT
    end

    while index < limit do
        local sensor = getSensor(index)
        if type(sensor) == "table" and sensor.name == entry.base then
            entry.state.precision = type(sensor.prec) == "number" and sensor.prec or 0
            entry.state.sensorIndex = index
            entry.state.precisionKnown = true
            entry.scanIndex = nil
            return
        end
        index = index + 1
    end

    -- Give up at the end of the table; precision stays at zero.
    entry.scanIndex = index < telemetryService.SENSOR_LIMIT and index or nil
    entry.state.precisionKnown = entry.scanIndex == nil
end

--- Apply one poll result to a subscription.
---@param entry table
---@param now integer
function telemetryService:poll(entry, now)
    local state = entry.state

    if not state.known then
        if now < entry.nextResolve then
            return
        end
        if not self:resolve(entry, now) then
            state.fresh = false
            -- A cached reading from a previous session stays stale, not unavailable.
            state.state = state.available and "stale" or "unavailable"
            state.stale = state.available
            return
        end
    end

    local read = self.env.getValue
    local raw = read and read(state.id)

    local kind = state.kind
    local value

    if kind == "number" then
        value = type(raw) == "number" and raw or nil
    elseif kind == "cells" then
        -- EdgeTX returns integer zero rather than a table when no cells are known.
        value = type(raw) == "table" and raw or nil
    elseif kind == "gps" then
        value = type(raw) == "table" and raw or nil
    else
        value = raw ~= nil and raw or nil
    end

    -- A telemetry source returns exactly integer zero when EdgeTX has nothing
    -- for it, so a non-zero value proves the link is alive no matter what the
    -- indicator says. Learn that once and stop trusting a broken indicator.
    -- Transmitter-local values (ELRS RFMD/TPWR) continue without a receiver.
    -- They are readings, but never evidence that receiver telemetry is live.
    if state.telemetry and entry.linkEvidence ~= false and value ~= nil and value ~= 0 and not self.linkLive then
        self.linkTrusted = false
        self.linkLive = true
    end

    -- Only the ambiguous case is withheld: a zero read while the link is down is
    -- not a reading, so the last live value is kept and marked stale.
    if value == nil or (state.telemetry and value == 0 and not self.linkLive) then
        state.fresh = false
        state.stale = state.available
        state.state = state.available and "stale" or "unavailable"
        if state.updatedAt then
            state.age = self.support.age(now, state.updatedAt)
        end
        return
    end

    local changed = state.raw ~= value
    state.raw = value
    state.value = kind == "number" and value or nil
    state.available = true
    state.fresh = true
    state.stale = false
    state.state = "normal"
    state.updatedAt = now
    state.age = 0
    if changed then
        state.revision = state.revision + 1
    end
end

--- Copy the current link belief into the published snapshot.
---@param now integer
function telemetryService:publishLink(now)
    local link = self.linkState
    if not link then
        return
    end

    link.rssi = self.rssi
    link.live = self.linkLive
    link.indicator = self.linkTrusted ~= false
    if self.linkLive then
        link.updatedAt = now
    end
end

--- Poll a bounded slice of the subscriptions.
---@param now integer
local function pollEntry(service, entry, now)
    if service.tickElapsed then
        if entry.nextPoll and service.tickElapsed(now, entry.nextPoll) < 0 then
            return false
        end
    elseif entry.nextPoll and now < entry.nextPoll then
        return false
    end

    service:poll(entry, now)
    entry.nextPoll = now + entry.interval
    if service.observers then
        for _, observer in ipairs(service.observers) do
            if not observer.failed and not observer.failure then
                local ok, message = pcall(observer.sample, observer, entry.view, now)
                if not ok then
                    observer.failure = tostring(message)
                end
            end
        end
    end
    return true
end

beginUpdate = function(service, now)
    local read = service.env.getRSSI
    local rssi = read and read() or 0
    if type(rssi) ~= "number" then
        rssi = 0
    end

    -- EdgeTX reports zero RSSI whenever telemetry is not streaming, which is the
    -- only link-liveness signal the Lua API offers.
    service.rssi = rssi
    service.linkLive = rssi > 0 or service.linkTrusted == false
    service:publishLink(now)
end

finishUpdate = function(service, now, scan)
    service:publishLink(now)
    local entries = service.entries
    local total = #entries
    if scan ~= false and total > 0 then
        -- Advance at most one precision search per completed release, in
        -- rotation, so a dashboard never pays multiple scans in one update.
        local scan = service.scanCursor
        if scan > total then
            scan = 1
        end
        for _ = 1, total do
            local entry = entries[scan]
            scan = scan % total + 1
            if entry and entry.scanIndex then
                service:scanPrecision(entry)
                break
            end
        end
        service.scanCursor = scan
    end
    service.revision = service.revision + 1
end

--- Run one source poll and its synchronous History observers as an indivisible grant.
---@param service table
---@param entry table
---@param grant integer
---@param now integer
---@return integer delay
function telemetryService.stepSource(service, entry, grant, now)
    local task = entry.task
    if grant < task.want then
        return 1
    end

    beginUpdate(service, now)
    if not pollEntry(service, entry, now) then
        return entry.interval
    end
    service:publishLink(now)
    service.revision = service.revision + 1
    return entry.interval
end

function telemetryService:update(now)
    beginUpdate(self, now)
    local entries = self.entries
    if #entries > 0 then
        local cap = math.min(self.pollCap or telemetryService.POLL_CAP, telemetryService.POLL_CAP)
        self.cursor = self.support.roundRobin(entries, self.cursor, cap, pollEntry, self, now)
    end
    finishUpdate(self, now)
end

--- Poll one bounded round-robin slice. A poll and all of its history observers
--- remain one atomic unit; a partial grant resumes at the next source.
---@param grant integer
---@param stage string
---@param now integer
---@return integer delay
function telemetryService:step(grant, _, now)
    beginUpdate(self, now)

    local entries = self.entries
    local total = #entries
    if total == 0 then
        finishUpdate(self, now)
        self.due = now + self.interval
        return self.interval
    end

    if not self.batchRemaining then
        self.batchRemaining = math.min(self.pollCap or telemetryService.POLL_CAP, telemetryService.POLL_CAP, total)
    end
    local visits = math.min(grant, self.batchRemaining)
    for _ = 1, visits do
        local entry = entries[self.cursor]
        self.cursor = self.cursor % total + 1
        pollEntry(self, entry, now)
    end
    self.batchRemaining = self.batchRemaining - visits
    if self.batchRemaining > 0 then
        self.want = self.batchRemaining
        finishUpdate(self, now, false)
        self.revision = self.revision + 1
        return 1
    end

    self.batchRemaining = nil
    self.want = math.min(self.pollCap or telemetryService.POLL_CAP, telemetryService.POLL_CAP, total)
    finishUpdate(self, now)
    self.revision = self.revision + 1
    self.due = now + self.interval
    return self.interval
end

--- Format a reading for display, honoring its precision.
--- Provided as a module function rather than a snapshot field so formatting is
--- paid only by the panels that actually render text.
---@param reading AeroGridReading?
---@param precision? integer Overrides the sensor's own precision.
---@return string
function telemetryService.format(reading, precision)
    if type(reading) ~= "table" then
        return "--"
    end

    local value = reading.value
    if type(value) ~= "number" or value ~= value then
        if reading.kind == "text" and type(reading.raw) == "string" then
            return reading.raw
        end
        return "--"
    end

    local digits = precision
    if type(digits) ~= "number" or digits < 0 then
        digits = reading.precision
    end
    digits = math.floor(tonumber(digits) or 0)
    if digits < 0 then
        digits = 0
    end
    if digits > 3 then
        digits = 3
    end

    return string.format("%." .. digits .. "f", value)
end

--- Describe a reading as diagnostic rows.
--- The rows exist so a diagnostic view can prove normalized output without
--- depending on any production panel's presentation.
---@param rows table Reusable row array of {label = , text = } tables.
---@param reading AeroGridReading? Subscription to describe.
---@return integer count
function telemetryService:describe(rows, reading)
    if type(reading) ~= "table" then
        return 0
    end

    local row = self.support.row
    local index = row(rows, 1, "SRC", reading.name ~= "" and reading.name or "-")
    index = row(rows, index, "STATE", string.upper(reading.state))
    index = row(rows, index, "VALUE", telemetryService.format(reading))
    index = row(rows, index, "UNIT", reading.unitText ~= "" and reading.unitText or "-")
    index = row(rows, index, "PREC", tostring(reading.precision))
    index = row(rows, index, "AGE", reading.age and string.format("%.1fs", reading.age) or "-")
    index = row(rows, index, "LINK", self.linkLive and "UP" or "DOWN")

    return index - 1
end

return telemetryService
