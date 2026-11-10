-- SPDX-License-Identifier: GPL-2.0-only

local profile = {}

local function add(state, id, instructions, slots, detail)
    local row = state.instructionRow
    row.charges[#row.charges + 1] = {
        id = id, instructions = instructions, slots = slots, detail = detail,
    }
end

function profile.install(context, state)
    if state.instructionInstalled then
        for _, entry in ipairs(context.panels) do
            state.instructionIds[entry.instance] = entry.placement.id
        end
        return
    end
    if not context.servicesModule then
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
    state.instructionIds = ids
    for _, entry in ipairs(context.panels) do
        ids[entry.instance] = entry.placement.id
        if not modules[entry.module] then
            modules[entry.module] = true
            local refresh = entry.module.refresh
            entry.module.refresh = function(chart, creating, slots)
                if not state.instructionRow then
                    return refresh(chart, creating, slots)
                end
                local detail = {
                    stage = state.instructionStage and state.instructionStage(chart) or "unknown",
                    grant = slots,
                    series = #(chart.series or {}),
                }
                local spans = {}
                local function wrap(owner, key, category)
                    if not owner or type(owner[key]) ~= "function" then
                        return
                    end
                    local original = owner[key]
                    spans[#spans + 1] = { owner = owner, key = key, original = original }
                    owner[key] = function(self, ...)
                        local positions
                        if category == "projection" and self.jobs then
                            positions = {}
                            for _, job in ipairs(self.jobs) do
                                positions[#positions + 1] = { job = job, index = job.index }
                            end
                        end
                        local start = __instructionCount()
                        local result, estimated = original(self, ...)
                        local finish = __instructionCount()
                        detail[category] = (detail[category] or 0) + finish - start
                        if category == "projection" then
                            detail.columns = -1
                            if positions then
                                detail.columns = 0
                                for _, position in ipairs(positions) do
                                    detail.columns = detail.columns + position.job.index - position.index
                                end
                            end
                        end
                        return result, estimated
                    end
                end
                wrap(chart.mipmapRenderer, "step", "projection")
                wrap(chart.mipmapRenderer, "prepare", "preparation")
                for _, consumer in ipairs(chart.mipmapConsumers or {}) do
                    wrap(consumer, "step", "rebuild")
                    wrap(consumer, "view", "view")
                end
                local before = __instructionCount()
                local interval, unfinished, used = refresh(chart, creating, slots)
                local after = __instructionCount()
                for _, span in ipairs(spans) do
                    span.owner[span.key] = span.original
                end
                detail.after = state.instructionStage and state.instructionStage(chart) or "unknown"
                add(state, assert(ids[chart]), after - before, used, detail)
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
    state.instructionRows = state.instructionRows or {}
    state.instructionRecipients = { "flight_poll" }
    for _, instance in ipairs(context.serviceRuntime.order) do
        state.instructionRecipients[#state.instructionRecipients + 1] = instance.id
    end
    for _, entry in ipairs(context.panels) do
        state.instructionRecipients[#state.instructionRecipients + 1] = entry.placement.id
    end
end

function profile.activate()
    local file = assert(io.open("/instruction-profile-enable", "w"))
    io.close(file)
end

function profile.begin(context, state, stage, phase, activated)
    if not activated then
        profile.activate()
    end
    state.instructionStage = stage
    profile.install(context, state)
    state.instructionRow = { charges = {}, phase = phase or "operation" }
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
    row.stage = state.profile and state.profile.pendingStage or "startup"
    state.instructionRows[#state.instructionRows + 1] = row
    state.instructionRow = nil
end

function profile.write(state, path, first, last)
    first = first or 1
    local offset = state.instructionOffset or 0
    local file = assert(io.open(path or "/instruction-profile.txt", first + offset == 1 and "w" or "a"))
    if first + offset == 1 then
        for _, id in ipairs(state.instructionRecipients) do
            io.write(file, "RECIPIENT id=" .. id .. "\n")
        end
    end
    for index = first, math.min(last or #state.instructionRows, #state.instructionRows) do
        local row = state.instructionRows[index]
        local callback = index + offset
        io.write(file, string.format(
            "CALLBACK index=%d instructions=%d counter=%d firmware_percent=%d period=%d unused=%d stage=%s probe=%d phase=%s before=%d\n",
            callback, row.total, row.counter, row.percent, row.period, row.unused, row.stage, row.probe, row.phase, row.started
        ))
        for _, charge in ipairs(row.charges) do
            io.write(file, string.format(
                "TASK callback=%d id=%s instructions=%d slots=%d\n",
                callback, charge.id, charge.instructions, charge.slots
            ))
            if charge.detail then
                local d = charge.detail
                io.write(file, string.format(
                    "CHART callback=%d id=%s instructions=%d slots=%d grant=%d series=%d stage=%s after=%s projection=%d preparation=%d rebuild=%d view=%d columns=%d\n",
                    callback, charge.id, charge.instructions, charge.slots, d.grant, d.series, d.stage, d.after,
                    d.projection or 0, d.preparation or 0, d.rebuild or 0, d.view or 0, d.columns or -1
                ))
            end
        end
    end
    io.close(file)
end

function profile.checkOperations(context)
    local renderer = getmetatable(context.panels[1].instance.mipmapRenderer)
    local root = lvgl.box(context.panels[1].container, { x = -10, y = -10, w = 1, h = 1 })
    lvgl.hide(root)
    local object = lvgl.rectangle(root, { x = 0, y = 0, w = 1, h = 1, filled = true })
    local cases = {
        { populated = false, visible = false },
        { populated = true, visible = true },
        { populated = true, visible = true, position = true },
        { populated = true, visible = false, activating = true },
        { populated = false, visible = true },
    }
    local function signal(path)
        local file = assert(io.open(path, "w"))
        io.close(file)
    end
    signal("/instruction-operations-reset")
    signal("/instruction-profile-enable")
    for _, case in ipairs(cases) do
        local job = {
            index = 0, last = 0, origin = 0, top = 0, low = 0, high = 1, left = 0, height = 100,
            tags = { case.populated and 1 or 0 }, lows = { 0.2 }, highs = { 0.8 },
            placeX = case.position, activate = case.activating,
            geometry = 1, level = 0, map = { level = 0 },
        }
        local target = setmetatable({
            width = 1, changes = {}, objects = { object }, visible = { case.visible },
            offsets = { 0 }, membership = { 1 }, root = root,
            context = { series = { {} } }, jobs = { job },
        }, renderer)
        target:step(75)
    end
    signal("/instruction-operations-check-dump")
    root:clear()
end

return profile
