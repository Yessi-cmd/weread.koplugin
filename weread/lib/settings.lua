local DataStorage = require("datastorage")
local BookStore = require("weread.lib.book_store")
local Cookie = require("weread.lib.cookie")
local LuaSettings = require("luasettings")
local lfs = require("libs/libkoreader-lfs")

local Settings = {}
Settings.__index = Settings
Settings.AUTH_SCHEMA_VERSION = 1
Settings.SYNC_SCHEMA_VERSION = 1
Settings.READ_REPORT_SCHEMA_VERSION = 1

local defaults = {
    auth_schema_version = Settings.AUTH_SCHEMA_VERSION,
    sync_schema_version = Settings.SYNC_SCHEMA_VERSION,
    read_report_schema_version = Settings.READ_REPORT_SCHEMA_VERSION,
    language = "zh",
    api_key = "",
    cookies = {},
    wr_ticket = "",
    wr_wrpa = "",
    account = {
        name = "",
        user_vid = "",
        login_method = "",
        login_time = 0,
    },
    books = {},
    downloads = {},
    sync = {
        pull_on_open = true,
        upload_on_close = false,
        ask_on_conflict = true,
        upload_interval_minutes = 1,
    },
    cache = {
        book_layout_mode = "smart",
        download_book_images = true,
        download_mp_images = false,
        download_underlines_and_thoughts = false,
        auto_prefetch_next_chapter = false,
        show_prefetch_notifications = true,
        show_annotations = true,
        -- When true, taps in the left/right edge zones never open thought popups
        -- (and native #wrthought link follow is suppressed there too).
        ignore_edge_thought_taps = true,
        -- Fraction of screen width on each side treated as the page-turn edge zone.
        edge_tap_ratio = 0.20,
        max_size_mb = 1024,
    },
    read_report = {
        enabled = true,
        mode = "auto",
        book_id = "",
        book_title = "",
        interval_seconds = 30,
        report_on_open = true,
    },
    advanced = {
        developer_logs = false,
    },
    update = {
        auto_check = false,
        prefer_proxy = true,
        last_check = 0,
        available_version = "",
        archive_url = "",
        checksum_url = "",
        archive_size = 0,
        release_notes = "",
        release_url = "",
    },
    shelf = {
        sort_order = "time_desc",
        paginated = true,
        view_mode = "list",
    },
    download_dir = "",
}

local function deepcopy(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    for key, item in pairs(value) do
        out[key] = deepcopy(item)
    end
    return out
end

local function merge_missing(target, source)
    local changed = false
    for key, value in pairs(source or {}) do
        if target[key] == nil then
            target[key] = deepcopy(value)
            changed = true
        elseif type(value) == "table" and type(target[key]) == "table" then
            changed = merge_missing(target[key], value) or changed
        end
    end
    return changed
end

local function ensure_dir(path)
    if not lfs.attributes(path, "mode") then
        lfs.mkdir(path)
    end
end

local function clear_auth_store(store)
    store:saveSetting("api_key", "")
    store:saveSetting("cookies", {})
    store:saveSetting("wr_ticket", "")
    store:saveSetting("wr_wrpa", "")
    store:saveSetting("account", deepcopy(defaults.account))
end

function Settings:new()
    local data_dir = DataStorage:getFullDataDir() .. "/weread"
    ensure_dir(data_dir)
    local obj = {
        data_dir = data_dir,
        default_cache_dir = data_dir .. "/cache",
        settings_file = DataStorage:getSettingsDir() .. "/weread.lua",
    }
    obj.store = LuaSettings:open(obj.settings_file)
    -- cache_dir is the download root; defaults to <data_dir>/cache unless overridden.
    local download_dir = obj.store:readSetting("download_dir", "")
    obj.cache_dir = (type(download_dir) == "string" and download_dir ~= "") and download_dir or obj.default_cache_dir
    ensure_dir(obj.cache_dir)
    local cache = obj.store:readSetting("cache", deepcopy(defaults.cache))
    local cache_changed = false
    if type(cache) ~= "table" then
        cache = deepcopy(defaults.cache)
        cache_changed = true
    end
    if cache.download_book_images == nil and cache.download_images ~= nil then
        cache.download_book_images = cache.download_images ~= false
        cache_changed = true
    end
    cache_changed = merge_missing(cache, defaults.cache) or cache_changed
    if cache.book_layout_mode ~= "smart"
        and cache.book_layout_mode ~= "original"
        and cache.book_layout_mode ~= "clean" then
        cache.book_layout_mode = defaults.cache.book_layout_mode
        cache_changed = true
    end
    local edge_tap_ratio = tonumber(cache.edge_tap_ratio)
    if not edge_tap_ratio or edge_tap_ratio < 0.10 or edge_tap_ratio > 0.40 then
        cache.edge_tap_ratio = defaults.cache.edge_tap_ratio
        cache_changed = true
    end
    local max_size_mb = tonumber(cache.max_size_mb)
    if not max_size_mb or max_size_mb < 16 or max_size_mb > 4096 then
        cache.max_size_mb = defaults.cache.max_size_mb
        cache_changed = true
    end
    if cache.download_images ~= nil then
        cache.download_images = nil
        cache_changed = true
    end
    if cache_changed then
        obj.store:saveSetting("cache", cache)
        obj.store:flush()
    end
    local stored_sync_version = tonumber(
        obj.store:readSetting("sync_schema_version", 0)) or 0
    if stored_sync_version < Settings.SYNC_SCHEMA_VERSION then
        local sync = obj.store:readSetting("sync", deepcopy(defaults.sync))
        if type(sync) ~= "table" then sync = deepcopy(defaults.sync) end
        -- Activate a verified open-time pull and the throttled heartbeat once
        -- for upgrades. Both remain user-controllable from the progress menu.
        sync.pull_on_open = true
        sync.upload_interval_minutes = defaults.sync.upload_interval_minutes
        obj.store:saveSetting("sync", sync)
        obj.store:saveSetting("sync_schema_version", Settings.SYNC_SCHEMA_VERSION)
        obj.store:flush()
    end
    local sync = obj.store:readSetting("sync", deepcopy(defaults.sync))
    local sync_changed = false
    if type(sync) ~= "table" then
        sync = deepcopy(defaults.sync)
        sync_changed = true
    end
    sync_changed = merge_missing(sync, defaults.sync) or sync_changed
    local interval = tonumber(sync.upload_interval_minutes)
    if interval ~= 0 and interval ~= 1 and interval ~= 2 and interval ~= 5 then
        sync.upload_interval_minutes = defaults.sync.upload_interval_minutes
        sync_changed = true
    elseif sync.upload_interval_minutes ~= interval then
        sync.upload_interval_minutes = interval
        sync_changed = true
    end
    if sync_changed then
        obj.store:saveSetting("sync", sync)
        obj.store:flush()
    end
    local stored_report_version = tonumber(
        obj.store:readSetting("read_report_schema_version", 0)) or 0
    if stored_report_version < Settings.READ_REPORT_SCHEMA_VERSION then
        local report = obj.store:readSetting(
            "read_report", deepcopy(defaults.read_report))
        if type(report) ~= "table" then
            report = deepcopy(defaults.read_report)
        else
            merge_missing(report, defaults.read_report)
            -- Preserve a deliberately selected manual target. Otherwise make
            -- this private build useful for daily reading records immediately.
            if tostring(report.book_id or "") == "" then
                report.mode = "auto"
                report.book_title = ""
            end
            report.enabled = true
            report.report_on_open = true
        end
        obj.store:saveSetting("read_report", report)
        obj.store:saveSetting(
            "read_report_schema_version", Settings.READ_REPORT_SCHEMA_VERSION)
        obj.store:flush()
    end
    local legacy_changed = false
    for _, key in ipairs({
        "config_auth_fingerprint",
        "config_preferences_fingerprint",
        "config_loaded",
        "curl_payload",
    }) do
        if obj.store:readSetting(key, nil) ~= nil then
            if type(obj.store.delSetting) == "function" then
                obj.store:delSetting(key)
            else
                obj.store:saveSetting(key, nil)
            end
            legacy_changed = true
        end
    end
    local stored_auth_version = tonumber(obj.store:readSetting("auth_schema_version", 0)) or 0
    if stored_auth_version < Settings.AUTH_SCHEMA_VERSION then
        -- Authentication before schema v1 may have come from legacy manual
        -- flows and has no reliable QR account provenance.
        -- Invalidate only credentials; books, downloads and user preferences
        -- remain intact and the UI will guide the user through a fresh QR login.
        clear_auth_store(obj.store)
        obj.store:saveSetting("auth_schema_version", Settings.AUTH_SCHEMA_VERSION)
        legacy_changed = true
    end
    if legacy_changed then
        obj.store:flush()
    end
    return setmetatable(obj, self)
end

function Settings:get(key, default)
    if default == nil then
        default = defaults[key]
    end
    if key ~= "books" then
        return self.store:readSetting(key, deepcopy(default))
    end
    local indexes = self.store:readSetting("books", {})
    local books = {}
    for book_id, index in pairs(indexes or {}) do
        books[book_id] = BookStore.load(self, book_id, index)
    end
    return books
end

function Settings:set(key, value)
    if key == "books" and type(value) == "table" then
        local indexes = {}
        for book_id, book in pairs(value) do
            local ok, index_or_err = BookStore.save(self, book_id, book)
            if not ok then
                error("Could not save book data: " .. tostring(index_or_err))
            end
            indexes[book_id] = index_or_err
        end
        value = indexes
    end
    self.store:saveSetting(key, value)
end

function Settings:delete(key)
    if type(self.store.delSetting) == "function" then
        self.store:delSetting(key)
    else
        self.store:saveSetting(key, nil)
    end
end

function Settings:has_legacy_book_records()
    local books = self.store:readSetting("books", {})
    return not BookStore.is_minimal_index(books)
end

function Settings:flush()
    self.store:flush()
end

function Settings:update_auth(credentials, options)
    credentials = credentials or {}
    options = options or {}
    local changed = false

    if type(credentials.cookies) == "table" then
        local cookies = credentials.cookies
        if options.replace_cookies ~= true then
            cookies = Cookie.merge(self:get("cookies", {}), cookies)
        else
            cookies = deepcopy(cookies)
        end
        self:set("cookies", cookies)
        changed = true
    end

    for _, key in ipairs({ "api_key", "wr_ticket", "wr_wrpa" }) do
        local value = credentials[key]
        if type(value) == "string" then
            self:set(key, value)
            changed = true
        end
    end
    if type(credentials.account) == "table" then
        self:set("account", deepcopy(credentials.account))
        changed = true
    end

    if changed and options.flush ~= false then
        self:flush()
    end
    return changed
end

function Settings:merge_set_cookie(set_cookie, options)
    if not set_cookie or set_cookie == "" then
        return false
    end
    local cookies = Cookie.merge_set_cookie(self:get("cookies", {}), set_cookie)
    return self:update_auth({ cookies = cookies }, {
        replace_cookies = true,
        flush = not options or options.flush ~= false,
    })
end

function Settings:get_all()
    local all = {}
    for key in pairs(defaults) do
        all[key] = self:get(key)
    end
    return all
end

function Settings:get_download_dir()
    return self.cache_dir
end

-- Pass nil or "" to reset to the default download directory.
function Settings:set_download_dir(path)
    if type(path) ~= "string" or path == "" then
        self:set("download_dir", "")
        self.cache_dir = self.default_cache_dir
    else
        self:set("download_dir", path)
        self.cache_dir = path
    end
    self:flush()
    ensure_dir(self.cache_dir)
    return self.cache_dir
end

function Settings:reset_account()
    clear_auth_store(self.store)
    self:flush()
end

function Settings:is_cookie_configured()
    return Cookie.has_login_cookie(self:get("cookies", {})) == true
end

function Settings:is_api_configured()
    return self:get("api_key", "") ~= ""
end

return Settings
