-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local hostIo = io
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
fixture.reset()
fixture.lvglMock.setAppMode(true)
fixture.lvglMock.setFullScreen(true)
local definition = fixture.module("main.lua")
local path = root .. "/build/test-widget-fixture/"
local file = assert(hostIo.open(path .. "layouts/app-continuity.yaml", "w"))
file:write([[
version: 5
grid:
  columns: 4
  rows: 4
panels:
  - id: metric
    type: metric
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
  - id: chart
    type: chart
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      metrics:
        - source: Alt
]])
file:close()
local context = fixture.createLoaded(nil, { Layout = "app-continuity", Theme = "modern-dark" })
fixture.pump(context, 40)
local oldRoot, oldPage = context.root, context.page
local oldChart, chartModule = context.panels[2].instance, context.panels[2].module
local destroy, destroyed = chartModule.destroy, false
chartModule.destroy = function(instance)
    if instance == oldChart then
        destroyed = true
    end
    return destroy(instance)
end
assert(context.rootBuiltFullscreen and context.pageBuiltFullscreen)
local function visible(object)
    while object do
        if object.hidden or object.cleared or object.invalid then
            return false
        end
        object = object.parent
    end
    return true
end
fixture.lvglMock.setFullScreen(false)
local retained, replaced = false, false
for _ = 1, 300 do
    definition.refresh(context)
    fixture.lvglMock.settle()
    local oldVisible = visible(oldPage)
    local newVisible = context.page ~= nil and context.page ~= oldPage and visible(context.page)
    assert(oldVisible or newVisible, "returning to App mode must never expose an empty dashboard")
    if context.retainedPage and not context.retainedPage.published then
        retained = true
        assert(oldVisible, "the old dashboard stays visible throughout staged loading")
        assert(not newVisible, "a partial replacement dashboard must stay hidden")
        assert(not destroyed, "retained charts must not clear their plots before the replacement is visible")
    elseif context.page ~= oldPage and not context.stage and not context.reloadState then
        replaced = true
        assert(newVisible and oldRoot.cleared and oldRoot.hidden)
        assert(not context.root.builtFullscreen and not context.page.builtFullscreen)
        break
    end
end
assert(retained and replaced, "App mode must replace fullscreen-built containers without a blank frame")
assert(#context.errors == 0, table.concat(context.errors, "\n"))
fixture.pump(context, 40)
assert(not context.retainedPage and #context.panels == 2 and destroyed)
assert(not context.panels[1].container.builtFullscreen, "replacement panels preserve native App-mode touch behavior")

file = assert(hostIo.open(path .. "layouts/arming-recovery.yaml", "w"))
file:write([[
version: 5
grid:
  columns: 4
  rows: 4
panels:
  - id: chart
    type: chart
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      armSwitch: ch5
      metrics:
        - source: Alt
]])
file:close()
fixture.lvglMock.setFullScreen(true)
local recovering = fixture.createLoaded(nil, { Layout = "arming-recovery", Theme = "modern-dark" })
fixture.pump(recovering, 40)
assert(#recovering.rejected == 0 and #recovering.panels == 1, "an invalid legacy arm source is ignored")
local recoveryPage = recovering.page
recovering.aeroMenuHandlers.modelSettings()
assert(fixture.pumpUntil(recovering, function(host)
    return host.modelSettingsUi and not host.modelSettingsUi.build
end, 300))
local settings = recovering.modelSettingsUi
settings.controls.armed.properties.set(getSwitchIndex("L01"))
assert(fixture.pumpUntil(recovering, function(host)
    return not settings.pending and not host.modelArmingReload and settings.armed == "L01"
end, 300))
lvgl.close(settings.dialog)
for _ = 1, 300 do
    definition.refresh(recovering)
    fixture.lvglMock.settle()
    assert(
        visible(recoveryPage) or recovering.page and visible(recovering.page),
        "reloading after an arming change must not blank the dashboard"
    )
    if not recovering.modelSettingsUi and not recovering.stage and not recovering.reloadState then
        break
    end
end
assert(#recovering.panels == 1 and #recovering.rejected == 0, "the chart survives the arming reload")
assert(#recovering.errors == 0, table.concat(recovering.errors, "\n"))
