-- User Profile window model.
--
-- Pure functions between the users module's shapes and the window: the
-- account row, its groups, the newest session and the declared profile fields
-- become a property sheet, a form and what is sent back. No IO: the window
-- reads and writes through the same libraries as GET/PUT /user/me and
-- GET/PUT /profile, the model decides what may be sent, so a test runs it on
-- stubs.
local format = require("format")
local sessions = require("sessions")
local consts = require("consts")

local model = {}

-- What the router's endpoint_firewall checks for PUT /user/me and PUT
-- /profile: `access` on the endpoint's own id (runtime
-- service/http/middleware/firewall/endpoint_firewall.go). The handlers check
-- nothing themselves, so the window checks what the firewall would.
model.GATES = {
    update_me = "kickside.users.api:update_me.endpoint",
    put_profile = "kickside.users.api:put_profile.endpoint",
}

model.OP_LABEL = {
    update_me = "Changing the name and password",
    put_profile = "Changing profile fields",
}

model.TABS = {"General", "Profile"}

model.LABEL_WIDTH = 18

-- The field other accounts see as a name (kickside/users declares it public).
model.DISPLAY_NAME = {namespace = "kickside.profile", key = "display_name"}

-- update_me.lua takes no current password: a new one in PUT /user/me is
-- enough. The sheet says so rather than ask for a password nobody checks.
model.NO_CURRENT = "The users module does not ask for the current password."

model.PUBLIC_ONLY = "Another account: only its public profile fields are shown."

model.explain = format.explain

local function text(value: any): string
    if value == nil then return "" end
    return tostring(value)
end

local function trim(value: any): string
    return (text(value):gsub("^%s+", ""):gsub("%s+$", ""))
end

function model.not_granted(op: string): string
    return tostring(model.OP_LABEL[op]) .. " is not granted to your account (" .. tostring(model.GATES[op]) .. ")"
end

-- ─── whose profile ──────────────────────────────────────────────────────

-- target(args, self_id, is_admin) -> {id, own, full}
--
-- The Start menu opens the window with {user_id = <id>}; without it the
-- window is the signed-in account's. `own` — the signed-in account, editable
-- where the gates allow. `full` — identity and groups are shown: own, or an
-- administrator looking at another account. Otherwise only the public
-- profile fields, as profile.get_namespace answers for a cross-user target.
-- Writes always target the actor (update_me, profile.set), so another account
-- is read-only for everyone.
function model.target(args: any, self_id: any, is_admin: any): any
    local wanted: any = type(args) == "table" and args.user_id or nil
    local id: any = (type(wanted) == "string" and wanted ~= "") and wanted or self_id
    local own = id ~= nil and id == self_id
    return {id = id, own = own, full = own or is_admin == true}
end

-- ─── profile fields ─────────────────────────────────────────────────────

local function max_length(schema: any): number?
    if type(schema) ~= "table" then return nil end
    return tonumber(schema.maxLength)
end

local function field(row: any, editable: boolean): any
    return {
        namespace = row.namespace,
        key = row.key,
        value_type = text(row.value_type),
        value = row.value,
        default = row.default,
        description = text(row.description),
        editable = editable,
        visibility = text(row.visibility),
        max = max_length(row.schema),
    }
end

local function sorted(list: any): any
    table.sort(list, function(a: any, b: any): boolean
        if a.namespace ~= b.namespace then return a.namespace < b.namespace end
        return a.key < b.key
    end)
    return list
end

local function declared(row: any): boolean
    return type(row) == "table" and type(row.namespace) == "string" and type(row.key) == "string"
end

