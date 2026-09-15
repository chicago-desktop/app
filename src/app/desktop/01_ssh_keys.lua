-- The accounts' SSH public keys (app.desktop:ssh_keys). The statement lives in
-- the library, so the table the migration makes is the table its test makes.
local keys = require("keys")

return require("migration").define(function()
    migration("Create app_ssh_keys table", function()
        database("sqlite", function()
            up(function(db)
                local _, err = db:execute(keys.DDL)
                if err then error("Failed to create app_ssh_keys: " .. err) end
                local _, ierr = db:execute(keys.INDEX)
                if ierr then error("Failed to index app_ssh_keys: " .. ierr) end
            end)
            down(function(db)
                local _, err = db:execute("DROP TABLE IF EXISTS app_ssh_keys;")
                if err then error("Failed to drop app_ssh_keys: " .. err) end
            end)
        end)
        database("postgres", function()
            up(function(db)
                local _, err = db:execute(keys.DDL)
                if err then error("Failed to create app_ssh_keys: " .. err) end
                local _, ierr = db:execute(keys.INDEX)
                if ierr then error("Failed to index app_ssh_keys: " .. ierr) end
            end)
            down(function(db)
                local _, err = db:execute("DROP TABLE IF EXISTS app_ssh_keys;")
                if err then error("Failed to drop app_ssh_keys: " .. err) end
            end)
        end)
    end)
end)
