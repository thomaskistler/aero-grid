-- SPDX-License-Identifier: GPL-2.0-only

local renderer = { RUNTIME_API = 1 }
renderer.__index = renderer

function renderer.new(context)
    local self = setmetatable({
        context = context,
        width = context.area.w // 1,
        geometry = context.geometryVersion,
        objects = {},
        connections = {},
        connected = {},
        visible = {},
        seriesRoots = {},
        published = {},
        changes = {},
        prepareIndex = 1,
    }, renderer)
    self.root = lvgl.box(context.plotRoot, { x = 0, y = 0, w = context.rect.w, h = context.rect.h })
    lvgl.hide(self.root)
    return self
end

function renderer:prepare(allowance)
    local context, width = self.context, self.width
    local remaining, used = allowance or 2000, 0
    while true do
        if #self.seriesRoots < #context.series then
            local index = #self.seriesRoots + 1
            local cost = 300
            if remaining < cost then
                return false, used
            end
            self.seriesRoots[index] = lvgl.box(self.root, { x = 0, y = 0, w = context.rect.w, h = context.rect.h })
            remaining, used = remaining - cost, used + cost
        else
            break
        end
    end
    while true do
        local index = self.prepareIndex
        if index > width * #context.series then
            return true, used
        end
        local cost = 600
        if remaining < cost then
            return false, used
        end
        local series, bucket = (index - 1) // width + 1, (index - 1) % width
        local object = lvgl.rectangle(self.seriesRoots[series], {
            x = context.area.x + bucket,
            y = 0,
            w = 1,
            h = 1,
            thickness = 0,
            filled = true,
            color = context.series[series].color,
        })
        self.objects[index] = object
        self.connections[index] = lvgl.line(self.seriesRoots[series], {
            pts = { { 0, 0 }, { 0, 0 } },
            thickness = 1,
            color = context.series[series].color,
        })
        lvgl.hide(self.connections[index])
        self.visible[index] = true
        self.prepareIndex = index + 1
        remaining, used = remaining - cost, used + cost
    end
end

function renderer:reset()
    self.jobs, self.published = nil, {}
    self.resetIndex = 1
    lvgl.hide(self.root)
end

function renderer:resetStep(allowance)
    local remaining, used = allowance or 2000, 0
    while true do
        local index = self.resetIndex
        if index > #self.objects then
            self.resetIndex = nil
            return true, used
        end
        local cost = (self.visible[index] or self.connected[index]) and 200 or 25
        if remaining < cost then
            return false, used
        end
        if self.visible[index] then
            lvgl.hide(self.objects[index])
            self.visible[index] = nil
        end
        if self.connected[index] then
            lvgl.hide(self.connections[index])
            self.connected[index] = nil
        end
        self.resetIndex = index + 1
        remaining, used = remaining - cost, used + cost
    end
end

function renderer:destroy()
    lvgl.hide(self.root)
    self.root:clear()
end

