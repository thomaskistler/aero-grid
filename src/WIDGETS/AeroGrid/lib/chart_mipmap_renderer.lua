-- SPDX-License-Identifier: GPL-2.0-only

local renderer = {}
renderer.__index = renderer

function renderer.new(context)
    local self = setmetatable({
        context = context,
        width = context.area.w // 1,
        objects = {},
        visible = {},
        groups = {},
        offsets = {},
        membership = {},
        published = {},
        changes = {},
        groupChanges = {},
        prepareIndex = 1,
    }, renderer)
    self.root = lvgl.box(context.plotRoot, { x = 0, y = 0, w = context.rect.w, h = context.rect.h })
    return self
end

function renderer:prepare()
    local context, width = self.context, self.width
    if #self.groups < #context.series * 4 then
        local index = #self.groups + 1
        self.groups[index] = lvgl.box(self.root, { x = 0, y = 0, w = context.rect.w, h = context.rect.h })
        self.offsets[index] = 0
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
            x = 0,
            y = 0,
            w = 1,
            h = 1,
            thickness = 0,
            filled = true,
            color = context.series[series].color,
        })
        lvgl.hide(object)
        self.objects[index], self.membership[index] = object, group
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
        local map, item = owner.map, context.series[series]
        local at = math.max(0, context.session.elapsed - owner.startedAt)
        local level, origin = map:select(at)
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
            scroll = scroll,
            retainedLast = scroll and ((previous.at or 0) * self.width / summary.span) // 1 - 1,
        }
    end
    return jobs, changed
end

function renderer:begin(jobs)
    local grouped, reset = true, false
    for _, job in ipairs(jobs) do
        grouped = grouped and job.scroll
        reset = reset or job.updateX
    end
    if grouped then
        for series, job in ipairs(jobs) do
            for quarter = 0, 3 do
                local start = (quarter * self.width / 4) // 1
                local base = (job.origin // self.width) * self.width + start
                if base < job.origin then
                    base = base + self.width
                end
                local group = (series - 1) * 4 + quarter + 1
                self.groupChanges.x = base - start - job.origin
                self.groups[group]:set(self.groupChanges)
                self.offsets[group] = self.groupChanges.x
            end
            job.index = math.max(job.index, job.retainedLast + 1)
            job.updateX = false
        end
    elseif reset then
        for index, group in ipairs(self.groups) do
            if self.offsets[index] ~= 0 then
                self.groupChanges.x = 0
                group:set(self.groupChanges)
                self.offsets[index] = 0
                local job = jobs[(index - 1) // 4 + 1]
                job.updateX, job.index, job.last = true, job.origin, job.origin + self.width - 1
            end
        end
    end
    self.jobs = jobs
end

local function draw(self, job, series, quota)
    if job.index > job.last then
        return 0
    end
    local width, changes = self.width, self.changes
    local finish = math.min(job.last, job.index + quota - 1)
    local slot, offset = job.index % width + 1, (series - 1) * width
    local scale = job.height / (job.high - job.low)
    local bottom = job.top + job.height
    local set = self.objects[1].set
    changes.x = nil
    for bucket = job.index, finish do
        local index = offset + slot
        if job.tags[slot] == bucket + 1 then
            local low, high = job.lows[slot], job.highs[slot]
            local top = math.max(job.top, math.min(bottom, (bottom - (high - job.low) * scale + 0.5) // 1))
            local last = math.max(job.top, math.min(bottom, (bottom - (low - job.low) * scale + 0.5) // 1))
            changes.y, changes.h = top, last - top + 1
            if job.updateX or not self.visible[index] then
                changes.x = job.left + bucket - job.origin - self.offsets[self.membership[index]]
            end
            set(self.objects[index], changes)
            changes.x = nil
            if not self.visible[index] then
                lvgl.show(self.objects[index])
                self.visible[index] = true
            end
        elseif self.visible[index] then
            lvgl.hide(self.objects[index])
            self.visible[index] = nil
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
        local used = draw(self, job, series, math.min(quota, job.updateX and 90 or 130))
        local remaining = math.min(quota, job.updateX and 90 or 130) - used
        if job.index > job.last and job.revision ~= job.map.revision then
            job.index = math.max(job.origin, ((job.at or 0) * self.width / job.span) // 1)
            job.last = math.min(job.origin + self.width - 1, ((job.map.at or 0) * self.width / job.span) // 1)
            job.at, job.revision, job.updateX = job.map.at, job.map.revision, false
            if remaining > 0 then
                draw(self, job, series, remaining)
            end
        end
        complete = complete and job.index > job.last
    end
    if complete then
        self.published, self.jobs = self.jobs, nil
        lvgl.show(self.root)
    end
    return complete
end

return renderer
