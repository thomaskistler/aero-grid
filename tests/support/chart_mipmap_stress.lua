-- SPDX-License-Identifier: GPL-2.0-only

local load = assert(...)
local prototype = load("tests/support/chart_mipmap_prototype.lua", load)
local Oracle = load("tests/support/mipmap_reading_oracle.lua")
local stress = {}
stress.__index = stress
stress.operations = { "append", "horizontal", "vertical", "scroll" }

local function inputs(env, state)
    local field, value = env.getFieldInfo, env.getValue
    local fields, sensors =
        {}, {
            [12] = { type = 0, id = 9, instance = 0, unit = 9, prec = 2 },
            [37] = { type = 0, id = 2, instance = 0, unit = 40, prec = 0 },
            [49] = { type = 0, id = 2, instance = 2, unit = 8, prec = 1 },
            [59] = { type = 0, id = 2, instance = 5, unit = 0, prec = 0 },
        }
    for index = 1, 24 do
        fields["Q" .. index] = { id = 5000 + index, name = "Q" .. index, unit = 1 }
    end
    for index, sensor in pairs(sensors) do
        fields["telem" .. (index + 1)] = { id = 6000 + index * 3, unit = sensor.unit }
    end
    fields.ch3 = { id = 4400, name = "ch3" }
    local gps = { lat = 1, lon = 2, delay = 0 }
    return {
        getFieldInfo = function(name)
            return fields[name] or field(name)
        end,
        getValue = function(id)
            if type(id) == "number" and id > 5000 and id <= 5024 then
                return ((getTime() * 17 + id * 13) % 97 + 1) / 100
            elseif id == 4400 then
                return 0
            end
            return value(id)
        end,
        getRSSI = function()
            return 80
        end,
        getSwitchValue = function()
            return state.armed
        end,
        getModule = function(index)
            return { Type = index == 0 and 5 or 0 }
        end,
        getSensor = function(index)
            return sensors[index]
        end,
        getSourceValue = function(id)
            local index = (id - 6000) / 3
            if index == 37 then
                return gps, true, true
            end
            return index == 59 and 8 or getTime() % 100 / 100, true, true
        end,
    }
end

