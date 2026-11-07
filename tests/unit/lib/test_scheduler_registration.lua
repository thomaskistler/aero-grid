-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."
assert(loadfile(root .. "/tests/support/edgetx.lua"))().constants()
local function load(relative, ...)
    local path = string.sub(relative, 1, 9) == "@support/" and root .. "/tests/support/" .. string.sub(relative, 10)
        or root .. "/src/WIDGETS/AeroGrid/" .. relative
    return assert(loadfile(path))(...)
end
local fixture = load("@support/scheduler_registration_fixture.lua")(load)
local scheduler = load("lib/scheduler.lua")
local function finish(state)
    for _ = 1, state.size * 20 + 100 do
        local job = state.job
        local stage, declarations = job.stage, #job.declarations
        local retained, sourceIndex = job.cursor, job.index
        local done, ok, message = state.registration.advance(job)
        assert(#job.declarations - declarations <= 1, "only one declaration per callback")
        if stage == "sources" then
            assert(job.index - sourceIndex <= 1)
        end
        if stage == "retained" and job.cursor ~= retained then
            assert(job.stage == stage or job.stage == "sources")
        end
        if stage ~= "commit" and not job.done then
            assert(state.member.declarations == state.original, "member metadata commits atomically")
        end
        if done then
            return ok, message
        end
    end
    error("registration did not finish")
end
for _, variant in ipairs({ "empty", "legacy", "model", "normal", "critical", "cached" }) do
    for _, size in ipairs({ 1, 16, 128, 512 }) do
        local state = fixture(variant, size)
        local s = scheduler.new({ steady = 1250, background = 1130 })
        state.context.scheduler = s
        for index, item in ipairs(state.owner.schedulerTasks) do
            assert(s:add({ id = item.id, decl = item.instance.decl, instance = item.instance, due = index * 37 }))
        end
        local first, second = s.byId["service:flight"], s.byId["service:smart"]
        local ok, message = finish(state)
        assert(ok, message)
        local synchronous = fixture(variant, size)
        synchronous.registration.configure(synchronous.context)
        local expected = {}
        for _, declaration in ipairs(synchronous.member.declarations) do
            expected[declaration.source] = declaration
        end
        local control, synchronousControl = state.runtime.byId.control, synchronous.runtime.byId.control
        for _, group in ipairs({ "critical", "normal" }) do
            local entries, expectedEntries = control[group .. "Entries"], synchronousControl[group .. "Entries"]
            assert(#entries == #expectedEntries, "bounded claims remove exactly the synchronous readers")
            for index, entry in ipairs(entries) do
                assert(entry.state.name == expectedEntries[index].state.name, "claim removal preserves polling order")
            end
            assert(control[group .. "Cursor"] == synchronousControl[group .. "Cursor"], "claim cursor parity")
            assert(control[group .. "Remaining"] == synchronousControl[group .. "Remaining"], "claim cycle parity")
            assert(control.tasks[group].want == synchronousControl.tasks[group].want, "claim demand parity")
        end
        assert(state.member.pending == false and state.member.error == nil)
        assert(state.member.modelFilename == "model1.yml" and state.member.layoutName == "Registration")
        assert(#state.member.declarations == (variant == "empty" and 1 or size * 2))
        assert(s.byId[first.id] == first and s.byId[second.id] == second)
        assert(s:dueOf(first.id) == 37 and s:dueOf(second.id) == 74, "registration never retimes canonical releases")
        for _, declaration in ipairs(state.member.declarations) do
            local previous = assert(expected[declaration.source])
            assert(previous.armKey == declaration.armKey, "synchronous declaration parity")
            if previous.settings then
                assert(state.owner.config.key(previous.settings) == state.owner.config.key(declaration.settings))
            else
                assert(not declaration.settings)
            end
            assert(
                declaration.armKey
                    == (
                        variant == "model" and "L02"
                        or state.context.document.legacyFlightArms and state.context.document.legacyFlightArms[declaration.source]
                        or ""
                    )
            )
        end
        local revision = state.owner.factory.revision
        assert(state.registration.advance(state.job))
        assert(state.owner.factory.revision == revision, "completion is idempotent")
    end
end
for _, failure in ipairs({ "retained", "switch", "source", "replacement", "model", "identity" }) do
    local state = fixture("legacy", 16)
    if failure == "retained" then
        state.job.original.bad = 42
    elseif failure == "switch" then
        state.job.original.bad = "not-a-switch"
    elseif failure == "source" then
        state.context.flightSources[1].id = 42
    elseif failure == "replacement" then
        state.context.serviceRuntime = {}
    elseif failure == "model" then
        state.context.modelFilename = "other.yml"
    else
        state.owner.env.getInfo = function()
            error("model identity unavailable")
        end
    end
    local ok, message = finish(state)
    assert(not ok and type(message) == "string")
    assert(state.member.declarations == state.original, "failed registration retains member metadata")
    assert(
        state.context.document.legacyFlightArms == state.job.original,
        "failed registration does not partially publish retained arms"
    )
    assert(state.owner.schedulerEnabled, "configuration errors do not disable canonical tasks")
end
print("Bounded Flight registration passed")
