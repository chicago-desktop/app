-- Users model: pure, so every case runs on stub rows, stub tokens and a stub
-- catalog; the e-mail and password rules are the users module's own consts.
local test = require("test")
local model = require("model")

local NOW = 1789164414
local ADMIN = "app.security:admin"
local USER = "app.security:user"

-- The assignable catalog as list_scopes_func returns it (internal scopes are
-- not in it: include_internal = false).
local SCOPES = {
    {id = ADMIN, label = "Administrator", description = "Full access", source = "builtin", internal = false, enabled = true},
    {id = USER, label = "User", description = "Standard access", source = "builtin", internal = false, enabled = true},
}

-- list_users.lua's rows: user_repo.list() plus security_groups.
local function rows(): any
    return {
        {user_id = "u-ops", email = "ops@example.com", full_name = "", status = "active",
            created_at = "2026-09-01T10:00:00Z", security_groups = {USER}},
        {user_id = "u-root", email = "root@example.com", full_name = "Root", status = "active",
            created_at = "2026-08-01T10:00:00Z", security_groups = {ADMIN, USER}},
        {email = "broken@example.com"},
    }
end

local function sample(): any
    return model.users(rows(), model.tokens({
        {actor_id = "u-root", expires_unix = NOW + 19 * 3600},
        {actor_id = "u-root", expires_unix = NOW - 3600},
        {actor_id = "u-ops", expires_unix = NOW - 2 * 3600},
        {actor_id = "", expires_unix = NOW},
    }))
end

local function ctx(extra: any?): any
    local out: any = {self_id = "u-root", admin_group = ADMIN, admin_count = 1}
    for key, value in pairs(extra or {}) do out[key] = value end
    return out
end

local ALL = {list = true, create = true, update = true, delete = true, get_groups = true, set_groups = true}

local function walk(node: any, visit: any)
    visit(node)
    for _, child in ipairs(type(node.children) == "table" and node.children or {}) do walk(child, visit) end
end

local function by_id(tree: any, id: string): any
    local found = nil
    walk(tree, function(node) if node.id == id then found = node end end)
    return found
end

local function has_text(tree: any, needle: string): boolean
    local found = false
    walk(tree, function(node)
        if node.kind == "label" and tostring(node.text):find(needle, 1, true) then found = true end
    end)
    return found
end

