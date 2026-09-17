local app = require("app")
local model = require("model")
local store = require("store")
local definition: any = {backend = store}
local function load(state: any)
    local fresh, err = definition.backend.load()
    if not fresh then state.failure = tostring(err); return end
    for key, value in pairs(fresh) do state[key] = value end
    state.failure, state.confirm = nil, nil
end
function definition.init(args: any, context: any): any
    local state: any = {items = {}, definitions = {}, selected = 0, available = "", dirty = false}
    load(state)
    return state
end
local function field(id: string, text: string, value: any, disabled: boolean): any
    return {kind = "row", size = 1, gap = 1, children = {
        {kind = "label", size = 10, text = text},
        {kind = "input", id = id, text = tostring(value or ""), disabled = disabled}}}
end
function definition.view(state: any, context: any): any
    local rows, options = {}, {}
    for _, item in ipairs(state.items) do
        rows[#rows + 1] = {id = item.name, cells = {item.title, item.enabled and "On" or "Off", item.width .. " x " .. item.height}}
    end
    for _, entry in ipairs(state.definitions) do
        options[#options + 1] = {value = entry.id, label = tostring(entry.meta.title or entry.id)}
    end
    local item: any = state.items[state.selected]
    local disabled = item == nil or state.failure ~= nil
    local controls: any
    if state.confirm then
        controls = {kind = "row", size = 2, gap = 1, children = {
            {kind = "label", text = state.confirm == "close" and "Discard changes and close?" or "Discard changes and reload?"},
            {kind = "button", id = "discard", size = 10, text = "Discard"},
            {kind = "button", id = "keep", size = 8, text = "Back"}}}
    else
        controls = {kind = "row", size = 2, gap = 1, children = {
            {kind = "button", id = "apply", size = 10, text = "Apply", default = true,
                disabled = (not state.dirty and not state.pending) or state.failure ~= nil},
            {kind = "button", id = "reload", size = 10, text = "Reload"},
            {kind = "button", id = "refresh", size = 12, text = "Refresh"},
            {kind = "label", text = ""}, {kind = "button", id = "close", size = 9, text = "Close"}}}
    end
    local listing: any = {kind = "table", id = "instances", rows = rows, selected = state.selected,
        columns = {{title = "Widget", weight = 1}, {title = "State", width = 6}, {title = "Size", width = 10}}}
    local chooser: any = {kind = "row", size = 2, gap = 1, children = {
        {kind = "select", id = "available", value = state.available, options = options},
        {kind = "button", id = "add", text = "Add", size = 7, disabled = #options == 0 or state.failure ~= nil},
        {kind = "button", id = "remove", text = "Remove", size = 9, disabled = disabled}}}
    local fields: any = {
        {kind = "label", size = 1, text = item and (item.name .. " / " .. tostring(item.widget)) or "Select or add a widget."},
        {kind = "checkbox", id = "enabled", size = 1, text = "Enabled", checked = item and item.enabled or false, disabled = disabled},
        field("title", "Title", item and item.title, disabled), field("width", "Width", item and item.width, disabled),
        field("height", "Height", item and item.height, disabled), field("order", "Order", item and item.order, disabled)}
    local children: any = {{kind = "label", size = 1, text = "Manage widgets on all desktops"}}
    if (tonumber(context.height) or 24) < 22 or (tonumber(context.width) or 66) < 52 then
        local page = state.page or 1
        children[#children + 1] = {kind = "tabs", id = "pages", labels = {"Widgets", "Properties"}, active = page,
            padding = 0, children = page == 1 and {listing, chooser} or fields}
        if not state.confirm then
            controls.children = {controls.children[1], controls.children[2], controls.children[5]}
        end
    else
        children[#children + 1], children[#children + 2] = listing, chooser
        for _, node in ipairs(fields) do children[#children + 1] = node end
        children[#children + 1] = {kind = "label", size = 1, text = "Size includes frame. Lower order appears first."}
    end
    children[#children + 1] = controls
    children[#children + 1] = {kind = "label", size = 2, wrap = true, alert = state.failure ~= nil, text = state.failure or state.status or ""}
    return {kind = "column", padding = 1, gap = 0, children = children}

end
function definition.update(state: any, action: any, context: any): any
    if action.type == "close" or (action.type == "key" and action.key_type == "esc") or action.id == "close" then
        if state.dirty then state.confirm = "close"; context.stay() else context.close() end
    elseif action.type == "select" and action.id == "pages" then state.page = action.index
    elseif action.type == "select" and action.id == "instances" then state.selected = action.index
    elseif action.type == "change" then
        if action.id == "available" then state.available = action.value
        else
            local item: any = state.items[state.selected]
            if not item then return false end
            if action.id == "enabled" or action.id == "title" or action.id == "width" or action.id == "height" or action.id == "order" then
                item[action.id], state.dirty = action.value, true
            end
        end
    elseif action.type == "activate" then
        if action.id == "add" then
            local ok, err = model.add(state)
            state.status = ok and "Widget added. Apply to start it." or tostring(err)
        elseif action.id == "remove" then model.remove(state); state.status = "Removed from draft. Apply to stop it."
        elseif action.id == "apply" then
            local ok, message = definition.backend.save(state)
            state.status = tostring(message)
            if ok then state.confirm = nil end
        elseif action.id == "reload" then if state.dirty then state.confirm = "reload" else load(state) end
        elseif action.id == "discard" then
            if state.confirm == "close" then state.dirty = false; context.close() else load(state) end
        elseif action.id == "keep" then state.confirm = nil
        elseif action.id == "refresh" then state.status = definition.backend.refresh()
        else return false end
    elseif action.type ~= "resize" then return false end
end
return {main = app.main(definition), definition = definition}
