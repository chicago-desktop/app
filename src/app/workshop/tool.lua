-- WindowsWorkshop — an MCP tool: build a window of the Windows 95 shell in the
-- running runtime, open it, look at its screen, remove it.
--
-- Under MCP the tool runs under the token owner's actor in the
-- `kickside.mcp.security:session` scope, where `registry.apply` is forbidden
-- by an explicit deny. So the registry entry is applied not by the tool but by
-- the compositor: the tool puts the window into the workshop store (the same
-- one the compositor restores windows from at start) and asks it with the
-- `desktop.workshop` command. The body is parsed by the code shared with the
-- HTTP workshop (`apps.prepare`): two parsers would drift apart on the first
-- field.
--
-- The return is an envelope `{success, ...}`; a crash turns into `{success =
-- false, error}`: a tool that threw an exception is, to the model,
-- indistinguishable from emptiness.

local channel = require("channel")
local process = require("process")
local registry = require("registry")
local time = require("time")
local repo = require("repo")
local apps = require("apps")
local fs = require("fs")
local base64 = require("base64")
local gfx = require("gfx")
local desktop = require("desktop")

-- The Windows 95 shell and the base register under different families of
-- names; the tool asks both, and the first running desktop answers. A family
-- may have several desktops (terminal.ssh, one per connection) — any one will
-- do: the registry entry is shared, the others see the window when their menu
-- opens.
local SERVICES = {"windows.shell.desktop", "windows.tui_desktop.desktop"}
local REPLY_TOPIC = "desktop.reply"
local BUDGET = "3s"

-- Pictures of workshop windows: the `app.workshop:images` pack (an FS entry
-- with meta.type windows.images). The file is `<size>/<name>.png`; in a window
-- the picture is named `app.workshop:images/<name>`. The shell finds the pack
-- in the registry and rereads the file on request, so an uploaded picture
-- appears without a restart, and a replaced one takes the old one's place.
local PACK = "app.workshop:images"
local PACK_MAX = 256

local function unwrap(value: any): any
    if type(value) == "userdata" then
        local ok, decoded = pcall(function() return value:data() end)
        if ok and type(decoded) == "table" then return decoded end
        return {}
    end
    if type(value) ~= "table" then return {} end
    if value[1] ~= nil and #value > 0 then return unwrap(value[1]) end
    return value
end

local function await(): (any, any)
    local inbox = process.inbox()
    local expiry = time.after(BUDGET)
    while true do
        local result = channel.select({inbox:case_receive(), expiry:case_receive()})
        if result.channel == expiry then return nil, "the compositor did not answer within " .. BUDGET end
        if not result.ok then return nil, "the inbox closed while waiting for the compositor" end
        local message = result.value
        if message:topic() == REPLY_TOPIC then return unwrap(message:payload()), nil end
    end
end

-- ask(topic, body) -> answer | nil, reason, running
local function ask(topic: string, body: any): (any, any, boolean)
    local pid: any = nil
    for _, family in ipairs(SERVICES) do
        local live: any = desktop.desktops(family)
        if live[1] then pid = live[1].pid; break end
    end
    if not pid then
        return nil, "the desktop is not running: start the shell (`wippy run --host windows.shell:terminal windows`)", false
    end
    local payload: any = type(body) == "table" and body or {}
    payload.reply_to = process.pid()
    local sent, serr = process.send(tostring(pid), topic, payload)
    if not sent then return nil, "the command did not reach the compositor: " .. tostring(serr), true end
    local answer, aerr = await()
    if not answer then return nil, aerr, true end
    if answer.ok == false then return nil, tostring(answer.error or "the compositor refused without a reason"), true end
    return answer, nil, true
end

local actions = {}

