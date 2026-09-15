-- SSH public keys of the application's accounts: a key registered here logs
-- its owner on to the Windows 95 desktop over SSH without a password.
--
-- Three readers, one rule each, all here:
--
--   * the SSH host (terminal.ssh `key_owner`, through app.desktop:ssh_key_owner)
--     accepts an offered key only if it is registered, so a client with
--     several keys gets to try the next one instead of being let in on the
--     first and asked for a password;
--   * the logon function (app.desktop:logon {ssh_key}) turns the key the host
--     verified into its owner's session;
--   * the "SSH Keys" window adds and removes the logged-on person's own keys.
--
-- A key is stored in its canonical form "type base64" — exactly what the host
-- sends (ssh.MarshalAuthorizedKey without the newline) — so the lookup is an
-- equality, and a comment or a trailing space can never make a registered
-- key look unknown. One key belongs to one account: the owner is the answer
-- to "who is this", and two answers would be none.
local sql = require("sql")

local keys = {}

keys.DB = "app:db"
keys.TABLE = "app_ssh_keys"

-- The table, for the migration and for the test that builds it in a scratch
-- database: one definition, not two that drift apart.
keys.DDL = [[
    CREATE TABLE app_ssh_keys (
        key TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        type TEXT NOT NULL,
        comment TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL
    )
]]
keys.INDEX = "CREATE INDEX app_ssh_keys_user_idx ON app_ssh_keys (user_id)"

-- The key types an OpenSSH client offers.
keys.TYPES = {
    ["ssh-ed25519"] = true,
    ["ssh-rsa"] = true,
    ["ecdsa-sha2-nistp256"] = true,
    ["ecdsa-sha2-nistp384"] = true,
    ["ecdsa-sha2-nistp521"] = true,
    ["sk-ssh-ed25519@openssh.com"] = true,
    ["sk-ecdsa-sha2-nistp256@openssh.com"] = true,
}

local function trim(value: any): string
    if type(value) ~= "string" then return "" end
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- parse(line) -> {key, type, comment} | nil, reason
--
-- The line is what the person pastes from their `.pub` file. Options in
-- front of the type (from=, command=, restrict) are refused, not dropped:
-- nothing here would enforce them, and a key its owner restricted must not
-- turn into one that is not.
function keys.parse(line: any): (any, string?)
    local text = trim(line)
    if text == "" then return nil, "Paste a public key: the line from your id_ed25519.pub." end
    if text:find("PRIVATE KEY", 1, true) then
        return nil, "This is a private key. Paste the .pub file instead, and keep the private one to yourself."
    end
    local kind, blob, comment = text:match("^(%S+)%s+(%S+)%s*(.*)$")
    if kind == nil or not keys.TYPES[kind] then
        return nil, "Not an SSH public key: the line must start with its type (ssh-ed25519, ssh-rsa, ecdsa-sha2-…)."
    end
    if not blob:match("^[A-Za-z0-9+/]+=*$") or #blob < 40 then
        return nil, "The key data after " .. kind .. " is not a valid key."
    end
    return {key = kind .. " " .. blob, type = kind, comment = trim(comment)}, nil
end

-- open() -> db | nil, reason — the application's database.
function keys.open(): (any, string?)
    local db, err = sql.get(keys.DB)
    if not db then return nil, "the database " .. keys.DB .. " is not available: " .. tostring(err) end
    return db, nil
end

-- owner(db, key) -> user_id | nil, error
function keys.owner(db: any, key: any): (string?, string?)
    if type(key) ~= "string" or key == "" then return nil, nil end
    local rows, err = db:query("SELECT user_id FROM " .. keys.TABLE .. " WHERE key = $1 LIMIT 1", {key})
    if err then return nil, tostring(err) end
    if type(rows) ~= "table" or rows[1] == nil then return nil, nil end
    return tostring(rows[1].user_id), nil
end

-- list(db, user_id) -> {{key, type, comment, created_at}, …} | nil, error
function keys.list(db: any, user_id: string): (any, string?)
    local rows, err = db:query("SELECT key, type, comment, created_at FROM " .. keys.TABLE
        .. " WHERE user_id = $1 ORDER BY created_at, key", {user_id})
    if err then return nil, tostring(err) end
    return type(rows) == "table" and rows or {}, nil
end

-- add(db, user_id, parsed, now) -> true | nil, reason
function keys.add(db: any, user_id: string, parsed: any, now: string): (boolean?, string?)
    local owner, oerr = keys.owner(db, parsed.key)
    if oerr then return nil, "the key could not be checked: " .. oerr end
    if owner == user_id then return nil, "This key is already added." end
    if owner ~= nil then return nil, "This key belongs to another account." end
    local _, err = db:execute("INSERT INTO " .. keys.TABLE
        .. " (key, user_id, type, comment, created_at) VALUES ($1, $2, $3, $4, $5)",
        {parsed.key, user_id, parsed.type, parsed.comment or "", now})
    if err then return nil, "the key was not saved: " .. tostring(err) end
    return true, nil
end

-- remove(db, user_id, key) -> true | nil, reason — only the owner's own key.
function keys.remove(db: any, user_id: string, key: string): (boolean?, string?)
    local _, err = db:execute("DELETE FROM " .. keys.TABLE .. " WHERE key = $1 AND user_id = $2", {key, user_id})
    if err then return nil, "the key was not removed: " .. tostring(err) end
    return true, nil
end

-- short(key) -> "ssh-ed25519 AAAAC3Nz…kXq2" — enough to tell keys apart in a list.
function keys.short(key: any): string
    local text = tostring(key or "")
    local kind, blob = text:match("^(%S+)%s+(%S+)$")
    if kind == nil then return text end
    if #blob <= 16 then return text end
    return kind .. " " .. blob:sub(1, 8) .. "…" .. blob:sub(-8)
end

return keys
