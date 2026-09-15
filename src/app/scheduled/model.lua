-- Scheduled Tasks window model.
--
-- Pure functions between kickside/cron's shapes and the window: a schedule row
-- of the scheduler contract becomes a table row, a `get` answer becomes the
-- properties sheet, and the three writes (update, delete, execute) get their
-- request bodies here. No IO: the window reads and writes, the model only
-- translates, so a test runs it on stubs.
--
-- Times arrive as RFC3339 UTC text (schedule_store keeps them canonical) and
-- are shown in the stand's local time, whose offset the window reads from the
-- clock once per load and passes in; parsing and formatting are
-- app.common:format's, shared with the stand's other windows. Cron fields are NOT converted: the
-- calculator evaluates them in UTC, and "at 07:00" with a local next run of
-- 11:00 beside it would read as a bug, so a cron schedule says "UTC".
local format = require("format")

local model = {}

model.PAGE_LIMIT = 100  -- list_schedules_func.lua's MAX_LIMIT
model.HEADING = "Tasks scheduled under your account:"
model.EMPTY = "No tasks are scheduled under your account"
model.NEVER = "Never"

local STATUS_TEXT: {[string]: string} = {
    scheduled = "Ready",
    executing = "Running",
    completed = "Completed",
    failed = "Failed",
    disabled = "Paused",
}

