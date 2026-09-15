-- Services window model.
--
-- Pure functions between the runtime's shapes and the window: the
-- supervisor's states (system.supervisor.states) joined with each service's
-- registry entry become table rows, the detail line, the properties sheet and
-- the status line. No IO here: the window reads, the model translates, so a
-- test runs it on stubs.
--
-- Refusals are worded by the shell's windows.shell.config:system
-- (`facts.reason`): the runtime's system module marks a permission denial
-- with kind Invalid and the text "permission denied: system.read on …", not
-- with PermissionDenied, and that library is the one place that knows it.
local facts = require("facts")

local model = {}

model.EMPTY = "The supervisor reports no services"

-- Start, Stop and Restart are drawn disabled and say why, instead of doing
-- nothing when pressed: the runtime gives Lua no per-service control.
-- system.supervisor has `state` and `states` only
-- (runtime/lua/modules/system/module.go, createSupervisorTable), and the Go
-- supervisor exports Start/Stop of the whole supervisor, not of one service.
model.NO_CONTROL = "Start, Stop, Restart: this runtime has no service control for Lua"

model.COLUMNS = {
    {title = "Service", weight = 5},
    {title = "Status", width = 10},
    {title = "Startup", width = 14},
    {title = "Host", weight = 2},
}

-- The width of the caption column on the Properties… sheet, in cells.
model.LABEL_WIDTH = 12

-- supervisor.Status values (runtime api/supervisor/supervisor.go).
local STATUS_TEXT: {[string]: string} = {
    unknown = "Unknown",
    starting = "Starting",
    running = "Running",
    stopping = "Stopping",
    stopped = "Stopped",
    exited = "Exited",
    failed = "Failed",
}

local function text(value: any): string
    if value == nil then return "" end
    return tostring(value)
end

local function number(value: any): number
    return tonumber(value) or 0
end

