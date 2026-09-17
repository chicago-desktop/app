local app = require("app")
local model = require("model")
local store = require("store")
local process = require("process")
local json = require("json")
local definition: any = {backend = store}
local function current(state: any): any return state.items[state.selected] end
local function defaults(state: any)
    local item = current(state)
    if not item then return end
    for _, field in ipairs(model.fields(item, state.definitions)) do
        if item.config[field.key] == nil and field.default ~= nil then item.config[field.key] = model.copy(field.default) end
    end
end
function definition.init(args: any, context: any): any
    if type(args) == "string" then args = json.decode(tostring(args)) end
    args = type(args) == "table" and args or {}
    local state, err = definition.backend.load()
    if not state then return {items = {}, definitions = {}, selected = 0, failure = tostring(err)} end
    state.mode, state.page, state.channels = args.mode or "edit", 1, {}
    if state.mode == "add" then
        model.add(state)
        if current(state) then model.set_grid(current(state), 2, 2) end
    else
        state.selected = 0
        for i, item in ipairs(state.items) do if item.name == args.name then state.selected = i end end
        if not current(state) then state.failure = "This widget no longer exists. Close and reopen its properties." end
    end
    defaults(state)
    state.status = state.mode == "add" and "Choose a widget and its settings." or "Changes affect only this instance."
    return state
