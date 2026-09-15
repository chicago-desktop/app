-- Is this SSH key registered to an account? Asked by the SSH host
-- (terminal.ssh `key_owner`) while a client offers its keys one by one.
--
-- {key = "type base64"} → {known = true, user_id} | {known = false}
--
-- It answers only whether, and whose: the session itself is issued later by
-- app.desktop:logon, once the host has seen the client prove it holds the
-- private half. A lookup that fails says so in `error`; the host logs it and
-- treats the key as unknown, so a broken table costs a password prompt, not
-- a way in.
local keys = require("keys")

local function handler(args: any): any
    local key = type(args) == "table" and args.key or nil
    if type(key) ~= "string" or key == "" then return {known = false, error = "no key given"} end
    local db, err = keys.open()
    if not db then return {known = false, error = err} end
    local owner, oerr = keys.owner(db, key)
    db:release()
    if oerr then return {known = false, error = oerr} end
    if owner == nil then return {known = false} end
    return {known = true, user_id = owner}
end

return {handler = handler}
