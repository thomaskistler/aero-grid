-- SPDX-License-Identifier: GPL-2.0-only

local load = assert(...)
local mipmap = load("lib/chart_mipmap.lua")
local recorder = load("tests/support/mipmap_recorder.lua", nil, load)
local prototype = {}
prototype.__index = prototype
local makeJob, draw, drawScroll
local function checkpoint() end

function prototype.new(chart, width, background)
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
    if background then
        lvgl.rectangle(self.root, {
            x = chart.area.x,
            y = chart.area.y,
            w = chart.area.w + 1,
            h = chart.area.h + 1,
            filled = true,
            thickness = 0,
            color = background,
        })
    end
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
    if self.groupedScroll and not self.groups then
        assert(self.width % 4 == 0, "grouped scrolling requires integral quarter-columns")
        assert(
            self.chart.area.w % 1 == 0 and self.chart.area.x % 1 == 0,
            "grouped scrolling requires integral plot geometry"
        )
        self.groups, self.groupOffsets, self.objectGroups = {}, {}, {}
        self.groupChanges = {}
        self.groupScale, self.groupLeft = self.chart.area.w / self.width, self.chart.area.x + 0.5
        self.groupReady = true
    end
    if self.groups and #self.groups < 16 * #self.maps then
        local group = #self.groups + 1
        self.groups[group] = lvgl.box(self.root, { x = 0, y = 0, w = self.chart.rect.w, h = self.chart.rect.h })
        self.groupOffsets[group] = 0
        return false
    end
    if index <= self.width * #self.maps then
        local series = (index - 1) // self.width + 1
        local parent = self.root
        if self.groups then
            local bucket = (index - 1) % self.width
            local quarter = bucket // (self.width / 4)
            local phase = ((bucket * self.chart.area.w + self.width / 2) % self.width * 4) // self.width
            local group = (series - 1) * 16 + quarter * 4 + phase + 1
            self.objectGroups[index], parent = group, self.groups[group]
        end
        self.objects[index] = lvgl.vline(parent, {
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
    self.jobKind = operation
    self.repairs = 0
    self.sampleUpdates = 0
    self.shifted = 0
    self.groupMoves = 0
    self.startedAt, self.finishedAt = getTime(), nil
    self.completedAt = nil
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
    local operation = self.jobKind or self.operation
    local height = area.h * (operation == "vertical" and 0.75 or 1)
    local scale = area.w / self.width * (operation == "resize" and 0.75 or 1)
    if operation == "scroll" or operation == "append" and previous then
        height, scale = previous.height, previous.scale
    end
    local first, last = origin // 1, (origin + self.width - 1) // 1
    if operation == "append" and previous and previous.level == level and previous.origin == origin then
        first = math.max(first, (previous.at * self.width / summary.span) // 1)
        last = math.min(last, (map.at * self.width / summary.span) // 1)
    elseif
        (operation == "vertical" or operation == "resize")
        and previous
        and previous.level == level
        and previous.origin == origin
    then
        -- The published frame already hid every column beyond the newest reading.
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
        revision = map.revision,
        span = summary.span,
        scale = scale,
        height = height,
        bottom = area.y + height + 0.5,
        left = area.x + 0.5,
        low = summary.low,
        high = summary.high,
        tags = summary.tags,
        offsets = self.groupActive and self.groupOffsets,
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

--- Quarter and subpixel-phase groups share an exact integer native translation.
function prototype:shiftGroups(job, series)
    local width, scale, origin = self.width, job.scale, job.origin
    for quarter = 0, 3 do
        local base = (origin // width) * width + quarter * width / 4
        if base < origin then
            base = base + width
        end
        local delta = (base - quarter * width / 4 - origin) * scale
        for phase = 0, 3 do
            local group = (series - 1) * 16 + quarter * 4 + phase + 1
            local shift = delta // 1 + (phase / 4 + delta % 1 >= 1 and 1 or 0)
            self.groupChanges.x = shift
            self.groups[group]:set(self.groupChanges)
            self.groupOffsets[group] = shift
        end
    end
    self.groupActive, job.offsets = true, self.groupOffsets
    self.groupMoves = self.groupMoves + 16
    job.index = math.max(job.first, job.retainedLast + 1)
    job.scroll, job.updateX = false, false
end

function prototype:resetGroups()
    if self.groupActive then
        self.groupChanges.x = 0
        for index, group in ipairs(self.groups) do
            group:set(self.groupChanges)
            self.groupOffsets[index] = 0
        end
        self.groupActive = false
    end
    self.groupReady = false
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
                    if job.offsets then
                        changes.x = changes.x - job.offsets[self.objectGroups[index]]
                    end
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
                if job.offsets then
                    changes.x = changes.x - job.offsets[self.objectGroups[index]]
                end
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
        local changed = false
        if self.live then
            for series, map in ipairs(self.maps) do
                changed = changed or self.published[series].revision ~= map.revision
            end
        end
        if not changed then
            return 1
        end
        self.active, self.admitted, self.preparedJobs = true, true, false
        self.finishedAt, self.jobKind = nil, "append"
    end
    self.turns = self.turns + 1
    self:checkpoint("start")
    local admitting = not self.admitted
    if admitting then
        self:sample(self.nextStamp)
        self.admitted = true
    end
    self:checkpoint("recording")
    -- Sample observers have already updated every retained level synchronously.
    self.lastWork = 0
    self:checkpoint("maintenance")
    if not self.preparedJobs then
        local grouped, reset = self.groupReady == true, false
        for series = 1, #self.maps do
            self.jobs[series] = makeJob(self, series)
            local job = self.jobs[series]
            grouped = grouped and job.scroll and job.scale == self.groupScale and job.left == self.groupLeft
            reset = reset or job.updateX
        end
        if grouped then
            for series, job in ipairs(self.jobs) do
                self:shiftGroups(job, series)
            end
        elseif self.groups and reset then
            local active = self.groupActive
            self:resetGroups()
            for _, job in ipairs(self.jobs) do
                job.offsets, job.updateX = nil, active or job.updateX
            end
        end
        self.preparedJobs = true
    end
    self:checkpoint("setup")
    local complete = true
    self.shifted = self.shifted or 0
    for series, job in ipairs(self.jobs) do
        local start, quota = job.index
        if job.scroll then
            quota = math.min(self.batch, math.max(1, 400 // #self.maps))
            if admitting then
                quota = math.min(quota, math.max(1, 300 // #self.maps))
            end
            drawScroll(self, job, series, quota)
        else
            quota = math.min(self.batch, job.updateX and 90 or 130)
            if admitting then
                quota = math.min(quota, 24)
            end
            if job.catchup then
                job.last = math.min((job.map.at * self.width / job.span) // 1, (job.origin + self.width - 1) // 1)
                if job.last < job.index + quota then
                    job.at, job.revision = job.map.at, job.map.revision
                end
            end
            draw(self, job, series, quota)
        end
        local remaining = quota - (job.index - start)
        if job.index > job.last then
            local level, origin = job.map:select(self.clock)
            if level ~= job.level or origin ~= job.origin then
                -- A further level/window boundary invalidates geometry, not history.
                local kind = self.jobKind
                self.jobKind = "refresh"
                self.jobs[series] = makeJob(self, series)
                self.jobs[series].height, self.jobs[series].bottom = job.height, job.bottom
                self.jobs[series].scale, self.jobs[series].left = job.scale, job.left
                if self.groupActive then
                    self:resetGroups()
                    for _, pending in ipairs(self.jobs) do
                        pending.offsets, pending.updateX = nil, true
                        pending.index = pending.first
                    end
                end
                self.jobKind = kind
                complete = false
                self.repairs = self.repairs + 1
            elseif job.revision ~= job.map.revision then
                local first = (job.at * self.width / job.span) // 1
                local last = (job.map.at * self.width / job.span) // 1
                job.index = math.max(first, job.first)
                job.last = math.min(last, (job.origin + self.width - 1) // 1)
                job.at, job.revision = job.map.at, job.map.revision
                job.scroll, job.updateX = false, false
                job.catchup = true
                if remaining > 0 then
                    draw(self, job, series, remaining)
                end
                complete = complete and job.index > job.last
                self.repairs = self.repairs + 1
            end
        else
            complete = false
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
    self.completedAt = self.completedAt or self.finishedAt
    return 1
end

function prototype:verify()
    for series, job in ipairs(self.published) do
        if self.live then
            assert(job.revision == job.map.revision, "published view missed an incoming reading")
        end
        for bucket = job.origin // 1, (job.origin + self.width - 1) // 1 do
            local slot = (series - 1) * self.width + bucket % self.width + 1
            local low, high, gap = job.map:column(job.level, bucket)
            assert(self.visible[slot] == not gap, "prototype gap visibility differs from summary")
            if not gap then
                local properties = self.objects[slot].properties
                local top = (job.bottom - high * job.height) // 1
                local offset = job.offsets and job.offsets[self.objectGroups[slot]] or 0
                if job.offsets then
                    assert(self.groups[self.objectGroups[slot]].properties.x == offset, "native parent x differs")
                end
                assert(
                    properties.x + offset == (job.left + (bucket - job.origin) * job.scale) // 1,
                    "prototype x differs"
                )
                assert(properties.y == top, "prototype top differs")
                assert(properties.h == (job.bottom - low * job.height) // 1 - top + 1, "prototype span differs")
            end
        end
    end
end

return prototype
