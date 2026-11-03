-- SPDX-License-Identifier: GPL-2.0-only

-- Diagnostic input trace, independent of mipmap rings and rendered objects.
local oracle = {}
oracle.__index = oracle

function oracle.new()
    return setmetatable({ times = {}, values = {}, breaks = {} }, oracle)
end

function oracle:sample(at, value, broken)
    local index = #self.times + 1
    if value == nil then
        value = false
    end
    self.times[index], self.values[index], self.breaks[index] = at, value, broken == true
end

function oracle:column(width, level, bucket)
    local span = 6000 * (4 / 3) ^ level
    local times, values = self.times, self.values
    if #times == 0 or bucket < (times[#times] * width / span) // 1 - width + 1 then
        return nil, nil, true
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
    local low, high, gap
    while first <= #times and times[first] * width / span < bucket + 1 do
        local value = values[first]
        if low == nil and high == nil and gap == nil then
            if value == false then
                gap = true
            else
                low, high, gap = value, value, false
            end
        elseif value == false or self.breaks[first] or gap then
            gap = true
        else
            low, high = math.min(low, value), math.max(high, value)
        end
        first = first + 1
    end
    return low, high, gap ~= false
end

return oracle
