-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."
local parity = assert(loadfile(root .. "/tests/support/scheduler_parity.lua"))(root)
local scheduler = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/scheduler.lua"))()
local services = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/services.lua"))()
local telemetryService = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/telemetry_service.lua"))()
local historyService = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/history_service.lua"))()
local equal = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual

local function adapter()
    return {
        id = "service:telemetry",
        decl = telemetryService.legacyDecl,
        new = function()
            local values, arms = { S01 = 10, S02 = 20 }, {}
            local rssi = 42
            local env = services.environment({
                getFieldInfo = function(name)
                    local index = tonumber(string.match(name, "^S(%d+)$"))
                    return index and { id = index, name = name, unit = 1 }
                end,
                getValue = function(id)
                    return values["S" .. string.format("%02d", id)]
                end,
                getRSSI = function()
                    return rssi
                end,
            })
            local runtime = services.runtime(env)
            runtime.byId.armed = {
                state = function(_, name)
                    if not arms[name] then
                        arms[name] = {
                            key = name,
                            configured = true,
                            available = true,
                            fresh = true,
                            value = true,
                            updatedAt = 0,
                        }
                    end
                    return arms[name]
                end,
            }
            local telemetry = telemetryService.new(env, services, runtime)
            runtime.byId.telemetry = telemetry
            local history = historyService.new(env, services, runtime)
            runtime.byId.history = history
            history:subscribe("S01", {
                armSwitch = "L01",
                timeRange = "rolling",
                windowSeconds = 30,
            })
            history:subscribe("S01", {
                armSwitch = "L01",
                timeRange = "rolling",
                windowSeconds = 60,
            })
            history:subscribe("S01", {
                armSwitch = "L01",
                timeRange = "rolling",
                windowSeconds = 120,
            })
            telemetry:subscribe("S02")
            telemetry.pollCap = 2
            telemetry.want = 2
            telemetry.tickElapsed = scheduler.elapsed
            telemetry.due = 1000
            history:advance(990)
            history:sample({
                name = "S01",
                value = 5,
                kind = "number",
                fresh = true,
                updatedAt = 990,
                precision = 0,
                precisionKnown = true,
                unitText = "V",
            }, 990)
            telemetry.update = function(self, now)
                self:step(telemetryService.POLL_CAP, "run", now)
                self.revision = self.revision - 1
                self.due = now + self.interval
            end
            telemetry.values, telemetry.arms = values, arms
            telemetry.setRssi = function(value)
                rssi = value
            end
            return telemetry
        end,
        feed = function(task, callback)
            task.values.S01 = callback.values.S01
            task.values.S02 = callback.values.S02
            task.setRssi(callback.rssi)
            local arm = task.arms.L01
            arm.value = callback.armed
            arm.fresh = callback.armed ~= nil
            arm.available = callback.armed ~= nil
            arm.updatedAt = callback.now
        end,
        old = function(task, now)
            telemetryService.update(task, now)
        end,
        snapshot = function(task)
            local rows = {
                tostring(task.revision),
                tostring(task.linkLive),
                tostring(task.linkTrusted),
                tostring(task.cursor),
            }
            for _, name in ipairs({ "S01", "S02" }) do
                local reading = task:reading(name)
                rows[#rows + 1] = table.concat({
                    name,
                    tostring(reading.available),
                    tostring(reading.fresh),
                    tostring(reading.stale),
                    tostring(reading.value),
                    tostring(reading.updatedAt),
                    tostring(reading.revision),
                }, ":")
            end
            local history = task.runtime.byId.history
            for _, entry in ipairs(history.entries) do
                rows[#rows + 1] = table.concat({
                    entry.state.name,
                    tostring(entry.state.first),
                    tostring(entry.state.last),
                    tostring(entry.state.count),
                    tostring(entry.state.value),
                    tostring(entry.state.stale),
                    tostring(entry.state.revision),
                    tostring(entry.state.plotRevision),
                }, ":")
            end
            return table.concat(rows, "|")
        end,
    }
