-- SPDX-License-Identifier: GPL-2.0-only

--- Instruction estimates from lib/instruction_snapshot.lua. Modules with costs
--- export `bindCosts(costs)`; the module loader calls it, and a missing estimate
--- fails the load instead of falling back to a default.

local costs = { RUNTIME_API = 1 }
costs.__index = costs

local function missing(group, key)
    error("instruction snapshot has no estimate for " .. group .. "." .. tostring(key), 0)
end

--- `snapshot` is the snapshot chunk; only its estimates are retained.
---@param snapshot function
function costs.new(snapshot)
    local estimates = snapshot("estimates")
    return setmetatable({ tasks = estimates.tasks, bounds = estimates.bounds }, costs)
end

--- Fill `fixed` and `perUnit` of every stage of `decl` from task `name`.
function costs:stages(name, decl)
    local task = self.tasks[name] or missing("tasks", name)
    for stage, declared in pairs(decl.stages) do
        local estimate = task[stage] or missing("tasks." .. name, stage)
        declared.fixed, declared.perUnit = estimate.fixed, estimate.perUnit
    end
    return decl
end

--- The bounds of `group` named by `keys`, as a new table.
function costs:group(group, keys)
    local values = self.bounds[group] or missing("bounds", group)
    local result = {}
    for _, key in ipairs(keys) do
        result[key] = values[key] or missing("bounds." .. group, key)
    end
    return result
end

--- One bound.
function costs:bound(group, key)
    local values = self.bounds[group] or missing("bounds", group)
    return values[key] or missing("bounds." .. group, key)
end

--- Whether every stage of `decl` carries its own integer estimates.
local function selfCosted(decl)
    for _, stage in pairs(decl.stages) do
        if math.type(stage.fixed) ~= "integer" or math.type(stage.perUnit) ~= "integer" then
            return false
        end
    end
    return true
end

--- A panel's task stages and its reflow bound, when it declares them. A panel
--- the snapshot does not know (not shipped with AeroGrid) may declare its own.
function costs:panel(name, module)
    local decl = rawget(module, "decl")
    local task = "panel." .. name
    if decl and (self.tasks[task] or not selfCosted(decl)) then
        self:stages(task, decl)
    end
    local reflow = rawget(module, "reflowDecl")
    if reflow and (self.bounds["panel-reflow"][name] or math.type(reflow.bound) ~= "integer") then
        reflow.bound = self:bound("panel-reflow", name)
    end
end

--- Bind a freshly loaded module from `relative` (for example "panels/metric.lua").
function costs:bind(relative, module)
    if type(module) ~= "table" then
        return module
    end
    local panel = string.match(relative, "^panels/(.+)%.lua$")
    if panel then
        self:panel(panel, module)
    end
    local bind = rawget(module, "bindCosts")
    if bind then
        bind(self)
    end
    return module
end

return costs
