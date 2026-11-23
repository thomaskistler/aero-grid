-- SPDX-License-Identifier: GPL-2.0-only

local glass = {}
glass.__index = glass

local SAMPLE_SIZE = 16
local MAX_FILE_SIZE = 65536

local function field(env, filename, name)
    local info = env.stat(filename)
    if not info or not info.size or info.size > MAX_FILE_SIZE then
        return nil, "cannot read " .. filename
    end
    local handle, message = env.io.open(filename, "r")
    if not handle then
        return nil, message or ("cannot open " .. filename)
    end
    local content = env.io.read(handle, info.size)
    env.io.close(handle)
    if type(content) ~= "string" or #content ~= info.size then
        return nil, "cannot read " .. filename
    end
    local value = string.match("\n" .. content, "\n[ \t]*" .. name .. ":[ \t]*([^\r\n]*)")
    if not value then
        return nil
    end
    local parsed, parseError = env.yaml.parse("value: " .. value)
    if not parsed or type(parsed.value) ~= "string" then
        return nil, parseError or ("invalid " .. name .. " in " .. filename)
    end
    return parsed.value
end

function glass.new(builder, yaml, cache, persistent, env)
    env = env
        or {
            stat = fstat,
            dir = dir,
            io = io,
            bitmap = bitmap or Bitmap,
            width = LCD_W,
            height = LCD_H,
        }
    return setmetatable({
        env = {
            stat = env.stat,
            dir = env.dir,
            io = env.io,
            bitmap = env.bitmap,
            width = env.width,
            height = env.height,
            yaml = yaml,
        },
        builder = builder,
        cache = cache,
        persistent = persistent,
        stage = "radio",
        opacity = 204,
    }, glass)
end

local function fallback(self, reason)
    self.reason, self.stage, self.image, self.iterator = reason, "palette", nil, nil
    return false
end

