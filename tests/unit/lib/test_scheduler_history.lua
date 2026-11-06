-- SPDX-License-Identifier: GPL-2.0-only

-- History service migration parity, bounded releases, and no-room behavior.
local root = (... and ... ~= "" and ...) or "."
local parity = assert(loadfile(root .. "/tests/support/scheduler_parity.lua"))(root)
local scheduler = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/scheduler.lua"))()
local services = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/services.lua"))()
local historyService = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/history_service.lua"))()
local equal = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual

local CALLBACKS, TAIL = 240, 80
local DECL = historyService.decl

local function digest(text)
    local hash = 5381
    for position = 1, #text do
        hash = (hash * 33 + string.byte(text, position)) % 16777213
    end
    return string.format("%06x", hash)
end

local function stateText(service, includeSchedule)
    local values = {}
    for _, session in ipairs(service.sessions) do
        local state = session.state
        values[#values + 1] = table.concat({
            session.name,
            tostring(state.available),
            tostring(state.recording),
            tostring(state.elapsed),
            tostring(state.segment),
            tostring(state.stoppedAt),
            tostring(state.revision),
            tostring(state.flightRevision),
            tostring(state.flightActive),
            tostring(state.flightLost),
            tostring(state.flightFirst),
            tostring(state.flightLast),
            tostring(state.armRevision),
            tostring(state.armFirst),
            tostring(state.armLast),
            tostring(state.resumeRevision),
            tostring(state.resumeFirst),
            tostring(state.resumeLast),
        }, ":")
    end
    for _, entry in ipairs(service.entries) do
        local state = entry.state
        local points = {}
        for index = state.first, state.last do
            local at, value, broken, resumed = service:point(entry.view, index)
            points[#points + 1] =
                table.concat({ tostring(at), tostring(value), tostring(broken), tostring(resumed) }, ":")
        end
        values[#values + 1] = table.concat({
            state.name,
            tostring(state.available),
            tostring(state.stale),
            tostring(state.value),
            tostring(state.min),
            tostring(state.max),
            tostring(state.first),
            tostring(state.last),
            tostring(state.count),
            tostring(state.window),
            tostring(state.full),
            tostring(state.epsilon),
            tostring(state.revision),
            tostring(state.plotRevision),
            table.concat(points, "|"),
        }, ":")
    end
    return digest(table.concat({
        includeSchedule
                and table.concat({ service.revision, service.due, service.count, service.cursor }, ":")
            or "",
        table.concat(values, ";"),
    }, " "))
end

local function adapter()
    return {
        id = "service:history",
        decl = DECL,
        new = function()
            local arms, readings = {}, {}
            local runtime = services.runtime(services.environment({}))
            runtime.byId.armed = {
                state = function(_, name)
                    if not arms[name] then
                        arms[name] = {
                            key = name,
                            configured = name ~= "",
                            available = true,
                            fresh = true,
                            value = false,
                            updatedAt = 0,
                        }
                    end
                    return arms[name]
                end,
            }
            runtime.byId.telemetry = {
                subscribe = function(_, name)
                    readings[name] = readings[name] or {}
                    return readings[name]
                end,
                observe = function() end,
            }
            local service = historyService.new(runtime.env, services, runtime)
            service:subscribe("V", {
                armSwitch = "L01",
                timeRange = "rolling",
                windowSeconds = 30,
                precision = 2,
            })
            service:subscribe("A", {
                armSwitch = "L01",
                timeRange = "rolling",
                windowSeconds = 30,
                precision = 1,
            })
            service:subscribe("V", {
                armSwitch = "L02",
                timeRange = "rolling",
                windowSeconds = 30,
                precision = 2,
            })
            service.tickElapsed = scheduler.elapsed
            service.arms, service.readings = arms, readings
            return service
        end,
        feed = function(service, callback)
            if callback.index == 170 then
                local nextItem = 1
                repeat
                    nextItem = service:resetSession(callback.now, nextItem)
                until not nextItem
            end
            for name, arm in pairs(service.arms) do
                local value = callback.arms[name]
                arm.value = value == true
                arm.fresh = value ~= nil
                arm.available = value ~= nil
                arm.updatedAt = callback.now
            end
            for _, name in ipairs({ "V", "A" }) do
                local value = callback.values[name]
                local reading = service.readings[name]
                reading.name = name
                reading.value = value
                reading.kind = "number"
                reading.fresh = value ~= nil
                reading.updatedAt = callback.now
                reading.precision = name == "V" and 2 or 1
                reading.precisionKnown = true
                reading.unitText = "V"
                service:sample(reading, callback.now)
            end
        end,
        old = function(service, now)
            historyService.update(service, now)
        end,
        snapshot = function(service)
            return stateText(service, true)
        end,
        published = function(service)
            return stateText(service, false)
        end,
    }
