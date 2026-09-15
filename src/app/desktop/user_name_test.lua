-- The Start menu's user name, answered for the shell: pure over a stub repo.
local test = require("test")
local user_name = require("user_name")
local consts = require("consts")

local USERS: any = {
    u1 = {user_id = "u1", email = "root@example.com", full_name = "Pavel B."},
    u2 = {user_id = "u2", email = "noname@example.com", full_name = ""},
}

-- A user_repo that answers from a table, the way user_repo.get answers:
-- the row, or nil and USER_NOT_FOUND. `calls` counts the reads.
local function repo(users: any): any
    local stub: any = {calls = 0}
    stub.get = function(id: any): (any, any)
        stub.calls = stub.calls + 1
        local found = users[id]
        if found then return found, nil end
        return nil, consts.ERROR.USER_NOT_FOUND
    end
    return stub
end

local function define_tests()
    test.describe("The Start menu's user name", function()
        -- The naming rule itself is tested with app.common:format; here only
        -- that the answer carries it.
        test.it("answers the full name, else the e-mail, as logon does", function()
            local named = user_name.answer({user_id = "u1"}, repo(USERS))
            test.eq(named.success, true)
            test.eq(named.name, "Pavel B.")
            test.eq(named.user_id, "u1")
            test.eq(user_name.answer({user_id = "u2"}, repo(USERS)).name, "noname@example.com",
                "an empty full name falls back to the e-mail")
            test.eq(user_name.answer({user_id = " u1 "}, repo(USERS)).name, "Pavel B.", "the id is trimmed")
        end)

        test.it("refuses an empty id without asking the repository", function()
            for _, args in ipairs({{}, {user_id = ""}, {user_id = "   "}}) do
                local stub = repo(USERS)
                local refused = user_name.answer(args, stub)
                test.eq(refused.success, false)
                test.eq(refused.error, "user_id is required")
                test.is_nil(refused.name)
                test.eq(stub.calls, 0, "no read for an empty id")
            end
            test.eq(user_name.answer(nil, repo(USERS)).error, "user_id is required")
        end)

        test.it("names a missing user and a failed read differently", function()
            local missing = user_name.answer({user_id = "u9"}, repo(USERS))
            test.eq(missing.success, false)
            test.eq(missing.error, "no such user: u9")
            local broken: any = {get = function() return nil, "database is down" end}
            local failed = user_name.answer({user_id = "u1"}, broken)
            test.eq(failed.success, false)
            test.eq(failed.error, "the user could not be read: database is down")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
