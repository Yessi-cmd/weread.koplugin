-- GitHub Release based self-updater.
--
-- Update checks are read-only. Installation is only performed after explicit
-- confirmation, verifies the release SHA-256, stages the archive, and keeps
-- the previous plugin directory as a rollback copy.
local Crypto = require("weread.lib.crypto")
local logger = require("weread.lib.logger")

local Updater = {}
Updater.__index = Updater

Updater.AUTO_CHECK_INTERVAL = 24 * 60 * 60
Updater.MAX_PACKAGE_BYTES = 10 * 1024 * 1024
Updater.MAX_RELEASE_METADATA_BYTES = 1024 * 1024
Updater.MAX_CHECKSUM_BYTES = 4096
Updater.MAX_UNPACKED_BYTES = 64 * 1024 * 1024
Updater.MAX_ARCHIVE_ENTRIES = 4096
Updater.API_URL = "https://api.github.com/repos/finlater/weread.koplugin/releases/latest"
Updater.RELEASE_PREFIX = "https://github.com/finlater/weread.koplugin/releases/download/"
Updater.GITHUB_MIRRORS = {
    "https://gh-proxy.com/",
    "https://ghfast.top/",
    "https://ghproxy.net/",
}

local function repository_urls(repository)
    repository = tostring(repository or "")
    local owner, name = repository:match("^([%w_.-]+)/([%w_.-]+)$")
    if not owner or owner == "." or owner == ".."
        or name == "." or name == ".." then
        return nil, "invalid update repository"
    end
    return {
        repository = repository,
        api_url = "https://api.github.com/repos/" .. repository
            .. "/releases/latest",
        release_prefix = "https://github.com/" .. repository
            .. "/releases/download/",
    }
end

Updater.repository_urls = repository_urls

local function plugin_dir_from_source()
    local source = debug.getinfo(1, "S").source or ""
    return source:match("^@?(.+)/weread/lib/[^/]+$")
end

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function read_file(path, max_bytes)
    local file, err = io.open(path, "rb")
    if not file then return nil, err end
    if max_bytes then
        local size, size_err = file:seek("end")
        if not size then
            file:close()
            return nil, size_err or "could not determine file size"
        end
        if size > max_bytes then
            file:close()
            return nil, "file is larger than expected"
        end
        local reset, reset_err = file:seek("set", 0)
        if not reset then
            file:close()
            return nil, reset_err or "could not rewind file"
        end
    end
    local data = file:read("*a")
    file:close()
    if not data then return nil, "could not read file" end
    return data
end

local function remove_file(path)
    if path then pcall(os.remove, path) end
end

local function safe_absolute_path(path)
    if type(path) ~= "string" or path == "" or path == "/"
        or path:sub(1, 1) ~= "/" or path:find("%z") then
        return false
    end
    for component in path:gmatch("[^/]+") do
        if component == "." or component == ".." then return false end
    end
    return true
end

local function path_mode(path)
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok or not lfs then return nil, "filesystem inspection unavailable" end
    local inspect = type(lfs.symlinkattributes) == "function"
        and lfs.symlinkattributes or lfs.attributes
    if type(inspect) ~= "function" then
        return nil, "filesystem inspection unavailable"
    end
    local called, attributes = pcall(inspect, path)
    if not called then return nil, attributes end
    return type(attributes) == "table" and attributes.mode or attributes
end

local function remove_tree(path)
    if not safe_absolute_path(path) then return nil, "invalid directory" end
    local mode, mode_err = path_mode(path)
    if mode_err then return nil, mode_err end
    if not mode then return true end
    if mode == "link" then return nil, "refusing to remove a symbolic link" end
    if mode ~= "directory" then return nil, "cleanup target is not a directory" end
    local ok, ffiutil = pcall(require, "ffi/util")
    if ok and ffiutil and ffiutil.purgeDir then
        local called, removed, err = pcall(ffiutil.purgeDir, path)
        if not called then return nil, removed end
        if removed == false then
            return nil, err or "directory cleanup failed"
        end
        return true
    end
    return nil, "directory cleanup unavailable"
