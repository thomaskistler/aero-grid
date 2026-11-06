-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local sameTree = assert(loadfile(root .. "/tests/support/panel_tree.lua"))()
local host = fixture.createLoaded(nil, { Layout = "review-metric", Theme = "modern-dark" })
fixture.pump(host, 40)
assert(#host.errors == 0, table.concat(host.errors, "\n"))
local cases = assert(loadfile(root .. "/tests/support/construction_cases.lua"))()(fixture.module, host.themeBuilder)
local checked = 0
for _, case in ipairs(cases) do
    local panel = case.panel
    local legacy = BASELINES and BASELINES[case.kind] or panel
    local function create(module, staged, rect)
        local services = case.dependencies()
        services.staged = staged
        return module.create(lvgl.box({ x = 0, y = 0, w = 800, h = 480 }), rect or case.rect, case.settings, services)
    end
    local function finish(context, rect)
        for _ = 1, 40 do
            local done = panel.construct(context, rect)
            assert(type(done) == "boolean", case.name)
            if done then
                assert(not context.createStage and not context.createGeometry and not context.createPresentation)
                assert(not context.createInvalidated and not context.createParent)
                assert(panel.construct(context, rect), "completed construction must be idempotent")
                return
            end
        end
        error(case.name .. ": construction did not finish")
    end
    local reference, synchronous, staged = create(legacy, false), create(panel, false), create(panel, true)
    assert(staged.createStage and not staged.panel, case.name .. ": create must defer real construction")
    local stages = {}
    for _ = 1, 20 do
        stages[#stages + 1] = staged.createStage
        if panel.construct(staged, case.rect) then
            break
        end
    end
    assert(not staged.createStage, case.name)
    sameTree(reference.panel.root, synchronous.panel.root, case.name .. "/legacy")
    sameTree(synchronous.panel.root, staged.panel.root, case.name .. "/staged")
    for _, context in ipairs({ reference, synchronous, staged }) do
        (context == reference and legacy or panel).refresh(context)
    end
    sameTree(reference.panel.root, synchronous.panel.root, case.name .. "/legacy-refresh")
    sameTree(synchronous.panel.root, staged.panel.root, case.name .. "/refresh")

    -- Interrupt every real stage, including repeated RX candidate fits.
    for stop = 1, #stages do
        local partial, expected = create(panel, true), create(panel, false)
        for _ = 1, stop - 1 do
            assert(not panel.construct(partial, case.rect))
        end
        local changed = { x = 2, y = 3, w = case.rect.w + 30, h = case.rect.h + 40 }
        finish(partial, changed)
        if stop == 1 then
            expected = create(panel, false, changed)
        else
            panel.refresh(expected)
            panel.update(expected, changed)
        end
        if case.kind == "metric" and not expected.feed then
            panel.setValue(expected, nil)
        end
        panel.refresh(partial)
        panel.refresh(expected)
        if case.kind == "flight-timer" then
            local _, drawn = expected.primitives.changed(expected, panel.render)
            panel.apply(expected, drawn)
        end
        sameTree(expected.panel.root, partial.panel.root, case.name .. "/resize-" .. stop)

        for _, event in ipairs({ "cancelRefresh", "resetSession", "update" }) do
            if panel[event] then
                partial, expected = create(panel, true), create(panel, false)
                for _ = 1, stop - 1 do
                    assert(not panel.construct(partial, case.rect))
                end
                if event == "update" then
                    panel.update(partial, changed)
                    if stop == 1 then
                        expected = create(panel, false, changed)
                    else
                        panel.update(expected, changed)
                    end
                else
                    panel[event](partial, 1000)
                    panel[event](expected, 1000)
                end
                finish(partial, event == "update" and changed or case.rect)
                panel.refresh(partial)
                panel.refresh(expected)
                if case.kind == "flight-timer" then
                    local _, drawn = expected.primitives.changed(expected, panel.render)
                    panel.apply(expected, drawn)
                end
                sameTree(expected.panel.root, partial.panel.root, case.name .. "/" .. event .. "-" .. stop)
            end
        end
    end
    checked = checked + 1
end
print("Bounded construction: " .. checked .. " synchronous/staged trees, every-stage resize and invalidation passed")
