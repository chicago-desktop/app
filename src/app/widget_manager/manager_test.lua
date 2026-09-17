local test = require("test")
local model = require("model")
local store = require("store")
local window = require("window")
local editor = require("editor")
local ui = require("ui")
local render = require("render")
local rasters = require("rasters")
local cells = require("cells")
local fs = require("fs")
local gfx = require("gfx")
local yaml = require("yaml")
local json = require("json")
local registry = require("registry")
local process = require("process")
local tty = require("tty")
local time = require("time")
local channel = require("channel")
local funcs = require("funcs")

local function fixture(): any
    local defs = {{id = "test:memory", kind = "process.lua", meta = {type = "chicago.widget", title = "Memory", width = 20, height = 8}}}
    local doc = {version = "1.0", namespace = model.NAMESPACE, entries = {
        {name = "memory", kind = "registry.entry", meta = {type = "chicago.widget.instance"}, data = {widget = "test:memory", config = {unit = "MB"}}},
        {name = "other", kind = "registry.entry", meta = {type = "unrelated"}, data = {keep = true}},
    }}
    local state = assert(model.open(doc, defs))
    state.before = assert(yaml.encode(doc))
    return state
end
local function handle(text: string): any
    local h: any = {files = {["_index.yaml"] = text}}
    function h:readfile(path: string): any return self.files[path], nil end
    function h:writefile(path: string, value: string): any self.files[path] = value; return true, nil end
    return h
