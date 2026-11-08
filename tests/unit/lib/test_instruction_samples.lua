-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local radio = assert(loadfile(root .. "/tests/support/edgetx.lua"))()
radio.constants()
radio.radio(io)
local function load(relative, ...)
    local path = string.sub(relative, 1, 9) == "@support/"
        and "/tests/support/" .. string.sub(relative, 10) or "/src/WIDGETS/AeroGrid/" .. relative
    return assert(loadfile(root .. path))(...)
end
local names = {
    "armed", "control-critical", "control-normal", "control-outputs", "model", "navigation",
    "history", "flight-tasks", "smart-task", "telemetry-maintenance", "telemetry-recorded-one",
    "telemetry-unrecorded", "telemetry", "flight-counter-panel", "flight-mode-panel",
    "flight-timer-panel", "host-diagnostics-panel", "link-status-panel", "metric-panel",
    "model-identity-panel", "navigation-panel", "output-panel", "rx-battery-panel",
    "service-probe-panel", "state-panel", "trim-panel", "tx-battery-panel",
    "theme-resolution", "modal-log", "panel-reflow", "rx-reflow",
}
for _, name in ipairs(names) do
    local case = assert(loadfile(root .. "/tests/fixtures/scheduler-cases/" .. name .. ".lua"))()(load)
    local groups, order = {}, {}
    for index, item in ipairs(case.cases) do
        local key = item.stage .. "|" .. item.grant
        local group = groups[key]
        if not group then
            group = {}
            groups[key], order[#order + 1] = group, key
        end
        groups[key] = group
        group[#group + 1] = index
    end
    for _, key in ipairs(order) do
        local group = groups[key]
        local seen = {}
        for _, position in ipairs({ 1, (#group + 1) // 2, #group }) do
            local index = group[position]
            if not seen[index] then
                seen[index] = true
                local item = case.cases[index]
                local instance, now = item.setup(1)
                assert(type(instance.step) == "function")
                local owner = instance.owner or instance
                local beforeWant, beforeStage, beforeCursor = instance.want, instance.stage, owner.cursor
                local delay = instance:step(item.grant, item.stage, now or 1)
                assert(delay == nil or type(delay) == "number" or type(delay) == "boolean",
                    name .. ": sampled step must return a scheduler delay")
                assert(not owner.failed, name .. ": sampled work must complete without a task failure")
                if __instructionWitness then
                    __instructionWitness({
                        case = name, caseIndex = index, stage = item.stage, grant = item.grant, seed = 1,
                        beforeWant = beforeWant, beforeStage = beforeStage, beforeCursor = beforeCursor,
                        want = instance.want, nextStage = instance.stage, cursor = owner.cursor, delay = delay,
                        expectedGrant = item.grant, expectedStage = item.stage, completed = true,
                    })
                end
            end
        end
    end
end
print("Instruction witnesses: first/middle/last stimulus per stage/grant passed")
