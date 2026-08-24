local ok_json, json = pcall(require, "json")
if not ok_json then
    ok_json, json = pcall(require, "rapidjson")
end

local CacheSafety = require("weread.lib.cache_safety")
local logger = require("weread.lib.logger")

local BookStore = {}
BookStore.MAX_METADATA_BYTES = 2 * 1024 * 1024
BookStore.MAX_READING_STATE_BYTES = 1024 * 1024
BookStore.MAX_ARTICLES_BYTES = 16 * 1024 * 1024
local PRESERVED_UNOWNED = "_preserved_unowned"

local reading_fields = {
    app_id = true,
    chapter_idx = true,
    chapter_offset = true,
    chapter_uid = true,
    last_local_position = true,
    last_pull_at = true,
    last_remote_position = true,
    last_sync_error = true,
    last_upload_at = true,
    last_uploaded_position = true,
    pclts = true,
    pending_upload_position = true,
    pending_upload_reason = true,
    progress = true,
    psvts = true,
    read_context_updated_at = true,
    read_session_entered_at = true,
    read_session_id = true,
    reader_url = true,
    summary = true,
    token = true,
    verified_at = true,
    verified_source = true,
}

local article_fields = {
    mp_articles = true,
    mp_articles_time = true,
}

local function basename_safe(value)
    value = tostring(value or ""):gsub("[^%w%._-]", "_")
    return value ~= "" and value or "weread"
end

local function dirname(path)
    if type(path) == "string" then
        return path:match("^(.*)/[^/]+$")
    end
end

local function resolved_dir(settings, book_id, book)
    if type(book) == "table" and type(book.cache_dir) == "string" and book.cache_dir ~= "" then
        return book.cache_dir
    end
    local dir = type(book) == "table"
        and dirname(book.cached_full_book or book.cached_file) or nil
    if not dir and type(book) == "table" and type(book.cached_chapters) == "table" then
        for _uid, path in pairs(book.cached_chapters) do
            dir = dirname(path)
            if dir then break end
        end
    end
    local root = tostring(settings.cache_dir or ""):gsub("/+$", "")
    return dir or (root .. "/" .. basename_safe(book_id))
end

local function encode(value)
    if not ok_json then
        error("JSON module is not available")
    end
    if json.encode then
        return json.encode(value)
    end
    return json:encode(value)
end

local function decode(value)
    if not ok_json then
        error("JSON module is not available")
    end
    if json.decode then
        return json.decode(value)
    end
    return json:decode(value)
end

local function read_json(path, max_bytes)
    local file = io.open(path, "rb")
    if not file then return nil end
    local size, size_err = file:seek("end")
    if not size or size > max_bytes then
        file:close()
        return nil, size_err or "file exceeds cache size limit"
    end
    local rewound, rewind_err = file:seek("set", 0)
    if not rewound then
        file:close()
        return nil, rewind_err or "could not rewind cache file"
    end
    local content = file:read("*a")
    file:close()
    if not content then return nil, "could not read cache file" end
    local ok, value = pcall(decode, content)
    if ok and type(value) == "table" then return value end
    return nil, "invalid cache JSON"
end

local function write_json(path, value)
    local ok, content = pcall(encode, value)
    if not ok then return false, content end
    local tmp_path = path .. ".tmp"
    local file, err = io.open(tmp_path, "wb")
    if not file then return false, err end
    local write_ok, write_err = file:write(content)
    local close_ok, close_err = file:close()
    if not write_ok or not close_ok then
        os.remove(tmp_path)
        return false, write_err or close_err
    end
    local rename_ok, rename_err = os.rename(tmp_path, path)
    if not rename_ok then
        os.remove(tmp_path)
        return false, rename_err
    end
    return true
end

local function merge(target, source)
    for key, value in pairs(type(source) == "table" and source or {}) do
        target[key] = value
    end
end

local function has_values(value)
    return next(value) ~= nil
end

function BookStore.load(settings, book_id, index)
    local book = {}
    if type(index) == "table" then merge(book, index[PRESERVED_UNOWNED]) end
    merge(book, index)
    book[PRESERVED_UNOWNED] = nil
    local dir = resolved_dir(settings, book_id, index)
    local owner = tostring(book_id)
    local valid = CacheSafety.validate_owned(dir, owner, {
        roots = { settings.cache_dir, settings.default_cache_dir },
        legacy_evidence = CacheSafety.has_legacy_file_evidence(dir, book),
    })
    if valid then
        for _, cache in ipairs({
            { "metadata.json", BookStore.MAX_METADATA_BYTES },
            { "reading_state.json", BookStore.MAX_READING_STATE_BYTES },
            { "articles.json", BookStore.MAX_ARTICLES_BYTES },
        }) do
            local value, read_err = read_json(dir .. "/" .. cache[1], cache[2])
            merge(book, value)
            if read_err then
                logger.warn("ignore invalid book cache:", cache[1],
                    tostring(read_err))
            end
        end
    end
    book.book_id = owner
    book.cache_dir = dir
    return book
end

function BookStore.save(settings, book_id, book, options)
    options = options or {}
    book = type(book) == "table" and book or {}
    local dir = resolved_dir(settings, book_id, book)
    local owner = tostring(book_id)
    local roots = { settings.cache_dir, settings.default_cache_dir }
    local valid, validation_error = CacheSafety.validate_owned(dir, owner, {
        roots = roots,
        allow_new_child = true,
        legacy_evidence = CacheSafety.has_legacy_file_evidence(dir, book),
    })
    if not valid then
        if options.preserve_unowned_index then
            local preserved = { book_id = owner }
            for key, value in pairs(book) do
                if key ~= "chapters" and key ~= "cache_dir"
                    and key ~= "bookId" and key ~= "book_id" then
                    preserved[key] = value
                end
            end
            return true, {
                cache_dir = dir,
                [PRESERVED_UNOWNED] = preserved,
            }, validation_error
        end
        return false, validation_error
    end

    local made, make_err = CacheSafety.make_path(dir)
    if not made then return false, make_err end
    local marked, mark_err = CacheSafety.mark(dir, owner)
    if not marked then return false, mark_err end

    local metadata = { book_id = owner }
    local reading_state = {}
    local articles = {}
    for key, value in pairs(book) do
        if article_fields[key] then
            articles[key] = value
        elseif reading_fields[key] then
            reading_state[key] = value
        elseif key ~= "chapters" and key ~= "cache_dir"
            and key ~= "bookId" and key ~= "book_id" then
            metadata[key] = value
        end
    end

    local ok, err = write_json(dir .. "/metadata.json", metadata)
    if not ok then return false, err end
    if has_values(reading_state) then
        ok, err = write_json(dir .. "/reading_state.json", reading_state)
        if not ok then return false, err end
    else
        os.remove(dir .. "/reading_state.json")
    end
    if has_values(articles) then
        ok, err = write_json(dir .. "/articles.json", articles)
        if not ok then return false, err end
    else
        os.remove(dir .. "/articles.json")
    end
    return true, { cache_dir = dir }
end

function BookStore.is_minimal_index(books)
    for _book_id, record in pairs(books or {}) do
        if type(record) ~= "table" then return false end
        for key in pairs(record) do
            if key ~= "cache_dir" and key ~= PRESERVED_UNOWNED then
                return false
            end
        end
        if record[PRESERVED_UNOWNED] ~= nil
            and type(record[PRESERVED_UNOWNED]) ~= "table" then return false end
    end
    return true
end

return BookStore
