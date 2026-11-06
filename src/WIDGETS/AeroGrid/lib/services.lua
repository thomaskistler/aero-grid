-- SPDX-License-Identifier: GPL-2.0-only

--- Shared data service registry, scheduler, and snapshot plumbing.
---
--- The host owns polling so panels never read EdgeTX sources themselves.
--- Two rules keep that affordable inside EdgeTX's 20000-instruction callback
--- budget, which every service update shares with every panel refresh:
---
--- 1. A service only reads what a loaded panel actually subscribed to. A
---    service with no subscriptions is skipped entirely, so a dashboard of
---    metrics never pays for GPS, trims, or global variables.
--- 2. At most one legacy-owned service is updated per host cycle, chosen round robin among
---    those due, and each service further caps how many subscriptions it
---    refreshes in one update. Per-callback cost is therefore bounded by the
---    caps rather than by how much the layout asks for.
---
--- Panels receive immutable views. The service mutates its own state table
--- in place, which costs no allocation per cycle, and hands out a proxy whose
--- writes raise. Services update before panels refresh, so a panel
--- sees one consistent set of readings for the cycle.

---@class AeroGridServiceInstance
---@field id string Service name used in the services table.
---@field interval integer Ticks of 10ms between updates.
---@field due integer Tick at which this service is next due.
---@field revision integer Incremented on every completed update.
---@field count integer Number of live subscriptions.
---@field failed? boolean Set after an update raises, which retires the service.
---@field update? fun(self: AeroGridServiceInstance, now: integer) Legacy-owned service entry point.
---@field step? fun(self: AeroGridServiceInstance, grant: integer, stage: string, now: integer): integer
---@field tasks? table<string, table> Named scheduler tasks.
---@field schedulerTasks? table[] Ordered task registrations.
---@field resetSession? fun(self: AeroGridServiceInstance, now: integer, index: integer): integer? Next reset item, or nil when finished.

local services = { RUNTIME_API = 1 }

--- Service modules loaded by the host, in the order they are staged.
--- Each entry's `id` becomes the key in the services table handed to a
--- panel, so a panel reads `services.telemetry`, `services.model`,
--- and so on.
services.DEFINITIONS = {
    { id = "telemetry", file = "lib/telemetry_service.lua" },
    { id = "model", file = "lib/model_service.lua" },
    { id = "control", file = "lib/control_service.lua" },
    { id = "flight", file = "lib/flight_service.lua" },
    { id = "armed", file = "lib/armed_service.lua" },
    { id = "navigation", file = "lib/navigation_service.lua" },
    { id = "history", file = "lib/history_service.lua" },
    { id = "smart", file = "lib/smart_flight.lua" },
}

--- Refuse writes to a published snapshot.
local function readOnly()
    error("service snapshots are read-only", 2)
end

--- Publish a mutable state table as an immutable view.
--- Reads fall through to the live state, so the service can keep updating in
--- place without allocating a fresh table every cycle, while a panel
--- cannot corrupt data another panel is also reading.
---@param state table
---@return table view
function services.snapshot(state)
    return setmetatable({}, {
        __index = state,
        __newindex = readOnly,
        -- Hide the metatable so a panel cannot reach the mutable state.
        __metatable = false,
    })
end

--- Read a global EdgeTX function, tolerating firmware that lacks it.
---@param value any
---@return function?
local function callable(value)
    if type(value) == "function" then
        return value
    end
    return nil
end

