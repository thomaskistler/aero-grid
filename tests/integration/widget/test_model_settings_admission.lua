-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."
local support = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root)
assert(os.execute("mkdir -p '" .. root .. "/build/test-widget-fixture/AEROGRID/models'"))

for _, ending in ipairs({ "return", "fullscreen", "explicit", "error", "replaced", "idle" }) do
    local fixture = support.new()
    fixture.reset()
    EVT_VIRTUAL_EXIT = 9106
    local definition = fixture.module("main.lua")
    local context = fixture.createLoaded(nil, { Layout = "review-navigation", Theme = "modern-dark" })
    fixture.lvglMock.setFullScreen(true)
    fixture.pump(context, 100)
    context.aeroMenuHandlers.modelSettings()
    for _ = 1, 200 do
        if context.modelSettingsUi and not context.modelSettingsUi.build then break end
        fixture.pump(context, 1)
    end
    local state, owner = assert(context.modelSettingsUi), context.flightBroker
    local previousRevision = state.revision
    local admissions, stages = {}, {}
    local function step(background, event)
        local advanced, admitted
        local advance, finish, dispatch = context.modelSettingsUiModule.advance,
            context.schedulerHost.finish, context.panelHost.dispatch
        local stage = context.modelSettingsUi and context.modelSettingsUiModule.stageOf(context.modelSettingsUi)
        context.modelSettingsUiModule.advance = function(...)
            advanced = true
            return advance(...)
        end
        context.schedulerHost.finish = function(self, kind)
            admitted = kind
            return finish(self, kind)
        end
        context.panelHost.dispatch = function(entry, operation, ...)
            assert(operation ~= "refresh", "settings callbacks must never refresh hidden panels")
            return dispatch(entry, operation, ...)
        end
        fixture.tick(5)
        if background then definition.background(context) else definition.refresh(context, event) end
        context.modelSettingsUiModule.advance, context.schedulerHost.finish, context.panelHost.dispatch =
            advance, finish, dispatch
        if advanced then
            assert(admitted == "modal-settings", "settings phase lost service admission: " .. tostring(stage))
            admissions[background and "background" or "refresh"] = true
            stages[stage] = true
        end
        fixture.lvglMock.settle()
    end
    if ending == "idle" then
        step(false, EVT_VIRTUAL_EXIT)
        assert(not context.modelSettingsUi, "Return must retire the idle dialog with admission")
    else
        state.controls.motorReversed.properties.set(1)
        if ending == "error" then
            state.handlers.startSave = function() return nil, "injected save failure" end
        end
        local replaced
        for index = 1, 180 do
            if ending == "replaced" and not replaced and state.saving and state.saving.phase == "publish" then
                owner:setDocument(owner.document)
                replaced = true
            end
            step(index % 2 == 0)
            if state.saving and state.saving.phase == "publish" then
                if ending == "return" then
                    context.modelSettingsUiModule.handle(context, EVT_VIRTUAL_EXIT)
                elseif ending == "fullscreen" then
                    fixture.lvglMock.setFullScreen(false)
                elseif ending == "explicit" then
                    assert(context.modelSettingsUiModule.close(context) == false)
                end
            end
            if not context.modelSettingsUi or not state.saving and not state.pending and not state.closing then break end
        end
        assert(admissions.refresh and admissions.background)
        assert(not state.pending and not state.saving, "confirmed save/publication must reach a terminal state")
        if ending == "error" or ending == "replaced" then
            assert(stages["save-error"] and #context.errors == 1, "errors remain explicit and admit services")
            assert(state.revision == previousRevision + (ending == "replaced" and 1 or 0))
        else
            assert(not context.modelSettingsUi and state.revision == previousRevision + 1)
            assert(owner.document.revision == state.revision and owner.document.flight.motorReversed)
            assert(stages["publish-start"] and stages.publish_commit)
        end
    end
end
print("Model settings foreground/background publication and retirement admission passed")
