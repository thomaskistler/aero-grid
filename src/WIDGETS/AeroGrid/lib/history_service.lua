-- SPDX-License-Identifier: GPL-2.0-only

--- Armed-time recordings. Raw extrema are collected at every telemetry poll;
--- bounded display buckets are compacted separately in scheduled service work.
local history = { RUNTIME_API = 1, CAPACITY = 32 }
history.__index = history

local TAU = { off = 0, light = 50, medium = 100, strong = 200 }
local FIELDS = { "first", "firstAt", "low", "lowAt", "high", "highAt", "last", "lastAt", "segment", "breakBefore" }

local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function copy(target, source)
    for _, key in ipairs(FIELDS) do
        target[key] = source[key]
    end
end

local function start(point, value, now, segment, broken)
    point.first, point.low, point.high, point.last = value, value, value, value
    point.firstAt, point.lowAt, point.highAt, point.lastAt = now, now, now, now
    point.segment, point.breakBefore = segment, broken
end

local function extend(point, value, now)
    if value < point.low then
        point.low, point.lowAt = value, now
    end
    if value > point.high then
        point.high, point.highAt = value, now
    end
    point.last, point.lastAt = value, now
end

function history.new(env, support, runtime)
    local state = { configured = false, available = false, recording = false, elapsed = 0, segment = 0, revision = 0 }
    return setmetatable({
        id = "history",
        revision = 0,
        interval = 5,
        count = 0,
        due = 0,
        env = env,
        support = support,
        runtime = runtime,
        entries = {},
        names = {},
        views = {},
        cursor = 1,
        state = state,
        view = support.snapshot(state),
    }, history)
end

function history:session(armSource)
    if type(armSource) == "string" and armSource ~= "" and not self.armSource then
        self.armSource = armSource
        self.state.configured = true
        local telemetry = self.runtime.byId.telemetry
        self.arm = telemetry and telemetry:subscribe(armSource) or nil
    end
    return self.view
end

function history:advance(now)
    local state = self.state
    if self.lastTime and state.recording then
        state.elapsed = state.elapsed + math.max(0, now - self.lastTime)
    end
    self.lastTime = now
    local arm = self.arm
    local available = arm ~= nil and arm.fresh == true and finite(arm.value)
    local recording = arm ~= nil and available and arm.value > 0 or false
    if state.recording ~= recording or state.available ~= available then
        if recording and not state.recording then
            state.segment = state.segment + 1
        end
        state.recording, state.available = recording, available == true
        state.revision = state.revision + 1
    end
end

