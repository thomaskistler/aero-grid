-- SPDX-License-Identifier: GPL-2.0-only

local count = { MAX = 16777215 }

function count.valid(value)
    return type(value) == "number" and value >= 0 and value <= count.MAX and value % 1 == 0
end

function count.external(env, combined)
    local read = assert(env.getGlobalVariable, "External flight count requires global-variable APIs")
    local function component(index)
        local value = read(index, 0)
        local details = env.getGlobalVariableDetails and env.getGlobalVariableDetails(index)
        assert(
            count.valid(value) and value <= 999 and details and details.prec == 0,
            "External flight count requires integer GV" .. (index + 1) .. " FM0 in 0..999, with precision 0"
        )
        return math.floor(value)
    end
    local low = component(8)
    return combined and component(7) * 1000 + low or low
end

local function scalar(value)
    value = string.match(value, "^%s*(.-)%s*$")
    local quote = string.sub(value, 1, 1)
    if quote == '"' or quote == "'" then
        assert(string.sub(value, -1) == quote, "Malformed Flights widget option")
        return string.sub(value, 2, -2)
    end
    if value == "true" then
        return true
    elseif value == "false" then
        return false
    end
    return tonumber(value) or value
end

local function finishWidget(job)
    local widget = job.widget
    if not widget then
        return
    end
    job.widgets[#job.widgets + 1] = widget
    job.widget, job.option = nil, nil
end

-- Only inspect saved screen/top-bar widget options, not the rest of EdgeTX YAML.
local function line(job, text)
    local spaces, key, value = string.match(text, "^( *)([%w_]+):%s*(.-)%s*$")
    if not spaces then
        assert(not job.widget or not string.find(text, "%S"), "Malformed Flights widget configuration")
        return
    end
    local indent = #spaces
    if job.widget and indent < job.widgetIndent then
        finishWidget(job)
    end
    if indent == 0 then
        job.section = key
        job.modelSection = job.modelSection or key == "header" or key == "screenData" or key == "topbarData"
    end
    if key == "widgetName" and (job.section == "screenData" or job.section == "topbarData") then
        if scalar(value) == "Flights" then
            assert(not job.widget, "Malformed Flights widget placement")
            job.widget, job.widgetIndent = {}, indent
        end
    elseif job.widget then
        if key == "options" then
            job.optionsIndent = indent
        elseif job.optionsIndent and indent == job.optionsIndent + 3 and tonumber(key) then
            job.option = {}
            job.widget[tonumber(key)] = job.option
        elseif job.optionsIndent and tonumber(key) and value == "" then
            -- Companion/model files can also use two-space indentation.
            job.option = {}
            job.widget[tonumber(key)] = job.option
        elseif job.option and key == "type" then
            job.option.kind = scalar(value)
        elseif
            job.option and (key == "unsignedValue" or key == "signedValue" or key == "boolValue" or key == "source")
        then
            assert(job.option.value == nil, "Duplicate Flights widget option")
            job.option.value = scalar(value)
        end
    end
end

function count.begin(operations, filename, legacy, env)
    assert(type(filename) == "string" and string.match(filename, "^[^/\\%z]+$"), "Invalid model filename")
    return {
        operations = operations,
        filename = "/MODELS/" .. filename,
        legacy = legacy,
        env = env,
        widgets = {},
        buffer = "",
        stage = "open",
    }
end

local function option(widget, index, kind, other)
    local entry = widget[index]
    assert(
        entry and (entry.kind == kind or other ~= nil and entry.kind == other) and entry.value ~= nil,
        "Unrecognized Flights options; review its configuration"
    )
    return entry.value
end

-- EdgeTX saves the switch option through its unsigned union member, so negative switches wrap.
local function switchOption(widget)
    local index = option(widget, 1, "Signed", "Unsigned")
    if type(index) == "number" and index > 2147483647 then
        index = index - 4294967296
    end
    return index
end

-- EdgeTX saves channel sources as zero-based ch(N); older files used CHn.
local function motorChannel(source)
    if type(source) ~= "string" then
        return nil
    end
    local saved = string.match(source, "^ch%((%d+)%)$")
    if saved then
        return tonumber(saved) + 1
    end
    local named = string.match(source, "^CH(%d+)$")
    return named and tonumber(named)
end

local function switchName(env, index)
    for letter = string.byte("A"), string.byte("Z") do
        for _, suffix in ipairs({ "^", "-", "v" }) do
            local native = suffix == "^" and env.charUp or suffix == "v" and env.charDown or "-"
            local name = "S" .. string.char(letter)
            if native and env.getSwitchIndex and env.getSwitchIndex(name .. native) == index then
                return name .. suffix
            end
        end
    end
    for number = 1, 64 do
        local name = string.format("L%02d", number)
        local resolved = env.getSwitchIndex and env.getSwitchIndex(name)
        if resolved and resolved ~= 0 and resolved == math.abs(index) then
            return index < 0 and "!" .. name or name
        end
    end
end

local function settings(job, widget, modern)
    local values, arm = {}, nil
    local trigger = modern and option(widget, 0, "Unsigned") or 1
    if trigger ~= 1 and trigger ~= 2 then
        return nil, nil, "Flights count imported; choose AeroGrid arming and detection settings for this trigger type."
    end
    local motor = option(widget, modern and 2 or 1, "Source")
    local channel = motorChannel(motor)
    if channel and channel >= 1 and channel <= 32 then
        values.motorSource = "ch" .. channel
    end
    local duration = option(widget, modern and 4 or 2, "Signed", "Unsigned")
    if type(duration) == "number" and duration ~= 0 and math.abs(duration) <= 3600 then
        values.minFlightDuration = math.abs(duration)
    end
    values.requireReceiver = trigger == 1
    if modern then
        local index = switchOption(widget)
        if type(index) == "number" and index ~= 0 then
            arm = switchName(job.env, index)
        end
    else
        local source = option(widget, 0, "Source")
        if type(source) == "string" and string.match(source, "^S[A-Z]$") then
            arm = source .. "^"
        end
    end
    if not arm or not values.motorSource or not values.minFlightDuration then
        return nil, nil, "Flights count imported; review AeroGrid arming, motor channel and detection settings."
    end
    return values,
        arm,
        "Flights count and compatible settings imported; review Model settings. End detection uses AeroGrid's disarm window."
end

function count.step(job)
    local ops = job.operations
    if job.stage == "open" then
        local info = ops.stat(job.filename)
        if not info then
            job.stage = "resolve"
        else
            assert(type(info.size) == "number" and info.size > 0, "Cannot inspect model's Flights configuration")
            job.handle = assert(ops.open(job.filename, "r"))
            job.found = true
            job.remaining, job.stage = info.size, "read"
        end
        return false
    elseif job.stage == "read" then
        if job.remaining > 0 and not string.find(job.buffer, "\n", 1, true) then
            local size = math.min(1024, job.remaining)
            local text = ops.read(job.handle, size)
            if type(text) ~= "string" or #text ~= size then
                ops.close(job.handle)
                job.handle = nil
                error("Cannot read model's Flights configuration")
            end
            job.buffer, job.remaining = job.buffer .. text, job.remaining - size
            assert(#job.buffer <= 4096, "Model configuration line too long")
        end
        local processed = 0
        while processed < 24 do
            local stop = string.find(job.buffer, "\n", 1, true)
            if not stop then
                break
            end
            line(job, string.gsub(string.sub(job.buffer, 1, stop - 1), "\r$", ""))
            job.buffer = string.sub(job.buffer, stop + 1)
            processed = processed + 1
        end
        if job.remaining == 0 and not string.find(job.buffer, "\n", 1, true) then
            if job.buffer ~= "" then
                line(job, job.buffer)
            end
            ops.close(job.handle)
            job.handle = nil
            finishWidget(job)
            job.stage = "resolve"
        end
        return false
    end
    assert(not job.found or job.modelSection, "Cannot recognize model's Flights configuration")
    local widget = job.widgets[1]
    if not widget then
        return true, { count = job.legacy and count.external(job.env, false) or 0 }
    end
    local modern = widget[0] and widget[0].kind == "Unsigned"
    local combined = false
    if modern then
        local trigger = option(widget, 0, "Unsigned")
        assert(type(trigger) == "number" and trigger >= 1 and trigger <= 7, "Unrecognized Flights trigger")
        switchOption(widget)
        option(widget, 2, "Source")
        if widget[7] then
            local enabled = option(widget, 7, "Bool")
            assert(enabled == true or enabled == false or enabled == 0 or enabled == 1, "Invalid Flights GV8 option")
            combined = enabled == true or enabled == 1
        end
    else
        option(widget, 0, "Source")
        option(widget, 1, "Source")
        option(widget, 2, "Signed")
    end
    for index = 2, #job.widgets do
        for key = 0, 7 do
            local a, b = widget[key], job.widgets[index][key]
            assert(
                (not a and not b) or a and b and a.kind == b.kind and a.value == b.value,
                "Conflicting Flights widgets; keep one configuration before importing"
            )
        end
    end
    local result = { count = count.external(job.env, combined) }
    if not job.legacy then
        local ok, flight, arm, notice = pcall(settings, job, widget, modern)
        if ok then
            result.flight, result.armed, result.notice = flight, arm, notice
        else
            result.notice = "Flights count imported; review Model settings: " .. tostring(flight)
        end
    end
    return true, result
end

return count
