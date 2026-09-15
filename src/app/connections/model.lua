-- Connections window model.
--
-- Pure functions between the platform's shapes and the window: component rows
-- become table rows, contract.binding entries become providers, a provider's
-- credential_schema becomes a form tree, what the user typed becomes a
-- private_context. No IO here: the window reads and writes, the model only
-- translates, so a test runs it on stubs.
--
-- Every rule that the HTTP handlers of kickside/connection apply is taken from
-- them rather than restated: the state projection is conn_types.project_state,
-- the binding test is create_policy.is_connection_binding, and the last word on
-- a private_context is create_policy.validate_private_context — the same call
-- create_connection.lua makes.
local conn_types = require("conn_types")
local create_policy = require("create_policy")
local errors = require("errors")

local model = {}

model.EMPTY = "No connections yet"
model.NO_PROVIDERS = "No connection providers are installed"

-- update_connection.lua goes through update_policy.fields, which REFUSES any
-- private_context ("connection credentials cannot be patched through this
-- endpoint; reconnect or recreate the connection") and accepts only the title.
-- So a secret is never sent back on update — there is no partial merge to
-- protect, and a blank password field cannot erase anything: Properties edits
-- the name only, and new credentials mean a new connection.
model.CREDENTIALS_FIXED = "Credentials cannot be changed here: create a new connection and delete this one."

-- The width of the caption column in the form, in cells.
model.LABEL_WIDTH = 22

local STATE_TEXT: {[string]: string} = {
    connected = "Connected",
    needs_reauth = "Needs re-auth",
    disabled = "Disabled",
    expired = "Expired",
    error = "Error",
}

local function text(value: any): string
    if value == nil then return "" end
    return tostring(value)
end

local function trim(value: any): string
    return (text(value):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- ─── connections ────────────────────────────────────────────────────────

function model.state_text(state: any): string
    return STATE_TEXT[text(state)] or text(state)
end

-- project(row, now_unix) — one component row as list_connections.lua's
-- project_connection sees it: name is meta.title, the state is the stored
-- connection_state projected against expires_at.
function model.project(row: any, now_unix: number): any
    local meta: any = type(row.meta) == "table" and row.meta or {}
    return {
        id = text(row.component_id),
        name = text(meta.title),
        provider = text(meta.provider),
        description = text(meta.comment),
        state = conn_types.project_state(meta.connection_state, meta.expires_at, now_unix),
        created = text(row.created_at or meta.created_at),
    }
end

-- connections(rows, now_unix) -> list, problem
-- A row without component_id is a contract violation the handler refuses with
-- "connection row missing component_id". The window keeps the valid rows and
-- names the problem instead of dropping the evidence.
function model.connections(rows: any, now_unix: number): (any, string?)
    local out = {}
    local problem = nil
    for _, row in ipairs(type(rows) == "table" and rows or {}) do
        if type(row) == "table" and type(row.component_id) == "string" and row.component_id ~= "" then
            out[#out + 1] = model.project(row, now_unix)
        else
            problem = "connection row missing component_id"
        end
    end
    return out, problem
end

function model.find(connections: any, id: any): any
    for _, item in ipairs(connections) do
        if item.id == id then return item end
    end
    return nil
end

function model.table_rows(connections: any): any
    local rows = {}
    for _, item in ipairs(connections) do
        rows[#rows + 1] = {id = item.id, cells = {
            item.name ~= "" and item.name or "(unnamed)",
            item.provider,
            model.state_text(item.state),
        }}
    end
    return rows
end

function model.detail(item: any): string
    if not item then return "" end
    local parts = {item.provider ~= "" and item.provider or "no provider"}
    if item.created ~= "" then parts[#parts + 1] = "created " .. item.created end
    if item.description ~= "" then parts[#parts + 1] = item.description end
    return table.concat(parts, " · ")
end

function model.summary(connections: any, more: any): string
    local count = #connections
    local line = count == 1 and "1 connection" or (tostring(count) .. " connections")
    if more == true then line = line .. " (showing the first " .. tostring(count) .. ")" end
    return line
end

-- ─── providers ──────────────────────────────────────────────────────────

-- options(declared) — a schema's select options as the SDK select wants them:
-- {value, label}. A declared option is a plain value or a table with `value`
-- (and maybe `label`) — the two shapes create_policy's option_value accepts.
function model.options(declared: any): any
    local out = {}
    for _, raw in ipairs(type(declared) == "table" and declared or {}) do
        local option: any = raw
        if type(option) == "table" then
            if option.value ~= nil then
                out[#out + 1] = {value = option.value, label = text(option.label ~= nil and option.label or option.value)}
            end
        elseif option ~= nil then
            out[#out + 1] = {value = option, label = text(option)}
        end
    end
    return out
end

-- The choice list of a select field. A required select starts on its first
-- option, as a Windows drop-down always shows a value; an optional one gets
-- a "(none)" row with an empty value first, so a field nobody touched stays
-- out of the private_context instead of sending the first option unasked.
function model.select_options(field: any): any
    if field.required then return field.options end
    local out = {{value = "", label = "(none)"}}
    for _, option in ipairs(field.options) do out[#out + 1] = option end
    return out
end

-- provider(entry) — discover_providers.lua's provider_info, reduced to what the
-- window draws and sends: a connection binding with a credential_schema and a
-- non-empty meta.provider. Anything else is not a provider and is skipped.
function model.provider(entry: any): any
    if type(entry) ~= "table" or entry.kind ~= "contract.binding" then return nil end
    if not create_policy.is_connection_binding(entry, conn_types.CONNECTION_CONTRACT) then return nil end
    local meta: any = type(entry.meta) == "table" and entry.meta or {}
    local schema: any = meta.credential_schema
    if type(schema) ~= "table" then return nil end
    if type(meta.provider) ~= "string" or meta.provider == "" then return nil end

    local fields = {}
    for _, raw in ipairs(type(schema.fields) == "table" and schema.fields or {}) do
        local field: any = raw
        if type(field) == "table" and type(field.key) == "string" and field.key ~= "" then
            fields[#fields + 1] = {
                key = field.key,
                label = text(field.label ~= nil and field.label or field.key),
                type = type(field.type) == "string" and field.type or "text",
                required = field.required == true,
                placeholder = text(field.placeholder),
                help = text(field.help),
                options = model.options(field.options),
            }
        end
    end
    local submit = type(schema.submit_label) == "string" and schema.submit_label ~= "" and schema.submit_label or "Connect"
    return {
        impl_id = text(entry.id),
        provider = meta.provider,
        title = text(meta.title or meta.provider),
        description = text(meta.comment),
        group = type(meta.group) == "string" and meta.group or "",
        fields = fields,
        submit_label = submit,
        entry = entry,
    }
end

-- providers(entries) — sorted by title, as discover_providers.lua sorts them.
function model.providers(entries: any): any
    local out = {}
    for _, entry in ipairs(type(entries) == "table" and entries or {}) do
        local found = model.provider(entry)
        if found then out[#out + 1] = found end
    end
    table.sort(out, function(a: any, b: any): boolean return a.title < b.title end)
    return out
end

function model.find_provider(providers: any, impl_id: any): any
    for _, item in ipairs(providers) do
        if item.impl_id == impl_id then return item end
    end
    return nil
end

function model.provider_rows(providers: any): any
    local rows = {}
    for _, item in ipairs(providers) do
        rows[#rows + 1] = {id = item.impl_id, cells = {item.title, item.group, item.description}}
    end
    return rows
end

-- ─── the form ───────────────────────────────────────────────────────────

-- A form is the window's record of what the user typed: the name, the
-- description and one value per credential field, by key. Text fields hold
-- strings, a checkbox holds a boolean.
function model.new_form(provider: any): any
    local values = {}
    for _, field in ipairs(provider.fields) do
        if field.type == "checkbox" then
            values[field.key] = false
        elseif field.type == "select" then
            local first: any = model.select_options(field)[1]
            values[field.key] = first and first.value or ""
        end
    end
    return {mode = "new", provider = provider, name = "", description = "", values = values}
end

function model.props_form(item: any): any
    return {mode = "props", id = item.id, name = item.name, description = item.description,
        provider_name = item.provider, values = {}}
end

-- The input id of a credential field. The prefix keeps a schema key like
-- "name" from colliding with the connection's own Name input.
function model.field_id(key: any): string
    return "cred_" .. tostring(key)
end

function model.key_of(id: any): string?
    if type(id) ~= "string" then return nil end
    return id:match("^cred_(.+)$")
end

local function caption(label: string, required: boolean): string
    return label .. (required and " *" or "") .. ":"
end

-- The hint under a field is the schema's help. The placeholder is not part
-- of it any more: the SDK input draws it inside the empty field and never
-- sends it.
function model.hint(field: any): string
    return text(field.help)
end

-- The height of a hint in rows. Help texts run to a few hundred characters
-- (Slack's names five scopes); two wrapped rows show the gist, and the last
-- row is cut with "…" by the label itself.
model.HINT_ROWS = 2

local function field_row(caption_text: string, control: any): any
    return {kind = "row", size = 2, gap = 1, children = {
        {kind = "label", size = model.LABEL_WIDTH, text = caption_text},
        control,
    }}
end

local function hint_row(line: string): any
    return {kind = "row", size = model.HINT_ROWS, gap = 1, children = {
        {kind = "label", size = model.LABEL_WIDTH, text = ""},
        {kind = "label", text = line, wrap = true},
    }}
end

-- form_tree(form, busy) — the sheet for "New…" (a provider's credential form)
-- and for "Properties…" (the name only; credentials are fixed, see
-- CREDENTIALS_FIXED). `busy` disables the buttons while a request runs.
function model.form_tree(form: any, busy: any): any
    local children: any = {}
    local new = form.mode == "new"
    local heading = new and ("New connection: " .. form.provider.title)
        or ("Properties: " .. (form.name ~= "" and form.name or "(unnamed)"))
    children[#children + 1] = {kind = "label", size = 1, text = heading}
    children[#children + 1] = {kind = "label", size = 1, text = ""}
    children[#children + 1] = field_row(caption("Name", true), {kind = "input", id = "f_name", text = form.name})

    if new then
        children[#children + 1] = field_row(caption("Description", false),
            {kind = "input", id = "f_description", text = form.description})
        for _, field in ipairs(form.provider.fields) do
            local id = model.field_id(field.key)
            if field.type == "checkbox" then
                children[#children + 1] = {kind = "row", size = 1, gap = 1, children = {
                    {kind = "label", size = model.LABEL_WIDTH, text = ""},
                    {kind = "checkbox", id = id, checked = form.values[field.key] == true,
                        text = field.label .. (field.required and " *" or "")},
                }}
            elseif field.type == "select" then
                children[#children + 1] = field_row(caption(field.label, field.required), {
                    kind = "select", id = id, value = form.values[field.key],
                    options = model.select_options(field),
                })
            else
                children[#children + 1] = field_row(caption(field.label, field.required), {
                    kind = "input", id = id, text = text(form.values[field.key]),
                    password = field.type == "password",
                    placeholder = field.placeholder ~= "" and field.placeholder or nil,
                })
            end
            local line = model.hint(field)
            if line ~= "" then children[#children + 1] = hint_row(line) end
        end
    else
        children[#children + 1] = {kind = "row", size = 1, gap = 1, children = {
            {kind = "label", size = model.LABEL_WIDTH, text = "Provider:"},
            {kind = "label", text = form.provider_name ~= "" and form.provider_name or "none"},
        }}
        children[#children + 1] = {kind = "row", size = 1, gap = 1, children = {
            {kind = "label", size = model.LABEL_WIDTH, text = "Description:"},
            {kind = "label", text = form.description ~= "" and form.description or "none"},
        }}
        children[#children + 1] = {kind = "label", size = 1, text = ""}
        children[#children + 1] = {kind = "label", size = 1, text = model.CREDENTIALS_FIXED}
    end

    children[#children + 1] = {kind = "label", text = ""}
    local buttons: any
    if new then
        buttons = {
            {kind = "button", id = "submit", size = 12, text = form.provider.submit_label, default = true, disabled = busy == true},
            {kind = "button", id = "save", size = 10, text = "Save", disabled = busy == true},
            {kind = "button", id = "cancel", size = 10, text = "Cancel"},
        }
    else
        buttons = {
            {kind = "button", id = "save", size = 10, text = "Save", default = true, disabled = busy == true},
            {kind = "button", id = "props_test", size = 10, text = "Test", disabled = busy == true},
            {kind = "button", id = "cancel", size = 10, text = "Cancel"},
        }
    end
    children[#children + 1] = {kind = "row", size = 2, gap = 1, align = "right", children = buttons}
    return {kind = "column", padding = 1, padding_bottom = 0, gap = 0, children = children}
end

-- private_context(provider, form) — what create_connection.lua receives as
-- body.private_context. Only declared keys, never anything else; a checkbox is
-- always a boolean; an EMPTY text field is left out, so an optional field the
-- user did not fill is absent rather than an empty string. Secrets are passed
-- as typed — no trimming, a token's characters are not ours to change.
function model.private_context(provider: any, form: any): any
    local out: {[string]: any} = {}
    for _, field in ipairs(provider.fields) do
        local value = form.values[field.key]
        if field.type == "checkbox" then
            out[field.key] = value == true
        elseif type(value) == "string" and value ~= "" then
            out[field.key] = value
        end
    end
    return out
end

-- check(provider, form, binding?) -> problem or nil
-- The window's own messages first (they use the labels the user sees: "Bot
-- token is required", not "bot_token is required"), then the platform's rule
-- on the exact private_context that would be sent — create_policy, the same
-- validation create_connection.lua runs, against the given binding (a fresh
-- registry.get at create time) or the one discovered with the provider.
function model.check(provider: any, form: any, binding: any?): string?
    if trim(form.name) == "" then return "Name is required" end
    for _, field in ipairs(provider.fields) do
        if field.required and field.type ~= "checkbox" then
            local value = form.values[field.key]
            if type(value) ~= "string" or value == "" then return field.label .. " is required" end
        end
    end
    local problem = create_policy.validate_private_context(binding or provider.entry, model.private_context(provider, form))
    if problem then return problem end
    return nil
end

function model.name_of(form: any): string
    return trim(form.name)
end

-- ─── refusals ───────────────────────────────────────────────────────────

-- explain(what, err) — a refusal as text for the status bar. The kind decides
-- the wording, the same rule as the shell's config libraries: a permission
-- refusal must not read as "not found" or as a generic failure, because the
-- fix is different (a policy, not the data).
function model.explain(what: string, err: any): string
    if err == nil then return what .. " failed" end
    local message = tostring(err)
    if errors.is(err, errors.PERMISSION_DENIED) then return what .. ": permission denied — " .. message end
    if errors.is(err, errors.NOT_FOUND) then return what .. ": not found — " .. message end
    return what .. ": " .. message
end

return model
