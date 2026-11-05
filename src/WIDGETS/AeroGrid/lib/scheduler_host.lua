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

--- The one owner of every task: `service:<id>` for a service update and
--- `panel:<type>` for a panel's refresh (the chart's stages included). Flipping a
--- task to `new` is a one-line change, and it needs a task registered under the
--- same id: a service carries its `decl` and `step` and the host registers it once
--- it has subscribers (`host:enroll`); the others use `host.scheduler:add`. Modal
--- callbacks also run migrated service tasks through the scheduler.
host.OWNERS = {
    ["service:telemetry"] = "legacy",
    ["service:model"] = "new",
    ["service:control"] = "legacy",
    ["service:flight"] = "legacy",
    ["service:armed"] = "legacy",
    ["service:navigation"] = "legacy",
    ["service:history"] = "legacy",
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

--- Declared bounds of one legacy service update (plans/scheduler-contracts.md);
--- telemetry's depends on how many sources it polls in one update.
host.SERVICE_BOUNDS = {
    telemetry = function(instance)
        return 750 + 1180 * math.min(instance.count, instance.pollCap or 8)
    end,
    model = declared,
    control = 2620,
    navigation = 710,
    history = 650,
    smart = 2600,
    flight = 0,
    armed = 0,
}

host.SERVICE_CLASS = { telemetry = "critical", history = "critical", control = "critical" }

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
host.OVERHEAD = { steady = 1250, background = 1130 }

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
        active = false,
        waiting = {},
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

---@param instance table Registered service.
---@return integer? bound Declared cost of one update, nil when there is none.
function host:serviceBound(instance)
    local bound = self.serviceBounds[instance.id]
    if type(bound) == "function" then
        return bound(instance)
    end
    return bound
end

--- Check the owner table against what is loaded; returns a message, or nil.
--- Every legacy item needs a declared bound for scheduler accounting; every new
--- item needs a registered task. `new` mode needs all items owned by the scheduler.
---@param context table
---@return string?
function host:verify(context)
    if self.mode == "legacy" then
        return nil
    end
    local function problem(key, bound, idle)
        local owner = self.owners[key]
        if owner ~= "legacy" and owner ~= "new" then
            return key .. " has no owner"
        elseif owner == "new" then
            return not idle and not self.scheduler.byId[key] and key .. " is owned by the scheduler but has no task"
                or nil
        elseif self.mode == "new" then
            return key .. " is not owned by the scheduler"
        elseif not bound then
            return key .. " has no declared bound"
        end
    end
    for _, instance in ipairs(context.serviceRuntime and context.serviceRuntime.order or {}) do
        local message = problem("service:" .. instance.id, self:serviceBound(instance), instance.count == 0)
        if message then
            return message
        end
    end
    for _, entry in ipairs(context.panels) do
        local message = problem("panel:" .. entry.module.id, self.panelBounds[entry.module.id])
        if message then
            return message
        end
    end
    return nil
end

--- A new layout or service registry replaces the service instances: drop the tasks
--- of the old ones and wait for subscribers to the new ones.
---@param context table
function host:resync(context)
    local waiting = {}
    for index, instance in ipairs(context.serviceRuntime and context.serviceRuntime.order or {}) do
        local key = "service:" .. instance.id
        if self.owners[key] == "new" then
            self.scheduler:remove(key)
            waiting[#waiting + 1] = { instance = instance, index = index - 1 }
        end
    end
    self.waiting = waiting
end

--- Register the task of every service the scheduler owns once it has subscribers: a
--- service nothing reads is not scheduled, and a panel the editor adds later
--- subscribes after the load. Returns a message when the scheduler refuses a task.
---@return string?
function host:enroll()
    local waiting, scheduler = self.waiting, self.scheduler
    for position = #waiting, 1, -1 do
        local item = waiting[position]
        local instance = item.instance
        if instance.count > 0 and not instance.failed then
            table.remove(waiting, position)
            -- The service step may need the same wrap-safe time comparison.
            instance.tickElapsed = scheduler.elapsed
            local ok, reason = scheduler:add({
                id = "service:" .. instance.id,
                decl = instance.decl,
                instance = instance,
                due = getTime() + scheduler.stagger(item.index, instance.interval),
            })
            if not ok then
                return "service:" .. instance.id .. ": " .. reason
            end
        end
    end
    return nil
end

--- True when the host can run this callback. A failed check is logged and the
--- caller uses the legacy path for unowned work while retaining scheduled tasks.
---@param context table
---@return boolean
function host:ready(context)
    local changed = self.checked ~= context.panels or self.registry ~= context.serviceRuntime
    if not changed and self.waiting[1] == nil then
        return true
    end
    local message
    if self.scheduler then
        if changed then
            self:resync(context)
        end
        message = self:enroll()
    end
    message = message or (changed and self:verify(context))
    if message then
        self.api.log(context, "scheduler: " .. message .. "; using legacy fallback for unowned work")
        return false
    end
    self.checked, self.registry = context.panels, context.serviceRuntime
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
    self.legacy.spent = 0
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
    if self.scheduler then
        self.scheduler:run(kind, getTime(), self.head + self.legacy.spent)
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
        local instance = id and context.serviceRuntime and context.serviceRuntime.byId[id]
        if instance then
            instance.failed = true
        end
    end
    self.api.show(context)
    return true
end

return host
