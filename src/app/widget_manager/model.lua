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
    return {name = entry.name, original = model.copy(entry), widget = data.widget, enabled = data.enabled ~= false,
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
        data.title, data.enabled, data.widget = item.title, item.enabled, item.widget
        entry.data = data
        doc.entries[#doc.entries + 1] = entry
        records[#records + 1] = {id = model.NAMESPACE .. ":" .. item.name, kind = entry.kind, meta = entry.meta, data = data}
    end
    local _, err = catalog.widget_instances(state.definitions, records)
    if err then return nil, tostring(err) end
    return doc, nil
end
return model
