local catalog = require("catalog")
local model = {NAMESPACE = "app.desktop.widgets"}
function model.copy(value: any): any
    if type(value) ~= "table" then return value end
    local out: any = {}
    for k, v in pairs(value) do out[k] = model.copy(v) end
    return out
end
function model.definition(defs: any, id: any): any
    for _, entry in ipairs(defs) do if entry.id == id then return entry end end
    return nil
end
function model.is_instance(entry: any): boolean
    return entry.kind == "registry.entry" and type(entry.meta) == "table" and entry.meta.type == catalog.WIDGET_INSTANCE_TYPE
end
function model.item(entry: any, defs: any): any
    local data: any = entry.data or {}
    local definition: any = model.definition(defs, data.widget)
    local meta: any = definition and definition.meta or {}
    return {name = entry.name, original = model.copy(entry), config = model.copy(data.config or {}), widget = data.widget, enabled = data.enabled ~= false,
        title = tostring(data.title or meta.title or entry.name), width = tostring(data.width or meta.width or 20),
        height = tostring(data.height or meta.height or 5), order = tostring(data.order or meta.order or 100)}
end
function model.open(doc: any, defs: any): (any, any)
    if type(doc) ~= "table" or doc.namespace ~= model.NAMESPACE or type(doc.entries) ~= "table" then
        return nil, "Invalid widget declarations file"
    end
    local state: any = {document = model.copy(doc), definitions = defs, items = {}, selected = 0,
        available = defs[1] and defs[1].id or "", dirty = false, status = "Changes apply to all desktops."}
    local names: any = {}
    for _, entry in ipairs(doc.entries) do
        if type(entry.name) ~= "string" or names[entry.name] then return nil, "Invalid or duplicate declaration name" end
        names[entry.name] = true
        if model.is_instance(entry) then state.items[#state.items + 1] = model.item(entry, defs) end
    end
    if #state.items > 0 then state.selected = 1 end
    return state, nil
end
function model.add(state: any): (boolean, any)
    local definition: any = model.definition(state.definitions, state.available)
    if not definition then return false, "Choose an available widget first." end
    local taken: any = {}
    for _, entry in ipairs(state.document.entries) do taken[entry.name] = true end
    for _, item in ipairs(state.items) do taken[item.name] = true end
    local n = 1
    while taken["widget_" .. n] do n = n + 1 end
    state.items[#state.items + 1] = model.item({name = "widget_" .. n, kind = "registry.entry",
        meta = {type = catalog.WIDGET_INSTANCE_TYPE}, data = {widget = definition.id, config = {}}}, state.definitions)
    state.selected, state.dirty = #state.items, true
    return true, nil
end
function model.remove(state: any)
    if not state.items[state.selected] then return end
    table.remove(state.items :: {any}, math.tointeger(state.selected) or 1)
    state.selected, state.dirty = math.min(state.selected, #state.items), true
end
function model.build(state: any): (any, any)
    local doc: any = model.copy(state.document)
    doc.entries = {}
    for _, entry in ipairs(state.document.entries) do
        if not model.is_instance(entry) then doc.entries[#doc.entries + 1] = model.copy(entry) end
    end
    local records: any = {}
    for _, item in ipairs(state.items) do
        local entry: any = model.copy(item.original)
        local data: any = entry.data or {}
        for _, key in ipairs({"width", "height", "order"}) do
            local value = tonumber(item[key])
            if not value or not math.tointeger(value) then return nil, item.name .. ": " .. key .. " must be an integer" end
            data[key] = value
        end
        local problem = model.config_problem(item, state.definitions)
        if problem then return nil, problem end
        data.config = model.copy(item.config or {})
        data.title, data.enabled, data.widget = item.title, item.enabled, item.widget
        entry.data = data
        doc.entries[#doc.entries + 1] = entry
        records[#records + 1] = {id = model.NAMESPACE .. ":" .. item.name, kind = entry.kind, meta = entry.meta, data = data}
    end
    local _, err = catalog.widget_instances(state.definitions, records)
    if err then return nil, tostring(err) end
    return doc, nil
end
-- The host grid is independent of a widget's own configuration fields.
model.CELL_W, model.CELL_H = 10, 4
function model.grid_label(item: any): string
    local w, h = tonumber(item.width) or 0, tonumber(item.height) or 0
    if w % model.CELL_W == 0 and h % model.CELL_H == 0 and w >= 10 and w <= 30 and h >= 4 and h <= 12 then
        return tostring(w // model.CELL_W) .. " x " .. tostring(h // model.CELL_H)
    end
    return "Custom (" .. tostring(item.width) .. " x " .. tostring(item.height) .. ")"
end
function model.set_grid(item: any, x: any, y: any): boolean
    if type(x) ~= "number" or type(y) ~= "number" or x % 1 ~= 0 or y % 1 ~= 0 or x < 1 or x > 3 or y < 1 or y > 3 then return false end
    item.width, item.height = tostring(x * model.CELL_W), tostring(y * model.CELL_H)
    return true
end
function model.fields(item: any, defs: any): any
    local entry = item and model.definition(defs, item.widget)
    local settings = entry and entry.meta and entry.meta.settings
    return type(settings) == "table" and type(settings.fields) == "table" and settings.fields or {}
end
function model.config_problem(item: any, defs: any): any
    for _, field in ipairs(model.fields(item, defs)) do
        local value = item.config[field.key]
        if value == nil then value = field.default end
        if field.required and (value == nil or value == "") then return tostring(field.label or field.key) .. " is required" end
        if value ~= nil then
            if field.type == "text" and type(value) ~= "string" then return field.key .. " must be text" end
            if field.type == "boolean" and type(value) ~= "boolean" then return field.key .. " must be a boolean" end
            if field.type == "lookup" and type(value) ~= "table" then return field.key .. " must be a selected result" end
            if field.type == "select" then
                local found = false
                for _, option in ipairs(field.options or {}) do if option.value == value then found = true end end
                if not found then return field.key .. ": choose an available option" end
            end
        end
    end
    return nil
end
return model
