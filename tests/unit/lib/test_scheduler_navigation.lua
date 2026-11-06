-- SPDX-License-Identifier: GPL-2.0-only

-- Navigation migration parity and bounded-grant checks.
local root = (... and ... ~= "" and ...) or "."
local hostIo = io

local parity = assert(loadfile(root .. "/tests/support/scheduler_parity.lua"))(root)
local scheduler = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/scheduler.lua"))()
local services = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/services.lua"))()
local navigationService = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/navigation_service.lua"))()
local equal = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual

local CALLBACKS, TAIL = 300, 100
local DECL = navigationService.decl

local function digest(text)
    local hash = 5381
    for position = 1, #text do
        hash = (hash * 33 + string.byte(text, position)) % 16777213
    end
    return string.format("%06x", hash)
end

local function stateText(state)
    return table.concat({
        state.source,
        tostring(state.known),
        tostring(state.fix),
        tostring(state.home),
        tostring(state.homeStatus),
        tostring(state.state),
        tostring(state.latitude),
        tostring(state.longitude),
        tostring(state.pilotLatitude),
        tostring(state.pilotLongitude),
        tostring(state.distance),
        tostring(state.distanceUnit),
        tostring(state.bearing),
        tostring(state.age),
    }, ":")
end

local function recordTrace()
    local trace, now = {}, 0
    for index = 1, CALLBACKS + TAIL do
        now = now + 3 + index % 5 + (index % 53 == 0 and 80 or 0)
        local sources, arms = {}, {}
        local sampleIndex = math.min(index, CALLBACKS)
        for source = 1, 4 do
            local sample = index > CALLBACKS and 0 or (sampleIndex // 35 + source) % 4
            sources["GPS" .. tostring(source)] = {
                known = true,
                available = not (sample == 3 and sampleIndex % 2 == 0),
                fresh = sample ~= 3,
                stale = sample == 2,
                age = (sampleIndex % 9) / 10,
                updatedAt = now,
                raw = sample == 3 and nil
                    or {
                        lat = 47 + source / 1000 + (sampleIndex % 8) / 10000,
                        lon = 8 + source / 1000,
                        ["pilot-lat"] = 46.5,
                        ["pilot-lon"] = 7.5,
                        delay = sampleIndex % 4,
                    },
            }
            arms["SF" .. tostring(source)] = index > CALLBACKS
        end
        trace[index] = {
            now = now,
            index = index,
            kind = index % 7 == 0 and "background" or "steady",
            sources = sources,
            arms = arms,
        }
    end
    return trace
end

local trace = recordTrace()

local function adapter()
    return {
        id = "service:navigation",
        decl = DECL,
        new = function()
            local readings, switches = {}, {}
            local runtime = services.runtime(services.environment({}))
            runtime.byId.telemetry = {
                subscribe = function(_, name)
                    if not readings[name] then
                        readings[name] = {}
                    end
                    return readings[name]
                end,
            }
            runtime.byId.armed = {
                state = function(_, name)
                    if not switches[name] then
                        switches[name] = {
                            key = name,
                            available = true,
                            fresh = true,
                            value = false,
                            updatedAt = 0,
                        }
                    end
                    return switches[name]
                end,
            }
            local service = navigationService.new(runtime.env, services, runtime)
            for source = 1, 4 do
                local name = "GPS" .. tostring(source)
                if source == 1 then
                    service:subscribe(name)
                else
                    service:subscribe(name, "SF" .. tostring(source), "first-arm")
                end
            end
            service.tickElapsed = scheduler.elapsed
            service.due = 0
            service.readings, service.switches = readings, switches
            return service
        end,
        feed = function(task, callback)
            for source, reading in pairs(callback.sources) do
                local target = task.readings[source]
                for key in pairs(target) do
                    target[key] = nil
                end
                for key, value in pairs(reading) do
                    target[key] = value
                end
            end
            for switch, value in pairs(callback.arms) do
                local arm = task.switches[switch]
                if arm then
                    arm.value, arm.updatedAt = value, callback.now
                end
            end
        end,
        old = function(task, now)
            navigationService.update(task, now)
        end,
        snapshot = function(task)
            local values = {}
            for _, entry in ipairs(task.entries) do
                values[#values + 1] = stateText(entry.state)
            end
            local homes = {}
            for key, capture in pairs(task.homes) do
                homes[#homes + 1] = table.concat({
                    key,
                    tostring(capture.latitude),
                    tostring(capture.longitude),
                    tostring(capture.attempted),
                }, ":")
            end
            table.sort(homes)
            return digest(table.concat({
                table.concat({
                    task.revision,
                    task.due,
                    task.count,
                    task.cursor,
                }, ":"),
                table.concat(values, "|"),
                table.concat(homes, "|"),
            }, " "))
        end,
        published = function(task)
            local values = {}
            for _, entry in ipairs(task.entries) do
                values[#values + 1] = stateText(entry.state)
            end
            return table.concat(values, "|")
        end,
    }
end

local goldenPath = root .. "/tests/fixtures/scheduler-navigation-golden.txt"
local writing = os.getenv("AEROGRID_WRITE_NAVIGATION_GOLDEN")
local goldenName = math.maxinteger == 2147483647 and "navigation32" or "navigation64"
if writing then
    local run = parity.golden(adapter(), trace)
    local lines = {}
    local existing = hostIo.open(goldenPath, "r")
    if existing then
        for line in existing:lines() do
            local name = string.match(line, "^(%w+) ")
            if name == "navigation32" or name == "navigation64" then
                if name ~= goldenName then
                    lines[#lines + 1] = line
                end
            end
        end
        existing:close()
    end
    lines[#lines + 1] = goldenName .. " " .. table.concat(run.snapshots, " ")
    local file = assert(hostIo.open(goldenPath, "w"))
    file:write(table.concat(lines, "\n") .. "\n")
    file:close()
    return
end

local golden = {}
do
    local file = assert(hostIo.open(goldenPath, "r"))
    for line in file:lines() do
        local name, rest = string.match(line, "^(%w+) (.*)$")
        local snapshots = {}
        for hash in string.gmatch(rest, "%x+") do
            snapshots[#snapshots + 1] = hash
        end
        golden[name] = { snapshots = snapshots }
    end
    file:close()
end

local taskAdapter = adapter()
local expected = assert(golden[goldenName], "navigation golden trace is present for this Lua integer width")
equal(#expected.snapshots, #trace, "golden covers the complete trace")
local extraction = parity.extraction(taskAdapter, trace)
parity.assertSame(expected, extraction, "navigation extraction")
assert(#extraction.schedule > 20, "legacy navigation schedule has releases")
parity.assertSame(expected, parity.replay(taskAdapter, trace, extraction.schedule), "navigation replay")

local ample = parity.budgeted(taskAdapter, trace)
parity.assertSame(expected, ample, "navigation ample budget")
equal(ample.task.revision, extraction.task.revision, "ample budget preserves update revisions")

local tight = parity.budgeted(taskAdapter, trace, {
    used = function(callback)
        if callback.index % 7 == 0 then
            local stage = DECL.stages.run
            local oneUnit = stage.fixed + stage.perUnit + scheduler.EXAMINE_COST + scheduler.RUN_COST
            return scheduler.CEILING
                - scheduler.MARGIN
                - 1250
                - scheduler.FIXED_COST
                - oneUnit
                - math.max(1, stage.perUnit // 2)
        end
        return callback.index % 7 == 1 and scheduler.CEILING
            - scheduler.MARGIN
            - 1250
            - scheduler.FIXED_COST
            - 10
            or 0
    end,
})
local timing = parity.timing(extraction, tight, trace[#trace].now)
assert(timing.late > 0, "tight budget delays some releases")
assert(timing.late <= 180, "navigation release lateness remains bounded: " .. timing.late)
assert(timing.budgetedGap <= timing.legacyGap + 180, "navigation polling gaps remain bounded")
equal(taskAdapter.published(tight.task), taskAdapter.published(extraction.task), "tight budget converges to legacy values")
local partial = false
for _, release in ipairs(tight.schedule) do
    partial = partial or release.grant < DECL.stages.run.maxUnits
end
assert(partial, "tight budget exercises partial navigation grants")

do
    local task = taskAdapter.new()
    equal(task.decl.class, "normal")
    equal(task.decl.stages.run.maxUnits, 2)
    equal(scheduler.check(task.decl), nil, "navigation declaration is usable")

    local runtime = services.runtime(services.environment({}))
    runtime.host = {}
    runtime.byId.telemetry = {
        subscribe = function()
            return { known = true, available = true, raw = { lat = 47, lon = 8 } }
        end,
    }
    local hostOwned = navigationService.new(runtime.env, services, runtime)
    hostOwned:subscribe("GPS")
    equal(hostOwned.update, nil, "the host-owned service has no legacy update entry point")

    local s = scheduler.new({ steady = 1250, background = 1130 })
    local added, reason = s:add({ id = "service:navigation", decl = task.decl, instance = hostOwned, due = trace[1].now })
    assert(added, reason)
    s:run("steady", trace[1].now, scheduler.CEILING)
    equal(hostOwned.revision, 0, "a no-room callback does not run navigation work")
    assert(not s:takeErrors(), "no room is not a navigation task failure")
end

print("Scheduler navigation task parity passed")
