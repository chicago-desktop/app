local test = require("test")
local process = require("process")
local channel = require("channel")
local time = require("time")
local tty = require("tty")
local ui = require("ui")
local function receive(stream, predicate)
    local deadline = time.after("6s")
    while true do
        local picked = channel.select({stream:case_receive(), deadline:case_receive()})
        assert(picked.channel ~= deadline and picked.ok, "Widget dialog did not reach expected state")
        local value: any = picked.value:payload()
        if type(value) == "userdata" then value = value:data() end
        if type(value) == "table" and value[1] then value = value[1] end
        if predicate(value) then return value end
    end
end
local function plan(frame: any): any
    return ui.plan(frame.state.ui, frame.width, frame.height, frame.state.interaction)
end
local function exercise(action: string)
    local session: any = {}
    local ok, err = pcall(function()
        session.frames = process.listen("widget.dialog.frame", {message = true})
        session.replies = process.listen("desktop.reply", {message = true})
        local service = "chicago.shell.test.widget_dialog_" .. action
        session.view = assert(tty.viewport({width = 100, height = 36}))
        session.pid = assert(process.with_options({terminal = assert(session.view:grant())})
            :spawn_monitored("app.desktop.widget_manager:dialog_composer", "app:processes", service, tostring(process.pid())))
        local deadline = time.now():unix_nano() + 5000000000
        while not process.registry.lookup(service) and time.now():unix_nano() < deadline do
            channel.select({time.after("20ms"):case_receive()})
        end
        assert(process.registry.lookup(service), "compositor did not start")
        assert(process.send(service, "desktop.open", {entry = "app.desktop.widget_manager:window", reply_to = tostring(process.pid())}))
        local opened = receive(session.replies, function(value) return value.command == "desktop.open" end)
        test.is_true(opened.ok)
        local frame = receive(session.frames, function(value) return value.entry == "app.desktop.widget_manager:window" end)
        local function click(x: any, y: any)
            assert(session.view:send({type = "mouse", action = "press", button = "left", x = math.tointeger(x), y = math.tointeger(y)}))
            assert(session.view:send({type = "mouse", action = "release", button = "left", x = math.tointeger(x), y = math.tointeger(y)}))
        end
        if action == "properties" then
            local listing = plan(frame).by_id.instances
            local index: any = nil
            for i, row in ipairs(listing.node.rows) do if row.id == "weather" then index = i end end
            assert(index, "host Weather instance is required by this regression")
            click(frame.x + listing.rect.x + 1, frame.y + listing.rect.y + index)
            frame = receive(session.frames, function(value)
                return value.entry == "app.desktop.widget_manager:window" and plan(value).by_id.instances.node.selected == index
            end)
        end
        local button = plan(frame).by_id[action].rect
        click(frame.x + button.x + 1, frame.y + button.y)
        local editor = receive(session.frames, function(value) return value.entry == "app.desktop.widget_manager:editor" end)
        local controls = plan(editor).by_id
        test.not_nil(controls.pages, "dialog receives its arguments rather than reporting a missing widget")
        if action == "add" then
            test.not_nil(controls.definition)
            test.eq(controls.save.node.text, "Add widget")
        else
            test.is_nil(controls.definition)
            local tabs = controls.pages
            click(editor.x + tabs.rect.x + tabs.spans[2].x, editor.y + tabs.rect.y)
            editor = receive(session.frames, function(value)
                return value.entry == "app.desktop.widget_manager:editor" and plan(value).by_id.config_place ~= nil
            end)
            test.not_nil(plan(editor).by_id.search_place, "Weather owns the City search field")
        end
    end)
    if session.pid then process.terminate(tostring(session.pid)) end
    if session.view then session.view:close() end
    if session.frames then process.unlisten(session.frames) end
    if session.replies then process.unlisten(session.replies) end
    if not ok then error(tostring(err)) end
end
local function define_tests()
    test.describe("Widget dialogs through the real compositor", function()
        test.it("Add opens an editable creation dialog after a real mouse click", function() exercise("add") end)
        test.it("Weather Properties retains the selected instance and its City settings", function() exercise("properties") end)
    end)
end
local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
