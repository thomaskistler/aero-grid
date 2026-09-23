-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local identity = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/components/model-identity.lua"))()

local function testPresentation()
    assertions.assertEqual(identity.presentationFor({ presentation = "name" }, 4, 4).showImage, false)
    assertions.assertEqual(identity.presentationFor({ presentation = "image" }, 1, 1).showName, false)
    assertions.assertEqual(identity.presentationFor({ presentation = "both" }, 1, 1).showImage, true)
    assertions.assertEqual(identity.presentationFor({ presentation = "auto" }, 1, 1).showImage, false)
    assertions.assertEqual(identity.presentationFor({ presentation = "auto" }, 2, 2).showImage, true)
end

local function testImageLookup()
    local previous = fstat
    assertions.assertEqual(identity.fileExists(""), false)
    fstat = nil
    local exists, checked = identity.fileExists("/IMAGES/plane.png")
    assertions.assertEqual(exists, false)
    assertions.assertEqual(checked, false)

    fstat = function()
        error("no filesystem")
    end
    assertions.assertEqual(identity.fileExists("/IMAGES/plane.png"), false)

    fstat = function(path)
        return path == "/IMAGES/plane.png" and { size = 10 } or nil
    end
    assertions.assertEqual(identity.fileExists("/IMAGES/plane.png"), true)
    assertions.assertEqual(identity.fileExists("/IMAGES/gone.png"), false)
    fstat = previous
end

local function run()
    testPresentation()
    testImageLookup()
end

run()
