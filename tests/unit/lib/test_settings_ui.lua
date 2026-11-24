-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local support = assert(loadfile(root .. "/tests/support/edgetx.lua"))()
support.constants()
support.lcd()
local mock = support.lvgl()
local ui = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/settings_ui.lua"))()
local context = { zone = { w = 480 } }
local parent = lvgl.box({ x = 0, y = 0, w = 480, h = 272 })
local closed, reads, pending = 0, 0
local values = { enabled = false, details = "visible" }
local fields = {
    { key = "enabled", label = "Enabled", type = "boolean" },
    { key = "details", label = "Details", type = "string", visibleWhen = { key = "enabled", value = true } },
}
local view
local function open()
    view = ui.open(context, parent, {
        title = "Shared settings",
        close = function()
            closed = closed + 1
        end,
    }, {
        fields = fields,
        errorHeight = 18,
        active = function()
            return true
        end,
        config = function()
            return values
        end,
        read = function(field)
            reads = reads + 1
            return values[field.key]
        end,
        write = function(field, value)
            values[field.key] = value
        end,
        enqueue = function(apply, value)
            if view.dialog and not view.build and not pending then
                pending = { apply = apply, value = value }
                return true
            end
            return false
        end,
    })
    return view
end

open()
assert(view.host and view.dialog.registeredParent == view.host, "the native dialog must register below its host")
assert(ui.cost(view, 32, 32) == 4 and #view.controls == 0)
local field, first = ui.advance(view)
assert(field == fields[1] and #view.controls == 1 and view.build == 2, "one advancement builds exactly one row")
local toggle = first.object.properties
assert(not toggle.active(), "partially built controls must not accept input")
toggle.set(1)
assert(not pending and toggle.get() == 0, "building must not optimistically accept blocked edits")
ui.advance(view)
assert(#view.controls == 2 and view.controls[2].row.hidden)
assert(ui.cost(view, 32, 32) == 32, "finishing can include caller-owned rendering")
ui.advance(view)
assert(not view.build and toggle.active())
local count = reads
for _ = 1, 10 do
    assert(toggle.get() == 0)
end
assert(reads == count, "native polling must only read the cache")
toggle.set(1)
assert(pending and not values.enabled and toggle.get() == 1, "accepted toggles acknowledge selection before applying")
toggle.set(0)
assert(toggle.get() == 1 and pending.value == 1, "blocked repeated input must not change the acknowledged value")
first.readNative()
assert(toggle.get() == 0, "failed writes can restore the committed value")
pending.apply(pending.value)
pending = nil
first.readNative()
ui.relayout(view)
assert(toggle.get() == 1 and not view.controls[2].row.hidden)
local function unchangedLayout(action)
    local calls = {}
    for _, object in ipairs(mock.objects) do
        calls[object] = object.writes + object.visibilityCalls
    end
    action()
    for object, before in pairs(calls) do
        assert(object.writes + object.visibilityCalls == before, "unchanged settings must not refresh native rows")
    end
end
unchangedLayout(function()
    ui.relayout(view)
    ui.fieldError(view, first, nil)
end)
local y = view.controls[2].row.properties.y
ui.fieldError(view, first, "Invalid setting")
assert(not first.errorLabel.hidden and view.controls[2].row.properties.y == y + 18)
unchangedLayout(function()
    ui.relayout(view)
    ui.fieldError(view, first, "Invalid setting")
end)
ui.fieldError(view, first, nil)
assert(first.errorLabel.hidden and view.controls[2].row.properties.y == y)
values.enabled = false
ui.relayout(view)
local nextY, writes = view.nextY, first.row.writes
view.fields[3] = { key = "extra", label = "Extra", type = "boolean" }
view.build = 3
local _, third = ui.advance(view)
assert(third.row.properties.y == nextY and first.row.writes == writes, "appending must not reflow all existing rows")
fields[3] = nil
ui.close(view)
assert(not view.dialog and not view.host and closed == 0, "programmatic close must not trigger navigation")
toggle.set(0)
assert(not pending, "retired controls must not queue input")
mock.settle()

open()
lvgl.close(view.dialog)
assert(closed == 1 and not view.dialog and not view.host and not view.build, "RTN must retire the shared host")
mock.settle()

local box = lvgl.box
lvgl.box = function(first, second)
    if second and second.visible then
        local properties = {}
        for key, value in pairs(second) do
            properties[key] = value
        end
        properties.visible = nil
        return box(first, properties)
    end
    return box(first, second)
end
open()
assert(
    context.nativeDialogsCreated and not view.host and view.dialog,
    "firmware without construction refs uses fallback"
)
ui.close(view)
lvgl.box = box
mock.settle()

local dialog = lvgl.dialog
for _, failure in ipairs({ false, "dialog construction failed" }) do
    lvgl.dialog = function()
        if failure then
            error(failure)
        end
    end
    local options = {}
    local ok, message = pcall(ui.open, context, parent, { title = "Failure" }, options)
    assert(not ok and string.find(message, failure or "cannot open settings dialog", 1, true))
    assert(not options.host and not options.dialog, "failed construction must retire the registration host")
    mock.settle()
end
lvgl.dialog = dialog
