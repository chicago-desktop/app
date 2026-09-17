local app = require("app")
local model = require("model")
local store = require("store")
local desktop = require("desktop")
local definition: any = {backend = store, desktop = desktop, interval = "2s"}
local function load(state: any, quiet: boolean?): boolean
    local fresh, err = definition.backend.load()
    if not fresh then state.failure = tostring(err); return true end
    if quiet and fresh.before == state.before and not state.failure then return false end
    local selected = state.items[state.selected]
    for key, value in pairs(fresh) do state[key] = value end
    if selected then
        for i, item in ipairs(state.items) do if item.name == selected.name then state.selected = i end end
    end
    state.failure, state.confirm = nil, nil
    return true
end
function definition.init(args: any, context: any): any
    local state: any = {items = {}, definitions = {}, selected = 0, dirty = false}
    load(state)
    return state
end
function definition.view(state: any, context: any): any
    local rows = {}
    for _, item in ipairs(state.items) do
        rows[#rows + 1] = {id = item.name, cells = {item.title, item.enabled and "On" or "Off", model.grid_label(item)}}
    end
    local item = state.items[state.selected]
    local blocked = state.failure ~= nil or state.dirty or state.pending
    local buttons: any = {kind = "row", size = 2, gap = 1, children = {
        {kind = "button", id = "add", text = "Add...", disabled = blocked},
        {kind = "button", id = "properties", text = "Properties...", disabled = blocked or not item},
        {kind = "button", id = "remove", text = "Remove", disabled = blocked or not item}}}
    if state.confirm then
        buttons.children = {{kind = "button", id = "discard", text = state.confirm == "remove" and "Remove widget" or "Discard changes"},
            {kind = "button", id = "keep", text = "Back"}}
    end
    return {kind = "column", padding = 1, children = {
        {kind = "label", size = 1, text = "Manage widgets on all desktops"},
        {kind = "table", id = "instances", rows = rows, selected = state.selected,
            columns = {{title = "Widget", weight = 1}, {title = "State", width = 6}, {title = "Size", width = 14}}},
        buttons,
        {kind = "checkbox", id = "enabled", size = 1, text = "Enabled", checked = item and item.enabled or false, disabled = blocked or not item},
        {kind = "row", size = 2, gap = 1, children = {
            {kind = "button", id = "apply", text = state.pending and "Retry Apply" or "Apply", disabled = state.failure ~= nil},
            {kind = "button", id = "reload", text = "Reload"}, {kind = "button", id = "close", text = "Close"}}},
        {kind = "label", size = 3, wrap = true, alert = state.failure ~= nil, text = state.failure or state.status or ""}}}
end
local function save(state: any)
    local ok, message = definition.backend.save(state)
    state.status, state.confirm = tostring(message), nil
end
function definition.update(state: any, action: any, context: any): any
    if action.type == "tick" then
        if state.dirty or state.pending or state.confirm then return false end
        return load(state, true)
    elseif action.type == "close" or (action.type == "key" and action.key_type == "esc") or action.id == "close" then
        if state.dirty then state.confirm = "close"; context.stay() else context.close() end
    elseif action.type == "select" and action.id == "instances" then state.selected = action.index
    elseif action.type == "change" and action.id == "enabled" then
        local item = state.items[state.selected]
        if item then item.enabled, state.dirty = action.value, true; save(state) end
    elseif action.type == "activate" then
        if action.id == "add" or action.id == "properties" or action.id == "instances" then
            local item = state.items[state.selected]
            if state.dirty or state.pending or state.failure then return false end
            if action.id ~= "add" and not item then return false end
            local opened, err = definition.desktop.dialog({entry = "app.desktop.widget_manager:editor",
                title = action.id == "add" and "Add Widget" or "Widget Properties",
                w = 52, h = 26, args = {mode = action.id == "add" and "add" or "edit", name = item and item.name}})
            if not opened then state.status = "Could not open: " .. tostring(err) end
        elseif action.id == "remove" then state.confirm = "remove"; state.status = "Remove the selected widget from all desktops?"
        elseif action.id == "apply" then save(state)
        elseif action.id == "reload" then if state.dirty then state.confirm = "reload" else load(state) end
        elseif action.id == "discard" then
            if state.confirm == "remove" then model.remove(state); save(state)
            elseif state.confirm == "close" then state.dirty = false; context.close()
            else load(state) end
        elseif action.id == "keep" then state.confirm = nil
        else return false end
    elseif action.type ~= "resize" then return false end
end
return {main = app.main(definition), definition = definition}