function history:subscribe(source, options)
    options = options or {}
    local window = options.windowSeconds or 60
    local mode = options.timeRange or "growing"
    local smoothing = options.smoothing or "off"
    assert(finite(window) and window >= 30 and window <= 600, "history window must be 30 to 600 seconds")
    assert(mode == "growing" or mode == "rolling", "invalid history time range")
    assert(TAU[smoothing], "invalid history smoothing")
    source = type(source) == "string" and source or ""
    local key = source .. "\0" .. mode .. "\0" .. window .. "\0" .. smoothing
    if self.names[key] then
        return self.names[key].view
    end
    local state = {
        name = source,
        available = false,
        stale = false,
        value = nil,
        min = nil,
        max = nil,
        unitText = "",
        precision = 0,
        revision = 0,
        count = 0,
        window = window * 100,
    }
    local entry = {
        state = state,
        view = self.support.snapshot(state),
        points = {},
        head = 1,
        step = window * 100 / (history.CAPACITY - 2),
        mode = mode,
        tau = TAU[smoothing],
        pending = {},
        gap = true,
    }
    self.entries[#self.entries + 1] = entry
    self.names[key], self.views[entry.view] = entry, entry
    self.sources = self.sources or {}
    local tracks = self.sources[source] or {}
    self.sources[source] = tracks
    tracks[#tracks + 1] = entry
    self.count = self.count + 1
    local telemetry = self.runtime.byId.telemetry
    if telemetry then
        telemetry:subscribe(source)
        if not self.observing then
            telemetry:observe(self)
            self.observing = true
        end
    end
    return entry.view
end

function history:point(view, index)
    local entry = self.views[view]
    if not entry or index < 1 or index > entry.state.count then
        return nil
    end
    return entry.points[(entry.head + index - 2) % history.CAPACITY + 1].view
end

local function slot(service, entry, index)
    local point = entry.points[index]
    if not point then
        point = {}
        point.view = service.support.snapshot(point)
        entry.points[index] = point
    end
    return point
end

local function append(service, entry, source)
    local state = entry.state
    local index = (entry.head + state.count - 1) % history.CAPACITY + 1
    if state.count == history.CAPACITY then
        entry.head = entry.head % history.CAPACITY + 1
    else
        state.count = state.count + 1
    end
    copy(slot(service, entry, index), source)
end

local function record(service, entry, value, now, segment)
    local state = entry.state
    local last = state.count > 0 and entry.points[(entry.head + state.count - 2) % history.CAPACITY + 1] or nil
    if
        last
        and not entry.compact
        and not entry.gap
        and last.segment == segment
        and math.floor(last.lastAt / entry.step) == math.floor(now / entry.step)
    then
        extend(last, value, now)
    else
        if entry.compact then
            if entry.pendingActive and not entry.gap and entry.pending.segment == segment then
                extend(entry.pending, value, now)
            else
                start(entry.pending, value, now, segment, true)
                entry.pendingActive = true
            end
        elseif state.count == history.CAPACITY and entry.mode == "growing" then
            start(entry.pending, value, now, segment, entry.gap)
            entry.pendingActive, entry.compact = true, true
        else
            start(entry.pending, value, now, segment, entry.gap)
            append(service, entry, entry.pending)
        end
    end
    entry.gap = false
end

function history:sample(reading, now)
    self:advance(now)
    if not self.state.recording then
        return
    end
    local entries = self.sources[reading.name]
    if not entries then
        return
    end
    for _, entry in ipairs(entries) do
        local state = entry.state
        local valid = reading.fresh and reading.updatedAt == now and finite(reading.value) and reading.kind == "number"
        if valid then
            local value = reading.value
            if entry.segment ~= self.state.segment or entry.gap or not entry.filtered then
                entry.filtered = value
                entry.gap = true
            elseif entry.tau > 0 then
                local alpha = 1 - math.exp(-math.max(0, now - entry.sampledAt) / entry.tau)
                entry.filtered = entry.filtered + alpha * (value - entry.filtered)
            else
                entry.filtered = value
            end
            entry.sampledAt, entry.segment = now, self.state.segment
            state.value = value
            state.min = state.min and math.min(state.min, value) or value
            state.max = state.max and math.max(state.max, value) or value
            state.unitText, state.precision = reading.unitText, reading.precision
            state.available, state.stale = true, false
            record(self, entry, entry.filtered, self.state.elapsed, self.state.segment)
            state.revision = state.revision + 1
        else
            entry.gap = true
            if not state.stale then
                state.stale = state.available
                state.revision = state.revision + 1
            end
        end
    end
end

local function compact(service, entry)
    local count = entry.state.count
    local write = 0
    for index = 1, count, 2 do
        write = write + 1
        local first, second = entry.points[index], entry.points[index + 1]
        local target = entry.points[write]
        if second then
            if first.segment ~= second.segment or second.breakBefore then
                copy(target, second)
                target.breakBefore = true
            else
                local low, lowAt = first.low, first.lowAt
                local high, highAt = first.high, first.highAt
                if second.low < low then
                    low, lowAt = second.low, second.lowAt
                end
                if second.high > high then
                    high, highAt = second.high, second.highAt
                end
                local initial, initialAt, broken = first.first, first.firstAt, first.breakBefore
                copy(target, second)
                target.first, target.firstAt, target.breakBefore = initial, initialAt, broken
                target.low, target.lowAt, target.high, target.highAt = low, lowAt, high, highAt
            end
        else
            copy(target, first)
        end
    end
    entry.state.count, entry.head = write, 1
    entry.step = entry.step * 2
    entry.compact = false
    if entry.pendingActive then
        append(service, entry, entry.pending)
        entry.pendingActive = false
    end
    entry.state.revision = entry.state.revision + 1
end

local function updateEntry(service, entry)
    local state = entry.state
    if entry.compact then
        compact(service, entry)
    end
    if entry.mode == "growing" then
        while service.state.elapsed > state.window do
            state.window = state.window * 2
        end
    else
        local cutoff = service.state.elapsed - state.window
        while state.count > 0 and entry.points[entry.head].lastAt < cutoff do
            entry.head = entry.head % history.CAPACITY + 1
            state.count = state.count - 1
            state.revision = state.revision + 1
        end
    end
end

function history:update(now)
    if self.failure then
        error(self.failure)
    end
    self:advance(now)
    self.cursor = self.support.roundRobin(self.entries, self.cursor, 1, updateEntry, self, now)
end

return history
