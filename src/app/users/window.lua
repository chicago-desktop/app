-- Users — the application's accounts in the Windows 95 shell.
--
-- A window on the shell SDK doing what kickside/users' HTTP handlers do,
-- without HTTP: the same gates (security.can("access", <handler endpoint>),
-- checked again right before every write), the same libraries (user_repo,
-- user_groups_repo, admin_repo, group_validation, the security_scopes
-- contract, the lifecycle report for deletion). The model (app.users:model)
-- decides what may be sent and is tested on its own.
--
-- One read the handlers do not have: the newest session token's expiry per
-- account (app.users:sessions — the payload's actor_id and the expiry column
-- only; the token column is never selected).
--
-- Sheets instead of child windows, like Connections: the list, New…,
-- Properties…, Groups… and the delete question are modes of one window.
-- Writes are deferred by one timer tick so the status bar says what runs
-- before the password hashing blocks the loop.
local app = require("app")
local ui = require("ui")
local model = require("model")
local sessions = require("sessions")
local consts = require("consts")
local user_repo = require("user_repo")
local user_groups_repo = require("user_groups_repo")
local admin_repo = require("admin_repo")
local group_validation = require("group_validation")
local lifecycle_report = require("lifecycle_report")
local contract = require("contract")
local security = require("security")
local time = require("time")

local definition: any = {title = "Users"}

local SCOPES_CONTRACT = "kickside.contract:security_scopes"

-- ─── IO ─────────────────────────────────────────────────────────────────

local function gate(op: string): boolean
    if not security.actor() then return false end
    return security.can("access", model.GATES[op]) == true
end

local function read_access(): any
    local access: {[string]: boolean} = {}
    for op, _ in pairs(model.GATES) do access[op] = gate(op) end
    return access
end

-- The assignable catalog, opened the way list_assignable_scopes.lua opens it:
-- with the caller's actor and scope, internal scopes left out.
local function read_scopes(state: any)
    state.scopes, state.scope_problem = {}, nil
    local def, derr = contract.get(SCOPES_CONTRACT)
    if derr or not def then
        state.scope_problem = model.explain("groups catalog", derr or "unavailable")
        return
    end
    local opener: any = def
    local actor, scope = security.actor(), security.scope()
    if actor and scope then opener = opener:with_actor(actor):with_scope(scope) end
    local instance, oerr = opener:open()
    if oerr or not instance then
        state.scope_problem = model.explain("groups catalog", oerr or "open failed")
        return
    end
    local result, lerr = instance:list({include_internal = false})
    if lerr then
        state.scope_problem = model.explain("groups catalog", lerr)
        return
    end
    state.scopes = type(result) == "table" and type(result.scopes) == "table" and result.scopes or {}
end

local function read_tokens(state: any): any
    local map, err = sessions.read(consts.get_db_resource())
    state.token_problem = err ~= nil and model.explain("tokens", err) or nil
    return map
end

-- The administrator group and how many accounts hold it — what the
-- last-administrator rule counts.
local function read_admins(state: any)
    local config: any = consts.get_config()
    state.ctx.admin_group = config.admin_group_id
    state.default_group = config.default_group_id
    state.ctx.admin_count, state.ctx.admin_problem = nil, nil
    if type(config.admin_group_id) ~= "string" or config.admin_group_id == "" then return end
    local result, err = user_groups_repo.get_group_users(config.admin_group_id, {limit = model.PAGE})
    if err or type(result) ~= "table" then
        state.ctx.admin_problem = tostring(err or "no answer")
        return
    end
    state.ctx.admin_count = #(result.users or {})
end

-- load(state) — list_users.lua's process, then the catalog, the
-- administrators and the tokens. A groups lookup error empties the list, as
-- the handler answers 500: "no groups" must not be read into an error.
local function load(state: any)
    state.failure = nil
    if not state.access.list then
        state.users, state.failure = {}, model.not_granted("list")
        return
    end
    local rows, err = user_repo.list({limit = model.PAGE, offset = 0})
    if err or type(rows) ~= "table" then
        state.users, state.failure = {}, model.explain("users", err)
        return
    end
    for _, raw in ipairs(rows) do
        local row: any = raw
        local groups, gerr = user_groups_repo.get_user_groups(row.user_id)
        if gerr then
            state.users, state.failure = {}, model.explain("groups of " .. tostring(row.email), gerr)
            return
        end
        row.security_groups = groups and groups.groups or {}
    end
    read_scopes(state)
    read_admins(state)
    state.users = model.users(rows, read_tokens(state))
    state.more = #rows >= model.PAGE
    if state.selected_id == nil or model.find(state.users, state.selected_id) == nil then
        state.selected_id = state.users[1] and state.users[1].id or nil
    end
