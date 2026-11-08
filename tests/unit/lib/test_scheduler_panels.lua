-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."
local panelHost = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/panel_host.lua"))()
local scheduling = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/scheduler_host.lua"))()
local now = 100
getTime = function()
    return now
end

local function fixture(exclusive)
    local errors = {}
    local context = { panels = {}, panelHost = panelHost }
    local host = scheduling.attach(context, {
        load = function(relative)
            return assert(loadfile(root .. "/src/WIDGETS/AeroGrid/" .. relative))()
        end,
        api = {
            log = function(_, message)
                errors[#errors + 1] = message
            end,
            error = function(_, message)
                errors[#errors + 1] = message
            end,
            show = function() end,
        },
    })
    local module = {
        id = "sample",
        decl = {
            class = "normal",
            exclusive = exclusive or false,
            kinds = { steady = true },
            stages = { run = { fixed = 0, perUnit = 100, maxUnits = 1 } },
        },
        step = function(instance, grant, stage, stamp)
            assert(grant == 1 and stage == "run" and stamp == now)
            instance.runs = instance.runs + 1
            return instance.delay, instance.unfinished
        end,
    }
    local function add(id)
        local entry = {
            placement = { id = id },
            module = module,
            instance = { runs = 0 },
            interval = 10,
            nextRefresh = now,
        }
        context.panels[#context.panels + 1] = entry
        context.panelTasksDirty = true
        return entry
    end
    local function run(kind)
        if
            host.reconciliation
            or host.checked ~= context.panels
            or host.registry ~= context.serviceRuntime
            or context.panelTasksDirty
        then
            for _ = 1, 512 do
                assert(host:ready(context), table.concat(errors, "\n"))
                if not host.reconciliation then
                    break
                end
            end
            assert(not host.reconciliation, "bounded reconciliation must eventually finish")
        end
        assert(host:ready(context), table.concat(errors, "\n"))
        host:finish(kind or "steady")
    end
    return context, host, add, run, errors
end

do
    local context, host, add, run = fixture()
    local first, second = add("first"), add("second")
    run()
    assert(first.instance.runs == 1 and second.instance.runs == 0, "enrollment is bounded to one placement")
    assert(host.pendingPanels[second])
    assert(host.panelEntries[first] and host.panelEntries[second], "both placements were reconciled")
    run()
    assert(not host.pendingPanels)
    assert(first.instance.runs == 1 and second.instance.runs == 1, "same-type placements have independent releases")
    assert(host.scheduler.byId["panel:first"] and host.scheduler.byId["panel:second"])
    local task = host.panelTasks[first]
    local release = host.scheduler.byId[task.id].due
    context.serviceRuntime = { order = {}, byId = {} }
    assert(host:ready(context))
    assert(
        host.panelTasks[first] == task and host.scheduler.byId[task.id].due == release,
        "service registry changes preserve panel tasks and pending releases"
    )
    now = now + 5
    run()
    assert(first.instance.runs == 1, "a placement cannot run twice before its next release")
    now = now + 5
    run("background")
    assert(first.instance.runs == 1 and second.instance.runs == 1, "hidden panels are ineligible")
    run()
    assert(first.instance.runs == 2 and second.instance.runs == 2, "background does not consume panel releases")
end

do
    local context, host, add, run = fixture()
    local first, second = add("first"), add("second")
    run()
    run()
    local kept = host.panelTasks[second]
    table.remove(context.panels, 1)
    local replacement = add("first")
    run()
    assert(host.panelTasks[first] == nil and host.panelTasks[replacement], "same-count replacement retires old task")
    assert(host.panelTasks[second] == kept, "surviving placements keep their task")
    assert(not host.panelEntries[first] and host.panelEntries[replacement])
    now = now + 10
    run()
    assert(first.instance.runs == 1 and replacement.instance.runs == 2, "retired panel is never called again")
    context.panels = {}
    run()
    assert(
        next(host.panelTasks) == nil
            and host.scheduler.byId["panel:first"] == nil
            and host.scheduler.byId["panel:second"] == nil,
        "page retirement removes every panel task"
    )
end

do
    local _, host, add, run = fixture(true)
    local first, second = add("first"), add("second")
    run()
    assert(first.instance.runs + second.instance.runs == 1, "only one exclusive panel per callback")
    now = now + 1
    run()
    assert(first.instance.runs == 1 and second.instance.runs == 1, "another chart gets the next callback")
    assert(host.scheduler.lastPlan.ran == 1)
end

do
    local _, host, add, run = fixture()
    local entry = add("staged")
    entry.instance.delay, entry.instance.unfinished = 25, true
    run()
    assert(entry.interval == 25 and entry.nextRefresh == now + 1, "unfinished work resumes after one tick")
    now = now + 1
    entry.instance.unfinished = nil
    run()
    assert(entry.nextRefresh == now + 25 and host.scheduler.byId["panel:staged"].due == now + 25)
end

for _, failure in ipairs({ "raise", "interval" }) do
    local context, host, add, run, errors = fixture()
    local bad, healthy = add("bad"), add("healthy")
    if failure == "raise" then
        bad.module = {
            id = "sample",
            decl = healthy.module.decl,
            step = function()
                error("deliberate panel failure")
            end,
        }
    else
        bad.instance.delay = 0
    end
    run()
    assert(bad.failed and healthy.instance.runs == 0, "later placements wait for bounded enrollment")
    assert(#errors == 0, "task errors are reported at the next callback head")
    assert(host:report(context) and #errors == 1)
    assert(not host:report(context) and #errors == 1, "a retired task is reported once")
    assert(host.panelTasks[bad] == nil and not host.scheduler.byId["panel:bad"])
    run()
    assert(healthy.instance.runs == 1, "one failed panel cannot stop another")
    now = now + 10
    run()
    assert(healthy.instance.runs == 2)
end

do
    local context, host, add, run = fixture()
    local first, pending, last = add("first"), add("pending"), add("last")
    run()
    assert(host.pendingPanels[pending] and host.pendingPanels[last])
    context.panels = { last }
    run()
    assert(not host.pendingPanels and host.panelTasks[last])
    assert(not host.panelTasks[first] and not host.panelTasks[pending])
    assert(not host.panelEntries[first] and not host.panelEntries[pending] and host.panelEntries[last])
    assert(not host.scheduler.byId["panel:first"] and not host.scheduler.byId["panel:pending"])
    assert(first.instance.runs == 1 and pending.instance.runs == 0 and last.instance.runs == 1)
end

do
    local context, host, add, _, errors = fixture()
    local entry = add("invalid")
    entry.instance = nil
    for _ = 1, 16 do
        if not host:ready(context) then
            break
        end
    end
    assert(#errors == 1 and string.find(errors[1], "has no task instance", 1, true))
    assert(not host.scheduler.byId["panel:invalid"])
end

do
    local context, host, add, run = fixture()
    local releases = {}
    local clock = {
        id = "clock",
        count = 1,
        interval = 10,
        decl = { class = "normal", stages = { run = { fixed = 0, perUnit = 100, maxUnits = 1 } } },
        step = function()
            releases[#releases + 1] = now
            return 10
        end,
    }
    context.serviceRuntime = { order = { clock }, byId = { clock = clock } }
    run()
    local serviceTask = assert(host.scheduler.byId["service:clock"])
    releases = {}
    now = now + 10
    local entries = {}
    for index = 1, 16 do
        entries[index] = add("placement-" .. index)
    end
    for index = 1, 16 do
        run()
        local count = 0
        for _ in pairs(host.panelTasks) do
            count = count + 1
        end
        assert(count == index and host.panelTasks[entries[index]], "each callback enrolls exactly one placement")
        assert(#releases == index and releases[index] == now, "enrollment preserves ten-tick service releases")
        local current = host.scheduler.byId["service:clock"]
        assert(current == serviceTask, "partial enrollment must not resync service tasks")
        now = now + 10
    end
    assert(not host.pendingPanels)
    run()
end

do
    local context, host, add, run = fixture()
    local idleModule = { id = "sample", idle = true }
    local first, active, last = add("idle-first"), add("active"), add("idle-last")
    first.module, last.module = idleModule, idleModule
    run()
    assert(active.instance.runs == 1, "idle placements do not consume the enrollment slot")
    assert(host.panelEntries[first] and host.panelEntries[last])
    assert(not host.panelTasks[first] and not host.panelTasks[last] and not host.pendingPanels)
    assert(host.scheduler.count == 1)
    now = now + 10
    run("background")
    assert(active.instance.runs == 1 and not host.panelTasks[first])
    local activeModule = active.module
    active.module, context.panelTasksDirty = idleModule, true
    run()
    assert(host.scheduler.count == 0 and not host.panelTasks[active])
    assert(host.panelEntries[active])
    active.module, context.panelTasksDirty = activeModule, true
    run()
    assert(host.panelTasks[active] and active.instance.runs == 2, "leaving idle enrolls a genuine task")
    context.panels = { active }
    run()
    assert(not host.panelEntries[first] and not host.panelEntries[last])
end

do
    local context, host, add, run = fixture()
    local entries = {}
    for index = 1, 16 do
        entries[index] = add("idle-" .. index)
        entries[index].module = { id = "sample", idle = true }
    end
    run()
    assert(host.scheduler.count == 0 and not host.pendingPanels)
    run()
    for _, entry in ipairs(entries) do
        assert(host.panelEntries[entry])
    end
    context.panels = {}
    run()
    for _, entry in ipairs(entries) do
        assert(not host.panelEntries[entry])
    end
end

do
    local context, host, add, _, errors = fixture()
    local entry = add("not-idle")
    entry.module = { id = "sample", idle = true, refresh = function() end }
    for _ = 1, 16 do
        if not host:ready(context) then
            break
        end
    end
    assert(string.find(errors[1], "declares idle but has periodic work", 1, true))
    assert(host.scheduler.count == 0)
end

do
    local context, host, add, run = fixture()
    local entry = add("missing-task")
    entry.module = { id = "sample" }
    assert(not pcall(run), "a missing task is not an implicit idle declaration")
    assert(host.pendingPanels[entry], "rejected metadata cannot silently consume its pending entry")
    assert(not host:ready(context), "subsequent admission cannot turn rejection into success")
end

print("Scheduler panel lifecycle passed")
