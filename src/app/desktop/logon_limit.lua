-- Failed logons per user name, counted across connections.
--
-- A limit per connection stops nothing: the next connection starts at zero.
-- So the count lives in a memory store the logon function reaches from every
-- connection, keyed by the name as typed, in any case — a name that does not
-- exist is counted too, or the limit would tell which names do. After
-- MAX_FAILURES the password of that name is not checked at all until
-- WINDOW_SECONDS pass without a counted failure; a success clears the count.
--
-- The rule lives here only: the shell's logon screen asks as often as the
-- application lets it.
local limit = {}

limit.MAX_FAILURES = 10
limit.WINDOW_SECONDS = 15 * 60

local function key(login: string): string
    return "logon.failures:" .. string.lower(login)
end

local function count(store: any, login: string): number
    return tonumber((store:get(key(login)))) or 0
end

local function locked(): string
    return string.format("Too many failed logons for this user name. Try again in %d minutes.",
        limit.WINDOW_SECONDS // 60)
end

-- blocked(store, login) -> refusal | nil
function limit.blocked(store: any, login: string): any
    if count(store, login) < limit.MAX_FAILURES then return nil end
    return locked()
end

-- failed(store, login) -> failures so far | nil, error
function limit.failed(store: any, login: string): (any, any)
    local failures = count(store, login) + 1
    local ok, err = store:set(key(login), failures, limit.WINDOW_SECONDS)
    if not ok then return nil, err end
    return failures, nil
end

function limit.passed(store: any, login: string)
    store:delete(key(login))
end

-- guard(store, login, check) -> result
--
-- check() is the logon itself and answers {success, error, ...}; a failure
-- that should count (a wrong password, an unknown name) carries
-- counted = true. The flag stays here: the shell gets what it always got.
-- A failure that could not be counted is not reported as a wrong password:
-- the limit would be off without anyone knowing.
function limit.guard(store: any, login: string, check: any): any
    local refusal = limit.blocked(store, login)
    if refusal then return {success = false, error = refusal} end
    local result: any = check()
    local counted = result.counted == true
    result.counted = nil
    if result.success then
        limit.passed(store, login)
    elseif counted then
        local failures, err = limit.failed(store, login)
        if failures == nil then
            return {success = false, error = "Logon is unavailable: the failed logon could not be counted ("
                .. tostring(err) .. ")."}
        end
        if failures >= limit.MAX_FAILURES then result.error = locked() end
    end
    return result
end

return limit