function renderer:selection()
    local context, area = self.context, self.context.area
    local jobs, changed = {}, false
    for series, owner in ipairs(context.columnConsumers) do
        local map = owner.map
        local item = context.series[series]
        local previous, summary = self.published[series], map
        local first, last = 0, self.width - 1
        local same = previous
            and previous.map == map
            and previous.geometry == context.geometryVersion
            and previous.low == item.low
            and previous.high == item.high
        changed = changed or not same or previous.revision ~= map.revision
        if same then
            first = math.max(first, previous.pixelAt or 0)
            last = math.min(last, map:pixel(map.at or 0) // 1)
        end
        jobs[series] = {
            map = map,
            index = first,
            first = first,
            last = last,
            at = map.at,
            pixelAt = map:pixel(map.at or 0) // 1,
            connectors = map:seamConnectors(),
            revision = map.revision,
            historyRevision = map.historyRevision,
            low = item.low,
            high = item.high,
            geometry = context.geometryVersion,
            tags = summary.tags,
            lows = summary.low,
            highs = summary.high,
            widths = summary.widths,
            froms = summary.froms,
            left = area.x,
            top = area.y,
            height = area.h,
            placeX = self.geometry ~= context.geometryVersion,
        }
    end
    return jobs, changed
end

--- Project only changed columns; connections are clipped to fixed bounds.
function renderer:begin(jobs)
    self.jobs = jobs
end

local function connection(job, bucket, width, from, to)
    if not from or width == 0 then
        return nil
    end
    local left, right = bucket - width, bucket
    local low, high, height, top = job.low, job.high, job.height, job.top
    if left >= 0 and from >= low and from <= high and to >= low and to <= high then
        return {
            { job.left + left, top + math.floor((high - from) * height / (high - low) + 0.5) },
            { job.left + right, top + math.floor((high - to) * height / (high - low) + 0.5) },
        }
    end
    local first, last = math.max(0, -left / width), 1
    local delta = to - from
    if delta == 0 then
        if from < job.low or from > job.high then
            return nil
        end
    else
        local a, b = (job.low - from) / delta, (job.high - from) / delta
        first, last = math.max(first, math.min(a, b)), math.min(last, math.max(a, b))
    end
    if first > last then
        return nil
    end
    return {
        {
            job.left + math.floor(left + first * width + 0.5),
            top + math.floor((high - (from + first * delta)) * height / (high - low) + 0.5),
        },
        {
            job.left + math.floor(left + last * width + 0.5),
            top + math.floor((high - (from + last * delta)) * height / (high - low) + 0.5),
        },
    }
end

local function draw(self, job, series, allowance)
    if job.index > job.last then
        return 0
    end
    local width, changes = self.width, self.changes
    local objects, visible = self.objects, self.visible
    local tags, lows, highs = job.tags, job.lows, job.highs
    local placeX = job.placeX
    local minimum, maximum = math.min, math.max
    local finish, remaining = job.index - 1, allowance
    local slot, offset = job.index + 1, (series - 1) * width
    local topEdge, lowEdge = job.top, job.low
    local left = job.left
    local scale = job.height / (job.high - lowEdge)
    local bottom = topEdge + job.height
    local set = objects[1].set
    changes.x = nil
    for bucket = job.index, job.last do
        local index = offset + slot
        local populated = tags[slot] == bucket + 1
        local from, span = job.froms[slot], job.widths[slot]
        local cost = 75
        if populated then
            cost = 500
            if not from or span == 0 then
                cost = 200
            elseif
                bucket - span >= 0
                and from >= lowEdge
                and from <= job.high
                and lows[slot] >= lowEdge
                and lows[slot] <= job.high
            then
                cost = 260
            end
        end
        if cost > remaining then
            break
        end
        remaining, finish = remaining - cost, bucket
        if populated then
            local low, high = lows[slot], highs[slot]
            local top = maximum(topEdge, minimum(bottom, (bottom - (high - lowEdge) * scale + 0.5) // 1))
            local last = maximum(topEdge, minimum(bottom, (bottom - (low - lowEdge) * scale + 0.5) // 1))
            changes.y, changes.h = top, last - top + 1
            if placeX or not visible[index] then
                changes.x = left + bucket
            end
            set(objects[index], changes)
            changes.x = nil
            if not visible[index] then
                lvgl.show(objects[index])
                visible[index] = true
            end
            local points = connection(job, bucket, span, from, low)
            if points then
                self.connections[index]:set({ pts = points })
                if not self.connected[index] then
                    lvgl.show(self.connections[index])
                    self.connected[index] = true
                end
            elseif self.connected[index] then
                lvgl.hide(self.connections[index])
                self.connected[index] = nil
            end
        elseif visible[index] then
            lvgl.hide(objects[index])
            visible[index] = nil
        end
        if not populated and self.connected[index] then
            lvgl.hide(self.connections[index])
            self.connected[index] = nil
        end
        slot = slot + 1
    end
    job.index = finish + 1
    return allowance - remaining
end

local function project(self, allowance)
    local consumed = 0
    if self.resetIndex then
        local complete
        complete, consumed = self:resetStep(allowance)
        if not complete then
            return false, consumed
        end
    end
    if not self.jobs then
        if allowance - consumed < 450 then
            return false, consumed
        end
        local jobs, changed = self:selection()
        consumed = consumed + #jobs * 150
        if not changed then
            return true, consumed
        end
        self:begin(jobs)
    end
    local complete = true
    for series, job in ipairs(self.jobs) do
        consumed = consumed + draw(self, job, series, allowance - consumed)
        -- Publish this horizon before chasing newer samples. Polling every
        -- callback must not keep an owner alive forever and starve other charts.
        complete = complete and job.index > job.last
    end
    if complete and consumed + 200 <= allowance then
        self.published, self.jobs = self.jobs, nil
        lvgl.show(self.root)
        consumed = consumed + 200
        for series, job in ipairs(self.published) do
            local item = self.context.series[series]
            item.drawnRevision, item.drawnVersion = job.historyRevision, self.context.version
        end
    else
        complete = false
    end
    return complete, consumed
end

function renderer:step(allowance)
    return project(self, allowance)
end

return renderer
