-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local sameTree = assert(loadfile(root .. "/tests/support/panel_tree.lua"))()
local host = fixture.createLoaded(nil, { Layout = "review-metric", Theme = "modern-dark" })
fixture.pump(host, 40)
assert(#host.errors == 0, table.concat(host.errors, "\n"))
local showcase = fixture.module("panels/theme-showcase.lua")
local builder = host.panels[1].instance.themeBuilder
local frames = 0
for _, mode in ipairs({ "modern-dark", "modern-light" }) do
    local theme = builder.build(mode)
    for _, shape in ipairs({ { 480, 272 }, { 800, 480 }, { 212, 90 }, { 320, 200 } }) do
        local dependencies = {
            theme = theme,
            themeBuilder = builder,
            primitives = fixture.module("lib/primitives.lua"),
            state = function(state, accent)
                return builder.state(theme, state, accent)
            end,
        }
        local rect = { x = 0, y = 0, w = shape[1], h = shape[2] }
        local function create(module, staged, geometry)
            dependencies.staged = staged
            return module.create(lvgl.box({ x = 0, y = 0, w = 800, h = 480 }), geometry, {}, dependencies)
        end
        for resizeAt = 0, 35 do
            local staged = create(showcase, true, rect)
            assert(staged.createStage == "frame" and #staged.root.children == 0)
            local latest = rect
            local completed = false
            for step = 1, 44 do
                if step == resizeAt then
                    latest = { x = 2, y = 4, w = rect.w + 20, h = rect.h + 30 }
                end
                local done = showcase.construct(staged, latest)
                assert(type(done) == "boolean")
                if done then
                    assert(step >= 35, "construction stages must stay bounded and stable")
                    completed = true
                    break
                end
            end
            assert(completed, "construction did not complete")
            assert(not staged.createStage and not staged.createIndex and not staged.createServices)
            assert(not staged.createRect and not staged.createLayout)
            assert(showcase.construct(staged, latest), "completion is idempotent")
            local synchronous = create(showcase, false, latest)
            sameTree(synchronous.root, staged.root)
            local changed = { x = 0, y = 1, w = rect.w + 40, h = rect.h + 60 }
            showcase.update(staged, changed)
            showcase.update(synchronous, changed)
            sameTree(synchronous.root, staged.root)
            frames = frames + 1
        end
    end
end
print("Theme Showcase construction: " .. frames .. " completed frames, pending resize and reflow parity passed")
