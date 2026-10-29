-- SPDX-License-Identifier: GPL-2.0-only

local smart = { RUNTIME_API = 1, RECENT_TICKS = 120 }
smart.__index = smart

local SPEED = { [4] = 0.51444444444444, [5] = 1, [6] = 0.3048, [7] = 1 / 3.6, [8] = 0.44704 }
local ALTITUDE = { [9] = 1, [10] = 0.3048 }
local COUNT = { [0] = 1 }
local FRSKY = { [2] = true, [3] = true, [7] = true, [8] = true, [9] = true, [10] = true, [12] = true, [14] = true }

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

function smart.new(env, support)
    return setmetatable({
        id = "smart",
        interval = 10,
        due = 0,
        count = 0,
        revision = 0,
        env = env,
        support = support,
        state = {
            generation = 0,
            altitude = {},
            speed = {},
            gps = {},
            satellites = {},
            status = "Smart: discovering sensors; standard available.",
        },
    }, smart)
end

local function invalidate(state)
    if state.fresh then
        state.continuity = (state.continuity or 0) + 1
    end
    state.fresh, state.sampleFresh = false, false
    state.evidenceAt, state.confirmedAt = nil, nil
end

local function observe(state, value, current, fresh, now)
    local evidence = state.evidenceAt
    if evidence and (now < evidence or now - evidence > smart.RECENT_TICKS) then
        invalidate(state)
    end
    if current ~= true or value == nil then
        invalidate(state)
        return false
    end
    -- isCurrent can outlive a stopped stream by seconds. Only positive
    -- isFresh observations renew this bounded per-sensor receipt evidence.
    if fresh == true then
        state.evidenceAt = now
    end
    if not state.evidenceAt then
        invalidate(state)
        return false
    end
    state.value, state.available, state.fresh, state.updatedAt = value, true, true, now
    state.sampleFresh, state.confirmedAt = fresh == true, state.evidenceAt
    return true
end

function smart:enable()
    self.count = 1
    return self.support.snapshot(self.state)
end

-- ModuleType, custom sensor IDs/instances, and "telemN" are EdgeTX firmware
-- contracts, not editable labels. Unknown/multiple modules fail closed.
function smart:family()
    if not (self.env.getSourceValue and self.env.getSensor and self.env.getFieldInfo and self.env.getModule) then
        return nil, "Smart unavailable: sensor API missing; standard only."
    end
    local selected
    for index = 0, 1 do
        local module = self.env.getModule(index)
        if type(module) == "table" and module.Type ~= 0 then
            if selected then
                return nil, "Smart unavailable: ambiguous radio modules; standard only."
            end
            selected = module.Type
        end
    end
    if selected == 5 then
        return "crsf"
    elseif FRSKY[selected] then
        return "sport"
    end
    return nil, "Smart unavailable: unsupported radio protocol; standard only."
end

local function category(sensor, family)
    if type(sensor) ~= "table" or sensor.type ~= 0 or not finite(sensor.id) then
        return nil
    end
    local id = sensor.id
    if family == "crsf" then
        if id == 0x09 and sensor.instance == 0 then
            return "altitude"
        elseif id == 0x02 and sensor.instance == 2 then
            return "speed"
        elseif id == 0x02 and sensor.instance == 0 then
            return "gps"
        elseif id == 0x02 and sensor.instance == 5 then
            return "satellites"
        end
    elseif family == "sport" then
        if id >= 0x0100 and id <= 0x010F then
            return "altitude"
        elseif id >= 0x0830 and id <= 0x083F then
            return "speed"
        elseif id >= 0x0800 and id <= 0x080F then
            return "gps"
        end
    end
end

local function identity(sensor, index)
    return table.concat({
        index,
        tostring(sensor.type),
        tostring(sensor.id),
        sensor.instance or -1,
        sensor.unit or -1,
        sensor.prec or -1,
    }, ":")
end

