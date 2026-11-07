-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."
assert(loadfile(root .. "/tests/support/edgetx.lua"))().constants()
local function load(relative, ...)
    local path = string.sub(relative, 1, 9) == "@support/" and root .. "/tests/support/" .. string.sub(relative, 10)
        or root .. "/src/WIDGETS/AeroGrid/" .. relative
    return assert(loadfile(path))(...)
end
local case = assert(loadfile(root .. "/tests/fixtures/scheduler-cases/flight-publication.lua"))()(load)
local function notified(state)
    local count = 0
    for _, host in ipairs(state.hosts) do
        if not host.navigationHomes.retained then
            count = count + 1
        end
    end
    return count
end
for _, example in ipairs(case.cases) do
    local task, _, state = example.setup()
    local owner, action = state.owner, state.action
    local before, revision = notified(state), owner.factory.revision
    assert(task:step(1, example.stage) == 1)
    assert(notified(state) - before <= 1, "one publication turn cannot fan out")
    if action == "begin" then
        assert(state.job and owner.document == state.previous)
        assert(not owner:startPublication(state.document), "concurrent publication must be rejected")
    elseif
        action == "model-change"
        or action == "model-reset"
        or action == "superseded"
        or action == "identity-error"
    then
        assert(state.done and state.ok == false and type(state.error) == "string")
        assert(notified(state) == before and not owner.publication, "terminal failure stops fanout")
    elseif action == "finish" or action == "repeat" then
        assert(state.done and state.ok == true and not state.error)
    elseif example.stage == "commit" then
        assert(owner.document == state.document and owner.factory.revision == revision + 1)
        assert(owner.state.configurationRevision == 2 and owner.documentLoaded)
        assert(action == "commit" and not state.done or action ~= "commit" and state.done)
    end
    if
        action ~= "model-change"
        and action ~= "model-reset"
        and action ~= "superseded"
        and action ~= "identity-error"
    then
        local job = assert(state.job)
        for _ = 1, #state.hosts * 3 + 5 do
            before = notified(state)
            local done, ok, message = owner:advancePublication(job)
            assert(notified(state) - before <= 1, "bounded notification during completion")
            if done then
                assert(ok, message)
                break
            end
        end
        assert(job.done and job.ok, "publication eventually completes")
        for index, host in ipairs(state.hosts) do
            if owner.members[host] and action ~= "unchanged" and action ~= "first" then
                assert(not host.navigationHomes.retained)
                local matching = host.modelFilename == owner.filename
                assert((host.modelArmingReload == true) == matching)
                assert((state.members[index].pending == true) == matching)
                assert(host.reloadState == (matching and "clear" or nil))
            end
        end
        assert(owner.document == state.document and owner.state.configurationRevision == 2)
        assert(state.document.armed == (action == "unchanged" and "L01" or "L02"))
        assert(state.document.modelFilename == "model1.yml" and state.document.sessionReset == "L03")
        local finalRevision = owner.factory.revision
        assert(owner:advancePublication(job))
        assert(owner.factory.revision == finalRevision, "terminal advancement is idempotent")
    end
end

do
    local _, _, state = case.cases[1].setup()
    local owner = state.owner
    local job = assert(owner:startPublication(state.document))
    state.filename = "other.yml"
    local done, ok, message = owner:advancePublication(job)
    assert(done and ok == false and string.find(message, "Model changed", 1, true))
    assert(owner.document == state.previous and owner.factory.revision == 1, "precommit failure has no effects")
    assert(not owner:startPublication(state.document), "wrong-model start is rejected")
    assert(not owner:startPublication({}), "a validated model identity is required")
    assert(select(2, owner:advancePublication({})) == false)
end

do
    local _, _, state = case.cases[14].setup()
    local owner = state.owner
    local old = assert(owner:startPublication(state.document))
    owner:setDocument(state.previous)
    local current = assert(owner:startPublication(state.document))
    local done, ok = owner:advancePublication(old)
    assert(done and ok == false and owner.publication == current, "stale jobs cannot retire newer publication")
    owner:resetSession(2000)
    for _ = 1, 5 do
        done, ok = owner:advancePublication(current)
        if done then
            break
        end
    end
    assert(done and ok and owner.document == state.document, "session reset does not cancel a confirmed model save")
end

do
    local _, _, state = case.cases[1].setup()
    local owner = state.owner
    local job = assert(owner:startPublication(state.document))
    owner.env.getInfo = function()
        error("identity unavailable")
    end
    local done, ok, message = owner:advancePublication(job)
    assert(done and not ok and string.find(message, "identity unavailable", 1, true))
    assert(owner.document == state.previous and owner.factory.revision == 1 and not owner.publication)
    local nextJob, nextError = owner:startPublication(state.document)
    assert(not nextJob and string.find(nextError, "identity unavailable", 1, true))
    done, ok, message = owner:advancePublication(job)
    assert(done and not ok and message == nextError, "failed publication has a stable terminal result")
end

do
    local _, _, state = case.cases[27].setup()
    local owner = state.owner
    local job = assert(owner:startPublication(state.document))
    assert(not owner:advancePublication(job))
    owner:setDocument(state.document)
    assert(notified(state) == state.size, "synchronous replacement completes outstanding member invalidation")
    local done, ok = owner:advancePublication(job)
    assert(done and ok == false and owner.document == state.document)
end
print("Bounded Flight document publication passed")
