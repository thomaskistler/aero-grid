-- SPDX-License-Identifier: GPL-2.0-only

--- Saved model Armed takes precedence over retained panel switches.
local armed = { RUNTIME_API = 1 }
armed.__index = armed

local INTERVAL = 20
local POLL_CAP = 6

armed.decl = {
    class = "critical",
    stages = { run = { fixed = 180, perUnit = 120, maxUnits = POLL_CAP } },
}

local function valid(name)
    if type(name) ~= "string" then
        return false
    end
    local logical = tonumber(string.match(name, "^!?L(%d%d)$"))
    return name == ""
        or string.match(name, "^S[A-Z][%^v%-]$") ~= nil
        or logical ~= nil and logical >= 1 and logical <= 64
end
local function nativeName(index, control)
    if index == nil or index == 0 then
        return ""
    end
    assert(type(index) == "number" and control, "Arm switch requires switch APIs")
    for letter = string.byte("A"), string.byte("Z") do
        for _, suffix in ipairs({ "^", "-", "v" }) do
            local name = "S" .. string.char(letter) .. suffix
            if control:switchIndex(name) == index then
                return name
            end
        end
    end
    for number = 1, 64 do
        local name = string.format("L%02d", number)
        if control:switchIndex(name) == math.abs(index) then
            return index < 0 and "!" .. name or name
        end
    end
    error("Arm switch must be a physical switch position or logical switch", 2)
end

armed.valid = valid
armed.name = nativeName

function armed.new(env, support, runtime)
    local service = setmetatable({
        id = "armed",
        interval = INTERVAL,
        due = 0,
        count = 0,
        revision = 0,
        env = env,
        support = support,
        runtime = runtime,
        condition = runtime.modelArmed,
        generation = runtime.armGeneration or 0,
        views = {},
        entries = {},
        cursor = 1,
        remaining = nil,
    }, armed)
    local task = { decl = armed.decl, interval = INTERVAL, want = 0 }
    task.step = function(_, grant, _, now)
        if service.failed then
            return 1
        end
        local ok, delay = pcall(service.step, service, grant, now)
        if not ok then
            service.failed = true
            for _, entry in ipairs(service.entries) do
                entry.state.available, entry.state.fresh = false, false
            end
            error(delay, 0)
        end
        return delay
    end
    service.task = task
    service.schedulerTasks = {
        { id = "service:armed", instance = task, critical = true },
    }
    return service
end

--- Read the next bounded batch of arm conditions.
---@param grant integer
---@param now integer
---@return integer delay
function armed:step(grant, now)
    local entries = self.entries
    local total = #entries
    if total == 0 then
        return INTERVAL
    end

    local cursor = self.cursor
    if cursor > total then
        cursor = 1
    end
    local remaining = self.remaining
    if remaining == nil then
        remaining = math.min(POLL_CAP, total)
    end
    local reads = math.min(grant, remaining)
    local control = self.runtime.byId.control
    for _ = 1, reads do
        local entry = entries[cursor]
        cursor = cursor % total + 1
        entry.read(control, entry, now)
    end
    self.cursor = cursor
    remaining = remaining - reads
    control.markScheduledUpdate(control, now)
    self.revision = self.revision + 1
    if remaining > 0 then
        self.remaining = remaining
        return 1
    end
    self.remaining = nil
    return INTERVAL
end

function armed:state(legacy)
    local name = self.condition ~= nil and self.condition or legacy or ""
    if self.views[name] then
        return self.views[name]
    end
    assert(
        valid(name),
        "Invalid Armed condition "
            .. tostring(name)
            .. ": use a position such as SF^ or a logical switch such as L01; replace legacy numeric arm sources in Model settings"
    )
    local control = self.runtime.byId.control
    assert(name == "" or control, "Arm switch requires control service")
    local reading, entry
    if name ~= "" then
        reading, entry = control:armSwitch(name)
        self.entries[#self.entries + 1] = entry
        self.count = self.count + 1
        self.task.want = math.min(POLL_CAP, #self.entries)
    end
    local metadata = {
        condition = name,
        key = name,
        configured = name ~= "",
        generation = self.generation,
        origin = self.condition ~= nil and "model" or name ~= "" and "legacy" or "none",
    }
    local revision = 0
    local lastValue, lastTime, lastAvailable, lastFresh
    -- Reliability is evaluated on access, so a stopped/failed poller cannot
    -- leave a permanently fresh arm reading behind.
    local state = setmetatable(metadata, {
        __index = function(_, key)
            if key == "value" then
                return reading and reading.value == true or false
            elseif key == "updatedAt" then
                return reading and reading.updatedAt or 0
            end
            local available = reading ~= nil and not self.failed and not control.failed and reading.available == true
            if key == "available" then
                return available
            end
            local now = self.env.getTime and self.env.getTime() or reading and reading.updatedAt
            local fresh = reading ~= nil
                and available
                and reading.fresh == true
                and type(reading.updatedAt) == "number"
                and type(now) == "number"
                and now >= reading.updatedAt
                and now - reading.updatedAt <= 100
            if key == "fresh" then
                return fresh == true
            elseif key == "revision" then
                local value, stamp = reading and reading.value, reading and reading.updatedAt
                if value ~= lastValue or stamp ~= lastTime or available ~= lastAvailable or fresh ~= lastFresh then
                    revision = revision + 1
                    lastValue, lastTime, lastAvailable, lastFresh = value, stamp, available, fresh
                end
                return revision
            elseif key == "status" then
                return name == "" and "unconfigured" or fresh and "ready" or "unavailable"
            end
        end,
    })
    local view = self.support.snapshot(state)
    self.views[name] = view
    return view
end

return armed
