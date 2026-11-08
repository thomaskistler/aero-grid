-- SPDX-License-Identifier: GPL-2.0-only
-- Synthetic service inputs for the scheduler audit. Installed only in the
-- isolated simulator copy. Every numeric reading swings on each poll so panels
-- and recorders take their changed-value path, which costs more than the
-- unchanged path.

local config = assert(loadScript("/WIDGETS/AeroGrid/audit/config.lua"))()
local overrides = {}
if config.baseInputs then
    overrides = assert(loadScript("/WIDGETS/AeroGrid/audit/base-inputs.lua"))()
end

local calls = 0

local function swing(value, salt)
    local kind = type(value)
    if kind == "number" then
        local wave = math.sin(getTime() / (11 + salt % 5) + salt)
        if value == 0 then
            return wave * 40
        end
        return value * (1 + config.swing * wave)
    elseif kind == "table" then
        local copy = {}
        for key, item in pairs(value) do
            copy[key] = type(item) == "number" and swing(item, salt + 1) or item
        end
        return copy
    end
    return value
end

local function wrapReader(name, positive)
    local base = overrides[name] or _G[name]
    if type(base) ~= "function" then
        return nil
    end
    return function(...)
        calls = calls + 1
        local value = swing(base(...), calls)
        if positive and type(value) == "number" then
            return math.abs(value)
        end
        return value
    end
end

local env = {}
for key, value in pairs(overrides) do
    env[key] = value
end
env.getValue = wrapReader("getValue")
env.getOutputValue = wrapReader("getOutputValue")
env.getRSSI = wrapReader("getRSSI", true)

if config.toggleLink then
    for _, name in ipairs({ "getValue", "getRSSI" }) do
        local reader = env[name]
        env[name] = function(...)
            if math.floor(getTime() / 400) % 2 == 1 then
                return 0
            end
            return reader(...)
        end
    end
end

local sourceValue = overrides.getSourceValue or _G.getSourceValue
if type(sourceValue) == "function" then
    env.getSourceValue = function(...)
        if config.toggleLink and math.floor(getTime() / 400) % 2 == 1 then
            return 0, true, false
        end
        calls = calls + 1
        local value, current, fresh = sourceValue(...)
        return swing(value, calls), current, fresh
    end
end

if config.toggleSwitches then
    local base = overrides.getSwitchValue or getSwitchValue
    env.getSwitchValue = function(index)
        local value = base(index)
        if type(value) == "boolean" then
            return (math.floor(getTime() / (200 + index)) + index) % 2 == 0
        end
        return value
    end
end

if string.match(config.scenario, "^aircraft%-link%-recovery") then
    for _, name in ipairs({ "getValue", "getRSSI", "getSourceValue" }) do
        local reader = env[name]
        if reader then
            env[name] = function(...)
                if _G.AUDIT_LINK_OFF then return 0 end
                return reader(...)
            end
        end
    end
end

return env
