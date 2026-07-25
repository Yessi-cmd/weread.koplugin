-- Pure bookshelf ordering and filtering.
--
-- Only keys are handled here; the translated labels for each sort/filter option
-- live in the view (lib/shelf.lua) so this module stays free of KOReader and
-- i18n dependencies and can be unit-tested with a plain Lua interpreter.
-- See spec/shelf_sort_spec.lua.

local ShelfSort = {}

-- Returns a sorted copy, or the original table for the shelf's native order.
function ShelfSort.sort_books(books, sort_order)
    if sort_order == "default" or not sort_order then
        return books
    end
    local sorted = {}
    for i, book in ipairs(books) do
        sorted[i] = book
    end
    if sort_order == "time_desc" then
        table.sort(sorted, function(a, b)
            return (a.readUpdateTime or 0) > (b.readUpdateTime or 0)
        end)
    elseif sort_order == "time_asc" then
        table.sort(sorted, function(a, b)
            return (a.readUpdateTime or 0) < (b.readUpdateTime or 0)
        end)
    elseif sort_order == "name_asc" then
        table.sort(sorted, function(a, b)
            return (a.title or "") < (b.title or "")
        end)
    elseif sort_order == "name_desc" then
        table.sort(sorted, function(a, b)
            return (a.title or "") > (b.title or "")
        end)
    end
    return sorted
end

-- Whether a book passes the active filters.
--   filters.reading  : "finished" | "unfinished" | nil
--   filters.download : "downloaded" | "not_downloaded" | nil
--   is_downloaded    : function(book) -> boolean, only called when the download
--                      filter is active (so no filesystem work is done otherwise)
function ShelfSort.matches_filters(book, filters, is_downloaded)
    filters = filters or {}
    if filters.reading == "finished" and book.finishReading ~= 1 then return false end
    if filters.reading == "unfinished" and book.finishReading == 1 then return false end
    if filters.download then
        local downloaded = is_downloaded(book)
        if filters.download == "downloaded" and not downloaded then return false end
        if filters.download == "not_downloaded" and downloaded then return false end
    end
    return true
end

return ShelfSort