end

local trace, now = {}, 1000
for index = 1, CALLBACKS + TAIL do
    now = now + 3 + index % 5 + (index % 43 == 0 and 80 or 0)
    local phase = math.min(index, CALLBACKS)
    local values = {
        V = math.sin(phase / 13) * 10 + phase / 100,
        A = math.cos(phase / 11) * 4,
    }
    if phase % 19 == 0 then
        values.V = nil
    end
    if phase % 23 == 0 then
        values.A = nil
    end
    trace[index] = {
        now = now,
        index = index,
        kind = index % 7 == 0 and "background" or "steady",
        arms = {
            L01 = phase % 61 < 39 and true or false,
            L02 = phase % 47 < 26 and true or false,
        },
        values = values,
    }
end

local taskAdapter = adapter()
local golden = parity.golden(taskAdapter, trace)
local extraction = parity.extraction(taskAdapter, trace)
parity.assertSame(golden, extraction, "history extraction")
assert(#extraction.schedule > 20, "legacy history has scheduled releases")
parity.assertSame(golden, parity.replay(taskAdapter, trace, extraction.schedule), "history replay")

local ample = parity.budgeted(taskAdapter, trace)
parity.assertSame(golden, ample, "history ample budget")
equal(ample.task.revision, extraction.task.revision, "ample budget preserves history releases")

local tight = parity.budgeted(taskAdapter, trace, {
    used = function(callback)
        if callback.index % 7 ~= 0 then
            return 0
        end
        local stage = DECL.stages.run
        local overhead = callback.kind == "background" and 1130 or 1250
        return scheduler.CEILING
            - scheduler.MARGIN
            - scheduler.FIXED_COST
            - overhead
            - stage.fixed
            - stage.perUnit
            - scheduler.EXAMINE_COST
            - scheduler.RUN_COST
            + 1
    end,
})
local timing = parity.timing(extraction, tight, trace[#trace].now)
assert(timing.late > 0, "tight budget defers some history releases")
assert(timing.late <= 100, "deferred history releases remain bounded: " .. timing.late)
assert(timing.budgetedGap <= timing.legacyGap + 100, "history update gaps remain bounded")
equal(taskAdapter.published(tight.task), taskAdapter.published(extraction.task), "tight budget converges to legacy history")

do
    equal(DECL.class, "normal")
    equal(DECL.stages.run.maxUnits, 16)
    assert(scheduler.check(DECL) == nil, "history declaration is usable")

    local runtime = services.runtime(services.environment({}))
    runtime.host = {}
    local arm = {
        key = "L01",
        configured = true,
        available = true,
        fresh = true,
        value = true,
        updatedAt = 0,
    }
    runtime.byId.armed = {
        state = function()
            return arm
        end,
    }
    runtime.byId.telemetry = {
        subscribe = function()
            return {}
        end,
        observe = function() end,
    }
    local hostOwned = historyService.new(runtime.env, services, runtime)
    hostOwned:subscribe("V", { armSwitch = "L01" })
    equal(hostOwned.update, nil, "the host-owned history service has no legacy update entry point")

    local at = trace[1].now
    arm.updatedAt = at
    local s = scheduler.new({ steady = 1250, background = 1130 })
    local added, reason = s:add({ id = "service:history", decl = hostOwned.decl, instance = hostOwned, due = at })
    assert(added, reason)
    s:run("steady", at, scheduler.CEILING)
    equal(hostOwned.revision, 0, "a no-room callback does not run history work")
    equal(hostOwned.sessions[1].state.elapsed, 0, "a no-room callback leaves the recording clock untouched")
    equal(s:dueOf("service:history"), at, "a deferred release stays pending")
    assert(not s:takeErrors(), "no room is not a history task failure")

    arm.updatedAt = at + 1
    s:run("steady", at + 1)
    equal(hostOwned.revision, 1, "history resumes when room returns")
    equal(hostOwned.sessions[1].state.recording, true, "the resumed release observes the current armed state")
    assert(not s:takeErrors())
end

print("Scheduler history task parity passed")
