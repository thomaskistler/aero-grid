-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."
assert(loadfile(root .. "/tests/support/edgetx.lua"))().constants()
getTime = function()
    return 1100
end
local function load(relative, ...)
    local path = string.sub(relative, 1, 9) == "@support/" and root .. "/tests/support/" .. string.sub(relative, 10)
        or root .. "/src/WIDGETS/AeroGrid/" .. relative
    return assert(loadfile(path))(...)
end
local fixture = load("@support/scheduler_registration_fixture.lua")(load)
local host = load("lib/scheduler_host.lua")
local function finish(state)
    for _ = 1, 2000 do
        local done, ok, message = state.registration.advance(state.job)
        if done then
            return ok, message
        end
    end
    error("configuration model load did not finish")
end
for _, scenario in ipairs({
    "missing",
    "valid",
    "recovered",
    "obsolete",
    "large",
    "schema0",
    "damaged",
    "edited",
    "plain",
    "read-error",
    "unreadable",
}) do
    local state = fixture("empty", 1, scenario)
    local context, owner = state.context, state.owner
    context.panels, context.panelHost = {}, load("lib/panel_host.lua")
    local scheduling = host.attach(context, {
        mode = "mixed",
        load = load,
        api = {
            log = function(_, message)
                error(message)
            end,
        },
    })
    for _ = 1, 8 do
        assert(scheduling:ready(context))
    end
    local flight, smart =
        assert(context.scheduler.byId["service:flight"]), assert(context.scheduler.byId["service:smart"])
    assert(context.scheduler:reschedule(flight.id, 47) and context.scheduler:reschedule(smart.id, 83))
    local before = {}
    for filename, text in pairs(state.files) do
        before[filename] = text
    end
    local ok, message = finish(state)
    if state.expected then
        assert(ok, message)
        assert(owner.documentLoaded and not owner.loadError)
        local actual, expected = owner.document, state.expected
        assert(actual.revision == expected.revision and actual.armed == expected.armed)
        assert(actual.sessionReset == expected.sessionReset)
        if expected.flight then
            assert(owner.config.key(actual.flight) == owner.config.key(expected.flight))
            assert(actual.flight.announcements == nil and actual.flight.history == nil)
        else
            assert(actual.flight == nil)
        end
        for key, value in pairs(state.expectedInfo) do
            assert(state.job.loadInfo[key] == value)
        end
        for key, value in pairs(state.job.loadInfo) do
            assert(state.expectedInfo[key] == value)
        end
    else
        assert(not ok and type(message) == "string")
        assert(message == state.expectedInfo, "synchronous load diagnostics are preserved verbatim")
        assert(owner.documentLoaded and owner.loadError == message and not owner.document)
    end
    for filename, text in pairs(state.files) do
        assert(before[filename] == text, "load never writes")
    end
    for filename, text in pairs(before) do
        assert(state.files[filename] == text)
    end
    assert(scheduling:ready(context))
    assert(context.scheduler.byId[flight.id] == flight and context.scheduler.byId[smart.id] == smart)
    assert(context.scheduler:dueOf(flight.id) == 47 and context.scheduler:dueOf(smart.id) == 83)
    local completed = assert(state.registration.beginLoad(context, state.store))
    assert(completed.done and completed.ok == ok, "same-model reload uses cached success or load error")
    local done, repeated, repeatedMessage = state.registration.advance(state.job)
    assert(done and repeated == ok and repeatedMessage == message, "load result is idempotent")
end

do
    local state = fixture("empty", 1, "valid")
    local original = state.job
    state.owner:reset("other.yml")
    state.owner:reset(state.context.modelFilename)
    local done, ok, message = state.registration.advance(original)
    assert(done and not ok and string.find(message, "load was replaced", 1, true))
    assert(
        not state.owner.documentLoaded and not state.owner.document and not state.owner.loadError,
        "an ABA model switch must not let an old load publish or poison its successor"
    )
end

do
    local state = fixture("empty", 1, "valid")
    state.runtime.byId.armed = nil
    assert(finish(state), "document loading precedes Armed construction")
    state.runtime.modelArmed = state.owner.document.armed
    local armed = load("lib/armed_service.lua").new(state.owner.env, load("lib/services.lua"), state.runtime)
    state.runtime.byId.armed = armed
    assert(armed:state("L01").key == "L02", "initial dashboard Armed captures the loaded model selection")
    state.job = assert(state.registration.begin(state.context))
    assert(finish(state))
    assert(state.member.declarations[1].armKey == "L02")
end

do
    local state = fixture("empty", 1, "valid")
    for _ = 1, 200 do
        if state.job.stage == "publish" then
            break
        end
        assert(not state.registration.advance(state.job))
    end
    assert(state.job.stage == "publish")
    state.context.serviceRuntime = nil
    assert(finish(state), "an already-started publication drains through a same-model registry gap")
    assert(state.owner.document.revision == 4 and not state.owner.publication)
end

do
    local state = fixture("empty", 1, "valid")
    state.job = assert(state.registration.begin(state.context, { store = state.store }))
    assert(finish(state), "registration can explicitly append the owning document-load tail")
    assert(not state.member.pending and state.owner.document.revision == 4)
end

for _, changed in ipairs({ "context", "model", "retirement" }) do
    local state = fixture("empty", 1, "large")
    assert(not state.registration.advance(state.job))
    if changed == "context" then
        state.context.serviceRuntime = {}
    elseif changed == "model" then
        state.owner.env.getInfo = function()
            return { filename = "other.yml" }
        end
    else
        state.owner:disableScheduler(state.context)
    end
    local ok, message = finish(state)
    assert(not ok and type(message) == "string" and not state.owner.document)
    assert(
        not state.owner.documentLoaded and not state.owner.loadError,
        "retired loads do not poison a replacement host"
    )
end

do
    local state = fixture("empty", 1, "valid")
    state.owner.members[state.context].declarations = nil
    local replacement = { flightFactory = state.context.flightFactory }
    assert(not state.registration.beginLoad(replacement, state.store), "nonowners cannot duplicate the canonical load")
end
print("Bounded Flight registration model loading passed")
