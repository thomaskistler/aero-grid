-- SPDX-License-Identifier: GPL-2.0-only

--- Saved model Armed takes precedence over retained panel switches.
local armed = { RUNTIME_API = 1 }
armed.__index = armed

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
    return setmetatable({
        id = "armed",
        interval = 20,
        due = 0,
        count = 0,
        revision = 0,
        env = env,
        support = support,
        runtime = runtime,
        condition = runtime.modelArmed,
        generation = runtime.armGeneration or 0,
        views = {},
    }, armed)
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
    local reading = name ~= "" and control:switch(name) or nil
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
            local available = reading ~= nil and not control.failed and reading.available == true
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
