-- SPDX-License-Identifier: GPL-2.0-only

--- Development host for the new scheduler (plans/scheduler-framework.md, section 7).
---
--- Loaded by `main.lua` when its `SCHEDULER_MODE` is not `legacy` or its
--- `SCHEDULER_PROBE` is on. Releases ship `mixed` and `false`.
---
--- Modes: `legacy` (this host only observes), `mixed` (legacy work keeps its
--- existing limits and scheduling; the framework gets only the remaining budget),
--- `new` (every task is owned by the framework).

local host = { RUNTIME_API = 1 }
host.__index = host
-- Unverified dashboard records retain deadlines but cannot run during reconciliation.
local RECONCILE_KIND = "host-reconcile"

--- The one owner of every task: `service:<id>` for a service update and
--- `panel:<type>` for a panel's refresh (the chart's stages included). Flipping a
--- task to `new` is a one-line change, and it needs a task registered under the
--- same id: a service carries its `decl` and `step` and the host registers it once
--- it has subscribers (`host:enroll`); the others use `host.scheduler:add`. Modal
--- callbacks also run migrated service tasks through the scheduler.
host.OWNERS = {
    ["service:telemetry"] = "new",
    ["service:model"] = "new",
    ["service:control"] = "new",
    ["service:control-normal"] = "new",
    ["service:control-outputs"] = "new",
    ["service:armed"] = "new",
    ["service:flight"] = "legacy",
    ["service:navigation"] = "new",
    ["service:history"] = "new",
    ["service:smart"] = "legacy",
    ["panel:chart"] = "legacy",
    ["panel:flight-counter"] = "legacy",
    ["panel:flight-mode"] = "legacy",
    ["panel:flight-timer"] = "legacy",
    ["panel:host-diagnostics"] = "legacy",
    ["panel:link-status"] = "legacy",
    ["panel:metric"] = "legacy",
    ["panel:model-identity"] = "legacy",
    ["panel:navigation"] = "legacy",
    ["panel:output"] = "legacy",
    ["panel:rx-battery"] = "legacy",
    ["panel:service-probe"] = "legacy",
    ["panel:state"] = "legacy",
    ["panel:theme-showcase"] = "legacy",
    ["panel:trim-panel"] = "legacy",
    ["panel:tx-battery"] = "legacy",
}

--- The declared cost of one release of a service that carries its task
--- declaration, at its largest grant.
local function declared(instance)
    local stage = instance.decl.stages[instance.decl.first or "run"]
    return stage.fixed + stage.maxUnits * stage.perUnit
end

local TELEMETRY_TASK_PREFIX = "service:telemetry:"

