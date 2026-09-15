-- SSH Keys — the public keys that log the signed-in account on to the
-- Windows 95 desktop over SSH without a password (app.desktop:ssh_keys).
--
-- A window on the shell SDK under the signed-in account's actor. It reads and
-- writes only that account's keys: the id comes from the actor, never from the
-- window's arguments, so no window can attach a key to someone else's
-- account. A desktop without a logon has no account to attach a key to, and
-- the window says so instead of showing an empty list.
local app = require("app")
local security = require("security")
local time = require("time")
local keys = require("keys")
local user_repo = require("user_repo")

local definition: any = {title = "SSH Keys"}

local function account(): (string?, string?)
    local actor = security.actor()
    if not actor then return nil, "Log on to manage your SSH keys." end
    local id = tostring(actor:id())
    local user = user_repo.get(id)
    if type(user) ~= "table" then
        return nil, "This desktop is not logged on to an account, so there is nobody to attach a key to."
    end
    return id, nil
end

local function reload(model: any)
    local db, err = keys.open()
    if not db then
        model.notice = err
        return
    end
    local rows, lerr = keys.list(db, tostring(model.user_id))
    db:release()
    if lerr then
        model.notice = "The keys could not be read: " .. lerr
        return
    end
    model.rows = rows
    if model.selected ~= nil and model.selected > #rows then
        model.selected = #rows > 0 and #rows or nil
    end
end

local function add(model: any)
    local parsed, why = keys.parse(model.draft)
    if not parsed then
        model.notice = why
        return
    end
    local db, err = keys.open()
    if not db then
        model.notice = err
        return
    end
    local ok, aerr = keys.add(db, tostring(model.user_id), parsed, time.now():utc():format(time.RFC3339))
    db:release()
    if not ok then
        model.notice = aerr
        return
    end
    model.draft = ""
    reload(model)
    model.notice = "Added " .. keys.short(parsed.key) .. ": connect with it and the desktop opens without a password."
end

local function remove(model: any)
    local row = model.rows[model.selected or 0]
    if not row then return end
    local db, err = keys.open()
    if not db then
        model.notice = err
        return
    end
    local ok, rerr = keys.remove(db, tostring(model.user_id), tostring(row.key))
    db:release()
    if not ok then
        model.notice = rerr
        return
    end
    reload(model)
    model.notice = "Removed " .. keys.short(row.key) .. "."
end

function definition.init(args: any, context: any): any
    local model: any = {rows = {}, draft = "", selected = nil, notice = nil, user_id = nil, refusal = nil}
    local id, why = account()
    if not id then
        model.refusal = why
        return model
    end
    model.user_id = id
    reload(model)
    return model
end

function definition.update(model: any, action: any, context: any)
    if (action.type == "key" and action.key_type == "esc") or (action.id == "close" and action.type == "activate") then
        context.close()
        return
    end
    if model.refusal then return false end
    if action.id == "draft" and action.type == "change" then
        -- Every keystroke redraws: the input reads its text from the tree.
        model.draft = action.value
    elseif (action.id == "draft" or action.id == "add") and action.type == "activate" then
        add(model)
    elseif action.id == "keys" and action.type == "select" then
        model.selected = action.index
    elseif action.id == "remove" and action.type == "activate" then
        remove(model)
    else
        return false
    end
end

local function status(model: any): string
    if model.notice then return tostring(model.notice) end
    if #model.rows == 0 then return "No keys yet: without one the desktop asks for the password." end
    return #model.rows == 1 and "1 key" or (#model.rows .. " keys")
end

function definition.view(model: any, context: any): any
    if model.refusal then
        return {kind = "column", padding = 1, padding_bottom = 0, gap = 1, children = {
            {kind = "label", alert = true, wrap = true, text = model.refusal},
            {kind = "row", size = 2, align = "right", children = {
                {kind = "button", id = "close", size = 10, text = "Close", default = true},
            }},
        }}
    end
    local items = {}
    for index, row in ipairs(model.rows) do
        local comment = tostring(row.comment or "")
        items[#items + 1] = {id = index, text = keys.short(row.key)
            .. (comment ~= "" and ("  " .. comment) or "")
            .. "  · added " .. tostring(row.created_at or ""):sub(1, 10)}
    end
    return {kind = "column", padding = 1, padding_bottom = 0, gap = 1, children = {
        {kind = "label", size = 2, wrap = true,
            text = "A key listed here opens this account's desktop over SSH without a password. "
                .. "Paste the line from your .pub file:"},
        {kind = "row", size = 2, gap = 1, children = {
            {kind = "input", id = "draft", text = model.draft, placeholder = "ssh-ed25519 AAAA… you@host"},
            {kind = "button", id = "add", size = 10, text = "Add", default = true},
        }},
        {kind = "list", id = "keys", items = items, selected = model.selected},
        {kind = "row", size = 2, gap = 1, align = "right", children = {
            {kind = "button", id = "remove", size = 10, text = "Remove", disabled = model.selected == nil},
            {kind = "button", id = "close", size = 10, text = "Close"},
        }},
        {kind = "statusbar", size = 1, fields = {{text = status(model)}}},
    }}
end

local function main(first: any, id: any, args: any, viewport: any)
    app.run(definition, first, id, args, viewport)
end

return {main = main, definition = definition}
