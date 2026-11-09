-- SPDX-License-Identifier: GPL-2.0-only

-- Compare preserved pre-optimization modules in build/ with the working tree.
local root = assert(...)
local function load(path)
    if path == "lib/history_service.lua" then
        return assert(loadfile(root .. "/build/history_service-baseline.lua"))()
    end
    return assert(loadfile(root .. "/src/WIDGETS/AeroGrid/" .. path))()
end
local Support = load("lib/services.lua")
local Control, Armed = load("lib/control_service.lua"), load("lib/armed_service.lua")
local History = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/history_service.lua"))()
local Original = load("lib/history_service.lua")
local Map = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/chart_mipmap.lua"))()
local OriginalMap = assert(loadfile(root .. "/build/chart_mipmap-baseline.lua"))()
local function equal(a, b, path)
    if type(a) == "table" then
        assert(type(b) == "table", path)
        for key, value in pairs(a) do
            equal(value, b[key], path .. "." .. tostring(key))
        end
        for key in pairs(b) do
            assert(a[key] ~= nil, path .. "." .. tostring(key))
        end
    else
        assert(a == b, path .. ": " .. tostring(a) .. " differs from " .. tostring(b))
    end
end
local function fixture(module, maps, options)
    local env = Support.environment({
        getSwitchIndex = function()
            return 1
        end,
        getSwitchValue = function()
            return true
        end,
        model = {},
    })
    local runtime = Support.runtime(env)
    runtime.byId.control = Control.new(env, Support)
    runtime.byId.armed = Armed.new(env, Support, runtime)
    local history = module.new(env, Support, runtime)
    options.armSwitch = "L01"
    local feed = history:subscribe("Q1", options)
    local consumers = {}
    if options.timeRange ~= "rolling" then
        for _, width in ipairs({ 226, 398, 399, 800 }) do
            consumers[#consumers + 1] = maps.attach(history, feed, width)
        end
    end
    return { history = history, entry = history.views[feed], runtime = runtime, consumers = consumers }
end
local function sample(f, index, at)
    local arm = f.runtime.byId.control.entries[1].state
    arm.available, arm.fresh, arm.value, arm.updatedAt = true, true, index % 211 < 200, at
    f.history:sample({
        name = "Q1",
        fresh = index % 97 ~= 7,
        updatedAt = at,
        kind = "number",
        value = index % 2 == 0 and 123456789 or (index * 37 % 103) / 100,
        precision = index % 307 < 150 and 0 or index % 307 < 200 and 1.5 or 2,
        precisionKnown = index % 307 > 20,
        unitText = "V",
    }, at)
    f.history:update(at)
end
local function compare(a, b)
    for _, key in ipairs({
        "state",
        "chunks",
        "resumeBits",
        "blocks",
        "lows",
        "highs",
        "bounds",
        "last",
        "anchorAt",
        "lastAt",
        "anchor",
        "endpoint",
        "low",
        "high",
        "segment",
        "filtered",
        "sampledAt",
        "gap",
    }) do
        equal(a.entry[key], b.entry[key], key)
    end
    equal(a.entry.session.state, b.entry.session.state, "session")
    for index, owner in ipairs(a.consumers) do
        equal(owner.map.levels, b.consumers[index].map.levels, "mipmap")
        equal(owner.map.at, b.consumers[index].map.at, "mipmap.at")
        equal(owner.map.revision, b.consumers[index].map.revision, "mipmap.revision")
    end
end
local cases, samples = 0, 0
for _, mode in ipairs({ "growing", "rolling" }) do
    for _, smoothing in ipairs({ "off", "light", "medium", "strong" }) do
        for _, precision in ipairs({ false, 0, 1, 2, 3 }) do
            local options = {
                timeRange = mode,
                windowSeconds = 30,
                smoothing = smoothing,
                precision = precision ~= false and precision or nil,
            }
            local a, b = fixture(History, Map, options), fixture(Original, OriginalMap, options)
            local at = 0
            for index = 0, 7200 do
                at = at + (index % 31 == 0 and 0 or index % 59 == 0 and 401 or 1)
                sample(a, index, at)
                sample(b, index, at)
                if index % 500 == 0 then
                    compare(a, b)
                end
                samples = samples + 1
            end
            compare(a, b)
            for _, f in ipairs({ a, b }) do
                local index = 1
                repeat
                    index = f.history:resetSession(at, index)
                until not index
            end
            sample(a, 1, at + 10)
            sample(b, 1, at + 10)
            compare(a, b)
            cases = cases + 1
        end
    end
end
print(
    "Telemetry equivalence: "
        .. cases
        .. " cases, "
        .. samples
        .. " samples; exact history bytes, summaries and mipmaps"
)
