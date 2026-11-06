-- SPDX-License-Identifier: GPL-2.0-only

-- Phase 3 parity and bounded-grant checks for the three control tasks.
local root = (... and ... ~= "" and ...) or "."
local parity = assert(loadfile(root .. "/tests/support/scheduler_parity.lua"))(root)
local scheduler = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/scheduler.lua"))()
local services = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/services.lua"))()
local controlService = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/control_service.lua"))()
local hostIo = io
local equal = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual

local CALLBACKS, TAIL = 120, 40
local LATE = 120

local function digest(text)
    local hash = 5381
    for position = 1, #text do
        hash = (hash * 33 + string.byte(text, position)) % 16777213
    end
    return string.format("%06x", hash)
end

local function trace()
    local callbacks, now = {}, 0
    local function world(index)
        local values = {}
        for channel = 0, 31 do
            values[channel] = (channel * 37 + index * 13) % 2049 - 1024
        end
        return {
            flag = index % 20 < 10,
            values = values,
            raw = index % 2 == 0 and 128 or -128,
        }
    end
    for index = 1, CALLBACKS + TAIL do
        now = now + 3 + index % 5 + (index % 37 == 0 and LATE or 0)
        callbacks[index] = {
            now = now,
            index = index,
            kind = index % 7 == 0 and "background" or "steady",
            world = world(index <= CALLBACKS and index or CALLBACKS),
        }
    end
    return callbacks
end

local function radio(box)
    local ids = {}
    return services.environment({
        getSwitchIndex = function()
            return 1
        end,
        getSwitchValue = function()
            return box.world.flag
        end,
        getFieldInfo = function(name)
            ids[name] = ids[name] or #name + 10
            return { id = ids[name], name = name }
        end,
        getValue = function(id)
            return box.world.raw + id
        end,
        getGlobalVariable = function(index)
            return index * 10 + box.world.index
        end,
        getGlobalVariableDetails = function(index)
            return { name = "GV" .. tostring(index + 1), prec = 1, min = -100, max = 100, unit = 1 }
        end,
        getOutputValue = function(index)
            return box.world.values[index]
        end,
        getOutput = function(index)
            return { name = "CH" .. tostring(index + 1) }
        end,
        getMix = function(_, line)
            if line < 64 then
                return { source = "A", name = "Mix", weight = 100, carryTrim = false }
            end
        end,
    })
end

