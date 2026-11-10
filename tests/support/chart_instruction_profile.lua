-- SPDX-License-Identifier: GPL-2.0-only

local profile = {}

local function add(state, id, instructions, slots)
    local row = state.instructionRow
    row.charges[#row.charges + 1] = {
        id = id, instructions = instructions, slots = slots,
    }
end

function profile.install(context, state)
    if state.instructionInstalled or not context.servicesModule then
        return
    end
    assert(type(__instructionCount) == "function", "native instruction counter not installed")
    for _, instance in ipairs(context.serviceRuntime.order) do
        local update = instance.update
        instance.update = function(owner, now, slots)
            if not state.instructionRow then
                return update(owner, now, slots)
            end
            local before = __instructionCount()
            local used = update(owner, now, slots)
            local after = __instructionCount()
            add(state, owner.id, after - before, used or slots)
            return used
        end
    end
    local modules, ids = {}, {}
    for _, entry in ipairs(context.panels) do
        ids[entry.instance] = entry.placement.id
        if not modules[entry.module] then
            modules[entry.module] = true
            local refresh = entry.module.refresh
            entry.module.refresh = function(chart, creating, slots)
                if not state.instructionRow then
                    return refresh(chart, creating, slots)
                end
                local before = __instructionCount()
                local interval, unfinished, used = refresh(chart, creating, slots)
                local after = __instructionCount()
                add(state, assert(ids[chart]), after - before, used)
                return interval, unfinished, used
            end
        end
    end
    local broker = context.flightFactory.broker
    local tick = broker.tick
    broker.tick = function(owner, ...)
        if not state.instructionRow then
            return tick(owner, ...)
        end
        local before = __instructionCount()
        local result = tick(owner, ...)
        local after = __instructionCount()
        add(state, "flight_poll", after - before, 1)
        return result
    end
    state.instructionInstalled = true
    state.instructionRows = {}
    state.instructionRecipients = { "flight_poll" }
    for _, instance in ipairs(context.serviceRuntime.order) do
        state.instructionRecipients[#state.instructionRecipients + 1] = instance.id
    end
    for _, entry in ipairs(context.panels) do
        state.instructionRecipients[#state.instructionRecipients + 1] = entry.placement.id
    end
end

function profile.begin(context, state)
    local file = assert(io.open("/instruction-profile-enable", "w"))
    io.close(file)
    profile.install(context, state)
    state.instructionRow = { charges = {} }
    local probe = __instructionCount()
    state.instructionRow.probe = __instructionCount() - probe
    state.instructionRow.started = __instructionCount()
end

function profile.finish(context, state)
    local count, percent, period = __instructionCount()
    local row = state.instructionRow
    assert(period == 200 and count // period == percent, "native counter differs from firmware instruction hook")
    row.total = count - row.started
    row.counter, row.percent, row.period = count, percent, period
    row.unused = context.remainingSlots
    row.stage = state.profile.pendingStage
    state.instructionRows[#state.instructionRows + 1] = row
    state.instructionRow = nil
end

function profile.write(state)
    local file = assert(io.open("/instruction-profile.txt", "w"))
    for _, id in ipairs(state.instructionRecipients) do
        io.write(file, "RECIPIENT id=" .. id .. "\n")
    end
    for callback, row in ipairs(state.instructionRows) do
        io.write(file, string.format(
            "CALLBACK index=%d instructions=%d counter=%d firmware_percent=%d period=%d unused=%d stage=%s probe=%d\n",
            callback, row.total, row.counter, row.percent, row.period, row.unused, row.stage, row.probe
        ))
        for _, charge in ipairs(row.charges) do
            io.write(file, string.format(
                "TASK callback=%d id=%s instructions=%d slots=%d\n",
                callback, charge.id, charge.instructions, charge.slots
            ))
        end
    end
    io.close(file)
end

return profile
