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

local telemetryService = {}
telemetryService.__index = telemetryService

--- Ticks of 10ms between polls of a recorded source, the 10 Hz telemetry rate.
--- Updates run on this grid, so a late update does not slow later ones.
telemetryService.INTERVAL = 10

--- Ticks between polls of a source only panels display, 5 Hz.
telemetryService.DISPLAY_PERIOD = 20

--- Above this many recorded sources, updates run twice as often and each polls
--- half of them, so every source keeps 10 Hz without one heavy callback.
telemetryService.SPLIT_AT = 12

--- Every due source is polled in one step. Handing samples to observers was
--- measured at about 1,800 instructions, and each source at under 100.
telemetryService.OBSERVER_SLOTS = 4
telemetryService.SOURCES_PER_SLOT = 6
telemetryService.updateCost = 1
local MAX_COST = 32

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
function telemetryService.new(env, support)
    return setmetatable({
        id = "telemetry",
        interval = telemetryService.INTERVAL,
        revision = 0,
        count = 0,
        due = 0,
        env = env,
        support = support,
        names = {},
        entries = {},
        batch = {},
        scanCursor = 1,
        precisionScans = 0,
        linkLive = false,
        rssi = 0,
    }, telemetryService)
end

--- Build the mutable state behind a subscription.
---@param name string
---@return table entry
local function newEntry(name)
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

    return { state = state, base = base, nextResolve = 0, nextPoll = 0, scanIndex = nil }
end

--- Charge the next update for the sources it will poll.
---@param service table
---@param polls integer
local function chargeFor(service, polls)
    local cost = math.ceil(polls / telemetryService.SOURCES_PER_SLOT)
    if service.observers and #service.observers > 0 then
        cost = cost + telemetryService.OBSERVER_SLOTS
    end
    service.updateCost = cost < 1 and 1 or cost > MAX_COST and MAX_COST or cost
    service.nextPolls = polls
end

--- Subscribe to an EdgeTX source by name.
--- An absent or empty name yields a permanently unavailable reading rather
--- than nil, so a panel can render an unconfigured source without
--- branching and without ever indexing nil.
---
--- A recorded source is polled at 10 Hz and handed to observers; any other is
--- polled at 5 Hz for display.
---@param name any
---@param linkEvidence? boolean False identifies a transmitter-local source shared by all subscribers.
---@param recorded? boolean True when observers record every sample of the source.
---@return AeroGridReading
function telemetryService:subscribe(name, linkEvidence, recorded)
    if type(name) ~= "string" or name == "" then
        if not self.noneView then
            self.noneView = self.support.snapshot(newEntry("").state)
        end
        return self.noneView
    end

    local entry = self.names[name]
    if not entry then
        entry = self.support.addSubscription(self, self.entries, newEntry(name))
        self.names[name] = entry
        -- A new source is polled by the next update.
        chargeFor(self, (self.nextPolls or 0) + 1)
    end

    if linkEvidence == false then
        entry.linkEvidence = false
    end
    if recorded and not entry.recorded then
        entry.recorded = true
        self.recordedCount = (self.recordedCount or 0) + 1
        entry.half = self.recordedCount % 2
    end
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
        self.support.subscribed(self)
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

