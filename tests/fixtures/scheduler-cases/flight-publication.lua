-- SPDX-License-Identifier: GPL-2.0-only

return function(load)
    local fixture = load("@support/scheduler_flight_fixture.lua")(load)
    local stages, cases = {}, {}
    for stage, cost in pairs({ begin = 150, commit = 200, member = 160, finish = 160, reject = 140 }) do
        stages[stage] = { fixed = 0, perUnit = cost, maxUnits = 1 }
    end
    for _, size in ipairs({ 0, 1, 16, 128 }) do
        for _, action in ipairs({
            "begin",
            "commit",
            "member",
            "finish",
            "unchanged",
            "first",
            "model-change",
            "model-reset",
            "superseded",
            "repeat",
            "join",
            "retire",
            "identity-error",
        }) do
            local stage = action == "begin" and "begin"
                or (action == "commit" or action == "unchanged" or action == "first") and "commit"
                or (action == "member" or action == "join" or action == "retire") and "member"
                or (action == "finish" or action == "repeat") and "finish"
                or "reject"
            cases[#cases + 1] = {
                stage = stage,
                grant = 1,
                setup = function()
                    local owner, radio, _, original = fixture("run")
                    owner.members[original] = nil
                    owner.factory = { members = owner.members, revision = 1 }
                    local state = {
                        owner = owner,
                        hosts = {},
                        members = {},
                        size = size,
                        action = action,
                        filename = owner.filename,
                        previous = owner.document,
                    }
                    owner.env.getInfo = function()
                        return { filename = state.filename }
                    end
                    owner.document.armed = "L01"
                    local function add(index)
                        local host = {
                            modelFilename = index % 3 == 0 and "other.yml" or owner.filename,
                            navigationHomes = { retained = true },
                        }
                        local member = { modelFilename = host.modelFilename, declarations = {} }
                        owner.members[host] = member
                        state.hosts[#state.hosts + 1], state.members[#state.members + 1] = host, member
                    end
                    for index = 1, size do
                        add(index)
                    end
                    state.document = {
                        modelFilename = owner.filename,
                        revision = 2,
                        armed = action == "unchanged" and "L01" or "L02",
                        sessionReset = "L03",
                        flight = owner.document.flight,
                    }
                    if action == "first" then
                        owner.document = nil
                    end
                    if action ~= "begin" then
                        state.job = assert(owner:startPublication(state.document))
                        if stage ~= "commit" then
                            owner:advancePublication(state.job)
                            if action == "finish" or action == "repeat" then
                                for _ = 1, size do
                                    owner:advancePublication(state.job)
                                end
                                if action == "repeat" then
                                    assert(owner:advancePublication(state.job))
                                end
                            elseif action == "model-change" then
                                state.filename = "other.yml"
                            elseif action == "identity-error" then
                                owner.env.getInfo = function()
                                    error("identity unavailable")
                                end
                            elseif action == "model-reset" then
                                owner:reset(owner.filename)
                            elseif action == "superseded" then
                                owner:setDocument(state.previous)
                            elseif action == "join" or action == "retire" then
                                if size > 0 then
                                    owner:advancePublication(state.job)
                                end
                                if action == "join" then
                                    add(size + 1)
                                elseif state.job.cursor then
                                    owner.members[state.job.cursor] = nil
                                end
                                owner.factory.revision = owner.factory.revision + 1
                            end
                        end
                    end
                    return {
                        stage = stage,
                        step = function()
                            if action == "begin" then
                                state.job, state.error = owner:startPublication(state.document)
                            else
                                state.done, state.ok, state.error = owner:advancePublication(state.job)
                            end
                            return 1
                        end,
                    },
                        radio.now,
                        state
                end,
            }
        end
    end
    return {
        id = "broker:document-publication",
        decl = { class = "normal", first = "begin", stages = stages },
        cases = cases,
    }
end
