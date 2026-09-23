-- SPDX-License-Identifier: GPL-2.0-only

local assertions = {}

function assertions.assertEqual(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

function assertions.assertContains(value, expected, message)
    if type(value) ~= "string" or not string.find(value, expected, 1, true) then
        error((message or "value missing expected substring") .. ": expected to find " .. tostring(expected) .. " in " .. tostring(value), 2)
    end
end

function assertions.assertTableHasKey(tableValue, key, message)
    if type(tableValue) ~= "table" or tableValue[key] == nil then
        error((message or "table missing key") .. ": missing key " .. tostring(key), 2)
    end
end

function assertions.assertIsType(value, expectedType, message)
    if type(value) ~= expectedType then
        error((message or "wrong type") .. ": expected " .. expectedType .. ", got " .. type(value), 2)
    end
end

return assertions
