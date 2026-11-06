-- SPDX-License-Identifier: GPL-2.0-only

return function(load)
    local scheduler = load("lib/scheduler.lua")
    local decl = {
        class = "normal",
        stages = {
            run = { fixed = 0, perUnit = 670, maxUnits = 1 },
            cancel = { fixed = 0, perUnit = 70, maxUnits = 1 },
        },
    }
    local cases = {}
    for _, class in ipairs({ "critical", "normal" }) do
        for _, size in ipairs({ 1, 8, 32, 128 }) do
            for _, position in ipairs({ 1, math.max(1, size // 2), size }) do
                for _, offset in ipairs({ -100, 0, 100 }) do
                    for _, base in ipairs({ 0, 0x7ffffff0, 0xfffffff0 }) do
                        cases[#cases + 1] = {
                            stage = "run",
                            grant = 1,
                            setup = function()
                                local queue = scheduler.new({ steady = 0 })
                                local queued = {
                                    class = class,
                                    stages = { run = { fixed = 0, perUnit = 100, maxUnits = 1 } },
                                }
                                for index = 1, size do
                                    assert(queue:add({
                                        id = index,
                                        decl = queued,
                                        instance = {
                                            step = function()
                                                return 10
                                            end,
                                        },
                                        due = base + index,
                                    }))
                                end
                                for _, name in ipairs({ "metric", "navigation", "output" }) do
                                    local panel = load("panels/" .. name .. ".lua")
                                    for _, stage in ipairs({
                                        false,
                                        "geometry",
                                        "layout",
                                        "render",
                                        "apply",
                                        "reading",
                                        "tape-frame",
                                        "tape",
                                    }) do
                                        cases[#cases + 1] = {
                                            stage = "cancel",
                                            grant = 1,
                                            setup = function()
                                                local context = {
                                                    refreshWork = stage and { stage = stage } or nil,
                                                    rendered = {},
                                                    pendingDrawn = stage and {} or nil,
                                                    captionWork = stage and {} or nil,
                                                    renderReady = stage or nil,
                                                    applyRow = stage and 3 or nil,
                                                }
                                                return {
                                                    step = function()
                                                        panel.cancelRefresh(context)
                                                        return 10
                                                    end,
                                                },
                                                    0
                                            end,
                                        }
                                    end
                                end
                                return {
                                    step = function()
                                        assert(queue:reschedule(position, base + offset))
                                        return 10
                                    end,
                                },
                                    base
                            end,
                        }
                    end
                end
            end
        end
    end
    return { id = "host:lifecycle-release", decl = decl, cases = cases }
end
