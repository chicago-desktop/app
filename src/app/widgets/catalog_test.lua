local test = require("test")
local catalog = require("catalog")

local function define_tests()
    test.describe("Application widget composition", function()
        test.it("resolves the actual host instances against installed widget definitions", function()
            local list, err = catalog.widgets()
            test.is_nil(err)
            local found = {}
            for _, item in ipairs(list or {}) do found[item.instance] = item end
            for _, name in ipairs({"weather", "memory", "goroutines"}) do
                local instance = found["app.desktop.widgets:" .. name]
                test.not_nil(instance, name)
                local expected = name == "weather" and "chicago.weather:widget" or "chicago.taskman:" .. name
                test.eq(instance.entry, expected)
                test.eq(type(instance.config), "table")
            end
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
