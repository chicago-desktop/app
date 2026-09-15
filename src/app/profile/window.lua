-- User Profile — an account's properties in the Chicago shell.
--
-- Opened from the Start menu's user row with {user_id = <id>} (the shell
-- names this entry through CHICAGO_PROFILE_ENTRY); without a
-- target it is the signed-in account's. A window on the shell SDK doing what
-- GET/PUT /user/me and GET/PUT /profile do, without HTTP: user_repo for the
-- account, user_groups_repo for its groups, the kickside.users.profile:profile
-- contract (opened with the actor, as the handlers open it) for the declared
-- fields, app.users:sessions for the session. Writes check the router's gates
-- first — `access` on the endpoint ids — and always target the actor, as the
-- handlers do. The model (app.profile:model) decides what may be sent.
local app = require("app")
local model = require("model")
local sessions = require("sessions")
local consts = require("consts")
local user_repo = require("user_repo")
local user_groups_repo = require("user_groups_repo")
local contract = require("contract")
local security = require("security")
local time = require("time")
local desktop = require("desktop")

local definition: any = {title = "User Profile"}

local PROFILE_CONTRACT = "kickside.users.profile:profile"

-- ─── IO ─────────────────────────────────────────────────────────────────

local function gate(op: string): boolean
    if not security.actor() then return false end
    return security.can("access", model.GATES[op]) == true
end

local function profile_instance(): (any, string?)
    local def, derr = contract.get(PROFILE_CONTRACT)
    if derr or not def then return nil, model.explain("profile", derr) end
    local opener: any = def
    local actor, scope = security.actor(), security.scope()
    if actor and scope then opener = opener:with_actor(actor):with_scope(scope) end
    local instance, oerr = opener:open()
    if oerr or not instance then return nil, model.explain("profile", oerr) end
    return instance, nil
end

local function answer_error(result: any, err: any): any
    if err then return err end
    if type(result) == "table" and result.error then return result.error end
    return "no answer"
end

-- The fields: list() for the actor's own; for another account list() tells
-- which declarations are public, and get_namespace answers their values.
local function read_fields(state: any): (any, string?)
    local instance, err = profile_instance()
    if not instance then return {}, err end
    local listed, lerr = instance:list({})
    if lerr or type(listed) ~= "table" or listed.success ~= true then
        return {}, model.explain("profile fields", answer_error(listed, lerr))
    end
    if state.target.own then return model.fields(listed.fields), nil end
    local values: {[string]: any} = {}
    for _, ns in ipairs(model.public_namespaces(listed.fields)) do
        local got, gerr = instance:get_namespace({namespace = ns, user_id = state.target.id})
        if gerr or type(got) ~= "table" or got.success ~= true then
            return {}, model.explain("public fields", answer_error(got, gerr))
        end
        values[ns] = got.values
    end
    return model.public_fields(listed.fields, values), nil
end

local function load(state: any)
    state.failure, state.problems = nil, {}
    state.identity, state.groups, state.token = nil, {}, nil
    if not state.target.id then
        state.failure, state.form = "No signed-in account: the shell runs without a logon", nil
        return
    end
    if state.target.full then
        local user, err = user_repo.get(state.target.id)
        if err or type(user) ~= "table" then
            state.failure, state.form = model.explain("account", err), nil
            return
        end
        state.identity = {email = tostring(user.email or ""), full_name = tostring(user.full_name or "")}
        local groups, gerr = user_groups_repo.get_user_groups(state.target.id)
        if gerr then
            table.insert(state.problems, model.explain("groups", gerr))
        else
            state.groups = groups and groups.groups or {}
        end
    end
    if state.target.own then
        local expiries, terr = sessions.read(consts.get_db_resource())
        if terr then table.insert(state.problems, model.explain("tokens", terr)) end
        state.token = expiries[state.target.id]
    end
    local fields, ferr = read_fields(state)
    state.fields = fields
    if ferr then table.insert(state.problems, ferr) end
    state.form = model.new_form(state.identity, state.fields)
end

-- apply(state) — PUT /user/me for the name (user_repo.update on the actor, as
-- update_me.lua does), PUT /profile for the fields (profile set/unset on the
-- actor). Each checked against its gate right before the write. The third
-- value is what to ask the compositor afterwards (model.after_rename): a name
-- that was written is the Start menu's user row, even when a later field of
-- the same save fails.
local function apply(state: any): (boolean, string, any)
    if not state.target.own then return false, "another account is read-only here", {} end
    local changes, problem = model.changes(state.form, state.fields)
    if problem then return false, problem, {} end
    if not changes then return true, "nothing changed", {} end
    local requests: any = {}
    if changes.full_name then
        if not gate("update_me") then return false, model.not_granted("update_me"), {} end
        local _, err = user_repo.update(state.self_id, {full_name = changes.full_name})
        requests = model.after_rename(changes, err)
        if err then return false, model.explain("full name", err), requests end
        model.apply_rename(state, state.form, tostring(changes.full_name))
    end
    if #changes.sets > 0 or #changes.unsets > 0 then
        if not gate("put_profile") then return false, model.not_granted("put_profile"), requests end
        local instance, ierr = profile_instance()
        if not instance then return false, tostring(ierr), requests end
        for _, item in ipairs(changes.sets) do
            local result, err = instance:set(item)
            if err or type(result) ~= "table" or result.success ~= true then
                return false, model.explain(item.namespace .. ":" .. item.key, answer_error(result, err)), requests
            end
        end
        for _, item in ipairs(changes.unsets) do
            local result, err = instance:unset(item)
            if err or type(result) ~= "table" or result.success ~= true then
                return false, model.explain(item.namespace .. ":" .. item.key, answer_error(result, err)), requests
            end
        end
    end
    return true, "saved", requests