end

local trace, now = {}, 1000
for index = 1, 120 do
    now = now + 10
    local phase = math.min(index, 90)
    local first = 10 + phase / 10
    local second = 20 + phase / 20
    if phase % 13 == 0 then
        first = nil
    end
    if phase % 19 == 0 then
        second = nil
    end
    trace[index] = {
        now = now,
        kind = index % 7 == 0 and "background" or "steady",
        values = {
            S01 = phase % 17 == 0 and 0 or first,
            S02 = second,
        },
        rssi = index % 23 < 3 and 0 or 42,
        armed = phase % 31 < 20,
    }
end

local taskAdapter = adapter()
local golden = parity.golden(taskAdapter, trace)
local extraction = parity.extraction(taskAdapter, trace)
parity.assertSame(golden, extraction, "telemetry extraction")
assert(#extraction.schedule > 8, "legacy telemetry has scheduled releases")
parity.assertSame(golden, parity.replay(taskAdapter, trace, extraction.schedule), "telemetry replay")
parity.assertSame(golden, parity.budgeted(taskAdapter, trace), "telemetry ample budget")

do
    local service = taskAdapter.new()
    local at = trace[1].now
    local s = scheduler.new({ steady = 1250, background = 1130 })
    local added, reason = s:add({ id = taskAdapter.id, decl = taskAdapter.decl, instance = service, due = at })
    assert(added, reason)
    s:run("steady", at, scheduler.CEILING)
    equal(service.revision, 0, "no room leaves telemetry untouched")
    equal(s:dueOf(taskAdapter.id), at, "no room leaves the telemetry release pending")
    assert(not s:takeErrors(), "no room is not a telemetry task failure")
    s:run("steady", at + 1)
    equal(service.revision, 2, "telemetry resumes when budget returns")
    assert(not s:takeErrors())
end

do
    local buildCase = assert(loadfile(root .. "/tests/fixtures/scheduler-cases/telemetry.lua"))()
    local declared = assert(loadfile(root .. "/tests/fixtures/scheduler-bounds.lua"))().tasks
    local sourceBound = declared["service:telemetry:source:recorded"]
    local case = buildCase(function(relative)
        return assert(loadfile(root .. "/src/WIDGETS/AeroGrid/" .. relative))()
    end)
    equal(case.id, "service:telemetry:source:recorded")
    equal(#case.cases, historyService.SOURCE_CAP)
    equal(case.decl.class, sourceBound.class)
    equal(case.decl.stages.run.fixed, sourceBound.fixed)
    equal(case.decl.stages.run.perUnit, sourceBound.perUnit)
    equal(case.decl.stages.run.maxUnits, sourceBound.maxUnits)
    for _, item in ipairs(case.cases) do
        local task = item.setup(1)
        local recorders = task.service.runtime.byId.history.sources.S01 or {}
        equal(
            #recorders,
            item.recorders,
            "native case exercises the declared observer multiplicity"
        )
        equal(task.want, item.recorders, "source polls request all observer work atomically")
        equal(task.decl.stages.run.maxUnits, item.recorders)
    end

    local maintenance = assert(loadfile(root .. "/tests/fixtures/scheduler-cases/telemetry-maintenance.lua"))()(function(relative)
        return assert(loadfile(root .. "/src/WIDGETS/AeroGrid/" .. relative))()
    end)
    local maintenanceBound =
        assert(loadfile(root .. "/tests/fixtures/scheduler-bounds.lua"))().tasks["service:telemetry:maintenance"]
    equal(maintenance.id, "service:telemetry:maintenance")
    equal(maintenance.decl.class, maintenanceBound.class)
    equal(maintenance.decl.stages.run.fixed, maintenanceBound.fixed)
    equal(maintenance.decl.stages.run.perUnit, maintenanceBound.perUnit)
    equal(maintenance.decl.stages.run.maxUnits, maintenanceBound.maxUnits)
    equal(maintenance.decl.stages.run.maxUnits, scheduler.MAX_TASKS, "maintenance covers the host's task limit")
    for _, item in ipairs(maintenance.cases) do
        local task = item.setup(1)
        equal(task.want, item.grant, "maintenance reserves every possible source inspection")
    end

    local env = services.environment({
        getRSSI = function()
            return 42
        end,
    })
    local scanService = telemetryService.new(env, services)
    for index = 1, 24 do
        scanService:subscribe("S" .. index)
    end
    local maintenanceTask = scanService.maintenanceTask
    local before = scanService.revision
    equal(maintenanceTask:step(23, "run", 100), 1, "an undersized maintenance grant retries")
    equal(scanService.revision, before, "an undersized maintenance grant does no work")
    equal(maintenanceTask:step(24, "run", 101), scanService.interval)
    assert(scanService.revision > before, "maintenance resumes with a full inspection grant")

    local unrecorded = assert(loadfile(root .. "/tests/fixtures/scheduler-cases/telemetry-unrecorded.lua"))()(function(relative)
        return assert(loadfile(root .. "/src/WIDGETS/AeroGrid/" .. relative))()
    end)
    local plainBound = declared["service:telemetry:source:plain"]
    equal(unrecorded.id, "service:telemetry:source:plain")
    equal(unrecorded.decl.stages.run.fixed, plainBound.fixed)
    equal(unrecorded.decl.stages.run.perUnit, plainBound.perUnit)
    equal(unrecorded.decl.stages.run.maxUnits, plainBound.maxUnits)
    local plain, plainTick = unrecorded.cases[1].setup(1)
    plain:step(1, "run", plainTick)
    equal(plain.entry.state.available, true, "the native unrecorded case must resolve and read a source")

    local recordedOne =
        assert(loadfile(root .. "/tests/fixtures/scheduler-cases/telemetry-recorded-one.lua"))()(function(relative)
            return assert(loadfile(root .. "/src/WIDGETS/AeroGrid/" .. relative))()
        end)
    local recordedOneBound = declared["service:telemetry:source:recorded-one"]
    equal(recordedOne.decl.stages.run.fixed, recordedOneBound.fixed)
    equal(recordedOne.decl.stages.run.perUnit, recordedOneBound.perUnit)
    equal(recordedOne.decl.stages.run.maxUnits, recordedOneBound.maxUnits)

    local largest = case.cases[#case.cases].setup(1)
    local history = largest.service.runtime.byId.history
    local sampled = {}
    local sample = history.sample
    history.sample = function(self, reading, now)
        for _, entry in ipairs(self.sources[reading.name] or {}) do
            sampled[entry] = (sampled[entry] or 0) + 1
        end
        return sample(self, reading, now)
    end
    local tick = 1000000
    local budget = scheduler.new({ steady = 1250, background = 1130 })
    local added, reason = budget:add({
        id = largest.id,
        decl = largest.decl,
        instance = largest,
        due = tick,
    })
    assert(added, reason)
    budget:run("steady", tick, 7000)
    equal(largest.entry.state.available, false, "an undersized grant cannot partially poll a source")
    equal(budget:dueOf(largest.id), tick + 1, "an undersized source grant is retried")
    assert(not budget:takeErrors(), "an undersized source grant is not a task failure")
    for _, entry in ipairs(history.sources.S01) do
        equal(sampled[entry], nil, "History observers wait for a complete source grant")
    end
    budget:run("steady", tick + 1)
    equal(largest.entry.state.available, true, "a complete grant resumes the source poll")
    for _, entry in ipairs(history.sources.S01) do
        equal(sampled[entry], 1, "all History observers run in the completed source poll")
    end
    assert(not budget:takeErrors())
end

print("Scheduler telemetry task parity passed")
