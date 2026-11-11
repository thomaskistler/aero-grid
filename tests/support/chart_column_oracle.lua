-- SPDX-License-Identifier: GPL-2.0-only

-- Independent input trace; does not read production columns or native objects.
-- Pause gaps are not modeled: resumed samples only interrupt the trace.
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

local function bucketOf(at, width, span)
    return math.floor(at * width / span)
end

-- A valid sample connects from the previous valid sample unless it is itself
-- broken or resumed, or a missing reading lies between them.
local function incoming(self, index)
    local previous = index - 1
    if self.breaks[index] or self.resumes[index] or previous < 1 or self.values[previous] == false then
        return nil
    end
    return previous
end

function oracle:columns(width, span)
    local key = width .. ":" .. span
    if self.cache[key] then
        return self.cache[key]
    end
    local result = {}
    for index, at in ipairs(self.times) do
        local bucket, value = bucketOf(at, width, span), self.values[index]
        if bucket >= 0 and bucket < width then
            local column = result[bucket]
            if value == false then
                result[bucket] = column or { kind = "missing", width = 1 }
            elseif column and column.kind == "data" then
                column.min, column.max = math.min(column.min, value), math.max(column.max, value)
                column.finish = value
            else
                local previous = incoming(self, index)
                local from = previous and self.values[previous] or nil
                result[bucket] = { kind = "data", min = value, max = value, finish = value, width = 1, from = from }
                local start = previous and bucketOf(self.times[previous], width, span)
                if start and bucket - start > 1 then
                    result[start + 1] =
                        { kind = "hold", min = from, max = from, finish = from, width = bucket - start - 1 }
                end
            end
        end
    end
    self.cache[key] = result
    return result
end

function oracle:summary(width, bucket, window)
    return self:columns(width, window or 6000)[bucket]
end

--- Expected native rectangle for one column, or nil when nothing is drawn.
function oracle:rectangle(width, bucket, area, low, high, window)
    local column = self:summary(width, bucket, window)
    if not column or column.kind == "missing" or column.kind == "pause" then
        return nil
    end
    local minimum, maximum = column.min, column.max
    if column.from then
        minimum, maximum = math.min(minimum, column.from), math.max(maximum, column.from)
    end
    local function y(value)
        local offset = math.floor(area.y + area.h - (value - low) * area.h / (high - low) + 0.5)
        return math.max(area.y, math.min(area.y + area.h, offset))
    end
    local top, bottom = y(maximum), y(minimum)
    return { x = area.x + bucket, y = top, w = column.width, h = bottom - top + 1 }
end

return oracle