-- build: save, apply through the compositor, optionally open right away.
function actions.build(args: any): any
    local window, verr = apps.prepare(args)
    if not window then return {success = false, error = tostring(verr)} end
    local existing = repo.get(window.name)
    local _, serr = repo.save(window)
    if serr then return {success = false, error = "store: " .. tostring(serr)} end

    local entry = apps.entry_id(window.name)
    local applied, aerr, running = ask("desktop.workshop", {name = window.name})
    local out: any = {
        success = true, name = window.name, entry = entry, title = window.title,
        modules = window.modules, imports = window.spec.imports, group = window.group,
        replaced = existing ~= nil,
        live = applied ~= nil and applied.live == true,
    }
    if not applied then
        if not running then
            out.note = "the desktop is not running: the window is saved and enters the registry on the next start"
        else
            -- The row is saved but there is no window: that is a refusal, and it is named.
            repo.delete(window.name)
            return {success = false, error = "the registry did not accept the window: " .. tostring(aerr)}
        end
    end
    if args.open == true and out.live then
        local opened, oerr = ask("desktop.open", {entry = entry, title = window.title, args = args.args})
        if opened then out.window = opened.window else out.open_error = tostring(oerr) end
    end
    if existing ~= nil and out.live then
        out.note = (out.note and out.note .. "; " or "") .. "windows already open from the previous build keep running until closed"
    end
    return out
end

function actions.remove(args: any): any
    local name = type(args.name) == "string" and args.name or ""
    if name == "" then return {success = false, error = "name is required"} end
    local existed, derr = repo.delete(name)
    if derr then return {success = false, error = "store: " .. tostring(derr)} end
    local removed, rerr, running = ask("desktop.workshop", {name = name, remove = true})
    return {
        success = true, name = name, existed = existed == true,
        unregistered = removed ~= nil,
        note = removed and "windows of this kind already open keep running until closed"
            or (running and ("entry not removed: " .. tostring(rerr)) or "the desktop is not running: the entry was removed from the store only"),
    }
end

function actions.list(args: any): any
    local windows, err = repo.list()
    if err then return {success = false, error = "store: " .. tostring(err)} end
    local out = {}
    for _, window in ipairs(windows or {}) do
        local id = apps.entry_id(window.name)
        out[#out + 1] = {
            name = window.name, title = window.title, entry = id, group = window.group,
            width = window.width, height = window.height, modules = window.modules,
            imports = window.spec and window.spec.imports or nil,
            pixel_render = window.spec and window.spec.pixel_render or nil,
            live = registry.get(id) ~= nil, updated_at = window.updated_at,
        }
    end
    return {success = true, apps = out}
end

function actions.windows(args: any): any
    local answer, err = ask("desktop.list", {})
    if not answer then return {success = false, error = tostring(err)} end
    return {success = true, windows = answer.windows, focused = answer.focused, screen = answer.screen,
        user = answer.user, notice = answer.notice, pixels = answer.pixels}
end

function actions.open(args: any): any
    local entry = type(args.entry) == "string" and args.entry or ""
    if entry == "" and type(args.name) == "string" and args.name ~= "" then entry = apps.entry_id(args.name) end
    if entry == "" then return {success = false, error = "entry or name is required"} end
    local answer, err = ask("desktop.open", {entry = entry, title = args.title, args = args.args, w = args.w, h = args.h})
    if not answer then return {success = false, error = tostring(err)} end
    return {success = true, window = answer.window}
end

function actions.screen(args: any): any
    local id = type(args.id) == "string" and args.id or ""
    if id == "" then return {success = false, error = "window id is required (see windows)"} end
    local answer, err = ask("desktop.screen", {id = id})
    if not answer then return {success = false, error = tostring(err)} end
    -- The rows as text too: the model reads the screen more easily as a whole.
    local rows: any = answer.rows or {}
    local plain = {}
    for index, row in ipairs(rows) do
        plain[index] = (tostring(row):gsub("\27%[[%d;]*[A-Za-z]", ""))
    end
    return {success = true, id = id, ready = answer.ready, rows = plain, text = table.concat(plain, "\n")}
end

function actions.type(args: any): any
    local id = type(args.id) == "string" and args.id or ""
    if id == "" then return {success = false, error = "window id is required"} end
    local answer, err = ask("desktop.type", {id = id, text = args.text, enter = args.enter == true})
    if not answer then return {success = false, error = tostring(err)} end
    return {success = true, id = id, sent = answer.sent}