-- fields(rows) -> list — the actor's own fields: what profile.list() returns
-- (visible declarations merged with the actor's values).
function model.fields(rows: any): any
    local out = {}
    for _, raw in ipairs(type(rows) == "table" and rows or {}) do
        local row: any = raw
        if declared(row) then out[#out + 1] = field(row, row.editable ~= false) end
    end
    return sorted(out)
end

-- public_namespaces(rows) — the namespaces holding a public declaration, the
-- ones get_namespace is asked about for another account.
function model.public_namespaces(rows: any): any
    local seen: {[string]: boolean} = {}
    local out = {}
    for _, raw in ipairs(type(rows) == "table" and rows or {}) do
        local row: any = raw
        if declared(row) and row.visibility == "public" and not seen[row.namespace] then
            seen[row.namespace] = true
            out[#out + 1] = row.namespace
        end
    end
    table.sort(out)
    return out
end

-- public_fields(rows, values) -> list — another account's fields: the public
-- declarations only, with what get_namespace answered for that account
-- (values[namespace][key]), the declared default where it gave nothing. None
-- is editable.
function model.public_fields(rows: any, values: any): any
    local out = {}
    for _, raw in ipairs(type(rows) == "table" and rows or {}) do
        local row: any = raw
        if declared(row) and row.visibility == "public" then
            local item = field(row, false)
            local ns: any = type(values) == "table" and values[row.namespace] or nil
            item.value = type(ns) == "table" and ns[row.key] or nil
            if item.value == nil then item.value = row.default end
            out[#out + 1] = item
        end
    end
    return sorted(out)
end

function model.is_text(item: any): boolean
    return item.value_type == "string"
end

function model.value_text(item: any): string
    local value = item.value
    if value == nil then return "" end
    if item.value_type == "bool" then return value == true and "Yes" or "No" end
    if item.value_type == "int" then return string.format("%d", tonumber(value) or 0) end
    if item.value_type == "json" then return "(a structured value)" end
    return text(value)
end

-- caption(item) — "display_name" reads "Display name:".
function model.caption(item: any): string
    local words = (text(item.key):gsub("_", " "))
    return words:sub(1, 1):upper() .. words:sub(2) .. ":"
end

function model.field_id(item: any): string
    return "p:" .. item.namespace .. ":" .. item.key
end

function model.field_of(id: any): (string?, string?)
    if type(id) ~= "string" then return nil, nil end
    local ns, key = id:match("^p:([^:]+):(.+)$")
    if not ns then return nil, nil end
    return tostring(ns), tostring(key)
end

function model.display_name(fields: any): string
    for _, item in ipairs(type(fields) == "table" and fields or {}) do
        if item.namespace == model.DISPLAY_NAME.namespace and item.key == model.DISPLAY_NAME.key then
            return text(item.value)
        end
    end
    return ""
end

-- ─── the form ───────────────────────────────────────────────────────────

-- new_form(identity, fields) — what the sheet's inputs hold: the full name and
-- the text of every text field, and the same again as it was read.
function model.new_form(identity: any, fields: any): any
    local values: {[string]: string} = {}
    local before: {[string]: string} = {}
    for _, item in ipairs(fields) do
        if model.is_text(item) then
            local id = model.field_id(item)
            values[id] = model.value_text(item)
            before[id] = values[id]
        end
    end
    local name = identity and text(identity.full_name) or ""
    return {full_name = name, name_before = name, values = values, before = before}
end

function model.dirty(form: any): boolean
    if not form then return false end
    if form.full_name ~= form.name_before then return true end
    for id, value in pairs(form.values) do
        if form.before[id] ~= value then return true end
    end
    return false
end

-- changes(form, fields) -> {full_name?, sets, unsets} | nil, problem | nil
--
-- Only what changed. update_me.lua drops an empty full_name instead of
-- clearing it, so clearing is refused here rather than silently not done. A
-- field typed back to its declared default is unset — it follows the default
-- again — and anything else is set. nil, nil: nothing to save.
function model.changes(form: any, fields: any): (any, string?)
    local out: any = {sets = {}, unsets = {}}
    local name = trim(form.full_name)
    if name ~= trim(form.name_before) then
        if name == "" then return nil, "The full name cannot be cleared: the users module keeps the old one" end
        if #name > consts.LIMITS.MAX_FULL_NAME_LENGTH then return nil, "Full name is too long" end
        out.full_name = name
    end
    for _, item in ipairs(fields) do
        local id = model.field_id(item)
        local typed = form.values[id]
        if item.editable and model.is_text(item) and typed ~= nil and typed ~= form.before[id] then
            if item.max and #typed > item.max then
                return nil, model.caption(item):sub(1, -2) .. " is longer than "
                    .. string.format("%d", item.max) .. " characters"
            end
            if typed == text(item.default) then
                out.unsets[#out.unsets + 1] = {namespace = item.namespace, key = item.key}
            else
                out.sets[#out.sets + 1] = {namespace = item.namespace, key = item.key, value = typed}
            end
        end
    end
    if out.full_name == nil and #out.sets == 0 and #out.unsets == 0 then return nil, nil end
    return out, nil
end

-- check_password(form) -> problem or nil — the users module's own rule.
function model.check_password(form: any): string?
    if form.password == "" then return "Type the new password twice" end
    local ok, why = consts.validate_password(form.password)
    if not ok then return tostring(why) end
    if form.password ~= form.confirm then return "The passwords do not match" end
    return nil
end

-- ─── the sheet ──────────────────────────────────────────────────────────

local function line(caption: string, value: string): any
    return {kind = "row", size = 1, gap = 1, children = {
        {kind = "label", size = model.LABEL_WIDTH, text = caption},
        {kind = "label", text = value},
    }}
end

local function input_row(caption: string, control: any): any
    return {kind = "row", size = 2, gap = 1, children = {
        {kind = "label", size = model.LABEL_WIDTH, text = caption},
        control,
    }}
end

-- heading(view) — the caption beside the user icon: "Full Name <e-mail>",
-- or for a public view the account's display name.
function model.heading(view: any): string
    local identity: any = view.identity
    if identity and text(identity.email) ~= "" then
        local name = text(identity.full_name)
        return name ~= "" and (name .. " <" .. identity.email .. ">") or identity.email
    end
    local shown = model.display_name(view.fields)
    if shown ~= "" then return shown end
    return text(view.target and view.target.id)
end

-- after_rename(changes, err) -> the compositor requests after the name write
--
-- The full name is also the user row at the top of Start, and the shell reads
-- it again on `desktop.refresh` (through CHICAGO_USER_FUNC). So a
-- name that WAS written asks for exactly one refresh — the request Display
-- Properties sends after a colour; a refused write, or a save that did not
-- touch the name, asks for none.
function model.after_rename(changes: any, err: any): {any}
    if type(changes) ~= "table" or changes.full_name == nil or err ~= nil then return {} end
    return {{topic = "desktop.refresh", body = {}}}
end

-- apply_rename(view, form, name) — the written name in the window at once: the
-- heading's identity and the form's "as it was read". The heading is right and
-- the sheet is not dirty even when a later field of the same save fails and
-- the window is not reloaded.
function model.apply_rename(view: any, form: any, name: string)
    if type(view.identity) == "table" then view.identity.full_name = name end
    if type(form) == "table" then
        form.full_name = name
        form.name_before = name
    end
end

function model.general_reason(view: any): string
    if not view.target.own then
        return view.target.full and "Another account, read-only: change it in Users → Properties…" or ""
    end
    if view.can.update_me ~= true then return model.not_granted("update_me") end
    return ""
end

function model.profile_reason(view: any): string
    if not view.target.own then return "Read-only: profile writes always go to the signed-in account." end
    if view.can.put_profile ~= true then return model.not_granted("put_profile") end
    for _, item in ipairs(view.fields) do
        if not model.is_text(item) then return "Only text fields are changed here; the others where they are used." end
    end
    return ""
end

function model.general_page(view: any, form: any, now: any): any
    local target = view.target
    local busy = view.pending ~= nil
    local children: any = {}
    if target.full and view.identity then
        local editable = target.own and view.can.update_me == true and not busy
        children[#children + 1] = {kind = "group", title = "Identity", size = 5, children = {
            line("E-mail:", text(view.identity.email)),
            input_row("Full name:", {kind = "input", id = "f_full_name", text = form.full_name,
                disabled = not editable}),
        }}
        local groups = type(view.groups) == "table" and view.groups or {}
        children[#children + 1] = {kind = "group", title = "Groups", size = 3, children = {
            {kind = "label", size = 1, text = #groups > 0 and table.concat(groups, ", ") or "(none)"},
        }}
    else
        children[#children + 1] = {kind = "label", size = 1, text = model.PUBLIC_ONLY}
    end
    if target.own then
        children[#children + 1] = {kind = "group", title = "Session", size = 4, children = {
            line("Signed in as:", view.identity and text(view.identity.email) or text(target.id)),
            line("This session:", sessions.text(view.token, now)),
        }}
    end
    children[#children + 1] = {kind = "label", text = ""}
    children[#children + 1] = {kind = "label", size = 1, text = model.general_reason(view)}
    return children
end

function model.profile_page(view: any, form: any): any
    local writable = view.target.own and view.can.put_profile == true and view.pending == nil
    local children: any = {}
    if #view.fields == 0 then
        children[1] = {kind = "label", size = 1, text = "No profile fields are declared."}
    end
    for _, item in ipairs(view.fields) do
        if model.is_text(item) then
            local id = model.field_id(item)
            children[#children + 1] = input_row(model.caption(item), {kind = "input", id = id,
                text = form.values[id] or model.value_text(item), disabled = not (writable and item.editable)})
        else
            children[#children + 1] = line(model.caption(item), model.value_text(item) .. " (" .. item.value_type .. ")")
        end
    end
    children[#children + 1] = {kind = "label", text = ""}
    children[#children + 1] = {kind = "label", size = 1, text = model.profile_reason(view)}
    return children
end

-- sheet(view, form, now) — the property sheet: the user icon and the caption,
-- the General and Profile tabs, and the buttons at the right edge.
function model.sheet(view: any, form: any, now: any): any
    if not form then
        return {kind = "column", padding = 1, padding_bottom = 0, gap = 0, children = {
            {kind = "label", text = text(view.failure or "The profile could not be read."), alert = true},
            {kind = "row", size = 2, gap = 1, align = "right", children = {
                {kind = "button", id = "cancel", size = 10, text = "Close", default = true},
            }},
        }}
    end
    local busy = view.pending ~= nil
    local page = view.tab == 2 and model.profile_page(view, form) or model.general_page(view, form, now)
    local can_password = view.target.own and view.can.update_me == true and not busy
    return {kind = "column", padding = 1, padding_bottom = 0, gap = 0, children = {
        {kind = "row", size = 2, gap = 1, children = {
            {kind = "image", size = 4, image = "user", icon = "☺"},
            {kind = "label", text = model.heading(view)},
        }},
        {kind = "tabs", id = "pages", labels = model.TABS, active = view.tab, padding = 1, pad = 1, children = {
            {kind = "column", gap = 0, children = page},
        }},
        {kind = "row", size = 2, gap = 1, align = "right", children = {
            {kind = "button", id = "password", size = 19, text = "Change Password…", disabled = not can_password},
            {kind = "button", id = "ok", size = 8, text = "OK", default = true, disabled = busy},
            {kind = "button", id = "cancel", size = 10, text = "Cancel"},
            {kind = "button", id = "apply", size = 9, text = "Apply", disabled = busy or not model.dirty(form)},
        }},
    }}
end

function model.password_tree(form: any, busy: any): any
    return {kind = "column", padding = 1, padding_bottom = 0, gap = 0, children = {
        {kind = "label", size = 1, text = "Change Password"},
        {kind = "label", size = 1, text = ""},
        input_row("New password:", {kind = "input", id = "f_password", text = form.password, password = true}),
        input_row("Confirm:", {kind = "input", id = "f_confirm", text = form.confirm, password = true}),
        {kind = "label", size = 1, text = model.NO_CURRENT},
        {kind = "label", text = ""},
        {kind = "row", size = 2, gap = 1, align = "right", children = {
            {kind = "button", id = "password_ok", size = 10, text = "OK", default = true, disabled = busy == true},
            {kind = "button", id = "password_cancel", size = 10, text = "Cancel"},
        }},
    }}
end

-- status_line(view) — a message of the moment first, then why the profile
-- could not be read, then whose profile this is and what could not be read.
function model.status_line(view: any): string
    if view.status and view.status ~= "" then return tostring(view.status) end
    if view.failure then return tostring(view.failure) end
    local parts: any = {}
    if view.target.own then
        parts[1] = "Your profile"
    elseif view.target.full then
        parts[1] = "Another account, read-only"
    else
        parts[1] = "Public profile, read-only"
    end
    for _, problem in ipairs(type(view.problems) == "table" and view.problems or {}) do
        parts[#parts + 1] = tostring(problem)
    end
    return table.concat(parts, " · ")
end

return model
