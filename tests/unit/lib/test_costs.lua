-- SPDX-License-Identifier: GPL-2.0-only

-- Every shipped instruction estimate comes from lib/instruction_snapshot.lua:
-- sources carry none, every declaration is bound, and every estimate is used.

local root = ...
local base = root .. "/src/WIDGETS/AeroGrid/"
local loadModule = assert(loadfile(root .. "/tests/support/module_loader.lua"))(root)
local costsModule = loadModule("lib/costs.lua")
local snapshot = assert(loadfile(base .. "lib/instruction_snapshot.lua"))()

local function listing(directory)
    local path = root .. "/build/costs-listing.txt"
    os.execute("mkdir -p '" .. root .. "/build' && ls '" .. base .. directory .. "' > '" .. path .. "'")
    local file = assert(io.open(path, "r"))
    local names = {}
    for name in file:lines() do
        if string.find(name, "%.lua$") then
            names[#names + 1] = directory .. "/" .. name
        end
    end
    file:close()
    os.remove(path)
    assert(#names > 0, "no modules in " .. directory)
    return names
end

local function read(relative)
    local file = assert(io.open(base .. relative, "r"))
    local text = file:read("a")
    file:close()
    return text
end

local sources = listing("lib")
for _, relative in ipairs(listing("panels")) do
    sources[#sources + 1] = relative
end
sources[#sources + 1] = "main.lua"

-- Sources hold structure only; the numbers live in the snapshot.
for _, relative in ipairs(sources) do
    if relative ~= "lib/instruction_snapshot.lua" then
        local text = read(relative)
        for _, pattern in ipairs({ "fixed = %d", "perUnit = %d", "bound = %d", "_BOUNDS = %d", "BOUNDS = {%s*%a" }) do
            assert(not string.find(text, pattern), relative .. " declares an estimate (" .. pattern .. ")")
        end
    end
end

-- Record every estimate that binding reads.
local used = {}
local function track(value, path)
    if type(value) ~= "table" then
        return value
    end
    local proxy = {}
    return setmetatable(proxy, {
        __index = function(_, key)
            local child = path .. "." .. tostring(key)
            used[child] = true
            return track(value[key], child)
        end,
        __pairs = function()
            return function(_, key)
                local nextKey, nextValue = next(value, key)
                if nextKey ~= nil then
                    local child = path .. "." .. tostring(nextKey)
                    used[child] = true
                    return nextKey, track(nextValue, child)
                end
            end, proxy, nil
        end,
    })
end
local estimates = snapshot("estimates")
local tracked = costsModule.new(function()
    return { tasks = track(estimates.tasks, "tasks"), bounds = track(estimates.bounds, "bounds") }
end)

local panels = 0
for _, relative in ipairs(sources) do
    local costed = string.find(relative, "^panels/") or string.find(read(relative), "bindCosts", 1, true)
    if costed and relative ~= "lib/costs.lua" and relative ~= "main.lua" then
        local module = loadModule(relative)
        tracked:bind(relative, module)
        local decl = rawget(module, "decl")
        if string.find(relative, "^panels/") then
            panels = panels + 1
            if decl then
                assert(
                    estimates.tasks["panel." .. string.match(relative, "^panels/(.+)%.lua$")],
                    relative .. " has a task declaration without snapshot estimates"
                )
            end
        end
    end
end
assert(panels > 10, "panels were not checked")

-- main.lua reads its own bounds at run time.
for key in pairs(estimates.bounds.main) do
    assert(string.find(read("main.lua"), 'mainBound(context, "' .. key .. '")', 1, true), "main." .. key .. " is unused")
    used["bounds.main." .. key] = true
end

for section, groups in pairs(estimates) do
    for group, entries in pairs(groups) do
        for key in pairs(entries) do
            local path = section .. "." .. group .. "." .. key
            assert(used[path], path .. " is not bound to any declaration")
        end
    end
end

-- A missing estimate fails rather than defaulting.
local empty = costsModule.new(function()
    return { tasks = {}, bounds = { ["panel-reflow"] = {} } }
end)
local ok, message = pcall(empty.stages, empty, "service", { stages = { run = { maxUnits = 1 } } })
assert(not ok and string.find(message, "tasks.service", 1, true), "a missing task estimate was accepted")
ok, message = pcall(empty.bound, empty, "group", "key")
assert(not ok and string.find(message, "bounds.group", 1, true), "a missing bound was accepted")
ok = pcall(empty.panel, empty, "metric", { decl = { stages = { run = { maxUnits = 1 } } } })
assert(not ok, "a panel without estimates was accepted")

-- A panel not shipped with AeroGrid may carry complete estimates of its own.
local external = { decl = { stages = { run = { fixed = 0, perUnit = 1000, maxUnits = 1 } } } }
empty:panel("external", external)
assert(external.decl.stages.run.perUnit == 1000)

print("Instruction estimates come from the snapshot")
