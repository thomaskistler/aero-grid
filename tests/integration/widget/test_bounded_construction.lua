-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local sameTree = assert(loadfile(root .. "/tests/support/panel_tree.lua"))()
local host = fixture.createLoaded(nil, { Layout = "review-metric", Theme = "modern-dark" })
local panelHost = fixture.module("lib/panel_host.lua")
fixture.pump(host, 40)
assert(#host.errors == 0, table.concat(host.errors, "\n"))
local cases = assert(loadfile(root .. "/tests/support/construction_cases.lua"))()(fixture.module, host.themeBuilder)
local checked = 0
for _, case in ipairs(cases) do
    local panel = case.panel
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
    local function finishTask(context)
        local task = panelHost.task({ module = panel, instance = context, interval = 20 })
        for now = 1, 200 do
            if task:step(task.want or 1, task.stage, now) ~= 1 then return end
        end
        error(case.name .. ": task did not finish")
    end
    local synchronous, staged = create(panel, false), create(panel, true)
    assert(staged.createStage and not staged.panel, case.name .. ": create must defer real construction")
    local stages = {}
    for _ = 1, 20 do
        stages[#stages + 1] = staged.createStage
        if panel.construct(staged, case.rect) then
            break
        end
    end
    assert(not staged.createStage, case.name)
    sameTree(synchronous.panel.root, staged.panel.root, case.name .. "/staged")
    for _, context in ipairs({ synchronous, staged }) do
        finishTask(context)
    end
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
            finishTask(expected)
            panel.update(expected, changed)
        end
        if case.kind == "metric" and not expected.feed then
            panel.setValue(expected, nil)
        end
        finishTask(partial)
        finishTask(expected)
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
                finishTask(partial)
                finishTask(expected)
                sameTree(expected.panel.root, partial.panel.root, case.name .. "/" .. event .. "-" .. stop)
            end
        end
    end
    checked = checked + 1
end

local nativeConstruction = assert(loadfile(root .. "/tests/support/native_construction.lua"))()
local representative
for _, case in ipairs(cases) do
    if case.kind == "metric" then
        representative = case
        break
    end
end
assert(representative and type(representative.settle) == "function")
local settle, settled = representative.settle, 0
representative.settle = function(case, instance)
    settled = settled + 1
    return settle(case, instance)
end
for _, reflowOnly in ipairs({ false, true }) do
    local exercised = false
    local state = nativeConstruction(lvgl, { representative }, sameTree,
        lvgl.box({ x = 0, y = 0, w = 800, h = 480 }), function(current, case)
            assert(case == representative and current.reference.panel and current.partial.panel)
            exercised = true
        end, reflowOnly)
    local phases = { "begin" }
    if not reflowOnly then phases[#phases + 1] = "construct" end
    for _, phase in ipairs({ "refresh", "exercise", "cleanup" }) do
        phases[#phases + 1] = phase
    end
    for _, phase in ipairs(phases) do
        assert(state.phase == phase and not state:step(), "native factory must advance " .. phase)
        fixture.lvglMock.settle()
    end
    assert(state:step() and state.checked == 1 and exercised)
    assert(not state.reference and not state.partial and not state.container)
end
representative.settle = settle
assert(settled == 4, "native comparison must settle both trees through scheduler tasks")
print("Bounded construction: " .. checked .. " synchronous/staged trees, every-stage resize and invalidation passed")
