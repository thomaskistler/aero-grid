-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local definition = fixture.module("main.lua")
EVT_TOUCH_FIRST, EVT_TOUCH_SLIDE, EVT_TOUCH_TAP = 9301, 9302, 9303
EVT_TOUCH_BREAK, EVT_VIRTUAL_ENTER, EVT_VIRTUAL_EXIT = 9304, 9305, 9306

local path = root .. "/build/test-widget-fixture/layouts/instruction-witness.yaml"
local kinds = {
    "metric", "link-status", "rx-battery", "tx-battery", "flight-timer", "flight-mode",
    "flight-counter", "model-identity", "navigation", "output", "state", "trim-panel",
    "host-diagnostics", "service-probe",
}
for _, kind in ipairs(kinds) do
    fixture.reset()
    fixture.lvglMock.setFullScreen(true)
    local file = assert(io.open(path, "w"))
    io.write(file, "version: 5\ngrid:\n  columns: 4\n  rows: 4\npanels:\n"
        .. "  - id: witness\n    type: " .. kind
        .. "\n    col: 0\n    row: 0\n    colSpan: 2\n    rowSpan: 2\n")
    io.close(file)
    local context = fixture.createLoaded(nil, { Layout = "instruction-witness", Theme = "modern-dark" })
    fixture.pump(context, 40, 10)
    assert(#context.errors == 0, table.concat(context.errors, ";"))
    assert(context.editorController.openEditor(context))
    local function settled()
        local ui = context.editorUi
        return ui and not ui.session.initializing and not ui.buildStage and not ui.renderStage
            and not ui.previewPending and not ui.previewRefresh and not ui.drawerOpen
            and not ui.drawerBuild and not ui.drawerPending
    end
    assert(fixture.pumpUntil(context, settled, 256, 10), kind .. ": editor did not open")
    local ui = context.editorUi
    ui.session.draft.panels[1].col = 1
    ui.renderStage, ui.layoutJob = 1, nil
    assert(fixture.pumpUntil(context, settled, 256, 10), kind .. ": layout did not finish")
    assert(context.panels[1].editorPlacement.col == 1, kind .. ": layout must publish its preview geometry")
    if kind == "metric" then
        local function input(event, point)
            context.touchTapHandled = nil
            fixture.tick(10)
            definition.refresh(context, event, point)
            fixture.lvglMock.settle()
        end
        local rect = ui.controls[1].rect
        local point = { x = rect.x + rect.w / 2, y = rect.y + rect.h / 2 }
        input(EVT_TOUCH_FIRST, point)
        assert(ui.drag and ui.drag.job, "touch must queue real drag enumeration")
        input(EVT_TOUCH_SLIDE, { x = point.x + 8, y = point.y + 8 })
        for _ = 1, 256 do
            if not ui.drag.job and #ui.drag.rects == #ui.drag.positions then break end
            fixture.pump(context, 1, 10)
        end
        assert(not ui.drag.job and #ui.drag.rects == #ui.drag.positions, "drag enumeration must finish")
        fixture.pump(context, 1, 10)
        input(EVT_TOUCH_BREAK, point)
        assert(fixture.pumpUntil(context, settled, 256, 10))
        rect = ui.controls[1].rect
        point = { x = rect.x + rect.w - 1, y = rect.y + rect.h - 1 }
        input(EVT_TOUCH_FIRST, point)
        assert(ui.drag and ui.drag.resize and ui.drag.job, "resize must queue settings and module checks")
        input(EVT_TOUCH_SLIDE, { x = point.x + 8, y = point.y + 8 })
        for _ = 1, 256 do
            if not ui.drag.job and #ui.drag.rects == #ui.drag.positions then break end
            fixture.pump(context, 1, 10)
        end
        assert(not ui.drag.job and #ui.drag.rects == #ui.drag.positions, "resize enumeration must finish")
        input(EVT_TOUCH_BREAK, point)
        input(EVT_TOUCH_TAP, point)
        assert(fixture.pumpUntil(context, settled, 256, 10))
        rect = ui.controls[1].rect
        input(EVT_TOUCH_TAP, { x = rect.x + rect.w / 2, y = rect.y + rect.h / 2 })
        ui.keyAdd = true
        input(EVT_VIRTUAL_ENTER)
        assert(fixture.pumpUntil(context, settled, 256, 10), "add drawer must finish")
        input(EVT_VIRTUAL_EXIT)
        assert(fixture.pumpUntil(context, function() return not context.editorUi or settled() end, 256, 10),
            "Return must close or settle the drawer")
        if not context.editorUi then
            assert(context.editorController.openEditor(context))
            assert(fixture.pumpUntil(context, settled, 256, 10))
        end
        ui = context.editorUi
        ui.keyAdd = false
        input(EVT_VIRTUAL_ENTER)
        assert(fixture.pumpUntil(context, settled, 256, 10), "panel drawer must finish")
        local removed = false
        for _, control in ipairs(ui.drawerControls) do
            if control.field.action == "remove" then
                assert(control.object.properties.active())
                control.object.properties.press()
                removed = true
                break
            end
        end
        assert(removed, "panel drawer must expose Remove panel")
        fixture.pump(context, 1, 10)
        assert(#ui.session.draft.panels == 0, "Remove panel must change the draft")
    end
    context.editorUiModule.close(context, false)
    context.dashboardLifecycle.beginReflow(context)
    assert(fixture.pumpUntil(context, function() return context.reflowIndex == nil end, 256, 10),
        kind .. ": reflow must finish")
    assert(#context.errors == 0, table.concat(context.errors, ";"))
    if kind == "host-diagnostics" then
        context.logViewerModule = fixture.module("lib/log_viewer.lua")
        context.logViewerModule.open(context)
        assert(fixture.pumpUntil(context, function()
            return context.logViewerModule.stageOf(context.logViewer) == "idle"
        end, 256, 10), "modal log must finish")
        fixture.pump(context, 1, 10)
        context.logViewerModule.close(context)

        local menu = assert(context.aerogridMenu)
        context.aeroMenuModule.handle(context, EVT_TOUCH_FIRST, { x = 1, y = 1 })
        context.aeroMenuModule.handle(context, EVT_TOUCH_BREAK, { x = 1, y = 1 })
        context.aeroMenuModule.handle(context, EVT_TOUCH_TAP, { x = 1, y = 1 })
        fixture.pump(context, 2, 10)
        assert(menu.open, "deferred menu opening must finish")
        context.aeroMenuModule.close(context)
    elseif kind == "metric" then
        context.pendingFlightError = "instruction witness"
        fixture.pump(context, 1, 10)
        assert(string.find(context.errors[#context.errors], "instruction witness", 1, true),
            "Flight error witness must be reported")
    end
end
assert(os.remove(path))
print("Foreground witnesses: per-panel layout/reflow, drag, touch and add drawer passed")
