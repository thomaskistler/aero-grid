-- SPDX-License-Identifier: GPL-2.0-only

--- Enroll services and panels in the instruction-budgeted scheduler.

local host = { RUNTIME_API = 1 }
host.__index = host
-- Unverified dashboard records retain deadlines but cannot run during reconciliation.
local RECONCILE_KIND = "host-reconcile"

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
--- Broker task ids a broker-only reconciliation may retire before services run.
host.BROKER_TASK_LIMIT = 4

--- Reset polling and one-time broker handoff run before scheduled work.
host.HEAD_COSTS = { reset = 620, handoff = 3600 }

--- Attach a host to `context`. `options`: `probe` (boolean), `load`
--- (relative path -> module) and `api` (`log`, `error`, `show` of main.lua).
---@param context table
---@param options table
---@return table host
function host.attach(context, options)
    local self = setmetatable({
        context = context,
        api = options.api,
        overhead = host.OVERHEAD,
        headCosts = host.HEAD_COSTS,
        head = 0,
        lastRun = getTime(),
        panelSetup = 0,
        waiting = {},
        pendingServices = {},
        registeredTasks = {},
        panelTasks = {},
        serviceDeclarations = setmetatable({}, { __mode = "k" }),
        brokerDeclarations = setmetatable({}, { __mode = "k" }),
        panelEntries = {},
        dormant = {},
        panelQueue = {},
        panelCursor = 1,
        resetReleases = {},
        resetOwners = {},
    }, host)

    self.scheduler = options.load("lib/scheduler.lua").new(self.overhead)
    if options.probe then
        self.probe = options.load("lib/scheduler_probe.lua").new(self)
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

local function serviceRegistry(context)
    local broker = context.flightFactory and context.flightFactory.broker
    local persistent = broker and broker.schedulerService and broker:schedulerService(context)
    return context.serviceRuntime and context.serviceRuntime.order or {}, persistent
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
    if instance.schedulerTasks and instance.schedulerTasks[index + 1] then
        return index + 1
    end
end

