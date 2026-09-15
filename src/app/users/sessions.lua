-- Session expiries per account (app.users:sessions): when the newest session
-- token of each account runs out, and how that is worded. Users and User
-- Profile both show it; the query and the words live here once.
--
-- Only the payload's actor_id and the expiry column are selected; the token
-- column is never read. json_extract reads the payload the runtime's token
-- store writes ({"created", "actor_id", "expires", …} —
-- service/security/tokenstore/store.go), and actor_id is the user_id login
-- mints the actor with (kickside.users:session). The query is SQLite's.
local sql = require("sql")

local sessions = {}

sessions.SQL = [[
SELECT json_extract(token_value, '$.actor_id') AS actor_id,
       MAX(CAST(strftime('%s', substr(expires_at, 1, 19)) AS INTEGER)) AS expires_unix
FROM kickside_user_auth_tokens
GROUP BY json_extract(token_value, '$.actor_id')
]]

local function text(value: any): string
    if value == nil then return "" end
    return tostring(value)
end

-- expiries(rows) -> {[user_id] = expires_unix} — the newest expiry per
-- account, whatever order the rows come in.
function sessions.expiries(rows: any): any
    local out: {[string]: number} = {}
    for _, raw in ipairs(type(rows) == "table" and rows or {}) do
        local row: any = raw
        local id = text(row.actor_id)
        local at = tonumber(row.expires_unix)
        if id ~= "" and at then
            local seen = out[id]
            if seen == nil or at > seen then out[id] = at end
        end
    end
    return out
end

function sessions.span(seconds: number): string
    local s = math.floor(seconds)
    if s < 60 then return string.format("%ds", s) end
    local m = math.floor(s / 60)
    if m < 60 then return string.format("%dm", m) end
    local h = math.floor(m / 60)
    if h < 48 then return string.format("%dh", h) end
    return string.format("%dd", math.floor(h / 24))
end

-- text(expires_unix, now_unix) — when the session runs out. A session lives
-- 24 hours by default (kickside.users.security:tokens), and "expired" is the
-- answer to "why does every endpoint say Authentication required".
function sessions.text(expires: any, now: any): string
    local at = tonumber(expires)
    if not at then return "no session" end
    local left = at - (tonumber(now) or 0)
    if left <= 0 then return "expired " .. sessions.span(-left) .. " ago" end
    return "expires in " .. sessions.span(left)
end

-- read(db_resource) -> {[user_id] = expires_unix}, err | nil
-- The caller words the error (its own `explain`); the map is empty then.
function sessions.read(db_resource: any): (any, any)
    local db, err = sql.get(text(db_resource))
    if err or not db then return {}, err or "no database" end
    local rows, qerr = db:query(sessions.SQL, {})
    db:release()
    if qerr then return {}, qerr end
    return sessions.expiries(rows), nil
end

return sessions
