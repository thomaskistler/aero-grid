-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local definition = fixture.module("main.lua")
for _, layout in ipairs({ "review-chart", "review-navigation" }) do
    local context = definition.create(
        { x = 0, y = 0, w = 480, h = 272 },
        { Layout = layout, Theme = "modern-dark" },
        root .. "/build/test-widget-fixture/"
    )
    for _ = 1, 150 do
        if context.stage == "panel-prepare" then
            break
        end
        fixture.tick(10)
        definition.refresh(context)
    end
    assert(context.stage == "panel-prepare", "loading must reach separate preparation")
    local count = #context.panels
    local placement = context.pendingPlacement
    assert(context.dashboardLoader.advanceLoad(context))
    local prepared = assert(context.pendingPanel)
    assert(context.stage == "panel-build" and #context.panels == count, "preparation must not construct a panel")

    local create, calls = prepared.module.create, 0
    context.panelTasksDirty = false
    prepared.module.create = function(...)
        calls = calls + 1
        return create(...)
    end
    context.zone = { x = 0, y = 0, w = 640, h = 360 }
    local rect = assert(context.dashboardLoader.panelRect(context, placement))
    assert(context.dashboardLoader.advanceLoad(context))
    prepared.module.create = create
    local partial = assert(context.pendingConstruction)
    assert(
        context.stage == "panel-construct"
            and #context.panels == count
            and partial.container.hidden
            and not context.panelTasksDirty,
        "a partially constructed panel stays hidden and outside the live registry"
    )
    local resized = false
    for _ = 1, 50 do
        if context.stage ~= "panel-construct" then
            break
        end
        if
            (partial.instance.createStage == "position" or partial.instance.createStage == "publish") and not resized
        then
            context.zone = { x = 0, y = 0, w = 800, h = 480 }
            rect = assert(context.dashboardLoader.panelRect(context, placement))
            resized = true
        end
        assert(#context.panels == count and partial.container.hidden)
        context.dashboardLoader.advanceLoad(context)
    end
    local entry = assert(context.panels[count + 1])
    assert(calls == 1 and context.stage == "panels" and context.pendingPanel == nil)
    assert(resized and not entry.container.hidden and not context.pendingConstruction)
    assert(context.panelTasksDirty, "only a completed panel invalidates scheduler enrollment")
    assert(
        entry.module == prepared.module and entry.settings == prepared.settings,
        "construction reuses prepared inputs"
    )
    assert(
        entry.container.properties.w == rect.w and entry.container.properties.h == rect.h,
        "construction uses current zone geometry, not the preparation snapshot"
    )
    assert(context.pendingPlacement == nil and context.panelMigrationVersion == nil)

    context.pendingPlacement = {
        id = "unavailable",
        type = "not-installed",
        col = 0,
        row = 0,
        colSpan = 2,
        rowSpan = 1,
    }
    context.stage = "panel-prepare"
    local errors, rejected = #context.errors, #context.rejected
    assert(context.dashboardLoader.advanceLoad(context))
    assert(context.stage == "panels" and not context.pendingPanel and not context.pendingPlacement)
    assert(
        #context.panels == count + 1 and #context.errors == errors + 1 and #context.rejected == rejected + 1,
        "failed preparation reports and rejects the placement without constructing it"
    )

    context.pendingPlacement, context.stage = placement, "panel-prepare"
    assert(context.dashboardLoader.advanceLoad(context))
    prepared = assert(context.pendingPanel)
    create = prepared.module.create
    prepared.module.create = function()
        error("expected construction failure")
    end
    errors, rejected = #context.errors, #context.rejected
    assert(context.dashboardLoader.advanceLoad(context))
    prepared.module.create = create
    assert(#context.panels == count + 1 and #context.errors == errors + 1 and #context.rejected == rejected + 1)
    assert(
        not context.pendingPanel and not context.pendingPlacement and context.stage == "panels",
        "failed construction retires prepared state and advances loading"
    )

    for _, failure in ipairs({ "raise", "invalid-result" }) do
        context.pendingPlacement, context.stage = placement, "panel-prepare"
        context.dashboardLoader.advanceLoad(context)
        context.dashboardLoader.advanceLoad(context)
        local pending = assert(context.pendingConstruction)
        local construct = pending.module.construct
        pending.module.construct = function()
            if failure == "raise" then
                error("expected construction step failure")
            end
        end
        errors, rejected = #context.errors, #context.rejected
        context.dashboardLoader.advanceLoad(context)
        pending.module.construct = construct
        assert(#context.errors == errors + 1 and #context.rejected == rejected + 1)
        assert(not context.pendingConstruction and not context.pendingPlacement and context.stage == "panels")
        assert(
            pending.container.hidden and #context.panels == count + 1,
            "failed or malformed construction steps cannot publish a panel"
        )
    end

    context.pendingPlacement, context.stage = placement, "panel-prepare"
    context.dashboardLoader.advanceLoad(context)
    assert(context.pendingPanel)
    context.dashboardLoader.advanceLoad(context)
    local cancelled = assert(context.pendingConstruction)
    context.dashboardLoader.beginLoad(context)
    assert(
        context.pendingPanel == nil
            and context.pendingPlacement == nil
            and not context.pendingConstruction
            and context.stage == "theme-read"
            and cancelled.container.hidden,
        "a replacement load invalidates and hides partial construction"
    )

    context.pendingPlacement, context.stage = placement, "panel-prepare"
    context.dashboardLoader.advanceLoad(context)
    context.dashboardLoader.advanceLoad(context)
    assert(context.pendingConstruction)
    context.dashboardLifecycle.retirePage(context)
    fixture.lvglMock.settle()
    assert(not context.pendingConstruction and not context.pendingPanel and context.reloadState == "rebuild")
    context.dashboardLifecycle.rebuildPage(context)
    context.dashboardLoader.beginLoad(context)
    assert(
        context.stage == "theme-read" and not context.pendingConstruction,
        "page retirement must not retain constructor references to deleted native objects"
    )
end

print("Panel preparation and construction lifecycle passed")
