-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local path = root .. "/build/test-widget-fixture/"
for _, parked in ipairs({
    "loaded",
    "scheduled",
    "flight-identity",
    "flight-store-writer",
    "flight-store-create",
    "flight-load-begin",
    "flight-load",
    "publish",
    "cancelled",
}) do
    fixture.reset()
    local definition = fixture.module("main.lua")
    local originalFilename = fixture.radio.modelFilename
    local function create()
        return definition.create(
            { x = 0, y = 0, w = 480, h = 272 },
            { Layout = "review-flight-mode", Theme = "modern-dark" },
            path
        )
    end
    local function step(context)
        fixture.tick(10)
        definition.background(context)
    end
    local function settle(context)
        for _ = 1, 2000 do
            if
                not context.stage
                and not context.reloadState
                and context.modelFilename == fixture.radio.modelFilename
            then
                return
            end
            step(context)
        end
        error("model-switch Flight loading stalled: " .. tostring(context.stage))
    end
    local first = create()
    if parked == "loaded" or parked == "scheduled" then
        settle(first)
    else
        for _ = 1, 2000 do
            local work = first.flightLoading
            if
                parked == "publish" and work and work.job and work.job.stage == "publish"
                or parked ~= "publish" and first.stage == (parked == "cancelled" and "flight-load" or parked)
            then
                break
            end
            step(first)
        end
        assert(first.flightLoading)
        if parked == "cancelled" then
            first.reloadState = "clear"
        end
    end
    local owner = assert(first.flightBroker)
    local records
    if parked == "scheduled" then
        local host = first.schedulerHost
        local owners = {}
        for key, value in pairs(host.owners) do
            owners[key] = value
        end
        owners["service:flight"], owners["service:smart"] = "new", "new"
        host.owners = owners
        owner:enableScheduler(first)
        for _ = 1, 128 do
            assert(host:ready(first))
        end
        records = { first.scheduler.byId["service:flight"], first.scheduler.byId["service:smart"] }
        assert(records[1] and records[2])
        assert(first.scheduler:reschedule("service:flight", 47000))
        assert(first.scheduler:reschedule("service:smart", 83000))
    end
    local stale = first.flightLoading and first.flightLoading.job
    local second = create()
    if parked == "loaded" or parked == "scheduled" then
        settle(second)
    end
    local owning = owner:owningContext()
    fixture.radio.modelFilename = "switched-" .. parked .. ".yml"
    local fresh, observer = create(), create()
    for _ = 1, 2000 do
        if fresh.stage == "flight-load" then break end
        step(fresh)
    end
    assert(fresh.stage == "flight-load" and owner:loadingContext() == fresh)
    local loads, startLoad = 0, owner.store.startLoad
    owner.store.startLoad = function(self, filename)
        loads = loads + 1
        return startLoad(self, filename)
    end
    settle(observer)
    settle(fresh)
    assert(loads == 1, "other new-model widgets must help the elected load instead of starting duplicates")
    assert(fresh.flightBroker == owner and observer.flightBroker == owner)
    assert(owner.filename == fixture.radio.modelFilename and owner.documentLoaded)
    assert(owner.document.modelFilename == fixture.radio.modelFilename)
    assert(owner:owningContext() == owning, "document initialization must not transfer canonical scheduler ownership")
    if records then
        assert(
            first.scheduler.byId["service:flight"] == records[1] and first.scheduler.byId["service:smart"] == records[2]
        )
        assert(
            first.scheduler:dueOf("service:flight") == 47000 and first.scheduler:dueOf("service:smart") == 83000,
            "model initialization preserves the parked scheduler's exact task releases"
        )
        assert(owner:schedulerService(fresh) == nil and owner:schedulerService(first))
    end
    assert(#fresh.errors == 0 and #observer.errors == 0)
    local document = owner.document
    if stale then
        local done, ok = first.flightRegistration.advance(stale)
        assert(done and not ok, "an old-model load must terminate without publishing")
        assert(owner.document == document)
    end
    if first.stage and first.stage ~= "flight-identity" then
        first.dashboardLoader.advanceLoad(first)
        assert(first.reloadState == "clear", "stale pre-job loader stages must cancel before shared mutation")
        assert(owner.document == document)
    end
    first.reloadState = "clear"
    settle(first)
    second.reloadState = "clear"
    settle(second)
    assert(first.modelFilename == fixture.radio.modelFilename and second.modelFilename == fixture.radio.modelFilename)
    assert(owner.document == document, "returning old widgets must reuse the new-model document")
    assert(owner:owningContext() == owning)
    fixture.radio.modelFilename = originalFilename
end
print("Flight model-switch loading with parked owners passed")
