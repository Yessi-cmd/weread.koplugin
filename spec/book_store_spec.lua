package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local encoded_values = {}
local encoded_index = 0
local function deepcopy(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for key, item in pairs(value) do copy[key] = deepcopy(item) end
    return copy
end

package.preload["json"] = function()
    return {
        encode = function(value)
            encoded_index = encoded_index + 1
            local token = "json-fixture-" .. tostring(encoded_index)
            encoded_values[token] = deepcopy(value)
            return token
        end,
        decode = function(token)
            assert(encoded_values[token], "unknown JSON fixture token")
            return deepcopy(encoded_values[token])
        end,
    }
end

local BookStore = require("weread.lib.book_store")
local root = os.tmpname() .. "-weread-book-store"
os.remove(root)
local settings = { cache_dir = root }

local ok, index = BookStore.save(settings, "book/42", {
    book_id = "book/42",
    title = "Fixture book",
    author = "Fixture author",
    progress = 37,
    chapter_uid = 9,
    mp_articles = { { title = "Fixture article" } },
    chapters = { { chapterUid = 9 } },
})
expect(ok == true, "split book save failed")
expect(index.cache_dir == root .. "/book_42",
    "book id was not sanitized for the cache directory")
expect(BookStore.is_minimal_index({ ["book/42"] = index }),
    "saved index was not minimal")
expect(not BookStore.is_minimal_index({
    ["book/42"] = { cache_dir = index.cache_dir, title = "legacy" },
}), "legacy inline metadata was accepted as a minimal index")

local function exists(path)
    local file = io.open(path, "rb")
    if not file then return false end
    file:close()
    return true
end

expect(exists(index.cache_dir .. "/metadata.json"),
    "metadata file was not written")
expect(exists(index.cache_dir .. "/reading_state.json"),
    "reading-state file was not written")
expect(exists(index.cache_dir .. "/articles.json"),
    "article file was not written")
expect(exists(index.cache_dir .. "/.weread-cache-owner"),
    "cache ownership marker was not written")

local loaded = BookStore.load(settings, "book/42", index)
expect(loaded.title == "Fixture book" and loaded.author == "Fixture author",
    "metadata did not round-trip")
expect(loaded.progress == 37 and loaded.chapter_uid == 9,
    "reading state did not round-trip")
expect(loaded.mp_articles[1].title == "Fixture article",
    "article data did not round-trip")
expect(loaded.chapters == nil,
    "large chapter catalog should not be stored in the book record")
expect(loaded.cache_dir == index.cache_dir,
    "resolved cache directory did not round-trip")

ok, index = BookStore.save(settings, "book/42", {
    book_id = "book/42",
    title = "Metadata only",
    cache_dir = index.cache_dir,
})
expect(ok == true, "metadata-only update failed")
expect(not exists(index.cache_dir .. "/reading_state.json")
    and not exists(index.cache_dir .. "/articles.json"),
    "stale split files were not removed")
loaded = BookStore.load(settings, "book/42", index)
expect(loaded.title == "Metadata only"
    and loaded.progress == nil and loaded.mp_articles == nil,
    "removed split state reappeared after reload")

local unowned_parent = os.tmpname() .. "-weread-unowned"
local unowned_path = unowned_parent .. "/arbitrary"
local refused, refused_err = BookStore.save(settings, "book/42", {
    book_id = "book/42",
    cache_dir = unowned_path,
    title = "Must not be written",
})
expect(refused == false and refused_err ~= nil,
    "unowned persisted path was accepted for metadata writes")
local absent_status = os.execute(
    "test ! -e " .. string.format("%q", unowned_parent))
expect(absent_status == true or absent_status == 0,
    "unowned persisted path was created before validation")

local preserved, preserved_index = BookStore.save(settings, "book/42", {
    book_id = "book/42",
    cache_dir = unowned_path,
    title = "Preserved unsafe record",
}, { preserve_unowned_index = true })
expect(preserved == true and preserved_index.cache_dir == unowned_path
    and BookStore.load(settings, "book/42", preserved_index).title
        == "Preserved unsafe record"
    and BookStore.is_minimal_index({ ["book/42"] = preserved_index }),
    "unowned record could not be preserved as a non-writing index")

assert(os.execute("mkdir -p " .. string.format("%q", root .. "/collision")))
local collision_ok = BookStore.save(settings, "collision", {
    book_id = "collision",
    title = "Must not claim a same-name directory",
})
expect(collision_ok == false,
    "an existing same-name directory was claimed without cache evidence")

local legacy_dir = root .. "/legacy"
assert(os.execute("mkdir -p " .. string.format("%q", legacy_dir)))
local legacy_epub = assert(io.open(legacy_dir .. "/old.epub", "wb"))
legacy_epub:write("legacy")
legacy_epub:close()
local legacy_ok = BookStore.save(settings, "legacy", {
    book_id = "legacy",
    cached_file = legacy_dir .. "/old.epub",
    title = "Migrated legacy cache",
})
expect(legacy_ok == true
    and exists(legacy_dir .. "/.weread-cache-owner"),
    "a verified legacy cache could not be migrated")

assert(os.execute("mkdir -p " .. string.format("%q", unowned_path)))
encoded_values["foreign-metadata"] = { title = "Foreign metadata" }
local foreign = assert(io.open(unowned_path .. "/metadata.json", "wb"))
foreign:write("foreign-metadata")
foreign:close()
local safely_loaded = BookStore.load(settings, "book/42", {
    cache_dir = unowned_path,
    title = "Inline title",
})
expect(safely_loaded.title == "Inline title",
    "metadata was read from an unowned persisted directory")

local oversized_metadata = assert(io.open(
    index.cache_dir .. "/metadata.json", "wb"))
assert(oversized_metadata:seek("set", BookStore.MAX_METADATA_BYTES))
oversized_metadata:write("x")
oversized_metadata:close()
local bounded_load = BookStore.load(settings, "book/42", {
    cache_dir = index.cache_dir,
    title = "Bounded fallback",
})
expect(bounded_load.title == "Bounded fallback",
    "oversized metadata cache replaced the safe in-memory fallback")

os.execute("rm -rf " .. string.format("%q", root))
os.execute("rm -rf " .. string.format("%q", unowned_parent))

print(("book_store_spec: %d checks"):format(checks))
