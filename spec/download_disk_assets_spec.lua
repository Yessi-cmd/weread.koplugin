package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

package.preload["logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["bit"] = function()
    return { rshift = function(value, bits) return math.floor(value / 2 ^ bits) end }
end
package.preload["weread.lib.crypto"] = function()
    return { md5_hex = function() return string.rep("a", 32) end }
end
package.preload["weread.lib.reader_state"] = function() return {} end
package.preload["weread.lib.protocol"] = function()
    return {
        reader_url = function(book_id, chapter_uid)
            return "https://weread.qq.com/reader/" .. tostring(book_id)
                .. "/" .. tostring(chapter_uid or "")
        end,
    }
end
package.preload["weread.lib.thoughts"] = function() return {} end

local archive_calls = {}
local archive_should_fail = false
package.preload["ffi/archiver"] = function()
    local Reader = {}
    function Reader:new() return setmetatable({}, { __index = self }) end
    function Reader:open(path)
        self.path = path
        self.index = 0
        return true
    end
    function Reader:iterate()
        local entries = {
            { path = "converted/page-1.jpeg", mode = "file", size = 7 },
            { path = "converted/metadata.json", mode = "file", size = 2 },
        }
        return function()
            self.index = self.index + 1
            return entries[self.index]
        end
    end
    function Reader:extractToMemory(path)
        if path:match("[.]jpeg$") then return "\255\216\255jpeg" end
        return "{}"
    end
    function Reader:close() end
    local Writer = {}
    function Writer:new() return setmetatable({}, { __index = self }) end
    function Writer:open(path)
        self.path = path
        local file = assert(io.open(path, "wb"))
        file:write("partial archive")
        file:close()
        return true
    end
    function Writer:setZipCompression(method)
        archive_calls[#archive_calls + 1] = { kind = "compression", method = method }
        return true
    end
    function Writer:addFileFromMemory(name, data)
        archive_calls[#archive_calls + 1] = {
            kind = "memory", name = name, bytes = #data, data = data,
        }
        return true
    end
    function Writer:addPath(name, path, recursive)
        archive_calls[#archive_calls + 1] = {
            kind = "path", name = name, path = path, recursive = recursive,
        }
        if archive_should_fail then
            self.err = "injected archive failure"
            return false
        end
        -- Match KOReader's wrapper: a successful disk walk terminates at EOF
        -- and currently returns false without setting err.
        return false
    end
    function Writer:close() end
    return { Reader = Reader, Writer = Writer }
end
package.preload["ffi/util"] = function()
    return {
        purgeDir = function(path)
            return os.execute("rm -rf " .. string.format("%q", path))
        end,
    }
end
package.preload["lfs"] = function()
    return {
        attributes = function(path, attribute)
            local probe = io.popen("test -d " .. string.format("%q", path)
                .. " && echo directory")
            local mode = probe:read("*l")
            probe:close()
            if attribute == "mode" then return mode end
            return mode and { mode = mode } or nil
        end,
        dir = function(path)
            local listing = io.popen("ls -a " .. string.format("%q", path))
            return function()
                local name = listing:read("*l")
                if not name then listing:close() end
                return name
            end
        end,
    }
end

local Content = require("weread.lib.content")

local root = os.tmpname()
os.remove(root)
assert(os.execute("mkdir -p " .. string.format("%q", root)))
local book_dir = root .. "/book"
assert(os.execute("mkdir -p " .. string.format("%q", book_dir)))
assert(require("weread.lib.cache_safety").mark(book_dir, "book"))
local workspace = {
    path = book_dir .. "/.weread-download-100-123456",
}
workspace.incoming_dir = workspace.path .. "/incoming"
workspace.asset_dir = workspace.path .. "/images"
workspace.body_dir = workspace.path .. "/bodies"
workspace.package_text_dir = workspace.path .. "/package-text"
assert(os.execute("mkdir -p " .. string.format("%q", workspace.incoming_dir)))
assert(os.execute("mkdir -p " .. string.format("%q", workspace.asset_dir)))
assert(os.execute("mkdir -p " .. string.format("%q", workspace.body_dir)))
assert(os.execute("mkdir -p " .. string.format("%q", workspace.package_text_dir)))
local available_disk = Content.available_disk_bytes(workspace.path)
expect(type(available_disk) == "number" and available_disk > 0,
    "free-space preflight could not inspect the download filesystem")

local function tar_header(name, size)
    local header = name .. string.rep("\0", 100 - #name)
    header = header .. string.rep("0", 24)
    local octal = string.format("%011o\0", size)
    header = header .. octal
    header = header .. string.rep("0", 20)
    header = header .. "0"
    return header .. string.rep("\0", 512 - #header)
end

local image_count = 24
local image_size = 256 * 1024
local fake_client = {}
function fake_client:download_to_file(_url, path)
    local file = assert(io.open(path, "wb"))
    for index = 1, image_count do
        local name = string.format("image-%03d.jpg", index)
        file:write(tar_header(name, image_size))
        file:write("\255\216\255", string.rep("x", image_size - 3))
        local padding = (512 - image_size % 512) % 512
        if padding > 0 then file:write(string.rep("\0", padding)) end
    end
    file:write(string.rep("\0", 1024))
    file:close()
    return path
end

collectgarbage("collect")
local before_kb = collectgarbage("count")
local assets, src_map = Content.download_chapter_assets_to_files(
    fake_client, { book_id = "book" },
    { chapterUid = 7, tar = "https://example.test/chapter.tar" },
    {}, workspace)
collectgarbage("collect")
local after_kb = collectgarbage("count")
expect(#assets == image_count, "not all TAR images were extracted")
expect(assets[1].data == nil and type(assets[1].path) == "string",
    "extracted image remained resident in an asset data field")
expect(src_map["image-001.jpg"] == "../images/image-001.jpg",
    "file-backed image map was wrong")
expect(after_kb - before_kb < 1024,
    "file-backed extraction retained resource-sized Lua memory")
local first = assert(io.open(assets[1].path, "rb"))
expect(first:read(3) == "\255\216\255", "extracted image bytes were corrupted")
first:close()
expect(io.open(workspace.incoming_dir .. "/chapter-7.tar", "rb") == nil,
    "source TAR was not removed after extraction")

function fake_client:download_to_file(_url, path)
    local file = assert(io.open(path, "wb"))
    file:write("PK\003\004fake converted-book ZIP")
    file:close()
    return path
end
local zip_assets, zip_src_map = Content.download_chapter_assets_to_files(
    fake_client, { book_id = "converted-book" },
    { chapterUid = 1, tar = "https://example.test/resources" },
    {}, workspace)
expect(#zip_assets == 1, "ZIP image resources were not extracted")
local zip_image = assert(io.open(zip_assets[1].path, "rb"))
expect(zip_image:read(3) == "\255\216\255",
    "ZIP image was not staged on disk")
zip_image:close()
expect(zip_src_map["page-1.jpeg"] == "../" .. zip_assets[1].href,
    "ZIP image map was wrong")
expect(io.open(workspace.incoming_dir .. "/chapter-1.tar", "rb") == nil,
    "source ZIP was not removed after extraction")

local settings = {
    cache_dir = root,
    get = function(_self, _key, default) return default end,
}
local book = { book_id = "book", title = "Disk Assets", cache_dir = book_dir }
local output = Content.save_book_epub(settings, book,
    { { chapterUid = 7, title = "Chapter" } },
    { ["7"] = "<p>body</p>" }, "book", assets, "body{}")
local used_path = false
local path_calls = 0
for _, call in ipairs(archive_calls) do
    if call.kind == "path" then
        path_calls = path_calls + 1
        if call.name == "OEBPS/images" then
            used_path = call.path == workspace.asset_dir
                and call.recursive == true
        end
    end
end
expect(used_path and path_calls == 1,
    "EPUB writer did not stream the staged image directory with one addPath")
expect(io.open(output .. ".part", "rb") == nil,
    "successful EPUB build left a partial archive")

local long_name = Content.filename_safe(string.rep("超长书名", 100))
expect(#long_name <= 180 and long_name:match("%-aaaaaaaaaa$"),
    "long filenames were not safely shortened with a stable suffix")

local staged_chapters = {}
local staged_bodies = {}
for index = 1, 40 do
    local uid = tostring(1000 + index)
    staged_chapters[index] = {
        chapterUid = uid,
        chapterIdx = index,
        title = "Staged " .. tostring(index),
    }
    staged_bodies[uid] = Content.stage_chapter_body(
        workspace, index, "<p>" .. string.rep("正文", 64 * 1024) .. "</p>")
end
collectgarbage("collect")
local staged_before_kb = collectgarbage("count")
archive_calls = {}
Content.save_book_epub(settings, book, staged_chapters, staged_bodies,
    "staged", {}, "body{}")
collectgarbage("collect")
local staged_after_kb = collectgarbage("count")
local streamed_text_tree = false
local in_memory_chapters = 0
for _, call in ipairs(archive_calls) do
    if call.kind == "path" and call.name == "OEBPS/text" then
        streamed_text_tree = call.path == workspace.package_text_dir
            and call.recursive == true
    elseif call.kind == "memory"
        and call.name:match("OEBPS/text/chapter%-%d+%.xhtml$") then
        in_memory_chapters = in_memory_chapters + 1
    end
end
expect(streamed_text_tree and in_memory_chapters == 0,
    "staged chapter bodies were not streamed as one directory tree")
expect(staged_after_kb - staged_before_kb < 2048,
    "EPUB assembly retained all staged chapter bodies in Lua memory")
local packaged_chapter = assert(io.open(
    workspace.package_text_dir .. "/chapter-040.xhtml", "rb"))
local packaged_text = packaged_chapter:read("*a")
packaged_chapter:close()
expect(packaged_text:find("Staged 40", 1, true)
        and packaged_text:find("正文", 1, true),
    "staged chapter wrapper was not written correctly")

Content.save_book_epub(settings, book, {
    { chapterUid = 1, title = "One" },
    { chapterUid = 2, title = "Two" },
}, {
    ["1"] = "<p>one</p>",
    ["2"] = "<p>two</p>",
}, "book", {}, ".shared{}", nil, {
    ["1"] = ".one{background:url(images/image.png)}",
    ["2"] = ".two{background:url(images/image-2.png)}",
})
local chapter_css_files = {}
local chapter_links = {}
for _, call in ipairs(archive_calls) do
    if call.kind == "memory" and call.name:match("OEBPS/chapter%-%d+%.css$") then
        chapter_css_files[call.name] = call.data
    elseif call.kind == "memory"
        and call.name:match("OEBPS/text/chapter%-%d+%.xhtml$") then
        chapter_links[call.name] = call.data
    end
end
expect(chapter_css_files["OEBPS/chapter-001.css"]:find(
        "images/image.png", 1, true)
        and not chapter_css_files["OEBPS/chapter-001.css"]:find(
            "image-2.png", 1, true)
        and chapter_css_files["OEBPS/chapter-002.css"]:find(
            "images/image-2.png", 1, true),
    "same-named CSS resources were not isolated by chapter")
expect(chapter_links["OEBPS/text/chapter-001.xhtml"]:find(
        'href="../chapter-001.css"', 1, true)
        and chapter_links["OEBPS/text/chapter-002.xhtml"]:find(
            'href="../chapter-002.css"', 1, true),
    "chapter XHTML did not link its own stylesheet")

Content.save_book_epub(settings, book, {
    { chapterUid = 1, chapterIdx = 1, title = "" },
    { chapterUid = 2, chapterIdx = 2, title = "" },
}, {
    ["1"] = "<p>one</p>",
    ["2"] = "<p>two</p>",
}, "untitled", {}, "")
local inferred_nav
local inferred_second_chapter
for _, call in ipairs(archive_calls) do
    if call.kind == "memory" and call.name == "OEBPS/nav.xhtml" then
        inferred_nav = call.data
    elseif call.kind == "memory"
        and call.name == "OEBPS/text/chapter-002.xhtml" then
        inferred_second_chapter = call.data
    end
end
expect(inferred_nav and inferred_nav:find("第2章", 1, true)
        and inferred_second_chapter
        and inferred_second_chapter:find(
            '<header class="wr-generated-chapter-heading"><h1>第2章</h1>',
            1, true),
    "inferred chapter title was not written to EPUB navigation and body")

local old = assert(io.open(output, "wb"))
old:write("known-good-old-epub")
old:close()
archive_should_fail = true
local ok = pcall(function()
    Content.save_book_epub(settings, book,
        { { chapterUid = 7, title = "Chapter" } },
        { ["7"] = "<p>body</p>" }, "book", assets, "body{}")
end)
expect(not ok, "injected archive failure was not propagated")
old = assert(io.open(output, "rb"))
expect(old:read("*a") == "known-good-old-epub",
    "failed atomic build damaged the previous EPUB")
old:close()
expect(io.open(output .. ".part", "rb") == nil,
    "failed EPUB build left a partial archive")

local stale = book_dir .. "/.weread-download-200-654321"
assert(os.execute("mkdir -p " .. string.format("%q", stale)))
local orphan = assert(io.open(book_dir .. "/orphan.epub.part", "wb"))
orphan:write("partial")
orphan:close()
local recovery_settings = {
    cache_dir = root,
    get = function(_self, key, default)
        if key == "books" then
            return { book = { book_id = "book", cache_dir = book_dir } }
        end
        return default
    end,
}
local removed = Content.cleanup_stale_downloads(recovery_settings)
expect(removed == 3 and io.open(book_dir .. "/orphan.epub.part", "rb") == nil,
    "startup recovery did not remove stale workspace and partial EPUB: "
        .. tostring(removed))

local lfs = require("lfs")
expect(lfs.attributes(workspace.path, "mode") == nil,
    "startup recovery did not remove the active-looking stale workspace")
assert(os.execute("rm -rf " .. string.format("%q", root)))
print(("download_disk_assets_spec: %d checks"):format(checks))
