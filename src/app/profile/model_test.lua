-- User Profile model: pure, so every case runs on stub rows; the password and
-- name limits are the users module's own consts.
local test = require("test")
local model = require("model")

local NOW = 1789164414

-- profile.list() rows in the shape list.lua builds them: the declarations of
-- kickside/users and kickside/ui with the actor's values.
local function rows(): any
    return {
        {namespace = "kickside.profile", key = "timezone", value_type = "string", value = "Asia/Dubai",
            default = "UTC", is_default = false, editable = true, visibility = "self", schema = {maxLength = 64}},
        {namespace = "kickside.profile", key = "display_name", value_type = "string", value = "Pavel",
            default = "", is_default = false, editable = true, visibility = "public", schema = {maxLength = 80}},
        {namespace = "kickside.ui", key = "seen_splashes", value_type = "json", value = {"welcome"},
            default = {}, is_default = false, editable = true, visibility = "self"},
        {namespace = "kickside.profile", key = "locale", value_type = "string", value = "en",
            default = "en", is_default = true, editable = true, visibility = "self", schema = {maxLength = 35}},
        {namespace = "kickside.profile", key = "bio", value_type = "string", value = "",
            default = "", is_default = true, editable = false, visibility = "public", schema = {maxLength = 500}},
    }
end

local IDENTITY = {email = "root@example.com", full_name = "Root"}

local function view(extra: any?): any
    local fields = model.fields(rows())
    local out: any = {target = model.target({user_id = "u-root"}, "u-root", true), identity = IDENTITY,
        groups = {"app.security:admin"}, token = NOW + 19 * 3600, fields = fields, tab = 1,
        can = {update_me = true, put_profile = true}, problems = {}}
    for key, value in pairs(extra or {}) do out[key] = value end
    return out
end

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
        if (node.kind == "label" or node.kind == "group") and tostring(node.text or node.title):find(needle, 1, true) then
            found = true
        end
    end)
    return found
end

local function find_field(fields: any, key: string): any
    for _, item in ipairs(fields) do
        if item.key == key then return item end
    end
    return nil
end

