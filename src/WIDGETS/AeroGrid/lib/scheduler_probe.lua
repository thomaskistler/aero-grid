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

local probe = {}
probe.__index = probe

local LIMIT = 64

---@param host table
---@param options? table `usage` (default `getUsage`), `armed`
---@return table
function probe.new(host, options)
    options = options or {}
    return setmetatable({
        host = host,
        usage = options.usage or (type(getUsage) == "function" and getUsage) or nil,
        armed = options.armed or false,
        nearMisses = {},
    }, probe)
end

local function remember(list, item)
    if #list >= LIMIT then
        table.remove(list, 1)
    end
    list[#list + 1] = item
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

--- Record the scheduler's upper bound, or no plan when work was deferred.
function probe:after(U)
    self.record = U
end

return probe
