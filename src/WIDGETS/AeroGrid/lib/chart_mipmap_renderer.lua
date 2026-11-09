-- SPDX-License-Identifier: GPL-2.0-only

local renderer = { RUNTIME_API = 1 }
renderer.__index = renderer

function renderer.new(context)
    local self = setmetatable({
        context = context,
        width = context.area.w // 1,
        geometry = context.geometryVersion,
        objects = {},
        visible = {},
        groups = {},
        offsets = {},
        phases = {},
        membership = {},
        published = {},
        changes = {},
        groupChanges = {},
        prepareIndex = 1,
    }, renderer)
    self.root = lvgl.box(context.plotRoot, { x = 0, y = 0, w = context.rect.w, h = context.rect.h })
    lvgl.hide(self.root)
    return self
end

function renderer:prepare()
    local context, width = self.context, self.width
    if #self.groups < #context.series * 4 then
        local index = #self.groups + 1
        self.groups[index] = lvgl.box(self.root, { x = 0, y = 0, w = context.rect.w, h = context.rect.h })
        self.offsets[index] = 0
        self.phases[(index - 1) // 4 + 1] = 0
        return false
    end
    for _ = 1, 8 do
        local index = self.prepareIndex
        if index > width * #context.series then
            return true
        end
        local series, bucket = (index - 1) // width + 1, (index - 1) % width
        local quarter = math.min(3, ((bucket + 1) * 4 - 1) // width)
        local group = (series - 1) * 4 + quarter + 1
        local object = lvgl.rectangle(self.groups[group], {
            x = context.area.x + bucket,
            y = 0,
            w = 1,
            h = 1,
            thickness = 0,
            filled = true,
            color = context.series[series].color,
        })
        self.objects[index], self.membership[index] = object, group
        self.visible[index] = true
        self.prepareIndex = index + 1
    end
    return false
end

function renderer:reset()
    self.jobs, self.published = nil, {}
    self.resetIndex = 1
    lvgl.hide(self.root)
end

function renderer:resetStep()
    for _ = 1, 8 do
        local index = self.resetIndex
        if index > #self.objects then
            self.resetIndex = nil
            return true
        end
        if self.visible[index] then
            lvgl.hide(self.objects[index])
            self.visible[index] = nil
        end
        self.resetIndex = index + 1
    end
    return false
end

function renderer:destroy()
    lvgl.hide(self.root)
    self.root:clear()
end

function renderer:selection()
    local context, area = self.context, self.context.area
    local jobs, changed = {}, false
    for series, owner in ipairs(context.mipmapConsumers) do
        local at = math.max(0, context.session.elapsed - owner.startedAt)
        local map = owner.output or owner.map
        local level, origin = map:select(map.pinned and 0 or at)
        local item = context.series[series]
        local previous, summary = self.published[series], map.levels[level]
        local first, last = origin, origin + self.width - 1
        local same = previous
            and previous.map == map
            and previous.level == level
            and previous.origin == origin
            and previous.geometry == context.geometryVersion
            and previous.low == item.low
            and previous.high == item.high
        changed = changed or not same or previous.revision ~= map.revision
        local scroll = previous
            and previous.map == map
            and previous.level == level
            and previous.geometry == context.geometryVersion
            and previous.low == item.low
            and previous.high == item.high
            and origin > previous.origin
            and origin < previous.origin + self.width
        if same then
            first = math.max(first, ((previous.at or 0) * self.width / summary.span) // 1)
            last = math.min(last, ((map.at or 0) * self.width / summary.span) // 1)
        end
        jobs[series] = {
            map = map,
            level = level,
            origin = origin,
            index = first,
            first = first,
            last = last,
            at = map.at,
            revision = map.revision,
            historyRevision = map.historyRevision,
            low = item.low,
            high = item.high,
            geometry = context.geometryVersion,
            span = summary.span,
            tags = summary.tags,
            lows = summary.low,
            highs = summary.high,
            left = area.x,
            top = area.y,
            height = area.h,
            updateX = not previous
                or previous.map ~= map
                or previous.origin ~= origin
                or previous.geometry ~= context.geometryVersion,
            placeX = self.geometry ~= context.geometryVersion,
            scroll = scroll,
            retainedLast = scroll and ((previous.at or 0) * self.width / summary.span) // 1 - 1,
        }
    end
    return jobs, changed
end

--- Every draw uses one ring layout: object x is left + slot and each quarter
--- group carries the origin, so a later scroll may retain any prior frame.
function renderer:begin(jobs)
    local grouped, reset = true, false
    for _, job in ipairs(jobs) do
        grouped = grouped and job.scroll
        reset = reset or job.updateX
    end
    self.jobs = jobs
    -- Any origin change, including a scroll, marks its job as moving in x.
    if not reset then
        return
    end
    for series, job in ipairs(jobs) do
        local phase, moved = job.origin % self.width, false
        if self.phases[series] ~= phase then
            self.phases[series] = phase
            for quarter = 0, 3 do
                local group = (series - 1) * 4 + quarter + 1
                local offset = (quarter * self.width / 4) // 1 < phase and self.width - phase or -phase
                if self.offsets[group] ~= offset then
                    self.groupChanges.x = offset
                    self.groups[group]:set(self.groupChanges)
                    self.offsets[group], moved = offset, true
                end
            end
        end
        if grouped then
            job.index = math.max(job.index, job.retainedLast + 1)
            job.updateX = false
        elseif moved and not job.updateX then
            job.updateX, job.index, job.last = true, job.origin, job.origin + self.width - 1
        end
    end
end

local function draw(self, job, series, quota, activating)
    if job.index > job.last then
        return 0
    end
    local width, changes = self.width, self.changes
    local objects, visible = self.objects, self.visible
    local tags, lows, highs = job.tags, job.lows, job.highs
    local placeX = job.placeX
    local minimum, maximum = math.min, math.max
    local finish = math.min(job.last, job.index + quota - 1)
    local slot, offset = job.index % width + 1, (series - 1) * width
    local topEdge, lowEdge = job.top, job.low
    local left, origin = job.left, job.origin
    local scale = job.height / (job.high - lowEdge)
    local bottom = topEdge + job.height
    local set = objects[1].set
    changes.x = nil
    for bucket = job.index, finish do
        local index = offset + slot
        if tags[slot] == bucket + 1 then
            local low, high = lows[slot], highs[slot]
            local top = maximum(topEdge, minimum(bottom, (bottom - (high - lowEdge) * scale + 0.5) // 1))
            local last = maximum(topEdge, minimum(bottom, (bottom - (low - lowEdge) * scale + 0.5) // 1))
            changes.y, changes.h = top, last - top + 1
            if placeX or not visible[index] then
                if not activating and not visible[index] then
                    job.activate, finish = true, bucket - 1
                    break
                end
                changes.x = left + bucket - origin - self.offsets[self.membership[index]]
            end
            set(objects[index], changes)
            changes.x = nil
            if not visible[index] then
                lvgl.show(objects[index])
                visible[index] = true
            end
        elseif visible[index] then
            lvgl.hide(objects[index])
            visible[index] = nil
        end
        slot = slot % width + 1
    end
    local consumed = finish - job.index + 1
    job.index = finish + 1
    return consumed
end

function renderer:step(quota)
    if self.resetIndex and not self:resetStep() then
        return false
    end
    if not self.jobs then
        local jobs, changed = self:selection()
        if not changed then
            return true
        end
        self:begin(jobs)
    end
    local complete = true
    for series, job in ipairs(self.jobs) do
        local activating = job.activate
        job.activate = nil
        local limit = math.min(quota, job.updateX and 90 or 130)
        -- Revealing a hidden column also places it and calls native show.
        local used = draw(self, job, series, activating and math.max(1, limit // 2) or limit, activating)
        used = activating and used * 2 or used
        local remaining = limit - used
        if job.activate and remaining >= 2 then
            job.activate = nil
            remaining = remaining - draw(self, job, series, remaining // 2, true) * 2
        end
        if job.index > job.last and job.revision ~= job.map.revision then
            job.index = math.max(job.origin, ((job.at or 0) * self.width / job.span) // 1)
            job.last = math.min(job.origin + self.width - 1, ((job.map.at or 0) * self.width / job.span) // 1)
            job.at, job.revision, job.updateX = job.map.at, job.map.revision, false
            job.historyRevision = job.map.historyRevision
            if remaining > 0 then
                draw(self, job, series, remaining)
            end
        end
        complete = complete and job.index > job.last
    end
    if complete then
        self.published, self.jobs = self.jobs, nil
        lvgl.show(self.root)
        for series, job in ipairs(self.published) do
            local item = self.context.series[series]
            item.drawnRevision, item.drawnVersion = job.historyRevision, self.context.version
            if job.level > job.map.level then
                job.map:releaseBelow(job.level)
            end
        end
    end
    return complete
end

return renderer