-- Typed on purpose: indexing an untyped array literal by an expression
-- (`WEEKDAYS[(n % 7) + 1]`) crashes the type checker (E9999, "type checker
-- internal error (skipped)"), and the whole module then types as `any` for
-- every importer.
local WEEKDAYS: {string} = {"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"}

local function text(value: any): string
    if value == nil then return "" end
    return tostring(value)
end

local function trim(value: any): string
    return (text(value):gsub("^%s+", ""):gsub("%s+$", ""))
end

local digits = format.digits
local two = format.two

-- ─── schedules ──────────────────────────────────────────────────────────

local function weekday_list(field: string): string?
    if field == "1-5" then return "weekdays" end
    local names = {}
    for part in field:gmatch("[^,]+") do
        -- An integer from the start, with no nil to narrow away: in this
        -- loop the checker narrows `n` after `if not n or …` to `never` on
        -- some runs and not on others ("cannot perform arithmetic on never").
        local n = math.tointeger(tonumber(part) or -1) or -1
        if n < 0 or n > 7 then return nil end
        names[#names + 1] = WEEKDAYS[(n % 7) + 1]
    end
    if #names == 0 then return nil end
    return table.concat(names, ", ")
end

local function clock(hour: string, minute: string): string?
    local h, m = tonumber(hour), tonumber(minute)
    if not h or not m or h < 0 or h > 23 or m < 0 or m > 59 then return nil end
    if math.floor(h) ~= h or math.floor(m) ~= m then return nil end
    return two(h) .. ":" .. two(m)
end

-- cron_text(expression) — the common five-field shapes in words, everything
-- else as the expression itself. Never a guess: a shape not recognised here
-- is shown verbatim rather than described approximately.
function model.cron_text(expression: any): string
    local fields: {string} = {}
    for field in text(expression):gmatch("%S+") do fields[#fields + 1] = field end
    local raw = "cron " .. trim(expression)
    if #fields ~= 5 then return raw end
    local minute, hour, dom, month, dow = fields[1], fields[2], fields[3], fields[4], fields[5]
    local step = minute:match("^%*/(%d+)$")
    if step and hour == "*" and dom == "*" and month == "*" and dow == "*" then
        return "Every " .. step .. " minutes"
    end
    if hour == "*" and dom == "*" and month == "*" and dow == "*" then
        local m = tonumber(minute)
        if m and m >= 0 and m <= 59 and math.floor(m) == m then return "Hourly at :" .. two(m) end
        return raw
    end
    local at = clock(hour, minute)
    if not at or month ~= "*" then return raw end
    if dom == "*" and dow == "*" then return "Daily at " .. at .. " UTC" end
    if dom == "*" then
        local days = weekday_list(dow)
        if not days then return raw end
        if days == "weekdays" then return "Weekdays at " .. at .. " UTC" end
        return "Weekly on " .. days .. " at " .. at .. " UTC"
    end
    if dow == "*" then
        local day = tonumber(dom)
        if day and day >= 1 and day <= 31 and math.floor(day) == day then
            return "Monthly on day " .. digits(day) .. " at " .. at .. " UTC"
        end
    end
    return raw
end

-- schedule_text(type, expression, offset) — the Schedule column. The forms
-- are the calculator's: interval and ticker take a Go duration ("90s", "2h"),
-- once takes an ISO time, cron takes five fields.
function model.schedule_text(kind: any, expression: any, offset: number): string
    local expr = trim(expression)
    if kind == "interval" then return "Every " .. expr end
    if kind == "ticker" then return "Every " .. expr .. " (ticker)" end
    if kind == "once" then
        local unix = format.parse_time(expr)
        if unix then return "Once at " .. format.format_time(unix, offset) end
        return "Once: " .. expr
    end
    if kind == "cron" then return model.cron_text(expr) end
    return text(kind) .. " " .. expr
end

-- A SQLite BOOLEAN comes back as 1/0 or true/false depending on the path.
function model.flag(value: any): boolean
    return value == true or value == 1 or value == "1" or value == "true"
end

-- project(row) — one row of the scheduler's `list` (or its `get`) as the
-- window keeps it.
function model.project(row: any): any
    return {
        id = text(row.task_id),
        description = text(row.description),
        class = text(row.class),
        kind = text(row.schedule_type),
        expression = text(row.schedule_expression),
        impl = text(row.task_implementation_id),
        status = text(row.status),
        enabled = model.flag(row.enabled),
        next_run_at = row.next_run_at,
        last_run_at = row.last_run_at,
        retry_count = tonumber(row.retry_count) or 0,
        consecutive_failures = tonumber(row.consecutive_failures) or 0,
        created_at = row.created_at,
        updated_at = row.updated_at,
    }
end

-- A task fires again only when it is enabled and waiting; a paused, running,
-- completed or failed one has no next run to show.
function model.firing(item: any): boolean
    return item.enabled == true and item.status == "scheduled"
end

-- tasks(rows) -> list, problem — sorted by the next run (the soonest first,
-- then everything that does not fire, by name). A row without task_id is a
-- contract violation: the valid rows stay and the problem is named.
function model.tasks(rows: any): (any, string?)
    local out = {}
    local problem = nil
    for _, raw in ipairs(type(rows) == "table" and rows or {}) do
        local row: any = raw
        if type(row) == "table" and type(row.task_id) == "string" and row.task_id ~= "" then
            out[#out + 1] = model.project(row)
        else
            problem = "schedule row missing task_id"
        end
    end
    local function key(item: any): number
        local unix = model.firing(item) and format.parse_time(item.next_run_at) or nil
        return unix or math.huge
    end
    table.sort(out, function(a: any, b: any): boolean
        local ka, kb = key(a), key(b)
        if ka ~= kb then return ka < kb end
        if model.name(a) ~= model.name(b) then return model.name(a) < model.name(b) end
        return a.id < b.id
    end)
    return out, problem
end

function model.find(items: any, id: any): any
    for _, item in ipairs(items) do
        if item.id == id then return item end
    end
    return nil
end

-- The owner names the row: bridge writes "Bridge job: <title>", the content
-- machine "Content beat: <title>". A row without a description is named by
-- the implementation that runs it.
function model.name(item: any): string
    local description, impl = text(item.description), text(item.impl)
    if description ~= "" then return description end
    if impl ~= "" then return impl end
    return text(item.id)
end

function model.status_text(item: any): string
    if not item.enabled then return "Paused" end
    local shown = STATUS_TEXT[item.status] or item.status
    if item.status == "scheduled" and item.consecutive_failures > 0 then
        return shown .. " (" .. digits(item.consecutive_failures) .. " failed)"
    end
    return shown
end

function model.next_text(item: any, offset: number): string
    if not model.firing(item) then return model.NEVER end
    return format.when(item.next_run_at, offset, model.NEVER)
end

function model.table_rows(items: any, offset: number): any
    local rows = {}
    for _, item in ipairs(items) do
        rows[#rows + 1] = {id = item.id, cells = {
            model.name(item),
            model.schedule_text(item.kind, item.expression, offset),
            model.next_text(item, offset),
            format.when(item.last_run_at, offset, model.NEVER),
            model.status_text(item),
        }}
    end
    return rows
end

-- owner(impl, title) — who runs the task: the binding's title when the
-- window could read it, the implementation id otherwise. The id is the
-- owner's real name, so the fallback is not a guess.
function model.owner(impl: any, title: any): string
    local shown = trim(title)
    if shown ~= "" then return shown .. " (" .. text(impl) .. ")" end
    return text(impl)
end

function model.detail(item: any, owners: any): string
    if not item then return "" end
    local titles: any = type(owners) == "table" and owners or {}
    local parts = {"Run by " .. model.owner(item.impl, titles[item.impl])}
    if item.class ~= "" then parts[#parts + 1] = item.class end
    return table.concat(parts, " · ")
end

function model.summary(items: any, total: any): string
    local count = #items
    local line = count == 1 and "1 task" or (digits(count) .. " tasks")
    local all = tonumber(total)
    if all and all > count then line = line .. " (showing the first " .. digits(count) .. " of " .. digits(all) .. ")" end
    return line
end

-- ─── actions ────────────────────────────────────────────────────────────

-- Pause and resume are the scheduler's `update` with `enabled`: the
-- repository turns it into one lifecycle transition (disabled / scheduled)
-- and invalidates an in-flight claim in the same statement.
function model.toggle_request(item: any): any
    return {task_id = item.id, enabled = not item.enabled}
end

function model.toggle_label(item: any): string
    if item and not item.enabled then return "Resume" end
    return "Pause"
end

-- delete_request(id) — the body delete_schedule.lua sends: `lifecycle = true`
-- is the owner's delete, and without it the scheduler refuses rows of class
-- "component" (bridge jobs, content beats). The window is the same caller as
-- that handler, so it sends the same body; the confirmation says whose row
-- it is instead.
function model.delete_request(id: any): any
    return {task_id = text(id), lifecycle = true}
end

function model.confirm_lines(item: any, owners: any): any
    local lines = {}
    if item.class == "component" then
        local titles: any = type(owners) == "table" and owners or {}
        lines[#lines + 1] = "It was created by " .. model.owner(item.impl, titles[item.impl]) .. ","
        lines[#lines + 1] = "which may still expect it to run."
    else
        lines[#lines + 1] = "The schedule is removed; what it runs is not."
    end
    lines[#lines + 1] = "This cannot be undone."
    return lines
end

-- run_payload(detail, fired_at) — what the worker hands schedulable.execute
-- (worker.lua execute_task): the schedule id, a fire timestamp, the previous
-- runs and the row's arguments. A fresh fired_at makes Run Now a distinct
-- fire: automation deduplicates on schedule_id:fired_at.
function model.run_payload(detail: any, fired_at: string): any
    return {
        schedule_id = text(detail.task_id),
        fired_at = fired_at,
        previous_runs = {
            last_run_at = detail.last_run_at,
            consecutive_failures = detail.consecutive_failures,
            retry_count = detail.retry_count,
            last_error = detail.last_error,
        },
        args = type(detail.task_args) == "table" and detail.task_args or {},
    }
end

-- run_result(name, result, err) — execute's answer for the status bar. A
-- tick that did nothing ("paused", "a cycle is already in flight") is a
-- success with `skipped`: it is said as such, not as a failure. A manual run
-- does not move the row's Last Run: that column is the scheduler's.
function model.run_result(name: string, result: any, err: any): string
    if err ~= nil then return format.explain(name .. ": run", err) end
    if type(result) ~= "table" then return name .. ": the task answered nothing" end
    if result.success == false then
        return name .. ": could not start — " .. text(result.error or "no reason given")
    end
    local out: any = type(result.result) == "table" and result.result or {}
    if out.skipped ~= nil then return name .. ": nothing to do now — " .. text(out.skipped) end
    local handle = out.run_id or out.cycle_id
    if handle ~= nil then return name .. ": started (" .. text(handle) .. ")" end
    return name .. ": started"
end

-- failure(what, answer, err) — a scheduler answer that is not a success, as
-- text; nil when it succeeded. The scheduler returns its refusals inside the
-- answer (`success = false, error = <typed error>`), not as the second value.
function model.failure(what: string, answer: any, err: any): string?
    if err ~= nil then return format.explain(what, err) end
    if type(answer) ~= "table" then return what .. ": the scheduler answered nothing" end
    if answer.success == false then return format.explain(what, answer.error) end
    return nil
end

-- ─── properties ─────────────────────────────────────────────────────────

-- args_text(args) — a task's arguments as "key=value" pairs, sorted; a
-- nested table is shown as "{…}" rather than half-printed.
function model.args_text(args: any): string
    if type(args) ~= "table" then return "none" end
    local keys = {}
    for key in pairs(args) do keys[#keys + 1] = tostring(key) end
    table.sort(keys)
    local parts = {}
    for _, key in ipairs(keys) do
        local value = args[key]
        parts[#parts + 1] = key .. "=" .. (type(value) == "table" and "{…}" or text(value))
    end
    if #parts == 0 then return "none" end
    return table.concat(parts, ", ")
end

-- properties(detail, owner_title, offset) — the name/value pairs of the
-- sheet, from the scheduler's `get` (which carries what `list` does not:
-- retries, the last error, the timeout and the arguments).
function model.properties(detail: any, owner_title: any, offset: number): any
    local item = model.project(detail)
    local retries = digits(tonumber(detail.retry_count) or 0) .. " of " .. digits(tonumber(detail.max_retries) or 0)
    return {
        {"Name", model.name(item)},
        {"Run by", model.owner(item.impl, owner_title)},
        {"Class", item.class},
        {"Schedule", model.schedule_text(item.kind, item.expression, offset)},
        {"Expression", item.kind .. " " .. item.expression},
        {"Next run", model.next_text(item, offset)},
        {"Last run", format.when(item.last_run_at, offset, model.NEVER)},
        {"Status", model.status_text(item)},
        {"Retries", retries},
        {"Failures in a row", digits(item.consecutive_failures)},
        {"Timeout", digits(tonumber(detail.timeout_seconds) or 0) .. " s"},
        {"Arguments", model.args_text(detail.task_args)},
        {"Created", format.when(item.created_at, offset, "")},
        {"Updated", format.when(item.updated_at, offset, "")},
    }
end

-- props_tree(detail, owner_title, offset, busy) — the Properties sheet: the
-- pairs read-only, the last error wrapped under them, Run Now and
-- Pause/Resume, Close. `busy` disables the actions while a request runs.
function model.props_tree(detail: any, owner_title: any, offset: number, busy: any): any
    local item = model.project(detail)
    local rows = {}
    for index, pair in ipairs(model.properties(detail, owner_title, offset)) do
        rows[#rows + 1] = {id = "p" .. digits(index), cells = {pair[1], pair[2]}}
    end
    local last_error = trim(detail.last_error)
    return {kind = "column", padding = 1, padding_bottom = 0, gap = 0, children = {
        {kind = "label", size = 1, text = "Properties: " .. model.name(item)},
        {kind = "table", static = true, header = false, rows = rows,
            columns = {{title = "", width = 20}, {title = "", weight = 1}}},
        {kind = "label", size = 2, wrap = true, alert = last_error ~= "",
            text = last_error ~= "" and ("Last error: " .. last_error) or "No error recorded."},
        {kind = "row", size = 2, gap = 1, align = "right", children = {
            {kind = "button", id = "props_run", size = 11, text = "Run Now",
                disabled = busy == true or item.status == "executing"},
            {kind = "button", id = "props_toggle", size = 10, text = model.toggle_label(item), disabled = busy == true},
            {kind = "button", id = "props_close", size = 10, text = "Close", default = true},
        }},
    }}
end

return model
