-- The logged-on user's display name for the Chicago shell's Start menu.
--
-- The shell calls this through funcs — it reads the name of this function
-- from CHICAGO_USER_FUNC — with {user_id} when the desktop is reread
-- (`desktop.refresh`), so a name changed in the User Profile window reaches the
-- user row at the top of Start. The name is chicago.shell.sdk:format's display_name
-- (the full name, else the e-mail, else the id) — the rule logon.lua uses
-- too, so the row reads the same after a refresh as after the logon that
-- first put it there.
--
-- It runs under its own actor with the least that user_repo.get needs:
-- `db.get` on the application's database and `env.get` of the one variable
-- that names it. The shell itself is given no access to the users table.
--
-- One file, two entries: app.desktop:user_name is the function the shell
-- calls, app.desktop:user_name_rules the same code as a library for the test
-- (a function entry cannot be imported).
local consts = require("consts")
local user_repo = require("user_repo")
local format = require("format")

local M = {}

local function trimmed(value: any): string
    if value == nil then return "" end
    return (tostring(value):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- answer(args, repo) -> {success = true, user_id, name} | {success = false, error}
--
-- `repo` is user_repo; a test passes a stub. An empty id is refused before the
-- repository is asked; a user that is not there and a repository that failed
-- are refused with different words, because the fixes differ.
function M.answer(args: any, repo: any): any
    local id = trimmed(type(args) == "table" and args.user_id or nil)
    if id == "" then return {success = false, error = "user_id is required"} end
    local user, err = repo.get(id)
    if type(user) ~= "table" then
        if err == nil or err == consts.ERROR.USER_NOT_FOUND then
            return {success = false, error = "no such user: " .. id}
        end
        return {success = false, error = "the user could not be read: " .. tostring(err)}
    end
    return {success = true, user_id = tostring(user.user_id or id), name = format.display_name(user)}
end

-- handler(args) — the funcs entry point. The answer is assigned before it is
-- returned: a bare `return <call>(...)` at the end of an entry function is the
-- go-lua tail-call trap.
function M.handler(args: any): any
    local result = M.answer(args, user_repo)
    return result
end

return M
