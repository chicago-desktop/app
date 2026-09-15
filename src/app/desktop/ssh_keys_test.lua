-- Account SSH keys: reading a pasted key, and the table rules (one owner per
-- key, only one's own key is removed). The table tests run on a scratch table
-- with a random name, never on app_ssh_keys: running the suite must not touch
-- anybody's keys.
local test = require("test")
local keys = require("keys")
local sql = require("sql")
local uuid = require("uuid")

local BLOB = "AAAAC3NzaC1lZDI1NTE5AAAAI" .. string.rep("x", 30) .. "LAST8xyz"
local ED = "ssh-ed25519 " .. BLOB
local OTHER = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI" .. string.rep("y", 30) .. "OTHERkey"

local function has(text: any, part: string): boolean
    return string.find(tostring(text), part, 1, true) ~= nil
end

local function define_tests()
    test.describe("Reading a pasted public key", function()
        test.it("keeps the type and the data as the key, and the rest as the comment", function()
            local parsed, why = keys.parse("  " .. ED .. " alice@laptop \n")
            test.is_nil(why)
            test.eq(parsed.key, ED, "the canonical form the SSH host looks keys up by")
            test.eq(parsed.type, "ssh-ed25519")
            test.eq(parsed.comment, "alice@laptop")
        end)

        test.it("refuses options in front of the key, a private key, junk and nothing", function()
            local _, options = keys.parse('from="10.0.0.1" ' .. ED)
            test.is_true(has(options, "must start with its type"), tostring(options))
            local _, private = keys.parse("-----BEGIN OPENSSH PRIVATE KEY-----")
            test.is_true(has(private, "private key"), tostring(private))
            local _, junk = keys.parse("ssh-ed25519 not-base64!!")
            test.is_true(has(junk, "not a valid key"), tostring(junk))
            local _, empty = keys.parse("   ")
            test.is_true(has(empty, "Paste a public key"), tostring(empty))
        end)

        test.it("shortens a key to its type and both ends of the data", function()
            test.eq(keys.short(ED), "ssh-ed25519 AAAAC3Nz…LAST8xyz")
            test.eq(keys.short("ssh-ed25519 short"), "ssh-ed25519 short")
        end)
    end)

    test.describe("Keys of accounts", function()
        test.it("one owner per key; the owner lists and removes it, nobody else can", function()
            local db = sql.get(keys.DB)
            test.not_nil(db, "the harness database")
            local real = keys.TABLE
            local scratch = "app_ssh_keys_t" .. string.gsub(tostring(uuid.v4()), "-", "")
            keys.TABLE = scratch
            local ddl = string.gsub(keys.DDL, "app_ssh_keys", scratch)
            local _, cerr = db:execute(ddl)
            test.is_nil(cerr)

            local first = assert(keys.parse(ED .. " alice@laptop"))
            test.is_true(keys.add(db, "alice", first, "2026-09-15T10:00:00Z") == true)
            test.eq(keys.owner(db, ED), "alice")
            test.is_nil(keys.owner(db, OTHER), "a key nobody added has no owner")

            local listed = keys.list(db, "alice")
            test.eq(#listed, 1)
            test.eq(listed[1].comment, "alice@laptop")
            test.eq(#keys.list(db, "bob"), 0)

            local _, again = keys.add(db, "alice", first, "2026-09-15T10:01:00Z")
            test.is_true(has(again, "already added"), tostring(again))
            local _, taken = keys.add(db, "bob", first, "2026-09-15T10:02:00Z")
            test.is_true(has(taken, "belongs to another account"), tostring(taken))

            keys.remove(db, "bob", ED)
            test.eq(keys.owner(db, ED), "alice", "bob cannot remove alice's key")
            keys.remove(db, "alice", ED)
            test.is_nil(keys.owner(db, ED))

            db:execute("DROP TABLE " .. scratch)
            keys.TABLE = real
            db:release()
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
