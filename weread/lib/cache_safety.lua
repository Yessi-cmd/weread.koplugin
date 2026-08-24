-- Ownership markers and guarded removal for plugin-managed book directories.
-- Persistent paths are user-editable state, so deletion must never trust a
-- cached path alone. New and migrated directories receive a marker; legacy
-- directories may fall back to matching metadata or verified legacy files under
-- the exact book child of a configured WeRead cache root.

local CacheSafety = {}

CacheSafety.MARKER = ".weread-cache-owner"

local ok_json, json = pcall(require, "json")
if not ok_json then ok_json, json = pcall(require, "rapidjson") end

local function dirname(path)
    return type(path) == "string" and path:match("^(.*)/[^/]+$") or nil
end

local function basename(path)
    return type(path) == "string" and path:match("([^/]+)$") or nil
end

local function dir_name(book_id)
    local value = tostring(book_id or ""):gsub("[^%w%._-]", "_")
    return value ~= "" and value or "weread"
end

local function filesystem(options)
    if options and options.lfs then return options.lfs end
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok then ok, lfs = pcall(require, "lfs") end
    return ok and lfs or nil
end

local function path_mode(path, options)
    local lfs = filesystem(options)
    if not lfs then return nil end
    local attributes
    if type(lfs.symlinkattributes) == "function" then
        attributes = lfs.symlinkattributes(path)
    elseif type(lfs.attributes) == "function" then
        attributes = lfs.attributes(path)
    end
    return type(attributes) == "table" and attributes.mode or attributes
end

local function path_exists(path, options)
    if path_mode(path, options) then return true end
    local renamed, _, code = os.rename(path, path)
    -- POSIX may report EACCES for an existing path that cannot be renamed.
    return renamed == true or code == 13
end

local function safe_absolute_path(path)
    if type(path) ~= "string" or path == "" or path:sub(1, 1) ~= "/"
        or path == "/" or path:find("%z") then
        return false
    end
    for component in path:gmatch("[^/]+") do
        if component == "." or component == ".." then return false end
    end
    return dirname(path) ~= nil and basename(path) ~= nil
end

function CacheSafety.shell_quote(value)
    return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

function CacheSafety.make_path(path)
    if not safe_absolute_path(path) then return nil, "unsafe directory path" end
    local ok_util, util = pcall(require, "util")
    if ok_util and util and type(util.makePath) == "function" then
        local called, made, make_err = pcall(util.makePath, path)
        if not called then return nil, made end
        if made == false then return nil, make_err or "could not create directory" end
        return true
    end
    -- Plain-Lua test environments do not provide KOReader's util.makePath.
    -- Keep the fallback shell-safe; Lua's %q uses double quotes and therefore
    -- does not prevent command substitution in user-selected directory names.
    local status = os.execute("mkdir -p " .. CacheSafety.shell_quote(path))
    if status == true or status == 0 then return true end
    return nil, "could not create directory"
end

local function read_file(path, max_bytes)
    local file = io.open(path, "rb")
    if not file then return nil end
    local size = file:seek("end")
    if not size or size > (max_bytes or 65536) then
        file:close()
        return nil
    end
    file:seek("set", 0)
    local value = file:read("*a")
    file:close()
    return value
end

local function write_atomic(path, value)
    local temporary = path .. ".tmp"
    pcall(os.remove, temporary)
    local file, open_err = io.open(temporary, "wb")
    if not file then return nil, open_err end
    local wrote, write_err = file:write(value)
    local closed, close_err = file:close()
    if not wrote or not closed then
        pcall(os.remove, temporary)
        return nil, write_err or close_err or "marker write failed"
    end
    local renamed, rename_err = os.rename(temporary, path)
    if not renamed then
        pcall(os.remove, temporary)
        return nil, rename_err
    end
    return true
end

function CacheSafety.mark(path, book_id)
    if not safe_absolute_path(path) then return nil, "unsafe cache path" end
    local owner = tostring(book_id or ""):gsub("[%c]", "")
    if owner == "" then return nil, "missing cache owner" end
    return write_atomic(path .. "/" .. CacheSafety.MARKER,
        "weread-cache-v1\n" .. owner .. "\n")
end

function CacheSafety.read_marker_owner(path)
    if not safe_absolute_path(path) then return nil end
    local marker = read_file(path .. "/" .. CacheSafety.MARKER, 4096)
    if marker then
        local owner = marker:match("^weread%-cache%-v1\n([^\r\n]+)")
        if owner and owner ~= "" then return owner end
    end
    return nil
end

