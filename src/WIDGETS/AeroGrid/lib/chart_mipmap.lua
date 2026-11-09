-- SPDX-License-Identifier: GPL-2.0-only

-- Incoming-reading prototype. Not selected by the production chart.
local mipmap = { LAST_LEVEL = 10 }
mipmap.__index = mipmap
local consumer = {}
consumer.__index = consumer
local huge = math.huge

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
        value == nil or type(value) == "number" and value == value and value ~= huge and value ~= -huge,
        "invalid mipmap reading"
    )
    local width = self.width
    local position = at * width
    for index = self.level, mipmap.LAST_LEVEL do
        local level = self.levels[index]
        local bucket = (position / level.span) // 1
        local slot, tag = bucket % width + 1, bucket + 1
        local lows, highs, tags = level.low, level.high, level.tags
        local previous = tags[slot]
        if previous ~= tag and previous ~= -tag then
            lows[slot], highs[slot] = value, value
            tags[slot] = value == nil and -tag or tag
        elseif value == nil or broken or previous == -tag then
            local endpoint = value or highs[slot]
            lows[slot], highs[slot], tags[slot] = endpoint, endpoint, -tag
        else
            if value < lows[slot] then
                lows[slot] = value
            end
            if value > highs[slot] then
                highs[slot] = value
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

--- Chart-local summaries: call only after publishing the replacement view.
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

--- A late attachment cannot reconstruct observed extrema from compressed knots.
function mipmap.attach(history, feed, width)
    local self = setmetatable({
        history = history,
        feed = feed,
        map = mipmap.new(width),
        startedAt = 0,
        complete = feed.count == 0,
    }, consumer)
    history:observeSamples(feed, self)
    return self
end

function consumer:sample(at, value, broken)
    self.map:sample(at - self.startedAt, value, broken)
end

function consumer:reset()
    self.startedAt, self.complete = 0, true
    self.map:reset()
end

--- Configuration-time restart affects this presentation, never its recording.
function consumer:restart(width, at)
    assert(self.history, "mipmap consumer was destroyed")
    assert(type(at) == "number" and at >= 0 and at % 1 == 0, "invalid mipmap restart timestamp")
    local map = mipmap.new(width)
    self.map, self.startedAt, self.complete = map, at, true
end

function consumer:destroy()
    if self.history then
        self.history:unobserveSamples(self.feed, self)
        self.history, self.feed, self.map = nil, nil, nil
    end
end

return mipmap