end

local function make_path(path)
    if not safe_absolute_path(path) then return nil, "invalid directory" end
    local mode, mode_err = path_mode(path)
    if mode_err then return nil, mode_err end
    if mode == "link" then return nil, "refusing to use a symbolic link" end
    if mode then
        if mode == "directory" then return true end
        return nil, "path is not a directory"
    end
    local ok, util = pcall(require, "util")
    if ok and util and util.makePath then
        local called, made, make_err = pcall(util.makePath, path)
        if not called then return nil, made end
        if made == false then return nil, make_err or "could not create directory" end
        return true
    end
    local lfs = require("libs/libkoreader-lfs")
    return lfs.mkdir(path)
end

local function clear_tree(path, label)
    local mode, mode_err = path_mode(path)
    if mode_err then return nil, mode_err end
    if not mode then return true end
    if mode == "link" then
        return nil, "refusing to clean symbolic-link " .. tostring(label)
    end
    if mode ~= "directory" then
        return nil, tostring(label) .. " is not a directory"
    end
    local removed, remove_err = remove_tree(path)
    if not removed then return nil, remove_err end
    local remaining, inspect_err = path_mode(path)
    if inspect_err then return nil, inspect_err end
    if remaining then
        return nil, tostring(label) .. " cleanup was incomplete"
    end
    return true
end

function Updater.is_safe_archive_entry(entry)
    if type(entry) ~= "table" then return false end
    local path = entry.path
    local mode = entry.mode
    if type(path) ~= "string" or path == ""
        or path:sub(1, 1) == "/" or path:find("%z")
        or path:find("\\", 1, true) or path:find("//", 1, true)
        or path:match("^weread%.koplugin/") == nil
        or (mode ~= "file" and mode ~= "directory") then
        return false
    end
    for component in path:gmatch("[^/]+") do
        if component == "." or component == ".." then return false end
    end
    for _, key in ipairs({ "linkpath", "linkname", "hardlink", "symlink" }) do
        local value = entry[key]
        if value ~= nil and value ~= false and value ~= "" then return false end
    end
    if mode == "file" then
        local size = tonumber(entry.size)
        if not size or size < 0 or size ~= size
            or size > Updater.MAX_UNPACKED_BYTES then
            return false
        end
    end
    return true
end

local function unpack_release(archive, stage)
    local Archiver = require("ffi/archiver")
    local reader = Archiver.Reader:new()
    if not reader:open(archive) then
        reader:close()
        return nil, reader.err or "could not open release archive"
    end
    local ok, err = true, nil
    local entry_count, unpacked_bytes = 0, 0
    local seen_paths = {}
    for entry in reader:iterate() do
        local path = entry.path
        entry_count = entry_count + 1
        if not Updater.is_safe_archive_entry(entry) then
            ok, err = nil, "unsafe entry in release archive"
            break
        end
        if entry_count > Updater.MAX_ARCHIVE_ENTRIES then
            ok, err = nil, "release archive contains too many entries"
            break
        end
        if seen_paths[path] then
            ok, err = nil, "release archive contains duplicate paths"
            break
        end
        seen_paths[path] = true
        if entry.mode == "file" then
            unpacked_bytes = unpacked_bytes + tonumber(entry.size)
            if unpacked_bytes > Updater.MAX_UNPACKED_BYTES then
                ok, err = nil, "release archive expands beyond the size limit"
                break
            end
        end
        if not reader:extractToPath(path, stage .. "/" .. path) then
            ok, err = nil, reader.err or "archive extraction failed"
            break
        end
    end
    if reader.err then ok, err = nil, reader.err end
    reader:close()
    return ok, err
end

