-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local mipmap = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/chart_mipmap.lua"))()
local recorder = assert(loadfile(root .. "/tests/support/mipmap_recorder.lua"))(root)
local equal = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual

local observed, baseline = recorder(1), recorder(1)
local history, feed = observed.history, observed.feeds[1]
local screen = mipmap.attach(history, feed, 398)
local detail = mipmap.attach(history, feed, 800)
assert(screen.complete and detail.complete)
for at = 0, 100 do
    local value = at % 13 / 10
    observed.sample(at, { value })
    baseline.sample(at, { value })
end
local original, detailMap = screen.map, detail.map
local late = mipmap.attach(history, feed, 226)
assert(not late.complete, "late attachment must not claim complete recorded history")
local count, last = feed.count, feed.last

screen:restart(226, 100)
equal(screen.map.width, 226)
equal(screen.startedAt, 0)
assert(not screen.complete and screen.map.at == 100)
assert(screen.map ~= original and detail.map == detailMap)
equal(feed.count, count)
equal(feed.last, last)
observed.sample(110, { 0.7 })
baseline.sample(110, { 0.7 })
equal(screen.map.at, 110)
equal(detail.map.at, 110)
equal(late.map.at, 110)
equal(original.at, 100, "retired screen map still receives input")
assert(not late.complete)
for _, owner in ipairs({ screen, late }) do
    for _ = 1, 2000 do
        if owner:step() then
            break
        end
    end
    assert(owner.complete, "reconstruction must finish while telemetry continues")
end
assert(not pcall(screen.restart, screen, 0, 110))
assert(not pcall(screen.restart, screen, 226, -1))
equal(screen.map.width, 226, "invalid restart changed the live map")

local retired = screen.map
screen:destroy()
screen:destroy()
assert(screen.map == nil and screen.history == nil and screen.feed == nil)
observed.sample(120, { 0.9 })
baseline.sample(120, { 0.9 })
equal(retired.at, 110)
equal(detail.map.at, 120)
equal(feed.count, baseline.feeds[1].count)
for index = feed.first, feed.last do
    local a, b, c, d = history:point(feed, index)
    local x, y, z, w = baseline.history:point(baseline.feeds[1], index)
    assert(a == x and b == y and c == z and d == w, "consumer lifecycle changed shared recording")
end
assert(not pcall(history.unobserveSamples, history, feed, screen), "invalid detachment must fail explicitly")
assert(not pcall(history.unobserveSamples, history, {}, detail))

local index = 1
repeat
    index = history:resetSession(200, index)
until not index
assert(detail.complete and late.complete, "new recording must enable complete coverage")
equal(detail.startedAt, 0)
equal(late.map.at, nil)
equal(retired.at, 110, "destroyed consumer was reset")
observed.sample(210, { 0.4 })
equal(detail.map.at, 0)
equal(late.map.at, 0)
detail:destroy()
late:destroy()
local entry = history.views[feed]
assert(entry.observers == nil, "empty observer registry retains consumers")
assert(not pcall(screen.restart, screen, 398, 210))

-- Physical restarts do not accumulate callbacks or change a sibling consumer.
local sibling = mipmap.attach(history, feed, 800)
local panel = mipmap.attach(history, feed, 398)
for at = 220, 320, 10 do
    panel:restart(at % 20 == 0 and 226 or 398, at - 210)
    observed.sample(at, { at / 1000 })
    equal(#entry.observers, 2)
    equal(sibling.map.at, at - 210)
    equal(panel.map.at, at - 210)
end
panel:destroy()
equal(#entry.observers, 1)
sibling:destroy()
assert(entry.observers == nil)
print("Chart-local mipmap consumer lifetime preserves shared history and other consumers")
