-- Unit tests for lib/book_index.lua (book identification and chapter mapping).
-- Run from the repo root with a plain Lua interpreter:
--   lua spec/book_index_spec.lua

package.path = "./?.lua;" .. package.path
local BookIndex = require("lib.book_index")

local CACHE_DIR = "/mnt/onboard/weread"

-- Mirrors Content.book_resolved_dir: an explicit cache_dir wins, otherwise the
-- book sits under the cache root in a directory named after its id.
local function resolve_dir(book_id, book)
    if type(book) == "table" and type(book.cache_dir) == "string" and book.cache_dir ~= "" then
        return book.cache_dir
    end
    return CACHE_DIR .. "/" .. tostring(book_id)
end

local function detect(file, books)
    return BookIndex.detect_book_id{
        file = file,
        books = books,
        cache_dir = CACHE_DIR,
        resolve_dir = resolve_dir,
    }
end

local failures, checks = 0, 0
local current_test

local function eq(got, want, label)
    checks = checks + 1
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL [%s] %s: got %s, want %s",
            current_test, label, tostring(got), tostring(want)))
    end
end

local function test(name, fn)
    current_test = name
    fn()
end

test("detect: exact cached_file match", function()
    local books = {
        ["123"] = { cached_file = "/sdcard/elsewhere/three-body.epub" },
    }
    eq(detect("/sdcard/elsewhere/three-body.epub", books), "123", "matched by cached_file")
end)

test("detect: file inside a book's resolved directory", function()
    local books = {
        ["123"] = { cache_dir = "/sdcard/library/three-body" },
    }
    eq(detect("/sdcard/library/three-body/ch5.epub", books), "123", "matched by cache_dir prefix")
    eq(detect("/sdcard/library/three-body", books), nil, "the directory itself is not a document")
end)

test("detect: trailing slashes in the resolved dir do not break matching", function()
    local books = {
        ["123"] = { cache_dir = "/sdcard/library/three-body///" },
    }
    eq(detect("/sdcard/library/three-body/ch5.epub", books), "123", "trailing slashes normalized")
end)

test("detect: sibling directory sharing a name prefix is not matched", function()
    local books = {
        ["123"] = { cache_dir = "/sdcard/library/book" },
    }
    -- Without the path-boundary slash, "/sdcard/library/book2/..." would match.
    eq(detect("/sdcard/library/book2/ch1.epub", books), nil, "no false prefix match")
end)

test("detect: falls back to the first path segment under the cache root", function()
    eq(detect(CACHE_DIR .. "/987/ch1.epub", {}), "987", "book id from cache path")
    eq(detect(CACHE_DIR .. "/987", {}), "987", "single segment")
end)

test("detect: paths outside the cache root are not WeRead content", function()
    eq(detect("/sdcard/books/other.epub", {}), nil, "unrelated path")
    -- A sibling of the cache root must not be treated as being inside it.
    eq(detect(CACHE_DIR .. "-backup/987/ch1.epub", {}), nil, "cache root boundary enforced")
end)

test("detect: missing or empty file yields nil", function()
    eq(detect(nil, {}), nil, "nil file")
    eq(detect("", {}), nil, "empty file")
end)

test("detect: non-table book records are skipped", function()
    local books = { ["123"] = "corrupt" }
    eq(detect("/sdcard/whatever.epub", books), nil, "no crash, no match")
end)

local BOOK = {
    chapters = {
        { chapterUid = 11, title = "one" },
        { chapterUid = 22, title = "two" },
        { chapterUid = 33, title = "three" },
    },
}

local function book_with(cached_chapters)
    return { chapters = BOOK.chapters, cached_chapters = cached_chapters }
end

test("chapter_info: single mapped chapter resolves index and object", function()
    local book = book_with({ ["22"] = "/c/two.epub" })
    local idx, ch, is_full = BookIndex.chapter_info_from_file(book, "/c/two.epub")
    eq(idx, 2, "index")
    eq(ch and ch.title, "two", "chapter object")
    eq(is_full, false, "not a full book")
end)

