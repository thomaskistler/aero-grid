-- SPDX-License-Identifier: GPL-2.0-only

local root = ... or "."
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local definition = fixture.module("main.lua")
local originalLoadScript = loadScript
local path = root .. "/build/test-widget-fixture/"

for _, relative in ipairs({
    "lib/dashboard_loader.lua",
    "lib/dashboard_lifecycle.lua",
    "lib/editor_controller.lua",
    "lib/typography.lua",
    "lib/panel_layout.lua",
    "lib/reading.lua",
}) do
    for _, failure in ipairs({ "missing", "incompatible", "no-constructor", "constructor-error", "no-operations" }) do
        loadScript = function(filename)
            if string.sub(filename, -#relative) == relative then
                if failure == "missing" then
                    return nil, "deliberately missing " .. relative
                end
                return function()
                    local module = { RUNTIME_API = failure == "incompatible" and 0 or 1 }
                    if failure == "constructor-error" then
                        module.new = function()
                            error("deliberate constructor error: " .. relative)
                        end
                        module.install = module.new
                    elseif failure == "no-operations" then
                        module.new = function()
                            return {}
                        end
                        -- Visual dependency installers are checked by module execution.
                        module.install = nil
                    end
                    return module
                end
            end
            return originalLoadScript(filename)
        end
        local zone = { x = 0, y = 0, w = 480, h = 272 }
        local context = definition.create(zone, { Layout = "main", Theme = "modern-dark" }, path)
        assert(context.runtimeFailed and not context.stage, relative .. " should fail before staging")
        assert(string.find(table.concat(context.errors, "\n"), relative, 1, true), "missing module was not reported")
        definition.update(context, { Layout = "gallery", Theme = "modern-light" })
        zone.w = 320
        definition.refresh(context)
        definition.background(context)
        assert(definition.event(context, _G.EVT_VIRTUAL_ENTER) == false)
        assert(context.root.properties.w == 320 and context.page.properties.w == 320)
        assert(context.errorLabel.properties.w == 304, "runtime failures must remain visible after resizing")
        assert(not context.stage, "option changes must not restart an incomplete runtime")
    end
end
loadScript = originalLoadScript

local context = fixture.createLoaded()
assert(not context.runtimeFailed and #context.errors == 0)
assert(context.dashboardLoader and context.dashboardLifecycle and context.editorController)