function smart:discover(now)
    if not self.scan then
        if now < (self.scanDue or 0) then
            return
        end
        local family, message = self:family()
        if not family then
            self.state.altitude, self.state.speed = {}, {}
            self.state.gps, self.state.satellites = {}, {}
            self.state.status = message
            self.state.generation = self.state.generation + 1
            self.selected = nil
            self.scanDue = now + 200
            return
        end
        self.scan = { index = 0, family = family, candidates = {}, counts = {} }
    end
    local scan = self.scan
    for _ = 1, 8 do
        local index = scan.index
        local sensor = self.env.getSensor(index)
        local kind = category(sensor, scan.family)
        if kind then
            scan.counts[kind] = (scan.counts[kind] or 0) + 1
            local info = self.env.getFieldInfo("telem" .. (index + 1))
            scan.candidates[kind] = {
                id = type(info) == "table" and info.id,
                unit = sensor.unit,
                index = index,
                instance = sensor.instance,
                sensorId = sensor.id,
                precision = sensor.prec,
                identity = identity(sensor, index),
            }
        end
        scan.index = index + 1
        if scan.index == 60 then
            local selected, parts = {}, { scan.family }
            for _, key in ipairs({ "altitude", "speed", "gps", "satellites" }) do
                local candidate = scan.candidates[key]
                if scan.counts[key] == 1 and candidate and type(candidate.id) == "number" then
                    selected[key] = candidate
                    parts[#parts + 1] = candidate.identity
                else
                    parts[#parts + 1] = key .. ":" .. tostring(scan.counts[key] or 0)
                end
            end
            local signature = table.concat(parts, "/")
            if signature ~= self.signature then
                self.state.generation = self.state.generation + 1
                self.state.altitude, self.state.speed = {}, {}
                self.state.gps, self.state.satellites = {}, {}
                self.signature = signature
            end
            self.selected, self.counts = selected, scan.counts
            self.scan, self.scanDue = nil, now
            return
        end
    end
end

function smart:read(candidate, scales, state, now)
    if not candidate or not scales[candidate.unit] then
        invalidate(state)
        return false
    end
    local value, current, fresh = self.env.getSourceValue(candidate.id)
    if not finite(value) then
        invalidate(state)
        return false
    end
    value = value * scales[candidate.unit]
    return observe(state, finite(value) and value or nil, current, fresh, now)
end

function smart:gpsReady(candidate, now)
    local position = self.state.gps
    if not candidate or candidate.unit ~= 40 then
        invalidate(position)
        return false
    end
    if self.selected.speed and string.match(self.signature, "^sport/") then
        if self.selected.speed.instance ~= candidate.instance then
            invalidate(position)
            return false
        end
    end
    local gps, current, fresh = self.env.getSourceValue(candidate.id)
    local valid = type(gps) == "table"
        and finite(gps.lat)
        and finite(gps.lon)
        and math.abs(gps.lat) <= 90
        and math.abs(gps.lon) <= 180
        and (math.abs(gps.lat) > 0.0000005 or math.abs(gps.lon) > 0.0000005)
        and finite(gps.delay)
        and gps.delay >= 0
        and gps.delay * 16 <= smart.RECENT_TICKS
    if not observe(position, valid and gps or nil, current, fresh, now) then
        return false
    end
    if string.match(self.signature, "^crsf/") then
        local satellites = self.selected.satellites
        local count = self.state.satellites
        if not self:read(satellites, COUNT, count, now) then
            return false
        end
        if count.value % 1 ~= 0 or count.value < 4 then
            return false
        end
    end
    return true
end

local function diagnostic(kind, count, candidate, live, received)
    if count and count > 1 then
        return kind .. " ambiguous"
    elseif not candidate then
        return kind .. " absent/unsupported"
    end
    return kind .. (live and (received and " ready" or " current") or " unavailable/stale")
end

function smart:update(now)
    self:discover(now)
    local selected = self.selected
    if not selected then
        return
    end
    local family = self:family()
    local valid = family ~= nil and family == string.match(self.signature, "^([^/]+)")
    for _, candidate in pairs(selected) do
        local sensor = self.env.getSensor(candidate.index)
        valid = valid
            and type(sensor) == "table"
            and sensor.type == 0
            and sensor.id == candidate.sensorId
            and sensor.instance == candidate.instance
            and sensor.unit == candidate.unit
            and sensor.prec == candidate.precision
    end
    if not valid then
        self.selected, self.signature, self.scan, self.scanDue = nil, nil, nil, nil
        self.state.generation = self.state.generation + 1
        self.state.altitude, self.state.speed = {}, {}
        self.state.gps, self.state.satellites = {}, {}
        self.state.status = "Smart: sensor configuration changed; rediscovering. Standard available."
        return
    end
    local altitude, speed = self.state.altitude, self.state.speed
    local baro = self:read(selected.altitude, ALTITUDE, altitude, now)
    local moving = self:read(selected.speed, SPEED, speed, now)
    if not self:gpsReady(selected.gps, now) or (moving and speed.value < 0) then
        moving = false
        invalidate(speed)
    elseif moving then
        speed.confirmedAt = math.min(speed.evidenceAt, self.state.gps.evidenceAt)
        if string.match(self.signature, "^crsf/") then
            speed.confirmedAt = math.min(speed.confirmedAt, self.state.satellites.evidenceAt)
        end
    end
    self.state.status = "Smart: "
        .. diagnostic("baro", self.counts.altitude, selected.altitude, baro, altitude.sampleFresh)
        .. "; "
        .. diagnostic(
            "GPS speed",
            math.max(self.counts.speed or 0, self.counts.gps or 0, self.counts.satellites or 0),
            selected.speed and selected.gps and selected.speed,
            moving,
            speed.sampleFresh
                and self.state.gps.sampleFresh
                and (not string.match(self.signature, "^crsf/") or self.state.satellites.sampleFresh)
        )
        .. ". Standard available."
end

return smart