local function define_tests()
    test.describe("User Profile model: the Start menu after a rename", function()
        test.it("a written name asks the compositor for exactly one refresh", function()
            local requests = model.after_rename({full_name = "Pavel", sets = {}, unsets = {}}, nil)
            test.eq(#requests, 1)
            test.eq(requests[1].topic, "desktop.refresh")
            test.eq(type(requests[1].body), "table")
            test.is_nil(next(requests[1].body), "the same empty body Display Properties sends")
        end)

        test.it("a refused rename, or a save without one, asks for none", function()
            test.eq(#model.after_rename({full_name = "Pavel", sets = {}, unsets = {}}, "permission denied"), 0)
            test.eq(#model.after_rename({sets = {{namespace = "kickside.profile", key = "bio"}}, unsets = {}}, nil), 0)
            test.eq(#model.after_rename(nil, nil), 0)
        end)

        test.it("the written name is in the heading at once, and the sheet is not dirty", function()
            local shown = view()
            shown.identity = {email = "root@example.com", full_name = "Root"}
            local form = model.new_form(shown.identity, shown.fields)
            form.full_name = "Pavel B."
            test.is_true(model.dirty(form))
            model.apply_rename(shown, form, "Pavel B.")
            test.eq(model.heading(shown), "Pavel B. <root@example.com>")
            test.eq(form.full_name, "Pavel B.")
            test.is_false(model.dirty(form), "the written name is no longer a pending change")
        end)
    end)

    test.describe("User Profile model: whose profile", function()
        test.it("is the signed-in account's without a target or with its own id", function()
            local own = model.target(nil, "u-1", false)
            test.eq(own.id, "u-1")
            test.eq(own.own, true)
            test.eq(own.full, true)
            test.eq(model.target({user_id = "u-1"}, "u-1", false).own, true)
            test.eq(model.target({user_id = ""}, "u-1", false).id, "u-1", "an empty id is no target")
        end)

        test.it("shows another account in full only to an administrator, and never as own", function()
            local seen = model.target({user_id = "u-2"}, "u-1", false)
            test.eq(seen.own, false)
            test.eq(seen.full, false, "a plain user sees the public fields only")
            local admin = model.target({user_id = "u-2"}, "u-1", true)
            test.eq(admin.own, false)
            test.eq(admin.full, true)
            test.is_nil(model.target(nil, nil, false).id, "no logon, no profile")
        end)
    end)

    test.describe("User Profile model: fields", function()
        test.it("lists the actor's fields sorted, text ones editable as declared", function()
            local fields = model.fields(rows())
            test.eq(#fields, 5)
            test.eq(fields[1].key, "bio")
            test.eq(fields[5].namespace, "kickside.ui")
            test.eq(find_field(fields, "bio").editable, false, "editable: false in the declaration")
            test.eq(find_field(fields, "timezone").max, 64)
            test.eq(model.value_text(find_field(fields, "seen_splashes")), "(a structured value)")
            test.eq(model.value_text({value_type = "bool", value = true}), "Yes")
            test.eq(model.value_text({value_type = "int", value = 42}), "42")
            test.eq(model.caption(find_field(fields, "display_name")), "Display name:")
        end)

        test.it("keeps another account's public fields only, with its values or the defaults", function()
            test.eq(table.concat(model.public_namespaces(rows()), ","), "kickside.profile")
            local fields = model.public_fields(rows(), {["kickside.profile"] = {display_name = "Ops"}})
            test.eq(#fields, 2, "self-visibility fields are not another user's to see")
            test.eq(fields[1].key, "bio")
            test.eq(fields[1].value, "", "the default where get_namespace gave nothing")
            test.eq(fields[2].value, "Ops")
            test.eq(fields[2].editable, false, "writes always target the actor")
        end)

        test.it("maps a field to its input id and back", function()
            local item = {namespace = "kickside.profile", key = "display_name"}
            test.eq(model.field_id(item), "p:kickside.profile:display_name")
            local ns, key = model.field_of("p:kickside.profile:display_name")
            test.eq(ns, "kickside.profile")
            test.eq(key, "display_name")
            test.is_nil(model.field_of("f_full_name"))
        end)
    end)

    test.describe("User Profile model: saving", function()
        test.it("sends only what changed, and unsets a field typed back to its default", function()
            local fields = model.fields(rows())
            local form = model.new_form(IDENTITY, fields)
            local changes, problem = model.changes(form, fields)
            test.is_nil(changes)
            test.is_nil(problem, "nothing changed is not a problem")
            test.eq(model.dirty(form), false)

            form.full_name = "  Root Admin "
            form.values["p:kickside.profile:timezone"] = "UTC"
            form.values["p:kickside.profile:display_name"] = "P."
            test.eq(model.dirty(form), true)
            changes = model.changes(form, fields)
            test.eq(changes.full_name, "Root Admin")
            test.eq(#changes.sets, 1)
            test.eq(changes.sets[1].key, "display_name")
            test.eq(changes.sets[1].value, "P.")
            test.eq(#changes.unsets, 1)
            test.eq(changes.unsets[1].key, "timezone", "UTC is the declared default")
        end)

        test.it("refuses what the handlers would drop or the declaration forbids", function()
            local fields = model.fields(rows())
            local form = model.new_form(IDENTITY, fields)
            form.full_name = ""
            local _, problem = model.changes(form, fields)
            test.eq(problem, "The full name cannot be cleared: the users module keeps the old one")
            form.full_name = "Root"
            form.values["p:kickside.profile:locale"] = string.rep("x", 36)
            _, problem = model.changes(form, fields)
            test.eq(problem, "Locale is longer than 35 characters")
            form.values["p:kickside.profile:locale"] = "en"
            form.values["p:kickside.profile:bio"] = "typed into a locked field"
            local changes = model.changes(form, fields)
            test.is_nil(changes, "a field the declaration does not let you edit is not sent")
        end)

        test.it("checks a new password with the module's own rule", function()
            test.eq(model.check_password({password = "", confirm = ""}), "Type the new password twice")
            test.eq(model.check_password({password = "short", confirm = "short"}), "Password must be at least 8 characters")
            test.eq(model.check_password({password = "long enough", confirm = "long enougH"}), "The passwords do not match")
            test.is_nil(model.check_password({password = "long enough", confirm = "long enough"}))
            local tree = model.password_tree({password = "", confirm = ""}, false)
            test.eq(by_id(tree, "f_password").password, true)
            test.eq(by_id(tree, "f_confirm").password, true)
            test.is_true(has_text(tree, model.NO_CURRENT))
        end)
    end)

    test.describe("User Profile model: the sheet", function()
        test.it("lets the signed-in account edit its name and fields and change its password", function()
            local v = view()
            local form = model.new_form(v.identity, v.fields)
            local tree = model.sheet(v, form, NOW)
            test.eq(by_id(tree, "f_full_name").disabled, false)
            test.eq(by_id(tree, "password").disabled, false)
            test.eq(by_id(tree, "apply").disabled, true, "nothing to apply yet")
            test.is_true(has_text(tree, "Root <root@example.com>"))
            test.is_true(has_text(tree, "expires in 19h"))
            test.is_true(has_text(tree, "app.security:admin"))
            v.tab = 2
            tree = model.sheet(v, form, NOW)
            test.eq(by_id(tree, "p:kickside.profile:display_name").disabled, false)
            test.eq(by_id(tree, "p:kickside.profile:bio").disabled, true, "not editable by declaration")
            test.is_true(has_text(tree, "(a structured value) (json)"))
        end)

        test.it("disables what the gates do not grant and says why", function()
            local v = view({can = {update_me = false, put_profile = false}})
            local form = model.new_form(v.identity, v.fields)
            local tree = model.sheet(v, form, NOW)
            test.eq(by_id(tree, "f_full_name").disabled, true)
            test.eq(by_id(tree, "password").disabled, true)
            test.is_true(has_text(tree, model.not_granted("update_me")))
            v.tab = 2
            tree = model.sheet(v, form, NOW)
            test.eq(by_id(tree, "p:kickside.profile:timezone").disabled, true)
            test.is_true(has_text(tree, "Changing profile fields is not granted to your account (kickside.users.api:put_profile.endpoint)"))
        end)

        test.it("shows another account's public fields read-only to a plain user", function()
            local fields = model.public_fields(rows(), {["kickside.profile"] = {display_name = "Ops"}})
            local v = view({target = model.target({user_id = "u-ops"}, "u-root", false), groups = {}, fields = fields})
            -- A nil in a table constructor creates no key: the identity is taken out after.
            v.identity, v.token = nil, nil
            local form = model.new_form(nil, fields)
            local tree = model.sheet(v, form, NOW)
            test.is_nil(by_id(tree, "f_full_name"), "no identity for a public view")
            test.is_true(has_text(tree, model.PUBLIC_ONLY))
            test.is_true(not has_text(tree, "Session"), "another account's session is not shown")
            test.is_true(has_text(tree, "Ops"), "the display name is the caption")
            test.eq(by_id(tree, "password").disabled, true)
            v.tab = 2
            tree = model.sheet(v, form, NOW)
            test.eq(by_id(tree, "p:kickside.profile:display_name").disabled, true)
            test.eq(model.status_line(v), "Public profile, read-only")

            -- The target alone keeps it read-only, even with fields editable by
            -- declaration and every gate granted: writes go to the actor.
            local admin = view({target = model.target({user_id = "u-ops"}, "u-root", true), tab = 2})
            local admin_tree = model.sheet(admin, model.new_form(admin.identity, admin.fields), NOW)
            test.eq(by_id(admin_tree, "p:kickside.profile:timezone").disabled, true)
            test.eq(by_id(admin_tree, "password").disabled, true)
        end)

        test.it("names what could not be read, and a failure instead of the sheet", function()
            local v = view({problems = {"tokens: no database"}})
            test.eq(model.status_line(v), "Your profile · tokens: no database")
            v.status = "saved"
            test.eq(model.status_line(v), "saved")
            local failed = {target = model.target(nil, nil, false), failure = "No signed-in account"}
            local tree = model.sheet(failed, nil, NOW)
            test.eq(by_id(tree, "cancel").text, "Close")
            test.eq(model.status_line(failed), "No signed-in account")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
