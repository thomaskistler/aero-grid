-- SPDX-License-Identifier: GPL-2.0-only

-- A trivial stand-in for a task that is being migrated, used to show the parity
-- harness and the host's ownership flip without migrating a real task. It
-- consumes queued samples, up to four per update, into a sum.
local standin = {}

standin.INTERVAL = 20

-- One shared declaration, as for a real task type.
standin.decl = {
    class = "normal",
    stages = { run = { fixed = 100, perUnit = 300, maxUnits = 4 } },
}

-- The stand-in's declared legacy bound, for the host's table.
standin.LEGACY_BOUND = 100 + 300 * 4

--- A fresh task: a service for the registry (`update` is the legacy shim around
--- the extracted `step`) that the new scheduler can run directly.
---@param options? { due: integer? }
---@return table
function standin.new(options)
    local task = {
        id = "standin",
        interval = standin.INTERVAL,
        due = options and options.due or 0,
        count = 1,
        revision = 0,
        queue = {},
        consumed = 0,
        sum = 0,
        last = 0,
    }

    --- The extracted step: exactly the planned stage with at most `grant` samples.
    function task.step(self, grant, stage, now)
        if stage ~= "run" then
            return 1
        end
        local samples = math.min(grant, #self.queue)
        for _ = 1, samples do
            self.sum = self.sum + table.remove(self.queue, 1)
            self.consumed = self.consumed + 1
            self.last = now
        end
        self.used = samples
        return self.interval
    end

    --- The legacy loop's entry point calls the extracted step with the full cap.
    function task.update(self, now)
        self:step(standin.decl.stages.run.maxUnits, "run", now)
    end

    return task
end

--- The pre-migration code: what the old `update` did, written independently of `step`.
---@param task table
---@param now integer
function standin.old(task, now)
    for _ = 1, 4 do
        local sample = table.remove(task.queue, 1)
        if sample == nil then
            return
        end
        task.sum, task.consumed, task.last = task.sum + sample, task.consumed + 1, now
    end
end

---@param task table
---@return string
function standin.snapshot(task)
    return string.format("consumed=%d sum=%d last=%d queued=%d", task.consumed, task.sum, task.last, #task.queue)
end

return standin
