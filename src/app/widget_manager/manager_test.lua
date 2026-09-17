local test = require("test")
local model = require("model")
local store = require("store")
local window = require("window")
local ui = require("ui")
local render = require("render")
local rasters = require("rasters")
local cells = require("cells")
local fs = require("fs")
local gfx = require("gfx")
local yaml = require("yaml")
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
        end)
        test.it("uploads only the unchanged widget namespace through installed Keeper", function()
            local result, err = funcs.call("keeper.gov.tools:sync_from_fs", {managed_namespaces = {model.NAMESPACE}, timeout = "2s"})
            test.is_nil(err)
            test.not_nil(result)
        end)
        test.it("starts the real window process and draws the installed composition", function()
            local events = assert(process.events())
            local view = assert(tty.viewport({width = 66, height = 24}))
            local pid = assert(process.with_options({terminal = assert(view:grant())})
                :spawn_monitored("app.desktop.widget_manager:window", "app:processes"))
            local deadline = time.after("3s")
            local drawn = false
            while not drawn do
                local picked = channel.select({events:case_receive(), deadline:case_receive(), time.after("20ms"):case_receive()})
                if picked.channel == deadline then break end
                if picked.channel == events and picked.value.kind == process.event.EXIT and tostring(picked.value.from) == tostring(pid) then break end
                local snapshot = view:snapshot(-1)
                for _, row in ipairs(snapshot and snapshot.rows or {}) do
                    if tostring(row):find("Manage widgets", 1, true) then drawn = true end
                end
            end
            process.terminate(tostring(pid))
            view:close()
            test.is_true(drawn, "real window presents its first frame")
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
        test.it("protects unsaved drafts on close and reload, and routes editor actions", function()
            local state = fixture()
            local flags: any = {closed = false, staying = false}
            local context: any = {close = function() flags.closed = true end, stay = function() flags.staying = true end}
            window.definition.update(state, {type = "change", id = "width", value = "24"}, context)
            test.eq(state.items[1].width, "24")
            window.definition.update(state, {type = "close"}, context)
            test.eq(flags.staying, true)
            test.eq(flags.closed, false)
            window.definition.update(state, {type = "activate", id = "keep"}, context)
            test.is_nil(state.confirm)
            window.definition.update(state, {type = "activate", id = "reload"}, context)
            test.eq(state.confirm, "reload")
            window.definition.update(state, {type = "close"}, context)
            window.definition.update(state, {type = "activate", id = "discard"}, context)
            test.eq(flags.closed, true)
        end)
        test.it("lays out cells and pixels at full and compact sizes and renders real previews", function()
            local files = assert(fs.get("chicago.shell.theme:fonts"))
            local fonts = {face = assert(gfx.font(assert(files:readfile("LiberationSans-Regular.ttf")), {size = 13, smooth = true})),
                bold = assert(gfx.font(assert(files:readfile("LiberationSans-Bold.ttf")), {size = 13, smooth = true}))}
            local shots = assert(fs.get("app.desktop.widget_manager:shots"))
            for _, size in ipairs({{w = 66, h = 24, page = 1}, {w = 40, h = 16, page = 1}, {w = 40, h = 16, page = 2}}) do
                local state = fixture()
                for index = 1, 30 do model.add(state) end
                state.selected, state.page = 1, size.page
                local tree = window.definition.view(state, {width = size.w, height = size.h})
                test.is_nil(ui.problem(tree))
                local interaction = ui.interaction()
                local plan = ui.plan(tree, size.w, size.h, interaction)
                for _, id in ipairs(size.page == 2 and {"enabled", "width", "height", "apply", "close"} or {"instances", "add", "apply", "close"}) do
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
