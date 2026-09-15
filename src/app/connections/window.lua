-- Connections — the platform's connections in the Windows 95 shell.
--
-- A window on the shell SDK. IO lives here and does what the HTTP handlers of
-- kickside/connection do, without HTTP; the model (app.connections:model)
-- translates shapes and is tested on its own.
--
-- Sheets instead of child windows: the list, the provider choice, the form and
-- the delete confirmation are modes of one window. Esc closes a sheet first,
-- then the window (close_on_escape: update returns false only in list mode).
--
-- A request that can take seconds (test_connection, create with a test,
-- delete) is deferred by one timer tick: the status bar says what is running
-- in the frame BEFORE update blocks on the request, instead of a frozen window.
local app = require("app")
local ui = require("ui")
local model = require("model")
local component = require("component")
local conn_types = require("conn_types")
local create_policy = require("create_policy")
local contract = require("contract")
local registry = require("registry")
local security = require("security")
local time = require("time")

local definition: any = {title = "Connections"}

local PAGE_LIMIT = 100  -- list_connections.lua's MAX_LIMIT

local COLUMNS = {
    {title = "Name", weight = 3},
    {title = "Provider", weight = 2},
    {title = "State", width = 14},
}
local PROVIDER_COLUMNS = {
    {title = "Name", weight = 2},
    {title = "Group", width = 12},
    {title = "Description", weight = 5},
}

-- ─── IO ─────────────────────────────────────────────────────────────────

-- The connections contract, opened the way list_connections.lua opens it:
-- with the caller's actor and scope when the process has them.
local function connections_contract(): (any, string?)
    local def, derr = contract.get(conn_types.CONNECTIONS_CONTRACT)
    if derr or not def then return nil, model.explain("connections contract", derr) end
    local opener: any = def
    local actor, scope = security.actor(), security.scope()
    if actor and scope then opener = opener:with_actor(actor):with_scope(scope) end
    local instance, oerr = opener:open()
    if oerr or not instance then return nil, model.explain("connections", oerr) end
    return instance, nil
end

local function load_connections(state: any)
    state.failure, state.more = nil, false
    local instance, err = connections_contract()
    if not instance then
        state.connections, state.failure = {}, err
        return
    end
    local page, lerr = instance:list({pagination = {limit = PAGE_LIMIT, offset = 0}, include_page = true})
    if lerr then
        state.connections, state.failure = {}, model.explain("list", lerr)
        return
    end
    if type(page) ~= "table" or type(page.connections) ~= "table" then
        state.connections, state.failure = {}, "list: the connections contract returned a non-conforming page"
        return
    end
    local rows, problem = model.connections(page.connections, time.now():unix())
    state.connections, state.failure, state.more = rows, problem, page.has_more == true
    if state.selected_id == nil or model.find(rows, state.selected_id) == nil then
        state.selected_id = rows[1] and rows[1].id or nil
    end
end

local function load_providers(state: any)
    state.provider_failure = nil
    local entries, err = registry.find({[".kind"] = "contract.binding", ["*meta.provider"] = ""})
    if err then
        state.providers, state.provider_failure = {}, model.explain("providers", err)
        return
    end
    state.providers = model.providers(entries or {})
    if state.provider_id == nil or model.find_provider(state.providers, state.provider_id) == nil then
        state.provider_id = state.providers[1] and state.providers[1].impl_id or nil
    end
end

-- test_one(id) — the live check create_connection.lua runs after creating.
-- The result is assigned before returning: a bare `return <yield-call>(...)`
-- at the end of a function is the go-lua trap that silently skips the call.
local function test_one(id: any): (boolean, string)
    local instance, oerr = component.open(tostring(id), component.ACCESS.WRITE, conn_types.CONNECTION_CONTRACT)
    if oerr or not instance then return false, model.explain("open", oerr) end
    local result, terr = (instance :: any):test_connection({})
    local failed = terr ~= nil or (type(result) == "table" and result.success == false)
    if failed then
        return false, "connection test failed: " .. tostring(terr or (type(result) == "table" and result.error) or "unknown")
    end
    return true, "connection test passed"
