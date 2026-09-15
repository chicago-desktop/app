-- Connections model: pure, so every case runs on stub rows and stub bindings.
local test = require("test")
local model = require("model")
local conn_types = require("conn_types")
local errors = require("errors")

-- A binding in the exact shape a provider module declares (see
-- kickside/telegram/connection): contract.binding, the connection contract in
-- data.contracts, meta.provider and meta.credential_schema.
local function binding(id: string, provider: string, title: string, fields: any, extra: any?): any
    local meta: any = {provider = provider, title = title, group = "Messaging", comment = title .. " bot",
        credential_schema = {fields = fields, submit_label = "Connect", version = "1.0"}}
    for key, value in pairs(extra or {}) do meta[key] = value end
    return {id = id, kind = "contract.binding", meta = meta,
        data = {contracts = {{contract = conn_types.CONNECTION_CONTRACT}}}}
end

local TELEGRAM_FIELDS = {
    {key = "bot_token", label = "Bot token", type = "password", required = true,
        placeholder = "123456:ABC...", help = "Paste the bot token."},
    {key = "default_chat_id", label = "Default chat id", type = "text", required = false,
        placeholder = "-1001234567890"},
}

local function telegram(): any
    return model.provider(binding("kickside.telegram.connection:binding", "telegram", "Telegram", TELEGRAM_FIELDS))
end

-- Walk a component tree; `visit(node)` sees every node.
local function walk(node: any, visit: any)
    visit(node)
    for _, child in ipairs(type(node.children) == "table" and node.children or {}) do walk(child, visit) end
end

local function by_id(tree: any, id: string): any
    local found = nil
    walk(tree, function(node) if node.id == id then found = node end end)
    return found
end