--- Collect the EdgeTX entry points the services use.
--- Everything is resolved once and every entry may be absent: a radio without
--- GPS, global variables, or a sensor table must degrade rather than raise.
--- Tests pass overrides instead of installing globals.
---@param overrides? table
---@return table env
function services.environment(overrides)
    overrides = type(overrides) == "table" and overrides or {}

    local modelApi = overrides.model
    if type(modelApi) ~= "table" then
        modelApi = model
    end
    if type(modelApi) ~= "table" then
        modelApi = {}
    end

    return {
        getValue = callable(overrides.getValue) or callable(getValue),
        getSourceValue = callable(overrides.getSourceValue) or callable(getSourceValue),
        getOutputValue = callable(overrides.getOutputValue) or callable(getOutputValue),
        getFieldInfo = callable(overrides.getFieldInfo) or callable(getFieldInfo),
        getRSSI = callable(overrides.getRSSI) or callable(getRSSI),
        getFlightMode = callable(overrides.getFlightMode) or callable(getFlightMode),
        getTime = callable(overrides.getTime) or callable(getTime),
        getSwitchIndex = callable(overrides.getSwitchIndex) or callable(getSwitchIndex),
        getSwitchValue = callable(overrides.getSwitchValue) or callable(getSwitchValue),
        setStickySwitch = callable(overrides.setStickySwitch) or callable(setStickySwitch),
        getLogicalSwitch = callable(modelApi.getLogicalSwitch),
        charUp = CHAR_UP,
        charDown = CHAR_DOWN,
        -- A global like `getValue`, not part of the model API: `etxlib` is in
        -- `_global_symbols` and reached through _G's __index
        -- (`radio/src/thirdparty/lua/src/linit.c`), so a widget sees it directly.
        getGeneralSettings = callable(overrides.getGeneralSettings) or callable(getGeneralSettings),
        getInfo = callable(modelApi.getInfo),
        getTimer = callable(modelApi.getTimer),
        getSensor = callable(modelApi.getSensor),
        getModule = callable(modelApi.getModule),
        getOutput = callable(modelApi.getOutput),
        getMix = callable(modelApi.getMix),
        getInput = callable(modelApi.getInput),
        getGlobalVariable = callable(modelApi.getGlobalVariable),
        setGlobalVariable = callable(modelApi.setGlobalVariable),
        getGlobalVariableDetails = callable(modelApi.getGlobalVariableDetails),
    }
end

--- Create the registry that owns every service instance.
---@param env table Result of services.environment.
---@return table runtime
function services.runtime(env)
    return { env = env, order = {}, byId = {}, cursor = 1, updates = 0 }
end

local function taskStep(task, grant, stage, now)
    local owner = task.owner
    if owner.failed then
        return 1
    end
    owner.tickElapsed = task.tickElapsed or owner.tickElapsed
    local ok, delay = pcall(task.run, owner, grant, stage, now, task)
    if not ok then
        owner.failed = true
        if owner.taskFailed then
            owner:taskFailed()
        end
        error(delay, 0)
    end
    return delay
end

