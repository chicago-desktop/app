-- Host adapter for the shared Workshop shelf. It uses the existing store.
local repo = require("repo")
local apps = require("apps")
local roster = require("roster")
local registry = require("registry")
local security = require("security")
local function describe(window: any, source: boolean): any
    return {name = window.name, title = window.title, entry = apps.entry_id(window.name),
        width = window.width, height = window.height, updated_at = window.updated_at,
        source = source and window.source or nil, modules = source and window.modules or nil,
        spec = source and window.spec or nil, group = window.group,
        live = registry.get(apps.entry_id(window.name)) ~= nil}
end
local function run(args: any): any
    if not security.actor() or not security.can("workshop.manage", "app.workshop:catalog") then
        return {success = false, error = "Workshop is a shared collection for administrators."}
    end
    if args.action == "list" then
        local saved, err = repo.list()
        if not saved then return {success = false, error = tostring(err)} end
        local out = {}
        for _, window in ipairs(saved) do out[#out + 1] = describe(window, false) end
        return {success = true, apps = out}
    elseif args.action == "get" then
        local window, err = repo.get(tostring(args.name or ""))
        if not window then return {success = false, error = tostring(err or "This tool is no longer saved. Refresh the collection.")} end
        return {success = true, app = describe(window, true)}
    elseif args.action == "agents" then
        local agents, truncated = roster.reachable(nil, "")
        return {success = true, agents = agents or {}, truncated = truncated == true}
    end
    return {success = false, error = "Unknown catalog action."}
end
local function handle(args: any): any
    local ok, result = pcall(run, type(args) == "table" and args or {})
    if not ok then return {success = false, error = tostring(result)} end
    return result
end
return {handle = handle}