end

local function create(state: any, form: any): (any, string)
    if not gate("create") then return nil, model.not_granted("create") end
    local data, groups = model.create_payload(form, state.scopes)
    local valid, verr = group_validation.validate(groups)
    if not valid then return nil, "groups: " .. tostring(verr) end
    local user, err = admin_repo.create(data, groups)
    if err or not user then return nil, model.explain("create", err) end
    return user.user_id, "created " .. data.email
end

local function update(form: any, data: any): (boolean, string)
    if not gate("update") then return false, model.not_granted("update") end
    local result, err = admin_repo.update(form.id, data, nil)
    if err or not result then return false, model.explain("save", err) end
    return true, "saved " .. form.email
end

local function save_groups(form: any, groups: any): (boolean, string)
    if not gate("set_groups") then return false, model.not_granted("set_groups") end
    local valid, verr = group_validation.validate(groups)
    if not valid then return false, "groups: " .. tostring(verr) end
    local _, err = user_groups_repo.set_user_groups(form.id, groups)
    if err then return false, model.explain("groups", err) end
    return true, "groups saved for " .. form.email
end

-- remove(state, item) — delete_user.lua: the durable principal.deleted report,
-- after the refusals are checked again on a fresh count. The account goes
-- when the lifecycle reaper removes it, not at once.
local function remove(state: any, item: any): (boolean, string)
    if not gate("delete") then return false, model.not_granted("delete") end
    read_admins(state)
    local refusal = model.delete_refusal(item, state.ctx)
    if refusal then return false, "Delete: " .. refusal end
    local user, gerr = user_repo.get(item.id)
    if gerr or not user then return false, model.explain("delete", gerr) end
    local reported, rerr = lifecycle_report.principal_deleted(tostring(user.user_id))
    if not reported then return false, "delete: the deletion report failed: " .. tostring(rerr) end
    return true, "deletion of " .. item.email .. " queued: the account goes when the lifecycle reaper removes it"
end

-- ─── state ──────────────────────────────────────────────────────────────

function definition.init(args: any, context: any): any
    local actor = security.actor()
    local state: any = {mode = "list", users = {}, scopes = {}, selected_id = nil, failure = nil,
        status = nil, more = false, form = nil, pending = nil, token_problem = nil,
        scope_problem = nil, default_group = nil, access = read_access(),
        ctx = {self_id = actor and tostring(actor:id()) or nil}}
    load(state)
    return state
end

local function selected(state: any): any
    return model.find(state.users, state.selected_id)
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

