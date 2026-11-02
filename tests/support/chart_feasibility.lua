-- SPDX-License-Identifier: GPL-2.0-only

-- Phase-1 column-envelope experiment; not the production mipmap.
local probe = {}
local function noSet() end

local function mapColumns(self, first, last, apply)
    local work, lows, highs = self.work, self.lows, self.highs
    local positions, changes = self.positions, self.changes
    local scale, offset = self.scale, self.offset
    local height, bottom = self.height, self.bottom
    local objects = self.objects
    local set = apply and self.setter or noSet
    for cursor = first, last do
        local index = work[cursor]
        local target = changes[index]
        target.x = (offset + positions[index] * scale) // 1
        local top = (bottom - highs[index] * height) // 1
        target.y = top
        target.h = (bottom - lows[index] * height) // 1 - top + 1
        set(objects[index], target)
    end
end

local function mapY(self, first, last, apply)
    local work, lows, highs, changes = self.work, self.lows, self.highs, self.changes
    local height, bottom = self.height, self.bottom
    local objects = self.objects
    local set = apply and self.setter or noSet
    for cursor = first, last do
        local index = work[cursor]
        local target = changes[index]
        local top = (bottom - highs[index] * height) // 1
        target.y = top
        target.h = (bottom - lows[index] * height) // 1 - top + 1
        set(objects[index], target)
    end
end

local function mapX(self, first, last, apply)
    local work, positions, changes = self.work, self.positions, self.changes
    local scale, offset = self.scale, self.offset
    local objects = self.objects
    local set = apply and self.setter or noSet
    for cursor = first, last do
        local index = work[cursor]
        local target = changes[index]
        target.x = (offset + positions[index] * scale) // 1
        set(objects[index], target)
    end
end

function probe.new(chart, options)
    return setmetatable({
        chart = chart,
        points = options.points,
        seriesCount = #chart.series,
        buffers = {},
        columns = {},
        lows = {},
        highs = {},
        positions = {},
        changes = {},
        objects = {},
        kernel = options.kernel or "combined",
        changesByOperation = { append = {}, horizontal = {}, vertical = {}, scroll = {}, resize = {} },
        worklists = { append = {}, horizontal = {}, vertical = {}, scroll = {}, resize = {} },
        prepareBuffer = 1,
        prepareIndex = 1,
        overlayCount = options.overlays or 12,
    }, { __index = probe })
end

function probe:prepare()
    local chart, buffer = self.chart, self.prepareBuffer
    if buffer > 2 then
        self.prepared = true
        lvgl.show(self.buffers[1].root)
        return true
    end
    local pool = self.buffers[buffer]
    if not pool then
        pool = {
            root = lvgl.box(chart.plotHost, { x = 0, y = 0, w = chart.rect.w, h = chart.rect.h }),
            lines = {},
            overlays = {},
        }
        lvgl.hide(pool.root)
        self.buffers[buffer] = pool
        return false
    end
    local index = self.prepareIndex
    if index <= self.points * self.seriesCount then
        local column = (index - 1) % self.points + 1
        local series = (index - 1) // self.points + 1
        local low = (column * 17 + series * 13) % 70 / 100
        local gap = column % 23 == 0
        local high = gap and low or math.min(1, low + 0.3)
        if buffer == 1 then
            self.columns[index] = { x = column - 1, low = low, high = high, gap = gap }
            self.lows[index], self.highs[index], self.positions[index] = low, high, column - 1
            for _, changes in pairs(self.changesByOperation) do
                changes[index] = {}
            end
            for operation, work in pairs(self.worklists) do
                if
                    not gap
                    and (operation ~= "append" or column == self.points)
                    and (operation ~= "scroll" or column - 1 >= self.points / 4)
                    and (operation ~= "horizontal" or column - 1 < self.points * 0.75)
                then
                    work[#work + 1] = index
                end
            end
        end
        local object = lvgl.vline(pool.root, {
            x = chart.area.x + (column - 1) * chart.area.w / self.points,
            y = chart.area.y + (1 - high) * chart.area.h,
            w = 1,
            h = math.max(1, (high - low) * chart.area.h),
            color = chart.series[series].color,
        })
        if gap then
            lvgl.hide(object)
        end
        pool.lines[index] = { object = object, visible = not gap }
        if buffer == 2 then
            self.objects[index] = object
            self.setter = object.set
        end
        self.prepareIndex = index + 1
        return false
    end
    local overlay = #pool.overlays + 1
    if overlay <= self.overlayCount then
        pool.overlays[overlay] = lvgl.vline(pool.root, {
            x = chart.area.x,
            y = chart.area.y,
            w = 1,
            h = chart.area.h,
            color = chart.theme.chartColor.grid,
        })
        return false
    end
    self.prepareBuffer, self.prepareIndex = buffer + 1, 1
    return false
end

function probe:begin(operation)
    assert(not self.active)
    self.operation = operation
    self.turns, self.submitted, self.mapped = 0, 0, 0
    self.firstAt, self.finishedAt = nil, nil
    self.startedAt = getTime()
    self.index = 1
    self.limit = (operation == "scroll" or operation == "append") and 2 or 5
    if operation == "append" and self.seriesCount == 1 then
        self.limit = 1
    end
    self.work = self.worklists[operation]
    self.changes = self.changesByOperation[operation]
    self.quota = math.ceil(#self.work / self.limit)
    local area = self.chart.area
    self.scale = area.w / self.points * (operation == "resize" and 0.75 or 1)
    self.offset = area.x - (operation == "scroll" and area.w / 4 or 0) + 0.5
    self.height = area.h * ((operation == "resize" or operation == "vertical") and 0.75 or 1)
    self.bottom = area.y + self.height + 0.5
    self.mapper = operation == "scroll" and mapX or operation == "vertical" and mapY or mapColumns
    if self.kernel == "setters" then
        self.mapper(self, 1, #self.work)
    end
    self.active = true
end

function probe:step()
    if not self.active then
        return 1
    end
    self.firstAt = self.firstAt or getTime()
    self.turns = self.turns + 1
    self.setter = self.objects[1].set
    local area, operation = self.chart.area, self.operation
    local offset = area.x - (operation == "scroll" and area.w / 4 or 0)
    local pool, floor = self.buffers[2], math.floor
    local first, last = self.index, math.min(#self.work, self.index + self.quota - 1)
    if self.kernel ~= "setters" then
        self.mapper(self, first, last, self.kernel == "combined")
        self.mapped = self.mapped + last - first + 1
    end
    if self.kernel == "setters" then
        local work, objects, changes = self.work, self.objects, self.changes
        for cursor = first, last do
            local index = work[cursor]
            objects[index]:set(changes[index])
        end
    end
    if self.kernel ~= "mapping" then
        self.submitted = self.submitted + last - first + 1
    end
    self.index = last + 1
    if operation ~= "append" then
        for index = self.turns, #pool.overlays, self.limit do
            pool.overlays[index]:set({
                x = floor(offset + index / (#pool.overlays + 1) * area.w + 0.5),
                y = area.y,
                h = area.h,
            })
        end
    end
    if self.index > #self.work then
        lvgl.hide(self.buffers[1].root)
        lvgl.show(pool.root)
        self.active, self.finishedAt = false, getTime()
        return 1
    end
    return 1, true
end

return probe
