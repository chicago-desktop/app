-- Drive C: the service that writes the registry out as a disk.
--
-- The runtime has two kinds of filesystem — a real directory and bytes
-- frozen into a package — and none whose contents are produced by code. A
-- disk invented inside the folder window would be visible only there:
-- Notepad, the picture viewer and the file dialogs open a file as
-- "filesystem entry + path". So the disk is written out, and every program
-- that can open a file opens these with no change at all.
--
-- What it does, once at start and then on a tick: read the registry, ask
-- `layout` where each entry goes, write what changed, and remove what no
-- longer has an entry behind it.
--
-- WHAT IT DOES NOT DO. It does not edit the registry, it holds no database
-- and it answers no requests. Its rights are three: find entries, read them,
-- and open its own filesystem.

local channel = require("channel")
local fs = require("fs")
local logger = require("logger")
local process = require("process")
local registry = require("registry")
local time = require("time")
local yaml = require("yaml")

local layout = require("layout")

-- How often the disk is brought back in step with the registry. A minute is
-- chosen against what changes it: an installed or removed module, a live
-- update through keeper. Nothing here is on a person's critical path — the
-- files are for reading, not for the system to run from.
local TICK = "60s"

-- The disk holds a few thousand small files. Reading every one of them back
-- on every tick to see whether it changed would cost more than the rendering
-- itself, so what was written is remembered here, by path, and only a file
-- whose text really differs is written again. A restart forgets it and
-- writes the disk once, which is what a restart should do.
local written: any = {}

local log = logger:named("app.c.writer")

-- Everything a function calls is declared above it: a `local` below its
-- reader is a global there, that is nil, and it fails silently.

local function encode(file: any): (any, any)
    if file.kind == "source" then return tostring(file.text), nil end
    local text, err = yaml.encode(file.entry)
    if err or type(text) ~= "string" then
        return nil, "entry not encoded: " .. tostring(err or "no text")
    end
    return text, nil
end

-- The folders of a path, from the top down. `mkdir` is called for each
-- level: a filesystem that creates intermediate folders by itself and one
-- that does not would differ here silently, and the second kind would leave
-- the disk empty with no error anybody sees.
local function ensure_folders(handle: any, path: any)
    local parts: any = {}
    for piece in tostring(path):gmatch("[^/]+") do parts[#parts + 1] = piece end
    local at = ""
    for index = 1, #parts - 1 do
        at = at == "" and parts[index] or (at .. "/" .. parts[index])
        handle:mkdir("/" .. at)
    end
end

-- Write one file, and say whether it was really written. A file whose text
-- is the one we last wrote is left alone.
local function put(handle: any, file: any): (boolean, any)
    local text, why = encode(file)
    if not text then return false, why end
    if written[file.path] == text then return false, nil end

    ensure_folders(handle, file.path)
    local ok, err = handle:writefile("/" .. file.path, text, "w")
    if not ok then return false, "not written: " .. tostring(err) end
    written[file.path] = text
    return true, nil
end

-- Remove the files of entries that are gone. Walked from what WE wrote, not
-- from the disk: a sweep of the whole directory would happily delete
-- something a person put there, and this service has no business deciding
-- that a file it did not write is rubbish.
local function sweep(handle: any, expected: any): number
    local gone = 0
    for path in pairs(written) do
        if not expected[path] then
            handle:remove("/" .. path)
            written[path] = nil
            gone = gone + 1
        end
    end
    return gone
end

-- One pass: the registry as it is now, written out.
local function render(): (any, any)
    local handle, err = fs.get("app.c:drive_c")
    if err or not handle then
        return nil, "drive not opened: " .. tostring(err or "no such entry")
    end

    local records, find_err = registry.find({})
    if find_err or type(records) ~= "table" then
        return nil, "registry not read: " .. tostring(find_err or "the answer is not a list")
    end

    local files, skipped = layout.plan(records)

    local expected: any = {}
    local put_count, failed = 0, 0
    for _, file in ipairs(files) do
        expected[file.path] = true
        local did, why = put(handle, file)
        if did then put_count = put_count + 1 end
        -- A file that could not be written is named once and does not stop
        -- the rest: one bad entry must not cost the whole disk.
        if why then
            failed = failed + 1
            log:warn("file not written", {path = file.path, error = tostring(why)})
        end
    end

    local gone = sweep(handle, expected)
    return {files = #files, written = put_count, removed = gone,
            failed = failed, skipped = #skipped}, nil
end

local function pass()
    local report, err = render()
    if err then
        -- A failure here is not fatal: the disk is for reading, and the next
        -- tick tries again. It is said out loud, because a failure told to
        -- nobody is how a disk quietly goes stale.
        log:warn("drive C: not rendered", {error = tostring(err)})
        return
    end
    log:info("drive C: rendered", report)
end

local function main()
    log:info("drive C: rendering the registry")

    -- The events channel is taken before the first pass: a service asked to
    -- stop during its first rendering must still hear it. The ticker is made
    -- anew after every tick — `time.after` is one shot, and a ticker that is
    -- not renewed leaves the loop waiting for a message that never comes,
    -- with the service alive and the disk frozen.
    local events = process.events()
    local ticker = time.after(TICK)

    pass()

    while true do
        local picked = channel.select({events:case_receive(), ticker:case_receive()})
        if not picked.ok then break end
        if picked.channel == events then
            if picked.value and picked.value.kind == process.event.CANCEL then break end
        else
            ticker = time.after(TICK)
            pass()
        end
    end

    log:info("drive C: writer stopped")
    return {status = "stopped"}
end

return {main = main, render = render}