local function list_text(value: any): string
    if type(value) ~= "table" then return text(value) end
    local out = {}
    for _, item in ipairs(value) do out[#out + 1] = text(item) end
    return table.concat(out, ", ")
end

local function lifecycle_of(entry: any): any
    if type(entry) ~= "table" or type(entry.data) ~= "table" then return nil end
    local lifecycle: any = entry.data.lifecycle
    return type(lifecycle) == "table" and lifecycle or nil
end

-- ─── rows ───────────────────────────────────────────────────────────────

function model.status_text(status: any): string
    return STATUS_TEXT[text(status)] or text(status)
end

-- failed(item) — a service that stopped on its own; its details are an error.
function model.failed(item: any): boolean
    return item.status == "failed" or item.status == "exited"
end

-- startup(entry) — the Startup column, from lifecycle.auto_start (false by
-- default) and lifecycle.startup: an auto-start root marked "optional" may
-- fail without failing the boot. "?" when the entry could not be read: the
-- column is a claim about the declaration, and there is none to read.
function model.startup(entry: any): string
    if type(entry) ~= "table" then return "?" end
    local lifecycle: any = lifecycle_of(entry)
    if not lifecycle or lifecycle.auto_start ~= true then return "Manual" end
    if lifecycle.startup == "optional" then return "Auto, optional" end
    return "Automatic"
end

-- host(entry) — the process host a process.service runs on (data.host). The
-- other supervised kinds (an HTTP server, a process host itself) have none.
function model.host(entry: any): string
    if type(entry) ~= "table" then return "?" end
    local data: any = type(entry.data) == "table" and entry.data or {}
    if type(data.host) == "string" and data.host ~= "" then return data.host end
    return "-"
end

-- services(states, entries) -> list, problem
--
-- `states` is what system.supervisor.states() returned; `entries[id]` is what
-- registry.get answered for that id: {entry = …} or {problem = "…"}. A
-- service whose entry could not be read keeps its row — the supervisor's word
-- on its status is still true — with "?" in the declared columns, and the
-- first reason comes back with the count instead of the row disappearing.
function model.services(states: any, entries: any): (any, string?)
    local out = {}
    local unread, reason = 0, nil
    for _, raw in ipairs(type(states) == "table" and states or {}) do
        local state: any = raw
        if type(state) == "table" and type(state.id) == "string" and state.id ~= "" then
            local found: any = type(entries) == "table" and entries[state.id] or nil
            local entry: any = type(found) == "table" and found.entry or nil
            local problem: any = nil
            if entry == nil then
                problem = type(found) == "table" and found.problem or "registry entry not read"
                unread = unread + 1
                reason = reason or problem
            end
            out[#out + 1] = {
                id = state.id,
                status = text(state.status),
                desired = text(state.desired),
                retry_count = number(state.retry_count),
                started_at = number(state.started_at),
                last_update = number(state.last_update),
                details = text(state.details),
                entry = entry,
                entry_problem = problem,
                startup = model.startup(entry),
                host = model.host(entry),
            }
        end
    end
    table.sort(out, function(a: any, b: any): boolean return a.id < b.id end)
    if unread == 0 then return out, nil end
    local count = unread == 1 and "1 registry entry" or string.format("%d registry entries", unread)
    return out, count .. " not read: " .. tostring(reason)
end

function model.find(services: any, id: any): any
    for _, item in ipairs(services) do
        if item.id == id then return item end
    end
    return nil
end

function model.table_rows(services: any): any
    local rows = {}
    for _, item in ipairs(services) do
        rows[#rows + 1] = {id = item.id, cells = {item.id, model.status_text(item.status), item.startup, item.host}}
    end
    return rows
end

-- ─── lines ──────────────────────────────────────────────────────────────

-- age(ns, now_ns) — how long ago, from the supervisor's UnixNano stamps. A
-- stamp at or below zero is Go's zero time (a service never started), not
-- the epoch.
function model.age(ns: any, now_ns: any): string
    local at = number(ns)
    if at <= 0 then return "never" end
    local seconds = math.floor((number(now_ns) - at) / 1e9)
    if seconds < 0 then seconds = 0 end
    if seconds < 60 then return string.format("%ds ago", seconds) end
    local minutes = math.floor(seconds / 60)
    if minutes < 60 then return string.format("%dm ago", minutes) end
    local hours = math.floor(minutes / 60)
    if hours < 24 then return string.format("%dh %dm ago", hours, minutes % 60) end
    return string.format("%dd ago", math.floor(hours / 24))
end

-- detail(item, now_ns) — the line under the table for the selected service.
function model.detail(item: any, now_ns: any): string
    if not item then return "" end
    local head = model.status_text(item.status)
    if item.desired ~= "" and item.desired ~= item.status then
        head = head .. ", desired " .. model.status_text(item.desired)
    end
    local parts = {head}
    if item.status == "running" then parts[#parts + 1] = "started " .. model.age(item.started_at, now_ns) end
    if item.retry_count > 0 then
        parts[#parts + 1] = item.retry_count == 1 and "1 retry" or string.format("%d retries", item.retry_count)
    end
    if model.failed(item) and item.details ~= "" then parts[#parts + 1] = "last error: " .. item.details end
    if item.entry_problem then parts[#parts + 1] = tostring(item.entry_problem) end
    return table.concat(parts, " · ")
end

-- summary(services, host_count, hosts_problem) — how many services, how many
-- run, how many process hosts; the host count is a reason instead when the
-- hosts could not be read.
function model.summary(services: any, host_count: any, hosts_problem: any): string
    local running = 0
    for _, item in ipairs(services) do
        if item.status == "running" then running = running + 1 end
    end
    local line = (#services == 1 and "1 service" or string.format("%d services", #services))
        .. string.format(", %d running", running)
    if host_count ~= nil then
        line = line .. " · " .. (host_count == 1 and "1 process host" or string.format("%d process hosts", host_count))
    elseif hosts_problem then
        line = line .. " · " .. tostring(hosts_problem)
    end
    return line
end

-- status_line(state) — the status bar: a message of the moment first, then
-- why the list is empty, then the summary with the entries not read.
function model.status_line(state: any): string
    if state.status and state.status ~= "" then return tostring(state.status) end
    if state.failure then return tostring(state.failure) end
    local line = model.summary(state.services, state.host_count, state.hosts_problem)
    if state.entry_problem then line = line .. " · " .. tostring(state.entry_problem) end
    return line
end

-- heading(snap) — "Services on <host> (node <name>):" from the shell's facts
-- snapshot; a fact that could not be read is left out, not guessed.
function model.heading(snap: any): string
    local known: any = type(snap) == "table" and snap or {}
    local where = text(known.hostname)
    local node = text(known.node_id)
    if where == "" then where = "this node" end
    if node ~= "" and node ~= where then where = where .. " (node " .. node .. ")" end
    return "Services on " .. where .. ":"
end

-- ─── properties ─────────────────────────────────────────────────────────

-- The services it waits for: `requires`, then the legacy `depends_on`, each
-- once — LifecycleConfig.RequiredServices in the runtime.
local function requires_of(lifecycle: any): any
    local out, seen = {}, {}
    for _, key in ipairs({"requires", "depends_on"}) do
        local list: any = lifecycle[key]
        for _, id in ipairs(type(list) == "table" and list or {}) do
            local name = text(id)
            if name ~= "" and not seen[name] then
                seen[name] = true
                out[#out + 1] = name
            end
        end
    end
    return out
end

local function restart_text(restart: any): string
    if type(restart) ~= "table" then return "runtime defaults" end
    local attempts = number(restart.max_attempts)
    local line = attempts > 0 and string.format("up to %d attempts", attempts) or "unlimited attempts"
    if restart.initial_delay ~= nil then line = line .. ", first after " .. text(restart.initial_delay) end
    return line
end

-- properties(item, now_ns) -> {{label, value}, …}
--
-- What Properties… shows: the supervisor's facts and the declaration's — the
-- host, the process, the actor and policies the service runs under, what it
-- requires, its restart policy. `details` is the supervisor's last word on the
-- service: for a failed or exited one that is the error it stopped with.
function model.properties(item: any, now_ns: any): any
    local lines = {}
    local function add(label: string, value: any)
        local shown = text(value)
        lines[#lines + 1] = {label = label, value = shown ~= "" and shown or "none"}
    end
    add("Service", item.id)
    local status = model.status_text(item.status)
    if item.desired ~= "" and item.desired ~= item.status then
        status = status .. " (desired " .. model.status_text(item.desired) .. ")"
    end
    add("Status", status)
    local entry: any = item.entry
    if entry then
        local data: any = type(entry.data) == "table" and entry.data or {}
        local lifecycle: any = lifecycle_of(entry) or {}
        local security: any = type(lifecycle.security) == "table" and lifecycle.security or {}
        local actor: any = type(security.actor) == "table" and security.actor or {}
        add("Kind", entry.kind)
        add("Startup", item.startup)
        add("Host", item.host ~= "-" and item.host or "")
        add("Process", data.process)
        add("Actor", actor.id)
        add("Policies", list_text(security.policies))
        add("Requires", list_text(requires_of(lifecycle)))
        add("Restart", restart_text(lifecycle.restart))
    else
        add("Entry", item.entry_problem or "not read")
    end
    add("Started", item.status == "running" and model.age(item.started_at, now_ns) or "")
    add("Updated", model.age(item.last_update, now_ns))
    add("Retries", string.format("%d", item.retry_count))
    add(model.failed(item) and "Last error" or "Details", item.details)
    return lines
end

-- properties_tree(item, now_ns) — the Properties… sheet: a row per line, the
-- last one (the error, which runs long) wrapped over the rows left.
function model.properties_tree(item: any, now_ns: any): any
    local children: any = {
        {kind = "label", size = 1, text = "Properties: " .. tostring(item.id)},
        {kind = "label", size = 1, text = ""},
    }
    local lines = model.properties(item, now_ns)
    for index, line in ipairs(lines) do
        local last = index == #lines
        local row: any = {kind = "row", gap = 1, children = {
            {kind = "label", size = model.LABEL_WIDTH, text = line.label .. ":"},
            {kind = "label", text = line.value, wrap = last},
        }}
        if not last then row.size = 1 end
        children[#children + 1] = row
    end
    children[#children + 1] = {kind = "row", size = 2, gap = 1, align = "right", children = {
        {kind = "button", id = "props_ok", size = 8, text = "OK", default = true},
    }}
    return {kind = "column", padding = 1, padding_bottom = 0, gap = 0, children = children}
end

-- ─── the list ───────────────────────────────────────────────────────────

-- list_tree(state, now_ns) — the list sheet. Start, Stop and Restart are
-- disabled for every row, and the line above them says why (NO_CONTROL).
function model.list_tree(state: any, now_ns: any): any
    local item = model.find(state.services, state.selected_id)
    local body: any
    if #state.services == 0 then
        body = {kind = "label", text = state.failure and "The services could not be read." or model.EMPTY,
            alert = state.failure ~= nil}
    else
        body = {kind = "table", id = "services", columns = model.COLUMNS,
            rows = model.table_rows(state.services), selected = state.selected_id}
    end
    return {kind = "column", padding = 1, padding_bottom = 0, gap = 0, children = {
        {kind = "label", size = 1, text = state.heading or model.heading(nil)},
        body,
        {kind = "label", size = 1, text = model.detail(item, now_ns)},
        {kind = "label", size = 1, text = model.NO_CONTROL},
        {kind = "row", size = 2, gap = 1, align = "right", children = {
            {kind = "button", id = "start", size = 9, text = "Start", disabled = true},
            {kind = "button", id = "stop", size = 8, text = "Stop", disabled = true},
            {kind = "button", id = "restart", size = 11, text = "Restart", disabled = true},
            {kind = "button", id = "refresh", size = 11, text = "Refresh"},
            {kind = "button", id = "props", size = 14, text = "Properties…", disabled = item == nil},
            {kind = "button", id = "close", size = 9, text = "Close", default = true},
        }},
    }}
end

-- ─── refusals ───────────────────────────────────────────────────────────

-- explain(what, err) — a refusal as text for the status bar, worded by the
-- shell's facts library: a permission denial reads as one, not as
-- "unavailable", because the fix is a policy, not the runtime.
function model.explain(what: string, err: any): string
    if err == nil then return what .. ": no answer" end
    return facts.reason(what, err)
end

return model
