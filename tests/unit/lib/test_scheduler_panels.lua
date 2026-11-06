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
        mode = "mixed",
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
    host.owners = { ["panel:sample"] = "new" }
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
        assert(host:ready(context), table.concat(errors, "\n"))
        host:begin(kind or "steady")
        host:finish(kind or "steady")
    end
    return context, host, add, run, errors
end

do
    local context, host, add, run = fixture()
    local first, second = add("first"), add("second")
    run()
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
    local kept = host.panelTasks[second]
    table.remove(context.panels, 1)
    local replacement = add("first")
    run()
    assert(host.panelTasks[first] == nil and host.panelTasks[replacement], "same-count replacement retires old task")
    assert(host.panelTasks[second] == kept, "surviving placements keep their task")
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
    assert(bad.failed and healthy.instance.runs == 1, "one failed panel cannot stop another")
    assert(#errors == 0, "task errors are reported at the next callback head")
    assert(host:report(context) and #errors == 1)
    assert(not host:report(context) and #errors == 1, "a retired task is reported once")
    assert(host.panelTasks[bad] == nil and not host.scheduler.byId["panel:bad"])
    now = now + 10
    run()
    assert(healthy.instance.runs == 2)
end

print("Scheduler panel lifecycle passed")
