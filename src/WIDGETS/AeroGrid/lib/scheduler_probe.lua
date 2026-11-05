-- SPDX-License-Identifier: GPL-2.0-only

--- Development tooling for the scheduler (plans/scheduler-framework.md, section 6).
--- It changes no behavior and is loaded only by the host when `SCHEDULER_PROBE`
--- is on; releases never load it.
---
--- Tripwire. Each callback leaves a record: the plan's upper bound `U`, or none
--- when the callback skipped the scheduler. The next callback reads `getUsage`,
--- which reports the callback before it, and flags `usage > floor(U / 200)`. It is
--- a gross-error check: `U` is a sum of padded bounds. Until the native simulator
--- confirms which callback `getUsage` reports when `refresh` and `background`
--- interleave it only records (`armed` is false).
---
--- Shadow mode (host mode `legacy`). The legacy loop keeps full control. Before
--- it runs, the probe asks the planner which of the ready tasks it would run;
--- afterwards it sums the declared cost of what the legacy loop ran, so that the
--- tripwire can check the declared table, and notes where the two differ.

local probe = {}
probe.__index = probe

local LIMIT, LOG_LIMIT = 64, 8

---@param host table
---@param scheduler table The scheduler library, for the shadow plans.
---@param options? table `usage` (default `getUsage`), `armed`
---@return table
function probe.new(host, scheduler, options)
    options = options or {}
    return setmetatable({
        host = host,
        scheduler = scheduler,
        usage = options.usage or (type(getUsage) == "function" and getUsage) or nil,
        armed = options.armed or false,
        nearMisses = {},
        differences = {},
        names = {},
        declared = 0,
        logged = 0,
    }, probe)
end

local function remember(list, item)
    if #list >= LIMIT then
        table.remove(list, 1)
    end
    list[#list + 1] = item
end

-- The ready legacy items as planner tasks. A step only names its task.
local function shadowPlan(self, kind, now, used)
    local host, context = self.host, self.host.context
    local s = self.scheduler.new(host.overhead)
    local chosen = {}
    local function add(key, class, bound, due, exclusive, kinds)
        local task = {
            id = key,
            due = due,
            instance = {
                step = function()
                    chosen[#chosen + 1] = key
                    return 10
                end,
            },
            decl = {
                class = class,
                exclusive = exclusive,
                kinds = kinds,
                stages = { run = { fixed = 0, perUnit = math.max(1, bound), maxUnits = 1 } },
            },
        }
        local ok, reason = s:add(task)
        if not ok then
            remember(self.differences, { kind = kind, problem = key .. ": " .. reason })
        end
    end
    local registry = context.serviceRuntime
    for _, instance in ipairs(registry and registry.order or {}) do
        if not instance.failed and instance.count > 0 and now >= instance.due then
            add(
                "service:" .. instance.id,
                host.SERVICE_CLASS[instance.id] or "normal",
                host:serviceBound(instance) or 0,
                instance.due
            )
        end
    end
    if kind == "steady" then
        for _, entry in ipairs(context.panels) do
            local due = entry.nextRefresh or 0
            if not entry.failed and now >= due then
                local exclusive = (rawget(entry.module, "refreshCost") or 1) >= 6
                add(
                    "panel:" .. entry.placement.id,
                    "normal",
                    host.panelBounds[entry.module.id] or 0,
                    due,
                    exclusive,
                    { steady = true }
                )
            end
        end
    end
    s:run(kind, now, used)
    self.chosen, self.shadowCharge = chosen, s.lastPlan.charged
end

--- Start of a callback: check the previous one and clear the record, so that a
--- callback that never reaches `after` is recorded as "no plan".
function probe:start()
    local record = self.record
    self.record = nil
    local usage = self.usage and self.usage()
    if self.armed and record and type(usage) == "number" and usage > record // 200 then
        remember(self.nearMisses, { usage = usage, U = record })
        self.host.api.log(self.host.context, "scheduler: near-miss, usage " .. usage .. " quanta, bound " .. record)
    end
end

--- Before the callback's scheduled work. `shadow` asks for a shadow plan.
function probe:before(kind, now, used, shadow)
    self.names, self.declared, self.chosen, self.shadowCharge = {}, 0, nil, 0
    if shadow then
        shadowPlan(self, kind, now, used)
    end
end

--- The legacy loop ran one task of declared cost `bound`.
function probe:ran(key, bound)
    self.names[#self.names + 1] = key
    self.declared = self.declared + bound
end

--- After the callback's scheduled work. `U` is the framework's plan bound; in
--- `legacy` mode it is nil and the bound is what the legacy loop declared plus the
--- shadow plan's charge.
function probe:after(kind, U, used)
    local host = self.host
    self.record = U or host.overhead[kind] + used + self.declared + self.shadowCharge
    if self.chosen then
        table.sort(self.chosen)
        table.sort(self.names)
        local planner, legacy = table.concat(self.chosen, " "), table.concat(self.names, " ")
        if planner ~= legacy then
            remember(self.differences, { kind = kind, planner = planner, legacy = legacy })
            if self.logged < LOG_LIMIT then
                self.logged = self.logged + 1
                host.api.log(
                    host.context,
                    "scheduler shadow (" .. kind .. "): planner [" .. planner .. "], legacy [" .. legacy .. "]"
                )
            end
        end
    end
end

return probe