local function adapter(kind)
    local decl =
        controlService.TASK_DECLARATIONS[kind == "critical" and "critical" or kind == "outputs" and "outputs" or "normal"]
    return {
        id = kind == "critical" and "service:control" or "service:control-" .. kind,
        decl = decl,
        new = function()
            local box = { world = { index = 1, flag = false, values = {}, raw = 0 } }
            local service = controlService.new(radio(box), services)
            local feeds = {}
            if kind == "critical" then
                for index = 1, 6 do
                    feeds[index] = service:switch(string.format("L%02d", index))
                end
                service.criticalCursor = 1
                service.tasks.critical.interval = 20
            elseif kind == "outputs" then
                for index = 0, 31 do
                    feeds[index + 1] = service:output(index)
                end
                service.outputCursor = 1
                service.tasks.outputs.interval = 10
            else
                for index = 1, 6 do
                    feeds[index] = service:trim("trim-" .. tostring(index))
                end
                service.normalCursor = 1
                service.tasks.normal.interval = 20
            end
            local task = kind == "critical" and service.tasks.critical
                or kind == "outputs" and service.tasks.outputs
                or service.tasks.normal
            task.id = kind == "critical" and "control" or kind
            task.count = #feeds
            task.interval = task.interval or 20
            task.due = 0
            task.revision = 0
            task.update = function(_, now)
                service:update(now)
            end
            task.box, task.service, task.feeds = box, service, feeds
            return task
        end,
        feed = function(task, callback)
            task.box.world = callback.world
            task.box.world.index = callback.index
        end,
        old = function(task, now)
            task.service:update(now)
        end,
        snapshot = function(task)
            local values = {}
            for index, feed in pairs(task.feeds) do
                values[#values + 1] =
                    table.concat({ index, tostring(feed.available), tostring(feed.value), tostring(feed.raw) }, ":")
            end
            table.sort(values)
            return digest(table.concat(values, "|"))
        end,
    }
end

local function readGolden(path)
    local gold = {}
    local file = assert(hostIo.open(path, "r"))
    for line in file:lines() do
        local name, rest = string.match(line, "^(%a+) (.*)$")
        local snapshots = {}
        for hash in string.gmatch(rest, "%x+") do
            snapshots[#snapshots + 1] = hash
        end
        gold[name] = { snapshots = snapshots }
    end
    file:close()
    return gold
end

local function writeGolden(path, callbacks)
    local variants, lines = { "critical", "normal", "outputs" }, {}
    for _, kind in ipairs(variants) do
        local run = parity.golden(adapter(kind), callbacks)
        lines[#lines + 1] = kind .. " " .. table.concat(run.snapshots, " ")
    end
    local file = assert(hostIo.open(path, "w"))
    file:write(table.concat(lines, "\n") .. "\n")
    file:close()
end

local callbacks = trace()
local goldenPath = root .. "/tests/fixtures/scheduler-control-golden.txt"
if os.getenv("AEROGRID_WRITE_CONTROL_GOLDEN") then
    writeGolden(goldenPath, callbacks)
end
local golden = readGolden(goldenPath)

for _, kind in ipairs({ "critical", "normal", "outputs" }) do
    local expected = assert(golden[kind], kind .. " golden trace is present")
    local taskAdapter = adapter(kind)
    local extraction = parity.extraction(taskAdapter, callbacks)
    parity.assertSame(expected, extraction, kind .. " extraction")
    assert(#extraction.schedule > 20, kind .. " legacy schedule has releases")
    parity.assertSame(expected, parity.replay(taskAdapter, callbacks, extraction.schedule), kind .. " replay")

    local ample = parity.budgeted(taskAdapter, callbacks)
    parity.assertSame(expected, ample, kind .. " ample budget")

    local tight = parity.budgeted(taskAdapter, callbacks, {
        used = function(callback)
            if callback.index % 7 == 0 then
                return 13000
            elseif callback.index % 7 == 1 then
                return 12700
            end
            return 0
        end,
    })
    local timing = parity.timing(extraction, tight, callbacks[#callbacks].now)
    assert(timing.late > 0, kind .. " tight budget delays some releases")
    assert(timing.late <= LATE + 100, kind .. " task lateness stays bounded: " .. timing.late)
    assert(timing.budgetedGap <= timing.legacyGap + LATE + 100, kind .. " maximum gap stays bounded")
    if kind == "outputs" then
        local partial = false
        for _, release in ipairs(tight.schedule) do
            partial = partial or release.grant < 32
        end
        assert(partial, "the budgeted output task exercises partial channel grants")
    end
    parity.assertSame(
        { snapshots = { expected.snapshots[#expected.snapshots] } },
        { snapshots = { tight.snapshots[#tight.snapshots] } },
        kind .. " final published values"
    )
end

do
    local runtime = services.runtime({})
    runtime.host = {}
    local scheduled = controlService.new(services.environment({}), services, runtime)
    assert(scheduled.update == nil, "the dashboard-owned service has no legacy update path")
    local private = controlService.new(services.environment({}), services, services.runtime({}))
    assert(type(private.update) == "function", "the flight broker's private runtime retains its legacy path")
    equal(scheduled.tasks.critical.decl.class, "critical")
    equal(scheduled.tasks.normal.decl.class, "normal")
    equal(scheduled.tasks.outputs.decl.class, "normal")
    equal(scheduler.check(scheduled.tasks.critical.decl), nil)
    equal(scheduler.check(scheduled.tasks.normal.decl), nil)
    equal(scheduler.check(scheduled.tasks.outputs.decl), nil)
end

do
    local reads = 0
    local env = services.environment({
        getFieldInfo = function(name)
            return { id = #name + 10 }
        end,
        getValue = function()
            reads = reads + 1
            return 128
        end,
        getOutputValue = function(index)
            reads = reads + 1
            return index * 32
        end,
    })
    local service = controlService.new(env, services, { host = true })
    for index = 1, 6 do
        service:trim("trim-" .. tostring(index))
    end
    local task = service.tasks.normal
    equal(task.step(task, 2, "run", 100), 1)
    equal(reads, 2, "a partial normal grant reads only two entries")
    equal(task.step(task, 2, "run", 101), 1)
    equal(reads, 4)
    equal(task.step(task, 2, "run", 102), 20)
    equal(reads, 6)

    for index = 0, 31 do
        service:output(index)
    end
    reads = 0
    equal(service.tasks.outputs.step(service.tasks.outputs, 3, "run", 200), 1)
    equal(reads, 3, "a partial output grant reads only three channels")
    equal(service.tasks.outputs.step(service.tasks.outputs, 29, "run", 201), 10)
    equal(reads, 32, "the remaining channels are read on the next release")
    for _, entry in ipairs(service.outputEntries) do
        assert(entry.state.available, "all channels publish after the partial output release")
    end
end

print("Scheduler control task parity passed")