end
local function label(value: any, field: any): string
    if type(value) ~= "table" then return "Not selected" end
    local parts = {}
    for _, key in ipairs(field.label_fields or {"name"}) do
        if value[key] and tostring(value[key]) ~= "" then parts[#parts + 1] = tostring(value[key]) end
    end
    return table.concat(parts, ", ")
end
local function input(id: string, title: string, value: any): any
    return {kind = "row", size = 1, gap = 1, children = {{kind = "label", size = 9, text = title},
        {kind = "input", id = id, text = tostring(value or "")}}}
end
function definition.view(state: any, context: any): any
    local item = current(state)
    local children: any = {}
    if not item then
        children = {{kind = "label", wrap = true, text = state.failure or "No widget selected"}}
    else
        if state.mode == "add" then
            local options = {}
            for _, entry in ipairs(state.definitions) do options[#options + 1] = {value = entry.id, label = entry.meta.title or entry.id} end
            children[#children + 1] = {kind = "select", id = "definition", size = 2, options = options, value = item.widget}
        end
        local body: any = {}
        if state.page == 1 then
            body[#body + 1] = input("title", "Title", item.title)
            body[#body + 1] = {kind = "checkbox", id = "enabled", text = "Enabled", checked = item.enabled, size = 1}
            body[#body + 1] = {kind = "label", size = 1, text = "Size: " .. model.grid_label(item)}
            for y = 1, 3 do
                local row: any = {kind = "row", size = (tonumber(context.height) or 24) < 23 and 1 or 2, gap = 1, children = {}}
                for x = 1, 3 do
                    local text = x .. " x " .. y
                    row.children[#row.children + 1] = {kind = "button", id = "size_" .. x .. "_" .. y,
                        text = model.grid_label(item) == text and ("[" .. text .. "]") or text}
                end
                body[#body + 1] = row
            end
            body[#body + 1] = input("order", "Order", item.order)
        else
            for _, field in ipairs(model.fields(item, state.definitions)) do
                local id, value = "config_" .. field.key, item.config[field.key]
                if field.type == "lookup" then
                    body[#body + 1] = {kind = "label", size = 2, wrap = true, text = field.label .. ": " .. label(value, field)}
                    body[#body + 1] = {kind = "row", size = 2, gap = 1, children = {
                        {kind = "input", id = id, text = state.query or "", placeholder = field.placeholder or "Search"},
                        {kind = "button", id = "search_" .. field.key, size = 9, text = "Search"}}}
                    local rows = {}
                    for i, result in ipairs(state.results or {}) do rows[#rows + 1] = {id = i, text = label(result, field)} end
                    body[#body + 1] = {kind = "list", id = "results_" .. field.key, items = rows, selected = state.result_index or 0}
                    body[#body + 1] = {kind = "button", id = "use_" .. field.key, size = 2, text = "Use selected", disabled = not (state.results and state.results[state.result_index])}
                elseif field.type == "select" then
                    body[#body + 1] = {kind = "label", size = 1, text = field.label}
                    body[#body + 1] = {kind = "select", id = id, size = 2, options = field.options, value = value}
                elseif field.type == "boolean" then
                    body[#body + 1] = {kind = "checkbox", id = id, size = 1, text = field.label, checked = value == true}
                else body[#body + 1] = input(id, tostring(field.label), value) end
            end
            if #body == 0 then body = {{kind = "label", text = "This widget provides no additional settings."}} end
        end
        children[#children + 1] = {kind = "tabs", id = "pages", labels = {"General", "Widget settings"}, active = state.page, children = body}
    end
    local actions: any = state.confirm and {
        {kind = "button", id = "discard", text = "Discard"}, {kind = "button", id = "keep", text = "Back"}} or {
        {kind = "button", id = "save", text = state.mode == "add" and "Add widget" or "Save", default = true, disabled = not item or state.failure ~= nil},
        {kind = "button", id = "close", text = "Cancel"}}
    children[#children + 1] = {kind = "row", size = 2, gap = 1, children = actions}
    children[#children + 1] = {kind = "label", size = 3, wrap = true, alert = state.failure ~= nil, text = state.failure or state.status or ""}
    return {kind = "column", padding = 1, children = children}
end
local function find_field(state: any, key: string): any
    for _, field in ipairs(model.fields(current(state), state.definitions)) do if field.key == key then return field end end
    return nil
end
function definition.update(state: any, action: any, context: any): any
    local item = current(state)
    local id = tostring(action.id or "")
    if action.type == "close" or id == "close" or (action.type == "key" and action.key_type == "esc") then
        if state.dirty then state.confirm = true; context.stay() else context.close() end
    elseif id == "discard" then state.dirty = false; context.close()
    elseif id == "keep" then state.confirm = false
    elseif action.type == "select" and id == "pages" then state.page = action.index
    elseif action.type == "channel" then
        if not action.ok then state.status = "Search service disconnected"; return end
        local payload = action.value:payload()
        if type(payload) == "userdata" then payload = payload:data() end
        if type(payload) == "table" and payload[1] then payload = payload[1] end
        if type(payload) ~= "table" or payload.query ~= state.query then return false end
        state.results, state.result_index = payload.results or {}, 0
        state.status = payload.ok == false and tostring(payload.error) or (#state.results == 0 and "No results" or "Select a result, then Use selected.")
    elseif not item then return false
    elseif action.type == "select" and id:sub(1, 8) == "results_" then state.result_index = action.index
    elseif action.type == "change" then
        if id == "definition" and state.mode == "add" then
            model.remove(state); state.available = action.value; model.add(state)
            model.set_grid(current(state), 2, 2); defaults(state)
            state.results, state.query, state.result_index = {}, "", 0
        elseif id == "title" or id == "order" or id == "enabled" then item[id], state.dirty = action.value, true
        elseif id:sub(1, 7) == "config_" then
            local field = find_field(state, id:sub(8))
            if field and field.type == "lookup" then state.query, state.results, state.result_index = action.value, {}, 0
            elseif field then item.config[field.key], state.dirty = action.value, true end
        end
    elseif action.type == "activate" then
        if id == "save" then
            local ok, message = definition.backend.save(state)
            state.status = tostring(message)
            if ok then context.close() end
        elseif id:sub(1, 5) == "size_" then
            local x, y = id:match("^size_(%d)_(%d)$")
            if model.set_grid(item, tonumber(x), tonumber(y)) then state.dirty = true end
        elseif id:sub(1, 7) == "search_" then
            local field = find_field(state, id:sub(8))
            if not field or not field.provider then return false end
            local provider = field.provider
            state.query = tostring(state.query or "")
            if not state.channels[provider.reply] then
                local replies = process.listen(tostring(provider.reply), {message = true})
                state.channels[provider.reply] = replies; context.watch(replies)
            end
            local pid = process.registry.lookup(tostring(provider.service))
            if not pid then state.status = "Search service is not running"; return end
            local sent, err = process.send(pid, tostring(provider.topic), {op = provider.operation, query = state.query or ""})
            state.status = sent and "Searching..." or tostring(err)
        elseif id:sub(1, 4) == "use_" then
            local field = find_field(state, id:sub(5))
            local result = state.results and state.results[state.result_index]
            if field and result then item.config[field.key], state.dirty = model.copy(result), true; state.status = "Selected: " .. label(result, field) end
        else return false end
    elseif action.type ~= "resize" then return false end
end
function definition.dispose(state: any, context: any)
    for _, ch in pairs(state.channels or {}) do process.unlisten(ch) end
end
return {main = app.main(definition), definition = definition}
