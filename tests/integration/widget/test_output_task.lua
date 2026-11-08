-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local output = fixture.module("panels/output.lua")
local panelHost = fixture.module("lib/panel_host.lua")
local dashboard = fixture.createLoaded(nil, { Layout = "review-output", Theme = "modern-dark" })
local reference = assert(fixture.instanceOf(dashboard, "outputs"))
local settings = assert(panelHost.resolveSettings(output, {
    firstChannel = 1,
    channelCount = 32,
    showNames = true,
    showTrim = true,
}))
local feeds = {}
for index = 1, 32 do
    feeds[index] = {
        available = true,
        nameReady = true,
        name = "AIL",
        fraction = index / 32,
        trim = { available = true, fraction = -index / 32 },
    }
end
local services = {
    theme = reference.theme,
    themeBuilder = reference.themeBuilder,
    primitives = reference.primitives,
    state = reference.state,
    fonts = reference.fonts,
    control = {
        output = function(_, index)
            return feeds[index + 1]
        end,
    },
}
local rect = { x = 0, y = 0, w = 800, h = 1000 }
local function create()
    local instance = output.create(lvgl.box({ x = 0, y = 0, w = 800, h = 1000 }), rect, settings, services)
    local task = panelHost.task({ module = output, instance = instance, interval = 10 })
    local done = false
    for _ = 1, 1000 do
        if task:step(task.want or 1, task.stage, getTime()) == 10 then
            done = true
            break
        end
    end
    assert(done and instance.showRows == 32)
    return instance
end
local expectedPanel, instance = create(), create()
local expectedTask = panelHost.task({ module = output, instance = expectedPanel, interval = 10 })
local function finishExpected()
    for _ = 1, 1000 do
        if expectedTask:step(1, expectedTask.stage, getTime()) == 10 then return end
    end
    error("Output comparison task did not finish")
end
local entry = { module = output, instance = instance, interval = 10, nextRefresh = getTime() }
local task = panelHost.task(entry)
local function step(grant)
    local delay = task:step(grant or 1, task.stage, getTime())
    assert(task.used <= (grant or 1))
    return delay
end

local function snapshot(panel)
    local rows = { panel.stateName }
    for _, row in ipairs(panel.rows) do
        rows[#rows + 1] = table.concat({
            row.captionText,
            row.text,
            tostring(row.fraction),
            tostring(row.trimFraction),
            tostring(row.fill.hidden),
            tostring(row.trim.hidden),
        }, ":")
    end
    return table.concat(rows, "\n")
end

for _, available in ipairs({ true, false, true }) do
    for index, feed in ipairs(feeds) do
        feed.available = available
        feed.fraction = -index / 32
        feed.trim.fraction = index / 32
    end
    finishExpected()
    for slice = 1, 4 do
        assert(step() == 1, "unfinished caption work and capture keep a one-tick release")
        if slice < 4 then
            assert(task.stage == "prepare", "caption work is capped at eight rows per preparation slice")
        end
    end
    assert(task.stage == "render", "preparation publishes a separate snapshot-capture stage")
    step()
    assert(task.stage == "apply" and instance.pendingDrawn, "prepare publishes a retained render snapshot")
    local frozen = instance.pendingDrawn
    local expected = snapshot(expectedPanel)
    for index = 1, 32 do
        feeds[index].fraction = 1.5
    end
    for first = 1, 32, 2 do
        local before = instance.rows[first + 2] and instance.rows[first + 2].fraction
        local delay = step(2)
        if first < 31 then
            assert(
                delay == 1 and task.stage == "apply",
                string.format(
                    "row %d: delay=%s stage=%s shown=%s next=%s",
                    first,
                    tostring(delay),
                    tostring(task.stage),
                    tostring(instance.showRows),
                    tostring(instance.applyRow)
                )
            )
            assert(instance.pendingDrawn == frozen, "partial grants must not rerender mutable feeds")
            assert(instance.rows[first + 2].fraction == before, "a grant paints no more than two rows")
        else
            assert(delay == 10 and task.stage == "prepare")
        end
    end
    assert(snapshot(instance) == expected, "completed application is consistent across grants")
end

local function finish()
    for _ = 1, 1000 do
        if step(task.want) == 10 then
            return
        end
    end
    error("Output task did not finish")
end

finish()
local previous = snapshot(instance)
assert(step() == 1)
feeds[1].name = "WWW"
for _ = 1, 3 do
    assert(step() == 1)
end
step()
assert(instance.pendingDrawn == nil, "capture uses the names whose column widths were measured")
assert(snapshot(instance) == previous)
finish()
assert(instance.rows[1].captionText == "CH1: WWW")
feeds[1].name = ""
finish()
assert(instance.rows[1].captionText == "CH1", "empty names retain the channel prefix")
feeds[1].nameReady = false
assert(step() == 10 and task.stage == "prepare", "unresolved names wait for the base refresh interval")
feeds[1].name, feeds[1].nameReady = "AIL", true
finish()

feeds[1].fraction = -1.5
for _ = 1, 4 do
    step()
end
step()
assert(task.stage == "apply")
local old = instance.pendingDrawn
output.update(instance, { x = 0, y = 0, w = 400, h = 400 }, settings)
assert(instance.pendingDrawn == nil and old ~= nil)
assert(
    step(2) == 1 and task.used == 0 and task.stage == "prepare",
    "reflow between planning and execution invalidates a stale apply stage"
)
assert(instance.applyRow == nil)

step()
assert(instance.captionWork and instance.captionWork.next == 9)
output.update(instance, rect, settings)
assert(instance.captionWork == nil and instance.renderReady == nil, "reflow discards partial caption work")
finish()
assert(instance.showRows == 32, "one-tick mounting continuations must finish every row")

for _, target in ipairs({ "prepare", "render", "apply", "partial" }) do
    feeds[1].fraction = feeds[1].fraction == 0.75 and -0.75 or 0.75
    assert(step() == 1 and instance.captionWork)
    if target ~= "prepare" then
        for _ = 1, 3 do
            assert(step() == 1)
        end
        assert(task.stage == "render")
        if target ~= "render" then
            assert(step() == 1 and task.stage == "apply")
            if target == "partial" then
                assert(step(2) == 1 and instance.applyRow == 3)
            end
        end
    end
    output.cancelRefresh(instance)
    assert(not instance.pendingDrawn and not instance.captionWork and not instance.renderReady)
    if target ~= "prepare" then
        assert(step(2) == 1 and task.used == 0 and task.stage == "prepare")
    end
    finishExpected()
    finish()
    assert(snapshot(instance) == snapshot(expectedPanel), "cancelRefresh resumes after " .. target)
end

output.update(instance, { x = 0, y = 0, w = 20, h = 20 }, settings)
assert(instance.area.count == 0)
instance.stateName, instance.rendered = nil, nil
finish()
assert(instance.showRows == 0 and task.used == 1, "an empty panel charges its final presentation unit")

print("Output task row grants and snapshot behavior passed")
