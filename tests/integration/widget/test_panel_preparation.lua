-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local definition = fixture.module("main.lua")
local worst = 0
local function measured(callback)
    local count = 0
    debug.sethook(function()
        count = count + 1
    end, "", 1)
    callback()
    debug.sethook()
    worst = math.max(worst, count)
    assert(math.ceil((count * 1.10 + 50) / 10) * 10 <= 4000, "complete preparation atom: " .. count)
end
local function same(left, right)
    assert(#left == #right)
    for index, value in ipairs(left) do
        assert(value == right[index], tostring(value) .. " ~= " .. tostring(right[index]))
    end
end
local function context()
    fixture.reset()
    fixture.lvglMock.setFullScreen(false)
    return fixture.createLoaded(nil, { Layout = "review-metric", Theme = "modern-dark" })
end
local function configFor(kind, malformed)
    local config = {}
    if kind == "state" then
        config.entries = { { label = "SW1", states = { { switch = "SA^", text = "UP" } } } }
    else
        config.metrics = { { source = "Alt", precision = 1 }, { source = "RSSI" } }
    end
    for index = 1, 128 do
        config["future" .. index] = index
        if malformed then
            local entry = kind == "state" and config.entries[1] or config.metrics[1]
            entry["future" .. index] = index
            if kind == "state" then
                entry.states[1]["future" .. index] = index
            end
        end
    end
    return config
end

for _, kind in ipairs({ "metric", "chart", "state" }) do
    for _, malformed in ipairs({ false, true }) do
        for _, app in ipairs({ false, true }) do
            local host = context()
            local loader = host.dashboardLoader
            local placement = {
                id = "prepared",
                type = kind,
                col = 0,
                row = 0,
                colSpan = 2,
                rowSpan = 2,
                config = configFor(kind, malformed),
            }
            local original = host.panels[1]
            if app then
                original.placement = placement
                host.appRebuild = { entry = original, index = 1 }
                host.dashboardLifecycle.advanceAppRebuild(host)
                fixture.lvglMock.settle()
            else
                host.pendingPlacement, host.stage = placement, "panel-prepare"
            end
            local panelCount, errors = #host.panels, #host.errors
            local phases, prepared = {}
            for turn = 1, 2000 do
                local work = app and host.appRebuild.preparation or host.panelPreparation
                if work then
                    phases[work.phase] = true
                end
                measured(function()
                    if app then
                        host.dashboardLifecycle.advanceAppRebuild(host)
                    else
                        assert(loader.advanceLoad(host))
                    end
                end)
                assert(#host.panels == panelCount and not host.pendingConstruction)
                if turn == 5 then
                    host.zone = { x = 0, y = 0, w = 640, h = 360 }
                end
                prepared = app and host.appRebuild.prepared or host.pendingPanel
                if prepared then
                    break
                end
            end
            assert(prepared and phases.settings and phases.warnings)
            assert(not loader.workBound(host), "preparation cost proof cannot activate constructor admission")
            local resolved, warnings = host.panelHost.resolveSettings(
                prepared.module,
                placement.config,
                { colSpan = 2, rowSpan = 2 },
                host.modelArmed
            )
            assert(#warnings == (malformed and (kind == "state" and 384 or 256) or 128))
            for key, value in pairs(placement.config) do
                assert(resolved[key] == value and prepared.settings[key] == value, "unknown keys and nested identity")
            end
            assert(#host.errors == errors + #warnings)
            for index, warning in ipairs(warnings) do
                assert(host.errors[errors + index] == placement.id .. ": " .. warning)
            end
            same(prepared.settingsValidation.warnings, prepared.module.validateSettings(prepared.settings))
            local begin = prepared.module.beginSettingsValidation
            prepared.module.beginSettingsValidation = function()
                error("construction repeated completed validation")
            end
            if app then
                host.dashboardLifecycle.advanceAppRebuild(host)
            else
                loader.advanceLoad(host)
            end
            prepared.module.beginSettingsValidation = begin
            if malformed then
                assert(not host.pendingConstruction and #host.panels == panelCount)
                assert(#host.rejected > 0 and not string.find(host.errors[#host.errors], "repeated", 1, true))
                for _, warning in ipairs(prepared.settingsValidation.warnings) do
                    assert(string.find(host.errors[#host.errors], warning, 1, true))
                end
            else
                local built = host.pendingConstruction or host.panels[app and 1 or #host.panels]
                assert(built)
                for _ = 1, 100 do
                    if not host.pendingConstruction then
                        break
                    end
                    loader.advanceConstruction(host, false)
                end
                assert(not host.pendingConstruction and #host.panels == panelCount + 1)
                local rect = loader.panelRect(host, placement)
                assert(built.container.properties.w == rect.w and built.container.properties.h == rect.h)
            end
        end
    end
end

for _, phase in ipairs({ "module", "span", "rect", "settings", "warnings" }) do
    for _, app in ipairs({ false, true }) do
        for _, replacement in ipairs({ false, true }) do
            local host = context()
            local loader = host.dashboardLoader
            local placement = host.panels[1].placement
            placement.config = configFor("metric", false)
            if app then
                host.appRebuild = { entry = host.panels[1], index = 1 }
                host.dashboardLifecycle.advanceAppRebuild(host)
                fixture.lvglMock.settle()
            end
            local work = loader.beginPreparation(host, placement)
            if app then
                host.appRebuild.preparation = work
            else
                host.pendingPlacement, host.stage, host.panelPreparation = placement, "panel-prepare", work
            end
            for _ = 1, 1000 do
                if work.phase == phase then
                    break
                end
                assert(not loader.advancePreparation(host, work))
            end
            assert(work.phase == phase)
            if replacement then
                loader.beginLoad(host)
            else
                host.dashboardLifecycle.retirePage(host)
                fixture.lvglMock.settle()
            end
            local count, errors = #host.panels, #host.errors
            local done, prepared = loader.advancePreparation(host, work)
            assert(done and not prepared and work.cancelled)
            assert(not host.panelPreparation and not host.pendingConstruction)
            assert(#host.panels == count and #host.errors == errors, "stale preparation cannot publish or report")
            if app then
                host.dashboardLifecycle.advanceAppRebuild(host)
                assert(not host.appRebuild)
            end
        end
    end
end

print("Bounded cold/App preparation, large/malformed config, warning parity, resize and cancellation: " .. worst)