--- Each call reads one metadata file, decodes/resizes one image, or averages up to 256 samples.
function glass:step()
    local env, stage = self.env, self.stage
    local api = env.bitmap
    if stage == "radio" then
        if type(env.stat) ~= "function" or type(env.dir) ~= "function" then
            return fallback(self, "background image analysis is unavailable")
        end
        local name, message = field(env, "/RADIO/radio.yml", "selectedTheme")
        if message then
            return fallback(self, message)
        end
        self.name = name or "EdgeTX Default"
        if self.name == "EdgeTX Default" then
            self.folder, self.stage = "/THEMES/EdgeTX/", "image"
        else
            self.iterator = env.dir("/THEMES")
            if type(self.iterator) ~= "function" then
                return fallback(self, "radio themes are unavailable")
            end
            self.stage = "theme"
        end
    elseif stage == "theme" then
        local entry = self.iterator()
        if not entry then
            return fallback(self, "selected radio theme was not found")
        end
        if not string.find(entry, "[/\\]") and entry ~= "." and entry ~= ".." then
            local folder = "/THEMES/" .. entry .. "/"
            local name = field(env, folder .. "theme.yml", "name")
            -- EdgeTX persists at most 26 bytes of the theme's display name.
            if name and string.sub(name, 1, 26) == self.name then
                self.folder, self.stage, self.iterator = folder, "image", nil
            end
        end
    elseif stage == "image" then
        local filename = self.folder .. "background_" .. tostring(env.width) .. "x" .. tostring(env.height) .. ".png"
        local info = env.stat(filename)
        if not info then
            filename = self.folder .. "background.png"
            info = env.stat(filename)
        end
        if not info then
            return fallback(self, "radio background image is not available on the SD card")
        end
        local key
        if type(info.size) == "number" and type(info.time) == "table" then
            key = filename .. ":" .. tostring(info.size)
            for _, name in ipairs({ "year", "mon", "day", "hour", "min", "sec" }) do
                if type(info.time[name]) ~= "number" then
                    key = nil
                    break
                end
                key = key .. ":" .. tostring(info.time[name])
            end
        end
        if not key then
            self.cacheReason, self.persistent = "background image modification time is unavailable", nil
        end
        self.filename, self.key = filename, key
        if key and self.cache.key == key then
            self.average = self.cache.average
        end
        if self.persistent then
            self.persistent:lookup(filename, key)
            self.stage = "cache-read"
        else
            self.stage = self.average and "palette" or "decode"
        end
    elseif stage == "cache-read" then
        if self.persistent:step() then
            self.cacheReason = self.persistent.reason
            if self.persistent.brightness ~= nil then
                self.average = self.persistent.brightness * 65793
                self.cache.key, self.cache.average = self.key, self.average
                self.stage = "palette"
            elseif self.average then
                self.persistent:save(self.average // 65793)
                self.stage = "cache-write"
            else
                self.stage = "decode"
            end
        end
    elseif stage == "decode" then
        if
            type(api) ~= "table"
            or type(api.open) ~= "function"
            or type(api.getSize) ~= "function"
            or type(api.resize) ~= "function"
            or type(api.toMask) ~= "function"
        then
            return fallback(self, "background image analysis is unavailable")
        end
        local ok, image = pcall(api.open, self.filename)
        if not ok or not image then
            return fallback(self, "cannot decode background image: " .. tostring(image))
        end
        local width, height = api.getSize(image)
        if width <= 0 or height <= 0 then
            return fallback(self, "cannot decode background image")
        end
        local scale = math.min(SAMPLE_SIZE / width, SAMPLE_SIZE / height)
        self.sampleWidth, self.sampleHeight = math.floor(width * scale), math.floor(height * scale)
        if self.sampleWidth < 1 or self.sampleHeight < 1 then
            return fallback(self, "background image is too narrow to sample")
        end
        self.sampleLeft = math.max(0, math.floor((SAMPLE_SIZE - width * scale) / 2))
        self.sampleTop = math.max(0, math.floor((SAMPLE_SIZE - height * scale) / 2))
        self.image, self.stage = image, "resize"
    elseif stage == "resize" then
        local ok, image = pcall(api.resize, self.image, SAMPLE_SIZE, SAMPLE_SIZE)
        self.image = nil
        if not ok or not image then
            return fallback(self, "cannot sample background image")
        end
        self.image, self.stage = image, "average"
    elseif stage == "average" then
        -- Native masks contain inverse, quantized grayscale after a four-byte size header.
        local ok, mask = pcall(api.toMask, self.image)
        self.image = nil
        if not ok or type(mask) ~= "string" or #mask ~= SAMPLE_SIZE * SAMPLE_SIZE + 4 then
            return fallback(self, "cannot read background image samples")
        end
        -- Bitmap.resize preserves aspect ratio; do not average its empty padding.
        local sum, count = 0, self.sampleWidth * self.sampleHeight
        for row = self.sampleTop, self.sampleTop + self.sampleHeight - 1 do
            local first = 5 + row * SAMPLE_SIZE + self.sampleLeft
            for index = first, first + self.sampleWidth - 1 do
                sum = sum + 255 - string.byte(mask, index)
            end
        end
        local average = math.floor(sum / count + 0.5)
        self.average = average * 65793
        self.cache.key, self.cache.average = self.key, self.average
        if self.persistent then
            self.persistent:save(average)
            self.stage = "cache-write"
        else
            self.stage = "palette"
        end
    elseif stage == "cache-write" then
        if self.persistent:step() then
            self.cacheReason = self.persistent.reason or self.cacheReason
            self.stage = "palette"
        end
    elseif stage == "palette" then
        local mode = self.average and self.average % 256 >= 128 and "modern-light" or "modern-dark"
        self.theme = self.builder.build(mode)
        self.stage = "opacity"
    elseif stage == "opacity" then
        if self.average then
            self.opacity = self.builder.glassOpacity(self.theme, self.average)
        end
        self.stage = nil
        return true
    else
        return true
    end
    return false
end

return glass
