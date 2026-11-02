-- SPDX-License-Identifier: GPL-2.0-only

local load = assert(...)
local mipmap = load("lib/chart_mipmap.lua")
local recorder = load("tests/support/mipmap_recorder.lua", nil, load)
local prototype = {}
prototype.__index = prototype
local makeJob, draw, drawScroll
local function checkpoint() end

function prototype.new(chart, width)
    local record = recorder(#chart.series)
    local self = setmetatable({
        chart = chart,
        width = width,
        record = record,
        maps = {},
        objects = {},
        visible = {},
        changes = {},
        prepareIndex = 1,
        sequence = 0,
        clock = 0,
        values = {},
        jobs = {},
        published = {},
        batch = 130,
        checkpoint = checkpoint,
        sampleTicks = 20,
    }, prototype)
    for series = 1, #chart.series do
        local map = mipmap.new(width)
        self.maps[series] = map
        record.history:observeSamples(record.feeds[series], map)
    end
    self.root = lvgl.box(chart.plotHost, { x = 0, y = 0, w = chart.rect.w, h = chart.rect.h })
    lvgl.hide(self.root)
    self:sample(0)
    return self
end

function prototype:sample(at, missing)
    self.sequence = self.sequence + 1
    for series = 1, #self.maps do
        self.values[series] = ((self.sequence * 17 + series * 13) % 70) / 100
    end
    self.record.sample(at, self.values, missing)
    self.sampleUpdates = 0
    for _, map in ipairs(self.maps) do
        self.sampleUpdates = self.sampleUpdates + mipmap.LAST_LEVEL - map.level + 1
    end
    self.clock = at
end

--- Warm initialization is separate from timed admission of each new reading.
function prototype:prepare()
    local index = self.prepareIndex
    if index <= self.width * #self.maps then
        local series = (index - 1) // self.width + 1
        self.objects[index] = lvgl.vline(self.root, {
            x = 0,
            y = 0,
            w = 1,
            h = 1,
            color = self.chart.series[series].color,
        })
        lvgl.hide(self.objects[index])
        self.visible[index], self.prepareIndex = false, index + 1
        return false
    end
    if self.clock < 5900 then
        local count = math.min(4, math.ceil(20 / self.sampleTicks))
        for _ = 1, count do
            self:sample(math.min(5900, self.clock + self.sampleTicks))
            if self.clock == 5900 then
                break
            end
        end
        return false
    end
    if not self.warmJobs then
        self.operation, self.warmJobs = "initial", {}
        for series = 1, #self.maps do
            self.warmJobs[series] = makeJob(self, series)
        end
    end
    local drawn = true
    for series, job in ipairs(self.warmJobs) do
        drawn = draw(self, job, series, 24) and drawn
    end
    if drawn then
        lvgl.show(self.root)
        self.published, self.warmJobs = self.warmJobs, nil
    end
    return drawn
end

--- Populate and publish a maximum-level window before measuring a real scroll.
function prototype:prepareScroll()
    if self.scrollFixtureReady then
        return true
    end
    local span = self.maps[1].levels[mipmap.LAST_LEVEL].span
    local target = math.ceil(span) - 1
    if self.clock < target then
        local ticks = math.max(1, (span / self.width) // 1)
        for _ = 1, 4 do
            self:sample(math.min(target, self.clock + ticks), self.scrollGaps and self.sequence % 53 == 0)
            if self.clock == target then
                break
            end
        end
        return false
    end
    if not self.scrollWarmJobs then
        self.operation, self.scrollWarmJobs = "initial", {}
        for series = 1, #self.maps do
            self.scrollWarmJobs[series] = makeJob(self, series)
        end
    end
    local complete = true
    for series, job in ipairs(self.scrollWarmJobs) do
        complete = draw(self, job, series, 24) and complete
    end
    if complete then
        self.published, self.scrollWarmJobs = self.scrollWarmJobs, nil
        self.scrollFixtureReady = true
        for _, job in ipairs(self.published) do
            job.map:releaseBelow(job.level)
        end
    end
    return complete
end

function prototype:begin(operation)
    assert(not self.active)
    self.operation, self.turns, self.mapped, self.submitted = operation, 0, 0, 0
    self.sampleUpdates = 0
    self.shifted = 0
    self.startedAt, self.finishedAt = getTime(), nil
    self.limit = (operation == "append" or operation == "scroll") and 2 or 5
    if operation == "append" and #self.maps == 1 then
        self.limit = 1
    end
    local stamp = self.clock + 20
    if operation == "horizontal" then
        stamp = 6001
    elseif operation == "scroll" then
        local previous = self.published[1]
        assert(previous.level == mipmap.LAST_LEVEL, "scroll fixture must publish the maximum level first")
        local span = self.maps[1].levels[mipmap.LAST_LEVEL].span
        stamp = math.ceil(span * (1 + previous.origin / self.width))
    end
    self.nextStamp, self.active, self.admitted = stamp, true, false
    self.preparedJobs = false
end

makeJob = function(self, series)
    local map, area = self.maps[series], self.chart.area
    local level, origin = map:select(self.clock)
    local summary, previous = map.levels[level], self.published[series]
    local operation = self.operation
    local height = area.h * (operation == "vertical" and 0.75 or 1)
    local scale = area.w / self.width * (operation == "resize" and 0.75 or 1)
    if operation == "scroll" then
        height, scale = previous.height, previous.scale
    end
    local first, last = origin // 1, (origin + self.width - 1) // 1
    if operation == "append" and previous and previous.level == level and previous.origin == origin then
        first = math.max(first, (previous.at * self.width / summary.span) // 1)
        last = math.min(last, (map.at * self.width / summary.span) // 1)
    end
    return {
        map = map,
        level = level,
        origin = origin,
        first = first,
        last = last,
        index = first,
        at = map.at,
        scale = scale,
        height = height,
        bottom = area.y + height + 0.5,
        left = area.x + 0.5,
        low = summary.low,
        high = summary.high,
        tags = summary.tags,
        scroll = operation == "scroll"
            and previous.level == level
            and previous.height == height
            and previous.scale == scale
            and previous.left == area.x + 0.5
            and origin > previous.origin
            and origin < previous.origin + self.width,
        retainedFirst = previous and previous.origin,
        retainedLast = previous and (previous.at * self.width / summary.span) // 1 - 1,
        updateX = not previous or previous.origin ~= origin or previous.scale ~= scale or previous.left ~= area.x + 0.5,
    }
end

draw = function(self, job, series, quota)
    local width, changes = self.width, self.changes
    local objects, visible = self.objects, self.visible
    local low, high, tags = job.low, job.high, job.tags
    local scale, height, bottom, left = job.scale, job.height, job.bottom, job.left
    local origin, offset = job.origin, (series - 1) * width
    local set = objects[1].set
    local last = math.min(job.last, job.index + quota - 1)
    local slot, submitted = job.index % width + 1, 0
    changes.x = nil
    if not job.updateX then
        for bucket = job.index, last do
            local index = offset + slot
            local object = objects[index]
            if tags[slot] == bucket + 1 then
                local top = (bottom - high[slot] * height) // 1
                changes.y, changes.h = top, (bottom - low[slot] * height) // 1 - top + 1
                if visible[index] then
                    set(object, changes)
                else
                    changes.x = (left + (bucket - origin) * scale) // 1
                    set(object, changes)
                    changes.x = nil
                    lvgl.show(object)
                    visible[index] = true
                end
                submitted = submitted + 1
            elseif visible[index] then
                lvgl.hide(object)
                visible[index] = false
            end
            slot = slot + 1
            if slot > width then
                slot = 1
            end
        end
    else
        for bucket = job.index, last do
            local index = offset + slot
            local object = objects[index]
            if tags[slot] == bucket + 1 then
                local top = (bottom - high[slot] * height) // 1
                changes.x = (left + (bucket - origin) * scale) // 1
                changes.y, changes.h = top, (bottom - low[slot] * height) // 1 - top + 1
                set(object, changes)
                submitted = submitted + 1
                if not visible[index] then
                    lvgl.show(object)
                    visible[index] = true
                end
            elseif visible[index] then
                lvgl.hide(object)
                visible[index] = false
            end
            slot = slot + 1
            if slot > width then
                slot = 1
            end
        end
    end
    self.mapped = (self.mapped or 0) + last - job.index + 1
    self.submitted = (self.submitted or 0) + submitted
    job.index = last + 1
    return job.index > job.last
end

--- Unchanged retained spans need only x; entering/updated spans need full geometry.
drawScroll = function(self, job, series, quota)
    local width, changes = self.width, self.changes
    local objects, visible, tags = self.objects, self.visible, job.tags
    local offset, origin, scale, left = (series - 1) * width, job.origin, job.scale, job.left
    local retainedFirst, retainedLast = job.retainedFirst, job.retainedLast
    local set = objects[1].set
    local last = math.min(job.last, job.index + quota - 1)
    local slot, submitted, shifted = job.index % width + 1, 0, 0
    changes.y, changes.h = nil, nil
    for bucket = job.index, last do
        local index = offset + slot
        local object = objects[index]
        if tags[slot] == bucket + 1 then
            changes.x = (left + (bucket - origin) * scale) // 1
            if visible[index] and bucket >= retainedFirst and bucket <= retainedLast then
                set(object, changes)
                shifted = shifted + 1
            else
                local top = (job.bottom - job.high[slot] * job.height) // 1
                changes.y, changes.h = top, (job.bottom - job.low[slot] * job.height) // 1 - top + 1
                set(object, changes)
                changes.y, changes.h = nil, nil
                if not visible[index] then
                    lvgl.show(object)
                    visible[index] = true
                end
            end
            submitted = submitted + 1
        elseif visible[index] then
            lvgl.hide(object)
            visible[index] = false
        end
        slot = slot + 1
        if slot > width then
            slot = 1
        end
    end
    self.mapped = self.mapped + last - job.index + 1
    self.submitted = self.submitted + submitted
    self.shifted = self.shifted + shifted
    job.index = last + 1
    return job.index > job.last
end

function prototype:step()
    if not self.active then
        return 1
    end
    self.turns = self.turns + 1
    self:checkpoint("start")
    if not self.admitted then
        self:sample(self.nextStamp)
        self.admitted = true
    end
    self:checkpoint("recording")
    -- Sample observers have already updated every retained level synchronously.
    self.lastWork = 0
    self:checkpoint("maintenance")
    if not self.preparedJobs then
        for series = 1, #self.maps do
            self.jobs[series] = makeJob(self, series)
        end
        self.preparedJobs = true
    end
    self:checkpoint("setup")
    local complete = true
    self.shifted = self.shifted or 0
    for series, job in ipairs(self.jobs) do
        if job.scroll then
            local quota = math.min(self.batch, math.max(1, 400 // #self.maps))
            if self.turns == 1 then
                quota = math.min(quota, math.max(1, 300 // #self.maps))
            end
            complete = drawScroll(self, job, series, quota) and complete
        else
            local quota = math.min(self.batch, job.updateX and 90 or 130)
            if self.turns == 1 then
                quota = math.min(quota, 24)
            end
            complete = draw(self, job, series, quota) and complete
        end
    end
    self:checkpoint("drawing")
    if not complete then
        return 1, true
    end
    for _, job in ipairs(self.jobs) do
        job.map:releaseBelow(job.level)
    end
    lvgl.show(self.root)
    self.published, self.jobs = self.jobs, {}
    self.finishedAt, self.active = getTime(), false
    return 1
end

function prototype:verify()
    for series, job in ipairs(self.published) do
        for bucket = job.first, job.last do
            local slot = (series - 1) * self.width + bucket % self.width + 1
            local low, high, gap = job.map:column(job.level, bucket)
            assert(self.visible[slot] == not gap, "prototype gap visibility differs from summary")
            if not gap then
                local properties = self.objects[slot].properties
                local top = (job.bottom - high * job.height) // 1
                assert(properties.x == (job.left + (bucket - job.origin) * job.scale) // 1, "prototype x differs")
                assert(properties.y == top, "prototype top differs")
                assert(properties.h == (job.bottom - low * job.height) // 1 - top + 1, "prototype span differs")
            end
        end
    end
end

return prototype
