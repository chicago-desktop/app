-- Logging on to the Windows 95 shell from a terminal: name and password →
-- an application session.
--
-- Called by the shell through `funcs` (it reads the function's name from
-- WINDOWS_LOGON_FUNC), and runs under its OWN actor with
-- permissions on the users database: the shell is not given them, and the
-- code of workshop windows arrives over HTTP and must not reach the password
-- table.
--
-- The steps are the web logon's (kickside.users.api:login), in the same
-- order: find the user with groups, check the status, check the password,
-- mint a session. The session is indistinguishable from a web logon: the same
-- token_store, the same 24 hours, `/user/me` and sharing see it.
--
-- What leaves is a TOKEN, not an actor: objects do not cross the `funcs`
-- boundary, and the token store on the shell's side restores the actor and
-- the scope from it.
--
-- Unlike the web logon, this one limits failures (app.desktop:logon_limit):
-- over SSH it is the only door, and every connection would bring fresh
-- attempts.

local consts = require("consts")
local user_repo = require("user_repo")
local user_groups_repo = require("user_groups_repo")
local session = require("session")
local format = require("format")
local limit = require("limit")
local store = require("store")
local keys = require("keys")

local INVALID = "The user name or password is incorrect."
local ATTEMPTS = "app.desktop:logon_attempts"

local function trim(value: any): string
    if type(value) ~= "string" then return "" end
    return (value:gsub("^%s*(.-)%s*$", "%1"))
end

-- issue(user) -> result: a session for an account that passed its check.
local function issue(user: any): any
    local minted, mint_err = session.mint(user, {source = "tui_desktop"}, {source = "tui_desktop"})
    if not minted then
        return {success = false, error = "Session not issued: " .. tostring(mint_err)}
    end

    -- The name is app.common:format's display_name — the same rule
    -- app.desktop:user_name answers with when the Start menu is refreshed.
    return {
        success = true,
        token = minted.token,
        user_id = tostring(user.user_id),
        display_name = format.display_name(user),
        email = user.email,
        expiration = minted.expiration,
        is_admin = minted.is_admin == true,
    }
end

-- key_logon(key) -> result: the owner of an SSH key (app.desktop:ssh_keys).
--
-- The key arrives only from the shell, which reads it from its own process
-- context, where the terminal host put it after the client proved it holds
-- the private half. No password and no failure count: a key is not a guess.
-- Whoever may call this function with any key may log on as that key's
-- owner — today the shell, and administrators, who can reset any password
-- anyway.
local function key_logon(key: string): any
    local db, err = keys.open()
    if not db then return {success = false, error = "Logon is unavailable: " .. tostring(err)} end
    local owner, oerr = keys.owner(db, key)
    db:release()
    if oerr then return {success = false, error = "The SSH key could not be checked: " .. oerr} end
    if owner == nil then return {success = false, error = "This SSH key is not registered to any account."} end
    local user, uerr = user_groups_repo.get_user_with_groups(owner)
    if uerr or not user then
        return {success = false, error = "The account of this SSH key could not be read: " .. tostring(uerr)}
    end
    if user.status ~= consts.USER_STATUS.ACTIVE then
        return {success = false, error = "The account is not active (" .. tostring(user.status) .. ")."}
    end
    local result = issue(user)
    return result
end

-- check(login, password) -> result; `counted` marks a failure that is a guess.
local function check(login: string, password: string): any
    local user, err = user_groups_repo.get_user_with_groups(login)
    if err or not user then
        if err == consts.ERROR.USER_NOT_FOUND or not user then
            return {success = false, error = INVALID, counted = true}
        end
        return {success = false, error = "Check failed: " .. tostring(err)}
    end
    if user.status ~= consts.USER_STATUS.ACTIVE then
        return {success = false, error = "The account is not active (" .. tostring(user.status) .. ")."}
    end

    local valid = user_repo.verify_password(login, password)
    if not valid then return {success = false, error = INVALID, counted = true} end

    local result = issue(user)
    return result
end

local function handler(args: any): any
    if type(args) == "table" and type(args.ssh_key) == "string" and args.ssh_key ~= "" then
        local result = key_logon(args.ssh_key)
        return result
    end
    local login = trim(type(args) == "table" and args.login or nil)
    local password = type(args) == "table" and type(args.password) == "string" and args.password or ""
    if login == "" then return {success = false, error = "Type a user name."} end
    if password == "" then return {success = false, error = "Type a password."} end

    -- Without the count there is no limit, and a logon without a limit is
    -- not offered: the refusal names why.
    local attempts, err = store.get(ATTEMPTS)
    if not attempts then
        return {success = false,
            error = "Logon is unavailable: failed logons cannot be counted (" .. tostring(err) .. ")."}
    end
    local result = limit.guard(attempts, login, function()
        local answer = check(login, password)
        return answer
    end)
    attempts:release()
    return result
end

return {handler = handler}
