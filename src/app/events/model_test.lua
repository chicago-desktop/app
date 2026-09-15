-- Event Viewer model: pure, so every case runs on stub rows.
local test = require("test")
local model = require("model")

local OFFSET = 4 * 3600

-- Thread rows as kickside.core.threads:contract list returns them: the
-- thread's columns plus the component's title (reader.list).
local function thread(fields: any?): any
    local out: any = {id = "t-journal", thread_class = "workspace.journal", event_count = 198,
        component_id = "c-journal", component_title = "Test", attrs = "{}",
        last_event_ts = "2026-09-07 15:53:20.025699"}
    for key, value in pairs(fields or {}) do out[key] = value end
    return out
end

-- An event row as list_events returns it (reader EVENT_COLUMNS).
local function event(fields: any?): any
    local out: any = {id = "e1", thread_id = "t-journal", type = "chestor.journal.events:entry.appended",
        role = "user", seq = 120, created_at = "2026-09-07 15:53:20.025699", content_mode = "inline",
        body = "{\"title\":\"RFC-001 έτοιμο για συζήτηση\",\"scope\":\"local\",\"ts\":1788702762}"}
    for key, value in pairs(fields or {}) do out[key] = value end
    return out
end

local function page(count: number, top: number): any
    local rows = {}
    for i = 1, count do
        rows[#rows + 1] = event({id = "e" .. tostring(top - i + 1), seq = top - i + 1})
    end
    return rows
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

local function define_tests()
    test.describe("Event Viewer model: logs", function()
        test.it("labels a log the way list_threads.lua does", function()
            test.eq(model.log_label(thread()), "Test", "the component's title first")
            test.eq(model.log_label(thread({component_title = "", attrs = "{\"title\":\"From attrs\"}"})), "From attrs")
            test.eq(model.log_label(thread({component_title = "", attrs = {name = "Named"}})), "Named")
            test.eq(model.log_label(thread({component_title = "", attrs = "not json"})), "c-journal")
            test.eq(model.log_label(thread({component_title = "", component_id = "", attrs = "{}"})), "t-journal")
        end)

        test.it("groups the logs by thread class, folders sorted, logs by label", function()
            -- Listed newest first, as the contract does: neither folders nor
            -- labels arrive in order, and the ids sort the other way round.
            local logs, problem = model.logs({
                thread({id = "j1", thread_class = "workspace.journal", component_title = "Test"}),
                thread({id = "b1", thread_class = "content.beat", component_title = "Εξωτερική περίμετρος"}),
                thread({id = "b2", thread_class = "content.beat", component_title = "Dovod - blog"}),
            })
            test.is_nil(problem)
            local rows = model.tree_rows(logs, {})
            test.eq(#rows, 5)
            test.eq(rows[1].id, "class:content.beat", "folders by class name")
            test.eq(rows[1].label, "content.beat (2)")
            test.eq(rows[1].kind, "folder")
            test.eq(rows[1].expanded, true, "folders start open")
            test.eq(rows[2].id, "log:b2", "by label, not id: Latin before Cyrillic, by byte order")
            test.eq(rows[2].depth, 1)
            test.eq(rows[2].trail[1], true, "a sibling follows")
            test.eq(rows[3].id, "log:b1")
            test.eq(rows[3].trail[1], false, "the last of its folder")
            test.eq(rows[4].id, "class:workspace.journal")
            test.eq(#rows[4].trail, 0)
            test.eq(model.first_log(logs).id, "b2", "the window opens the first log in tree order")
            local closed = model.tree_rows(logs, {["content.beat"] = true})
            test.eq(#closed, 3)
            test.eq(closed[1].expanded, false)
        end)

        test.it("keeps tree ids apart from thread ids", function()
            test.eq(model.log_of("log:t-1"), "t-1")
            test.is_nil(model.log_of("class:workspace.journal"))
            test.eq(model.group_of("class:workspace.journal"), "workspace.journal")
            test.is_nil(model.group_of("log:t-1"))
        end)

        test.it("names a thread row without id instead of dropping it silently", function()
            local logs, problem = model.logs({{thread_class = "x"}, thread()})
            test.eq(#logs, 1)
            test.eq(problem, "thread row missing id")
            test.is_nil(model.first_log({}))
            test.eq(model.find_log(logs, "t-journal").label, "Test")
        end)
    end)

    test.describe("Event Viewer model: events", function()
        test.it("splits the type into the source module and what happened", function()
            local source, name = model.split_type("acme.bridge.events:run.started")
            test.eq(source, "acme.bridge")
            test.eq(name, "run.started")
            source, name = model.split_type("kickside.component.events:updated")
            test.eq(source, "kickside.component")
            test.eq(name, "updated")
            source, name = model.split_type("plain")
            test.eq(source, "")
            test.eq(name, "plain")
        end)

        test.it("says what happened in one line", function()
            test.eq(model.message(event().body), "RFC-001 έτοιμο για συζήτηση", "the title first")
            test.eq(model.message("{\"reason\":\"the autonomy ceiling\",\"detail\":\"x\"}"), "the autonomy ceiling",
                "reason before detail")
            test.eq(model.message("{\"component_id\":\"c1\",\"impl_id\":\"chestor.journal:journal_kind\",\"command_types\":[\"SET_META\"]}"),
                "component_id=c1, impl_id=chestor.journal:journal_kind", "plain fields when nothing says it, tables left out")
            test.eq(model.message("{\"title\":\"a\\n  b\"}"), "a b", "whitespace collapses to one line")
            test.eq(model.message("not json"), "not json")
            test.eq(model.message("{\"list\":[1,2]}"), "{ \"list\": [ 1, 2 ] }", "only tables: the body itself")
            local long = string.rep("ω", 300)
            local clipped = model.message("{\"title\":\"" .. long .. "\"}")
            test.eq(#model.chars(clipped), model.MESSAGE_WIDTH, "clipped by characters, not bytes")
            test.eq(model.chars(clipped)[model.MESSAGE_WIDTH], "…")
            local fits = string.rep("ω", 200)
            test.eq(model.message("{\"title\":\"" .. fits .. "\"}"), fits,
                "200 letters are 400 bytes and still fit: the width counts characters")
        end)

        test.it("draws a row: local time, source, type, message", function()
            local events = model.events({event()})
            local rows = model.table_rows(events, OFFSET)
            test.eq(rows[1].id, "e1")
            test.eq(rows[1].cells[1], "2026-09-07 19:53", "SQLite's UTC datetime in local time")
            test.eq(rows[1].cells[2], "chestor.journal")
            test.eq(rows[1].cells[3], "entry.appended")
            test.eq(rows[1].cells[4], "RFC-001 έτοιμο για συζήτηση")
        end)

        test.it("names an event row without id", function()
            local events, problem = model.events({{type = "x"}, event()})
            test.eq(#events, 1)
            test.eq(problem, "event row missing id")
        end)

        test.it("pages newest first: the next page starts below the lowest loaded seq", function()
            local first = model.events(page(model.PAGE, 250))
            test.eq(model.has_more(first), true, "a full page may have more behind it")
            test.eq(model.next_before(first), 151)
            local request = model.page_request("t-journal", model.next_before(first), "")
            test.eq(request.thread_id, "t-journal")
            test.eq(request.before, 151)
            test.eq(request.limit, 100)
            test.eq(request.ascending, false)
            test.is_nil(request.event_type, "no type filter unless one is chosen")
            test.eq(model.page_request("t", nil, "a:b").event_type, "a:b")
            test.is_nil(model.page_request("t", nil, "").before)
            local second = model.events(page(30, 150))
            test.eq(model.has_more(second), false, "a short page is the end of the log")
            local both = model.merge(first, model.merge(second, {second[1]}))
            test.eq(#both, 130, "an event already loaded is not listed twice")
            test.eq(both[101].id, "e150")
            test.is_nil(model.next_before({}))
        end)

        test.it("asks for the next page when the table says end and the log has more", function()
            test.eq(model.loads_more({type = "end", id = "events"}, true), true)
            test.eq(model.loads_more({type = "end", id = "events"}, false), false, "not past the end of the log")
            test.eq(model.loads_more({type = "end", id = "logs"}, true), false, "only the events table pages")
            test.eq(model.loads_more({type = "select", id = "events", index = 100}, true), false,
                "reaching the last row is not pushing past it")
            test.eq(model.loads_more(nil, true), false)
        end)

        test.it("filters the loaded events by text in any column", function()
            local events = model.events({
                event({id = "a", body = "{\"title\":\"Run failed on card L22\"}"}),
                event({id = "b", type = "acme.bridge.events:run.started", body = "{}"}),
                event({id = "c", role = "assistant", body = "{\"title\":\"quiet\"}"}),
            })
            test.eq(#model.visible(events, ""), 3)
            test.eq(model.visible(events, "l22")[1].id, "a", "ASCII ignores case")
            test.eq(model.visible(events, "RUN FAILED")[1].id, "a", "in the typed text too")
            test.eq(model.visible(events, "bridge")[1].id, "b", "the source column counts")
            test.eq(model.visible(events, "  assistant ")[1].id, "c", "the role counts; spaces trimmed")
            test.eq(#model.visible(events, "nothing like this"), 0)
            test.eq(model.summary(3, 1, true, "l22", ""), "1 of 3 events loaded, more below match \"l22\"")
            test.eq(model.summary(1, 1, false, "", "a:b"), "1 event loaded · type a:b")
        end)

        test.it("offers every loaded type and keeps the chosen one", function()
            local events = model.events({event(), event({id = "b", type = "b.events:x"}), event({id = "c"})})
            local options = model.type_options(events, "z.events:gone")
            test.eq(options[1].value, "")
            test.eq(options[1].label, "(All types)")
            test.eq(#options, 4)
            test.eq(options[2].value, "b.events:x")
            test.eq(options[3].value, "chestor.journal.events:entry.appended")
            test.eq(options[4].value, "z.events:gone", "the chosen type stays offered")
        end)
    end)

    test.describe("Event Viewer model: properties", function()
        test.it("prints the payload as JSON with sorted keys and non-ASCII kept", function()
            local text = model.payload_text(model.event(event()))
            test.eq(text, "{\n  \"scope\": \"local\",\n  \"title\": \"RFC-001 έτοιμο για συζήτηση\",\n  \"ts\": 1788702762\n}")
            test.eq(model.pretty({a = {1, "x"}, b = {}}), "{\n  \"a\": [\n    1,\n    \"x\"\n  ],\n  \"b\": {}\n}")
            test.eq(model.pretty("say \"hi\"\n"), "\"say \\\"hi\\\"\\n\"")
            test.eq(model.payload_text(model.event(event({body = "plain text"}))), "plain text")
            test.eq(model.payload_text(model.event(event({content_mode = "ref", content_ref = "uploads/1"}))),
                "Stored by reference: uploads/1")
        end)

        test.it("lists the event's identities, the optional ones only when present", function()
            local base = model.event(event())
            local pairs_list = model.details(base, "Test", OFFSET)
            local values = {}
            for _, pair in ipairs(pairs_list) do values[pair[1]] = pair[2] end
            test.eq(values["Date"], "2026-09-07 19:53")
            test.eq(values["Source"], "chestor.journal")
            test.eq(values["Type"], "entry.appended")
            test.eq(values["Log"], "Test")
            test.eq(values["Sequence"], "120")
            test.is_nil(values["Trace"])
            test.is_nil(values["External"])
            local traced = model.event(event({trace_id = "tr1", external_source = "component.lifecycle", external_id = "u:1"}))
            local more = {}
            for _, pair in ipairs(model.details(traced, "Test", OFFSET)) do more[pair[1]] = pair[2] end
            test.eq(more["Trace"], "tr1")
            test.eq(more["External"], "component.lifecycle / u:1")
        end)

        test.it("builds the sheet: pairs read-only, the payload as the SDK's scrolling text", function()
            local tree = model.details_tree(model.event(event()), "Test", OFFSET)
            local pairs_table: any = nil
            walk(tree, function(node) if node.kind == "table" then pairs_table = node end end)
            test.eq(pairs_table.static, true)
            local payload = by_id(tree, "payload")
            test.eq(payload.kind, "text")
            test.eq(payload.text, model.payload_text(model.event(event())), "the whole payload: the SDK wraps it")
            test.eq(by_id(tree, "details_close").default, true)
        end)
    end)

end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
