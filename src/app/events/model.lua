-- Event Viewer window model.
--
-- Pure functions between kickside/core's thread shapes and the window: thread
-- rows become the log tree, event rows become table rows and the event's
-- properties sheet, and a page of events gets its request here. No IO: the
-- window reads through kickside.core.threads:contract, the model only
-- translates, so a test runs it on stubs.
--
-- Time parsing and the wording of refusals are app.common:format's: one
-- parse of the stored timestamps and one rule for a refusal's kind across the
-- stand's windows.
local json = require("json")
local format = require("format")

local model = {}

model.PAGE = 100          -- events per request; "more" asks for the next page
model.THREAD_LIMIT = 1000 -- list_threads.lua's ceiling for one listing
model.MESSAGE_WIDTH = 240 -- characters of a message kept for its cell
model.ALL_TYPES = ""
model.EMPTY_LOGS = "No logs you can read"
model.EMPTY_EVENTS = "No events in this log"
model.NO_MATCH = "No loaded event matches the filter"
model.PICK = "Select a log on the left"

-- The body fields that say what happened, in the order they are looked for.
local MESSAGE_KEYS: {string} = {"title", "message", "text", "summary", "reason", "error", "status", "detail", "name"}

-- One UTF-8 character: the payloads here are mostly Russian, and cutting
-- a two-byte letter in half prints garbage.
local CHAR = "[%z\1-\127\194-\244][\128-\191]*"

local function text(value: any): string
    if value == nil then return "" end
    return tostring(value)
end

