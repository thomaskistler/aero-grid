-- SPDX-License-Identifier: GPL-2.0-only

-- Recording time stops while the editor or model settings is open: charts queue
-- nothing, draw nothing, and resume with one ordinary pause gap afterwards.
local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local chart = fixture.module("panels/chart.lua")
assert(loadfile(root .. "/tests/support/chart_turns.lua"))().install(chart)
local recorder = assert(loadfile(root .. "/tests/support/chart_recorder.lua"))(root)
local view = assert(loadfile(root .. "/tests/support/chart_assertions.lua"))()
local equal = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual
fixture.reset()
local dashboard = fixture.createLoaded(nil, { Layout = "Empty", Theme = "modern-dark" })
local now = 0

local function nativeState()
    local writes = 0
    for _, object in ipairs(fixture.lvglMock.objects) do
        writes = writes + (rawget(object, "writes") or 0) + (rawget(object, "visibilityCalls") or 0)
    end
    return #fixture.lvglMock.objects, writes
end

local function run(duration, editingKey)
    local record = recorder(3)
    local host = {}
    record.history.runtime.host = host
    local services = dashboard.dashboardLoader.buildServices(dashboard, { col = 0, row = 0, colSpan = 2, rowSpan = 1 })
    services.history, services.clock = record.history, function()
        return now
    end
    local panel = chart.create(dashboard.page, { x = 0, y = 0, w = 472, h = 196 }, {
        armSwitch = "L01",
        duration = duration,
        metrics = {
            { source = record.feeds[1].name },
            { source = record.feeds[2].name },
            { source = record.feeds[3].name },
        },
    }, services)
    local session, grant, due, base = record.session, 1, 0, now
    local function advance(to)
        while now < to do
            now = now + 5
            if now % 20 == 0 then
                record.sample(now, { (now * 7) % 997, -(now % 389), (now % 600) - 300 })
            end
            if now >= due then
                grant = 3 - grant
                local offered = chart.offered(panel, grant)
                local interval, _, used = chart.refresh(panel, false, grant)
                assert(used >= 1 and used <= offered, "refreshes must stay within the grant")
                due = now + interval
            end
        end
    end
    advance(base + 9000)
    local elapsed, resumes = session.elapsed, session.resumeLast
    assert(session.recording and elapsed > 8000)

    -- Five minutes of editing: no time, no samples, no queue, no drawing.
    local objects, writes = nativeState()
    host[editingKey] = {}
    if editingKey == "editorUi" then
        panel.host = { editorUi = true }
    end
    advance(now + 40)
    local frozenAt, revision = session.elapsed, record.feeds[1].plotRevision
    local worstPending = 0
    while now < base + 9000 + 30000 do
        advance(now + 100)
        equal(session.recording, false, "editing must pause recording")
        equal(session.elapsed, frozenAt, "recording time must not advance while editing")
        for _, owner in ipairs(panel.columnConsumers) do
            worstPending = math.max(worstPending, #owner.pending)
        end
    end
    equal(worstPending, 0, "no readings may queue while editing")
    equal(record.feeds[1].plotRevision, revision, "no readings may be recorded while editing")
    if editingKey == "editorUi" then
        local afterObjects, afterWrites = nativeState()
        equal(afterObjects, objects, "editing must not create native objects")
        equal(afterWrites, writes, "editing must not change native objects")
    end

    -- Closing resumes the recording with one pause gap; charts carry on.
    host[editingKey], panel.host = nil, nil
    advance(now + 6000)
    equal(session.resumeLast, resumes + 1, "the editing period must become one pause")
    assert(session.elapsed > frozenAt + 5000, "recording time must advance again")
    local pauseAt = record.history:recordingBreak(session, session.resumeLast)
    equal(pauseAt, frozenAt, "the pause sits where recording time stopped")
    for _ = 1, 400 do
        local _, pending = chart.refresh(panel, false, 8)
        local waiting = false
        for _, owner in ipairs(panel.columnConsumers) do
            waiting = waiting or #owner.pending > 0 or owner.tail ~= nil
        end
        if not pending and not waiting and view.finished(panel) then
            break
        end
    end
    for index, owner in ipairs(panel.columnConsumers) do
        local map = owner.map
        local gap = map:bucketOf(pauseAt, map:gapCount(pauseAt))
        local pauses, after = 0, 0
        for slot = 1, map.width do
            pauses = pauses + (map.kinds[slot] == "pause" and 1 or 0)
            after = after + (slot - 1 > gap and map.kinds[slot] == "data" and 1 or 0)
        end
        assert(pauses == 1, "series " .. index .. " must show exactly one pause gap")
        assert(after > 0, "series " .. index .. " must draw readings after the pause")
        equal(#owner.pending, 0)
    end
    assert(#view.rectangles(panel, 1) > 0, "the chart must keep drawing after editing")
    if duration then
        -- 150 recorded seconds: a two-minute window has slid by one minute.
        equal(panel.window, duration * 6000)
        equal(panel.start, 6000, "a fixed window keeps sliding by recorded time")
    else
        equal(panel.window, 18000, "an Auto window keeps growing by recorded time")
    end
    chart.destroy(panel)
end

run(2, "editorUi")
run(nil, "editorUi")
run(2, "modelSettingsUi")
print("Recording time freezes while editing; charts queue and draw nothing, then resume with one pause")
