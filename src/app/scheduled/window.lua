-- Scheduled Tasks — kickside/cron's schedules in the Windows 95 shell.
--
-- A window on the shell SDK. IO lives here and does what the HTTP handlers of
-- kickside/cron do, without HTTP; the model (app.scheduled:model) translates
-- shapes and is tested on its own.
--
-- Sheets instead of child windows: the list, Properties and the delete
-- confirmation are modes of one window. Esc closes a sheet first, then the
-- window (close_on_escape: update returns false only in list mode).
--
-- Run Now and Delete are deferred by one timer tick: the status bar says what
-- is running in the frame BEFORE update blocks on the request, instead of a
-- frozen window. Both are quick on the stand's owners (bridge and the content
-- machine start a process and answer), but an owner is free to be slow.
local app = require("app")
local ui = require("ui")
local model = require("model")
local format = require("format")
local contract = require("contract")
local registry = require("registry")
local security = require("security")
local time = require("time")

local definition: any = {title = "Scheduled Tasks"}

local SCHEDULER = "kickside.cron:scheduler"
local SCHEDULABLE = "kickside.cron:schedulable"

local COLUMNS = {
    {title = "Name", weight = 3},
    {title = "Schedule", weight = 3},
    {title = "Next Run", width = 17},
    {title = "Last Run", width = 17},
    {title = "Status", width = 13},
}

-- ─── IO ─────────────────────────────────────────────────────────────────

-- A contract opener with the caller's actor and scope, as list_schedules.lua
-- opens the scheduler: the binding functions read security.actor() and keep
-- to that actor's rows.
local function as_caller(def: any): any
    local opener: any = def
    local actor, scope = security.actor(), security.scope()
    if actor and scope then opener = opener:with_actor(actor):with_scope(scope) end
    return opener
end

local function scheduler(): (any, string?)
    local def, derr = contract.get(SCHEDULER)
    if derr or not def then return nil, format.explain("scheduler contract", derr) end
    local instance, oerr = as_caller(def):open()
    if oerr or not instance then return nil, format.explain("scheduler", oerr) end
    return instance, nil
end

-- The stand's offset from UTC, read from the clock the taskbar reads.
local function local_offset(): number
    return format.parse_offset(time.now():format("-07:00"))
end

-- The owner's title is the binding's meta.title ("Scheduled Bridge Run").
-- It is decoration: when the registry does not give it, the row is named by
-- the implementation id, which IS the owner's name, so nothing is hidden.
local function load_owners(state: any)
    for _, item in ipairs(state.tasks) do
        if item.impl ~= "" and state.owners[item.impl] == nil then
            local entry, err = registry.get(tostring(item.impl))
            local meta: any = not err and type(entry) == "table" and type((entry :: any).meta) == "table"
                and (entry :: any).meta or nil
            state.owners[item.impl] = meta and type(meta.title) == "string" and meta.title or ""
        end
    end
end

local function load_tasks(state: any)
    state.failure, state.total = nil, nil
    state.offset = local_offset()
    local instance, err = scheduler()
    if not instance then
        state.tasks, state.failure = {}, err
        return
    end
    local answer, lerr = instance:list({
        pagination = {limit = model.PAGE_LIMIT, offset = 0},
        ordering = {field = "next_run_at", direction = "ASC"},
    })
    local problem = model.failure("list", answer, lerr)
    if problem then
        state.tasks, state.failure = {}, problem
        return
    end
    if type(answer.schedules) ~= "table" then
        state.tasks, state.failure = {}, "list: the scheduler returned a non-conforming page"
        return
    end
    local items, bad = model.tasks(answer.schedules)
    state.tasks, state.failure, state.total = items, bad, answer.total_count
    if state.selected_id == nil or model.find(items, state.selected_id) == nil then
        state.selected_id = items[1] and items[1].id or nil
    end
    load_owners(state)
end

-- read_detail(id) — the scheduler's get: what list does not carry (retries,
-- the last error, the timeout, the arguments and the task context).
local function read_detail(id: any): (any, string?)
    local instance, err = scheduler()
    if not instance then return nil, err end
    local answer, gerr = instance:get({task_id = tostring(id)})
    local problem = model.failure("properties", answer, gerr)
    if problem then return nil, problem end
    return answer, nil
end

local function toggle(item: any): (boolean, string)
    local instance, err = scheduler()
    if not instance then return false, tostring(err) end
    local answer, uerr = instance:update(model.toggle_request(item))
    local problem = model.failure(item.enabled and "pause" or "resume", answer, uerr)
    if problem then return false, problem end
    return true, (item.enabled and "Paused: " or "Resumed: ") .. model.name(item)