end

local function change_password(state: any, form: any): (boolean, string)
    if not state.target.own then return false, "another account's password is changed in Users" end
    if not gate("update_me") then return false, model.not_granted("update_me") end
    local _, err = user_repo.update(state.self_id, {password = form.password})
    if err then return false, model.explain("password", err) end
    return true, "password changed"
end

-- ─── state ──────────────────────────────────────────────────────────────

function definition.init(args: any, context: any): any
    local actor = security.actor()
    local self_id = actor and tostring(actor:id()) or nil
    local is_admin = false
    if self_id then
        local groups = user_groups_repo.get_user_groups(self_id)
        local _, admin = consts.derive_scope(consts.get_config(), groups and groups.groups or {})
        is_admin = admin == true
    end
    local state: any = {mode = "sheet", tab = 1, self_id = self_id,
        target = model.target(args, self_id, is_admin),
        can = {update_me = gate("update_me"), put_profile = gate("put_profile")},
        fields = {}, groups = {}, problems = {}, identity = nil, token = nil, form = nil,
        password = nil, pending = nil, status = nil, failure = nil}
    load(state)
    return state
end

local function defer(state: any, context: any, op: any)
    state.pending = op
    state.status = op.label
    context.after("30ms", "pending")
end

-- ─── view ───────────────────────────────────────────────────────────────

function definition.view(state: any, context: any): any
    local body: any
    if state.mode == "password" then
        body = model.password_tree(state.password, state.pending ~= nil)
    else
        body = model.sheet(state, state.form, time.now():unix())
    end
    return {kind = "column", gap = 0, children = {
        body,
        {kind = "statusbar", size = 1, fields = {{text = " " .. model.status_line(state)}}},
    }}
end

-- ─── update ─────────────────────────────────────────────────────────────

local function run_pending(state: any, context: any): boolean
    local op: any = state.pending
    state.pending = nil
    if not op then return false end
    if op.kind == "apply" then
        local ok, message, requests = apply(state)
        state.status = message
        -- A new full name is the Start menu's user row: the compositor is
        -- asked to reread the desktop, as Display Properties asks after a
        -- colour. A refusal is said, the save itself stands.
        for _, entry in ipairs(type(requests) == "table" and requests or {}) do
            local request: any = entry
            local _, rerr = desktop.request(request.topic, request.body)
            if rerr then state.status = message .. "; the Start menu was not refreshed: " .. tostring(rerr) end
        end
        if ok then
            load(state)
            if op.close then context.close() end
        end
    elseif op.kind == "password" then
        local ok, message = change_password(state, op.form)
        state.status = message
        if ok then state.mode, state.password = "sheet", nil end
    end
    return true
end

local function activate(state: any, id: any, context: any)
    if id == "cancel" then
        context.close()
    elseif id == "ok" then
        if state.form and model.dirty(state.form) then
            defer(state, context, {kind = "apply", close = true, label = "Saving…"})
        else
            context.close()
        end
    elseif id == "apply" then
        defer(state, context, {kind = "apply", close = false, label = "Saving…"})
    elseif id == "password" then
        if not (state.target.own and state.can.update_me) then
            state.status = model.not_granted("update_me")
            return
        end
        state.mode, state.password, state.status = "password", {password = "", confirm = ""}, nil
    elseif id == "password_ok" then
        local problem = model.check_password(state.password)
        if problem then
            state.status = problem
            return
        end
        defer(state, context, {kind = "password", form = state.password, label = "Changing the password…"})
    elseif id == "password_cancel" then
        state.mode, state.password, state.status = "sheet", nil, nil
    end
end

function definition.update(state: any, action: any, context: any)
    if action.type == "timer" then
        if action.tag == "pending" then return run_pending(state, context) end
        return false
    end
    if action.type == "resize" or action.type == "tick" then return false end

    if action.type == "key" then
        if action.key_type == "esc" and state.mode == "password" then
            state.mode, state.password, state.status = "sheet", nil, nil
            return true
        end
        return false
    end

    if action.id == "pages" and action.type == "select" then
        local index = tonumber(action.index) or 1
        state.tab = (index >= 1 and index <= #model.TABS) and math.floor(index) or 1
        return true
    end

    if action.type == "change" then
        if state.mode == "password" and state.password then
            if action.id == "f_password" then state.password.password = tostring(action.value or "") end
            if action.id == "f_confirm" then state.password.confirm = tostring(action.value or "") end
            return true
        end
        if state.form then
            if action.id == "f_full_name" then
                state.form.full_name = tostring(action.value or "")
            elseif model.field_of(action.id) then
                state.form.values[action.id] = tostring(action.value or "")
            end
            return true
        end
        return false
    end

    if action.type ~= "activate" then return false end
    -- Enter in a field does what the sheet's default button does.
    if type(action.id) == "string" and (action.id:sub(1, 2) == "f_" or model.field_of(action.id)) then
        activate(state, state.mode == "password" and "password_ok" or "ok", context)
        return true
    end
    activate(state, action.id, context)
    return true
end

definition.close_on_escape = true

return {main = app.main(definition), definition = definition}
