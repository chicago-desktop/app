-- Users window model.
--
-- Pure functions between the users module's shapes and the window: app_users
-- rows with their groups, the scope catalog and the newest session token per
-- account become table rows, forms and refusals. No IO: the window reads and
-- writes through kickside.users' own libraries (the ones its HTTP handlers
-- use), the model decides what may be sent, so a test runs it on stubs.
--
-- The rules the handlers apply are taken from the module rather than restated:
-- e-mail and password checks are kickside.users:consts' validate_email and
-- validate_password, the statuses are consts.USER_STATUS, the limits
-- consts.LIMITS.
local consts = require("consts")
local format = require("format")
local sessions = require("sessions")

local model = {}

-- The gates the HTTP handlers check with security.can("access", …). The window
-- runs under the signed-in user's actor, and app.security:user also carries
-- db.get on the application database — without these gates the window would
-- be a way around the handlers' authorization.
model.GATES = {
    list = "kickside.users.api:list_users.endpoint",
    create = "kickside.users.api:create_user.endpoint",
    update = "kickside.users.api:update_user.endpoint",
    delete = "kickside.users.api:delete_user.endpoint",
    get_groups = "kickside.users.api:get_user_groups.endpoint",
    set_groups = "kickside.users.api:set_user_groups.endpoint",
}

model.OP_LABEL = {
    list = "Users",
    create = "New…",
    update = "Properties…",
    delete = "Delete",
    get_groups = "Groups…",
    set_groups = "Saving groups",
}

-- list_users.lua caps a page at 100.
model.PAGE = 100

model.LABEL_WIDTH = 16

model.EMPTY = "No accounts yet"

model.COLUMNS = {
    {title = "Name", weight = 3},
    {title = "E-mail", weight = 4},
    {title = "Groups", weight = 3},
    {title = "Status", width = 10},
    {title = "Last token", width = 16},
}

model.STATUS_OPTIONS = {
    {value = consts.USER_STATUS.ACTIVE, label = "Active"},
    {value = consts.USER_STATUS.INACTIVE, label = "Inactive"},
    {value = consts.USER_STATUS.SUSPENDED, label = "Suspended"},
    {value = consts.USER_STATUS.PENDING, label = "Pending"},
}

local function text(value: any): string
    if value == nil then return "" end
    return tostring(value)
end

