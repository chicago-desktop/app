-- The failed-logon limit on a fake store: the count, the lock, what clears it.
local test = require("test")
local limit = require("limit")

local INVALID = "The user name or password is incorrect."

local function fake_store(): any
    local store: any = {values = {}, ttls = {}, broken = false}
    function store:get(key: string): (any, any) return self.values[key], nil end
    function store:set(key: string, value: any, ttl: any): (any, any)
        if self.broken then return false, "the store is full" end
        self.values[key], self.ttls[key] = value, ttl
        return true, nil
    end
    function store:delete(key: string): (any, any)
        local had = self.values[key] ~= nil
        self.values[key] = nil
        return had, nil
    end
    return store
end

-- A logon check that records that it was asked.
local function checker(answer: any): any
    local asked: any = {count = 0}
    function asked.check(): any
        asked.count = asked.count + 1
        local copy: any = {}
        for k, v in pairs(answer) do copy[k] = v end
        return copy
    end
    return asked
end

local WRONG = {success = false, error = INVALID, counted = true}
local RIGHT = {success = true, token = "t"}

local function define_tests()
    test.describe("Failed terminal logons", function()
        test.it("ten wrong passwords lock the name, and the eleventh is not even checked", function()
            local store = fake_store()
            local wrong = checker(WRONG)
            for attempt = 1, 9 do
                local result = limit.guard(store, "alice", wrong.check)
                test.eq(result.error, INVALID, "attempt " .. attempt)
            end
            local tenth = limit.guard(store, "alice", wrong.check)
            test.is_true(tenth.success == false)
            test.is_true(string.find(tostring(tenth.error), "Too many failed logons", 1, true) ~= nil,
                "the tenth failure says the name is now locked: " .. tostring(tenth.error))
            test.eq(wrong.count, 10)

            local right = checker(RIGHT)
            local locked = limit.guard(store, "alice", right.check)
            test.is_true(locked.success == false, "even the right password waits out the lock")
            test.eq(right.count, 0, "the password of a locked name is not checked")
            test.is_true(string.find(tostring(locked.error), "15 minutes", 1, true) ~= nil, tostring(locked.error))
            test.eq(store.ttls["logon.failures:alice"], 15 * 60, "the count expires on its own")
        end)

        test.it("counts the name however it is typed, and only that name", function()
            local store = fake_store()
            local wrong = checker(WRONG)
            for _ = 1, 5 do limit.guard(store, "ALICE", wrong.check) end
            for _ = 1, 5 do limit.guard(store, "alice", wrong.check) end
            test.not_nil(limit.blocked(store, "Alice"))
            test.is_nil(limit.blocked(store, "bob"), "another name keeps its attempts")
        end)

        test.it("a success clears the count", function()
            local store = fake_store()
            local wrong = checker(WRONG)
            for _ = 1, 9 do limit.guard(store, "alice", wrong.check) end
            local result = limit.guard(store, "alice", checker(RIGHT).check)
            test.is_true(result.success)
            for _ = 1, 9 do limit.guard(store, "alice", wrong.check) end
            test.is_nil(limit.blocked(store, "alice"), "nine after a success is nine, not eighteen")
        end)

        test.it("does not count what is not a guess: an inactive account, a failed check", function()
            local store = fake_store()
            local other = checker({success = false, error = "The account is not active (blocked)."})
            for _ = 1, 20 do limit.guard(store, "alice", other.check) end
            test.is_nil(limit.blocked(store, "alice"))
        end)

        test.it("hands the shell the answer without its own flag", function()
            local store = fake_store()
            local wrong = limit.guard(store, "alice", checker(WRONG).check)
            test.is_nil(wrong.counted)
            local right = limit.guard(store, "alice", checker(RIGHT).check)
            test.is_nil(right.counted)
            test.eq(right.token, "t")
        end)

        test.it("a failure that cannot be counted says so instead of 'wrong password'", function()
            local store = fake_store()
            store.broken = true
            local result = limit.guard(store, "alice", checker(WRONG).check)
            test.is_true(result.success == false)
            test.is_true(string.find(tostring(result.error), "could not be counted", 1, true) ~= nil,
                tostring(result.error))
            test.is_true(string.find(tostring(result.error), "the store is full", 1, true) ~= nil)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
