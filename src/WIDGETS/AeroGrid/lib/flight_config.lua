-- SPDX-License-Identifier: GPL-2.0-only

local config = { RUNTIME_API = 1 }
local defaults = {
    motorSource = "ch3",
    motorReversed = false,
    smartDetection = false,
    minMotorPercent = 25,
    minFlightDuration = 30,
    disarmDuration = 10,
    announcements = false,
    history = true,
    flightSwitch = "",
}

function config.defaults()
    local result = {}
    for key, value in pairs(defaults) do
        result[key] = value
    end
    return result
end

function config.resolve(values)
    local result = config.defaults()
    for key in pairs(defaults) do
        if values and values[key] ~= nil then
            result[key] = values[key]
        end
    end
    local channel = type(result.motorSource) == "string" and string.match(result.motorSource, "^[cC][hH](%d+)$")
    if channel then
        result.motorSource = "ch" .. tostring(tonumber(channel))
    end
    return result
end

function config.validate(values)
    local errors = {}
    if type(values) ~= "table" then
        return { "Flight settings must be a mapping" }
    end
    local channel = type(values.motorSource) == "string" and string.match(values.motorSource, "^[cC][hH](%d+)$")
    if not channel or tonumber(channel) < 1 or tonumber(channel) > 32 then
        errors[#errors + 1] = "Motor channel must be CH1-CH32"
    end
    for _, key in ipairs({ "motorReversed", "smartDetection", "announcements", "history" }) do
        if type(values[key]) ~= "boolean" then
            errors[#errors + 1] = key .. " must be a boolean"
        end
    end
    for _, key in ipairs({ "minFlightDuration", "disarmDuration" }) do
        local value = values[key]
        if type(value) ~= "number" or value ~= value or value <= 0 or value > 3600 then
            errors[#errors + 1] = key .. " must be greater than 0 and at most 3600 seconds"
        end
    end
    local percent = values.minMotorPercent
    if type(percent) ~= "number" or percent ~= percent or percent < 0 or percent >= 100 then
        errors[#errors + 1] = "minMotorPercent must be in the range 0..<100"
    end
    local output = values.flightSwitch
    local number = type(output) == "string" and string.match(output, "^L(%d%d)$")
    if output ~= "" and (not number or tonumber(number) < 1 or tonumber(number) > 64) then
        errors[#errors + 1] = "Flight-active output must be blank or L01-L64"
    end
    return errors
end

function config.key(values)
    local parts = {}
    for _, key in ipairs({
        "motorSource",
        "motorReversed",
        "smartDetection",
        "minMotorPercent",
        "minFlightDuration",
        "disarmDuration",
        "announcements",
        "history",
        "flightSwitch",
    }) do
        local value = values[key]
        parts[#parts + 1] = type(value) == "number" and string.format("%.17g", value) or tostring(value)
    end
    return table.concat(parts, ":")
end

return config