local function one_line(value: string): string
    return (value:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

function model.chars(value: string): {string}
    local out: {string} = {}
    for ch in value:gmatch(CHAR) do out[#out + 1] = ch end
    return out
end

-- clip(value, width) — at most `width` characters, the last one "…" when cut.
function model.clip(value: string, width: integer): string
    local chars = model.chars(value)
    if #chars <= width then return value end
    return table.concat(chars, "", 1, width - 1) .. "…"
end

-- ─── logs ───────────────────────────────────────────────────────────────

-- decode(body) -> value, ok. A body is JSON text (kickside_event.body) or
-- an already decoded table.
function model.decode(body: any): (any, boolean)
    if type(body) == "table" then return body, true end
    local raw = text(body)
    if raw == "" then return nil, false end
    local value, err = json.decode(raw)
    if err ~= nil or value == nil then return nil, false end
    return value, true
end

-- log_label(row) — the rule of list_threads.lua's thread_item: the
-- component's title, then a title or name kept in the thread's attrs, then
-- the id. A thread row has no title of its own.
function model.log_label(row: any): string
    local title = text(row.component_title)
    if title ~= "" then return title end
    local attrs, ok = model.decode(row.attrs)
    if ok and type(attrs) == "table" then
        local named = text(attrs.title)
        if named == "" then named = text(attrs.name) end
        if named ~= "" then return named end
    end
    local id = text(row.component_id)
    if id == "" then id = text(row.id) end
    return id
end

-- logs(rows) -> list, problem — one log per thread the contract listed. A row
-- without an id cannot be read; it is named, not dropped silently.
function model.logs(rows: any): (any, string?)
    local out = {}
    local problem = nil
    for _, raw in ipairs(type(rows) == "table" and rows or {}) do
        local row: any = raw
        if type(row) == "table" and type(row.id) == "string" and row.id ~= "" then
            out[#out + 1] = {
                id = row.id,
                label = model.log_label(row),
                class = text(row.thread_class),
                events = tonumber(row.event_count) or 0,
                last = row.last_event_ts,
            }
        else
            problem = "thread row missing id"
        end
    end
    return out, problem
end

function model.find_log(logs: any, id: any): any
    for _, log in ipairs(logs) do
        if log.id == id then return log end
    end
    return nil
end

function model.group_id(class: string): string return "class:" .. class end
function model.log_id(id: string): string return "log:" .. id end

-- log_of(tree_id) — the thread id behind a tree row, nil for a group.
function model.log_of(tree_id: any): string?
    return text(tree_id):match("^log:(.+)$")
end

function model.group_of(tree_id: any): string?
    return text(tree_id):match("^class:(.+)$")
end

-- groups(logs) -> classes in order, and the logs of each by label.
local function groups(logs: any): ({string}, {[string]: {any}})
    local members: {[string]: {any}} = {}
    local order: {string} = {}
    for _, log in ipairs(logs) do
        local list = members[log.class]
        if list == nil then
            list = {}
            members[log.class] = list
            order[#order + 1] = log.class
        end
        list[#list + 1] = log
    end
    table.sort(order)
    for _, class in ipairs(order) do
        table.sort(members[class], function(a: any, b: any): boolean
            if a.label ~= b.label then return a.label < b.label end
            return a.id < b.id
        end)
    end
    return order, members
end

-- tree_rows(logs, collapsed) — the SDK tree's visible rows: a folder per
-- thread class, a log per thread under it. Folders start expanded; the
-- window keeps the ones the user closed.
function model.tree_rows(logs: any, collapsed: any): any
    local closed: any = type(collapsed) == "table" and collapsed or {}
    local order, members = groups(logs)
    local rows = {}
    for _, class in ipairs(order) do
        local list = members[class]
        local open = closed[class] ~= true
        rows[#rows + 1] = {id = model.group_id(class), label = class .. " (" .. tostring(#list) .. ")",
            depth = 0, has_children = true, expanded = open, trail = {}, kind = "folder"}
        if open then
            for index, log in ipairs(list) do
                rows[#rows + 1] = {id = model.log_id(log.id), label = log.label, depth = 1,
                    has_children = false, expanded = false, trail = {index < #list}, kind = "entry"}
            end
        end
    end
    return rows
end

-- first_log(logs) — the log the window opens with: the first in tree order.
function model.first_log(logs: any): any
    local order, members = groups(logs)
    local class = order[1]
    if class == nil then return nil end
    return members[class][1]
end

-- ─── events ─────────────────────────────────────────────────────────────

-- split_type("acme.bridge.events:run.started") -> "acme.bridge",
-- "run.started": the module that wrote the event and what happened.
function model.split_type(value: any): (string, string)
    local full = text(value)
    local namespace, name = full:match("^(.-):(.+)$")
    if not namespace then return "", full end
    local source = (namespace :: string):gsub("%.events$", "")
    return source, name :: string
end

-- message(body) — one line for the Message column: the first of the fields
-- that say what happened, else the plain fields as key=value, else the body.
function model.message(body: any): string
    local value, ok = model.decode(body)
    if not ok then return model.clip(one_line(text(body)), model.MESSAGE_WIDTH) end
    if type(value) ~= "table" then return model.clip(one_line(text(value)), model.MESSAGE_WIDTH) end
    local map: any = value
    for _, key in ipairs(MESSAGE_KEYS) do
        local found = map[key]
        if type(found) == "string" and one_line(found) ~= "" then
            return model.clip(one_line(found), model.MESSAGE_WIDTH)
        end
    end
    local keys: {string} = {}
    for key, item in pairs(map) do
        if type(key) == "string" and type(item) ~= "table" then keys[#keys + 1] = key end
    end
    table.sort(keys)
    local parts: {string} = {}
    for _, key in ipairs(keys) do parts[#parts + 1] = key .. "=" .. text(map[key]) end
    if #parts == 0 then return model.clip(one_line(model.pretty(map)), model.MESSAGE_WIDTH) end
    return model.clip(one_line(table.concat(parts, ", ")), model.MESSAGE_WIDTH)
end

function model.event(row: any): any
    local source, name = model.split_type(row.type)
    return {id = text(row.id), seq = tonumber(row.seq) or 0, created_at = row.created_at,
        type = text(row.type), source = source, name = name, role = text(row.role),
        message = model.message(row.body), row = row}
end

-- events(rows) -> list, problem — in the order the contract returned them
-- (newest first).
function model.events(rows: any): (any, string?)
    local out = {}
    local problem = nil
    for _, raw in ipairs(type(rows) == "table" and rows or {}) do
        local row: any = raw
        if type(row) == "table" and type(row.id) == "string" and row.id ~= "" then
            out[#out + 1] = model.event(row)
        else
            problem = "event row missing id"
        end
    end
    return out, problem
end

-- merge(loaded, page) — the next page after the loaded ones; an event
-- already loaded (a write between two pages shifts nothing, but a retry may
-- repeat one) is not listed twice.
function model.merge(loaded: any, page: any): any
    local out = {}
    local seen: {[string]: boolean} = {}
    for _, event in ipairs(loaded) do
        out[#out + 1] = event
        seen[event.id] = true
    end
    for _, event in ipairs(page) do
        if not seen[event.id] then
            out[#out + 1] = event
            seen[event.id] = true
        end
    end
    return out
end

-- next_before(loaded) — the seq the next page starts below: the lowest
-- loaded, since pages come newest first. nil when nothing is loaded.
function model.next_before(loaded: any): number?
    local low: number = math.huge
    for _, event in ipairs(loaded) do
        local seq = tonumber(event.seq) or math.huge
        if seq < low then low = seq end
    end
    if low == math.huge then return nil end
    return low
end

-- A full page means there may be more; a short one is the end of the log.
function model.has_more(page: any): boolean
    return #page >= model.PAGE
end

-- page_request(thread_id, before, event_type) — list_events' window, the
-- way list_events.lua builds it: a seq bound, a limit, newest first, and
-- the type filter only when one is chosen.
function model.page_request(thread_id: string, before: number?, event_type: any): any
    local request: any = {thread_id = thread_id, limit = model.PAGE, ascending = false}
    if before ~= nil then request.before = before end
    if text(event_type) ~= "" then request.event_type = text(event_type) end
    return request
end

-- loads_more(action, more) — the events table said `end` (the wheel or the
-- keys pushed past its last loaded row) and the log has more below.
-- Reaching the last row is a `select` and loads nothing: only pushing past it.
function model.loads_more(action: any, more: boolean): boolean
    return more and type(action) == "table" and action.type == "end" and action.id == "events"
end

-- visible(events, needle) — the loaded events that contain the text, in any
-- column; ASCII letters match regardless of case.
function model.visible(events: any, needle: any): any
    local wanted = one_line(text(needle)):lower()
    if wanted == "" then return events end
    local out = {}
    for _, event in ipairs(events) do
        local hay = (event.source .. " " .. event.name .. " " .. event.role .. " " .. event.message):lower()
        if hay:find(wanted, 1, true) then out[#out + 1] = event end
    end
    return out
end

function model.table_rows(events: any, offset: number): any
    local rows = {}
    for _, event in ipairs(events) do
        rows[#rows + 1] = {id = event.id, cells = {
            format.when(event.created_at, offset, ""),
            event.source,
            event.name,
            event.message,
        }}
    end
    return rows
end

-- type_options(events, current) — the type filter's choices: all types, then
-- every type among the loaded events, and the chosen one even when this
-- page holds none of it.
function model.type_options(events: any, current: any): any
    local seen: {[string]: boolean} = {}
    local types: {string} = {}
    local function add(value: string)
        if value ~= "" and not seen[value] then
            seen[value] = true
            types[#types + 1] = value
        end
    end
    for _, event in ipairs(events) do add(text(event.type)) end
    add(text(current))
    table.sort(types)
    local out = {{value = model.ALL_TYPES, label = "(All types)"}}
    for _, value in ipairs(types) do out[#out + 1] = {value = value, label = value} end
    return out
end

function model.summary(loaded: number, shown: number, more: boolean, needle: any, event_type: any): string
    local line = tostring(loaded) .. (loaded == 1 and " event" or " events") .. " loaded"
    if more then line = line .. ", more below" end
    if text(event_type) ~= "" then line = line .. " · type " .. text(event_type) end
    if one_line(text(needle)) ~= "" then
        line = tostring(shown) .. " of " .. line .. " match \"" .. one_line(text(needle)) .. "\""
    end
    return line
end

-- ─── the event's properties ─────────────────────────────────────────────

local function quote(value: string): string
    local escaped = value:gsub("\\", "\\\\"):gsub("\"", "\\\""):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
    return "\"" .. escaped .. "\""
end

local function is_array(value: any): boolean
    local n = #value
    if n == 0 then return false end
    local count = 0
    for _ in pairs(value) do count = count + 1 end
    return count == n
end

-- pretty(value) — JSON with sorted keys, two spaces an indent. Written here
-- rather than taken from json.encode: an encoder escapes non-ASCII and HTML
-- characters, and a Russian payload would become \u sequences.
function model.pretty(value: any, indent: string?): string
    local pad = indent or ""
    if type(value) == "string" then return quote(value) end
    if type(value) ~= "table" then return text(value) end
    local inner = pad .. "  "
    local lines: {string} = {}
    if is_array(value) then
        for _, item in ipairs(value) do lines[#lines + 1] = inner .. model.pretty(item, inner) end
        return "[\n" .. table.concat(lines, ",\n") .. "\n" .. pad .. "]"
    end
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = {name = tostring(key), key = key} end
    if #keys == 0 then return "{}" end
    table.sort(keys, function(a: any, b: any): boolean return a.name < b.name end)
    for _, entry in ipairs(keys) do
        lines[#lines + 1] = inner .. quote(tostring(entry.name)) .. ": " .. model.pretty(value[entry.key], inner)
    end
    return "{\n" .. table.concat(lines, ",\n") .. "\n" .. pad .. "}"
end

-- payload_text(event) — the body for the sheet: pretty JSON when it is
-- JSON, the stored text otherwise, and the reference when the content is
-- not stored inline.
function model.payload_text(event: any): string
    local row: any = event.row or {}
    if row.content_mode == "ref" then return "Stored by reference: " .. text(row.content_ref) end
    local value, ok = model.decode(row.body)
    if ok then return model.pretty(value) end
    return text(row.body)
end

-- details(event, log_label, offset) — the name/value pairs of the sheet;
-- the optional identities only when the event carries them.
function model.details(event: any, log_label: any, offset: number): any
    local row: any = event.row or {}
    local pairs_list = {
        {"Date", format.when(event.created_at, offset, "")},
        {"Source", event.source},
        {"Type", event.name},
        {"Role", event.role},
        {"Log", text(log_label)},
        {"Sequence", text(math.tointeger(event.seq) or event.seq)},
        {"Event id", event.id},
    }
    local function add(label: string, value: any)
        if text(value) ~= "" then pairs_list[#pairs_list + 1] = {label, text(value)} end
    end
    if text(row.external_source) ~= "" then
        add("External", text(row.external_source) .. " / " .. text(row.external_id))
    end
    add("Trace", row.trace_id)
    add("Run", row.run_id)
    add("Caused by", row.caused_by_event_id)
    add("Correlation", row.correlation_key)
    return pairs_list
end

-- details_tree(event, log_label, offset) — the event's properties sheet: the
-- pairs read-only, the payload as the SDK's scrolling text (it wraps by its
-- own width, so the window does not), Close.
function model.details_tree(event: any, log_label: any, offset: number): any
    local rows = {}
    for index, pair in ipairs(model.details(event, log_label, offset)) do
        rows[#rows + 1] = {id = "d" .. tostring(index), cells = {pair[1], pair[2]}}
    end
    return {kind = "column", padding = 1, padding_bottom = 0, gap = 0, children = {
        {kind = "label", size = 1, text = "Event Properties: " .. event.type},
        {kind = "table", static = true, header = false, rows = rows, size = #rows,
            columns = {{title = "", width = 14}, {title = "", weight = 1}}},
        {kind = "label", size = 1, text = "Payload:"},
        {kind = "text", id = "payload", text = model.payload_text(event)},
        {kind = "row", size = 2, gap = 1, align = "right", children = {
            {kind = "button", id = "details_close", size = 10, text = "Close", default = true},
        }},
    }}
end

return model