local function trim(value: any): string
    return (text(value):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function contains(list: any, value: any): boolean
    for _, item in ipairs(type(list) == "table" and list or {}) do
        if item == value then return true end
    end
    return false
end

-- ─── rows ───────────────────────────────────────────────────────────────

function model.status_text(status: any): string
    for _, option in ipairs(model.STATUS_OPTIONS) do
        if option.value == status then return option.label end
    end
    return text(status)
end

-- The newest session per account and its wording live in app.users:sessions,
-- shared with User Profile.
model.tokens = sessions.expiries
model.span = sessions.span
model.token_text = sessions.text

-- users(rows, tokens) -> list
-- `rows` are list_users.lua's shape: user_repo.list() plus security_groups
-- per user. Sorted by e-mail, the one field every account has.
function model.users(rows: any, tokens: any): any
    local out = {}
    for _, raw in ipairs(type(rows) == "table" and rows or {}) do
        local row: any = raw
        local id = text(row.user_id)
        if id ~= "" then
            local groups = {}
            for _, group in ipairs(type(row.security_groups) == "table" and row.security_groups or {}) do
                groups[#groups + 1] = text(group)
            end
            out[#out + 1] = {
                id = id,
                email = text(row.email),
                name = text(row.full_name),
                status = text(row.status),
                groups = groups,
                token = type(tokens) == "table" and tokens[id] or nil,
                created = text(row.created_at),
            }
        end
    end
    table.sort(out, function(a: any, b: any): boolean return a.email < b.email end)
    return out
end

function model.find(users: any, id: any): any
    if id == nil then return nil end
    for _, item in ipairs(users) do
        if item.id == id then return item end
    end
    return nil
end

function model.group_label(scopes: any, id: any): string
    for _, raw in ipairs(type(scopes) == "table" and scopes or {}) do
        local scope: any = raw
        if scope.id == id then
            local label = text(scope.label)
            return label ~= "" and label or text(id)
        end
    end
    return text(id)
end

function model.groups_text(item: any, scopes: any): string
    local labels = {}
    for _, id in ipairs(item.groups) do labels[#labels + 1] = model.group_label(scopes, id) end
    return #labels > 0 and table.concat(labels, ", ") or "(none)"
end

function model.table_rows(users: any, scopes: any, now: any): any
    local rows = {}
    for _, item in ipairs(users) do
        rows[#rows + 1] = {id = item.id, cells = {
            item.name ~= "" and item.name or "(no name)",
            item.email,
            model.groups_text(item, scopes),
            model.status_text(item.status),
            model.token_text(item.token, now),
        }}
    end
    return rows
end

function model.detail(item: any, scopes: any, now: any): string
    if not item then return "" end
    local parts = {item.email, model.status_text(item.status), "session " .. model.token_text(item.token, now)}
    if item.created ~= "" then parts[#parts + 1] = "created " .. item.created:sub(1, 10) end
    return table.concat(parts, " · ")
end

-- ─── refusals ───────────────────────────────────────────────────────────

function model.is_admin(item: any, admin_group: any): boolean
    if type(admin_group) ~= "string" or admin_group == "" then return false end
    return contains(item.groups, admin_group)
end

-- last_admin(item, ctx) -> reason or nil
--
-- ctx is {self_id, admin_group, admin_count, admin_problem}: who is signed in,
-- the administrator group (kickside.users.env:admin_group_id) and how many
-- accounts hold it. An unknown count is not a count of two: taking an
-- administrator away is refused while the administrators cannot be counted.
function model.last_admin(item: any, ctx: any): string?
    if type(ctx.admin_group) ~= "string" or ctx.admin_group == "" then
        return "the administrator group is not configured, so the last administrator cannot be protected"
    end
    if not model.is_admin(item, ctx.admin_group) then return nil end
    if ctx.admin_count == nil then
        return "administrators could not be counted (" .. text(ctx.admin_problem or "no answer") .. ")"
    end
    if ctx.admin_count <= 1 then
        return item.email .. " is the last administrator: give another account the administrator group first"
    end
    return nil
end

-- delete_refusal(item, ctx) — the deletions refused before asking: the
-- account you are signed in with (the session would outlive its user) and the
-- last administrator (nobody could manage users afterwards).
function model.delete_refusal(item: any, ctx: any): string?
    if not item then return nil end
    if ctx.self_id ~= nil and item.id == ctx.self_id then
        return "you cannot delete the account you are signed in with"
    end
    return model.last_admin(item, ctx)
end

-- status_refusal(item, status, ctx) — the same two, for a status that stops
-- the account from signing in.
function model.status_refusal(item: any, status: any, ctx: any): string?
    if status == item.status or status == consts.USER_STATUS.ACTIVE then return nil end
    if ctx.self_id ~= nil and item.id == ctx.self_id then
        return "you cannot deactivate the account you are signed in with"
    end
    return model.last_admin(item, ctx)
end

-- groups_refusal(item, groups, ctx) — taking the administrator group away.
-- Without a configured administrator group no account can be told apart from
-- an administrator, so every change is refused, as delete and deactivate are.
function model.groups_refusal(item: any, groups: any, ctx: any): string?
    if type(ctx.admin_group) ~= "string" or ctx.admin_group == "" then return model.last_admin(item, ctx) end
    if not model.is_admin(item, ctx.admin_group) or contains(groups, ctx.admin_group) then return nil end
    if ctx.self_id ~= nil and item.id == ctx.self_id then
        return "you cannot take the administrator group from the account you are signed in with"
    end
    return model.last_admin(item, ctx)
end

function model.not_granted(op: string): string
    return tostring(model.OP_LABEL[op]) .. ": not granted to your account (" .. tostring(model.GATES[op]) .. ")"
end

-- explain(what, err) — a refusal as text, in the stand's one wording
-- (app.common:format): the persist libraries answer with strings ("Database
-- operation failed: …"), the contracts with errors whose kind decides it.
model.explain = format.explain

-- ─── forms ──────────────────────────────────────────────────────────────

-- The group ids of the catalog that are chosen, in the catalog's order.
function model.chosen_list(chosen: any, scopes: any): any
    local out = {}
    for _, raw in ipairs(type(scopes) == "table" and scopes or {}) do
        local scope: any = raw
        if chosen[scope.id] then out[#out + 1] = scope.id end
    end
    return out
end

-- foreign(groups, scopes) — groups an account holds that the assignable
-- catalog does not offer (an internal scope, a group granted by SSO).
-- set_user_groups replaces the WHOLE set and refuses ids outside the catalog,
-- so such an account's groups are not saved from here.
function model.foreign(groups: any, scopes: any): any
    local out = {}
    for _, id in ipairs(type(groups) == "table" and groups or {}) do
        local offered = false
        for _, raw in ipairs(type(scopes) == "table" and scopes or {}) do
            local scope: any = raw
            if scope.id == id then offered = true end
        end
        if not offered then out[#out + 1] = id end
    end
    return out
end

function model.group_of(id: any): string?
    if type(id) ~= "string" then return nil end
    return id:match("^g:(.+)$")
end

function model.new_form(default_group: any): any
    local chosen: {[string]: boolean} = {}
    if type(default_group) == "string" and default_group ~= "" then chosen[default_group] = true end
    return {mode = "new", email = "", name = "", password = "", confirm = "", chosen = chosen}
end

-- check_new(form) -> problem or nil — the handler's checks with the labels the
-- user sees, and the module's own validate_email / validate_password.
function model.check_new(form: any): string?
    local email = trim(form.email):lower()
    if email == "" then return "E-mail is required" end
    local email_ok, email_why = consts.validate_email(email)
    if not email_ok then return tostring(email_why) end
    if #trim(form.name) > consts.LIMITS.MAX_FULL_NAME_LENGTH then return "Full name is too long" end
    if form.password == "" then return "Password is required" end
    local pass_ok, pass_why = consts.validate_password(form.password)
    if not pass_ok then return tostring(pass_why) end
    if form.password ~= form.confirm then return "The passwords do not match" end
    return nil
end

-- create_payload(form, scopes) -> user_data, groups — what create_user.lua
-- hands admin_repo.create: the e-mail lowercased (user_repo does it too), the
-- password as typed.
function model.create_payload(form: any, scopes: any): (any, any)
    return {
        email = trim(form.email):lower(),
        full_name = trim(form.name),
        password = form.password,
        status = consts.USER_STATUS.ACTIVE,
    }, model.chosen_list(form.chosen, scopes)
end

function model.props_form(item: any): any
    return {mode = "props", id = item.id, email = item.email, name = item.name, status = item.status,
        password = "", confirm = "", name_before = item.name, status_before = item.status}
end

-- props_update(form, item, ctx) -> update_data | nil, problem | nil
--
-- Only what changed. update_user.lua drops an empty full_name instead of
-- clearing it, so clearing is refused here rather than silently not done.
-- nil, nil means nothing to save.
function model.props_update(form: any, item: any, ctx: any): (any, string?)
    local data: {[string]: any} = {}
    local name = trim(form.name)
    if name ~= form.name_before then
        if name == "" then return nil, "The full name cannot be cleared: the users module keeps the old one" end
        if #name > consts.LIMITS.MAX_FULL_NAME_LENGTH then return nil, "Full name is too long" end
        data.full_name = name
    end
    if form.status ~= form.status_before then
        local refusal = model.status_refusal(item, form.status, ctx)
        if refusal then return nil, "Status: " .. refusal end
        data.status = form.status
    end
    if form.password ~= "" or form.confirm ~= "" then
        local ok, why = consts.validate_password(form.password)
        if not ok then return nil, tostring(why) end
        if form.password ~= form.confirm then return nil, "The passwords do not match" end
        data.password = form.password
    end
    if next(data) == nil then return nil, nil end
    return data, nil
end

function model.groups_form(item: any): any
    local chosen: {[string]: boolean} = {}
    for _, id in ipairs(item.groups) do chosen[id] = true end
    return {mode = "groups", id = item.id, email = item.email, chosen = chosen}
end

-- groups_save(form, item, scopes, ctx) -> groups | nil, problem | nil
-- nil, nil means the set did not change.
function model.groups_save(form: any, item: any, scopes: any, ctx: any): (any, string?)
    local foreign = model.foreign(item.groups, scopes)
    if #foreign > 0 then
        return nil, item.email .. " holds " .. table.concat(foreign, ", ")
            .. ", which the catalog does not offer: saving here would remove it"
    end
    local groups = model.chosen_list(form.chosen, scopes)
    local same = #groups == #item.groups
    for _, id in ipairs(groups) do
        if not contains(item.groups, id) then same = false end
    end
    if same then return nil, nil end
    local refusal = model.groups_refusal(item, groups, ctx)
    if refusal then return nil, "Groups: " .. refusal end
    return groups, nil
end

-- ─── trees ──────────────────────────────────────────────────────────────

local function field(caption: string, control: any): any
    return {kind = "row", size = 2, gap = 1, children = {
        {kind = "label", size = model.LABEL_WIDTH, text = caption},
        control,
    }}
end

-- One checkbox per group of the catalog, then the foreign groups as text.
local function group_checks(scopes: any, chosen: any, held: any, disabled: boolean): any
    local rows: any = {}
    for _, raw in ipairs(type(scopes) == "table" and scopes or {}) do
        local scope: any = raw
        local caption = model.group_label(scopes, scope.id)
        if text(scope.description) ~= "" then caption = caption .. " — " .. text(scope.description) end
        rows[#rows + 1] = {kind = "row", size = 1, gap = 1, children = {
            {kind = "label", size = model.LABEL_WIDTH, text = ""},
            {kind = "checkbox", id = "g:" .. tostring(scope.id), text = caption,
                checked = chosen[scope.id] == true, disabled = disabled},
        }}
    end
    for _, id in ipairs(model.foreign(held, scopes)) do
        rows[#rows + 1] = {kind = "row", size = 1, gap = 1, children = {
            {kind = "label", size = model.LABEL_WIDTH, text = ""},
            {kind = "label", text = "[held] " .. id .. " — not offered by the catalog"},
        }}
    end
    return rows
end

local function buttons(list: any): any
    return {kind = "row", size = 2, gap = 1, align = "right", children = list}
end

-- list_tree(state, now) — the list sheet. A button the account may not use is
-- disabled, and the line above the buttons says why: the refusal for the
-- selected account first, then the grants the account lacks.
function model.list_tree(state: any, now: any): any
    local item = model.find(state.users, state.selected_id)
    local access: any = state.access or {}
    local refusal = item and model.delete_refusal(item, state.ctx) or nil
    local body: any
    if #state.users == 0 then
        body = {kind = "label", text = state.failure and "The accounts could not be read." or model.EMPTY,
            alert = state.failure ~= nil}
    else
        body = {kind = "table", id = "users", columns = model.COLUMNS,
            rows = model.table_rows(state.users, state.scopes, now), selected = state.selected_id}
    end
    return {kind = "column", padding = 1, padding_bottom = 0, gap = 0, children = {
        {kind = "label", size = 1, text = "Accounts of this application:"},
        body,
        {kind = "label", size = 1, text = model.detail(item, state.scopes, now)},
        {kind = "label", size = 1, text = model.reason_line(state, item)},
        buttons({
            {kind = "button", id = "new", size = 8, text = "New…", disabled = not access.create},
            {kind = "button", id = "props", size = 14, text = "Properties…", disabled = item == nil or not access.update},
            {kind = "button", id = "groups", size = 11, text = "Groups…", disabled = item == nil or not access.get_groups},
            {kind = "button", id = "delete", size = 10, text = "Delete",
                disabled = item == nil or not access.delete or refusal ~= nil},
            {kind = "button", id = "refresh", size = 11, text = "Refresh"},
            {kind = "button", id = "close", size = 9, text = "Close", default = true},
        }),
    }}
end

function model.reason_line(state: any, item: any): string
    local access: any = state.access or {}
    if item and access.delete then
        local refusal = model.delete_refusal(item, state.ctx)
        if refusal then return "Delete: " .. refusal end
    end
    local missing = {}
    for _, op in ipairs({"create", "update", "get_groups", "delete"}) do
        if not access[op] then missing[#missing + 1] = model.OP_LABEL[op] end
    end
    if #missing > 0 then return "Not granted to your account: " .. table.concat(missing, ", ") end
    return ""
end

function model.new_tree(form: any, scopes: any, busy: any): any
    local children: any = {
        {kind = "label", size = 1, text = "New user"},
        {kind = "label", size = 1, text = ""},
        field("E-mail *:", {kind = "input", id = "f_email", text = form.email}),
        field("Full name:", {kind = "input", id = "f_name", text = form.name}),
        field("Password *:", {kind = "input", id = "f_password", text = form.password, password = true}),
        field("Confirm *:", {kind = "input", id = "f_confirm", text = form.confirm, password = true}),
        {kind = "row", size = 1, gap = 1, children = {
            {kind = "label", size = model.LABEL_WIDTH, text = "Groups:"},
            {kind = "label", text = #scopes == 0 and "the groups catalog is empty" or ""},
        }},
    }
    for _, row in ipairs(group_checks(scopes, form.chosen, {}, busy == true)) do children[#children + 1] = row end
    children[#children + 1] = {kind = "label", text = ""}
    children[#children + 1] = buttons({
        {kind = "button", id = "save", size = 10, text = "Create", default = true, disabled = busy == true},
        {kind = "button", id = "cancel", size = 10, text = "Cancel"},
    })
    return {kind = "column", padding = 1, padding_bottom = 0, gap = 0, children = children}
end

function model.props_tree(form: any, busy: any): any
    return {kind = "column", padding = 1, padding_bottom = 0, gap = 0, children = {
        {kind = "label", size = 1, text = "Properties: " .. form.email},
        {kind = "label", size = 1, text = ""},
        field("E-mail:", {kind = "label", text = form.email}),
        field("Full name:", {kind = "input", id = "f_name", text = form.name}),
        field("Status:", {kind = "select", id = "f_status", value = form.status, options = model.STATUS_OPTIONS}),
        field("New password:", {kind = "input", id = "f_password", text = form.password, password = true}),
        field("Confirm:", {kind = "input", id = "f_confirm", text = form.confirm, password = true}),
        {kind = "label", size = 1, text = "Leave the password empty to keep it."},
        {kind = "label", text = ""},
        buttons({
            {kind = "button", id = "save", size = 10, text = "Save", default = true, disabled = busy == true},
            {kind = "button", id = "cancel", size = 10, text = "Cancel"},
        }),
    }}
end

function model.groups_tree(form: any, item: any, scopes: any, can_save: any, busy: any): any
    local children: any = {
        {kind = "label", size = 1, text = "Groups: " .. form.email},
        {kind = "label", size = 1, text = ""},
    }
    for _, row in ipairs(group_checks(scopes, form.chosen, item and item.groups or {}, can_save ~= true or busy == true)) do
        children[#children + 1] = row
    end
    children[#children + 1] = {kind = "label", text = ""}
    children[#children + 1] = {kind = "label", size = 1,
        text = can_save == true and "" or model.not_granted("set_groups")}
    children[#children + 1] = buttons({
        {kind = "button", id = "save", size = 10, text = "Save", default = true,
            disabled = can_save ~= true or busy == true},
        {kind = "button", id = "cancel", size = 10, text = "Cancel"},
    })
    return {kind = "column", padding = 1, padding_bottom = 0, gap = 0, children = children}
end

-- ─── status ─────────────────────────────────────────────────────────────

function model.summary(state: any): string
    local users = state.users
    local admins = 0
    for _, item in ipairs(users) do
        if model.is_admin(item, state.ctx.admin_group) then admins = admins + 1 end
    end
    local line = #users == 1 and "1 user" or string.format("%d users", #users)
    if state.more then line = line .. string.format(" (the first %d)", #users) end
    line = line .. ", " .. (admins == 1 and "1 administrator" or string.format("%d administrators", admins))
    local me = model.find(users, state.ctx.self_id)
    if me then line = line .. " · signed in as " .. me.email end
    return line
end

-- status_line(state) — a message of the moment first, then why the list is
-- empty, then the summary with what could not be read beside it.
function model.status_line(state: any): string
    if state.status and state.status ~= "" then return tostring(state.status) end
    if state.failure then return tostring(state.failure) end
    local line = model.summary(state)
    if state.token_problem then line = line .. " · " .. tostring(state.token_problem) end
    if state.scope_problem then line = line .. " · " .. tostring(state.scope_problem) end
    return line
end

return model