end

function actions.close(args: any): any
    local id = type(args.id) == "string" and args.id or ""
    if id == "" then return {success = false, error = "window id is required"} end
    local answer, err = ask("desktop.close", {id = id})
    if not answer then return {success = false, error = tostring(err)} end
    return {success = true, id = id}
end

-- image: put a PNG into the workshop pack. The size is not asked for but read
-- from the picture: the pack folder is the size, and a picture outside its own
-- folder is refused by the shell ("is 8x8, expected 16x16"). The check uses the
-- same gfx.image the shell will read it with: otherwise garbage would land in
-- the pack and be refused only when drawn.
function actions.image(args: any): any
    local file = type(args.image_name) == "string" and args.image_name or ""
    if not file:match("^[%w_%-]+$") then
        return {success = false, error = "image_name: letters, digits, _ and - (a name, not a path)"}
    end
    local encoded = type(args.png) == "string" and args.png or ""
    if encoded == "" then return {success = false, error = "png: base64 of a PNG file is required"} end
    local bytes, derr = base64.decode(encoded)
    if not bytes then return {success = false, error = "png is not base64: " .. tostring(derr)} end
    local raster, ierr = gfx.image(bytes)
    if not raster then return {success = false, error = "png is not a picture gfx can read: " .. tostring(ierr)} end
    local w, h = raster:size()
    if w ~= h or w < 1 or w > PACK_MAX then
        return {success = false, error = string.format(
            "the picture is %dx%d: a pack picture is square, 1..%d px, and its size is its folder", w, h, PACK_MAX)}
    end
    local store, serr = fs.get(PACK)
    if not store then return {success = false, error = "pack " .. PACK .. " not opened: " .. tostring(serr)} end
    local folder = tostring(w)
    if not store:isdir(folder) then
        local _, merr = store:mkdir(folder)
        if merr then return {success = false, error = "folder " .. folder .. " not created: " .. tostring(merr)} end
    end
    local path = folder .. "/" .. file .. ".png"
    local existed = store:exists(path) == true
    local _, werr = store:writefile(path, bytes)
    if werr then return {success = false, error = path .. " not written: " .. tostring(werr)} end
    return {success = true, image = PACK .. "/" .. file, size = w, path = path, replaced = existed,
        note = "the shell draws it within a few seconds, no restart: name it in build image, an SDK image, button.image or ui.message image"}
end

-- images: what lies in the pack — the name for a window and its sizes.
function actions.images(args: any): any
    local store, serr = fs.get(PACK)
    if not store then return {success = false, error = "pack " .. PACK .. " not opened: " .. tostring(serr)} end
    local folders, state = store:readdir(".")
    if type(folders) ~= "function" then return {success = false, error = "pack not read: " .. tostring(state)} end
    local found: any = {}
    for folder in folders, state do
        local size = math.tointeger(tonumber(folder.name))
        -- `size and store:readdir(...)` would keep only the first value and
        -- lose the iterator's state: the call stands on its own line.
        if size then
            local files, fstate = store:readdir(folder.name)
            if type(files) == "function" then
                for entry in files, fstate do
                    local name = tostring(entry.name):match("^([%w_%-]+)%.png$")
                    if name then
                        found[name] = found[name] or {}
                        table.insert(found[name], size)
                    end
                end
            end
        end
    end
    local out = {}
    for name, sizes in pairs(found) do
        table.sort(sizes)
        out[#out + 1] = {image = PACK .. "/" .. name, sizes = sizes}
    end
    table.sort(out, function(a, b) return a.image < b.image end)
    return {success = true, pack = PACK, images = out}
end

local function run(args: any): any
    args = type(args) == "table" and args or {}
    local action = type(args.action) == "string" and args.action or ""
    local handler = actions[action]
    if not handler then
        return {success = false, error = "action: build, remove, list, windows, open, screen, type, close, image or images"}
    end
    return handler(args)
end

local function handle(args: any): any
    local ok, result = pcall(run, args)
    if not ok then return {success = false, error = tostring(result)} end
    return result
end

return {handle = handle}