end
local function define_tests()
    test.describe("Desktop Widgets manager", function()
        test.it("loads installed definitions and is discoverable as an administrator settings window", function()
            local entry = assert(registry.get("app.desktop.widget_manager:window"))
            test.eq(entry.meta.type, "tui_desktop.window")
            test.eq(entry.meta.group, "Settings")
            test.eq(entry.meta.requires, "chicago.admin")
            local state, err = store.load()
            test.is_nil(err)
            test.is_true(#state.definitions > 0)
            test.not_nil(model.build(state))
            local weather = model.definition(state.definitions, "chicago.weather:widget")
            test.eq(weather.meta.settings.fields[1].key, "place")
            local memory = model.definition(state.definitions, "chicago.taskman:memory")
            test.eq(memory.meta.settings.fields[1].key, "show_history")
        end)
        test.it("applies a nonempty widget changeset through installed Keeper", function()
            -- A registry-only stale instance: syncing the host YAML must remove it.
            -- Unlike a no-op upload this exercises the final governance validator.
            local id = model.NAMESPACE .. ":manager_sync_probe"
            local changes = assert(registry.snapshot()):changes()
            changes:create({id = id, kind = "registry.entry", meta = {type = "chicago.widget.instance"},
                data = {widget = "chicago.taskman:memory", enabled = false}})
            assert(changes:apply())
            local result, err = funcs.call("keeper.gov.tools:sync_from_fs", {managed_namespaces = {model.NAMESPACE}, timeout = "10s"})
            local remaining = registry.get(id)
            if remaining then
                local cleanup = assert(registry.snapshot()):changes()
                cleanup:delete(id)
                assert(cleanup:apply())
            end
            test.is_nil(err, tostring(err))
            test.not_nil(result)
            test.is_nil(remaining, "Keeper applies the deletion instead of rejecting its namespace")
        end)
        test.it("starts the manager and add dialog as real independent window processes", function()
            for _, spec in ipairs({{entry = "window", caption = "Manage widgets"}, {entry = "editor", caption = "General", args = {mode = "add"}}}) do
            local events = assert(process.events())
            local view = assert(tty.viewport({width = 66, height = 24}))
            local pid = assert(process.with_options({terminal = assert(view:grant())})
                :spawn_monitored("app.desktop.widget_manager:" .. spec.entry, "app:processes", spec.args))
            local deadline = time.after("3s")
            local drawn = false
            while not drawn do
                local picked = channel.select({events:case_receive(), deadline:case_receive(), time.after("20ms"):case_receive()})
                if picked.channel == deadline then break end
                if picked.channel == events and picked.value.kind == process.event.EXIT and tostring(picked.value.from) == tostring(pid) then break end
                local snapshot = view:snapshot(-1)
                for _, row in ipairs(snapshot and snapshot.rows or {}) do
                    if tostring(row):find(spec.caption, 1, true) then drawn = true end
                end
            end
            process.terminate(tostring(pid))
            view:close()
            test.is_true(drawn, "real window presents its first frame: " .. spec.entry)
            end
        end)
        test.it("adds independent instances, validates sizes and preserves unrelated YAML and config", function()
            local state = fixture()
            test.is_true(model.add(state))
            test.is_true(model.add(state))
            test.is_true(state.items[2].name ~= state.items[3].name)
            state.items[1].enabled = false
            state.items[1].width = "28"
            local doc, err = model.build(state)
            test.is_nil(err)
            test.eq(doc.entries[1].name, "other")
            test.eq(doc.entries[1].data.keep, true)
            test.eq(doc.entries[2].data.config.unit, "MB")
            test.eq(doc.entries[2].data.enabled, false)
            state.items[1].width = "41"
            test.is_nil(model.build(state))
            state.items[1].width = "1.5"
            test.is_nil(model.build(state))
            state.items[1].width = "20"
            while #state.items > 0 do state.selected = 1; model.remove(state) end
            test.eq(#assert(model.build(state)).entries, 1, "removes widgets only")
        end)
        test.it("rejects conflicting file edits before calling upload and keeps a backup", function()
            local state = fixture()
            local disk = handle(state.before .. "\n# changed elsewhere\n")
            local calls: any = {count = 0}
            local function upload(input: any): any calls.count = calls.count + 1; return {} end
            local ok, err = store.commit(state, disk, upload, function() return {refreshed = true} end)
            test.eq(ok, false)
            test.is_true(tostring(err):find("changed on disk", 1, true) ~= nil)
            test.eq(calls.count, 0)
            disk.files["_index.yaml"] = state.before
            state.items[1].width, state.dirty = "28", true
            local old = state.before
            local saved = store.commit(state, disk, upload, function() return {refreshed = true} end)
            test.eq(saved, true)
            test.eq(disk.files["_index.yaml.bak"], old)
            test.eq(state.dirty, false)
            test.eq(calls.count, 1)
        end)
        test.it("scopes upload to widgets and retries saved-but-unconfirmed changes", function()
            local state = fixture()
            local disk = handle(tostring(state.before))
            state.items[1].enabled, state.dirty = false, true
            local called: any = {refresh = 0}
            local ok, message = store.commit(state, disk, function(input: any)
                test.eq(#input.managed_namespaces, 1)
                test.eq(input.managed_namespaces[1], "app.desktop.widgets")
                return nil, "timeout"
            end, function() called.refresh = called.refresh + 1; return {refreshed = true} end)
            test.eq(ok, false)
            test.eq(state.pending, true)
            test.eq(state.dirty, false, "already saved to disk")
            test.eq(called.refresh, 0)
            test.is_true(message:find("not confirmed", 1, true) ~= nil)
            local saved = store.commit(state, disk, function() return {} end, function() return {refreshed = true} end)
            test.eq(saved, true)
            test.eq(state.pending, false)
        end)
        test.it("edits one instance with a bounded grid and widget-owned settings", function()
            local state = fixture()
            state.mode, state.page, state.channels = "edit", 1, {}
            state.definitions[1].meta.settings = {fields = {{key = "show_history", type = "boolean", label = "History", default = true}}}
            local flags: any = {closed = false, staying = false}
            local context: any = {close = function() flags.closed = true end, stay = function() flags.staying = true end}
            editor.definition.update(state, {type = "activate", id = "size_3_3"}, context)
            test.eq(state.items[1].width, "30")
            test.eq(state.items[1].height, "12")
            test.eq(model.set_grid(state.items[1], 4, 1), false)
            editor.definition.update(state, {type = "change", id = "config_show_history", value = false}, context)
            test.eq(assert(model.build(state)).entries[2].data.config.show_history, false)
            test.eq(assert(model.build(state)).entries[2].data.config.unit, "MB")
            editor.definition.update(state, {type = "close"}, context)
            test.eq(flags.staying, true)
            test.eq(flags.closed, false)
            editor.definition.update(state, {type = "activate", id = "keep"}, context)
            test.eq(state.confirm, false)
            editor.definition.update(state, {type = "activate", id = "discard"}, context)
            test.eq(flags.closed, true)
        end)
        test.it("stores a provider choice only in the edited instance and ignores stale search replies", function()
            local state = fixture()
            state.definitions[1].meta.settings = {fields = {{key = "destination", type = "lookup", label = "Destination"}}}
            state.query = "Tbilisi"
            editor.definition.update(state, {type = "channel", ok = true, value = {payload = function()
                return {ok = true, query = "Berlin", results = {{name = "Berlin"}}}
            end}}, {})
            test.is_nil(state.results)
            editor.definition.update(state, {type = "channel", ok = true, value = {payload = function()
                return {ok = true, query = "Tbilisi", results = {{name = "Tbilisi", latitude = 41.7, longitude = 44.8}}}
            end}}, {})
            editor.definition.update(state, {type = "select", id = "results_destination", index = 1}, {})
            editor.definition.update(state, {type = "activate", id = "use_destination"}, {})
            state.results[1].name = "changed result"
            test.eq(state.items[1].config.destination.name, "Tbilisi")
            model.add(state)
            test.is_nil(state.items[2].config.destination)
            test.eq(assert(model.build(state)).entries[2].data.config.destination.latitude, 41.7)
        end)
        test.it("opens distinct add and properties dialogs without embedding property controls", function()
            local state = fixture()
            local previous = window.definition.desktop
            local calls: any = {}
            window.definition.desktop = {dialog = function(spec: any) calls[#calls + 1] = spec; return {id = "dialog"} end}
            window.definition.update(state, {type = "activate", id = "add"}, {})
            window.definition.update(state, {type = "activate", id = "properties"}, {})
            window.definition.desktop = previous
            test.eq(type(calls[1].args), "string")
            test.eq(assert(json.decode(tostring(calls[1].args))).mode, "add")
            test.eq(assert(json.decode(tostring(calls[2].args))).mode, "edit")
            test.eq(assert(json.decode(tostring(calls[2].args))).name, "memory")
            local plan = ui.plan(window.definition.view(state, {}), 50, 20, ui.interaction())
            test.is_nil(plan.by_id.width)
            test.not_nil(plan.by_id.properties)
        end)
        test.it("renders separate add and settings dialogs in cells and pixels", function()
            local files = assert(fs.get("chicago.shell.theme:fonts"))
            local fonts = {face = assert(gfx.font(assert(files:readfile("LiberationSans-Regular.ttf")), {size = 13})),
                bold = assert(gfx.font(assert(files:readfile("LiberationSans-Bold.ttf")), {size = 13}))}
            local shots = assert(fs.get("app.desktop.widget_manager:shots"))
            for _, mode in ipairs({"add", "edit"}) do
                for page = 1, 2 do
                    local state = fixture()
                    state.mode, state.page = mode, page
                    state.definitions[1].meta.settings = {fields = {{key = "place", type = "lookup", label = "City", label_fields = {"name", "country"}}}}
                    state.results, state.result_index = {{name = "Tbilisi", country = "Georgia"}}, 1
                    for _, size in ipairs({{w = 50, h = 24}, {w = 38, h = 20}}) do
                        local tree = editor.definition.view(state, {width = size.w, height = size.h})
                        test.is_nil(ui.problem(tree))
                        local interaction = ui.interaction()
                        local plan = ui.plan(tree, size.w, size.h, interaction)
                        for _, id in ipairs(page == 1 and {"size_1_1", "size_3_3", "order", "save", "close"} or {"config_place", "search_place", "use_place", "save"}) do
                            test.not_nil(plan.by_id[id], id)
                            test.is_true(plan.by_id[id].rect.h > 0, id .. " has room")
                        end
                        test.not_nil(cells.rows(plan, interaction, size.w, size.h))
                        local placed = assert(render.placement({id = mode, content_state = {sdk = 1, revision = page, ui = tree, interaction = interaction}},
                            {x = 1, y = 1, cols = size.w, rows = size.h}, {w = 10, h = 20}, fonts, rasters.store()))
                        assert(shots:writefile(mode .. "-" .. page .. "-" .. size.w .. ".png", assert(placed.raster:encode("png"))))
                    end
                end
            end
        end)
        test.it("lays out cells and pixels at full and compact sizes and renders real previews", function()
            local files = assert(fs.get("chicago.shell.theme:fonts"))
            local fonts = {face = assert(gfx.font(assert(files:readfile("LiberationSans-Regular.ttf")), {size = 13, smooth = true})),
                bold = assert(gfx.font(assert(files:readfile("LiberationSans-Bold.ttf")), {size = 13, smooth = true}))}
            local shots = assert(fs.get("app.desktop.widget_manager:shots"))
            for _, size in ipairs({{w = 66, h = 24, page = 1}, {w = 40, h = 16, page = 1}}) do
                local state = fixture()
                for index = 1, 30 do model.add(state) end
                state.selected, state.page, state.dirty = 1, size.page, false
                local tree = window.definition.view(state, {width = size.w, height = size.h})
                test.is_nil(ui.problem(tree))
                local interaction = ui.interaction()
                local plan = ui.plan(tree, size.w, size.h, interaction)
                for _, id in ipairs({"instances", "add", "properties", "apply", "close"}) do
                    test.not_nil(plan.by_id[id], id)
                    test.is_true(plan.by_id[id].rect.h > 0 and plan.by_id[id].rect.w > 0, id .. " has room")
                end
                if size.page == 1 then
                    local rect = plan.by_id.instances.rect
                    ui.event(plan, interaction, {type = "mouse", action = "wheel", button = "wheel_down", x = rect.x + 1, y = rect.y + 1})
                    test.is_true(interaction.offsets.instances > 0, "long list scrolls")
                    state.items, state.selected = {}, 0
                    local empty = ui.plan(window.definition.view(state, {width = size.w, height = size.h}), size.w, size.h, interaction)
                    test.eq(empty.by_id.instances.offset, 0, "empty list reclamps the offset")
                end
                local rows = cells.rows(plan, interaction, size.w, size.h)
                test.not_nil(rows)
                local placed, err = render.placement({id = "manager", content_state = {sdk = 1, revision = size.w + size.page,
                    ui = tree, interaction = interaction}}, {x = 1, y = 1, cols = size.w, rows = size.h},
                    {w = 10, h = 20}, fonts, rasters.store())
                test.is_nil(err)
                assert(shots:writefile("manager-" .. size.w .. "-" .. size.page .. ".png", assert(placed.raster:encode("png"))))
            end
        end)
    end)
end
local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