local function normalize_notes(notes)
    notes = trim(notes)
    if notes == "" then return nil end
    notes = notes:gsub("\r\n", "\n"):gsub("\r", "\n")
    notes = notes:gsub("^#+%s*", ""):gsub("\n#+%s*", "\n")
    notes = notes:gsub("%*%*(.-)%*%*", "%1")
    notes = notes:gsub("`(.-)`", "%1")
    if #notes > 1600 then notes = notes:sub(1, 1597) .. "..." end
    return notes
end

function Updater.compare_versions(left, right)
    local function parts(version)
        local major, minor, patch = tostring(version or ""):match(
            "^v?(%d+)%.(%d+)%.(%d+)$")
        if not major then return nil end
        return { tonumber(major), tonumber(minor), tonumber(patch) }
    end
    local a, b = parts(left), parts(right)
    if not a or not b then return nil end
    for i = 1, 3 do
        if a[i] < b[i] then return -1 end
        if a[i] > b[i] then return 1 end
    end
    return 0
end

function Updater.candidate_urls(url, prefer_proxy, source)
    source = source or {}
    local api_url = source.api_url or Updater.API_URL
    local release_prefix = source.release_prefix or Updater.RELEASE_PREFIX
    local is_allowed = url == api_url
        or (type(url) == "string"
            and url:sub(1, #release_prefix) == release_prefix)
    if not is_allowed then return {} end
    local direct, proxies = { url }, {}
    for _, prefix in ipairs(Updater.GITHUB_MIRRORS) do
        proxies[#proxies + 1] = prefix .. url
    end
    local out = {}
    local first, second = prefer_proxy and proxies or direct,
        prefer_proxy and direct or proxies
    for _, candidate in ipairs(first) do out[#out + 1] = candidate end
    for _, candidate in ipairs(second) do out[#out + 1] = candidate end
    return out
end

function Updater.parse_release(data, source)
    source = source or {}
    local release_prefix = source.release_prefix or Updater.RELEASE_PREFIX
    if type(data) ~= "table" or data.draft == true or data.prerelease == true then
        return nil, "invalid release metadata"
    end
    local version = type(data.tag_name) == "string"
        and data.tag_name:match("^v(%d+%.%d+%.%d+)$") or nil
    if not version then return nil, "invalid release tag" end

    local archive_name = "weread.koplugin-v" .. version .. ".zip"
    local checksum_name = archive_name .. ".sha256"
    local archive_url, checksum_url, archive_size
    for _, asset in ipairs(data.assets or {}) do
        if asset.name == archive_name then
            archive_url = asset.browser_download_url
            archive_size = tonumber(asset.size)
        elseif asset.name == checksum_name then
            checksum_url = asset.browser_download_url
        end
    end
    local function valid_url(url)
        return type(url) == "string"
            and url:sub(1, #release_prefix) == release_prefix
    end
    if not valid_url(archive_url) or not valid_url(checksum_url) then
        return nil, "release package or checksum is missing"
    end
    if archive_size and (archive_size < 0
        or archive_size > Updater.MAX_PACKAGE_BYTES) then
        return nil, "release package is too large"
    end
    local release_page_prefix = release_prefix:gsub("/download/$", "/tag/")
    return {
        version = version,
        archive_url = archive_url,
        checksum_url = checksum_url,
        archive_size = archive_size,
        notes = normalize_notes(data.body),
        -- Construct the page URL from the trusted repository instead of
        -- accepting an arbitrary link supplied by mirrored metadata.
        release_url = release_page_prefix .. "v" .. version,
    }
end

function Updater:new(options)
    options = options or {}
    local repository = options.repository or "finlater/weread.koplugin"
    local source, source_err = repository_urls(repository)
    assert(source, source_err)
    local obj = {
        settings = assert(options.settings, "settings required"),
        current_version = assert(options.current_version, "current_version required"),
        plugin_dir = options.plugin_dir or plugin_dir_from_source(),
        repository = source.repository,
        api_url = source.api_url,
        release_prefix = source.release_prefix,
    }
    assert(obj.plugin_dir and obj.plugin_dir ~= "", "plugin directory unavailable")
    return setmetatable(obj, self)
end

function Updater:_state()
    return self.settings:get("update")
end

function Updater:_save_state(values)
    local state = self:_state()
    for key, value in pairs(values) do state[key] = value end
    self.settings:set("update", state)
    self.settings:flush()
end

function Updater:has_update()
    local state = self:_state()
    if not self:_state_matches_repository(state) then return false end
    local latest = state.available_version
    return Updater.compare_versions(latest, self.current_version) == 1
end

function Updater:_state_matches_repository(state)
    state = state or self:_state()
    local state_repository = tostring(state.repository or "")
    return state_repository == self.repository
        or (state_repository == ""
            and self.repository == "finlater/weread.koplugin")
end

function Updater:last_check_time()
    local state = self:_state()
    if not self:_state_matches_repository(state) then return 0 end
    return tonumber(state.last_check) or 0
end

function Updater:available_version()
    return self:has_update() and self:_state().available_version or nil
end

function Updater:_http_get(url, destination, on_download, total_hint, max_bytes)
    local http = require("socket/http")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local sink, chunks, file, limit_error, transfer_error
    local received = 0
    local function close_destination()
        if not file then return true end
        local target = file
        file = nil
        local called, closed, close_err = pcall(target.close, target)
        if not called then return nil, closed end
        if not closed then return nil, close_err or "could not close download file" end
        return true
    end
    if destination then
        file = io.open(destination, "wb")
        if not file then return nil, "cannot create download file" end
        sink = function(chunk, err)
            if chunk then
                if max_bytes and received + #chunk > max_bytes then
                    limit_error = "download exceeds size limit"
                    return nil, limit_error
                end
                local wrote, write_err = file:write(chunk)
                if not wrote then
                    transfer_error = write_err or "download write failed"
                    return nil, transfer_error
                end
                received = received + #chunk
                if on_download then on_download(received, total_hint) end
                return 1
            end
            if err then transfer_error = err end
            local closed, close_err = close_destination()
            if not closed then
                transfer_error = close_err
                return nil, close_err
            end
            return 1
        end
    else
        chunks = {}
        sink = function(chunk, err)
            if chunk then
                if max_bytes and received + #chunk > max_bytes then
                    limit_error = "download exceeds size limit"
                    return nil, limit_error
                end
                received = received + #chunk
                chunks[#chunks + 1] = chunk
            elseif err then
                transfer_error = err
            end
            return 1
        end
    end
    local block_timeout = destination and socketutil.FILE_BLOCK_TIMEOUT
        or socketutil.LARGE_BLOCK_TIMEOUT
    local total_timeout = destination and socketutil.FILE_TOTAL_TIMEOUT
        or socketutil.LARGE_TOTAL_TIMEOUT
    local timeout_ok, timeout_err = pcall(function()
        socketutil:set_timeout(block_timeout, total_timeout)
    end)
    if not timeout_ok then
        close_destination()
        if destination then remove_file(destination) end
        return nil, "could not configure download timeout: " .. tostring(timeout_err)
    end
    local request_ok, code, headers, status = pcall(function()
        return socket.skip(1, http.request{
            url = url,
            method = "GET",
            headers = {
                ["User-Agent"] = "KOReader-WeRead-Updater/1.0",
                ["Accept"] = "application/vnd.github+json",
            },
            sink = sink,
            redirect = true,
        })
    end)
    local reset_ok, reset_err = pcall(function() socketutil:reset_timeout() end)
    local closed, close_err = close_destination()
    if limit_error or transfer_error then
        remove_file(destination)
        return nil, limit_error or transfer_error
    end
    if not request_ok then
        if destination then remove_file(destination) end
        return nil, "HTTP request failed: " .. tostring(code)
    end
    if not reset_ok then
        if destination then remove_file(destination) end
        return nil, "could not reset download timeout: " .. tostring(reset_err)
    end
    if not closed then
        if destination then remove_file(destination) end
        return nil, close_err
    end
    if headers == nil or code ~= 200 then
        if destination then remove_file(destination) end
        return nil, "HTTP " .. tostring(code or status or "error")
    end
    return destination and true or table.concat(chunks)
end

function Updater:_http_get_direct(url, destination, on_download, total_hint, max_bytes)
    local candidates = Updater.candidate_urls(url, false, self)
    if candidates[1] ~= url then return nil, "update URL is not allowed" end
    return self:_http_get(url, destination, on_download, total_hint, max_bytes)
end

function Updater:_http_get_with_mirrors(url, destination, on_download, total_hint, max_bytes)
    local candidates = Updater.candidate_urls(
        url, self:_state().prefer_proxy == true, self)
    if #candidates == 0 then return nil, "update URL is not allowed" end
    local last_error
    for index, candidate in ipairs(candidates) do
        if on_download then on_download(0, total_hint) end
        local ok, err = self:_http_get(
            candidate, destination, on_download, total_hint, max_bytes)
        if ok then
            logger.info("update resource fetched:", "source=", tostring(index),
                "proxy=", tostring(candidate ~= url))
            return ok
        end
        if err == "download exceeds size limit" then return nil, err end
        last_error = err
        logger.warn("update resource source failed:", "source=", tostring(index),
            "proxy=", tostring(candidate ~= url), "error=", tostring(err))
    end
    return nil, last_error or "all update sources failed"
end

function Updater:fetch_release()
    local body, err = self:_http_get_with_mirrors(
        self.api_url, nil, nil, nil, Updater.MAX_RELEASE_METADATA_BYTES)
    if not body then return nil, err end
    local ok_json, json = pcall(require, "json")
    if not ok_json then return nil, "JSON support unavailable" end
    local ok, data = pcall(json.decode, body)
    if not ok then return nil, "invalid GitHub response" end
    return Updater.parse_release(data, self)
end

function Updater:cache_release(release)
    self:_save_state{
        last_check = os.time(),
        available_version = release.version,
        archive_url = release.archive_url,
        checksum_url = release.checksum_url,
        archive_size = release.archive_size or 0,
        release_notes = release.notes or "",
        release_url = release.release_url or "",
        repository = self.repository,
    }
end

function Updater:clear_available_update()
    self:_save_state{
        available_version = "",
        archive_url = "",
        checksum_url = "",
    }
end

function Updater:cached_release()
    local state = self:_state()
    if not self:has_update() then return nil end
    return {
        version = state.available_version,
        archive_url = state.archive_url,
        checksum_url = state.checksum_url,
        archive_size = state.archive_size,
        notes = state.release_notes ~= "" and state.release_notes or nil,
        release_url = state.release_url,
    }
end

-- The backup must survive installation so a failed activation can be rolled
-- back. Reaching the end of the next plugin initialization confirms that the
-- new copy can load, at which point the previous copy is no longer needed.
function Updater:cleanup_backup()
    local backup = self.plugin_dir .. ".backup"
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok_lfs and lfs and not lfs.attributes(backup, "mode") then
        return true
    end
    local removed, err = remove_tree(backup)
    if removed then
        logger.info("previous update backup removed")
        return true
    end
    logger.warn("could not remove previous update backup:", tostring(err))
    return nil, err
end

function Updater:install_release(release, on_progress)
    local function report(stage, percent, current, total)
        if on_progress then
            on_progress{
                stage = stage,
                percent = percent,
                current = current or 0,
                total = total or 0,
            }
        end
    end
    report("preparing", 0)
    local data_dir = self.settings.data_dir
    if type(release) ~= "table"
        or Updater.compare_versions(release.version, release.version) == nil then
        return nil, "invalid release metadata"
    end
    if not safe_absolute_path(data_dir) or not safe_absolute_path(self.plugin_dir) then
        return nil, "invalid update installation path"
    end
    local plugin_mode, plugin_mode_err = path_mode(self.plugin_dir)
    if plugin_mode_err then return nil, plugin_mode_err end
    if plugin_mode ~= "directory" then
        return nil, plugin_mode == "link" and "plugin directory is a symbolic link"
            or "plugin directory is unavailable"
    end
    local archive = data_dir .. "/weread-update.zip"
    local checksum = archive .. ".sha256"
    local stage = data_dir .. "/update-stage"
    remove_file(archive)
    remove_file(checksum)
    local cleared, clear_err = clear_tree(stage, "staging directory")
    if not cleared then
        return nil, "cannot reset staging directory: " .. tostring(clear_err)
    end
    local made, make_err = make_path(stage)
    if not made then return nil, "cannot create staging directory: " .. tostring(make_err) end

    local archive_size = tonumber(release.archive_size) or 0
    if archive_size < 0 or archive_size > Updater.MAX_PACKAGE_BYTES then
        remove_tree(stage)
        return nil, "release package size is invalid"
    end
    local ok, err = self:_http_get_with_mirrors(
        release.archive_url, archive, function(received, total)
            local ratio = total and total > 0 and math.min(1, received / total) or 0
            report("downloading", math.floor(5 + ratio * 70), received, total or 0)
        end, archive_size, Updater.MAX_PACKAGE_BYTES)
    if not ok then remove_tree(stage); return nil, err end
    report("checksum", 76)
    -- The package may use a configured mirror, but its signed digest must come
    -- from the canonical GitHub URL. Otherwise one proxy could replace both.
    local checksum_ok, checksum_err = self:_http_get_direct(
        release.checksum_url, checksum, nil, nil, Updater.MAX_CHECKSUM_BYTES)
    if not checksum_ok then
        remove_file(archive); remove_tree(stage)
        return nil, checksum_err
    end
    local package, package_err = read_file(archive, Updater.MAX_PACKAGE_BYTES)
    local checksum_body = read_file(checksum, Updater.MAX_CHECKSUM_BYTES)
    if not package or not checksum_body then
        remove_file(archive); remove_file(checksum); remove_tree(stage)
        return nil, package_err or "invalid checksum file"
    end
    report("verifying", 82)
    local expected = checksum_body:match("^%s*([0-9a-fA-F]+)")
    if not expected or #expected ~= 64 or Crypto.sha256_hex(package) ~= expected:lower() then
        remove_file(archive); remove_file(checksum); remove_tree(stage)
        return nil, "SHA-256 verification failed"
    end

    report("extracting", 90)
    local unpacked, unpack_err = unpack_release(archive, stage)
    remove_file(archive)
    remove_file(checksum)
    if not unpacked then remove_tree(stage); return nil, unpack_err or "archive extraction failed" end
    local staged_plugin = stage .. "/weread.koplugin"
    local meta = read_file(staged_plugin .. "/_meta.lua", 65536)
    local main = read_file(staged_plugin .. "/main.lua", 1024 * 1024)
    local staged_version = meta and meta:match('version%s*=%s*"([^"]+)"') or nil
    if not main or staged_version ~= release.version then
        remove_tree(stage)
        return nil, "release package structure or version is invalid"
    end

    report("installing", 97)
    local backup = self.plugin_dir .. ".backup"
    local backup_cleared, backup_clear_err = clear_tree(backup, "update backup")
    if not backup_cleared then
        remove_tree(stage)
        return nil, "cannot reset update backup: " .. tostring(backup_clear_err)
    end
    local moved_old, move_old_err = os.rename(self.plugin_dir, backup)
    if not moved_old then remove_tree(stage); return nil, move_old_err or "could not back up plugin" end
    local moved_new, move_new_err = os.rename(staged_plugin, self.plugin_dir)
    if not moved_new then
        local restored, restore_err = os.rename(backup, self.plugin_dir)
        remove_tree(stage)
        if not restored then
            return nil, "could not activate update and rollback failed: "
                .. tostring(restore_err or move_new_err)
        end
        return nil, move_new_err or "could not activate update"
    end
    remove_tree(stage)
    report("complete", 100)
    return true
end

return Updater