end

-- remove(item) — delete_schedule.lua's request, through the scheduler.
local function remove(item: any): (boolean, string)
    local instance, err = scheduler()
    if not instance then return false, tostring(err) end
    local answer, derr = instance:delete(model.delete_request(item.id))
    local problem = model.failure("delete", answer, derr)
    if problem then return false, problem end
    if answer.deleted == false then return false, model.name(item) .. " was already gone" end
    return true, model.name(item) .. " deleted"
end

-- run_now(item) — what the worker does when the time comes (worker.lua
-- execute_task), once, now: open kickside.cron:schedulable on the row's
-- implementation with its task_context and call execute with its arguments.
-- It runs under the caller — the row's own actor, since the scheduler lists
-- nobody else's — and does not touch the row: Last Run stays the
-- scheduler's. The result is assigned before returning: a bare
-- `return <yield-call>(...)` at the end of a function is the go-lua trap
-- that silently skips the call.
local function run_now(item: any): string
    local name = model.name(item)
    local detail, err = read_detail(item.id)
    if not detail then return tostring(err) end
    local def, derr = contract.get(SCHEDULABLE)
    if derr or not def then return format.explain("schedulable contract", derr) end
    local context: any = type(detail.task_context) == "table" and detail.task_context or {}
    local instance, oerr = as_caller(def):open(tostring(detail.task_implementation_id), context)
    if oerr or not instance then return format.explain(name .. ": open " .. tostring(detail.task_implementation_id), oerr) end
    local result, xerr = instance:execute(model.run_payload(detail, time.now():utc():format(time.RFC3339)))
    local line = model.run_result(name, result, xerr)
    return line
end

-- ─── state ──────────────────────────────────────────────────────────────

function definition.init(args: any, context: any): any
    local state: any = {mode = "list", tasks = {}, owners = {}, selected_id = nil, detail = nil,
        status = nil, failure = nil, total = nil, offset = 0, pending = nil}
    load_tasks(state)
    return state
end

local function selected(state: any): any
    return model.find(state.tasks, state.selected_id)
end

local function back_to_list(state: any)
    state.mode, state.detail = "list", nil
end

local function defer(state: any, context: any, op: any)
    state.pending = op
    state.status = op.label
    context.after("30ms", "pending")
end

-- ─── view ───────────────────────────────────────────────────────────────

local function list_view(state: any): any
    local item = selected(state)
    local none = item == nil
    local busy = state.pending ~= nil
    local body: any
    if #state.tasks == 0 then
        body = {kind = "label", text = state.failure and "The scheduled tasks could not be read." or model.EMPTY,
            alert = state.failure ~= nil}
    else
        body = {kind = "table", id = "tasks", columns = COLUMNS,
            rows = model.table_rows(state.tasks, state.offset), selected = state.selected_id}
    end
    return {kind = "column", padding = 1, padding_bottom = 0, gap = 0, children = {
        {kind = "label", size = 1, text = model.HEADING},
        body,
        {kind = "label", size = 1, text = model.detail(item, state.owners)},
        {kind = "row", size = 2, gap = 1, align = "right", children = {
            {kind = "button", id = "run", size = 11, text = "Run Now",
                disabled = none or busy or (item and item.status == "executing")},
            {kind = "button", id = "toggle", size = 10, text = model.toggle_label(item), disabled = none or busy},
            {kind = "button", id = "delete", size = 10, text = "Delete", disabled = none or busy},
            {kind = "button", id = "props", size = 14, text = "Properties…", disabled = none or busy},
            {kind = "button", id = "refresh", size = 11, text = "Refresh", disabled = busy},
            {kind = "button", id = "close", size = 9, text = "Close", default = true},
        }},
    }}
end

-- The delete question. "No" is the default: Enter on a sheet that removes a
-- schedule must not remove it. While the delete runs, the same sheet comes
-- from ui.message with "Yes" disabled, so a second press cannot start a
-- second delete.
local function confirm_view(state: any): any
    local item = selected(state)
    if not item then return ui.message({title = "The task is gone.", image = "clock", icon = "◷", ok = "no"}) end
    local sheet: any = {
        title = "Delete the scheduled task \"" .. model.name(item) .. "\"?",
        lines = model.confirm_lines(item, state.owners),
        image = "clock", icon = "◷",
    }
    if state.pending ~= nil then
        sheet.buttons = {
            {id = "yes", text = "Yes", disabled = true},
            {id = "no", text = "No", default = true},
        }
        return ui.message(sheet)
    end
    sheet.yes, sheet.no, sheet.default = "yes", "no", "no"
    return ui.confirm(sheet)
