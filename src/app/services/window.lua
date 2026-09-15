-- Services — the runtime's supervised services in the Windows 95 shell.
--
-- A window on the shell SDK. IO lives here: the supervisor's states, each
-- service's registry entry, the process hosts and the node's name. The model
-- (app.services:model) joins and words them and is tested on its own.
--
-- The list follows the supervisor every five seconds; an entry is read again
-- only on Refresh or F5, because a declaration changes with a registry update,
-- not with a status. system.* returns nil and an error rather than throwing,
-- so there is no pcall here (and under go-lua one would tear the upvalues of
-- the frames below it).
local app = require("app")
local model = require("model")
local facts = require("facts")
local system = require("system")
local registry = require("registry")
local time = require("time")

local definition: any = {title = "Services", interval = "5s"}

-- ─── IO ─────────────────────────────────────────────────────────────────

-- read_entries(state, states) — registry.get for every service not read yet.
-- A refusal is kept as the reason, so an unreadable entry is not asked for
-- again every five seconds.
local function read_entries(state: any, states: any)
    for _, raw in ipairs(states) do
        local record: any = raw
        local id = type(record) == "table" and tostring(record.id or "") or ""
        if id ~= "" and state.entries[id] == nil then
            local entry, err = registry.get(id)
            if err or not entry then
                state.entries[id] = {problem = model.explain("registry", err or ("no entry " .. id))}
            else
                state.entries[id] = {entry = entry}
            end
        end
    end
end

-- load(state, fresh) — one read of everything the list shows; `fresh` forgets
-- the entries read before (Refresh, F5).
local function load(state: any, fresh: boolean)
    if fresh then state.entries = {} end
    state.failure, state.entry_problem = nil, nil
    local states, err = system.supervisor.states()
    if err or type(states) ~= "table" then
        state.services, state.failure = {}, model.explain("services", err)
    else
        read_entries(state, states)
        state.services, state.entry_problem = model.services(states, state.entries)
    end
    local hosts, herr = system.hosts.list()
    if herr or type(hosts) ~= "table" then
        state.host_count, state.hosts_problem = nil, model.explain("process hosts", herr)
    else
        state.host_count, state.hosts_problem = #hosts, nil
    end
    if state.selected_id == nil or model.find(state.services, state.selected_id) == nil then
        state.selected_id = state.services[1] and state.services[1].id or nil
    end
end

-- ─── state ──────────────────────────────────────────────────────────────

function definition.init(args: any, context: any): any
    local state: any = {mode = "list", services = {}, entries = {}, selected_id = nil, failure = nil,
        entry_problem = nil, host_count = nil, hosts_problem = nil, status = nil}
    state.heading = model.heading(facts.read({"hostname", "node_id"}))
    load(state, true)
    return state
end

-- ─── view ───────────────────────────────────────────────────────────────

function definition.view(state: any, context: any): any
    local now = time.now():unix_nano()
    local item = model.find(state.services, state.selected_id)
    local body: any
    if state.mode == "props" and item then
        body = model.properties_tree(item, now)
    else
        body = model.list_tree(state, now)
    end
    return {kind = "column", gap = 0, children = {
        body,
        {kind = "statusbar", size = 1, fields = {{text = " " .. model.status_line(state)}}},
    }}
end

-- ─── update ─────────────────────────────────────────────────────────────

local function open_props(state: any)
    if model.find(state.services, state.selected_id) then
        state.mode, state.status = "props", nil
    end
end

local function refresh(state: any)
    state.status = nil
    load(state, true)
end

function definition.update(state: any, action: any, context: any)
    if action.type == "tick" then
        -- A sheet stays as it was opened; the list follows the supervisor.
        if state.mode ~= "list" then return false end
        load(state, false)
        return true
    end
    if action.type == "resize" or action.type == "timer" then return false end

    if action.type == "key" then
        if action.key_type == "esc" and state.mode ~= "list" then
            state.mode = "list"
            return true
        end
        if (action.key_type == "f5" or action.key == "F5") and state.mode == "list" then
            refresh(state)
            return true
        end
        return false
    end

    if action.id == "services" and (action.type == "select" or action.type == "activate") then
        local value: any = action.value
        local id = type(value) == "table" and value.id or nil
        local again = id ~= nil and id == state.selected_id and action.pointer == true
        state.selected_id = id or state.selected_id
        if action.type == "activate" or again then open_props(state) end
        return true
    end

    if action.type ~= "activate" then return false end
    local id = action.id
    if id == "close" then
        context.close()
    elseif id == "refresh" then
        refresh(state)
    elseif id == "props" then
        open_props(state)
    elseif id == "props_ok" then
        state.mode = "list"
    elseif id == "start" or id == "stop" or id == "restart" then
        -- The buttons are disabled; anything that still sends the action gets
        -- the reason in the status bar, not silence.
        state.status = model.NO_CONTROL
    end
    return true
end

definition.close_on_escape = true

return {main = app.main(definition), definition = definition}