--- Cancel a captured frame and publish its new stage before waking its release.
---@return string? message
function host:resetPanelRelease(entry, now)
    if not self.scheduler then
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
        if self.pendingServices[item.id] ~= instance then
            -- A broker splice withdrew this claim; it can never be enrolled.
            waiting[position] = waiting[#waiting]
            waiting[#waiting] = nil
        elseif instance.count > 0 and not instance.failed and (task.want == nil or task.want > 0) then
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

local function serviceProblem(instance, item)
    local id = item and item.id or "service:" .. instance.id
    local task = item and item.instance or instance
    if instance.count > 0 and (type(task.decl) ~= "table" or type(task.step) ~= "function") then
        return id .. " has no scheduler task"
    end
end

--- Remove releases under `broker`'s task ids that `keep` does not own, so an
--- ordinary callback cannot run a replaced facade or broker task.
local function retireBrokerRecords(self, broker, keep)
    local items = broker and broker.schedulerTasks or {}
    for index = 1, #items do
        local id = items[index].id
        local record = self.scheduler.byId[id]
        if record and (self.registeredTasks[id] ~= keep or record.instance ~= items[index].instance) then
            self.scheduler:remove(id)
        end
    end
end

--- A panel-only job keeps every reconciled service task, its waiting enrollment
--- and reset releases; only the placement set is reconciled. A broker-only job
--- reconciles every service, but only broker task ids can be stale; their
--- releases are removed first, so reconciled services keep running.
local function beginReconciliation(self, context, order, persistent, revision, panelOnly, brokerOnly)
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
        brokerOnly = brokerOnly,
        -- Dormant facades whose later demand needs a service scan.
        dormant = panelOnly and self.dormant or {},
    }
    if panelOnly then
        self.reconciliation.servicesLive = #context.panels == 0 and next(self.panelTasks) == nil
    elseif brokerOnly then
        retireBrokerRecords(self, persistent, persistent)
        retireBrokerRecords(self, self.persistent, persistent)
        self.reconciliation.servicesLive = true
    end
    context.panelTasksDirty = nil
end

--- Retarget an unfinished full job to a newly activated or replaced broker without
--- rescanning services. Only the broker's bounded task ids can be affected: their
--- claims are withdrawn, the broker is scanned and enrolled, then the scan resumes.
--- Returns false when the change needs a full restart.
local function spliceBroker(self, context, order, persistent, revision)
    local job = self.reconciliation
    local previous = job.persistent
    if
        job.panelOnly
        or job.brokerOnly
        or job.phase ~= "services"
        or job.index < 1
        or not persistent
        or context.panelTasksDirty
        or job.panels ~= context.panels
        or job.registry ~= context.serviceRuntime
        or job.services ~= #order
        or job.revision ~= revision
        or #persistent.schedulerTasks + #(previous and previous.schedulerTasks or {}) > host.BROKER_TASK_LIMIT
    then
        return false
    end
    local claims = {}
    for _, broker in ipairs({ persistent, previous or persistent }) do
        for _, item in ipairs(broker.schedulerTasks) do
            local claimer = job.ids[item.id]
            if claimer and claimer ~= previous then
                if claimer.id ~= "flight" and (claimer.schedulerTasks or claimer.count ~= 0) then
                    return false
                end
                -- A facade claim becomes a skip or a dormant shadow under the broker.
                claims[#claims + 1] = claimer
            end
        end
    end
    for index = 1, #job.dormant do
        if job.dormant[index].count ~= 0 then
            return false
        end
    end
    for _, broker in ipairs({ persistent, previous or persistent }) do
        for _, item in ipairs(broker.schedulerTasks) do
            local id = item.id
            if job.ids[id] then
                job.ids[id] = nil
                self.pendingServices[id], self.registeredTasks[id] = nil, nil
            end
        end
    end
    retireBrokerRecords(self, persistent, persistent)
    retireBrokerRecords(self, previous, persistent)
    for index = 1, #claims do
        if claims[index].id ~= "flight" then
            job.dormant[#job.dormant + 1] = claims[index]
        end
    end
    job.persistent, job.resume = persistent, { index = job.index, taskIndex = job.taskIndex }
    job.index, job.taskIndex, job.mark = 0, 1, #self.waiting
    return true
end

local function reconcileService(self, job)
    local instance = job.index == 0 and job.persistent or job.order[job.index]
    if not instance then
        if job.index == 0 then
            job.phase, job.remaining = "broker-enroll", #self.waiting - (job.mark or 0)
            self.enrollCursor = job.mark and #self.waiting or self.enrollCursor
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
            job.phase, job.remaining = "broker-enroll", #self.waiting - (job.mark or 0)
            self.enrollCursor = job.mark and #self.waiting or self.enrollCursor
        else
            job.index, job.taskIndex = job.index + 1, 1
        end
        return
    end
    local message = serviceProblem(instance, item)
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
    if not instance.failed then
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
    local idle = rawget(entry.module, "idle") == true
    self.panelEntries[entry], job.panelsPresent[entry] = true, true
    if type(entry.instance) ~= "table" then
        return key .. " has no task instance"
    elseif idle and not context.panelHost.isIdle(entry.module) then
        return key .. " declares idle but has periodic work"
    end
    local task = self.panelTasks[entry]
    if idle or entry.failed then
        if task then
            self.scheduler:remove(task.id)
            self.panelTasks[entry] = nil
        end
    else
        if not task or not self.scheduler.byId[task.id] then
            self.panelQueue[#self.panelQueue + 1] = entry
            self.pendingPanels = self.pendingPanels or {}
            self.pendingPanels[entry] = true
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
        local resume = job.resume or { index = 1, taskIndex = 1 }
        job.index, job.taskIndex, job.phase = resume.index, resume.taskIndex, "services"
        job.resume, job.mark = nil, nil
    elseif job.phase == "retire-services" then
        local id, instance = next(self.registeredTasks, job.cursor)
        job.cursor = id
        if not id then
            job.phase, job.cursor = "retire-resets", nil
        elseif job.ids[id] ~= instance or instance.failed then
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
            self.panelEntries[entry], self.panelTasks[entry] = nil, nil
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

--- True when the host can run this callback. Invalid contracts are reported
--- without running unbudgeted fallback work.
---@param context table
---@return boolean
function host:ready(context)
    self.panelSetup = 0
    local telemetry = context.serviceRuntime and context.serviceRuntime.byId.telemetry
    local taskRevision = telemetry and telemetry.schedulerRevision or 0
    local order, persistent = serviceRegistry(context)
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
        or self.brokerDirty
        or snapshot.revision ~= taskRevision
        or snapshot.persistent ~= persistent
    if job and (job.panelOnly or job.brokerOnly) and not changed then
        -- Service growth or dormant demand after partial work began needs a full scan.
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
                and not self.brokerDirty
                and snapshot.panels == context.panels
                and snapshot.registry == context.serviceRuntime
                and snapshot.services == #order
                and snapshot.revision == taskRevision
                and snapshot.persistent == persistent
                and self.reconciledBroker == persistent
            for index = 1, panelOnly and #self.dormant or 0 do
                panelOnly = panelOnly and self.dormant[index].count == 0
            end
            local spliced = job
                and not self.brokerDirty
                and snapshot.persistent ~= persistent
                and spliceBroker(self, context, order, persistent, taskRevision)
            -- Only the broker changed: its bounded task ids are the only possibly stale releases.
            local previous = self.persistent
            local brokerOnly = not panelOnly
                and not self.brokerDirty
                and not job
                and not context.panelTasksDirty
                and snapshot.panels == context.panels
                and snapshot.registry == context.serviceRuntime
                and snapshot.services == #order
                and snapshot.revision == taskRevision
                and snapshot.persistent ~= persistent
                and self.reconciledBroker == previous
                and #(persistent and persistent.schedulerTasks or {})
                        + #(previous and previous.schedulerTasks or {})
                    <= host.BROKER_TASK_LIMIT
            for index = 1, brokerOnly and #self.dormant or 0 do
                brokerOnly = brokerOnly and self.dormant[index].count == 0
            end
            if not spliced then
                beginReconciliation(self, context, order, persistent, taskRevision, panelOnly, brokerOnly)
            end
            self.brokerDirty = nil
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
        self.api.error(context, "scheduler: " .. message)
        self.api.show(context)
        return false
    end
    return true
end

--- Add the declared cost of head work that ran.
---@param what string
function host:charge(what)
    self.head = self.head + self.headCosts[what]
end

--- Run tasks with head work, enrollment and bounded callback work reserved.
---@param kind string
---@param used? integer
function host:finish(kind, used)
    local plan
    local _, persistent = serviceRegistry(self.context)
    local job = self.reconciliation
    -- Reconciled services keep their kind while no possibly stale panel task exists.
    local reconciling = job and not job.servicesLive
    if self.scheduler and (not reconciling or persistent and persistent == self.reconciledBroker) then
        local now = getTime()
        self.scheduler:run(reconciling and RECONCILE_KIND or kind, now, self.head + self.panelSetup + (used or 0))
        self.lastRun = now
        plan = self.scheduler.lastPlan.U
    end
    if self.probe then
        self.probe:after(plan)
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
        -- A service that failed is retired for good.
        local id = type(item.id) == "string" and string.match(item.id, "^service:(.+)$")
        local instance = self.registeredTasks[item.id]
            or id and context.serviceRuntime and context.serviceRuntime.byId[id]
        for entry, task in pairs(self.panelTasks) do
            if task.id == item.id then
                entry.failed, entry.error = true, item.message
                self.panelTasks[entry] = nil
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
