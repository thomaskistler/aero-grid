-- SPDX-License-Identifier: GPL-2.0-only
-- Native runner for the scheduler framework measurements (tools/audit-scheduler.py
-- --framework). Copied only into an isolated simulator SD image. `__count` and
-- `__pause` come from tools/audit-native.cpp.
--
-- It measures the framework's own cost with stub tasks and runs every case file
-- named in the config through the real task step, once, in the first refresh
-- callback (the native counter does not enforce the callback limit).

local config = assert(loadScript("/WIDGETS/AeroGrid/audit/config.lua"))()
local costs = assert(loadScript("/WIDGETS/AeroGrid/audit/costs.lua"))(nil, true)
local scheduler = costs:bind("lib/scheduler.lua", assert(loadScript("/WIDGETS/AeroGrid/lib/scheduler.lua"))())
local overhead = assert(loadScript("/WIDGETS/AeroGrid/audit/scheduler_overhead.lua"))()
local measure = assert(loadScript("/WIDGETS/AeroGrid/audit/scheduler_measure.lua"))()
local mixes = assert(loadScript("/WIDGETS/AeroGrid/audit/scheduler_mixes.lua"))()
local paths = assert(loadScript("/WIDGETS/AeroGrid/audit/scheduler_path_witness.lua"))()

local finished = false

local function json(value)
    local kind = type(value)
    if kind == "number" then
        return value == math.floor(value) and string.format("%d", value) or string.format("%.4f", value)
    elseif kind == "string" then
        return '"'
            .. string.gsub(value, '[%c"\\]', function(char)
                return string.format("\\u%04x", string.byte(char))
            end)
            .. '"'
    elseif kind == "boolean" then
        return tostring(value)
    elseif kind == "table" then
        local size, parts = 0, {}
        for _ in pairs(value) do
            size = size + 1
        end
        if size == #value then
            for index, item in ipairs(value) do
                parts[index] = json(item)
            end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for key in pairs(value) do
            keys[#keys + 1] = tostring(key)
        end
        table.sort(keys)
        for _, key in ipairs(keys) do
            parts[#parts + 1] = json(key) .. ":" .. json(value[tonumber(key) or key])
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "null"
end

local function write(path, text)
    local file = assert(io.open(path, "w"))
    io.write(file, text)
    io.close(file)
end

local function measureAll()
    local results = { overhead = overhead.measure(scheduler, __count, __pause, mixes), cases = {} }
    for _, item in ipairs(overhead.measurePaths(scheduler, __count, __pause, paths)) do
        results.overhead.rows[#results.overhead.rows + 1] = item
    end
    results.verdict = overhead.verdict(results.overhead)
    results.charges = {
        fixed = scheduler.FIXED_COST,
        examine = scheduler.EXAMINE_COST,
        run = scheduler.RUN_COST,
    }
    for _, name in ipairs(config.cases) do
        local case = measure.open(
            assert(loadScript("/WIDGETS/AeroGrid/audit/cases/" .. name .. ".lua"))(),
            function(relative, ...)
                local path = string.sub(relative, 1, 9) == "@support/" and "audit/" .. string.sub(relative, 10)
                    or relative
                return costs:bind(path, assert(loadScript("/WIDGETS/AeroGrid/" .. path))(...))
            end
        )
        if config.focused and name == "link-status-panel" then
            local groups, selected = {}, {}
            for _, item in ipairs(case.cases) do
                local key = item.stage .. ":" .. item.grant
                local group = groups[key] or {}
                groups[key] = group
                group[#group + 1] = item
            end
            local keys = {}
            for key in pairs(groups) do keys[#keys + 1] = key end
            table.sort(keys)
            for _, key in ipairs(keys) do
                local group = groups[key]
                local seen = {}
                for _, index in ipairs({ 1, (#group + 1) // 2, #group }) do
                    if not seen[index] then
                        selected[#selected + 1], seen[index] = group[index], true
                    end
                end
            end
            case.cases = selected
        end
        results.cases[case.id] = measure.report(case, __count, __pause, scheduler)
    end
    return results
end

return function()
    if finished or not __count then
        return
    end
    finished = true
    local ok, results = pcall(measureAll)
    if ok then
        write("/audit-results.json", json(results))
        write("/audit-ready.txt", "done")
    else
        write("/audit-error.txt", tostring(results) .. "\n")
        write("/audit-ready.txt", "failed")
    end
end