end

-- create(form, validate) — create_connection.lua step by step: the binding is
-- read again (it may be gone since the provider list was drawn), the
-- private_context is validated by create_policy, the component is registered,
-- and with `validate` a failed live test deletes it again.
local function create(form: any, validate: boolean): (any, string)
    local provider: any = form.provider
    local binding, berr = registry.get(tostring(provider.impl_id))
    if berr or not create_policy.is_connection_binding(binding, conn_types.CONNECTION_CONTRACT) then
        return nil, "the provider " .. provider.title .. " is no longer a connection binding: " .. tostring(berr or provider.impl_id)
    end
    local problem = model.check(provider, form, binding)
    if problem then return nil, problem end

    local service, serr = component.get_service()
    if serr or not service then return nil, model.explain("component service", serr) end
    local name = model.name_of(form)
    local meta: any = {title = name, comment = form.description, class = conn_types.CONNECTION_CLASS}
    local binding_meta: any = (binding :: any).meta
    if type(binding_meta) == "table" and binding_meta.provider then meta.provider = binding_meta.provider end

    local result, rerr = service:register({
        impl_id = provider.impl_id,
        private_context = model.private_context(provider, form),
        meta = meta,
    })
    if not result or not result.success then
        return nil, model.explain("create", rerr or (result and result.error) or "creation failed")
    end
    local id = result.component_id
    if validate then
        local ok, why = test_one(id)
        if not ok then
            local _, derr = service:delete({component_id = id})
            if derr then return nil, why .. "; the half-created connection was not removed: " .. tostring(derr) end
            return nil, why .. " — nothing was saved"
        end
        return id, "connected: " .. name
    end
    return id, "saved: " .. name .. " (not tested)"
end

-- rename(id, name) — update_connection.lua: write access first, then the
-- title through component.set_meta. The title is the only field it accepts.
local function rename(id: any, name: string): (boolean, string)
    local _, aerr = component.validate_access(tostring(id), component.ACCESS.WRITE)
    if aerr then return false, model.explain("rename", aerr) end
    local ok, err = component.set_meta(tostring(id), {title = name})
    if not ok then return false, model.explain("rename", err or "update failed") end
    return true, "renamed to " .. name
end

-- remove(id) — delete_connection.lua: through the connections contract.
local function remove(id: any): (boolean, string)
    local instance, err = connections_contract()
    if not instance then return false, tostring(err) end
    local result, derr = instance:delete({component_id = tostring(id)})
    if derr or not result then return false, model.explain("delete", derr or "delete failed") end
    return true, "deleted"
end

-- ─── state ──────────────────────────────────────────────────────────────

function definition.init(args: any, context: any): any
    local state: any = {mode = "list", connections = {}, providers = {}, selected_id = nil,
        provider_id = nil, form = nil, status = nil, failure = nil, provider_failure = nil,
        more = false, pending = nil}
    load_connections(state)
    return state
end

local function selected(state: any): any
    return model.find(state.connections, state.selected_id)
end

local function back_to_list(state: any)
    state.mode, state.form = "list", nil
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
    if #state.connections == 0 then
        body = {kind = "label", text = state.failure and "The connections could not be read." or model.EMPTY,
            alert = state.failure ~= nil}
    else
        body = {kind = "table", id = "connections", columns = COLUMNS,
            rows = model.table_rows(state.connections), selected = state.selected_id}
    end
    return {kind = "column", padding = 1, padding_bottom = 0, gap = 0, children = {
        {kind = "label", size = 1, text = "Connections available to you:"},
        body,
        {kind = "label", size = 1, text = model.detail(item)},
        {kind = "row", size = 2, gap = 1, align = "right", children = {
            {kind = "button", id = "new", size = 8, text = "New…", disabled = busy},
            {kind = "button", id = "props", size = 14, text = "Properties…", disabled = none or busy},
            {kind = "button", id = "test", size = 8, text = "Test", disabled = none or busy},
            {kind = "button", id = "delete", size = 10, text = "Delete", disabled = none or busy},
            {kind = "button", id = "refresh", size = 11, text = "Refresh", disabled = busy},
            {kind = "button", id = "close", size = 9, text = "Close", default = true},
        }},
    }}