function CacheSafety.read_owner(path)
    if not safe_absolute_path(path) then return nil end
    local marker_owner = CacheSafety.read_marker_owner(path)
    if marker_owner then return marker_owner end
    if ok_json and json then
        local metadata = read_file(path .. "/metadata.json", 65536)
        if metadata then
            local ok, decoded = pcall(function()
                if json.decode then return json.decode(metadata) end
                return json:decode(metadata)
            end)
            if ok and type(decoded) == "table" then
                local owner = decoded.book_id or decoded.bookId
                if owner ~= nil then return tostring(owner) end
            end
        end
    end
    return nil
end

local function is_direct_regular_file(directory, path, options)
    if type(path) ~= "string" or dirname(path) ~= directory then return false end
    local mode = path_mode(path, options)
    if mode then return mode == "file" end
    local file = io.open(path, "rb")
    if not file then return false end
    file:close()
    return true
end

-- Old releases tracked downloaded files in the settings record but did not
-- create an ownership marker. Treat only existing regular files directly inside
-- the exact cache directory as migration evidence; a persisted path string by
-- itself is never sufficient.
function CacheSafety.has_legacy_file_evidence(directory, book, extra_paths, options)
    if type(book) ~= "table" then return false end
    for _, key in ipairs({ "cached_full_book", "cached_file" }) do
        if is_direct_regular_file(directory, book[key], options) then return true end
    end
    if type(book.cached_chapters) == "table" then
        for _, path in pairs(book.cached_chapters) do
            if is_direct_regular_file(directory, path, options) then return true end
        end
    end
    for _, path in ipairs(extra_paths or {}) do
        if is_direct_regular_file(directory, path, options) then return true end
    end
    return false
end

function CacheSafety.validate_owned(path, book_id, options)
    options = options or {}
    book_id = tostring(book_id or "")
    if book_id == "" then return nil, "missing book id" end
    if not safe_absolute_path(path) then return nil, "unsafe cache path" end

    local mode = path_mode(path, options)
    if mode == "link" then
        return nil, "refusing to use a symbolic-link cache directory"
    end
    if mode and mode ~= "directory" then
        return nil, "cache path is not a directory"
    end

    local owner = CacheSafety.read_owner(path)
    if owner then
        if owner == book_id then return true end
        return nil, "cache ownership does not match the book"
    end

    -- Compatibility for pre-marker caches that have not yet received split
    -- metadata. An exact direct-child name is necessary but not sufficient:
    -- existing directories also need concrete legacy file evidence. Writers may
    -- create a missing exact child, but may never claim an existing empty or
    -- unrelated directory merely because its name happens to match a book id.
    if basename(path) ~= dir_name(book_id) then
        return nil, "cache directory name does not match the book"
    end
    for _, root in pairs(options.roots or {}) do
        root = type(root) == "string" and root:gsub("/+$", "") or nil
        if root and root ~= "" and root ~= "/"
            and path == root .. "/" .. dir_name(book_id) then
            if options.legacy_evidence == true then
                return true, "legacy"
            end
            if options.allow_new_child == true
                and not path_exists(path, options) then
                return true, "new"
            end
            return nil, "legacy cache directory has no verified content"
        end
    end
    return nil, "cache directory has no WeRead ownership marker"
end

-- Claim or refresh a directory before writing plugin data. Unlike mark(), this
-- never turns an arbitrary persisted path into a plugin-owned deletion target:
-- it must already carry matching metadata/marker or verified legacy content.
-- A missing directory cannot be claimed until the caller has created it.
function CacheSafety.claim(path, book_id, options)
    local valid, validation_error = CacheSafety.validate_owned(
        path, book_id, options)
    if not valid then return nil, validation_error end
    return CacheSafety.mark(path, book_id)
end

function CacheSafety.remove_book_dir(path, book_id, options)
    options = options or {}
    local lfs = filesystem(options)
    if not lfs then return nil, "filesystem inspection is unavailable" end
    local attributes = lfs.symlinkattributes and lfs.symlinkattributes(path)
        or lfs.attributes(path)
    if not attributes then return true end
    local mode = type(attributes) == "table" and attributes.mode or attributes
    if mode == "link" then return nil, "refusing to remove a symbolic link" end
    if mode ~= "directory" then return nil, "cache path is not a directory" end

    local valid, validation_error = CacheSafety.validate_owned(
        path, book_id, options)
    if not valid then return nil, validation_error end

    local purge = options.purge
    if not purge then
        local ok, ffiutil = pcall(require, "ffi/util")
        purge = ok and ffiutil and ffiutil.purgeDir or nil
    end
    if type(purge) ~= "function" then
        return nil, "safe directory cleanup is unavailable"
    end
    local called, removed, purge_error = pcall(purge, path)
    if not called then return nil, removed end
    -- KOReader's purgeDir historically returned no value on success, while
    -- some test and platform implementations return true. Only an explicit
    -- false is a failure.
    if removed == false then
        return nil, purge_error or "safe directory cleanup failed"
    end
    return true
end

return CacheSafety
