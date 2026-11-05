-- SPDX-License-Identifier: GPL-2.0-only

-- The parity harness on a trivial stand-in task (no real task is migrated):
-- golden, extraction, replay and budgeted runs, and a check that the harness
-- notices a wrong extraction.
local root = (... and ... ~= "" and ...) or "."

local parity = assert(loadfile(root .. "/tests/support/scheduler_parity.lua"))(root)
local standin = assert(loadfile(root .. "/tests/support/scheduler_standin.lua"))()
local equal = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual

local adapter = {
    id = "service:standin",
    decl = standin.decl,
    new = standin.new,
    old = standin.old,
    snapshot = standin.snapshot,
    feed = function(task, callback)
        for _, sample in ipairs(callback.samples or {}) do
            task.queue[#task.queue + 1] = sample
        end
    end,
}

-- A recorded input: irregular callbacks (3 to 7 ticks apart), bursts of one to four samples,
-- and a quiet tail so every run can finish what it was given.
local function recordTrace(callbacks, tail)
    local state, trace, now = 12345, {}, 0
    local function random(low, high)
        state = (state * 1103515245 + 12345) & 0x7fffffff
        return low + (state >> 8) % (high - low + 1)
    end
    for index = 1, callbacks + tail do
        now = now + random(3, 7)
        local callback = { now = now, kind = index % 7 == 0 and "background" or "steady" }
        if index <= callbacks and random(1, 5) == 1 then
            callback.samples = {}
            for sample = 1, random(1, 4) do
                callback.samples[sample] = random(-50, 50)
            end
        end
        trace[index] = callback
    end
    return trace
end
local trace = recordTrace(300, 200)

local golden = parity.golden(adapter, trace)
assert(#golden.schedule == 0, "the golden run must not call the new step")
assert(golden.task.consumed > 60, "the trace must exercise the task")

-- 2. Extraction: the legacy loop calling the extracted step matches the golden run.
local extraction = parity.extraction(adapter, trace)
parity.assertSame(golden, extraction, "extraction")
assert(#extraction.schedule > 10, "the legacy run's schedule is recorded")

-- 3. Ownership flip by replay: the schedule replayed into `step` alone.
parity.assertSame(golden, parity.replay(adapter, trace, extraction.schedule), "replay")

-- 4. Budgeted, ample room: the planner releases exactly when the legacy loop did.
local ample = parity.budgeted(adapter, trace)
parity.assertSame(golden, ample, "budgeted, ample room")

-- 4. Budgeted, tight room: head work leaves too little in some callbacks.
local tight = parity.budgeted(adapter, trace, {
    used = function(callback)
        return callback.now % 5 < 3 and 13000 or 0
    end,
})
local timing = parity.timing(extraction, tight, trace[#trace].now)
assert(timing.late > 0, "the tight budget must delay some release")
assert(timing.late <= 60, "a release was more than 60 ticks late: " .. timing.late)
assert(timing.budgetedGap <= timing.legacyGap + 40, "the longest gap grew by more than 40 ticks")
equal(tight.task.consumed, golden.task.consumed, "every sample is recorded when no release is lost")
equal(tight.task.sum, golden.task.sum, "the sum of the samples")

-- A wrong extraction (a cap of three instead of four) is noticed.
local wrong = {}
for key, value in pairs(adapter) do
    wrong[key] = value
end
wrong.new = function()
    local task = standin.new()
    function task.update(self, now)
        self:step(3, "run", now)
    end
    return task
end
local ok, message = pcall(parity.assertSame, golden, parity.extraction(wrong, trace), "extraction")
assert(not ok and string.find(message, "differs", 1, true), "a wrong extraction must fail the parity check")

print("Scheduler parity harness passed")