--- Observe the samples of recorded sources without adding firmware reads.
--- `observer:samples(views, count, now)` receives each update's recorded
--- readings as one batch; a raised error stops that observer only.
function telemetryService:observe(observer)
    self.observers = self.observers or {}
    self.observers[#self.observers + 1] = observer
    chargeFor(self, self.nextPolls or 0)
end

function telemetryService:unobserve(observer)
    for index, existing in ipairs(self.observers or {}) do
        if existing == observer then
            table.remove(self.observers, index)
            chargeFor(self, self.nextPolls or 0)
            return
        end
    end
    error("telemetry observer is not registered")
end

---@class AeroGridThreshold
---@field sensor string EdgeTX source name.
---@field warning? number
---@field critical? number
---@field falling boolean Values at or below a threshold alarm, rather than at or above.
---@field strict? boolean Only values strictly beyond a threshold alarm.

--- Register one panel's thresholds, replacing any earlier registration.
---
--- EdgeTX sensors carry no thresholds, so they come from the panels on this
--- dashboard. Only saved panels register; editor previews leave the saved
--- thresholds in place until Save adopts them.
---@param owner any Placement id of the registering panel.
---@param module? table Panel module; nil, or one without a hook, clears.
---@param settings? table Resolved panel settings.
---@return boolean ok, string? message
function telemetryService:registerPanel(owner, module, settings)
    self.thresholdOwners = self.thresholdOwners or {}
    local hook = type(module) == "table" and rawget(module, "thresholds") or nil
    if type(hook) ~= "function" or type(settings) ~= "table" then
        self.thresholdOwners[owner] = nil
        return true
    end
    local ok, list = pcall(hook, settings)
    self.thresholdOwners[owner] = ok and type(list) == "table" and list or nil
    if not ok then
        return false, tostring(list)
    end
    return true
end

--- Forget every registration, before re-registering a whole saved layout.
function telemetryService:clearThresholds()
    self.thresholdOwners = {}
end

--- Supply the layout's placements in layout order.
---
--- Panels are rebuilt one at a time by App-mode rebuilds and the editor, so
--- registration order is not layout order; ownership is decided on lookup.
---@param order fun(): table[]?
function telemetryService:setLayoutOrder(order)
    self.layoutOrder = order
end

--- Thresholds of every sensor, built in one pass over the layout.
---@return table<string, AeroGridThreshold>
function telemetryService:thresholdMap()
    local owners = self.thresholdOwners
    local placements = owners and self.layoutOrder and self.layoutOrder()
    if type(placements) ~= "table" then
        return {}
    end
    return telemetryService.ownedThresholds(placements, owners)
end

--- The ownership rule on its own: the first placement in `placements` whose
--- declaration (`owners[placement.id]`) sets any level owns a sensor.
---@param placements table[]
---@param owners table<any, table[]>
---@return table<string, AeroGridThreshold>
function telemetryService.ownedThresholds(placements, owners)
    local map = {}
    for _, placement in ipairs(placements) do
        for _, spec in ipairs(owners[placement.id] or {}) do
            local sensor = type(spec) == "table" and spec.sensor
            if
                type(sensor) == "string"
                and map[sensor] == nil
                and (type(spec.warning) == "number" or type(spec.critical) == "number")
            then
                map[sensor] = spec
            end
        end
    end
    return map
end

--- Thresholds for one sensor; the first panel in layout order setting any wins.
---@param sensor any
---@return AeroGridThreshold?
function telemetryService:thresholds(sensor)
    return self:thresholdMap()[sensor]
end

--- Judge a value against thresholds.
---@param spec? AeroGridThreshold
---@param value any
---@return "normal"|"warning"|"critical"
function telemetryService.level(spec, value)
    if type(spec) ~= "table" or type(value) ~= "number" then
        return "normal"
    end
    local function beyond(limit)
        if type(limit) ~= "number" then
            return false
        end
        if spec.falling then
            if spec.strict then
                return value < limit
            end
            return value <= limit
        end
        if spec.strict then
            return value > limit
        end
        return value >= limit
    end
    if beyond(spec.critical) then
        return "critical"
    end
    if beyond(spec.warning) then
        return "warning"
    end
    return "normal"
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
        if not entry.scanIndex then
            self.precisionScans = self.precisionScans + 1
        end
        entry.scanIndex = 0
    else
        if entry.scanIndex then
            entry.scanIndex = nil
            self.precisionScans = self.precisionScans - 1
        end
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
        self.precisionScans = self.precisionScans - 1
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
            self.precisionScans = self.precisionScans - 1
            return
        end
        index = index + 1
    end

    -- Give up at the end of the table; precision stays at zero.
    entry.scanIndex = index < telemetryService.SENSOR_LIMIT and index or nil
    entry.state.precisionKnown = entry.scanIndex == nil
    if not entry.scanIndex then
        self.precisionScans = self.precisionScans - 1
    end
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

--- Poll every due subscription in one step, then hand observers the batch of
--- recorded samples.
---@param now integer
function telemetryService:update(now)
    local read = self.env.getRSSI
    local rssi = read and read() or 0
    if type(rssi) ~= "number" then
        rssi = 0
    end

    -- EdgeTX reports zero RSSI whenever telemetry is not streaming, which is the
    -- only link-liveness signal the Lua API offers.
    self.rssi = rssi
    self.linkLive = rssi > 0 or self.linkTrusted == false
    self:publishLink(now)

    -- Stay on the grid; an update later than a whole interval restarts it.
    local split = (self.recordedCount or 0) > telemetryService.SPLIT_AT
    local interval = telemetryService.INTERVAL
    local half
    if split then
        interval = interval // 2
        half = 1 - (self.half or 1)
        self.half = half
    end
    local due = (self.gridDue or now) + interval
    if due <= now then
        due = now + interval
    end
    self.gridDue, self.due = due, due

    local entries = self.entries
    local total = #entries
    local batch, recorded, upcoming = self.batch, 0, 0
    -- Half an interval of slack still polls a late display source every
    -- DISPLAY_PERIOD.
    local displayNext = now + telemetryService.DISPLAY_PERIOD - interval // 2
    for index = 1, total do
        local entry = entries[index]
        if entry.recorded then
            if entry.half == half or not split then
                self:poll(entry, now)
                recorded = recorded + 1
                batch[recorded] = entry.view
            end
            if entry.half ~= half or not split then
                upcoming = upcoming + 1
            end
        else
            if entry.nextPoll <= now then
                self:poll(entry, now)
                entry.nextPoll = displayNext
            end
            if entry.nextPoll <= due then
                upcoming = upcoming + 1
            end
        end
    end
    chargeFor(self, upcoming)

    -- Republished after the polls, because a live reading can prove the
    -- indicator wrong part way through this very update.
    self:publishLink(now)

    local observers = self.observers
    if observers and recorded > 0 then
        for _, observer in ipairs(observers) do
            if not observer.failed and not observer.failure then
                local ok, message = pcall(observer.samples, observer, batch, recorded, now)
                if not ok then
                    observer.failure = tostring(message)
                end
            end
        end
    end

    -- Advance at most one precision search per update, in rotation, so a
    -- dashboard of sixteen sources never pays sixteen table scans at once.
    if self.precisionScans == 0 or total == 0 then
        return
    end
    local scan = self.scanCursor
    if scan > total then
        scan = 1
    end
    for _ = 1, total do
        local entry = entries[scan]
        scan = scan % total + 1
        if entry and entry.scanIndex then
            self:scanPrecision(entry)
            break
        end
    end
    self.scanCursor = scan
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