local function confirm_view(state: any): any
    local item = selected(state)
    local email = item and item.email or ""
    local sheet: any = {
        title = "Delete the account " .. email .. "?",
        lines = {"The account, its groups and its data are removed by the lifecycle reaper.",
            "This cannot be undone."},
        image = "user", icon = "☺",
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

function definition.view(state: any, context: any): any
    local now = time.now():unix()
    local busy = state.pending ~= nil
    local body: any
    if state.mode == "new" then
        body = model.new_tree(state.form, state.scopes, busy)
    elseif state.mode == "props" then
        body = model.props_tree(state.form, busy)
    elseif state.mode == "groups" then
        body = model.groups_tree(state.form, selected(state), state.scopes, state.access.set_groups, busy)
    elseif state.mode == "confirm" then
        body = confirm_view(state)
    else
        body = model.list_tree(state, now)
    end
    return {kind = "column", gap = 0, children = {
        body,
        {kind = "statusbar", size = 1, fields = {{text = " " .. model.status_line(state)}}},
    }}
end

-- ─── update ─────────────────────────────────────────────────────────────

local function run_pending(state: any): boolean
    local op: any = state.pending
    state.pending = nil
    if not op then return false end
    local ok, message
    if op.kind == "create" then
        local id
        id, message = create(state, op.form)
        ok = id ~= nil
        if ok then state.selected_id = id end
    elseif op.kind == "update" then
        ok, message = update(op.form, op.data)
    elseif op.kind == "groups" then
        ok, message = save_groups(op.form, op.groups)
    elseif op.kind == "delete" then
        ok, message = remove(state, op.item)
    end
    state.status = message
    if ok then
        back_to_list(state)
        load(state)
    elseif op.kind == "delete" then
        back_to_list(state)
    end
    return true
end

local function save(state: any, context: any)
    local form: any = state.form
    local item = selected(state)
    if state.mode == "new" then
        local problem = model.check_new(form)
        if problem then state.status = problem return end
        defer(state, context, {kind = "create", form = form, label = "Creating " .. form.email .. "…"})
    elseif state.mode == "props" and item then
        local data, problem = model.props_update(form, item, state.ctx)
        if problem then state.status = problem return end
        if not data then
            state.status = "nothing changed"
            back_to_list(state)
            return
        end
        defer(state, context, {kind = "update", form = form, data = data, label = "Saving " .. form.email .. "…"})
    elseif state.mode == "groups" and item then
        local groups, problem = model.groups_save(form, item, state.scopes, state.ctx)
        if problem then state.status = problem return end
        if not groups then
            state.status = "nothing changed"
            back_to_list(state)
            return
        end
        defer(state, context, {kind = "groups", form = form, groups = groups,
            label = "Saving the groups of " .. form.email .. "…"})
    end
end

local function refresh(state: any)
    state.status = nil
    state.access = read_access()
    load(state)
end

local function activate(state: any, id: any, context: any)
    local item = selected(state)
    if id == "close" then
        context.close()
    elseif id == "refresh" then
        refresh(state)
    elseif id == "new" then
        if not state.access.create then state.status = model.not_granted("create") return end
        state.form, state.mode, state.status = model.new_form(state.default_group), "new", nil
    elseif id == "props" then
        if not state.access.update then state.status = model.not_granted("update") return end
        if item then state.form, state.mode, state.status = model.props_form(item), "props", nil end
    elseif id == "groups" then
        if not state.access.get_groups then state.status = model.not_granted("get_groups") return end
        if item then state.form, state.mode, state.status = model.groups_form(item), "groups", nil end
    elseif id == "delete" then
        if not state.access.delete then state.status = model.not_granted("delete") return end
        local refusal = item and model.delete_refusal(item, state.ctx) or nil
        if refusal then state.status = "Delete: " .. refusal return end
        if item then state.mode, state.status = "confirm", nil end
    elseif id == "yes" then
        if item then
            defer(state, context, {kind = "delete", item = item, label = "Deleting " .. item.email .. "…"})
        end
    elseif id == "no" or id == "cancel" then
        back_to_list(state)
        state.status = nil
    elseif id == "save" then
        save(state, context)
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
            refresh(state)
            return true
        end
        return false
    end

    if action.id == "users" and (action.type == "select" or action.type == "activate") then
        local value: any = action.value
        local id = type(value) == "table" and value.id or nil
        local again = id ~= nil and id == state.selected_id and action.pointer == true
        state.selected_id = id or state.selected_id
        if (action.type == "activate" or again) then activate(state, "props", context) end
        return true
    end

    if action.type == "change" and state.form then
        local form: any = state.form
        local group = model.group_of(action.id)
        if group then
            form.chosen[group] = action.value == true or nil
        elseif action.id == "f_email" then
            form.email = tostring(action.value or "")
        elseif action.id == "f_name" then
            form.name = tostring(action.value or "")
        elseif action.id == "f_password" then
            form.password = tostring(action.value or "")
        elseif action.id == "f_confirm" then
            form.confirm = tostring(action.value or "")
        elseif action.id == "f_status" then
            form.status = tostring(action.value or form.status)
        end
        return true
    end

    if action.type ~= "activate" then return false end
    -- Enter in a form field does what the form's default button does.
    if state.form and type(action.id) == "string" and action.id:sub(1, 2) == "f_" then
        save(state, context)
        return true
    end
    activate(state, action.id, context)
    return true
end

definition.close_on_escape = true

return {main = app.main(definition), definition = definition}