local function schedulerOwned(host, id)
    return host.owners[id] == "new" or string.sub(id, 1, #TELEMETRY_TASK_PREFIX) == TELEMETRY_TASK_PREFIX
end

--- Legacy service bounds; history's bound reserves its preserved mixed-mode slot.
host.SERVICE_BOUNDS = {
    model = declared,
    control = 2620,
    history = 650,
    smart = 2600,
    flight = 0,
    armed = 0,
}

host.SERVICE_CLASS = {}

--- Declared bounds of one legacy panel refresh. theme-showcase has no refresh work.
host.PANEL_BOUNDS = {
    chart = 7800,
    metric = 4800,
    output = 5700,
    navigation = 3700,
    ["link-status"] = 2500,
    ["rx-battery"] = 1800,
    ["trim-panel"] = 1600,
    ["tx-battery"] = 1300,
    ["flight-timer"] = 1200,
    state = 1000,
    ["model-identity"] = 1000,
    ["flight-counter"] = 700,
    ["flight-mode"] = 600,
    ["host-diagnostics"] = 500,
    ["service-probe"] = 500,
    ["theme-showcase"] = 0,
}

--- Declared fixed cost of a callback at 16 panels (contracts, callback overhead).
host.OVERHEAD = {
    [RECONCILE_KIND] = 2400,
    steady = 1250,
    background = 1130,
    ["editor-build"] = 2400,
    ["modal-log"] = 2400,
    ["modal-settings"] = 2400,
    ["modal-menu"] = 2400,
    ["modal-location"] = 2400,
    ["editor-render"] = 2400,
    ["editor-drawer"] = 2400,
    loader = 2400,
    ["editor-input"] = 2400,
}

host.SERVICE_KINDS = {
    ["editor-build"] = true,
    ["modal-log"] = true,
    ["modal-settings"] = true,
    ["modal-menu"] = true,
    ["modal-location"] = true,
    ["editor-render"] = true,
    ["editor-drawer"] = true,
    loader = true,
    ["editor-input"] = true,
}

--- Reserve registration/validation before admitting scheduled work.
--- Panel and service enrollment never share the same callback.
host.PANEL_ENROLL_COST = 4000
host.SERVICE_ENROLL_COST = 2300
host.RECONCILE_COST = 900

--- Declared cost of the head work `pumpFlight` runs before the scheduler: the
--- reset poll and the flight tick (which stay legacy at the head until R4).
host.HEAD_COSTS = { reset = 620, tick = 3600 }

--- Attach a host to `context`. `options`: `mode`, `probe` (boolean), `load`
--- (relative path -> module) and `api` (`log`, `error`, `show` of main.lua).
---@param context table
---@param options table
---@return table host
function host.attach(context, options)
    local self = setmetatable({
        context = context,
        mode = options.mode,
        api = options.api,
        owners = host.OWNERS,
        serviceBounds = host.SERVICE_BOUNDS,
        panelBounds = host.PANEL_BOUNDS,
        overhead = host.OVERHEAD,
        headCosts = host.HEAD_COSTS,
        head = 0,
        panelSetup = 0,
        active = false,
        waiting = {},
        pendingServices = {},
        registeredTasks = {},
        panelTasks = {},
        idlePanels = {},
        serviceDeclarations = {},
        brokerDeclarations = {},
        panelEntries = {},
        dormant = {},
        panelQueue = {},
        panelCursor = 1,
        resetReleases = {},
        resetOwners = {},
    }, host)

    local legacy = { spent = 0 }
    self.legacy = legacy
    function legacy.admit(instance)
        return self.owners["service:" .. instance.id] ~= "new"
    end
    function legacy.skips(entry)
        return self.owners["panel:" .. entry.module.id] == "new"
    end
    function legacy.panelCost(entry)
        return self.panelBounds[entry.module.id] or self.scheduler.CEILING
    end

    if self.mode ~= "legacy" then
        self.scheduler = options.load("lib/scheduler.lua").new(self.overhead)
    end
    if options.probe then
        self.probe = options.load("lib/scheduler_probe.lua").new(self, options.load("lib/scheduler.lua"))
        context.probe = self.probe
    end
    context.schedulerHost, context.scheduler = self, self.scheduler
    return self
end

local function serviceDeclaration(self, declaration, persistent)
    if type(declaration) ~= "table" or declaration.kinds ~= nil and type(declaration.kinds) ~= "table" then
        return declaration
    end
    local cache = persistent and self.brokerDeclarations or self.serviceDeclarations
    local result = cache[declaration]
    if not result then
        result = {}
        for key, value in pairs(declaration) do
            result[key] = value
        end
        result.kinds = {}
        for kind, allowed in pairs(declaration.kinds or { steady = true, background = true }) do
            result.kinds[kind] = allowed
        end
        for kind, allowed in pairs(host.SERVICE_KINDS) do
            result.kinds[kind] = allowed and result.kinds.steady == true
        end
        result.kinds[RECONCILE_KIND] = persistent == true
        cache[declaration] = result
    end
    return result
end

---@param instance table Registered service.
---@return integer? bound Declared cost of one update, nil when there is none.
function host:serviceBound(instance)
    local bound = self.serviceBounds[instance.id]
    if type(bound) == "function" then
        return bound(instance)
    end
    return bound
end

local function serviceRegistry(context)
    local broker = context.flightFactory and context.flightFactory.broker
    local persistent = broker and broker.schedulerService and broker:schedulerService(context)
    return context.serviceRuntime and context.serviceRuntime.order or {}, persistent
end

local function pendingService(self, instance, id)
    if self.pendingServices[id] == instance and self.registeredTasks[id] == instance then
        return true
    end
    local job = self.reconciliation
    return job and not job.panelOnly and job.registry == self.context.serviceRuntime and job.ids[id] == nil
end

--- Check the owner table against what is loaded; returns a message, or nil.
--- Every legacy item needs a declared bound for scheduler accounting; every new
--- item needs a registered task. `new` mode needs all items owned by the scheduler.
---@param context table
---@param panelsVerified? boolean The same ready call already synchronized their contracts.
---@return string?
function host:verify(context, panelsVerified)
    if self.mode == "legacy" then
        return nil
    end
    local function problem(key, bound, idle, instance)
        local owner = self.owners[key]
        if owner ~= "legacy" and owner ~= "new" then
            return key .. " has no owner"
        elseif owner == "new" then
            return not idle
                    and not self.scheduler.byId[key]
                    and not pendingService(self, instance, key)
                    and key .. " is owned by the scheduler but has no task"
                or nil
        elseif self.mode == "new" then
            return key .. " is not owned by the scheduler"
        elseif not bound then
            return key .. " has no declared bound"
        end
    end
    local order, persistent = serviceRegistry(context)
    for index = 1, #order + (persistent and 1 or 0) do
        local instance = order[index] or persistent
        if not persistent or instance.id ~= "flight" or instance == persistent then
            if instance.schedulerTasks then
                for _, item in ipairs(instance.schedulerTasks) do
                    local task = item.instance
                    local owner = self.owners[item.id]
                    if not schedulerOwned(self, item.id) and owner ~= "legacy" then
                        return item.id .. " has no owner"
                    elseif schedulerOwned(self, item.id) then
                        if
                            instance.count > 0
                            and (task.want or 0) > 0
                            and not self.scheduler.byId[item.id]
                            and not pendingService(self, instance, item.id)
                        then
                            return item.id .. " is owned by the scheduler but has no task"
                        end
                    elseif self.mode == "new" then
                        return item.id .. " is not owned by the scheduler"
                    elseif not self.serviceBounds[instance.id] then
                        return item.id .. " has no declared bound"
                    end
                end
            else
                local message =
                    problem("service:" .. instance.id, self:serviceBound(instance), instance.count == 0, instance)
                if message then
                    return message
                end
            end
        end
    end
    for _, entry in ipairs(context.panels) do
        local key = "panel:" .. entry.module.id
        local owner = self.owners[key]
        local task = self.panelTasks[entry]
        local pending = self.pendingPanels and self.pendingPanels[entry]
            or self.reconciliation
                and self.reconciliation.panels == context.panels
                and not self.reconciliation.panelsPresent[entry]
        local message
        if owner == "new" then
            local idle = panelsVerified and self.idlePanels[entry]
                or not panelsVerified
                    and rawget(entry.module, "idle") == true
                    and context.panelHost.isIdle(entry.module)
            if not idle and not entry.failed and not pending and (not task or not self.scheduler.byId[task.id]) then
                message = key .. " is owned by the scheduler but has no task"
            end
        else
            message = problem(key, self.panelBounds[entry.module.id])
        end
        if message then
            return message
        end
    end
    return nil
end

--- Preserve releases of surviving placements through editor changes and service
--- subscription changes. Retire removed placements before their boxes are reused.
--- Enroll at most one placement per callback; declarations are validated at add.
---@param context table
---@return string?
function host:syncPanels(context)
    local present, idlePanels = {}, {}
    if next(self.idlePanels) then
        self.panelSetup = host.PANEL_ENROLL_COST
    end
    for _, entry in ipairs(context.panels) do
        self.panelEntries[entry] = true
        if self.owners["panel:" .. entry.module.id] == "new" and not entry.failed then
            if type(entry.instance) ~= "table" then
                return "panel:" .. entry.module.id .. " is owned by the scheduler but has no task instance"
            end
            local idle = rawget(entry.module, "idle") == true
            if idle and not context.panelHost.isIdle(entry.module) then
                return "panel:" .. entry.module.id .. " declares idle but has periodic work"
            end
            present[entry] = idle and "idle" or true
            if idle then
                self.panelSetup = host.PANEL_ENROLL_COST
                idlePanels[entry] = true
            end
            rawset(entry.instance, "schedulerOwned", true)
        elseif type(entry.instance) == "table" then
            rawset(entry.instance, "schedulerOwned", nil)
        end
    end
    for entry in pairs(self.pendingPanels or {}) do
        if not present[entry] then
            rawset(entry.instance, "schedulerOwned", nil)
        end
    end
    for entry in pairs(self.idlePanels) do
        if not present[entry] then
            rawset(entry.instance, "schedulerOwned", nil)
        end
    end
    for entry, task in pairs(self.panelTasks) do
        if not present[entry] or present[entry] == "idle" then
            self.scheduler:remove(task.id)
            rawset(entry.instance, "schedulerOwned", present[entry] and true or nil)
            self.panelTasks[entry] = nil
        end
    end
    local enrolled, pending = false, {}
    for _, entry in ipairs(context.panels) do
        if present[entry] == true and not self.panelTasks[entry] then
            if enrolled then
                pending[entry] = true
            else
                self.panelSetup = host.PANEL_ENROLL_COST
                local ok, task = pcall(context.panelHost.task, entry)
                if not ok then
                    return "panel:"
                        .. entry.module.id
                        .. " is owned by the scheduler but has no task: "
                        .. tostring(task)
                end
                task.id = "panel:" .. entry.placement.id
                local accepted, reason = self.scheduler:add({
                    id = task.id,
                    decl = task.decl,
                    instance = task,
                    due = entry.nextRefresh,
                })
                if not accepted then
                    return task.id .. ": " .. reason
                end
                self.panelTasks[entry] = task
                enrolled = true
            end
        end
    end
    self.pendingPanels = next(pending) and pending or nil
    self.idlePanels = idlePanels
end

--- A new layout or service registry replaces the service instances: drop the tasks
--- of the old ones and wait for subscribers to the new ones.
---@param context table
function host:resync(context)
    local order, persistent = serviceRegistry(context)
    local waiting, registered = {}, {}
    local surviving = {}
    for _, instance in ipairs(order) do
        if not persistent or instance.id ~= "flight" then
            surviving[instance] = true
        end
    end
    if persistent then
        surviving[persistent] = true
    end
    for id, instance in pairs(self.registeredTasks) do
        if surviving[instance] and schedulerOwned(self, id) and not instance.failed and self.scheduler.byId[id] then
            registered[id] = instance
        else
            self.scheduler:remove(id)
        end
    end
    for index = 1, #order + (persistent and 1 or 0) do
        local instance = order[index] or persistent
        if not persistent or instance.id ~= "flight" or instance == persistent then
            local key = "service:" .. instance.id
            if instance.schedulerTasks then
                for taskIndex, item in ipairs(instance.schedulerTasks) do
                    if schedulerOwned(self, item.id) and registered[item.id] ~= instance then
                        waiting[#waiting + 1] = {
                            instance = instance,
                            task = item.instance,
                            id = item.id,
                            critical = item.critical,
                            persistent = instance == persistent,
                            -- Preserve the pre-refactor single-task stagger.
                            index = instance.tasks and instance.tasks.run == item.instance and index - 1
                                or (index - 1) * 3 + taskIndex - 1,
                        }
                        registered[item.id] = instance
                    end
                end
            elseif self.owners[key] == "new" and registered[key] ~= instance then
                waiting[#waiting + 1] = { instance = instance, task = instance, id = key, index = index - 1 }
                registered[key] = instance
            end
        end
    end
    local resetReleases, resetOwners = {}, {}
    self.waiting, self.pendingServices = waiting, {}
    for _, item in ipairs(waiting) do
        self.pendingServices[item.id] = item.instance
        if self.registeredTasks[item.id] == item.instance then
            resetReleases[item.id] = self.resetReleases[item.id]
            resetOwners[item.id] = self.resetOwners[item.id]
        end
    end
    self.enrollCursor = #waiting
    self.registeredTasks = registered
    self.resetReleases = resetReleases
    self.resetOwners = resetOwners
end

--- Release at most one service task after a session reset.
---@return integer? nextIndex
---@return string? message
function host:resetServiceRelease(instance, now, index)
    if not self.scheduler then
        return
    end
    local item = instance.schedulerTasks and instance.schedulerTasks[index]
    if instance.schedulerTasks and not item or not instance.schedulerTasks and index > 1 then
        return
    end
    local id = item and item.id or "service:" .. instance.id
    if schedulerOwned(self, id) then
        if instance.failed then
            self.scheduler:remove(id)
            self.resetReleases[id], self.resetOwners[id] = nil, nil
        elseif self.registeredTasks[id] == instance and self.scheduler:dueOf(id) ~= nil then
            local ok, message = self.scheduler:reschedule(id, now)
            if not ok then
                return nil, id .. ": reset release: " .. message
            end
        else
            self.resetReleases[id] = now
            self.resetOwners[id] = instance
        end
    end
    if instance.schedulerTasks and instance.schedulerTasks[index + 1] then
        return index + 1
    end
end

--- Cancel a captured frame and publish its new stage before waking its release.
---@return string? message
function host:resetPanelRelease(entry, now)
    if not self.scheduler or self.owners["panel:" .. entry.module.id] ~= "new" then
        return
    end
    local task = self.panelTasks[entry]
    if not entry.failed then
        local ok, message = self.context.panelHost.dispatch(entry, "cancelRefresh")
        if not ok then
            if task then
                self.scheduler:remove(task.id)
            end
            return entry.placement.id .. ": reset cancellation: " .. tostring(message)
        end
    end
    if entry.failed then
        if task then
            self.scheduler:remove(task.id)
        end
        return
    end
    entry.nextRefresh = now
    if task then
        if entry.module.stageOf then
            task.stage, task.want = entry.module.stageOf(entry.instance)
        end
        local ok, message = self.scheduler:reschedule(task.id, now)
        if not ok then
            return task.id .. ": reset release: " .. message
        end
    end
end

--- Examine at most one waiting service and register at most one task per callback.
--- Dormant subscriptions keep their round-robin place until they have demand.
---@return string?
function host:enroll()
    if self.panelSetup > 0 then
        return nil
    end
    local waiting, scheduler = self.waiting, self.scheduler
    local position = self.enrollCursor or #waiting
    if position < 1 or position > #waiting then
        position = #waiting
    end
    if position > 0 then
        local item = waiting[position]
        local instance = item.instance
        local task = item.task
        self.enrollCursor = position - 1
        if instance.count > 0 and not instance.failed and (task.want == nil or task.want > 0) then
            self.panelSetup = host.SERVICE_ENROLL_COST
            -- The service step may need the same wrap-safe time comparison.
            task.tickElapsed = scheduler.elapsed
            local interval = task.interval or instance.interval
            local due = self.resetReleases[item.id]
                or getTime() + (item.critical and 0 or scheduler.stagger(item.index, interval))
            local ok, reason = scheduler:add({
                id = item.id,
                decl = serviceDeclaration(self, task.decl, item.persistent),
                instance = task,
                due = due,
            })
            if not ok then
                return item.id .. ": " .. reason
            end
            if position < #waiting then
                waiting[position] = waiting[#waiting]
            end
            waiting[#waiting] = nil
            self.pendingServices[item.id] = nil
            self.resetReleases[item.id] = nil
            self.resetOwners[item.id] = nil
        end
    end
    return nil
end

local function serviceProblem(self, instance, item)
    local id = item and item.id or "service:" .. instance.id
    local owner = self.owners[id]
    if not schedulerOwned(self, id) and owner ~= "legacy" then
        return id .. " has no owner"
    elseif not schedulerOwned(self, id) then
        if self.mode == "new" then
            return id .. " is not owned by the scheduler"
        elseif not (item and self.serviceBounds[instance.id] or not item and self:serviceBound(instance)) then
            return id .. " has no declared bound"
        end
    end
end

--- A panel-only job keeps every reconciled service task, its waiting enrollment
--- and reset releases; only the placement set is reconciled.
local function beginReconciliation(self, context, order, persistent, revision, panelOnly)
    if not panelOnly then
        self.waiting, self.pendingServices = {}, {}
        self.enrollCursor = 0
    end
    self.panelQueue, self.panelCursor, self.pendingPanels = {}, 1, nil
    self.reconciliation = {
        panels = context.panels,
        registry = context.serviceRuntime,
        services = #order,
        revision = revision,
        order = order,
        persistent = persistent,
        phase = panelOnly and "panels" or "services",
        index = panelOnly and 1 or 0,
        taskIndex = 1,
        ids = {},
        panelsPresent = {},
        panelOnly = panelOnly,
        -- Dormant facades whose later demand needs a service scan.
        dormant = panelOnly and self.dormant or {},
    }
    if panelOnly then
        -- Without a scheduler-owned panel type, an unscanned placement cannot hold a task.
        local owned = next(self.panelTasks) ~= nil
        for key, owner in pairs(self.owners) do
            if owned then
                break
            end
            owned = owner == "new" and string.sub(key, 1, 6) == "panel:"
        end
        self.reconciliation.servicesLive = not owned
    end
    context.panelTasksDirty = nil
end

local function reconcileService(self, job)
    local instance = job.index == 0 and job.persistent or job.order[job.index]
    if not instance then
        if job.index == 0 then
            job.phase, job.remaining = "broker-enroll", #self.waiting
        else
            job.phase, job.cursor = "retire-services", nil
        end
        return
    end
    if job.persistent and instance.id == "flight" and instance ~= job.persistent then
        job.index, job.taskIndex = job.index + 1, 1
        return
    end
    local item = instance.schedulerTasks and instance.schedulerTasks[job.taskIndex]
    if instance.schedulerTasks and not item or not instance.schedulerTasks and job.taskIndex > 1 then
        if job.index == 0 then
            job.phase, job.remaining = "broker-enroll", #self.waiting
        else
            job.index, job.taskIndex = job.index + 1, 1
        end
        return
    end
    local message = serviceProblem(self, instance, item)
    if message then
        return message
    end
    local id, task = item and item.id or "service:" .. instance.id, item and item.instance or instance
    if job.persistent and job.ids[id] == job.persistent and not instance.schedulerTasks and instance.count == 0 then
        job.dormant[#job.dormant + 1] = instance
        job.index, job.taskIndex = job.index + 1, 1
        return
    end
    if job.ids[id] then
        return id .. " is registered more than once"
    end
    job.ids[id] = instance
    if schedulerOwned(self, id) and not instance.failed then
        local previous, record = self.registeredTasks[id], self.scheduler.byId[id]
        if previous ~= instance or record and record.instance ~= task then
            self.scheduler:remove(id)
            if self.resetOwners[id] and self.resetOwners[id] ~= instance then
                self.resetReleases[id] = nil
                self.resetOwners[id] = nil
            end
            record = nil
        end
        self.registeredTasks[id] = instance
        if not record then
            self.waiting[#self.waiting + 1] = {
                id = id,
                instance = instance,
                task = task,
                critical = item and item.critical,
                persistent = instance == job.persistent,
                index = instance.tasks and instance.tasks.run == task and math.max(0, job.index - 1)
                    or math.max(0, job.index - 1) * 3 + job.taskIndex - 1,
            }
            self.pendingServices[id] = instance
        end
    end
    job.taskIndex = job.taskIndex + 1
end

local function reconcilePanel(self, context, job)
    local entry = job.panels[job.index]
    if not entry then
        job.phase, job.cursor = "retire-panels", nil
        return
    end
    local key = "panel:" .. entry.module.id
    local owner = self.owners[key]
    local idle = rawget(entry.module, "idle") == true
    self.panelEntries[entry], job.panelsPresent[entry] = true, true
    if owner == "new" then
        if type(entry.instance) ~= "table" then
            return key .. " is owned by the scheduler but has no task instance"
        elseif idle and not context.panelHost.isIdle(entry.module) then
            return key .. " declares idle but has periodic work"
        end
        rawset(entry.instance, "schedulerOwned", not entry.failed and true or nil)
        local task = self.panelTasks[entry]
        if idle or entry.failed then
            if task then
                self.scheduler:remove(task.id)
                self.panelTasks[entry] = nil
            end
            self.idlePanels[entry] = idle and not entry.failed and true or nil
        else
            self.idlePanels[entry] = nil
            if not task or not self.scheduler.byId[task.id] then
                self.panelQueue[#self.panelQueue + 1] = entry
                self.pendingPanels = self.pendingPanels or {}
                self.pendingPanels[entry] = true
            end
        end
    else
        if type(entry.instance) == "table" then
            rawset(entry.instance, "schedulerOwned", nil)
        end
        local task = self.panelTasks[entry]
        if task then
            self.scheduler:remove(task.id)
            self.panelTasks[entry] = nil
        end
        self.idlePanels[entry] = nil
        if owner ~= "legacy" then
            return key .. " has no owner"
        elseif self.mode == "new" then
            return key .. " is not owned by the scheduler"
        elseif not self.panelBounds[entry.module.id] then
            return key .. " has no declared bound"
        end
    end
    job.index = job.index + 1
end

local function advanceReconciliation(self, context)
    local job = self.reconciliation
    if job.phase == "services" then
        return reconcileService(self, job)
    elseif job.phase == "broker-enroll" then
        if job.remaining > 0 then
            local message = self:enroll()
            if message then
                return message
            end
            job.remaining = job.remaining - 1
            if job.remaining > 0 then
                return
            end
        end
        self.reconciledBroker = job.persistent
        job.index, job.taskIndex, job.phase = 1, 1, "services"
    elseif job.phase == "retire-services" then
        local id, instance = next(self.registeredTasks, job.cursor)
        job.cursor = id
        if not id then
            job.phase, job.cursor = "retire-resets", nil
        elseif job.ids[id] ~= instance or instance.failed or not schedulerOwned(self, id) then
            self.scheduler:remove(id)
            self.registeredTasks[id], self.pendingServices[id], self.resetReleases[id] = nil, nil, nil
            self.resetOwners[id] = nil
        end
    elseif job.phase == "retire-resets" then
        local id, instance = next(self.resetOwners, job.cursor)
        job.cursor = id
        if not id then
            job.phase, job.index = "panels", 1
        elseif job.ids[id] ~= instance then
            self.resetOwners[id], self.resetReleases[id] = nil, nil
        end
    elseif job.phase == "panels" then
        return reconcilePanel(self, context, job)
    elseif job.phase == "retire-panels" then
        local entry = next(self.panelEntries, job.cursor)
        job.cursor = entry
        if not entry then
            self.checked, self.registry, self.taskRevision = job.panels, job.registry, job.revision
            self.persistent, self.services, self.dormant = job.persistent, job.services, job.dormant
            self.reconciliation = nil
        elseif not job.panelsPresent[entry] then
            local task = self.panelTasks[entry]
            if task then
                self.scheduler:remove(task.id)
            end
            if type(entry.instance) == "table" then
                rawset(entry.instance, "schedulerOwned", nil)
            end
            self.panelEntries[entry], self.panelTasks[entry], self.idlePanels[entry] = nil, nil, nil
        end
    end
end

local function enrollPanel(self, context)
    local entry = self.panelQueue[self.panelCursor]
    if not entry then
        self.pendingPanels = nil
        return
    end
    self.panelSetup = host.PANEL_ENROLL_COST
    local ok, task = pcall(context.panelHost.task, entry)
    if not ok then
        return "panel:" .. entry.module.id .. " is owned by the scheduler but has no task: " .. tostring(task)
    end
    task.id = "panel:" .. entry.placement.id
    local accepted, reason =
        self.scheduler:add({ id = task.id, decl = task.decl, instance = task, due = entry.nextRefresh })
    if not accepted then
        return task.id .. ": " .. reason
    end
    self.panelTasks[entry] = task
    self.pendingPanels[entry] = nil
    self.panelCursor = self.panelCursor + 1
    if self.panelCursor > #self.panelQueue then
        self.pendingPanels = nil
    end
end

--- True when the host can run this callback. A failed check is logged and the
--- caller uses the legacy path for unowned work while retaining scheduled tasks.
---@param context table
---@return boolean
function host:ready(context)
    self.panelSetup = 0
    local telemetry = context.serviceRuntime and context.serviceRuntime.byId.telemetry
    local taskRevision = telemetry and telemetry.schedulerRevision or 0
    local order, persistent = serviceRegistry(context)
    if not self.scheduler then
        self.checked, self.registry, self.taskRevision, self.persistent =
            context.panels, context.serviceRuntime, taskRevision, persistent
        self.services = #order
        context.panelTasksDirty = nil
        return true
    end
    local job = self.reconciliation
    local snapshot = job
        or {
            panels = self.checked,
            registry = self.registry,
            services = self.services,
            revision = self.taskRevision,
            persistent = self.persistent,
        }
    local changed = snapshot.panels ~= context.panels
        or snapshot.registry ~= context.serviceRuntime
        or context.panelTasksDirty
        or snapshot.revision ~= taskRevision
        or snapshot.persistent ~= persistent
    if job and job.panelOnly and not changed then
        -- Service growth or dormant demand after panel-only work began needs a full scan.
        changed = job.services ~= #order
        for index = 1, #job.dormant do
            changed = changed or job.dormant[index].count ~= 0
        end
    end
    if not changed and not job and not self.pendingPanels and self.waiting[1] == nil then
        return true
    end
    local message
    if self.scheduler then
        if changed then
            -- Services stay reconciled only when no service job is unfinished.
            local panelOnly = (not job or job.panelOnly)
                and snapshot.panels == context.panels
                and snapshot.registry == context.serviceRuntime
                and snapshot.services == #order
                and snapshot.revision == taskRevision
                and snapshot.persistent == persistent
                and self.reconciledBroker == persistent
            for index = 1, panelOnly and #self.dormant or 0 do
                panelOnly = panelOnly and self.dormant[index].count == 0
            end
            beginReconciliation(self, context, order, persistent, taskRevision, panelOnly)
        end
        if self.reconciliation then
            self.panelSetup = host.RECONCILE_COST
            if self.reconciliation.phase == "broker-enroll" then
                self.panelSetup = 0
            end
            message = advanceReconciliation(self, context)
            self.panelSetup = math.max(self.panelSetup, host.RECONCILE_COST)
        elseif self.pendingPanels then
            message = enrollPanel(self, context)
        else
            message = self:enroll()
        end
    end
    if message then
        self.api.log(context, "scheduler: " .. message .. "; using legacy fallback for unowned work")
        return false
    end
    return true
end

--- Add the declared cost of head work that ran (`reset` or `tick`).
---@param what string
function host:charge(what)
    self.head = self.head + self.headCosts[what]
end

--- Start the scheduled part of a callback. Returns legacy accounting, or nil
--- when the host only observes the legacy loop (`legacy` mode).
---@param kind string
---@return table? legacy accounting
function host:begin(kind)
    self.active = true
    self.legacy.panelRoom = nil
    self.legacy.spent = self.panelSetup
    if self.probe then
        self.probe:before(kind, getTime(), self.head, self.mode == "legacy")
    end
    if self.mode ~= "legacy" then
        return self.legacy
    end
end

--- The legacy loop served `instance`.
---@param instance table
function host:served(instance)
    if self.active then
        local bound = self:serviceBound(instance) or 0
        self.legacy.spent = self.legacy.spent + bound
        if self.probe then
            self.probe:ran("service:" .. instance.id, bound)
        end
    end
end

--- Finish the callback: the framework plans and runs its tasks with the head work
--- and declared legacy cost as `used`.
---@param kind string
function host:finish(kind)
    self.active = false
    local plan
    local _, persistent = serviceRegistry(self.context)
    local job = self.reconciliation
    -- Reconciled services keep their kind while no possibly stale panel task exists.
    local reconciling = job and not job.servicesLive
    if self.scheduler and (not reconciling or persistent and persistent == self.reconciledBroker) then
        self.scheduler:run(reconciling and RECONCILE_KIND or kind, getTime(), self.head + self.legacy.spent)
        plan = self.scheduler.lastPlan.U
    end
    if self.probe then
        self.probe:after(kind, plan, self.head)
    end
end

--- Report tasks the framework retired. They are reported at the head of the next
--- callback, which then counts as consumed. Returns true when it did.
---@param context table
---@return boolean
function host:report(context)
    local errors = self.scheduler and self.scheduler:takeErrors()
    if not errors then
        return false
    end
    for _, item in ipairs(errors) do
        self.api.error(context, "scheduler: " .. tostring(item.id) .. ": " .. item.message)
        -- A service that failed is retired for good, as in the legacy loop.
        local id = type(item.id) == "string" and string.match(item.id, "^service:(.+)$")
        local instance = self.registeredTasks[item.id]
            or id and context.serviceRuntime and context.serviceRuntime.byId[id]
        for entry, task in pairs(self.panelTasks) do
            if task.id == item.id then
                entry.failed, entry.error = true, item.message
                self.panelTasks[entry] = nil
                rawset(entry.instance, "schedulerOwned", nil)
            end
        end
        if instance then
            instance.failed = true
            for taskId, owner in pairs(self.registeredTasks) do
                if owner == instance then
                    self.scheduler:remove(taskId)
                    self.registeredTasks[taskId] = nil
                    self.resetReleases[taskId], self.resetOwners[taskId] = nil, nil
                end
            end
            for index = #self.waiting, 1, -1 do
                if self.waiting[index].instance == instance then
                    local taskId = self.waiting[index].id
                    self.pendingServices[taskId], self.resetReleases[taskId], self.resetOwners[taskId] = nil, nil, nil
                    table.remove(self.waiting, index)
                end
            end
        end
    end
    self.api.show(context)
    return true
end

return host
