-- Pure lookups over the plugin's book index (the `books` table) and the files
-- it points at: which WeRead book a document belongs to, which chapter a cached
-- file maps to, and whether a shelf entry is already downloaded.
--
-- Kept free of KOReader dependencies (the book-directory resolver is injected,
-- since lib/content.lua pulls in LuaJIT's `bit`) so it can be unit-tested with a
-- plain Lua interpreter. See spec/book_index_spec.lua.

local Util = require("lib.util")

local BookIndex = {}

-- Identify the WeRead book a document belongs to.
--   opts.file        : absolute path of the open document
--   opts.books       : the books table (book_id -> record)
--   opts.cache_dir   : the plugin's cache root
--   opts.resolve_dir : function(book_id, book) -> that book's real directory
-- Returns the book id, or nil when the file is not WeRead content.
function BookIndex.detect_book_id(opts)
    opts = opts or {}
    local file = opts.file
    if type(file) ~= "string" or file == "" then
        return nil
    end
    local resolve_dir = opts.resolve_dir
    for book_id, book in pairs(opts.books or {}) do
        if type(book) == "table" then
            local dir = resolve_dir(book_id, book):gsub("/+$", "") .. "/"
            if file == book.cached_file or file:sub(1, #dir) == dir then
                return book_id
            end
        end
    end
    -- Require a path boundary after the cache dir
    local prefix = tostring(opts.cache_dir or ""):gsub("/+$", "") .. "/"
    if file:sub(1, #prefix) == prefix then
        local rest = file:sub(#prefix + 1)
        local book_id = rest:match("^([^/]+)")
        return book_id
    end
    return nil
end

-- Retrieves chapter information for the given file path.
--
-- Parameters:
--   book: The book object from settings containing chapters and cached_chapters.
--   file_path: The absolute path of the currently open document.
--
-- Returns:
--   current_idx (number or nil): The index of the current chapter within book.chapters, if it's a single chapter file.
--   current_ch (table or nil): The chapter object of the current chapter, if it's a single chapter file.
--   is_full_book (boolean): True if the file maps to multiple chapters (e.g. a combined EPUB), false otherwise.
function BookIndex.chapter_info_from_file(book, file_path)
    if not book or not file_path or not book.chapters or not book.cached_chapters then
        return nil, nil, false
    end

    local mapped_count = 0
    local current_uid = nil
    for uid, path in pairs(book.cached_chapters) do
        if path == file_path then
            mapped_count = mapped_count + 1
            current_uid = uid
        end
    end

    local is_full_book = (mapped_count > 1)

    if mapped_count == 1 and current_uid then
        for i, ch in ipairs(book.chapters) do
            if tostring(ch.chapterUid) == tostring(current_uid) then
                return i, ch, is_full_book
            end
        end
    end

    return nil, nil, is_full_book
end

-- Whether a shelf book has a cached EPUB on disk. `saved_books` is the books
-- table; `downloaded_cache`, when given, memoizes results per book id so a shelf
-- page rebuild stats each file only once.
function BookIndex.is_downloaded(book, saved_books, downloaded_cache)
    local book_id = book.book_id or book.bookId
    if not book_id then
        return false
    end
    if downloaded_cache and downloaded_cache[book_id] ~= nil then
        return downloaded_cache[book_id]
    end
    local record = (saved_books or {})[book_id]
    local is_downloaded = record ~= nil and Util.file_exists(record.cached_file)
    if downloaded_cache then
        downloaded_cache[book_id] = is_downloaded
    end
    return is_downloaded
end

return BookIndex