local function define_tests()
    test.describe("Users model: rows", function()
        test.it("joins accounts with groups and their newest token, sorted by e-mail", function()
            local users = sample()
            test.eq(#users, 2, "a row without user_id is not an account")
            test.eq(users[1].email, "ops@example.com")
            test.eq(users[2].email, "root@example.com")
            test.eq(users[2].token, NOW + 19 * 3600, "the newest expiry wins, whatever the row order")
            local cells = model.table_rows(users, SCOPES, NOW)
            test.eq(cells[1].cells[1], "(no name)")
            test.eq(cells[2].cells[3], "Administrator, User", "groups by the catalog's labels")
            test.eq(cells[2].cells[4], "Active")
            test.eq(cells[2].cells[5], "expires in 19h")
            test.eq(cells[1].cells[5], "expired 2h ago")
        end)

        test.it("words a session's end the way the operator token trap needs it", function()
            test.eq(model.token_text(nil, NOW), "no session")
            test.eq(model.token_text(NOW + 30, NOW), "expires in 30s")
            test.eq(model.token_text(NOW + 45 * 60, NOW), "expires in 45m")
            test.eq(model.token_text(NOW - 3 * 86400, NOW), "expired 3d ago")
            test.eq(model.token_text(NOW, NOW), "expired 0s ago", "the second it ends it is over")
        end)

        test.it("names a group outside the catalog by its id", function()
            test.eq(model.group_label(SCOPES, "app.security:ingress"), "app.security:ingress")
            test.eq(model.groups_text({groups = {}}, SCOPES), "(none)")
        end)
    end)

    test.describe("Users model: refusals", function()
        test.it("refuses to delete the signed-in account and the last administrator", function()
            local users = sample()
            local root, ops = users[2], users[1]
            test.eq(model.delete_refusal(root, ctx()), "you cannot delete the account you are signed in with")
            test.eq(model.delete_refusal(root, ctx({self_id = "u-ops"})),
                "root@example.com is the last administrator: give another account the administrator group first")
            test.is_nil(model.delete_refusal(root, ctx({self_id = "u-ops", admin_count = 2})))
            test.is_nil(model.delete_refusal(ops, ctx()), "a plain user may go")
            -- A nil in a table constructor creates no key, so the count is taken out after.
            local uncounted = ctx({self_id = "u-ops", admin_problem = "db down"})
            uncounted.admin_count = nil
            test.eq(model.delete_refusal(root, uncounted),
                "administrators could not be counted (db down)", "an unknown count is not a count of two")
            local NOT_CONFIGURED = "the administrator group is not configured, so the last administrator cannot be protected"
            test.eq(model.delete_refusal(ops, ctx({admin_group = ""})), NOT_CONFIGURED,
                "without the group nobody can be told apart from an administrator")
            test.eq(model.groups_refusal(ops, {USER}, ctx({admin_group = ""})), NOT_CONFIGURED,
                "the same for a group change")
        end)

        test.it("refuses a deactivation and an administrator removal on the same grounds", function()
            local users = sample()
            local root = users[2]
            test.is_nil(model.status_refusal(root, "active", ctx()))
            test.eq(model.status_refusal(root, "suspended", ctx()), "you cannot deactivate the account you are signed in with")
            test.is_true(tostring(model.status_refusal(root, "inactive", ctx({self_id = "u-ops"}))):find("last administrator", 1, true) ~= nil)
            test.eq(model.groups_refusal(root, {USER}, ctx()),
                "you cannot take the administrator group from the account you are signed in with")
            test.is_nil(model.groups_refusal(root, {ADMIN}, ctx()))
            test.is_nil(model.groups_refusal(root, {USER}, ctx({self_id = "u-ops", admin_count = 2})))
        end)

        test.it("names the gate a refusal comes from", function()
            test.eq(model.not_granted("delete"), "Delete: not granted to your account (kickside.users.api:delete_user.endpoint)")
            test.eq(model.explain("users", "Database operation failed: locked"), "users: Database operation failed: locked")
            test.eq(model.explain("users", nil), "users failed", "the stand's wording, app.common:format")
        end)
    end)

    test.describe("Users model: the list sheet", function()
        test.it("disables Delete for the signed-in account and says why", function()
            local users = sample()
            local state = {users = users, selected_id = "u-root", access = ALL, ctx = ctx(), scopes = SCOPES}
            local tree = model.list_tree(state, NOW)
            test.eq(by_id(tree, "delete").disabled, true)
            test.is_true(has_text(tree, "Delete: you cannot delete the account you are signed in with"))
            test.eq(by_id(tree, "props").disabled, false)
            state.selected_id = "u-ops"
            tree = model.list_tree(state, NOW)
            test.eq(by_id(tree, "delete").disabled, false)
            test.eq(model.reason_line(state, users[1]), "")
        end)

        test.it("disables what the account is not granted and lists it", function()
            local users = sample()
            local state = {users = users, selected_id = "u-ops", ctx = ctx(), scopes = SCOPES,
                access = {list = true, get_groups = true}}
            local tree = model.list_tree(state, NOW)
            test.eq(by_id(tree, "new").disabled, true)
            test.eq(by_id(tree, "props").disabled, true)
            test.eq(by_id(tree, "delete").disabled, true)
            test.eq(by_id(tree, "groups").disabled, false)
            test.is_true(has_text(tree, "Not granted to your account: New…, Properties…, Delete"))
        end)

        test.it("says why the list is empty when listing is not granted", function()
            local state = {users = {}, selected_id = nil, ctx = ctx(), scopes = {}, access = {},
                failure = model.not_granted("list")}
            local tree = model.list_tree(state, NOW)
            test.is_nil(by_id(tree, "users"))
            test.is_true(has_text(tree, "The accounts could not be read."))
            test.eq(model.status_line(state), "Users: not granted to your account (kickside.users.api:list_users.endpoint)")
        end)

        test.it("counts accounts and administrators and names who is signed in", function()
            local state = {users = sample(), ctx = ctx(), more = false}
            test.eq(model.status_line(state), "2 users, 1 administrator · signed in as root@example.com")
            state.token_problem = "tokens: no database"
            test.eq(model.status_line(state), "2 users, 1 administrator · signed in as root@example.com · tokens: no database")
            state.status = "saved"
            test.eq(model.status_line(state), "saved", "a message of the moment wins")
        end)
    end)

    test.describe("Users model: forms", function()
        test.it("checks a new account with the module's own rules", function()
            local form = model.new_form(USER)
            test.eq(model.check_new(form), "E-mail is required")
            form.email = "not-an-email"
            test.eq(model.check_new(form), "Invalid email format")
            form.email = "  New.Person@Example.com "
            test.eq(model.check_new(form), "Password is required")
            form.password = "short"
            test.eq(model.check_new(form), "Password must be at least 8 characters")
            form.password, form.confirm = "long enough", "long enougH"
            test.eq(model.check_new(form), "The passwords do not match")
            form.confirm = "long enough"
            test.is_nil(model.check_new(form))
            form.name = "  Person  "
            local data, groups = model.create_payload(form, SCOPES)
            test.eq(data.email, "new.person@example.com")
            test.eq(data.full_name, "Person")
            test.eq(data.status, "active")
            test.eq(#groups, 1)
            test.eq(groups[1], USER, "the default group is chosen")
            form.chosen[ADMIN] = true
            local _, both = model.create_payload(form, SCOPES)
            test.eq(both[1], ADMIN, "groups go in the catalog's order")
        end)

        test.it("sends only what changed in Properties…, and refuses what the handler would drop", function()
            local users = sample()
            local ops = users[1]
            local form = model.props_form(ops)
            local data, problem = model.props_update(form, ops, ctx())
            test.is_nil(data)
            test.is_nil(problem, "nothing changed is not a problem")
            form.name = "Operations"
            data = model.props_update(form, ops, ctx())
            test.eq(data.full_name, "Operations")
            test.is_nil(data.status)
            test.is_nil(data.password)
            form.password = "new password 1"
            _, problem = model.props_update(form, ops, ctx())
            test.eq(problem, "The passwords do not match")
            form.confirm = "new password 1"
            data = model.props_update(form, ops, ctx())
            test.eq(data.password, "new password 1")

            local root = users[2]
            local rform = model.props_form(root)
            rform.name = ""
            _, problem = model.props_update(rform, root, ctx())
            test.eq(problem, "The full name cannot be cleared: the users module keeps the old one")
            rform.name = "Root"
            rform.status = "inactive"
            _, problem = model.props_update(rform, root, ctx())
            test.eq(problem, "Status: you cannot deactivate the account you are signed in with")
        end)

        test.it("saves a group set only when it changed and keeps the last administrator", function()
            local users = sample()
            local root, ops = users[2], users[1]
            local form = model.groups_form(ops)
            local groups, problem = model.groups_save(form, ops, SCOPES, ctx())
            test.is_nil(groups)
            test.is_nil(problem, "an unchanged set is not saved")
            form.chosen[ADMIN] = true
            groups = model.groups_save(form, ops, SCOPES, ctx())
            test.eq(#groups, 2)
            test.eq(groups[1], ADMIN)

            local rform = model.groups_form(root)
            rform.chosen[ADMIN] = nil
            _, problem = model.groups_save(rform, root, SCOPES, ctx({self_id = "u-ops"}))
            test.is_true(tostring(problem):find("last administrator", 1, true) ~= nil)

            local sso = model.users({{user_id = "u-sso", email = "sso@example.com", status = "active",
                security_groups = {USER, "idp:engineering"}}}, {})[1]
            local sform = model.groups_form(sso)
            sform.chosen[ADMIN] = true
            _, problem = model.groups_save(sform, sso, SCOPES, ctx())
            test.eq(problem, "sso@example.com holds idp:engineering, which the catalog does not offer: saving here would remove it")
        end)

        test.it("hides typed passwords and shows the chosen groups as checked boxes", function()
            local tree = model.new_tree(model.new_form(USER), SCOPES, false)
            test.eq(by_id(tree, "f_password").password, true)
            test.eq(by_id(tree, "f_confirm").password, true)
            test.eq(by_id(tree, "g:" .. USER).checked, true)
            test.eq(by_id(tree, "g:" .. ADMIN).checked, false)
            test.eq(model.group_of("g:" .. ADMIN), ADMIN)
            test.is_nil(model.group_of("f_name"))

            local props = model.props_tree(model.props_form(sample()[1]), false)
            test.eq(by_id(props, "f_password").password, true)
            test.eq(by_id(props, "f_status").value, "active")

            local users = sample()
            local groups = model.groups_tree(model.groups_form(users[1]), users[1], SCOPES, false, false)
            test.eq(by_id(groups, "save").disabled, true)
            test.eq(by_id(groups, "g:" .. USER).disabled, true)
            test.is_true(has_text(groups, model.not_granted("set_groups")))
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