end

local function status_text(state: any): string
    if state.status and state.status ~= "" then return tostring(state.status) end
    if state.failure then return tostring(state.failure) end
    return model.summary(state.tasks, state.total)
end

function definition.view(state: any, context: any): any
    local body: any
    if state.mode == "props" and state.detail then
        local detail: any = state.detail
        body = model.props_tree(detail, state.owners[tostring(detail.task_implementation_id)],
            tonumber(state.offset) or 0, state.pending ~= nil)
    elseif state.mode == "confirm" then body = confirm_view(state)
    else body = list_view(state) end
    return {kind = "column", gap = 0, children = {
        body,
        {kind = "statusbar", size = 1, fields = {{text = " " .. status_text(state)}}},
    }}
end

-- ─── update ─────────────────────────────────────────────────────────────

local function open_props(state: any)
    local item = selected(state)
    if not item then return end
    local detail, err = read_detail(item.id)
    if not detail then
        state.status = err
        return
    end
    state.detail, state.mode, state.status = detail, "props", nil
end

-- The task the actions work on: the one on the sheet in Properties, the
-- selected row in the list.
local function target(state: any): any
    if state.mode == "props" and state.detail then return model.project(state.detail) end
    return selected(state)
end

local function after_change(state: any)
    load_tasks(state)
    if state.mode == "props" and state.detail then
        local detail = read_detail(state.detail.task_id)
        if detail then state.detail = detail else back_to_list(state) end
    end
end

-- What the pending request does once its "…running" frame is on screen.
local function run_pending(state: any): boolean
    local op: any = state.pending
    state.pending = nil
    if not op then return false end
    if op.kind == "run" then
        state.status = run_now(op.item)
        after_change(state)
    elseif op.kind == "delete" then
        local ok, message = remove(op.item)
        state.status = message
        if ok then state.selected_id = nil end
        back_to_list(state)
        load_tasks(state)
    end
    return true
end

local function activate(state: any, id: any, context: any)
    if id == "close" then
        context.close()
    elseif id == "refresh" then
        state.status = nil
        load_tasks(state)
    elseif id == "props" then
        open_props(state)
    elseif id == "run" or id == "props_run" then
        local item = target(state)
        if item then
            defer(state, context, {kind = "run", item = item, label = "Running " .. model.name(item) .. "…"})
        end
    elseif id == "toggle" or id == "props_toggle" then
        local item = target(state)
        if item then
            local _, message = toggle(item)
            state.status = message
            after_change(state)
        end
    elseif id == "delete" then
        if selected(state) then state.mode, state.status = "confirm", nil end
    elseif id == "yes" then
        local item = selected(state)
        if item then
            defer(state, context, {kind = "delete", item = item, label = "Deleting " .. model.name(item) .. "…"})
        end
    elseif id == "no" or id == "props_close" then
        back_to_list(state)
        state.status = nil
    end
end

function definition.update(state: any, action: any, context: any)
    if action.type == "timer" then
        if action.tag == "pending" then return run_pending(state) end
        return false
    end
    if action.type == "tick" then
        -- The list moves on its own (Next Run, Status); a sheet stays still.
        if state.mode ~= "list" or state.pending ~= nil then return false end
        load_tasks(state)
        return true
    end
    if action.type == "resize" then return false end

    if action.type == "key" then
        if action.key_type == "esc" and state.mode ~= "list" then
            if state.pending ~= nil then return false end
            back_to_list(state)
            state.status = nil
            return true
        end
        if (action.key_type == "f5" or action.key == "F5") and state.mode == "list" then
            state.status = nil
            load_tasks(state)
            return true
        end
        return false
    end

    if action.id == "tasks" and (action.type == "select" or action.type == "activate") then
        local value: any = action.value
        local id = type(value) == "table" and value.id or nil
        local again = id ~= nil and id == state.selected_id and action.pointer == true
        state.selected_id = id or state.selected_id
        if action.type == "activate" or again then open_props(state) end
        return true
    end

    if action.type ~= "activate" then return false end
    activate(state, action.id, context)
    return true
end

definition.interval = "30s"
definition.close_on_escape = true

return {main = app.main(definition), definition = definition}
