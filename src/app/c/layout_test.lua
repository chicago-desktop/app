-- The layout of drive C:.
--
-- What is checked is the rule, not the disk: that a namespace becomes
-- folders under the names the registry uses, that the Lua text is written
-- once and referred to from the declaration beside it, and that an entry
-- which cannot be placed is named rather than dropped.

local test = require("test")
local layout = require("layout")

local function by_path(files: any, path: any): any
    for _, file in ipairs(files) do
        if file.path == path then return file end
    end
    return nil
end

local function define_tests()
    test.describe("drive C layout", function()
        test.it("turns a namespace into folders, keeping the names as the registry spells them", function()
            local folder = layout.folder("chicago.shell.explorer:window")
            test.eq(folder, "Programs/chicago/shell/explorer")

            local files = layout.files({
                id = "chicago.shell.explorer:window", kind = "process.lua",
                meta = {title = "My Computer"},
                data = {source = "-- the window\nreturn {}\n", method = "main"},
            })
            test.eq(#files, 2, "the Lua text and the declaration")
            test.not_nil(by_path(files, "Programs/chicago/shell/explorer/window.lua"))
            test.not_nil(by_path(files, "Programs/chicago/shell/explorer/window.yaml"))
        end)

        test.it("gives two entries that differ only in case two files", function()
            -- Names in the registry are case-sensitive. Folding them would
            -- write both entries to one file, and the second would overwrite
            -- the first without a word.
            local files = layout.plan({
                {id = "app.c:Probe", kind = "registry.entry", data = {}},
                {id = "app.c:probe", kind = "registry.entry", data = {}},
            })
            test.eq(#files, 2)
            test.not_nil(by_path(files, "Programs/app/c/Probe.yaml"))
            test.not_nil(by_path(files, "Programs/app/c/probe.yaml"))
        end)

        test.it("writes the Lua text once and refers to it from the declaration", function()
            -- The registry holds the source inside the entry. Writing it into
            -- both files would put the same thing on the disk twice, and the
            -- two copies would disagree on the first edit.
            local files = layout.files({
                id = "app.c:writer", kind = "library.lua",
                data = {source = "return {}\n", modules = {"fs"}},
            })
            local source = by_path(files, "Programs/app/c/writer.lua")
            test.not_nil(source)
            test.eq(source.kind, "source")
            test.eq(source.text, "return {}\n")

            local declared = by_path(files, "Programs/app/c/writer.yaml")
            test.not_nil(declared)
            test.eq(declared.kind, "entry")
            test.eq(declared.entry.id, "app.c:writer", "the entry id is the real address")
            test.eq(declared.entry.data.source, "file://writer.lua",
                "the declaration points at the file beside it, as the author wrote it")
            test.eq(declared.entry.data.modules[1], "fs", "the rest of the entry is kept")
        end)

        test.it("gives an entry without Lua text its declaration alone", function()
            local files = layout.files({
                id = "app.c:c", kind = "registry.entry",
                meta = {type = "chicago.drive", title = "C:"},
                data = {fs = "app.c:drive_c", letter = "C"},
            })
            test.eq(#files, 1)
            test.eq(files[1].path, "Programs/app/c/c.yaml")
            test.eq(files[1].entry.meta.title, "C:")
        end)

        test.it("keeps a `source` field that is not Lua text", function()
            -- A kind that does not carry Lua may still have a field of that
            -- name meaning something else. Dropping it would make the YAML a
            -- quieter lie than no YAML at all.
            local files = layout.files({
                id = "app.c:probe", kind = "http.endpoint",
                data = {source = "somewhere else", method = "GET"},
            })
            test.eq(#files, 1, "no .lua for a kind that carries no Lua")
            test.eq(files[1].entry.data.source, "somewhere else")
        end)

        test.it("spells a name a filesystem would not take, rather than losing the entry", function()
            local files = layout.files({id = "app.c:01_settings", kind = "registry.entry", data = {}})
            test.eq(files[1].path, "Programs/app/c/01_settings.yaml")

            local odd = layout.files({id = "app.c:a/b", kind = "registry.entry", data = {}})
            test.eq(odd[1].path, "Programs/app/c/a_b.yaml",
                "a separator in a name becomes an underscore, not a second folder")
        end)

        test.it("names what it could not place instead of dropping it quietly", function()
            -- A malformed id must not cost the whole disk, and silence about
            -- it would make a missing folder look like a module that is not
            -- installed.
            local files, skipped = layout.plan({
                {id = "app.c:one", kind = "registry.entry", data = {}},
                {id = "no_colon_here", kind = "registry.entry", data = {}},
                {id = "app.c:two", kind = "library.lua", data = {source = "return 1\n"}},
            })
            test.eq(#files, 3, "one YAML, plus a YAML and a Lua file")
            test.eq(#skipped, 1)
            test.eq(skipped[1].id, "no_colon_here")
            test.is_true(tostring(skipped[1].reason):find("not an entry id", 1, true) ~= nil)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)

return {run = function(options) return run_cases(options) end}
