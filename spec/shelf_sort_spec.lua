-- Unit tests for lib/shelf_sort.lua (bookshelf ordering and filtering).
-- Run from the repo root with a plain Lua interpreter:
--   lua spec/shelf_sort_spec.lua

package.path = "./?.lua;" .. package.path
local ShelfSort = require("lib.shelf_sort")

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

local function titles(books)
    local out = {}
    for i, book in ipairs(books) do
        out[i] = book.title
    end
    return table.concat(out, ",")
end

local function shelf()
    return {
        { title = "banana", readUpdateTime = 200 },
        { title = "apple",  readUpdateTime = 300 },
        { title = "cherry", readUpdateTime = 100 },
    }
end

test("sort: default and nil keep the shelf's own order", function()
    local books = shelf()
    eq(ShelfSort.sort_books(books, "default"), books, "default returns the same table")
    eq(ShelfSort.sort_books(books, nil), books, "nil returns the same table")
end)

test("sort: unknown order returns a copy in the original order", function()
    local books = shelf()
    local sorted = ShelfSort.sort_books(books, "nonsense")
    eq(titles(sorted), "banana,apple,cherry", "order untouched")
    eq(sorted ~= books, true, "but it is a copy")
end)

test("sort: by last read time", function()
    eq(titles(ShelfSort.sort_books(shelf(), "time_desc")), "apple,banana,cherry", "newest first")
    eq(titles(ShelfSort.sort_books(shelf(), "time_asc")), "cherry,banana,apple", "oldest first")
end)

test("sort: by title", function()
    eq(titles(ShelfSort.sort_books(shelf(), "name_asc")), "apple,banana,cherry", "A-Z")
    eq(titles(ShelfSort.sort_books(shelf(), "name_desc")), "cherry,banana,apple", "Z-A")
end)

test("sort: never mutates the input", function()
    local books = shelf()
    ShelfSort.sort_books(books, "name_asc")
    eq(titles(books), "banana,apple,cherry", "input order preserved")
end)

test("sort: missing fields are treated as zero / empty", function()
    local books = { { title = "has time", readUpdateTime = 5 }, { title = "no time" } }
    eq(titles(ShelfSort.sort_books(books, "time_desc")), "has time,no time", "nil time sorts last")
    local untitled = { {}, { title = "a" } }
    eq(ShelfSort.sort_books(untitled, "name_asc")[2].title, "a", "nil title sorts first")
end)

local function never_called()
    error("is_downloaded must not be called when no download filter is active")
end

test("filter: no filters accept everything", function()
    eq(ShelfSort.matches_filters({ finishReading = 1 }, {}, never_called), true, "empty filters")
    eq(ShelfSort.matches_filters({}, nil, never_called), true, "nil filters")
end)

test("filter: reading state", function()
    local done, reading = { finishReading = 1 }, { finishReading = 0 }
    eq(ShelfSort.matches_filters(done, { reading = "finished" }, never_called), true, "finished keeps done")
    eq(ShelfSort.matches_filters(reading, { reading = "finished" }, never_called), false, "finished drops reading")
    eq(ShelfSort.matches_filters(reading, { reading = "unfinished" }, never_called), true, "unfinished keeps reading")
    eq(ShelfSort.matches_filters(done, { reading = "unfinished" }, never_called), false, "unfinished drops done")
    -- A book with no finishReading field counts as unfinished.
    eq(ShelfSort.matches_filters({}, { reading = "unfinished" }, never_called), true, "missing field is unfinished")
    eq(ShelfSort.matches_filters({}, { reading = "finished" }, never_called), false, "missing field is not finished")
end)

test("filter: download state", function()
    local yes = function() return true end
    local no = function() return false end
    eq(ShelfSort.matches_filters({}, { download = "downloaded" }, yes), true, "downloaded keeps cached")
    eq(ShelfSort.matches_filters({}, { download = "downloaded" }, no), false, "downloaded drops uncached")
    eq(ShelfSort.matches_filters({}, { download = "not_downloaded" }, no), true, "not_downloaded keeps uncached")
    eq(ShelfSort.matches_filters({}, { download = "not_downloaded" }, yes), false, "not_downloaded drops cached")
end)

test("filter: the download check is skipped unless that filter is active", function()
    -- Guards the shelf-rebuild property that no file is stat-ed without need:
    -- never_called() would raise if the predicate ran.
    eq(ShelfSort.matches_filters({ finishReading = 1 }, { reading = "finished" }, never_called), true,
        "reading-only filter does not touch the disk")
end)

test("filter: both dimensions must pass", function()
    local yes = function() return true end
    local book = { finishReading = 1 }
    eq(ShelfSort.matches_filters(book, { reading = "finished", download = "downloaded" }, yes), true,
        "both satisfied")
    eq(ShelfSort.matches_filters(book, { reading = "unfinished", download = "downloaded" }, yes), false,
        "reading fails")
    eq(ShelfSort.matches_filters(book, { reading = "finished", download = "not_downloaded" }, yes), false,
        "download fails")
end)

print(string.format("%d checks, %d failures", checks, failures))
if failures > 0 then
    os.exit(1)
end
