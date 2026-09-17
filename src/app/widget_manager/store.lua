local fs = require("fs")
local yaml = require("yaml")
local registry = require("registry")
local gov = require("gov")
local model = require("model")
local writer = require("writer")
local control = require("control")
local store = {}
local FILE, DRIVE = "_index.yaml", "app.desktop.widget_manager:source"

function store.load(): (any, any)
    local handle, err = fs.get(DRIVE)
    if not handle then return nil, "Cannot open settings: " .. tostring(err) end
    local text, rerr = handle:readfile(FILE)
    if not text then return nil, "Cannot read settings: " .. tostring(rerr) end
    local doc, derr = yaml.decode(text)
    if not doc then return nil, "Cannot parse settings: " .. tostring(derr) end
    local defs, ferr = registry.find({[".kind"] = "process.lua", ["meta.type"] = "chicago.widget"})
    if not defs then return nil, tostring(ferr) end
    table.sort(defs, function(a: any, b: any): boolean return a.id < b.id end)
    local state, merr = model.open(doc, defs)
    if not state then return nil, merr end
    state.before, state.pending = text, false
    return state, nil
end

function store.commit(state: any, handle: any, upload: any, refresh: any): (boolean, any)
    local doc, err = model.build(state)
    if not doc then return false, err end
    local text, eerr = yaml.encode(doc)
    if not text then return false, tostring(eerr) end
    local written, werr = writer.write_file(handle, FILE, tostring(state.before), text)
    if not written then return false, tostring(werr) end
    state.before, state.document, state.dirty, state.pending = text, doc, false, true
    -- Reuse governance; the window has no registry.apply permission. The
    -- one-shot allow-list never changes Keeper's global configuration.
    local called, result, aerr = pcall(upload, {
        managed_namespaces = {model.NAMESPACE}, sync = false, timeout = "15s",
    })
    if not called then aerr, result = result, nil end
    if not result then return false, "Saved to disk; apply not confirmed: " .. tostring(aerr) .. ". Apply again to retry." end
    state.pending = false
    local refreshed_ok, refreshed = pcall(refresh)
    if not refreshed_ok then return true, "Saved. Desktop refresh failed: " .. tostring(refreshed) end
    if not refreshed.refreshed then return true, "Saved. Desktop refresh: " .. tostring(refreshed.reason) end
    return true, "Saved and applied to all desktops."
end

-- Upload already-written host YAML without exporting it to a second namespace path.
-- sync_from_fs currently drops the sync option; use the same governance client directly.
function store.upload(input: any): (any, any)
    local result, err = gov.request_upload({managed_namespaces = {model.NAMESPACE}, sync = false}, input.timeout or "15s")
    return result, err
end

function store.save(state: any): (boolean, any)
    local handle, err = fs.get(DRIVE)
    if not handle then return false, tostring(err) end
    local ok, message = store.commit(state, handle, store.upload, control.refresh)
    return ok, message
end

function store.refresh(): any
    local result = control.refresh()
    return result.refreshed and "Desktops refreshed." or "Refresh: " .. tostring(result.reason)
end
return store