local function texts(tree: any): any
    local out = {}
    walk(tree, function(node) if node.kind == "label" then out[#out + 1] = tostring(node.text) end end)
    return out
end

local function has_text(tree: any, needle: string): boolean
    for _, line in ipairs(texts(tree)) do
        if line:find(needle, 1, true) then return true end
    end
    return false
end

local function define_tests()
    test.describe("Connections model: rows", function()
        test.it("projects name, provider and state the way the list endpoint does", function()
            local rows, problem = model.connections({
                {component_id = "c1", created_at = "2026-09-10", meta = {title = "Alerts", provider = "telegram",
                    comment = "night alerts", connection_state = "needs_reauth"}},
                {component_id = "c2", meta = {title = "Old token", provider = "slack", expires_at = "100"}},
                {component_id = "c3", meta = {title = "Fresh", provider = "slack", expires_at = "999"}},
            }, 500)
            test.is_nil(problem)
            test.eq(#rows, 3)
            test.eq(rows[1].name, "Alerts")
            test.eq(rows[1].state, "needs_reauth")
            test.eq(model.state_text(rows[1].state), "Needs re-auth")
            test.eq(rows[2].state, "expired", "a connected token past expires_at reads as expired")
            test.eq(rows[3].state, "connected", "an absent state defaults to connected")
            local table_rows = model.table_rows(rows)
            test.eq(table_rows[1].id, "c1", "the table row is selected by component id")
            test.eq(table_rows[1].cells[3], "Needs re-auth")
            test.eq(model.detail(rows[1]), "telegram · created 2026-09-10 · night alerts")
        end)

        test.it("names a row without component_id instead of dropping it silently", function()
            local rows, problem = model.connections({{meta = {title = "ghost"}}, {component_id = "c1", meta = {}}}, 0)
            test.eq(#rows, 1)
            test.eq(problem, "connection row missing component_id")
            test.eq(model.table_rows(rows)[1].cells[1], "(unnamed)")
        end)

        test.it("says how many there are and that the list is cut", function()
            test.eq(model.summary({}, false), "0 connections")
            test.eq(model.summary({{}}, false), "1 connection")
            test.eq(model.summary({{}, {}}, true), "2 connections (showing the first 2)")
        end)
    end)

    test.describe("Connections model: providers", function()
        test.it("keeps only connection bindings with a credential schema and a provider, sorted by title", function()
            local other = binding("x:other", "other", "Other", TELEGRAM_FIELDS)
            other.data.contracts = {{contract = "kickside.contract:component"}}
            local no_schema = binding("x:bare", "bare", "Bare", TELEGRAM_FIELDS)
            no_schema.meta.credential_schema = nil
            local no_provider = binding("x:anon", "", "Anon", TELEGRAM_FIELDS)
            local slack = binding("x:slack", "slack", "Slack", {{key = "bot_token", label = "Bot token", type = "password", required = true}})
            slack.meta.credential_schema.submit_label = nil
            local list = model.providers({
                binding("x:telegram", "telegram", "Telegram", TELEGRAM_FIELDS),
                other, no_schema, no_provider, slack,
                {id = "x:lib", kind = "library.lua", meta = {provider = "telegram"}},
            })
            test.eq(#list, 2)
            test.eq(list[1].title, "Slack", "sorted by title")
            test.eq(list[2].title, "Telegram")
            test.eq(list[1].submit_label, "Connect", "no submit_label in the schema falls back to Connect")
            test.eq(list[2].group, "Messaging")
            test.eq(#list[2].fields, 2)
            local row = model.provider_rows(list)[2]
            test.eq(row.id, "x:telegram")
            test.eq(row.cells[1], "Telegram")
            test.eq(row.cells[2], "Messaging")
        end)
    end)

    test.describe("Connections model: the form", function()
        test.it("builds one input per credential field, secrets masked, required marked, hint under it", function()
            local form = model.new_form(telegram())
            local tree = model.form_tree(form, false)
            local token = by_id(tree, "cred_bot_token")
            test.not_nil(token, "the bot token field is in the tree")
            test.eq(token.kind, "input")
            test.is_true(token.password == true, "a password field is masked")
            local chat = by_id(tree, "cred_default_chat_id")
            test.not_nil(chat)
            test.is_true(chat.password ~= true, "a text field is not masked")
            test.is_true(has_text(tree, "Bot token *:"), "a required field carries *")
            test.is_true(has_text(tree, "Default chat id:"), "an optional one does not")
            test.is_true(has_text(tree, "Name *:"), "the name is required")
            test.eq(token.placeholder, "123456:ABC...", "the schema's placeholder is drawn inside the empty field")
            test.eq(chat.placeholder, "-1001234567890")
            test.is_nil(by_id(tree, "f_name").placeholder, "no placeholder where the schema declares none")
            test.is_true(has_text(tree, "Paste the bot token."), "the hint is the schema's help")
            test.is_true(not has_text(tree, "e.g."), "the placeholder is not repeated in the hint any more")
            local wrapped = false
            walk(tree, function(node)
                if node.kind == "label" and node.text == "Paste the bot token." then wrapped = node.wrap == true end
            end)
            test.is_true(wrapped, "a long help text wraps instead of running off the row")
            test.eq(by_id(tree, "submit").text, "Connect", "the submit button says the schema's submit_label")
            test.is_true(by_id(tree, "submit").default == true)
            test.not_nil(by_id(tree, "save"), "Save without a test is offered too")
        end)

        test.it("Properties edits the name only and says why the credentials are fixed", function()
            local form = model.props_form({id = "c1", name = "Alerts", provider = "telegram", description = ""})
            local tree = model.form_tree(form, false)
            test.not_nil(by_id(tree, "f_name"))
            test.is_nil(by_id(tree, "f_description"), "update_policy accepts the title only")
            local credentials = 0
            walk(tree, function(node) if model.key_of(node.id) then credentials = credentials + 1 end end)
            test.eq(credentials, 0, "no credential inputs in Properties")
            test.is_true(has_text(tree, model.CREDENTIALS_FIXED))
        end)

        test.it("a select field is a drop-down of the schema's options; an optional one can stay empty", function()
            local provider = model.provider(binding("x:s", "s", "S", {
                {key = "region", label = "Region", type = "select", required = true, options = {"eu", "us"}},
                {key = "tier", label = "Tier", type = "select",
                    options = {{value = "free", label = "Free"}, {value = "pro"}}},
            }))
            local form = model.new_form(provider)
            test.eq(form.values.region, "eu", "a required select starts on its first option")
            test.eq(form.values.tier, "", "an optional select starts on (none)")
            local tree = model.form_tree(form, false)
            local region = by_id(tree, "cred_region")
            test.eq(region.kind, "select")
            test.eq(#region.options, 2)
            test.eq(region.options[1].value, "eu")
            test.eq(region.options[1].label, "eu", "a plain option is its own label")
            local tier = by_id(tree, "cred_tier")
            test.eq(tier.options[1].label, "(none)")
            test.eq(tier.options[2].label, "Free")
            test.eq(tier.options[3].label, "pro", "an option without a label shows its value")
            form.name = "S"
            local untouched = model.private_context(provider, form)
            test.eq(untouched.region, "eu")
            test.is_nil(untouched.tier, "an optional select left on (none) is not sent")
            test.is_nil(model.check(provider, form))
            form.values.tier = "pro"
            test.eq(model.private_context(provider, form).tier, "pro")
            test.is_nil(model.check(provider, form), "a chosen option passes create_policy")
        end)

        test.it("a checkbox field is a checkbox holding a boolean", function()
            local provider = model.provider(binding("x:c", "c", "C", {
                {key = "tls", label = "Use TLS", type = "checkbox"},
            }))
            local form = model.new_form(provider)
            test.eq(form.values.tls, false)
            test.eq(by_id(model.form_tree(form, false), "cred_tls").kind, "checkbox")
            test.eq(model.private_context(provider, form).tls, false, "an unchecked box is sent as false, not left out")
        end)
    end)

    test.describe("Connections model: form → private_context", function()
        test.it("sends declared keys only, as typed, and leaves empty optional fields out", function()
            local provider = telegram()
            local form = model.new_form(provider)
            form.values.bot_token = " 123:abc "
            form.values.default_chat_id = ""
            form.values.injected = "x"
            local context = model.private_context(provider, form)
            test.eq(context.bot_token, " 123:abc ", "a secret is not trimmed")
            test.is_nil(context.default_chat_id, "an empty optional field is absent, not an empty string")
            test.is_nil(context.injected, "only keys the schema declares")
            local count = 0
            for _ in pairs(context) do count = count + 1 end
            test.eq(count, 1)
        end)

        test.it("the required check speaks the user's labels, then the platform's own rule", function()
            local provider = telegram()
            local form = model.new_form(provider)
            test.eq(model.check(provider, form), "Name is required")
            form.name = "   "
            test.eq(model.check(provider, form), "Name is required", "blank is not a name")
            form.name = "Alerts"
            test.eq(model.check(provider, form), "Bot token is required", "the label, not the key")
            form.values.bot_token = "123:abc"
            test.is_nil(model.check(provider, form))
            test.eq(model.name_of({name = "  Alerts "}), "Alerts")
        end)

        test.it("create_policy has the last word: a select value outside its options is refused", function()
            local provider = model.provider(binding("x:s", "s", "S", {
                {key = "region", label = "Region", type = "select", required = true, options = {"eu", "us"}},
            }))
            local form = model.new_form(provider)
            form.name, form.values.region = "S", "mars"
            test.eq(model.check(provider, form), "region must be one of the declared options")
            form.values.region = "eu"
            test.is_nil(model.check(provider, form))
        end)
    end)

    test.describe("Connections model: refusals", function()
        test.it("a permission refusal reads as one, not as a failure or as not found", function()
            -- The table form: in this runtime `errors.new(text):kind(x)` is a
            -- getter that returns the (empty) kind, not a builder.
            local denied = errors.new({message = "no component.write", kind = errors.PERMISSION_DENIED})
            local text = model.explain("create", denied)
            test.is_true(text:find("permission denied", 1, true) ~= nil, text)
            local missing = errors.new({message = "no such component", kind = errors.NOT_FOUND})
            test.is_true(model.explain("open", missing):find("not found", 1, true) ~= nil)
            test.eq(model.explain("list", "boom"), "list: boom")
            test.eq(model.explain("delete", nil), "delete failed")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
