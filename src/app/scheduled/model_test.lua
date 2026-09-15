-- Scheduled Tasks model: pure, so every case runs on stub rows.
local test = require("test")
local model = require("model")
local errors = require("errors")

-- The stand runs at +04.
local OFFSET = 4 * 3600

local CYCLE = "acme.content_machine:scheduled_cycle.binding"

-- A row of the scheduler's `list`, in the shape list_schedules_func.lua
-- builds; the defaults are the stand's one real row.
local function row(fields: any?): any
    local out: any = {task_id = "t1", description = "Content beat: Dovod - blog", class = "component",
        schedule_type = "cron", schedule_expression = "0 7 * * 1", task_implementation_id = CYCLE,
        status = "scheduled", enabled = true, next_run_at = "2026-09-14T07:00:00Z",
        last_run_at = "2026-09-07T07:00:00Z", retry_count = 0, consecutive_failures = 0,
        created_at = "2026-09-01T10:00:00Z", updated_at = "2026-09-07T07:00:05Z"}
    for key, value in pairs(fields or {}) do out[key] = value end
    return out
end

-- The scheduler's `get` adds what `list` does not carry.
local function detail(fields: any?): any
    local out: any = row({max_retries = 3, retry_count = 1, timeout_seconds = 3600,
        task_args = {beat_id = "01a07161"}, task_context = {}, last_error = nil})
    for key, value in pairs(fields or {}) do out[key] = value end
    return out
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

