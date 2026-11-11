-- SPDX-License-Identifier: GPL-2.0-only

-- Independent input trace; does not read production columns or native objects.
local oracle = {}
oracle.__index = oracle

function oracle.new()
    return setmetatable({ times = {}, values = {}, breaks = {}, resumes = {}, cache = {} }, oracle)
end

function oracle:sample(at, value, broken, resumed)
    local index = #self.times + 1
    if value == nil then
        value = false
    end
    self.times[index], self.values[index], self.breaks[index] = at, value, broken == true
    self.resumes[index], self.cache = resumed == true, {}
end

function oracle:summary(width, bucket, window)
    local span = window or 6000
    local times, values = self.times, self.values
    if #times == 0 or bucket < 0 or bucket >= width then
        return nil
    end
    local first, last = 1, #times + 1
    while first < last do
        local middle = (first + last) // 2
        if times[middle] * width / span < bucket then
            first = middle + 1
        else
            last = middle
        end
    end
    local previous = first - 1
    local missing = previous > 0 and values[previous] == false
    while previous > 0 and values[previous] == false do
        previous = previous - 1
    end
    local column
    for index = first, #times do
        if math.floor(times[index] * width / span) ~= bucket then
            break
        end
        local value = values[index]
        local distance = previous > 0 and bucket - math.floor(times[previous] * width / span)
            or (value == false or missing) and math.max(0, bucket)
            or 0
        if value == false then
            if not column or column.kind == "missing" then
                column = { kind = "missing", width = distance }
            end
            missing = true
        else
            local interrupted = self.breaks[index] or missing
            if not column or column.kind == "missing" or interrupted then
                column = {
                    kind = self.resumes[index] and "break" or "data",
                    min = value,
                    max = value,
                    finish = value,
                    width = self.resumes[index] and 24 or distance,
                    from = not interrupted and previous > 0 and values[previous] or nil,
                }
            else
                if column.kind == "break" then
                    column.kind, column.width = "data", 0
                end
                column.min, column.max = math.min(column.min, value), math.max(column.max, value)
                column.finish = value
            end
            previous, missing = index, false
        end
    end
    return column
end

function oracle:column(width, bucket)
    local column = self:summary(width, bucket)
    if not column or column.kind == "missing" then
        return nil, nil, true
    end
    return column.min, column.max, false
end

function oracle:connection(width, bucket, area, low, high, window)
    local column = self:summary(width, bucket, window)
    if not column or not column.from or column.width == 0 then
        return nil
    end
    local x1, x2 = bucket - column.width, bucket
    local y1, y2 = (high - column.from) * area.h / (high - low), (high - column.min) * area.h / (high - low)
    if x1 < 0 then
        y1 = y1 + (y2 - y1) * -x1 / (x2 - x1)
        x1 = 0
    end
    if x2 > area.w - 1 then
        y2 = y1 + (y2 - y1) * (area.w - 1 - x1) / (x2 - x1)
        x2 = area.w - 1
    end
    if x1 > x2 or y1 < 0 and y2 < 0 or y1 > area.h and y2 > area.h then
        return nil
    end
    if y1 < 0 or y1 > area.h then
        local edge = math.max(0, math.min(area.h, y1))
        x1, y1 = x1 + (x2 - x1) * (edge - y1) / (y2 - y1), edge
    end
    if y2 < 0 or y2 > area.h then
        local edge = math.max(0, math.min(area.h, y2))
        x2, y2 = x1 + (x2 - x1) * (edge - y1) / (y2 - y1), edge
    end
    return {
        { area.x + math.floor(x1 + 0.5), area.y + math.floor(y1 + 0.5) },
        { area.x + math.floor(x2 + 0.5), area.y + math.floor(y2 + 0.5) },
    }
end

return oracle