end

local function providers_view(state: any): any
    local chosen = model.find_provider(state.providers, state.provider_id)
    local body: any
    if #state.providers == 0 then
        body = {kind = "label", text = state.provider_failure and "The providers could not be read." or model.NO_PROVIDERS,
            alert = state.provider_failure ~= nil}
    else
        body = {kind = "table", id = "providers", columns = PROVIDER_COLUMNS,
            rows = model.provider_rows(state.providers), selected = state.provider_id}
    end
    return {kind = "column", padding = 1, padding_bottom = 0, gap = 0, children = {
        {kind = "label", size = 1, text = "Choose the kind of connection:"},
        body,
        {kind = "label", size = 1, text = chosen and chosen.description or ""},
        {kind = "row", size = 2, gap = 1, align = "right", children = {
            {kind = "button", id = "provider_ok", size = 10, text = "OK", default = true, disabled = chosen == nil},
            {kind = "button", id = "cancel", size = 10, text = "Cancel"},
        }},
    }}
end

-- The delete question. "No" is the default: Enter on a sheet that removes a
-- connection must not remove it. While the delete runs, the same sheet comes
-- from ui.message with "Yes" disabled, so a second press cannot start a
-- second delete.
local function confirm_view(state: any): any
    local item = selected(state)
    local name = item and (item.name ~= "" and item.name or "(unnamed)") or ""
    local sheet: any = {
        title = "Delete the connection \"" .. name .. "\"?",
        lines = {"Agents and flows that use it lose access.", "This cannot be undone."},
        image = "dialup", icon = "⇄",
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
    if state.mode == "providers" and state.provider_failure then return tostring(state.provider_failure) end
    if state.failure then return tostring(state.failure) end
    if state.mode == "providers" then return tostring(#state.providers) .. " providers" end
    return model.summary(state.connections, state.more)
end

function definition.view(state: any, context: any): any
    local body: any
    if state.mode == "providers" then body = providers_view(state)
    elseif state.mode == "form" then body = model.form_tree(state.form, state.pending ~= nil)
    elseif state.mode == "confirm" then body = confirm_view(state)
    else body = list_view(state) end
    return {kind = "column", gap = 0, children = {
        body,
        {kind = "statusbar", size = 1, fields = {{text = " " .. status_text(state)}}},
    }}
end

-- ─── update ─────────────────────────────────────────────────────────────

local function open_form(state: any)
    local provider = model.find_provider(state.providers, state.provider_id)
    if not provider then return end
    state.form = model.new_form(provider)
    state.mode = "form"
    state.status = nil
end

local function open_props(state: any)
    local item = selected(state)
    if not item then return end
    state.form = model.props_form(item)
    state.mode = "form"
    state.status = nil
end

-- What the pending request does once its "…running" frame is on screen.
local function run_pending(state: any): boolean
    local op: any = state.pending
    state.pending = nil
    if not op then return false end
    if op.kind == "test" then
        local _, message = test_one(op.id)
        state.status = op.name .. ": " .. message
    elseif op.kind == "delete" then
        local ok, message = remove(op.id)
        state.status = ok and (op.name .. " deleted") or message
        if ok then state.selected_id = nil end
        back_to_list(state)
        load_connections(state)
    elseif op.kind == "create" then
        local id, message = create(op.form, op.validate == true)
        state.status = message
        if id then
            state.selected_id = id
            back_to_list(state)
            load_connections(state)
        end
    end
    return true
end

local function submit(state: any, context: any, validate: boolean)
    local form: any = state.form
    local problem = model.check(form.provider, form)
    if problem then
        state.status = problem
        return
    end
    if validate then
        defer(state, context, {kind = "create", form = form, validate = true,
            label = "Connecting " .. model.name_of(form) .. "…"})
    else
        local id, message = create(form, false)
        state.status = message
        if id then
            state.selected_id = id
            back_to_list(state)
            load_connections(state)
        end
    end
end

local function save_props(state: any)
    local form: any = state.form
    local name = model.name_of(form)
    if name == "" then
        state.status = "Name is required"
        return
    end
    if name == form.name_before then
        back_to_list(state)
        return
    end
    local ok, message = rename(form.id, name)
    state.status = message
    if ok then
        back_to_list(state)
        load_connections(state)
    end
end

local function activate(state: any, id: any, context: any)
    if id == "close" then
        context.close()
    elseif id == "refresh" then
        state.status = nil
        load_connections(state)
    elseif id == "new" then
        load_providers(state)
        state.mode, state.status = "providers", nil
    elseif id == "props" then
        open_props(state)
        if state.form then state.form.name_before = state.form.name end
    elseif id == "test" or id == "props_test" then
        local item = selected(state)
        local target = id == "props_test" and state.form and state.form.id or (item and item.id)
        if target then
            local name = item and item.name or ""
            defer(state, context, {kind = "test", id = target, name = name ~= "" and name or target,
                label = "Testing " .. (name ~= "" and name or target) .. "…"})
        end
    elseif id == "delete" then
        if selected(state) then state.mode, state.status = "confirm", nil end
    elseif id == "yes" then
        local item = selected(state)
        if item then
            defer(state, context, {kind = "delete", id = item.id, name = item.name ~= "" and item.name or item.id,
                label = "Deleting " .. (item.name ~= "" and item.name or item.id) .. "…"})
        end
    elseif id == "no" or id == "cancel" then
        back_to_list(state)
        state.status = nil
    elseif id == "provider_ok" then
        open_form(state)
    elseif id == "submit" then
        submit(state, context, true)
    elseif id == "save" then
        if state.form and state.form.mode == "props" then save_props(state) else submit(state, context, false) end
    end
end

function definition.update(state: any, action: any, context: any)
    if action.type == "timer" then
        if action.tag == "pending" then return run_pending(state) end
        return false
    end
    if action.type == "resize" or action.type == "tick" then return false end

    if action.type == "key" then
        if action.key_type == "esc" and state.mode ~= "list" then
            back_to_list(state)
            state.status = nil
            return true
        end
        if (action.key_type == "f5" or action.key == "F5") and state.mode == "list" then
            state.status = nil
            load_connections(state)
            return true
        end
        return false
    end

    if action.id == "connections" and (action.type == "select" or action.type == "activate") then
        local value: any = action.value
        local id = type(value) == "table" and value.id or nil
        local again = id ~= nil and id == state.selected_id and action.pointer == true
        state.selected_id = id or state.selected_id
        if action.type == "activate" or again then
            open_props(state)
            if state.form then state.form.name_before = state.form.name end
        end
        return true
    end
    if action.id == "providers" and (action.type == "select" or action.type == "activate") then
        local value: any = action.value
        local id = type(value) == "table" and value.id or nil
        local again = id ~= nil and id == state.provider_id and action.pointer == true
        state.provider_id = id or state.provider_id
        if action.type == "activate" or again then open_form(state) end
        return true
    end

    if action.type == "change" and state.form then
        local form: any = state.form
        if action.id == "f_name" then
            form.name = tostring(action.value or "")
        elseif action.id == "f_description" then
            form.description = tostring(action.value or "")
        else
            local key = model.key_of(action.id)
            if key then form.values[key] = action.value end
        end
        return true
    end

    if action.type ~= "activate" then return false end
    -- Enter in a form field does what the form's default button does.
    if state.mode == "form" and (action.id == "f_name" or action.id == "f_description" or model.key_of(action.id)) then
        if state.form and state.form.mode == "props" then save_props(state) else submit(state, context, true) end
        return true
    end
    activate(state, action.id, context)
    return true
end

definition.close_on_escape = true

return {main = app.main(definition), definition = definition}