local function by_kind(tree: any, kind: string): any
    local found = {}
    walk(tree, function(node) if node.kind == kind then found[#found + 1] = node end end)
    return found
end

local function define_tests()
    test.describe("Scheduled Tasks model: schedule wording", function()
        test.it("words interval, ticker and once the way the calculator reads them", function()
            test.eq(model.schedule_text("interval", "90s", OFFSET), "Every 90s")
            test.eq(model.schedule_text("ticker", "5m", OFFSET), "Every 5m (ticker)")
            test.eq(model.schedule_text("once", "2026-09-20T06:00:00Z", OFFSET), "Once at 2026-09-20 10:00")
            test.eq(model.schedule_text("once", "tomorrow", OFFSET), "Once: tomorrow")
            test.eq(model.schedule_text("lunar", "full", OFFSET), "lunar full")
        end)

        test.it("words the common cron shapes in UTC and shows the rest verbatim", function()
            test.eq(model.cron_text("0 7 * * 1"), "Weekly on Mon at 07:00 UTC")
            test.eq(model.cron_text("0 7 * * 1,4"), "Weekly on Mon, Thu at 07:00 UTC")
            test.eq(model.cron_text("0 7 * * 0"), "Weekly on Sun at 07:00 UTC")
            test.eq(model.cron_text("0 7 * * 7"), "Weekly on Sun at 07:00 UTC", "7 is Sunday too")
            test.eq(model.cron_text("30 6 * * *"), "Daily at 06:30 UTC")
            test.eq(model.cron_text("0 9 * * 1-5"), "Weekdays at 09:00 UTC")
            test.eq(model.cron_text("*/15 * * * *"), "Every 15 minutes")
            test.eq(model.cron_text("5 * * * *"), "Hourly at :05")
            test.eq(model.cron_text("0 0 1 * *"), "Monthly on day 1 at 00:00 UTC")
            test.eq(model.cron_text("0 7 * 1 1"), "cron 0 7 * 1 1", "a month field is not worded")
            test.eq(model.cron_text("0 25 * * *"), "cron 0 25 * * *", "an impossible hour is not worded")
            test.eq(model.cron_text("0 7 * * 2-4"), "cron 0 7 * * 2-4")
            test.eq(model.cron_text("0 7 * * 9"), "cron 0 7 * * 9", "no weekday 9")
            test.eq(model.cron_text("0 7 * * 1.5"), "cron 0 7 * * 1.5", "no weekday 1.5")
            test.eq(model.cron_text("hourly"), "cron hourly")
        end)
    end)

    test.describe("Scheduled Tasks model: rows", function()
        test.it("draws the stand's content beat the way the table shows it", function()
            local items, problem = model.tasks({row()})
            test.is_nil(problem)
            local rows = model.table_rows(items, OFFSET)
            test.eq(rows[1].id, "t1", "the table row is selected by task id")
            test.eq(rows[1].cells[1], "Content beat: Dovod - blog")
            test.eq(rows[1].cells[2], "Weekly on Mon at 07:00 UTC")
            test.eq(rows[1].cells[3], "2026-09-14 11:00")
            test.eq(rows[1].cells[4], "2026-09-07 11:00")
            test.eq(rows[1].cells[5], "Ready")
            test.eq(#rows[1].cells, 5)
        end)

        test.it("orders the soonest first and what does not fire last, by name", function()
            local items = model.tasks({
                row({task_id = "later", description = "B later", next_run_at = "2026-09-14T07:00:00Z"}),
                row({task_id = "a-paused", description = "A paused", enabled = 0, status = "disabled",
                    next_run_at = "2026-09-12T00:00:00Z"}),
                row({task_id = "soon", description = "C soon", next_run_at = "2026-09-12T08:00:00Z"}),
                row({task_id = "z-done", description = "A done", status = "completed", next_run_at = nil}),
            })
            test.eq(items[1].id, "soon")
            test.eq(items[2].id, "later")
            test.eq(items[3].id, "z-done", "not firing: by name (A done before A paused), not by id")
            test.eq(items[4].id, "a-paused", "a paused row with an earlier next_run_at does not jump the queue")
            test.eq(items[4].enabled, false, "SQLite's 0 is false")
            test.eq(model.table_rows(items, OFFSET)[4].cells[3], "Never", "a paused task has no next run")
            test.eq(model.status_text(items[4]), "Paused")
        end)

        test.it("names a row without task_id instead of dropping it silently", function()
            local items, problem = model.tasks({{description = "ghost"}, row({description = ""})})
            test.eq(#items, 1)
            test.eq(problem, "schedule row missing task_id")
            test.eq(model.name(items[1]), CYCLE, "no description: named by the implementation")
        end)

        test.it("says what the scheduler is doing with the row", function()
            local function status(fields: any): string return model.status_text(model.project(row(fields))) end
            test.eq(status({status = "executing"}), "Running")
            test.eq(status({status = "failed"}), "Failed")
            test.eq(status({status = "completed"}), "Completed")
            test.eq(status({consecutive_failures = 2}), "Ready (2 failed)")
            test.eq(status({enabled = 1}), "Ready", "SQLite's 1 is true")
            -- create() with enabled = false stores status "scheduled": only
            -- update() moves a row to "disabled". Such a row does not fire.
            local created_off = model.project(row({enabled = false, status = "scheduled"}))
            test.eq(model.status_text(created_off), "Paused")
            test.eq(model.next_text(created_off, OFFSET), "Never")
            test.eq(model.next_text(model.project(row({status = "executing"})), OFFSET), "Never")
        end)

        test.it("names the owner by the binding's title, else by the implementation id", function()
            local item = model.project(row())
            test.eq(model.detail(item, {[CYCLE] = "Scheduled Content Cycle"}),
                "Run by Scheduled Content Cycle (" .. CYCLE .. ") · component")
            test.eq(model.detail(item, {}), "Run by " .. CYCLE .. " · component")
            test.eq(model.detail(nil, {}), "")
        end)

        test.it("counts the tasks and says when the page is not all of them", function()
            test.eq(model.summary({row()}, 1), "1 task")
            test.eq(model.summary({row(), row(), row()}, 120), "3 tasks (showing the first 3 of 120)")
            test.eq(model.summary({}, nil), "0 tasks")
        end)
    end)

    test.describe("Scheduled Tasks model: actions", function()
        test.it("pauses and resumes through update's enabled", function()
            local running = model.project(row())
            local paused = model.project(row({enabled = false, status = "disabled"}))
            test.eq(model.toggle_request(running).enabled, false)
            test.eq(model.toggle_request(running).task_id, "t1")
            test.eq(model.toggle_request(paused).enabled, true)
            test.eq(model.toggle_label(running), "Pause")
            test.eq(model.toggle_label(paused), "Resume")
            test.eq(model.toggle_label(nil), "Pause")
        end)

        test.it("deletes with the body delete_schedule.lua sends, and says whose row it is", function()
            local body = model.delete_request("t1")
            test.eq(body.task_id, "t1")
            test.eq(body.lifecycle, true, "without it the scheduler refuses a component row")
            local owned = model.confirm_lines(model.project(row()), {[CYCLE] = "Scheduled Content Cycle"})
            test.eq(owned[1], "It was created by Scheduled Content Cycle (" .. CYCLE .. "),")
            test.eq(owned[#owned], "This cannot be undone.")
            local own = model.confirm_lines(model.project(row({class = "user"})), {})
            test.eq(own[1], "The schedule is removed; what it runs is not.")
        end)

        test.it("hands execute what the worker hands it", function()
            local payload = model.run_payload(detail({last_error = "boom", consecutive_failures = 2}), "2026-09-12T10:00:00Z")
            test.eq(payload.schedule_id, "t1")
            test.eq(payload.fired_at, "2026-09-12T10:00:00Z")
            test.eq(payload.args.beat_id, "01a07161")
            test.eq(payload.previous_runs.last_run_at, "2026-09-07T07:00:00Z")
            test.eq(payload.previous_runs.consecutive_failures, 2)
            test.eq(payload.previous_runs.retry_count, 1)
            test.eq(payload.previous_runs.last_error, "boom")
            test.eq(type(model.run_payload(detail({task_args = "garbage"}), "x").args), "table")
        end)

        test.it("tells a start, a skip and a refusal apart", function()
            test.eq(model.run_result("Job", {success = true, result = {run_id = "r1"}}, nil), "Job: started (r1)")
            test.eq(model.run_result("Beat", {success = true, result = {cycle_id = "c9"}}, nil), "Beat: started (c9)")
            test.eq(model.run_result("Job", {success = true}, nil), "Job: started")
            test.eq(model.run_result("Job", {success = true, result = {skipped = "paused"}}, nil),
                "Job: nothing to do now — paused", "a tick that did nothing is not a failure")
            test.eq(model.run_result("Beat", {success = false, error = "this schedule names no beat"}, nil),
                "Beat: could not start — this schedule names no beat")
            local denied = errors.new({message = "contract open refused", kind = errors.PERMISSION_DENIED})
            test.eq(model.run_result("Job", nil, denied), "Job: run: permission denied — contract open refused")
            test.eq(model.run_result("Job", "odd", nil), "Job: the task answered nothing")
        end)

        test.it("reads the scheduler's refusals from inside its answer", function()
            test.is_nil(model.failure("list", {success = true}, nil))
            local missing = errors.new({message = "Task not found or access denied", kind = errors.NOT_FOUND})
            test.eq(model.failure("delete", {success = false, error = missing}, nil),
                "delete: not found — Task not found or access denied")
            test.eq(model.failure("list", nil, "boom"), "list: boom")
            test.eq(model.failure("list", nil, nil), "list: the scheduler answered nothing")
        end)
    end)

    test.describe("Scheduled Tasks model: properties", function()
        test.it("lists get's fields as name and value pairs", function()
            local pairs_list = model.properties(detail({task_args = {beat_id = "b1", nested = {a = 1}}}),
                "Scheduled Content Cycle", OFFSET)
            local values = {}
            for _, pair in ipairs(pairs_list) do values[pair[1]] = pair[2] end
            test.eq(values["Name"], "Content beat: Dovod - blog")
            test.eq(values["Run by"], "Scheduled Content Cycle (" .. CYCLE .. ")")
            test.eq(values["Expression"], "cron 0 7 * * 1")
            test.eq(values["Next run"], "2026-09-14 11:00")
            test.eq(values["Retries"], "1 of 3")
            test.eq(values["Timeout"], "3600 s")
            test.eq(values["Arguments"], "beat_id=b1, nested={…}")
            test.eq(values["Created"], "2026-09-01 14:00")
            test.eq(model.args_text({zeta = 1, alpha = "a", mid = true}), "alpha=a, mid=true, zeta=1")
            test.eq(model.args_text({}), "none")
            test.eq(model.args_text(nil), "none")
        end)

        test.it("builds the sheet: the pairs read-only, the last error, the actions", function()
            local tree = model.props_tree(detail({last_error = "cannot read this beat's source"}), nil, OFFSET, false)
            local tables = by_kind(tree, "table")
            test.eq(#tables, 1)
            test.eq(tables[1].static, true, "a properties table is read, never selected")
            test.eq(#tables[1].rows, #model.properties(detail(), nil, OFFSET))
            local alert = nil
            walk(tree, function(node) if node.kind == "label" and node.alert then alert = node end end)
            test.not_nil(alert)
            test.eq(alert.text, "Last error: cannot read this beat's source")
            test.eq(by_id(tree, "props_run").disabled, false)
            test.eq(by_id(tree, "props_toggle").text, "Pause")
            test.eq(by_id(tree, "props_close").default, true)

            local paused = model.props_tree(detail({enabled = false, status = "disabled"}), nil, OFFSET, false)
            test.eq(by_id(paused, "props_toggle").text, "Resume")
            local running = model.props_tree(detail({status = "executing"}), nil, OFFSET, false)
            test.eq(by_id(running, "props_run").disabled, true, "no second start while the scheduler runs it")
            local busy = model.props_tree(detail(), nil, OFFSET, true)
            test.eq(by_id(busy, "props_run").disabled, true)
            test.eq(by_id(busy, "props_toggle").disabled, true)
            test.is_nil(by_id(busy, "props_close").disabled)
        end)
    end)

end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