function stress.new(context, width, batch, integrated)
    assert(#context.panels == 2, "stress fixture requires two competing charts")
    local self = setmetatable({
        context = context,
        width = width,
        batch = batch,
        items = {},
        feeds = {},
        chartSources = {},
        stage = "subscriptions",
        index = 7,
        operationIndex = 0,
        events = {},
        rows = {},
        armed = false,
    }, stress)
    local runtime, owner = context.serviceRuntime, assert(context.flightBroker)
    local overrides = inputs(runtime.env, self)
    for key, fn in pairs(overrides) do
        runtime.env[key], owner.env[key] = fn, fn
    end
    owner:setDocument({
        modelFilename = owner.filename,
        revision = (owner.document and owner.document.revision or 0) + 1,
        armed = "SAv",
        flight = context.flightConfig.resolve({ smartDetection = true }),
    })
    self.history = runtime.byId.history
    for _, entry in ipairs(integrated and {} or context.panels) do
        entry.module.refresh = function(chart, _, slots)
            if self.running then
                local service = self:serviceWork()
                local allowance = service == "telemetry" and 64 or context.flightPolled and 80 or 130
                chart.feasibility.batch = math.min(self.batch, allowance)
                local interval, unfinished = chart.feasibility:step()
                return interval, unfinished, slots or 8
            end
            return 1, false, 0
        end
    end
    return self
end

function stress:prepare(refresh)
    if self.stage == "subscriptions" then
        for _ = 1, 3 do
            self.history:subscribe("Q" .. self.index, { armSwitch = "SAv", precision = 3 })
            self.index = self.index + 1
            if self.index > 24 then
                assert(self.history.count == 24, "stress must record exactly 24 sources")
                self.stage, self.index = "pools", 1
                break
            end
        end
    elseif self.stage == "pools" then
        local entry = self.context.panels[self.index]
        local item = self.items[self.index]
        if not item then
            item = prototype.new(entry.instance, self.width, entry.instance.theme.color.surface)
            item.groupedScroll = true
            item.oracles = {}
            for series, map in ipairs(item.maps) do
                local oracle = Oracle.new()
                oracle:sample(item.clock, item.values[series])
                item.oracles[series] = oracle
                local sample = map.sample
                map.sample = function(target, at, value, broken)
                    oracle:sample(at, value, broken)
                    return sample(target, at, value, broken)
                end
                local reset = map.reset
                map.reset = function(target)
                    oracle.times, oracle.values, oracle.breaks = {}, {}, {}
                    return reset(target)
                end
            end
            item.batch, item.sampleTicks = self.batch, 5
            entry.instance.feasibility = item
            self.items[self.index] = item
            local chartIndex = self.index
            for series, source in ipairs(entry.instance.series) do
                local feed = source.liveFeed or source.feed
                self.feeds[#self.feeds + 1] = feed
                self.chartSources[feed.name] = true
                self.history:observeSamples(feed, {
                    sample = function(_, at, reading, broken)
                        if self.forwarding then
                            local stamp = at + self.offset
                            item.maps[series]:sample(stamp, reading, broken)
                            item.clock = math.max(item.clock, stamp)
                            self.events[#self.events + 1] = { chart = chartIndex, series = series, at = stamp }
                            item.received = (item.received or 0) + 1
                        end
                    end,
                    reset = function()
                        item.maps[series]:reset()
                    end,
                })
            end
        end
        local count = item.prepareIndex <= item.width * #item.maps and 16 or 1
        for _ = 1, count do
            if item:prepare() then
                lvgl.hide(entry.instance.plotRoot)
                lvgl.hide(entry.instance.duration)
                lvgl.hide(entry.instance.durationBackground)
                if entry.instance.backPlot then
                    lvgl.hide(entry.instance.backPlot.plotRoot)
                end
                self.index = self.index + 1
                if self.index > #self.context.panels then
                    self.stage, self.warming, self.armed = "services", 0, false
                end
                break
            end
            if item.prepareIndex > item.width * #item.maps then
                break
            end
        end
    elseif self.stage == "services" then
        refresh(self.context)
        self.warming = self.warming + 1
        if self.warming == 40 then
            self.armed = true
        end
        if self.warming >= 120 then
            local owner = self.context.flightBroker
            assert(owner.session and owner.session.smart, "Smart detection did not start")
            assert(owner.session.smart.altitude.fresh and owner.session.smart.speed.fresh, "Smart inputs are stale")
            for _, feed in ipairs(self.feeds) do
                local session = self.history:session("SAv")
                local reading = self.context.serviceRuntime.byId.telemetry:reading(feed.name)
                assert(
                    feed.available and not feed.full,
                    string.format(
                        "live chart recording unavailable: %s recording=%s segment=%s input=%s at=%s now=%s",
                        feed.name,
                        tostring(session.recording),
                        tostring(session.segment),
                        tostring(reading and reading.available),
                        tostring(reading and reading.updatedAt),
                        tostring(getTime())
                    )
                )
            end
            self.stage = "ready"
            return true
        end
    end
    return false
end

function stress:prepareScroll(refresh)
    refresh(self.context)
    local item = self.items[self.scrollIndex]
    if item:prepareScroll() then
        self.scrollIndex = self.scrollIndex + 1
    end
    return self.scrollIndex > #self.items
end

--- Issue the trigger before a natural chart-source poll, without changing quotas/cursors.
function stress:prepareOperation(refresh)
    local runtime = self.context.serviceRuntime
    local telemetry = runtime.byId.telemetry
    local nextService
    for offset = 0, #runtime.order - 1 do
        local service = runtime.order[(runtime.cursor + offset - 1) % #runtime.order + 1]
        if not service.failed and service.count > 0 and service.due <= getTime() then
            nextService = service.id
            break
        end
    end
    if nextService == "telemetry" then
        for offset = 0, 3 do
            local entry = telemetry.entries[(telemetry.cursor + offset - 1) % #telemetry.entries + 1]
            if self.chartSources[entry.state.name] then
                self.pollWait = 0
                return true
            end
        end
    end
    refresh(self.context)
    self.pollWait = (self.pollWait or 0) + 1
    assert(
        self.pollWait < 120,
        string.format(
            "normal polling never returned to a chart source: next=%s cursor=%d due=%d now=%d",
            tostring(nextService),
            telemetry.cursor,
            telemetry.due,
            getTime()
        )
    )
    return false
end

function stress:begin(operation)
    self.operationIndex = self.operationIndex + 1
    self.operation, self.events = operation, {}
    self.startedAt, self.callbacks = getTime(), 0
    self.running, self.forwarding = true, true
    self.offset = nil
    self.context.refreshOwner = nil
    local session = self.history:session("SAv")
    for _, item in ipairs(self.items) do
        item:begin(operation == "resized_scroll" and "scroll" or operation)
        self.offset = self.offset or item.nextStamp - session.elapsed
        item.admitted, item.live, item.clock, item.received = true, true, item.nextStamp, 0
    end
    for _, entry in ipairs(self.context.panels) do
        entry.nextRefresh = getTime()
    end
end

function stress:serviceWork()
    local runtime = self.context.serviceRuntime
    if runtime.updates == self.updatesBefore then
        return "idle"
    end
    return runtime.order[(runtime.cursor - 2) % #runtime.order + 1].id
end

function stress:step(refresh)
    self.updatesBefore = self.context.serviceRuntime.updates
    refresh(self.context)
    self.lastService, self.smartPolled = self:serviceWork(), self.context.flightPolled == true
    self.callbacks = self.callbacks + 1
    local completed, settled = true, true
    for _, item in ipairs(self.items) do
        completed = completed and item.completedAt ~= nil
        settled = settled and not item.active
        for series, map in ipairs(item.maps) do
            settled = settled and item.published[series].revision == map.revision
        end
    end
    if completed and self.forwarding then
        -- Fence the comparison, not telemetry/recording. Drain all readings
        -- received during both initial redraws before declaring completion.
        self.forwarding, self.fencedAt = false, getTime()
    end
    if self.callbacks > 200 then
        local details = {}
        for index, item in ipairs(self.items) do
            local job = item.jobs[1]
            details[#details + 1] = string.format(
                "%d: turns=%d done=%s active=%s received=%d job=%s/%s",
                index,
                item.turns,
                tostring(item.completedAt),
                tostring(item.active),
                item.received,
                tostring(job and job.index),
                tostring(job and job.last)
            )
        end
        error("continuous stress job failed to converge: " .. table.concat(details, "; "))
    end
    if not settled then
        return false
    end
    self.running, self.finishedAt = false, getTime()
    local turns, repairs, groupMoves = 0, 0, 0
    for _, item in ipairs(self.items) do
        turns, repairs = math.max(turns, item.turns), repairs + item.repairs
        groupMoves = groupMoves + item.groupMoves
    end
    local row = {
        operation = self.operation,
        turns = turns,
        callbacks = self.callbacks,
        setter_complete_ms = (self.finishedAt - self.startedAt) * 10,
        input_events = #self.events,
        catchups = repairs,
        group_moves = groupMoves,
        fenced_at = self.fencedAt * 10,
        output_columns = self.items[1].width,
        native_spans = #self.items[1].objects + #self.items[2].objects,
    }
    self.rows[#self.rows + 1] = row
    return true
end

function stress:verify(geometry)
    for _, item in ipairs(self.items) do
        if geometry ~= false then
            item:verify()
        end
        for series, job in ipairs(geometry ~= false and item.published or {}) do
            for bucket = job.origin, job.origin + item.width - 1 do
                local low, high, gap = item.oracles[series]:column(item.width, job.level, bucket)
                local actualLow, actualHigh, actualGap = job.map:column(job.level, bucket)
                assert(gap == actualGap, "width-column oracle gap differs")
                if not gap then
                    assert(low == actualLow and high == actualHigh, "width-column oracle extrema differ")
                end
            end
        end
    end
    local now, telemetry = getTime(), self.context.serviceRuntime.byId.telemetry
    local oldest = 0
    for index = 1, 24 do
        local reading = assert(telemetry:reading("Q" .. index))
        assert(reading.available and reading.updatedAt, "ordinary telemetry was starved")
        oldest = math.max(oldest, now - reading.updatedAt)
    end
    self.rows[#self.rows].oldest_source_ms = oldest * 10
end

--- Export the complete expected plot, outside timed submission callbacks.
function stress:exportPaint()
    if not self.paintFile then
        self.paintFile = assert(io.open("/paint-" .. self.operationIndex .. ".txt", "w"))
        io.write(
            self.paintFile,
            string.format("%d %d %d\n", self.operationIndex, self.startedAt * 10, self.finishedAt * 10)
        )
        self.paintChart, self.paintSeries, self.paintBucket = 1, 0, 0
    end
    local item, entry = self.items[self.paintChart], self.context.panels[self.paintChart]
    if self.paintSeries == 0 then
        local rect = assert(self.context.grid.rect(self.context.zone, entry.placement, 4, 4, 4))
        local area, zone = item.chart.area, self.context.zone
        self.paintX, self.paintY = rect.x + (zone.xabs or 0), rect.y + (zone.yabs or 0)
        io.write(
            self.paintFile,
            string.format(
                "P %d %d %d %d %d\n",
                self.paintX + area.x,
                self.paintY + area.y,
                area.w + 1,
                area.h + 1,
                item.chart.theme.color.surface
            )
        )
        self.paintSeries, self.paintBucket = 1, 0
    end
    local job = item.published[self.paintSeries]
    local color = item.chart.series[self.paintSeries].color
    for _ = 1, 8 do
        local bucket = job.origin // 1 + self.paintBucket
        local low, high, gap = item.oracles[self.paintSeries]:column(item.width, job.level, bucket)
        if not gap then
            local x = self.paintX + (job.left + (bucket - job.origin) * job.scale) // 1
            local top = (job.bottom - high * job.height) // 1
            local bottom = (job.bottom - low * job.height) // 1
            io.write(self.paintFile, string.format("L %d %d %d %d\n", x, self.paintY + top, bottom - top + 1, color))
        end
        self.paintBucket = self.paintBucket + 1
        if self.paintBucket >= item.width then
            self.paintSeries, self.paintBucket = self.paintSeries + 1, 0
            if self.paintSeries > #item.maps then
                self.paintChart, self.paintSeries = self.paintChart + 1, 0
                if self.paintChart > #self.items then
                    io.close(self.paintFile)
                    self.paintFile = nil
                    return true
                end
            end
            break
        end
    end
    return false
end

return stress
