-- Drive C: the registry, laid out as folders and files.
--
-- Pure: registry entries in, a list of files out. Nothing here reads the
-- registry and nothing writes to disk — that is `app.c:writer` — so the
-- layout is checked without a running system. A rule that can be checked
-- only against a running system gets checked once, and then never.
--
-- The shape:
--
--   PROGRAMS/CHICAGO/SHELL/EXPLORER/WINDOW.LUA    the entry's Lua text
--   PROGRAMS/CHICAGO/SHELL/EXPLORER/WINDOW.YAML   the entry that declares it
--
-- The namespace becomes folders (a dot is one level down), the entry name
-- becomes the file, and both are upper case, the way a disk of that age
-- had them. Nothing is invented on the way: a module that is installed has
-- a folder, a module that is not has none, and the entry id — the real
-- address — is inside the YAML, not guessed from the path.
--
-- WHY THE SOURCE IS NOT REPEATED IN THE YAML. The registry holds the Lua
-- text inside the entry (`source: file://window.lua` is resolved at load
-- time), so writing it in both files would put the same thing on the disk
-- twice and let the two copies disagree. The YAML carries the reference the
-- author wrote instead — `source: file://WINDOW.LUA` — which is also what
-- the file beside it is called.

local layout = {}

-- The folder of the disk this module owns. One name, because three things
-- use it: the writer, the sweeper of files whose entries are gone, and the
-- tests.
layout.ROOT = "PROGRAMS"

-- The kinds whose `data.source` is Lua text. Taken from what the runtime
-- itself treats as source-carrying when it packs a module back into files;
-- an entry of any other kind gets its YAML and nothing else.
layout.SOURCE_KINDS = {
    ["function.lua"] = true,
    ["library.lua"] = true,
    ["process.lua"] = true,
    ["workflow.lua"] = true,
}

-- A path segment as it appears on this disk: upper case, and nothing in it
-- that a path separator could be mistaken for. A name the registry allows
-- but a filesystem does not is not dropped — it is spelled with an
-- underscore, because a missing file reads as "this module has no such
-- entry", which would be a lie.
local function segment(text: any): string
    local value = string.upper(tostring(text or ""))
    value = value:gsub("[/\\:%z]", "_")
    return value
end

-- split(id) -> namespace, name | nil, reason
--
-- An entry id is `namespace:name` and there is no slash in either half.
-- An id that is not of that shape is refused with a reason rather than
-- written somewhere approximate.
function layout.split(id: any): (any, any, any)
    local text = type(id) == "string" and id or ""
    local namespace, name = string.match(text, "^([^:]+):(.+)$")
    if not namespace or not name then
        return nil, nil, "not an entry id: " .. tostring(id)
    end
    return namespace, name, nil
end

-- folder(id) -> "PROGRAMS/CHICAGO/SHELL/EXPLORER" | nil, reason
function layout.folder(id: any): (any, any)
    local namespace, _, why = layout.split(id)
    if not namespace then return nil, why end

    local parts = {layout.ROOT}
    for piece in tostring(namespace):gmatch("[^%.]+") do
        parts[#parts + 1] = segment(piece)
    end
    return table.concat(parts, "/"), nil
end

-- files(record) -> a list of {path, kind, text?, entry?} | nil, reason
--
-- `kind` is "source" for the Lua text and "entry" for the declaration. The
-- declaration is handed over as a TABLE, not as YAML: encoding belongs to
-- the writer, which has the runtime's encoder, and a hand-rolled one here
-- would be a second YAML in the system.
function layout.files(record: any): (any, any)
    local entry: any = type(record) == "table" and record or {}
    local folder, why = layout.folder(entry.id)
    if not folder then return nil, why end

    local _, name = layout.split(entry.id)
    local base = folder .. "/" .. segment(name)

    local data: any = type(entry.data) == "table" and entry.data or {}
    local out: any = {}

    -- The Lua text first: it is what a person opens the folder for.
    local source = data.source
    local has_source = layout.SOURCE_KINDS[tostring(entry.kind)] == true
        and type(source) == "string" and source ~= ""
    if has_source then
        out[#out + 1] = {path = base .. ".LUA", kind = "source", text = source}
    end

    -- The declaration, with the source replaced by the reference to the file
    -- beside it. The copy is shallow on purpose: the writer encodes it and
    -- throws it away, and a deep copy of every entry on the disk would cost
    -- more than the whole rendering.
    local shown: any = {id = entry.id, kind = entry.kind}
    if type(entry.meta) == "table" then shown.meta = entry.meta end
    -- `source` is dropped ONLY when it is the Lua text that went into the
    -- .LUA file beside this one. An entry of another kind may carry a field
    -- of that name meaning something else entirely, and losing it would make
    -- the YAML a quieter lie than no YAML at all.
    local fields: any = {}
    for key, value in pairs(data) do
        if not (has_source and key == "source") then fields[key] = value end
    end
    if has_source then fields.source = "file://" .. segment(name) .. ".LUA" end
    if next(fields) ~= nil then shown.data = fields end

    out[#out + 1] = {path = base .. ".YAML", kind = "entry", entry = shown}
    return out, nil
end

-- plan(records) -> files, skipped
--
-- Everything the disk should hold, and the entries that could not be placed
-- with the reason each one was not. The skipped list is NOT an error: one
-- malformed id must not cost the whole disk, and silence about it would
-- make a missing folder look like a module that is not installed.
function layout.plan(records: any): (any, any)
    local files: any = {}
    local skipped: any = {}
    for _, record in ipairs(type(records) == "table" and records or {}) do
        local made, why = layout.files(record)
        if made then
            for _, file in ipairs(made) do files[#files + 1] = file end
        else
            skipped[#skipped + 1] = {id = (record :: any).id, reason = why}
        end
    end
    return files, skipped
end

return layout
