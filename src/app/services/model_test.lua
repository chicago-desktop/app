-- Services model: pure, so every case runs on stub states and stub entries.
local test = require("test")
local model = require("model")
local errors = require("errors")

local NOW = 1757600000 * 1e9

-- A supervisor state in the shape system.supervisor.states() returns it.
local function state(id: string, status: string, extra: any?): any
    local out: any = {id = id, status = status, desired = status, retry_count = 0,
        started_at = NOW - 90 * 1e9, last_update = NOW - 5 * 1e9}
    for key, value in pairs(extra or {}) do out[key] = value end
    return out
end

-- A process.service entry in the shape registry.get returns it: the YAML's
-- host, process and lifecycle under `data`.
local function service_entry(id: string, lifecycle: any): any
    return {id = id, kind = "process.service", meta = {},
        data = {host = "app:processes", process = (id:gsub("%.service$", "")), lifecycle = lifecycle}}
end

-- The weather service's lifecycle as src/app/weather/_index.yaml declares it,
-- plus a requires list written both ways.
local WEATHER: any = {
    auto_start = true,
    restart = {initial_delay = "5s", max_attempts = 10, backoff_factor = 2.0},
    security = {actor = {id = "app.weather.forecaster"}, policies = {"app.weather:service_scope"}},
    requires = {"app:db"},
    depends_on = {"app:db", "app:processes"},
}

local DENIED_REGISTRY = "registry: permission denied (no registry.get)"

local function sample(): (any, any)
    local states = {
        state("app:gateway", "running"),
        state("app.x:optional.service", "failed", {details = "dial tcp: connection refused", retry_count = 3}),
        state("app.weather:forecaster.service", "running"),
    }
    local entries = {
        ["app.weather:forecaster.service"] = {entry = service_entry("app.weather:forecaster.service", WEATHER)},
        ["app:gateway"] = {entry = {id = "app:gateway", kind = "http.service", meta = {},
            data = {lifecycle = {auto_start = true}}}},
        ["app.x:optional.service"] = {entry = service_entry("app.x:optional.service",
            {auto_start = true, startup = "optional", restart = {max_attempts = 0}})},
    }
    return model.services(states, entries)
end

local function walk(node: any, visit: any)
    visit(node)
    for _, child in ipairs(type(node.children) == "table" and node.children or {}) do walk(child, visit) end
end

local function by_id(tree: any, id: string): any
    local found = nil
    walk(tree, function(node) if node.id == id then found = node end end)
    return found
end

local function has_text(tree: any, needle: string): boolean
    local found = false
    walk(tree, function(node)
        if node.kind == "label" and tostring(node.text):find(needle, 1, true) then found = true end
    end)
    return found
end

local function by_label(lines: any): any
    local out = {}
    for _, line in ipairs(lines) do out[line.label] = line.value end
    return out
end