test("chapter_info: chapterUid is compared as a string", function()
    -- cached_chapters keys are strings; chapters carry numeric uids.
    local book = book_with({ ["33"] = "/c/three.epub" })
    local idx = BookIndex.chapter_info_from_file(book, "/c/three.epub")
    eq(idx, 3, "numeric uid matches string key")
end)

test("chapter_info: a file mapped to several chapters is a full book", function()
    local book = book_with({ ["11"] = "/c/all.epub", ["22"] = "/c/all.epub" })
    local idx, ch, is_full = BookIndex.chapter_info_from_file(book, "/c/all.epub")
    eq(idx, nil, "no single index")
    eq(ch, nil, "no chapter object")
    eq(is_full, true, "full book")
end)

test("chapter_info: unmapped file yields nothing", function()
    local book = book_with({ ["11"] = "/c/one.epub" })
    local idx, ch, is_full = BookIndex.chapter_info_from_file(book, "/c/other.epub")
    eq(idx, nil, "no index")
    eq(ch, nil, "no chapter")
    eq(is_full, false, "not full book")
end)

test("chapter_info: mapped chapter missing from the catalog yields nothing", function()
    local book = book_with({ ["99"] = "/c/ghost.epub" })
    local idx, _ch, is_full = BookIndex.chapter_info_from_file(book, "/c/ghost.epub")
    eq(idx, nil, "uid not in catalog")
    eq(is_full, false, "not full book")
end)

test("chapter_info: missing inputs are tolerated", function()
    eq(BookIndex.chapter_info_from_file(nil, "/c/one.epub"), nil, "no book")
    eq(BookIndex.chapter_info_from_file(book_with({}), nil), nil, "no path")
    eq(BookIndex.chapter_info_from_file({ chapters = BOOK.chapters }, "/c/one.epub"), nil,
        "no cached_chapters")
    eq(BookIndex.chapter_info_from_file({ cached_chapters = {} }, "/c/one.epub"), nil,
        "no chapters")
end)

test("is_downloaded: needs a book id", function()
    eq(BookIndex.is_downloaded({}, {}, nil), false, "no id")
end)

test("is_downloaded: unknown book is not downloaded", function()
    eq(BookIndex.is_downloaded({ bookId = "404" }, {}, nil), false, "no record")
end)

test("is_downloaded: a record pointing at a missing file is not downloaded", function()
    local books = { ["123"] = { cached_file = "/nonexistent/never.epub" } }
    eq(BookIndex.is_downloaded({ bookId = "123" }, books, nil), false, "file missing")
end)

test("is_downloaded: an existing file counts as downloaded", function()
    -- Use this spec file itself as a file that certainly exists.
    local books = { ["123"] = { cached_file = "./spec/book_index_spec.lua" } }
    eq(BookIndex.is_downloaded({ bookId = "123" }, books, nil), true, "file present")
end)

test("is_downloaded: the cache is consulted and populated", function()
    local cache = { ["123"] = true }
    local books = { ["123"] = { cached_file = "/nonexistent/never.epub" } }
    -- The cached answer wins over the filesystem.
    eq(BookIndex.is_downloaded({ bookId = "123" }, books, cache), true, "cache hit")

    local fresh = {}
    eq(BookIndex.is_downloaded({ bookId = "123" }, books, fresh), false, "cache miss checks disk")
    eq(fresh["123"], false, "negative result memoized")
end)

test("is_downloaded: book_id wins over bookId", function()
    local books = { ["local"] = { cached_file = "./spec/book_index_spec.lua" } }
    eq(BookIndex.is_downloaded({ book_id = "local", bookId = "remote" }, books, nil), true,
        "book_id preferred")
end)

print(string.format("%d checks, %d failures", checks, failures))
if failures > 0 then
    os.exit(1)
end