--- Adapt bounded service work to the scheduler. Only the scheduler computes grants.
--- `run(owner, grant, stage, now, task)` returns the delay to its next release.
--- Names are stable within the service; registrations retain their public IDs.
---@param owner table
---@param name string
---@param task table Task ID, declaration, run function, and optional scheduling fields.
---@return table task
function services.task(owner, name, task)
    owner.tasks = owner.tasks or {}
    owner.schedulerTasks = owner.schedulerTasks or {}
    assert(not owner.tasks[name], "duplicate service task " .. name)
    task.owner, task.step = owner, taskStep
    task.want = task.want or 0
    task.item = { id = task.id, instance = task, critical = task.critical }
    owner.tasks[name] = task
    owner.schedulerTasks[#owner.schedulerTasks + 1] = task.item
    return task
end

--- Add one constructed service to the registry.
--- Services are phase staggered on registration for the same reason panels
--- are: without it every service falls due on the same frame and the host pays
--- their combined cost in one callback.
---@param runtime table
---@param instance AeroGridServiceInstance
---@param now integer
function services.register(runtime, instance, now)
    local order = runtime.order
    order[#order + 1] = instance
    runtime.byId[instance.id] = instance
    instance.due = now + (#order - 1)
end

--- Update at most one due service.
--- Returns the service updated so the host can report a failure exactly once,
--- and so tests can observe the scheduling instead of inferring it.
--- `admit(instance)` lets the host skip scheduler-owned services. Scheduler-only
--- services also have no `update` method.
---@param runtime table
---@param now integer
---@param admit? fun(instance: AeroGridServiceInstance): boolean
---@return string? id
---@return string? error
function services.update(runtime, now, admit)
    local order = runtime.order
    local count = #order
    if count == 0 then
        return nil
    end

    local cursor = runtime.cursor
    if cursor > count then
        cursor = 1
    end

    for _ = 1, count do
        local instance = order[cursor]
        cursor = cursor % count + 1

        local due = instance and not instance.failed and instance.count > 0 and now >= instance.due
        local admitted = due and (not admit or admit(instance))

        -- Keep a scheduler-owned service's legacy rotation slot from pulling
        -- another service into this callback. Do not postpone the scheduler's
        -- release by overwriting the service task's own due time.
        if due and not admitted and instance.preserveLegacySlot then
            if type(instance.step) ~= "function" then
                instance.due = now + instance.interval
            end
            runtime.cursor = cursor
            return instance.legacySlotReservation and instance.id or nil
        end

        -- Scheduler-only services have no legacy update entry point. The host
        -- releases them from the task table instead.
        if
            due
            and admitted
            and type(instance.update) == "function"
        then
            instance.due = now + instance.interval
            runtime.cursor = cursor
            runtime.updates = runtime.updates + 1

            -- A source that misbehaves must not raise inside a widget callback, and
            -- a service that fails once is retired rather than left to fail forever.
            local ok, updateError = pcall(instance.update, instance, now)
            if not ok then
                instance.failed = true
                return instance.id, tostring(updateError)
            end

            instance.revision = instance.revision + 1
            return instance.id
        end
    end

    runtime.cursor = cursor
    return nil
end

--- Publish service-owned state and append one subscription in polling order.
--- Name lookup and duplicate detection remain with the domain service.
---@param owner table Service with support and count fields.
---@param entries table[] Service-owned polling list.
---@param entry table Mutable state plus domain-specific polling metadata.
---@return table entry Entry with its immutable live view.
function services.addSubscription(owner, entries, entry)
    entry.view = owner.support.snapshot(entry.state)
    entries[#entries + 1] = entry
    owner.count = owner.count + 1
    return entry
end

--- Visit a bounded round-robin slice of a subscription list.
---@param entries table[]
---@param cursor integer
---@param cap integer
---@param visit fun(owner: table, entry: table, now: integer)
---@param owner table Service instance passed to `visit`.
---@param now integer
---@return integer cursor Next entry to visit.
function services.roundRobin(entries, cursor, cap, visit, owner, now)
    local total = #entries
    if total == 0 then
        return cursor
    end

    if cursor < 1 or cursor > total then
        cursor = 1
    end
    if cap > total then
        cap = total
    end

    for _ = 1, cap do
        local entry = entries[cursor]
        cursor = cursor % total + 1
        if entry then
            visit(owner, entry, now)
        end
    end
    return cursor
end

--- Report whether any registered service has subscriptions.
---@param runtime table
---@return boolean
function services.active(runtime)
    for _, instance in ipairs(runtime.order) do
        if instance.count > 0 and not instance.failed then
            return true
        end
    end
    return false
end

--- Convert a tick count into whole seconds of age.
---@param now integer
---@param since? integer
---@return number?
function services.age(now, since)
    if type(since) ~= "number" then
        return nil
    end
    return (now - since) / 100
end

--- Fill one diagnostic row in a reusable array, returning the next position.
--- Rows are reused so a diagnostic view allocates nothing per refresh.
---@param rows table
---@param index integer
---@param label string
---@param text string
---@return integer
function services.row(rows, index, label, text)
    local row = rows[index]
    if not row then
        row = {}
        rows[index] = row
    end
    row.label = label
    row.text = text
    return index + 1
end

return services
