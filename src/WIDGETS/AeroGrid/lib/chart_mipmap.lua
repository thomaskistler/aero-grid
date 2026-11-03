-- SPDX-License-Identifier: GPL-2.0-only

-- Incoming-reading prototype. Not selected by the production chart.
local mipmap = { LAST_LEVEL = 10 }
mipmap.__index = mipmap

function mipmap.new(width)
    assert(type(width) == "number" and width >= 1 and width % 1 == 0, "mipmap requires an integer column count")
    local self = setmetatable({ width = width }, mipmap)
    self:reset()
    return self
end

function mipmap:reset()
    self.levels = {}
    for level = 0, mipmap.LAST_LEVEL do
        self.levels[level] = { span = 6000 * (4 / 3) ^ level, low = {}, high = {}, tags = {} }
    end
    self.level, self.at = 0, nil
    self.revision = (self.revision or 0) + 1
end

--- Each event touches one column per retained level, regardless of elapsed time.
--- A nil value marks missing telemetry. Never interpolate unsampled columns.
function mipmap:sample(at, value, broken)
    assert(type(at) == "number" and at >= 0 and at % 1 == 0, "invalid mipmap timestamp")
    assert(not self.at or at >= self.at, "mipmap time moved backwards; reset required")
    assert(
        value == nil or type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge,
        "invalid mipmap reading"
    )
    local width = self.width
    for index = self.level, mipmap.LAST_LEVEL do
        local level = self.levels[index]
        local bucket = (at * width / level.span) // 1
        local slot, tag = bucket % width + 1, bucket + 1
        local previous = level.tags[slot]
        if previous ~= tag and previous ~= -tag then
            level.low[slot], level.high[slot] = value, value
            level.tags[slot] = value == nil and -tag or tag
        elseif value == nil or broken or previous == -tag then
            local endpoint = value or level.high[slot]
            level.low[slot], level.high[slot], level.tags[slot] = endpoint, endpoint, -tag
        else
            if value < level.low[slot] then
                level.low[slot] = value
            end
            if value > level.high[slot] then
                level.high[slot] = value
            end
        end
    end
    self.at, self.revision = at, self.revision + 1
end

--- Selection only: no summary writes, raw-history reads or rebucketing.
function mipmap:select(at)
    local level = self.level
    while level < mipmap.LAST_LEVEL and at >= self.levels[level].span do
        level = level + 1
    end
    local selected, origin = self.levels[level], 0
    if level == mipmap.LAST_LEVEL and at >= selected.span then
        local quarter = selected.span / 4
        origin = ((((at - selected.span) / quarter) // 1 + 1) * self.width / 4) // 1
    end
    return level, origin
end

--- Single-consumer prototype: call only after publishing the replacement view.
function mipmap:releaseBelow(level)
    assert(
        type(level) == "number" and level % 1 == 0 and level >= self.level and level <= mipmap.LAST_LEVEL,
        "invalid mipmap retirement"
    )
    for index = self.level, level - 1 do
        self.levels[index] = nil
    end
    self.level = level
end

function mipmap:column(levelIndex, bucket)
    local level, width = assert(self.levels[levelIndex], "mipmap level was retired"), self.width
    local slot = bucket % width + 1
    local tag = level.tags[slot]
    if tag == bucket + 1 or tag == -(bucket + 1) then
        return level.low[slot], level.high[slot], tag < 0
    end
    return nil, nil, true
end

return mipmap