local function define_tests()
    test.describe("Services model: rows", function()
        test.it("joins supervisor states with their registry entries, sorted by id", function()
            local rows, problem = sample()
            test.is_nil(problem)
            test.eq(#rows, 3)
            test.eq(rows[1].id, "app.weather:forecaster.service")
            test.eq(rows[2].id, "app.x:optional.service")
            test.eq(rows[3].id, "app:gateway")
            test.eq(rows[1].startup, "Automatic")
            test.eq(rows[2].startup, "Auto, optional", "an optional auto-start root")
            test.eq(rows[1].host, "app:processes")
            test.eq(rows[3].host, "-", "an HTTP server runs on no process host")
            local cells = model.table_rows(rows)[2].cells
            test.eq(cells[1], "app.x:optional.service")
            test.eq(cells[2], "Failed")
            test.eq(cells[3], "Auto, optional")
        end)

        test.it("reads a missing or false auto_start as Manual", function()
            test.eq(model.startup({id = "a", kind = "process.service", data = {}}), "Manual")
            test.eq(model.startup({id = "a", kind = "process.service", data = {lifecycle = {auto_start = false}}}), "Manual")
            test.eq(model.startup(nil), "?", "no entry, no claim")
        end)

        test.it("keeps a service whose entry could not be read, with ? and the first reason", function()
            local rows, problem = model.services({
                state("app:b", "running"),
                state("app:a", "stopped"),
                {status = "running"},
            }, {["app:b"] = {problem = DENIED_REGISTRY}})
            test.eq(#rows, 2, "a state without an id is not a service")
            test.eq(rows[1].id, "app:a")
            test.eq(rows[1].startup, "?")
            test.eq(rows[1].host, "?")
            test.eq(rows[2].entry_problem, DENIED_REGISTRY)
            test.eq(problem, "2 registry entries not read: " .. DENIED_REGISTRY)
        end)
    end)

    test.describe("Services model: the list sheet", function()
        test.it("draws Start, Stop and Restart disabled for every row and says why", function()
            local rows = sample()
            local tree = model.list_tree({services = rows, selected_id = rows[1].id, heading = "Services on box:"}, NOW)
            for _, id in ipairs({"start", "stop", "restart"}) do
                test.eq(by_id(tree, id).disabled, true, id .. " is disabled")
            end
            test.is_true(has_text(tree, model.NO_CONTROL), "the reason is on screen")
            test.eq(by_id(tree, "props").disabled, false)
            test.is_nil(by_id(tree, "refresh").disabled)
            test.eq(by_id(tree, "services").selected, rows[1].id)
            test.is_true(has_text(tree, "Services on box:"))
        end)

        test.it("disables Properties… with nothing selected and says why the list is empty", function()
            local tree = model.list_tree({services = {}, selected_id = nil,
                failure = "services: permission denied: system.read on supervisor"}, NOW)
            test.eq(by_id(tree, "props").disabled, true)
            test.is_nil(by_id(tree, "services"))
            test.is_true(has_text(tree, "The services could not be read."))
        end)
    end)

    test.describe("Services model: refusals", function()
        test.it("words the runtime's denial as a permission denial, not as unavailable", function()
            -- The shape system.* returns: kind Invalid, text "permission denied: …".
            local denied = errors.new({message = "permission denied: system.read on supervisor", kind = errors.INVALID})
            local absent = errors.new({message = "service info not available", kind = errors.INTERNAL})
            test.eq(model.explain("services", denied), "services: permission denied: system.read on supervisor")
            test.eq(model.explain("services", absent), "services: unavailable (service info not available)")
            test.eq(model.explain("services", nil), "services: no answer")
            test.eq(model.status_line({services = {}, failure = model.explain("services", denied)}),
                "services: permission denied: system.read on supervisor")
        end)
    end)

    test.describe("Services model: status and detail", function()
        test.it("counts services, running ones and process hosts", function()
            local rows = sample()
            test.eq(model.summary(rows, 2, nil), "3 services, 2 running · 2 process hosts")
            test.eq(model.summary({rows[1]}, 1, nil), "1 service, 1 running · 1 process host")
            test.eq(model.summary(rows, nil, "process hosts: permission denied: system.read on hosts"),
                "3 services, 2 running · process hosts: permission denied: system.read on hosts")
            test.eq(model.status_line({services = rows, host_count = 2, entry_problem = "1 registry entry not read: x"}),
                "3 services, 2 running · 2 process hosts · 1 registry entry not read: x")
            test.eq(model.status_line({services = rows, host_count = 2, status = model.NO_CONTROL}), model.NO_CONTROL,
                "a message of the moment wins")
        end)

        test.it("describes the selected service: status, uptime, retries, last error", function()
            local rows = sample()
            test.eq(model.detail(rows[1], NOW), "Running · started 1m ago")
            test.eq(model.detail(rows[2], NOW), "Failed · 3 retries · last error: dial tcp: connection refused")
            local stopping = model.services({state("app:s", "running", {desired = "stopped"})}, {})[1]
            test.eq(model.detail(stopping, NOW), "Running, desired Stopped · started 1m ago · registry entry not read")
            test.eq(model.detail(nil, NOW), "")
        end)

        test.it("counts time from the supervisor's stamps, and Go's zero time is never", function()
            test.eq(model.age(0, NOW), "never")
            test.eq(model.age(-6795364578871345152, NOW), "never", "time.Time{}.UnixNano()")
            test.eq(model.age(NOW - 5 * 1e9, NOW), "5s ago")
            test.eq(model.age(NOW - (2 * 3600 + 5 * 60) * 1e9, NOW), "2h 5m ago")
            test.eq(model.age(NOW - 4 * 86400 * 1e9, NOW), "4d ago")
            test.eq(model.age(NOW + 3 * 1e9, NOW), "0s ago", "a clock step backwards is not a negative age")
        end)

        test.it("names the node in the heading and leaves out what it could not read", function()
            test.eq(model.heading({hostname = "box", node_id = "kickside"}), "Services on box (node kickside):")
            test.eq(model.heading({hostname = "kickside", node_id = "kickside"}), "Services on kickside:")
            test.eq(model.heading({problems = {hostname = "host name: permission denied"}}), "Services on this node:")
        end)
    end)

    test.describe("Services model: properties", function()
        test.it("shows host, process, actor, policies, requires and restart from the declaration", function()
            local rows = sample()
            local props = by_label(model.properties(rows[1], NOW))
            test.eq(props.Service, "app.weather:forecaster.service")
            test.eq(props.Status, "Running")
            test.eq(props.Kind, "process.service")
            test.eq(props.Startup, "Automatic")
            test.eq(props.Host, "app:processes")
            test.eq(props.Process, "app.weather:forecaster")
            test.eq(props.Actor, "app.weather.forecaster")
            test.eq(props.Policies, "app.weather:service_scope")
            test.eq(props.Requires, "app:db, app:processes", "requires first, depends_on after, each once")
            test.eq(props.Restart, "up to 10 attempts, first after 5s")
            test.eq(props.Started, "1m ago")
            test.eq(props.Retries, "0")
            test.eq(props.Details, "none")
            test.eq(by_label(model.properties(rows[3], NOW)).Restart, "runtime defaults")
            test.eq(by_label(model.properties(rows[3], NOW)).Host, "none")
        end)

        test.it("calls a failed service's details its last error, and an unread entry by its reason", function()
            local rows = sample()
            local failed = by_label(model.properties(rows[2], NOW))
            test.eq(failed["Last error"], "dial tcp: connection refused")
            test.is_nil(failed.Details)
            test.eq(failed.Restart, "unlimited attempts")
            test.eq(failed.Started, "none", "only a running service has an uptime")

            local unread = model.services({state("app:b", "running")}, {["app:b"] = {problem = DENIED_REGISTRY}})[1]
            local props = by_label(model.properties(unread, NOW))
            test.eq(props.Entry, DENIED_REGISTRY)
            test.is_nil(props.Actor)
        end)

        test.it("builds the sheet with an OK button and the error wrapped last", function()
            local rows = sample()
            local tree = model.properties_tree(rows[2], NOW)
            test.eq(by_id(tree, "props_ok").default, true)
            test.is_true(has_text(tree, "Properties: app.x:optional.service"))
            test.is_true(has_text(tree, "Last error:"))
            local rows_seen = 0
            local last: any = nil
            walk(tree, function(node) if node.kind == "row" and node.children[1].size == model.LABEL_WIDTH then
                rows_seen = rows_seen + 1
                last = node
            end end)
            test.eq(rows_seen, #model.properties(rows[2], NOW))
            test.is_nil(last.size, "the last line takes the rows left")
            test.eq(last.children[2].wrap, true)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
