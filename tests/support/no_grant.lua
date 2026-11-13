-- SPDX-License-Identifier: GPL-2.0-only

-- Withhold every task, including free tasks, to isolate callback admission from
-- execution. Native Return cleanup and failed-runtime rendering are not invoked.
return function(context, objects, exercise)
    local replacements, violations = {}, {}
    local function replace(owner, key, value)
        replacements[#replacements + 1] = { owner = owner, key = key, value = owner[key] }
        owner[key] = value
    end
    local function forbid(owner, key)
        if type(owner[key]) ~= "function" then
            return
        end
        replace(owner, key, function()
            local message = key .. " ran without a scheduler grant"
            violations[#violations + 1] = message
            error(message, 0)
        end)
    end
    local runs, enrolled = 0, {}
    replace(context.scheduler, "run", function()
        runs = runs + 1
        for _, task in ipairs(context.scheduler.tasks) do
            enrolled[task.name or "unnamed"] = true
        end
        return 0, 0, 0
    end)
    forbid(_G, "loadScript")
    forbid(io, "open")
    forbid(io, "write")
    forbid(_G, "mkdir")
    for key, value in pairs(lvgl) do
        if type(value) == "function" and key ~= "isFullScreen" and key ~= "isAppMode" then
            forbid(lvgl, key)
        end
    end
    for _, object in ipairs(objects) do
        forbid(object, "set")
        forbid(object, "clear")
    end
    local errors = #context.errors
    local ok, failure = pcall(exercise)
    for index = #replacements, 1, -1 do
        local item = replacements[index]
        item.owner[item.key] = item.value
    end
    assert(ok, failure)
    assert(#violations == 0, table.concat(violations, "\n"))
    assert(#context.errors == errors, "withheld callbacks must not hide bypass failures in the error log")
    assert(runs > 0, "exercise must reach scheduler admission")
    return enrolled
end
